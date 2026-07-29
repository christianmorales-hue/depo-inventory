-- Optional "provincia" on a delivery, for shipments to the countryside where
-- the city alone isn't enough to route the package.
--   psql "$DATABASE_URL" -f db/23_provincia.sql

ALTER TABLE nota_fulfillment ADD COLUMN IF NOT EXISTS provincia text;
