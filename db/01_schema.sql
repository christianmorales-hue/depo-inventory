-- DEPO autolamp - inventory schema for PostgreSQL 14+
-- Run once against an empty database.

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- unaccent() is not IMMUTABLE, so it cannot be used directly in an index or a
-- generated column. This wrapper makes it usable. The SET search_path is
-- important - PostgreSQL 18 needs it so functions called during CREATE INDEX
-- can find each other reliably.
CREATE OR REPLACE FUNCTION public.f_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  SET search_path = public, pg_catalog
  AS $$ SELECT unaccent($1) $$;

-- Normalisation used everywhere for matching: uppercase, no accents,
-- single spaces, no punctuation noise.
CREATE OR REPLACE FUNCTION public.norm_text(text) RETURNS text
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  SET search_path = public, pg_catalog
  AS $$ SELECT regexp_replace(upper(public.f_unaccent($1)), '[^A-Z0-9]+', ' ', 'g') $$;


-- ---------------------------------------------------------------- branches
CREATE TABLE branch (
  branch_id   smallserial PRIMARY KEY,
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  is_real     boolean NOT NULL DEFAULT true   -- false for the "unassigned" bucket
);

INSERT INTO branch (code, name, is_real) VALUES
  ('3MARIAS',    '3 Marías',        true),
  ('TELEFERICO', 'Teleférico Rojo', true),
  ('SIN_ASIGNAR','Sin asignar',     false);


-- -------------------------------------------------------------- categories
CREATE TABLE category (
  category_id smallserial PRIMARY KEY,
  name        text NOT NULL UNIQUE
);


-- ------------------------------------------------------------------- items
-- One row per real, physical product. This is the only source of truth for
-- identity. Never delete rows here - deactivate them.
CREATE TABLE item (
  item_id       bigserial PRIMARY KEY,
  sku           text NOT NULL UNIQUE,          -- internal, immutable, never reused
  part_code     text,                          -- CODIGO from the spreadsheet
  base_code     text,                          -- CODIGO without the -L / -R suffix
  side          char(1) CHECK (side IN ('L','R')),
  category_id   smallint REFERENCES category(category_id),
  description   text NOT NULL,
  unit_price    numeric(12,2) CHECK (unit_price >= 0),
  legacy_row_id integer,                       -- first column of the old file
  needs_review  boolean NOT NULL DEFAULT false,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Enforced only once duplicates are resolved; see 04_post_migration_checks.sql
-- CREATE UNIQUE INDEX item_part_code_uk ON item (part_code) WHERE part_code IS NOT NULL;

CREATE INDEX item_desc_trgm ON item USING gin (norm_text(description) gin_trgm_ops);
CREATE INDEX item_code_trgm ON item USING gin (norm_text(coalesce(part_code,'')) gin_trgm_ops);


-- ----------------------------------------------------------------- aliases
-- Every nickname anyone uses for an item lives here. Many aliases -> one item.
-- Aliases hold no stock; they only point.
CREATE TABLE item_alias (
  alias_id   bigserial PRIMARY KEY,
  item_id    bigint NOT NULL REFERENCES item(item_id) ON DELETE CASCADE,
  alias      text NOT NULL,
  alias_norm text GENERATED ALWAYS AS (norm_text(alias)) STORED,
  source     text,                             -- 'legacy', 'search', 'manual'
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (item_id, alias)
);

CREATE INDEX alias_norm_trgm ON item_alias USING gin (alias_norm gin_trgm_ops);


-- ------------------------------------------------------------- stock ledger
-- Never store a bare quantity. Store the movements; derive the quantity.
CREATE TYPE movement_reason AS ENUM
  ('opening','purchase','sale','transfer_in','transfer_out','adjustment','defect');

CREATE TYPE item_condition AS ENUM ('good','defective');

CREATE TABLE stock_movement (
  movement_id bigserial PRIMARY KEY,
  item_id     bigint NOT NULL REFERENCES item(item_id),
  branch_id   smallint NOT NULL REFERENCES branch(branch_id),
  qty_delta   integer NOT NULL CHECK (qty_delta <> 0),
  condition   item_condition NOT NULL DEFAULT 'good',
  reason      movement_reason NOT NULL,
  note        text,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  created_by  text
);

CREATE INDEX stock_movement_item_branch ON stock_movement (item_id, branch_id);
CREATE INDEX stock_movement_occurred ON stock_movement (occurred_at DESC);


-- ------------------------------------------------------------------- views
CREATE VIEW stock_on_hand AS
SELECT item_id, branch_id, condition, SUM(qty_delta)::integer AS qty
FROM stock_movement
GROUP BY item_id, branch_id, condition
HAVING SUM(qty_delta) <> 0;

-- What a branch clerk actually looks at.
CREATE VIEW v_availability AS
SELECT i.sku,
       i.part_code,
       i.description,
       i.side,
       i.unit_price,
       b.name AS branch,
       s.condition,
       s.qty
FROM stock_on_hand s
JOIN item i   ON i.item_id = s.item_id
JOIN branch b ON b.branch_id = s.branch_id;


-- --------------------------------------------------------------- searching
-- Finds an item from any nickname, code fragment, or misspelling.
CREATE OR REPLACE FUNCTION search_items(q text, max_rows int DEFAULT 20)
RETURNS TABLE (item_id bigint, sku text, description text, score real)
LANGUAGE sql STABLE AS $$
  SELECT i.item_id, i.sku, i.description,
         GREATEST(
           similarity(norm_text(i.description), norm_text(q)),
           similarity(norm_text(coalesce(i.part_code,'')), norm_text(q)),
           coalesce(MAX(similarity(a.alias_norm, norm_text(q))), 0)
         ) AS score
  FROM item i
  LEFT JOIN item_alias a ON a.item_id = i.item_id
  WHERE i.is_active
  GROUP BY i.item_id
  HAVING GREATEST(
           similarity(norm_text(i.description), norm_text(q)),
           similarity(norm_text(coalesce(i.part_code,'')), norm_text(q)),
           coalesce(MAX(similarity(a.alias_norm, norm_text(q))), 0)
         ) > 0.25
  ORDER BY score DESC
  LIMIT max_rows;
$$;
