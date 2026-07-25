-- Resolve the 7 duplicate part_codes in the catalogue.
--   docker compose exec db psql "$DATABASE_URL" -f /work/db/15_fix_duplicates.sql
-- or locally: psql "$DATABASE_URL" -f db/15_fix_duplicates.sql
--
-- Three cases:
--   MERGE - same physical part, keep one row and re-point everything to it
--   SPLIT - two different parts sharing a code, give one a suffixed code

BEGIN;

-- ============================================================== MERGE HELPER
-- Move every reference from src_sku to dst_sku, keep the winning description
-- if the caller provided one, then deactivate the losing row (never delete,
-- because that would break the audit trail).
CREATE OR REPLACE FUNCTION merge_items(dst_sku text, src_sku text,
                                       winning_desc text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  dst bigint := (SELECT item_id FROM item WHERE sku = dst_sku);
  src bigint := (SELECT item_id FROM item WHERE sku = src_sku);
BEGIN
  IF dst IS NULL OR src IS NULL THEN
    RAISE NOTICE 'skip merge: dst=% src=% not found', dst_sku, src_sku;
    RETURN;
  END IF;

  UPDATE stock_movement SET item_id = dst WHERE item_id = src;
  UPDATE quote_line     SET item_id = dst WHERE item_id = src;

  -- Fitment: move rows, tolerate duplicates (dst may already fit the vehicle)
  INSERT INTO item_fitment (item_id, vehicle_id, year_from, year_to, confidence)
  SELECT dst, vehicle_id, year_from, year_to, confidence
    FROM item_fitment WHERE item_id = src
  ON CONFLICT (item_id, vehicle_id) DO NOTHING;
  DELETE FROM item_fitment WHERE item_id = src;

  -- Aliases: move them, tolerate duplicates
  INSERT INTO item_alias (item_id, alias, source)
  SELECT dst, alias, coalesce(source, 'merge') FROM item_alias WHERE item_id = src
  ON CONFLICT (item_id, alias) DO NOTHING;
  DELETE FROM item_alias WHERE item_id = src;

  -- Save the loser's description as an alias so the search still finds it
  INSERT INTO item_alias (item_id, alias, source)
    SELECT dst, description, 'merged_from_' || src_sku FROM item WHERE item_id = src
    ON CONFLICT (item_id, alias) DO NOTHING;

  IF winning_desc IS NOT NULL THEN
    UPDATE item SET description = winning_desc WHERE item_id = dst;
  END IF;

  -- Deactivate and rename the loser so the code is freed up
  UPDATE item SET is_active = false,
                  part_code = 'MERGED-' || part_code || '-' || src_sku,
                  base_code = NULL
   WHERE item_id = src;
END $$;


-- ============================================================== SPLIT HELPER
-- The winner keeps the code. The loser gets a suffixed code so they no
-- longer collide, and stays fully active.
CREATE OR REPLACE FUNCTION split_item(sku_to_rename text, suffix text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE item
     SET part_code = part_code || '-' || suffix,
         base_code = base_code || '-' || suffix
   WHERE sku = sku_to_rename;
END $$;


-- ============================================================================
-- 3 pairs to MERGE (same physical part)
-- ============================================================================
--   216-19AG-L: keep the longer, more informative description
SELECT merge_items('DEPO-00787', 'DEPO-00985',
  'Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020');
--   216-19AG-R: same
SELECT merge_items('DEPO-00788', 'DEPO-00986',
  'Stop MAZDA BT-50 Mod.2015~2016~2017~2018~2019~2020');
--   DS-2007: keep the correctly-spaced description
SELECT merge_items('DEPO-00028', 'DEPO-01050',
  'Amortiguador DELANTERO HILUX 90');


-- ============================================================================
-- 4 pairs to SPLIT (two different parts sharing one code)
-- ============================================================================
--   20-260-R: DEPO-00335 has the real description ("Farol Toyota Corona 212-1138");
--             DEPO-00974 is the empty one - give it a suffix
SELECT split_item('DEPO-00974', 'NOCODE');

--   214-1112-L: MITSUBISHI COLT vs Mitsubishi Lancer. Keep the first, suffix the other.
SELECT split_item('DEPO-01103', 'LANCER');

--   VI-S-DOM-89-F-L: FIBRA vs JAPONÉS. Distinguish them explicitly.
SELECT split_item('DEPO-00953', 'JPN');   -- keep 951 (FIBRA) with original code
--   VI-S-DOM-89-F-R
SELECT split_item('DEPO-00954', 'JPN');   -- keep 952 (FIBRA) with original code


COMMIT;


-- ---------------------------------------------------------------- verification
SELECT part_code, count(*) FROM item
WHERE part_code IS NOT NULL AND NOT part_code LIKE 'MERGED-%'
GROUP BY part_code HAVING count(*) > 1;
-- should return 0 rows

-- Now safe to enforce uniqueness so this can never happen again
CREATE UNIQUE INDEX IF NOT EXISTS item_part_code_uk ON item (part_code)
  WHERE part_code IS NOT NULL AND NOT part_code LIKE 'MERGED-%' AND is_active;
