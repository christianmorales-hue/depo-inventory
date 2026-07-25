-- Load a new supplier catalog into the item table.
-- Duplicates (by part_code) are skipped, not overwritten.
--
-- Usage:  from data/out folder, once per file:
--   psql "$DATABASE_URL" -v csvfile='new_items_LISTA_EN_STOCK_04-03-2026.csv' \
--                       -f ../../db/13_import_catalog.sql
--
-- No stock movements are created. Every branch starts at zero for these
-- items until a physical count adds them.

BEGIN;

CREATE TEMP TABLE stg_new (
  part_code    text,
  base_code    text,
  side         text,
  description  text,
  price_usd    numeric,
  product_type text,
  make         text,
  supplier     text,
  origin       text,
  part_number  text
);

\copy stg_new FROM :'csvfile' WITH (FORMAT csv, HEADER true)

-- Categories: create any missing ones so items can point to them.
INSERT INTO category (name)
SELECT DISTINCT product_type FROM stg_new
WHERE product_type IS NOT NULL AND product_type <> ''
ON CONFLICT (name) DO NOTHING;

-- Skip anything whose part_code already exists. Case-insensitive match on the
-- normalised code catches near-duplicates like '870163-G' vs '870163 G'.
CREATE TEMP TABLE stg_new_fresh AS
SELECT s.* FROM stg_new s
WHERE NOT EXISTS (
  SELECT 1 FROM item i
  WHERE norm_text(i.part_code) = norm_text(s.part_code)
);

-- Report what we're skipping
SELECT count(*)      AS incoming,
       (SELECT count(*) FROM stg_new_fresh) AS to_insert,
       (SELECT count(*) FROM stg_new)
         - (SELECT count(*) FROM stg_new_fresh) AS already_exist
FROM stg_new;

-- Insert only the fresh ones.
INSERT INTO item (sku, part_code, base_code, side, description, price_usd,
                  category_id, product_type)
SELECT
  'DEPO-' || lpad(nextval('item_item_id_seq')::text, 5, '0'),
  s.part_code,
  nullif(s.base_code, ''),
  nullif(s.side, '')::char(1),
  s.description,
  s.price_usd,
  c.category_id,
  nullif(s.product_type, '')
FROM stg_new_fresh s
LEFT JOIN category c ON c.name = s.product_type;

-- Seed aliases: description, part_code, and part_number if given.
INSERT INTO item_alias (item_id, alias, source)
SELECT i.item_id, alias_value, 'import'
FROM item i
JOIN stg_new_fresh s ON s.part_code = i.part_code
CROSS JOIN LATERAL (VALUES (s.description), (s.part_code),
                           (nullif(s.part_number, ''))) AS a(alias_value)
WHERE alias_value IS NOT NULL AND alias_value <> ''
ON CONFLICT (item_id, alias) DO NOTHING;

COMMIT;

-- Summary
SELECT 'items now'   AS what, count(*) FROM item
UNION ALL
SELECT 'aliases now', count(*) FROM item_alias;
