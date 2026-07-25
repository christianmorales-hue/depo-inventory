DB_URL ?= postgresql://depo:depo@localhost:5432/depo
RAW    ?= data/raw/INVENTARIO_ENERO_2023.csv
OUT    ?= data/out
PSQL    = psql "$(DB_URL)" -v ON_ERROR_STOP=1

.PHONY: help up down psql transform schema load rebuild check clean

help:
	@echo "make up         start local Postgres"
	@echo "make rebuild    drop everything and rebuild from the raw CSV"
	@echo "make psql       open a SQL shell"
	@echo "make check      run the sanity queries"

up:
	docker compose up -d
	@until docker compose exec -T db pg_isready -U depo >/dev/null 2>&1; do sleep 1; done
	@echo "database ready on localhost:5432"

down:
	docker compose down

psql:
	@$(PSQL)

transform:
	python3 etl/02_transform.py "$(RAW)" "$(OUT)"

schema:
	$(PSQL) -f db/01_schema.sql
	$(PSQL) -f db/04_stocktake.sql

load: transform
	cd "$(OUT)" && $(PSQL) -f ../../db/03_load.sql

# The habit worth building: one command back to a known-good state.
rebuild: 
	$(PSQL) -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	$(MAKE) schema
	$(MAKE) load

check:
	$(PSQL) -c "SELECT b.name, s.condition, sum(s.qty) FROM stock_on_hand s JOIN branch b USING (branch_id) GROUP BY 1,2 ORDER BY 1,2;"
	$(PSQL) -c "SELECT * FROM search_items('faro izq corola');"

clean:
	rm -rf "$(OUT)"
