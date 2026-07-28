-- Speed up the make/model dropdown in "Buscar por vehículo".
--   psql "$DATABASE_URL" -f db/22_vehicle_index.sql
--
-- The /api/vehicles endpoint does SELECT DISTINCT make, model FROM vehicle
-- ORDER BY make, model. This index lets PostgreSQL satisfy both the DISTINCT
-- and the ORDER BY straight from the index, with no sort step.

CREATE INDEX IF NOT EXISTS vehicle_make_model_idx ON vehicle (make, model);
