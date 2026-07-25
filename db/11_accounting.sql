-- Accounting-style summaries built from sales movements.
--   docker compose exec db psql -U depo -d depo -f /work/db/11_accounting.sql
--
-- These use the boliviano value recorded at the moment of each sale
-- (qty x price_usd x fx_rate), so historical figures never move when the rate
-- or a price changes later.

-- Bolivia's general VAT (IVA) is 13% and is included in the marked price. So
-- from a gross sale, the net is price / 1.13 and the tax is the remainder.
CREATE OR REPLACE VIEW v_sales_accounting AS
WITH lines AS (
  SELECT m.occurred_at::date AS fecha,
         b.name AS sucursal,
         i.product_type,
         i.make,
         i.description,
         -m.qty_delta AS cantidad,
         (-m.qty_delta) * coalesce(m.price_usd * m.fx_rate,
                                   m.unit_price, i.unit_price) AS bruto
  FROM stock_movement m
  JOIN item i USING (item_id)
  JOIN branch b USING (branch_id)
  WHERE m.reason = 'sale' AND m.qty_delta < 0
)
SELECT fecha, sucursal, product_type, make, description, cantidad,
       round(bruto, 2)               AS total_bruto,
       round(bruto / 1.13, 2)        AS neto_sin_iva,
       round(bruto - bruto / 1.13, 2) AS iva_13
FROM lines;

-- Daily takings per branch, split into net and tax.
CREATE OR REPLACE VIEW v_acc_daily AS
SELECT fecha, sucursal,
       count(*)                 AS lineas,
       sum(cantidad)            AS unidades,
       sum(total_bruto)         AS total_bruto,
       sum(neto_sin_iva)        AS neto_sin_iva,
       sum(iva_13)              AS iva_13
FROM v_sales_accounting
GROUP BY fecha, sucursal
ORDER BY fecha DESC, sucursal;

-- Monthly summary - the row an accountant reconciles against.
CREATE OR REPLACE VIEW v_acc_monthly AS
SELECT to_char(fecha, 'YYYY-MM') AS mes, sucursal,
       count(*)          AS lineas,
       sum(cantidad)     AS unidades,
       sum(total_bruto)  AS total_bruto,
       sum(neto_sin_iva) AS neto_sin_iva,
       sum(iva_13)       AS iva_13,
       round(avg(total_bruto), 2) AS ticket_promedio
FROM v_sales_accounting
GROUP BY 1, 2 ORDER BY 1 DESC, 2;

-- Best sellers, last 90 days, by revenue.
CREATE OR REPLACE VIEW v_top_products AS
SELECT description,
       sum(cantidad)            AS unidades,
       round(sum(total_bruto), 2) AS ingresos
FROM v_sales_accounting
WHERE fecha > current_date - 90
GROUP BY description
ORDER BY ingresos DESC NULLS LAST;

-- Revenue by product type (espejo, farol...), useful for the owner.
CREATE OR REPLACE VIEW v_by_type AS
SELECT coalesce(product_type, '(sin tipo)') AS tipo,
       sum(cantidad)              AS unidades,
       round(sum(total_bruto), 2) AS ingresos
FROM v_sales_accounting
GROUP BY 1 ORDER BY ingresos DESC NULLS LAST;


-- parts_for_vehicle returned unit_price; items now carry price_usd. Redefine it
-- to return the USD price so the API can convert it.
CREATE OR REPLACE FUNCTION parts_for_vehicle(
  p_make text, p_model text DEFAULT NULL, p_year int DEFAULT NULL)
RETURNS TABLE (item_id bigint, sku text, description text, side char(1),
               unit_price numeric, confidence text)
LANGUAGE sql STABLE AS $$
  SELECT i.item_id, i.sku, i.description, i.side, i.price_usd, f.confidence
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
