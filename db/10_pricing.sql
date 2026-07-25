-- USD pricing, exchange-rate cache, structured item attributes, settings.
--   docker compose exec db psql -U depo -d depo -f /work/db/10_pricing.sql

-- Prices are entered and stored in USD. Bolivianos are computed for display
-- using the rate below, so a rate change never rewrites stored data.
ALTER TABLE item ADD COLUMN IF NOT EXISTS price_usd numeric(12,2);

-- One-time migration: if unit_price already held bolivianos, seed a USD value
-- using a starting rate so nothing looks empty. Adjust 6.96 if needed, then
-- correct individual prices in the app.
UPDATE item SET price_usd = round(unit_price / 6.96, 2)
 WHERE price_usd IS NULL AND unit_price IS NOT NULL;

-- Structured attributes. All optional - a part need not belong to a vehicle.
ALTER TABLE item ADD COLUMN IF NOT EXISTS product_type text;  -- espejo, farol...
ALTER TABLE item ADD COLUMN IF NOT EXISTS make text;
ALTER TABLE item ADD COLUMN IF NOT EXISTS model text;
ALTER TABLE item ADD COLUMN IF NOT EXISTS year_text text;     -- "92~95", free form
ALTER TABLE item ADD COLUMN IF NOT EXISTS nickname text;      -- "CHANCHO"

-- Exchange rates, cached so the external API is not hit on every page load.
CREATE TABLE IF NOT EXISTS fx_rate (
  source      text PRIMARY KEY,               -- 'oficial' | 'blue'
  compra      numeric(10,4),
  venta       numeric(10,4),
  casa        text,
  fetched_at  timestamptz NOT NULL DEFAULT now(),
  api_updated text
);

-- Small key/value store for店-wide settings.
CREATE TABLE IF NOT EXISTS app_setting (
  key   text PRIMARY KEY,
  value text
);

INSERT INTO app_setting (key, value) VALUES
  ('fx_source', 'oficial'),                   -- which rate drives boliviano prices
  ('store_name', 'DEPO autolamp'),
  ('store_phone', '')
ON CONFLICT (key) DO NOTHING;

-- Sale price is recorded in both currencies at the moment of sale, so an old
-- report never moves when today's rate or price changes.
ALTER TABLE stock_movement ADD COLUMN IF NOT EXISTS price_usd numeric(12,2);
ALTER TABLE stock_movement ADD COLUMN IF NOT EXISTS fx_rate numeric(10,4);
