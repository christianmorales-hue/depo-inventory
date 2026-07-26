-- Per-line discount and nota-de-venta cancellation support.
--   psql "$DATABASE_URL" -f db/20_discount_cancel.sql

-- Discount in Bs applied per unit on a sale line. Defaults to 0.
ALTER TABLE quote_line ADD COLUMN IF NOT EXISTS discount_bob numeric(12,2) NOT NULL DEFAULT 0;

-- When a nota de venta is cancelled, we stamp it here. The reversing stock
-- movements are what actually restore inventory; this flag stops double
-- cancellation and lets the UI show status.
ALTER TABLE quote ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;
ALTER TABLE quote ADD COLUMN IF NOT EXISTS cancelled_by text;
