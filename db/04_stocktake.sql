-- Physical counts per branch. Run after 01_schema.sql.
-- A count never overwrites a quantity - it produces adjustment movements,
-- so you keep the history of what was expected vs what was actually there.

CREATE TYPE stocktake_status AS ENUM ('open', 'closed', 'cancelled');

CREATE TABLE stocktake (
  stocktake_id bigserial PRIMARY KEY,
  branch_id    smallint NOT NULL REFERENCES branch(branch_id),
  label        text NOT NULL,                 -- 'Conteo 2024 - Teleférico Rojo'
  status       stocktake_status NOT NULL DEFAULT 'open',
  started_at   timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz,
  created_by   text
);

-- Only one count open per branch at a time, or two people will double-count.
CREATE UNIQUE INDEX stocktake_one_open_per_branch
  ON stocktake (branch_id) WHERE status = 'open';

CREATE TABLE stocktake_line (
  stocktake_id bigint NOT NULL REFERENCES stocktake(stocktake_id) ON DELETE CASCADE,
  item_id      bigint NOT NULL REFERENCES item(item_id),
  condition    item_condition NOT NULL DEFAULT 'good',
  counted_qty  integer NOT NULL CHECK (counted_qty >= 0),
  expected_qty integer,                       -- snapshot at the moment of counting
  note         text,
  counted_at   timestamptz NOT NULL DEFAULT now(),
  counted_by   text,
  PRIMARY KEY (stocktake_id, item_id, condition)
);

-- Record a count. Safe to call twice for the same item - the last count wins,
-- which is what you want when someone recounts a shelf.
CREATE OR REPLACE FUNCTION record_count(
  p_stocktake bigint, p_item bigint, p_qty integer,
  p_by text DEFAULT NULL, p_condition item_condition DEFAULT 'good'
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_branch smallint; v_expected integer;
BEGIN
  SELECT branch_id INTO v_branch FROM stocktake
   WHERE stocktake_id = p_stocktake AND status = 'open';
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'stocktake % is not open', p_stocktake;
  END IF;

  SELECT coalesce(sum(qty_delta), 0) INTO v_expected
    FROM stock_movement
   WHERE item_id = p_item AND branch_id = v_branch AND condition = p_condition;

  INSERT INTO stocktake_line (stocktake_id, item_id, condition, counted_qty,
                              expected_qty, counted_by)
  VALUES (p_stocktake, p_item, p_condition, p_qty, v_expected, p_by)
  ON CONFLICT (stocktake_id, item_id, condition) DO UPDATE
    SET counted_qty = excluded.counted_qty,
        expected_qty = excluded.expected_qty,
        counted_at = now(),
        counted_by = excluded.counted_by;
END $$;

-- Close the count: turn every difference into an adjustment movement.
CREATE OR REPLACE FUNCTION close_stocktake(p_stocktake bigint, p_by text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_branch smallint; v_rows integer;
BEGIN
  SELECT branch_id INTO v_branch FROM stocktake
   WHERE stocktake_id = p_stocktake AND status = 'open' FOR UPDATE;
  IF v_branch IS NULL THEN
    RAISE EXCEPTION 'stocktake % is not open', p_stocktake;
  END IF;

  INSERT INTO stock_movement (item_id, branch_id, qty_delta, condition, reason,
                              note, created_by)
  SELECT l.item_id, v_branch,
         l.counted_qty - coalesce(l.expected_qty, 0),
         l.condition, 'adjustment',
         format('stocktake %s: expected %s, counted %s',
                p_stocktake, coalesce(l.expected_qty, 0), l.counted_qty),
         coalesce(p_by, l.counted_by)
    FROM stocktake_line l
   WHERE l.stocktake_id = p_stocktake
     AND l.counted_qty - coalesce(l.expected_qty, 0) <> 0;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  UPDATE stocktake SET status = 'closed', closed_at = now()
   WHERE stocktake_id = p_stocktake;
  RETURN v_rows;
END $$;

-- What the counting clerk works from: everything expected at their branch,
-- plus everything still sitting in the unassigned bucket.
CREATE OR REPLACE VIEW v_count_sheet AS
SELECT b.code AS branch, i.sku, i.part_code, i.side, i.description,
       coalesce(s.qty, 0) AS expected_qty
FROM branch b
CROSS JOIN item i
LEFT JOIN stock_on_hand s
       ON s.item_id = i.item_id AND s.branch_id = b.branch_id
      AND s.condition = 'good'
WHERE i.is_active AND b.is_real
ORDER BY b.code, i.description;
