-- Fitment, reservations, transfers and reports.
--   docker compose exec db psql -U depo -d depo -f /work/db/06_features.sql

-- Sale price must be recorded at the moment of sale. Today's price is not what
-- last March's sale was worth, and the accountant needs last March's number.
ALTER TABLE stock_movement ADD COLUMN IF NOT EXISTS unit_price numeric(12,2);


-- ============================================================ vehicle fitment
CREATE TABLE IF NOT EXISTS vehicle (
  vehicle_id smallserial PRIMARY KEY,
  make  text NOT NULL,
  model text,
  UNIQUE (make, model)
);

CREATE TABLE IF NOT EXISTS item_fitment (
  item_id    bigint NOT NULL REFERENCES item(item_id) ON DELETE CASCADE,
  vehicle_id smallint NOT NULL REFERENCES vehicle(vehicle_id),
  year_from  smallint,
  year_to    smallint,
  confidence text NOT NULL DEFAULT 'manual',   -- high | model_only | make_only | manual
  PRIMARY KEY (item_id, vehicle_id)
);

CREATE INDEX IF NOT EXISTS fitment_vehicle ON item_fitment (vehicle_id, year_from, year_to);

-- "What do we stock for a 1995 Corolla?"
CREATE OR REPLACE FUNCTION parts_for_vehicle(
  p_make text, p_model text DEFAULT NULL, p_year int DEFAULT NULL)
RETURNS TABLE (item_id bigint, sku text, description text, side char(1),
               unit_price numeric, confidence text)
LANGUAGE sql STABLE AS $$
  SELECT i.item_id, i.sku, i.description, i.side, i.unit_price, f.confidence
  FROM item_fitment f
  JOIN vehicle v USING (vehicle_id)
  JOIN item i USING (item_id)
  WHERE i.is_active
    AND norm_text(v.make) = norm_text(p_make)
    AND (p_model IS NULL OR norm_text(coalesce(v.model,'')) = norm_text(p_model))
    AND (p_year IS NULL OR f.year_from IS NULL
         OR p_year BETWEEN f.year_from AND f.year_to)
  ORDER BY f.confidence, i.description;
$$;


-- ================================================================ reservations
CREATE TABLE IF NOT EXISTS reservation (
  reservation_id bigserial PRIMARY KEY,
  item_id    bigint NOT NULL REFERENCES item(item_id),
  branch_id  smallint NOT NULL REFERENCES branch(branch_id),
  qty        integer NOT NULL CHECK (qty > 0),
  customer   text,
  note       text,
  status     text NOT NULL DEFAULT 'held'
             CHECK (status IN ('held','collected','cancelled','expired')),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '2 days',
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by text
);

CREATE INDEX IF NOT EXISTS reservation_open ON reservation (item_id, branch_id)
  WHERE status = 'held';

CREATE OR REPLACE VIEW v_reserved AS
SELECT item_id, branch_id, sum(qty)::integer AS qty
FROM reservation
WHERE status = 'held' AND expires_at > now()
GROUP BY item_id, branch_id;

-- What a clerk may actually sell: on hand minus what is being held.
CREATE OR REPLACE VIEW v_available AS
SELECT s.item_id, s.branch_id,
       s.qty AS on_hand,
       coalesce(r.qty, 0) AS reserved,
       s.qty - coalesce(r.qty, 0) AS available
FROM stock_on_hand s
LEFT JOIN v_reserved r USING (item_id, branch_id)
WHERE s.condition = 'good';


-- =================================================================== transfers
-- Stock in transit belongs to neither branch. That is the whole point: a mirror
-- in a bag on a minibus must not appear as sellable at either end.
CREATE TABLE IF NOT EXISTS transfer (
  transfer_id   bigserial PRIMARY KEY,
  item_id       bigint NOT NULL REFERENCES item(item_id),
  from_branch   smallint NOT NULL REFERENCES branch(branch_id),
  to_branch     smallint NOT NULL REFERENCES branch(branch_id),
  qty           integer NOT NULL CHECK (qty > 0),
  status        text NOT NULL DEFAULT 'in_transit'
                CHECK (status IN ('in_transit','received','cancelled')),
  sent_at       timestamptz NOT NULL DEFAULT now(),
  received_at   timestamptz,
  sent_by       text,
  received_by   text,
  note          text,
  CHECK (from_branch <> to_branch)
);

CREATE OR REPLACE FUNCTION send_transfer(
  p_item bigint, p_from smallint, p_to smallint, p_qty integer,
  p_by text, p_note text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint; v_have integer;
BEGIN
  SELECT coalesce(available, 0) INTO v_have FROM v_available
   WHERE item_id = p_item AND branch_id = p_from;
  IF coalesce(v_have, 0) < p_qty THEN
    RAISE EXCEPTION 'Solo hay % disponibles en la sucursal de origen', coalesce(v_have, 0);
  END IF;

  INSERT INTO transfer (item_id, from_branch, to_branch, qty, sent_by, note)
  VALUES (p_item, p_from, p_to, p_qty, p_by, p_note) RETURNING transfer_id INTO v_id;

  INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason, note, created_by)
  VALUES (p_item, p_from, -p_qty, 'transfer_out',
          format('traspaso #%s', v_id), p_by);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION receive_transfer(p_transfer bigint, p_by text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE t transfer;
BEGIN
  SELECT * INTO t FROM transfer
   WHERE transfer_id = p_transfer AND status = 'in_transit' FOR UPDATE;
  IF t IS NULL THEN
    RAISE EXCEPTION 'El traspaso % no está en tránsito', p_transfer;
  END IF;

  INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason, note, created_by)
  VALUES (t.item_id, t.to_branch, t.qty, 'transfer_in',
          format('traspaso #%s', t.transfer_id), p_by);

  UPDATE transfer SET status = 'received', received_at = now(), received_by = p_by
   WHERE transfer_id = p_transfer;
END $$;


-- ===================================================================== reports
-- One row per sale line. Everything else is built from this.
CREATE OR REPLACE VIEW v_sales_lines AS
SELECT m.occurred_at::date        AS fecha,
       b.name                     AS sucursal,
       i.sku,
       i.part_code                AS codigo,
       i.description              AS producto,
       i.side                     AS lado,
       -m.qty_delta               AS cantidad,
       coalesce(m.unit_price, i.unit_price) AS precio_unitario,
       (-m.qty_delta) * coalesce(m.unit_price, i.unit_price) AS total,
       m.created_by               AS vendedor,
       m.note                     AS nota
FROM stock_movement m
JOIN item i   USING (item_id)
JOIN branch b USING (branch_id)
WHERE m.reason = 'sale' AND m.qty_delta < 0;

CREATE OR REPLACE VIEW v_sales_daily AS
SELECT fecha, sucursal,
       count(*)        AS lineas,
       sum(cantidad)   AS unidades,
       sum(total)      AS total
FROM v_sales_lines GROUP BY fecha, sucursal ORDER BY fecha DESC, sucursal;

CREATE OR REPLACE VIEW v_sales_monthly AS
SELECT to_char(fecha, 'YYYY-MM') AS mes, sucursal,
       count(*) AS lineas, sum(cantidad) AS unidades, sum(total) AS total
FROM v_sales_lines GROUP BY 1, 2 ORDER BY 1 DESC, 2;

CREATE OR REPLACE VIEW v_sales_yearly AS
SELECT to_char(fecha, 'YYYY') AS anio, sucursal,
       count(*) AS lineas, sum(cantidad) AS unidades, sum(total) AS total
FROM v_sales_lines GROUP BY 1, 2 ORDER BY 1 DESC, 2;

-- Cash sitting on a shelf: in stock, but not sold in a year.
CREATE OR REPLACE VIEW v_dead_stock AS
SELECT i.sku, i.part_code, i.description, b.name AS sucursal, s.qty,
       i.unit_price, s.qty * i.unit_price AS capital_inmovilizado,
       (SELECT max(m.occurred_at)::date FROM stock_movement m
         WHERE m.item_id = i.item_id AND m.reason = 'sale') AS ultima_venta
FROM stock_on_hand s
JOIN item i   USING (item_id)
JOIN branch b USING (branch_id)
WHERE s.qty > 0 AND s.condition = 'good' AND b.is_real
  AND NOT EXISTS (
    SELECT 1 FROM stock_movement m
    WHERE m.item_id = i.item_id AND m.reason = 'sale'
      AND m.occurred_at > now() - interval '12 months')
ORDER BY capital_inmovilizado DESC NULLS LAST;

-- Selling faster than the shelf can stand: 90-day rate vs what is left.
CREATE OR REPLACE VIEW v_reorder AS
SELECT i.sku, i.part_code, i.description, b.name AS sucursal,
       coalesce(a.available, 0) AS disponible,
       sum(-m.qty_delta)        AS vendidos_90d,
       round(sum(-m.qty_delta) / 3.0, 1) AS venta_mensual,
       round(coalesce(a.available, 0) / nullif(sum(-m.qty_delta) / 3.0, 0), 1)
         AS meses_de_stock
FROM stock_movement m
JOIN item i   USING (item_id)
JOIN branch b USING (branch_id)
LEFT JOIN v_available a ON a.item_id = i.item_id AND a.branch_id = b.branch_id
WHERE m.reason = 'sale' AND m.occurred_at > now() - interval '90 days'
GROUP BY i.sku, i.part_code, i.description, b.name, a.available
HAVING coalesce(a.available, 0) / nullif(sum(-m.qty_delta) / 3.0, 0) < 2
ORDER BY meses_de_stock;
