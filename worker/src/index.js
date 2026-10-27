// store-pos Cloudflare Worker
// POST /sync              推送本地改动，拉取服务器上 since 之后变化的商品
// PUT  /images/:barcode   上传商品图片（JPEG，需口令）
// GET  /images/:barcode   下载商品图片（需口令）
// GET  /app/latest        最新 APK 版本信息（公开）
// GET  /app/download      下载最新 APK（公开，国内比直连 GitHub 稳）
// GET  /lookup/:barcode   条码查商品信息（需口令；缓存 → 极数本源 → Open Food Facts）
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
  `CREATE TABLE IF NOT EXISTS barcode_cache ( barcode TEXT PRIMARY KEY, data TEXT NOT NULL, found INTEGER NOT NULL, updated_at INTEGER NOT NULL )`,
  `CREATE TABLE IF NOT EXISTS config ( key TEXT PRIMARY KEY, value TEXT NOT NULL )`,
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
  for (const sql of [
    `ALTER TABLE products ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0`,
    `ALTER TABLE sales ADD COLUMN original_total_cents INTEGER`,
    `ALTER TABLE sales ADD COLUMN note TEXT`,
    `ALTER TABLE sales ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0`,
    `ALTER TABLE sales ADD COLUMN edited_at INTEGER`,
  ]) {
    try {
      await db.prepare(sql).run();
    } catch (_) {
      // 列已存在
    }
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

// ---------- 条码查商品 ----------
// ApiZero Key：优先 Worker 环境变量，其次老板在 App 后台填写的（存 D1 config 表）
async function apizeroKey(env) {
  if (env.APIZERO_KEY) return env.APIZERO_KEY;
  if (env._azk !== undefined) return env._azk;
  try {
    const r = await env.DB.prepare(`SELECT value FROM config WHERE key = 'apizero_key'`).first();
    env._azk = r ? r.value : '';
  } catch (_) {
    env._azk = '';
  }
  return env._azk;
}
async function lookupApizero(barcode, env) {
  const headers = { 'user-agent': 'store-pos-worker' };
  const key = await apizeroKey(env);
  if (key) headers.authorization = `Bearer ${key}`;
  for (let i = 0; i < 2; i++) {
    const r = await fetch(`https://v1.apizero.cn/api/barcode-lookup?barcode=${encodeURIComponent(barcode)}`, { headers });
    if (!r.ok) return null;
    const j = await r.json();
    if (j.code === 4029) {
      await new Promise((res) => setTimeout(res, 1100));
      continue;
    }
    if (j.code !== 0 || !j.data) return null;
    if (!j.data.found) return { found: false };
    const d = j.data;
    return {
      found: true,
      name: d.name || '',
      brand: d.brand || '',
      spec: d.spec || '',
      manufacturer: d.manufacturer || '',
      price_cents: typeof d.price === 'number' ? Math.round(d.price * 100) : null,
      source: 'apizero',
    };
  }
  return null;
}

// 中国物品编码中心官方登记数据（ApiZero 商品条码查询PRO）：免费每天 5 次，超出按次计费，只在其他来源都查不到时用
async function lookupGs1(barcode, env) {
  const key = await apizeroKey(env);
  if (!key || !/^\d{8,14}$/.test(barcode)) return null;
  const r = await fetch(`https://v1.apizero.cn/api/barcode-gs1?code=${encodeURIComponent(barcode)}`, {
    headers: { 'user-agent': 'store-pos-worker', authorization: `Bearer ${key}` },
  });
  const j = await r.json().catch(() => null);
  if (!j || j.code !== 0 || !j.data) return j && (j.code === 4030 || j.code === 4022) ? { quota: true } : null;
  const d = j.data;
  if (!d.found) return { found: false };
  return {
    found: true,
    name: d.name || d.general_name || '',
    brand: d.brand || '',
    spec: d.specification || d.net_content || '',
    manufacturer: d.manufacturer || '',
    price_cents: null,
    image_url: (d.images && d.images[0]) || null,
    source: 'gs1',
  };
}

async function lookupOff(barcode) {
  const r = await fetch(
    `https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(barcode)}.json?fields=product_name,product_name_zh,brands,quantity,image_front_url`,
    { headers: { 'user-agent': 'store-pos-worker/1.0 (pos.xiaolele.eu.cc)' } }
  );
  if (!r.ok) return null;
  const j = await r.json();
  if (j.status !== 1 || !j.product) return { found: false };
  const p = j.product;
  return {
    found: true,
    name: p.product_name_zh || p.product_name || '',
    brand: (p.brands || '').split(',')[0].trim(),
    spec: p.quantity || '',
    image_url: p.image_front_url || null,
    source: 'openfoodfacts',
  };
}

// 本地条码库（EricLiuCN/barcode 100 万条 + 药品 4 万条），按前 6 位分片放在 GitHub barcode-db 分支
async function lookupLocalDb(barcode) {
  if (!/^\d{8,14}$/.test(barcode)) return null;
  const r = await fetch(
    `https://raw.githubusercontent.com/testdogbot/store-pos/barcode-db/d/${barcode.slice(0, 6)}.json`,
    { cf: { cacheTtl: 7 * 86400, cacheEverything: true } }
  );
  if (r.status === 404) return { found: false };
  if (!r.ok) return null;
  const v = (await r.json())[barcode];
  if (!v) return { found: false };
  const [name, spec, brand, price, manufacturer] = v;
  return { found: true, name, spec, brand, manufacturer, price_cents: price ?? null, source: 'localdb' };
}

async function lookup(barcode, env) {
  const cached = await env.DB.prepare(`SELECT data, found, updated_at FROM barcode_cache WHERE barcode = ?1`)
    .bind(barcode)
    .first();
  // 查到的永久缓存；没查到的 7 天后再查
  if (cached) {
    const d = JSON.parse(cached.data);
    // 有价格的结果永久缓存；没价格/没查到的 7 天后重查（本地条码库可能有参考价）
    const fresh = Date.now() - cached.updated_at < 7 * 86400000;
    if ((d.found && d.price_cents != null) || (fresh && d.source === 'localdb') || (!d.found && fresh)) {
      return { ...d, cached: true };
    }
    if (d.found && d.price_cents == null && d.source !== 'localdb') {
      try {
        const local = await lookupLocalDb(barcode);
        if (local && local.found && local.price_cents != null) {
          d.price_cents = local.price_cents;
          await env.DB.prepare(`UPDATE barcode_cache SET data = ?2, updated_at = ?3 WHERE barcode = ?1`)
            .bind(barcode, JSON.stringify(d), Date.now())
            .run();
        }
      } catch (_) {}
      return d;
    }
  }
  let res = null;
  try {
    res = await lookupLocalDb(barcode);
  } catch (_) {}
  if (!res || !res.found) {
    try {
      const api = await lookupApizero(barcode, env);
      if (api) res = api;
    } catch (_) {}
  }
  let off = null;
  try {
    off = await lookupOff(barcode);
  } catch (_) {}
  if (res && res.found) {
    if (off && off.found && off.image_url) res.image_url = off.image_url;
    if (res.price_cents == null && res.source !== 'localdb') {
      try {
        const local = await lookupLocalDb(barcode);
        if (local && local.found && local.price_cents != null) res.price_cents = local.price_cents;
      } catch (_) {}
    }
  } else if (off && off.found && off.name) {
    res = off;
  }
  if (!res || !res.found) {
    // 最后才查编码中心官方数据（有额度限制）
    try {
      const g = await lookupGs1(barcode, env);
      if (g && g.found) res = g;
      else if (g && g.quota && !(res && res.found)) return { found: false, error: '官方条码库今日免费额度已用完' };
    } catch (_) {}
  }
  if (res && res.found) {
    // 已找到
  } else if (res || off) {
    res = { found: false };
  } else {
    return { found: false, error: 'lookup unavailable' }; // 查询服务都不可用，不缓存
  }
  if (res.found) {
    const extra = res.spec && !res.name.includes(res.spec) ? ` ${res.spec}` : '';
    res.display_name = `${res.name}${extra}`.trim();
  }
  await env.DB.prepare(
    `INSERT INTO barcode_cache (barcode, data, found, updated_at) VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(barcode) DO UPDATE SET data = excluded.data, found = excluded.found, updated_at = excluded.updated_at`
  )
    .bind(barcode, JSON.stringify(res), res.found ? 1 : 0, Date.now())
    .run();
  return res;
}

// ---------- 主账号（老板）：营业额管理 ----------
async function sha256(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`store-pos:${text}`));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function getConfig(db, key) {
  const r = await db.prepare(`SELECT value FROM config WHERE key = ?1`).bind(key).first();
  return r ? r.value : null;
}
const TZ = 8 * 3600000; // 按北京时间算“哪一天”

async function admin(request, env, url) {
  const db = env.DB;
  const hash = await getConfig(db, 'admin_hash');
  if (url.pathname === '/admin/status') return json({ has_admin: !!hash });
  if (url.pathname === '/admin/setup' && request.method === 'POST') {
    if (hash) return json({ error: '主账号已设置' }, 409);
    const { password = '' } = await request.json();
    if (String(password).length < 4) return json({ error: '密码至少 4 位' }, 400);
    await db.prepare(`INSERT INTO config (key, value) VALUES ('admin_hash', ?1)`).bind(await sha256(password)).run();
    return json({ ok: true });
  }
  const pw = request.headers.get('x-admin-password') || '';
  if (!hash || (await sha256(pw)) !== hash) return json({ error: '主账号密码错误' }, 403);

  if (url.pathname === '/admin/login') return json({ ok: true });

  // 条码查询 Key（ApiZero）：只回显是否已设置和末 4 位
  if (url.pathname === '/admin/apizero') {
    if (request.method === 'POST') {
      const { key = '' } = await request.json();
      const k = String(key).trim();
      if (!k) {
        await db.prepare(`DELETE FROM config WHERE key = 'apizero_key'`).run();
        return json({ ok: true, has_key: false });
      }
      // 先验证 Key 是否有效（用免费接口试一次）
      const t = await fetch('https://v1.apizero.cn/api/barcode-lookup?barcode=6921168509256', {
        headers: { 'user-agent': 'store-pos-worker', authorization: `Bearer ${k}` },
      });
      const tj = await t.json().catch(() => ({}));
      if (tj.code === 4011 || tj.code === 4013 || tj.code === 4015) return json({ error: `Key 无效：${tj.msg || tj.code}` }, 400);
      await db
        .prepare(`INSERT INTO config (key, value) VALUES ('apizero_key', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
        .bind(k)
        .run();
      await db.prepare(`DELETE FROM barcode_cache WHERE found = 0`).run(); // 之前没查到的重新查
      return json({ ok: true, has_key: true, tail: k.slice(-4) });
    }
    const k = await getConfig(db, 'apizero_key');
    return json({ has_key: !!k, tail: k ? k.slice(-4) : null });
  }

  if (url.pathname === '/admin/password' && request.method === 'POST') {
    const { password = '' } = await request.json();
    if (String(password).length < 4) return json({ error: '密码至少 4 位' }, 400);
    await db.prepare(`UPDATE config SET value = ?1 WHERE key = 'admin_hash'`).bind(await sha256(password)).run();
    return json({ ok: true });
  }

  // 每日汇总：最近 days 天
  if (url.pathname === '/admin/summary') {
    const days = Math.min(Math.max(parseInt(url.searchParams.get('days') || '7', 10), 1), 90);
    const todayStart = Math.floor((Date.now() + TZ) / 86400000) * 86400000 - TZ;
    const from = todayStart - (days - 1) * 86400000;
    const { results } = await db
      .prepare(
        `SELECT CAST((created_at + ${TZ}) / 86400000 AS INTEGER) AS day, COUNT(*) AS n, SUM(total_cents) AS total
           FROM sales WHERE deleted = 0 AND created_at >= ?1 GROUP BY day`
      )
      .bind(from)
      .all();
    const map = Object.fromEntries(results.map((r) => [r.day, r]));
    const out = [];
    for (let i = 0; i < days; i++) {
      const start = from + i * 86400000;
      const day = Math.floor((start + TZ) / 86400000);
      const r = map[day];
      out.push({ start, count: r ? r.n : 0, total_cents: r ? r.total : 0 });
    }
    return json({ days: out });
  }

  // 某段时间的流水
  if (url.pathname === '/admin/sales' && request.method === 'GET') {
    const from = parseInt(url.searchParams.get('from') || '0', 10);
    const to = parseInt(url.searchParams.get('to') || String(Date.now() + 86400000), 10);
    const { results } = await db
      .prepare(
        `SELECT id, total_cents, original_total_cents, items, device, created_at, note, edited_at
           FROM sales WHERE deleted = 0 AND created_at >= ?1 AND created_at < ?2 ORDER BY created_at DESC LIMIT 500`
      )
      .bind(from, to)
      .all();
    return json({ sales: results.map((r) => ({ ...r, items: JSON.parse(r.items || '[]') })) });
  }

  // 手动记一笔
  if (url.pathname === '/admin/sales' && request.method === 'POST') {
    const { total_cents, note = '', created_at } = await request.json();
    if (!Number.isInteger(total_cents)) return json({ error: 'bad total' }, 400);
    const id = crypto.randomUUID();
    await db
      .prepare(
        `INSERT INTO sales (id, total_cents, items, device, created_at, note) VALUES (?1, ?2, '[]', 'admin', ?3, ?4)`
      )
      .bind(id, total_cents, created_at || Date.now(), note || '手动记账')
      .run();
    return json({ ok: true, id });
  }

  const sm = url.pathname.match(/^\/admin\/sales\/([^/]+)$/);
  if (sm) {
    const id = decodeURIComponent(sm[1]);
    const sale = await db.prepare(`SELECT * FROM sales WHERE id = ?1 AND deleted = 0`).bind(id).first();
    if (!sale) return json({ error: 'not found' }, 404);
    const now = Date.now();
    if (request.method === 'PUT') {
      const { total_cents, note } = await request.json();
      if (!Number.isInteger(total_cents)) return json({ error: 'bad total' }, 400);
      await db
        .prepare(
          `UPDATE sales SET total_cents = ?2, original_total_cents = COALESCE(original_total_cents, total_cents),
             note = ?3, edited_at = ?4 WHERE id = ?1`
        )
        .bind(id, total_cents, note ?? sale.note ?? null, now)
        .run();
      return json({ ok: true });
    }
    if (request.method === 'DELETE') {
      const stmts = [db.prepare(`UPDATE sales SET deleted = 1, edited_at = ?2 WHERE id = ?1`).bind(id, now)];
      if (url.searchParams.get('restock') === '1') {
        const items = JSON.parse(sale.items || '[]');
        items.forEach((it, i) => {
          if (!it.barcode || !it.qty) return;
          stmts.push(
            db
              .prepare(
                `INSERT OR IGNORE INTO movements (id, barcode, delta, type, device, created_at) VALUES (?1, ?2, ?3, 'refund', 'admin', ?4)`
              )
              .bind(`refund-${id}-${i}`, it.barcode, it.qty | 0, now)
          );
          stmts.push(
            db
              .prepare(
                `UPDATE products SET stock = (SELECT COALESCE(SUM(delta), 0) FROM movements WHERE barcode = ?1), updated_at = ?2 WHERE barcode = ?1`
              )
              .bind(it.barcode, now)
          );
        });
      }
      await db.batch(stmts);
      return json({ ok: true });
    }
  }
  return json({ error: 'not found' }, 404);
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

    if (url.pathname.startsWith('/admin/')) return admin(request, env, url);

    if (url.pathname === '/sync' && request.method === 'POST') {
      return sync(await request.json(), env.DB);
    }

    const lk = url.pathname.match(/^\/lookup\/([^/]+)$/);
    if (lk && request.method === 'GET') {
      return json(await lookup(decodeURIComponent(lk[1]).trim(), env));
    }
    // 商品图片代理（Open Food Facts 图片国内直连慢）
    if (url.pathname === '/proxy-image' && request.method === 'GET') {
      const src = url.searchParams.get('url') || '';
      if (!/^https:\/\/images\.openfoodfacts\.org\//.test(src)) return json({ error: 'bad url' }, 400);
      const r = await fetch(src, { cf: { cacheTtl: 86400, cacheEverything: true } });
      return new Response(r.body, { status: r.status, headers: { 'content-type': r.headers.get('content-type') || 'image/jpeg' } });
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

// 毫秒时间戳不能用 |0（会截成 32 位）
function toMs(v, fallback) {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) && n > 1e12 ? n : fallback;
}

async function sync(body, db) {
  const { device = '', since = 0, products = [], movements = [], sales = [] } = body || {};
  const now = Date.now();
  const stmts = [];

  // 1. 商品资料（名称/价格）：最后同步的为准，不碰库存（库存只由流水决定）
  for (const p of products) {
    if (!p.barcode || !p.name) continue;
    stmts.push(
      db.prepare(
        `INSERT INTO products (barcode, name, price_cents, stock, updated_at, deleted)
         VALUES (?1, ?2, ?3, 0, ?4, ?5)
         ON CONFLICT(barcode) DO UPDATE SET
           name = excluded.name, price_cents = excluded.price_cents, deleted = excluded.deleted, updated_at = ?4`
      ).bind(p.barcode, p.name, p.price_cents | 0, now, p.deleted ? 1 : 0)
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
      ).bind(m.id, m.barcode, m.delta | 0, m.type || 'adjust', device, toMs(m.created_at, now))
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
      ).bind(s.id, s.total_cents | 0, JSON.stringify(s.items || []), device, toMs(s.created_at, now))
    );
  }

  if (stmts.length) await db.batch(stmts);

  const { results } = await db
    .prepare(`SELECT barcode, name, price_cents, stock, updated_at, image_ver, deleted FROM products WHERE updated_at > ?1`)
    .bind(toMs(since, 0))
    .all();

  return json({ server_time: now, products: results });
}
