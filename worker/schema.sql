CREATE TABLE IF NOT EXISTS products (
  barcode     TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  price_cents INTEGER NOT NULL DEFAULT 0,
  stock       INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_products_updated ON products(updated_at);

-- 库存流水：sale(-) / stock_in(+) / adjust(±)
CREATE TABLE IF NOT EXISTS movements (
  id         TEXT PRIMARY KEY,
  barcode    TEXT NOT NULL,
  delta      INTEGER NOT NULL,
  type       TEXT NOT NULL,
  device     TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_movements_barcode ON movements(barcode);

CREATE TABLE IF NOT EXISTS sales (
  id          TEXT PRIMARY KEY,
  total_cents INTEGER NOT NULL,
  items       TEXT NOT NULL,
  device      TEXT,
  created_at  INTEGER NOT NULL
);
