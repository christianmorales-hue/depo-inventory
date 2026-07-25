-- Photos, and a pair-warning view the interface can join on.
--   docker compose exec db psql -U depo -d depo -f /work/db/09_extras.sql

ALTER TABLE item ADD COLUMN IF NOT EXISTS photo_path text;

-- Rebuilt with item_id and branch_id so the search screen can flag rows
-- directly instead of matching on text.
DROP VIEW IF EXISTS v_broken_pairs;
CREATE VIEW v_broken_pairs AS
SELECT i.item_id, i.sku, b.branch_id, b.name AS branch,
       i.base_code, i.description, i.side, s.qty
FROM stock_on_hand s
JOIN item i   ON i.item_id = s.item_id
JOIN branch b ON b.branch_id = s.branch_id
WHERE i.side IS NOT NULL AND s.condition = 'good' AND s.qty > 0
  AND b.is_real AND b.is_active
  AND NOT EXISTS (
    SELECT 1 FROM stock_on_hand s2
    JOIN item i2 ON i2.item_id = s2.item_id
    WHERE i2.base_code = i.base_code
      AND i2.side = CASE i.side WHEN 'L' THEN 'R' ELSE 'L' END
      AND s2.branch_id = s.branch_id AND s2.qty > 0
  );
