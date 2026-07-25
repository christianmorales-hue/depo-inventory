-- Additions for the editable web app. Run after 01_schema.sql and 04_stocktake.sql.
--   docker compose exec db psql -U depo -d depo -f /work/db/05_admin.sql

-- Branches get retired, never deleted - their movements must stay valid.
ALTER TABLE branch ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- Every price change is recorded automatically, by a trigger, so it cannot be
-- forgotten by the application.
CREATE TABLE IF NOT EXISTS price_change (
  price_change_id bigserial PRIMARY KEY,
  item_id    bigint NOT NULL REFERENCES item(item_id),
  old_price  numeric(12,2),
  new_price  numeric(12,2),
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text
);

CREATE INDEX IF NOT EXISTS price_change_item ON price_change (item_id, changed_at DESC);

CREATE OR REPLACE FUNCTION log_price_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.unit_price IS DISTINCT FROM OLD.unit_price THEN
    INSERT INTO price_change (item_id, old_price, new_price, changed_by)
    VALUES (NEW.item_id, OLD.unit_price, NEW.unit_price,
            current_setting('app.actor', true));
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS item_price_audit ON item;
CREATE TRIGGER item_price_audit
  AFTER UPDATE OF unit_price ON item
  FOR EACH ROW EXECUTE FUNCTION log_price_change();

-- Convenience: who changed what, most recent first.
CREATE OR REPLACE VIEW v_price_history AS
SELECT p.changed_at, i.part_code, i.description,
       p.old_price, p.new_price, p.changed_by
FROM price_change p JOIN item i USING (item_id)
ORDER BY p.changed_at DESC;

-- Items whose left/right partner is missing from a branch. You sell lamps and
-- mirrors in sides; a lone left is often an unsellable half.
CREATE OR REPLACE VIEW v_broken_pairs AS
SELECT b.name AS branch, i.base_code, i.description, i.side, s.qty
FROM stock_on_hand s
JOIN item i   ON i.item_id = s.item_id
JOIN branch b ON b.branch_id = s.branch_id
WHERE i.side IS NOT NULL AND s.condition = 'good' AND s.qty > 0
  AND NOT EXISTS (
    SELECT 1 FROM stock_on_hand s2
    JOIN item i2 ON i2.item_id = s2.item_id
    WHERE i2.base_code = i.base_code
      AND i2.side = CASE i.side WHEN 'L' THEN 'R' ELSE 'L' END
      AND s2.branch_id = s.branch_id AND s2.qty > 0
  );
