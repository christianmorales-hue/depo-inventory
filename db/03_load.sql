-- Load the cleaned CSVs into PostgreSQL.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01_schema.sql
--   cd out && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../03_load.sql
-- Run from the directory containing categories.csv, items.csv, etc.

BEGIN;

CREATE TEMP TABLE stg_category (name text);
CREATE TEMP TABLE stg_item (
  sku text, part_code text, base_code text, side text, category text,
  description text, unit_price numeric, legacy_row_id text, needs_review boolean
);
CREATE TEMP TABLE stg_alias (sku text, alias text, source text);
CREATE TEMP TABLE stg_stock (
  sku text, branch_code text, qty integer, condition text, note text
);

\copy stg_category FROM 'categories.csv'    WITH (FORMAT csv, HEADER true)
\copy stg_item     FROM 'items.csv'         WITH (FORMAT csv, HEADER true)
\copy stg_alias    FROM 'item_aliases.csv'  WITH (FORMAT csv, HEADER true)
\copy stg_stock    FROM 'opening_stock.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO category (name)
SELECT name FROM stg_category
ON CONFLICT (name) DO NOTHING;

INSERT INTO item (sku, part_code, base_code, side, category_id, description,
                  unit_price, legacy_row_id, needs_review)
SELECT s.sku,
       nullif(s.part_code, ''),
       nullif(s.base_code, ''),
       nullif(s.side, '')::char(1),
       c.category_id,
       s.description,
       s.unit_price,
       nullif(s.legacy_row_id, '')::integer,
       s.needs_review
FROM stg_item s
LEFT JOIN category c ON c.name = s.category;

INSERT INTO item_alias (item_id, alias, source)
SELECT i.item_id, a.alias, a.source
FROM stg_alias a
JOIN item i ON i.sku = a.sku
ON CONFLICT (item_id, alias) DO NOTHING;

-- Opening balances become the first movements in the ledger, dated to the
-- January 2023 count so the history is honest about where the numbers came from.
INSERT INTO stock_movement (item_id, branch_id, qty_delta, condition, reason,
                            note, occurred_at, created_by)
SELECT i.item_id,
       b.branch_id,
       s.qty,
       s.condition::item_condition,
       'opening',
       s.note,
       timestamptz '2023-01-31 00:00:00-04',
       'migration'
FROM stg_stock s
JOIN item   i ON i.sku = s.sku
JOIN branch b ON b.code = s.branch_code;

COMMIT;

-- Sanity checks
SELECT 'items'      AS what, count(*) FROM item
UNION ALL SELECT 'aliases',    count(*) FROM item_alias
UNION ALL SELECT 'movements',  count(*) FROM stock_movement
UNION ALL SELECT 'need review', count(*) FROM item WHERE needs_review;

SELECT b.name, s.condition, sum(s.qty) AS units
FROM stock_on_hand s JOIN branch b USING (branch_id)
GROUP BY 1, 2 ORDER BY 1, 2;

-- Codes that still collide - resolve these, then enable the unique index.
SELECT part_code, array_agg(sku) FROM item
WHERE part_code IS NOT NULL
GROUP BY part_code HAVING count(*) > 1;
