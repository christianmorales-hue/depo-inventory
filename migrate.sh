#!/usr/bin/env bash
# Run all database migrations in order.
# Usage:   ./migrate.sh
# Expects: DATABASE_URL environment variable (Railway sets this automatically)
set -euo pipefail

DB="${DATABASE_URL:?Set DATABASE_URL}"

echo "=== Running migrations against $(echo "$DB" | sed 's|://[^@]*@|://***@|') ==="

for f in db/01_schema.sql \
         db/04_stocktake.sql \
         db/05_admin.sql \
         db/06_features.sql \
         db/07_load_fitment.sql \
         db/08_users.sql \
         db/09_extras.sql \
         db/10_pricing.sql \
         db/11_accounting.sql \
         db/12_quotes.sql; do
  if [ -f "$f" ]; then
    echo "--- $f ---"
    psql "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | tail -5
  else
    echo "SKIP $f (not found)"
  fi
done

echo "=== Done ==="
