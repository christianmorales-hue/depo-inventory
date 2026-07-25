-- New features: devoluciones, recepción de mercadería, caja diaria.
--   psql "$DATABASE_URL" -f db/18_operations.sql
--
-- All three write to the existing stock_movement ledger where relevant, so
-- reports keep working without changes.

-- ========================================================== DEVOLUCIONES
-- A return references the original nota de venta. Each returned line puts
-- stock back and records why. Money handling is left to the caja - a return
-- note simply documents the physical + inventory reversal.
CREATE TABLE IF NOT EXISTS devolucion (
  devolucion_id  bigserial PRIMARY KEY,
  numero         integer NOT NULL UNIQUE,
  quote_id       bigint REFERENCES quote(quote_id),   -- the original nota
  customer       text,
  reason         text,
  refund_bob     numeric(12,2),                        -- what was given back
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text
);

CREATE TABLE IF NOT EXISTS devolucion_line (
  devolucion_id  bigint NOT NULL REFERENCES devolucion(devolucion_id) ON DELETE CASCADE,
  line_no        integer NOT NULL,
  item_id        bigint REFERENCES item(item_id),
  branch_id      bigint REFERENCES branch(branch_id),
  qty            integer NOT NULL CHECK (qty > 0),
  condition      text NOT NULL DEFAULT 'good',         -- good = resellable, defect = not
  price_bob      numeric(12,2),
  PRIMARY KEY (devolucion_id, line_no)
);

CREATE SEQUENCE IF NOT EXISTS devolucion_numero_seq START WITH 1;

-- ========================================================== RECEPCIÓN
-- Incoming merchandise. Raises stock and records cost, so average cost and
-- "what we owe this supplier" become answerable later.
CREATE TABLE IF NOT EXISTS recepcion (
  recepcion_id  bigserial PRIMARY KEY,
  numero        integer NOT NULL UNIQUE,
  supplier      text,
  invoice_ref   text,                                   -- supplier's factura no.
  branch_id     bigint REFERENCES branch(branch_id),
  note          text,
  total_usd     numeric(12,2),
  fx_rate       numeric(10,4),
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text
);

CREATE TABLE IF NOT EXISTS recepcion_line (
  recepcion_id  bigint NOT NULL REFERENCES recepcion(recepcion_id) ON DELETE CASCADE,
  line_no       integer NOT NULL,
  item_id       bigint REFERENCES item(item_id),
  qty           integer NOT NULL CHECK (qty > 0),
  cost_usd      numeric(12,2),
  PRIMARY KEY (recepcion_id, line_no)
);

CREATE SEQUENCE IF NOT EXISTS recepcion_numero_seq START WITH 1;

-- Optional cost tracking on the item itself: last cost paid, for margin.
ALTER TABLE item ADD COLUMN IF NOT EXISTS cost_usd numeric(12,2);

-- ========================================================== CAJA DIARIA
-- One row per branch per day. Staff enter counted cash; the system knows the
-- day's sales; the difference is the discrepancy.
CREATE TABLE IF NOT EXISTS caja (
  caja_id      bigserial PRIMARY KEY,
  branch_id    bigint NOT NULL REFERENCES branch(branch_id),
  fecha        date NOT NULL,
  opening_bob  numeric(12,2) NOT NULL DEFAULT 0,   -- cash at start of day
  counted_bob  numeric(12,2),                       -- cash counted at close
  note         text,
  closed_at    timestamptz,
  created_by   text,
  UNIQUE (branch_id, fecha)
);

-- What the system expected in the drawer: opening + today's cash sales.
-- (All sales are treated as cash for now; refine later if you add card/credit.)
CREATE OR REPLACE VIEW v_caja_expected AS
SELECT c.caja_id, c.branch_id, b.name AS sucursal, c.fecha,
       c.opening_bob, c.counted_bob, c.note, c.closed_at,
       coalesce((
         SELECT sum(-m.qty_delta * coalesce(m.unit_price, m.price_usd * m.fx_rate, 0))
         FROM stock_movement m
         WHERE m.branch_id = c.branch_id
           AND m.reason = 'sale'
           AND m.occurred_at::date = c.fecha
       ), 0) AS ventas_bob,
       c.opening_bob + coalesce((
         SELECT sum(-m.qty_delta * coalesce(m.unit_price, m.price_usd * m.fx_rate, 0))
         FROM stock_movement m
         WHERE m.branch_id = c.branch_id
           AND m.reason = 'sale'
           AND m.occurred_at::date = c.fecha
       ), 0) AS esperado_bob,
       CASE WHEN c.counted_bob IS NULL THEN NULL
            ELSE c.counted_bob - (c.opening_bob + coalesce((
              SELECT sum(-m.qty_delta * coalesce(m.unit_price, m.price_usd * m.fx_rate, 0))
              FROM stock_movement m
              WHERE m.branch_id = c.branch_id
                AND m.reason = 'sale'
                AND m.occurred_at::date = c.fecha), 0))
       END AS diferencia_bob
FROM caja c
JOIN branch b USING (branch_id);
