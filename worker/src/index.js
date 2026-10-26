// store-pos Cloudflare Worker
// POST /sync              推送本地改动，拉取服务器上 since 之后变化的商品
// PUT  /images/:barcode   上传商品图片（JPEG，需口令）
// GET  /images/:barcode   下载商品图片（需口令）
// GET  /app/latest        最新 APK 版本信息（公开）
// GET  /app/download      下载最新 APK（公开，国内比直连 GitHub 稳）
// GET  /health            健康检查
const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });


// 首次请求时自动建表（不需要单独执行 schema.sql）
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS products ( barcode TEXT PRIMARY KEY, name TEXT NOT NULL, price_cents INTEGER NOT NULL DEFAULT 0, stock INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL )`,
  `CREATE INDEX IF NOT EXISTS idx_products_updated ON products(updated_at)`,
  `CREATE TABLE IF NOT EXISTS movements ( id TEXT PRIMARY KEY, barcode TEXT NOT NULL, delta INTEGER NOT NULL, type TEXT NOT NULL, device TEXT, created_at INTEGER NOT NULL )`,
  `CREATE INDEX IF NOT EXISTS idx_movements_barcode ON movements(barcode)`,
  `CREATE TABLE IF NOT EXISTS sales ( id TEXT PRIMARY KEY, total_cents INTEGER NOT NULL, items TEXT NOT NULL, device TEXT, created_at INTEGER NOT NULL )`,
  `CREATE TABLE IF NOT EXISTS images ( barcode TEXT PRIMARY KEY, data BLOB NOT NULL, mime TEXT NOT NULL, updated_at INTEGER NOT NULL )`,
];
let migrated = false;
async function migrate(db) {
  if (migrated) return;
  await db.batch(SCHEMA.map((sql) => db.prepare(sql)));
  try {
    await db.prepare(`ALTER TABLE products ADD COLUMN image_ver INTEGER NOT NULL DEFAULT 0`).run();
  } catch (_) {
    // 列已存在
  }
  migrated = true;
}

const REPO = 'testdogbot/store-pos';
async function latestRelease() {
  const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { 'user-agent': 'store-pos-worker', accept: 'application/vnd.github+json' },
    cf: { cacheTtl: 120, cacheEverything: true },
  });
  if (!r.ok) return null;
  const rel = await r.json();
  const asset = (rel.assets || []).find((a) => a.name.endsWith('.apk'));
  const build = parseInt(String(rel.tag_name).replace(/\D/g, ''), 10) || 0;
  return { build, version: rel.name, tag: rel.tag_name, notes: rel.body || '', apk: asset && asset.browser_download_url };
}

const MAX_IMAGE = 1024 * 1024; // 1 MB，App 端会先压缩到几十 KB

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, time: Date.now() });

    if (url.pathname === '/app/latest') {
      const rel = await latestRelease();
      return rel ? json(rel) : json({ error: 'no release' }, 502);
    }
    if (url.pathname === '/app/download') {
      const rel = await latestRelease();
      if (!rel || !rel.apk) return json({ error: 'no release' }, 502);
      const r = await fetch(rel.apk, { headers: { 'user-agent': 'store-pos-worker' } });
      return new Response(r.body, {
        status: r.status,
        headers: {
          'content-type': 'application/vnd.android.package-archive',
          'content-disposition': `attachment; filename="store-pos-${rel.build}.apk"`,
          ...(r.headers.get('content-length') ? { 'content-length': r.headers.get('content-length') } : {}),
        },
      });
    }

    const auth = request.headers.get('authorization') || '';
    if (!env.API_TOKEN || auth !== `Bearer ${env.API_TOKEN}`) {
      return json({ error: 'unauthorized' }, 401);
    }

    await migrate(env.DB);

    if (url.pathname === '/sync' && request.method === 'POST') {
      return sync(await request.json(), env.DB);
    }

    const im = url.pathname.match(/^\/images\/([^/]+)$/);
    if (im) {
      const barcode = decodeURIComponent(im[1]);
      if (request.method === 'PUT') {
        const buf = await request.arrayBuffer();
        if (!buf.byteLength) return json({ error: 'empty' }, 400);
        if (buf.byteLength > MAX_IMAGE) return json({ error: 'too large' }, 413);
        const mime = request.headers.get('content-type') || 'image/jpeg';
        const now = Date.now();
        await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO images (barcode, data, mime, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(barcode) DO UPDATE SET data = excluded.data, mime = excluded.mime, updated_at = ?4`
          ).bind(barcode, buf, mime, now),
          env.DB.prepare(
            `INSERT INTO products (barcode, name, price_cents, stock, updated_at, image_ver)
             VALUES (?1, ?1, 0, 0, ?2, ?2)
             ON CONFLICT(barcode) DO UPDATE SET image_ver = ?2, updated_at = ?2`
          ).bind(barcode, now),
        ]);
        return json({ ok: true, image_ver: now });
      }
      if (request.method === 'GET') {
        const row = await env.DB.prepare(`SELECT data, mime, updated_at FROM images WHERE barcode = ?1`)
          .bind(barcode)
          .first();
        if (!row) return json({ error: 'not found' }, 404);
        return new Response(new Uint8Array(row.data), {
          headers: { 'content-type': row.mime, 'x-image-ver': String(row.updated_at) },
        });
      }
    }
    return json({ error: 'not found' }, 404);
  },
};

async function sync(body, db) {
  const { device = '', since = 0, products = [], movements = [], sales = [] } = body || {};
  const now = Date.now();
  const stmts = [];

  // 1. 商品资料（名称/价格）：最后同步的为准，不碰库存（库存只由流水决定）
  for (const p of products) {
    if (!p.barcode || !p.name) continue;
    stmts.push(
      db.prepare(
        `INSERT INTO products (barcode, name, price_cents, stock, updated_at)
         VALUES (?1, ?2, ?3, 0, ?4)
         ON CONFLICT(barcode) DO UPDATE SET
           name = excluded.name, price_cents = excluded.price_cents, updated_at = ?4`
      ).bind(p.barcode, p.name, p.price_cents | 0, now)
    );
  }

  // 2. 库存流水：按 id 去重；库存 = 该商品所有流水之和（幂等，多设备不冲突）
  const touched = new Set();
  for (const m of movements) {
    if (!m.id || !m.barcode) continue;
    touched.add(m.barcode);
    stmts.push(
      db.prepare(
        `INSERT INTO products (barcode, name, price_cents, stock, updated_at)
         VALUES (?1, ?1, 0, 0, ?2)
         ON CONFLICT(barcode) DO NOTHING`
      ).bind(m.barcode, now)
    );
    stmts.push(
      db.prepare(
        `INSERT OR IGNORE INTO movements (id, barcode, delta, type, device, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`
      ).bind(m.id, m.barcode, m.delta | 0, m.type || 'adjust', device, m.created_at | 0)
    );
  }
  for (const barcode of touched) {
    stmts.push(
      db.prepare(
        `UPDATE products
           SET stock = (SELECT COALESCE(SUM(delta), 0) FROM movements WHERE barcode = ?1),
               updated_at = ?2
         WHERE barcode = ?1`
      ).bind(barcode, now)
    );
  }

  for (const s of sales) {
    if (!s.id) continue;
    stmts.push(
      db.prepare(
        `INSERT OR IGNORE INTO sales (id, total_cents, items, device, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)`
      ).bind(s.id, s.total_cents | 0, JSON.stringify(s.items || []), device, s.created_at | 0)
    );
  }

  if (stmts.length) await db.batch(stmts);

  const { results } = await db
    .prepare(`SELECT barcode, name, price_cents, stock, updated_at, image_ver FROM products WHERE updated_at > ?1`)
    .bind(since | 0)
    .all();

  return json({ server_time: now, products: results });
}
