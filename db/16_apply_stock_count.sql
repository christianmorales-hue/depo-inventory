-- Apply a physical stock count to a branch.
--
--   cd data/out
--   cp stock_count_movements.csv movements.csv
--   cp stock_count_new_items.csv new_items.csv
--   psql "$DATABASE_URL" -f ../../db/16_apply_stock_count.sql
--
-- Everything runs in one transaction. If any step fails, nothing changes.

BEGIN;

-- Force the branch code here so the file self-documents. Change if you're
-- running a count for a different branch.
CREATE TEMP TABLE _params AS SELECT
  'TELEFERICO'::text  AS branch_code,
  '2026-03-26'::date  AS count_date;

CREATE TEMP TABLE stg_count (
  code_norm    text,
  counted_qty  integer
);
CREATE TEMP TABLE stg_new (
  code_norm         text,
  part_code_original text,
  description       text,
  qty               integer
);

\copy stg_count FROM 'movements.csv'  WITH (FORMAT csv, HEADER true)
\copy stg_new   FROM 'new_items.csv'  WITH (FORMAT csv, HEADER true)


-- Match counted rows to existing items via normalised part_code.
-- Same normalisation the app uses everywhere else.
CREATE TEMP TABLE matched AS
SELECT
  s.code_norm,
  s.counted_qty,
  i.item_id,
  i.description,
  (SELECT coalesce(sum(qty_delta), 0)::integer
     FROM stock_movement m
     JOIN branch b ON b.branch_id = m.branch_id
    WHERE m.item_id = i.item_id
      AND b.code = (SELECT branch_code FROM _params)
      AND m.condition = 'good') AS current_qty
FROM stg_count s
JOIN item i ON regexp_replace(upper(f_unaccent(coalesce(i.part_code, ''))),
                              '[^A-Z0-9]+', '', 'g') = s.code_norm
WHERE i.is_active;


-- Report
SELECT (SELECT count(*) FROM stg_count) AS incoming,
       (SELECT count(*) FROM matched)   AS matched,
       (SELECT count(*) FROM stg_count) - (SELECT count(*) FROM matched)
                                        AS unmatched;


-- Insert adjustment movements: delta = counted - current
-- We only insert when there IS a delta - no need to write a movement that
-- says "the number is the same as before".
INSERT INTO stock_movement (item_id, branch_id, qty_delta, condition,
                            reason, note, occurred_at, created_by)
SELECT m.item_id,
       b.branch_id,
       m.counted_qty - m.current_qty,
       'good',
       'adjustment',
       'conteo físico ' || (SELECT count_date FROM _params)::text,
       (SELECT count_date FROM _params)::timestamptz,
       'import'
FROM matched m
JOIN branch b ON b.code = (SELECT branch_code FROM _params)
WHERE m.counted_qty <> m.current_qty;


-- Create new items for unmatched codes (only rows with a real code and a qty).
INSERT INTO item (sku, part_code, base_code, description, is_active)
SELECT 'DEPO-' || lpad(nextval('item_item_id_seq')::text, 5, '0'),
       s.part_code_original,
       s.part_code_original,
       coalesce(nullif(s.description, ''), '(pendiente)'),
       true
FROM stg_new s
WHERE s.code_norm IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM item i WHERE regexp_replace(
      upper(f_unaccent(coalesce(i.part_code, ''))),
      '[^A-Z0-9]+', '', 'g') = s.code_norm
  );


-- Give those new items their opening stock at the branch.
INSERT INTO stock_movement (item_id, branch_id, qty_delta, condition,
                            reason, note, occurred_at, created_by)
SELECT i.item_id, b.branch_id, s.qty, 'good', 'adjustment',
       'conteo físico ' || (SELECT count_date FROM _params)::text
         || ' (item nuevo)',
       (SELECT count_date FROM _params)::timestamptz,
       'import'
FROM stg_new s
JOIN item   i ON i.part_code = s.part_code_original
JOIN branch b ON b.code = (SELECT branch_code FROM _params)
WHERE s.qty > 0
  AND i.created_at > now() - interval '1 minute';


-- Alias the description of every new item, so the search picks it up.
INSERT INTO item_alias (item_id, alias, source)
SELECT i.item_id, s.description, 'stock_count'
FROM stg_new s
JOIN item i ON i.part_code = s.part_code_original
WHERE s.description IS NOT NULL AND s.description <> ''
  AND i.created_at > now() - interval '1 minute'
ON CONFLICT (item_id, alias) DO NOTHING;


COMMIT;


-- ---------------------------------------------------------------- summary
SELECT b.name,
       count(*)                          AS filas_ajustadas,
       sum(qty_delta) FILTER (WHERE qty_delta > 0) AS unidades_agregadas,
       sum(qty_delta) FILTER (WHERE qty_delta < 0) AS unidades_restadas
FROM stock_movement m
JOIN branch b USING (branch_id)
WHERE m.reason = 'adjustment'
  AND m.note LIKE 'conteo físico%'
  AND b.code = 'TELEFERICO'
GROUP BY b.name;
