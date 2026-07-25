-- Load fitment.csv produced by etl/03_fitment.py.
-- Run from the folder containing fitment.csv:
--   docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/07_load_fitment.sql

BEGIN;

CREATE TEMP TABLE stg_fit (
  sku text, make text, model text, year_from text, year_to text,
  confidence text, matched_text text
);

\copy stg_fit FROM 'fitment.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO vehicle (make, model)
SELECT DISTINCT make, nullif(model, '') FROM stg_fit
ON CONFLICT (make, model) DO NOTHING;

INSERT INTO item_fitment (item_id, vehicle_id, year_from, year_to, confidence)
SELECT i.item_id, v.vehicle_id,
       nullif(f.year_from, '')::smallint,
       nullif(f.year_to, '')::smallint,
       f.confidence
FROM stg_fit f
JOIN item i ON i.sku = f.sku
JOIN vehicle v ON v.make = f.make AND v.model IS NOT DISTINCT FROM nullif(f.model, '')
ON CONFLICT (item_id, vehicle_id) DO NOTHING;

COMMIT;

SELECT confidence, count(*) FROM item_fitment GROUP BY 1 ORDER BY 2 DESC;

-- Try it:
SELECT * FROM parts_for_vehicle('Toyota', 'COROLLA', 1995);
