-- Cotizaciones (quotes).
--   docker compose exec db psql -U depo -d depo -f /work/db/12_quotes.sql
--
-- A quote freezes prices at the moment it is generated. A customer expects
-- the number on paper to be the number they pay - never recomputed later.

CREATE TABLE IF NOT EXISTS quote (
  quote_id     bigserial PRIMARY KEY,
  quote_number integer NOT NULL UNIQUE,
  customer     text NOT NULL,
  customer_nit text,
  customer_phone text,
  note         text,
  fx_rate      numeric(10,4) NOT NULL,        -- rate used, so BOB is reproducible
  fx_source    text,
  valid_days   integer NOT NULL DEFAULT 15,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text
);

CREATE TABLE IF NOT EXISTS quote_line (
  quote_id    bigint NOT NULL REFERENCES quote(quote_id) ON DELETE CASCADE,
  line_no     integer NOT NULL,
  item_id     bigint REFERENCES item(item_id),
  part_code   text,                            -- snapshot: item can be renamed later
  description text NOT NULL,
  side        char(1),
  qty         integer NOT NULL CHECK (qty > 0),
  price_usd   numeric(12,2) NOT NULL,          -- frozen
  price_bob   numeric(12,2) NOT NULL,          -- frozen (usd x fx_rate)
  PRIMARY KEY (quote_id, line_no)
);

-- Sequence for the quote number. Starts at 1 by default; if you want to
-- continue from the last paper quote number, do it once here:
--   SELECT setval('quote_number_seq', 643);
CREATE SEQUENCE IF NOT EXISTS quote_number_seq START WITH 1;

CREATE OR REPLACE VIEW v_quotes AS
SELECT q.quote_id, q.quote_number, q.customer, q.customer_nit,
       q.customer_phone, q.created_at::date AS fecha,
       q.valid_days, q.created_by, q.fx_rate,
       (SELECT count(*) FROM quote_line l WHERE l.quote_id = q.quote_id) AS lineas,
       (SELECT sum(l.price_bob * l.qty) FROM quote_line l
         WHERE l.quote_id = q.quote_id) AS total_bob,
       q.created_at + (q.valid_days || ' days')::interval AS valid_until
FROM quote q
ORDER BY q.quote_number DESC;
