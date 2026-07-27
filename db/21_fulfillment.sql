-- Fulfillment details for notas de venta + warehouse request queue.
--   psql "$DATABASE_URL" -f db/21_fulfillment.sql

-- How the customer receives the order. Attached to a nota (quote row).
CREATE TABLE IF NOT EXISTS nota_fulfillment (
  quote_id      bigint PRIMARY KEY REFERENCES quote(quote_id) ON DELETE CASCADE,
  method        text NOT NULL,              -- 'recojo' | 'entrega' | 'envio'
  -- recojo:
  branch_id     bigint REFERENCES branch(branch_id),
  -- entrega (delivery to address):
  recipient     text,
  city          text,
  address       text,
  dropoff_date  date,
  -- envio (bus/plane):
  transport     text,                       -- 'bus' | 'avion'
  company       text,                       -- shipping company name
  payment       text,                       -- 'pagado' | 'por_pagar'
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Warehouse request: created when a nota is generated, so the store/warehouse
-- can prepare and confirm the goods before (or as) they leave. Modeled on the
-- transfers flow: the request sits pending until a warehouse user confirms.
CREATE TABLE IF NOT EXISTS bodega_request (
  bodega_id     bigserial PRIMARY KEY,
  quote_id      bigint REFERENCES quote(quote_id) ON DELETE CASCADE,
  numero        integer NOT NULL UNIQUE,
  status        text NOT NULL DEFAULT 'pendiente',  -- pendiente | confirmado | rechazado
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text,
  resolved_at   timestamptz,
  resolved_by   text
);

CREATE SEQUENCE IF NOT EXISTS bodega_numero_seq START WITH 1;

CREATE INDEX IF NOT EXISTS bodega_status_idx ON bodega_request (status, created_at DESC);
