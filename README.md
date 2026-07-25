# DEPO autolamp — Inventory Management System

A multi-branch inventory management system for an auto-lamp distributor in Bolivia, built from scratch to replace a single-computer Excel spreadsheet and phone calls between branches.

## The Problem

DEPO autolamp manages 1,100+ auto lighting products across multiple branches. Before this system:
- Inventory lived in one Excel file on one computer
- Branches called the owner to check if a product was available
- The same product had dozens of nicknames across staff ("CHANCHO" = a specific mirror)
- No sales history, no audit trail, no per-branch stock tracking

## The Solution

A web application with PostgreSQL, FastAPI, and a single-page JavaScript frontend.

### Features

- **Fuzzy search** with accent/typo tolerance and automatic alias learning — search "corola" and find "Corolla"
- **Multi-branch stock** with a movement ledger (every change is recorded, not just the number)
- **Vehicle fitment** — parsed from product descriptions, so a clerk can search by Toyota → Corolla → 1995
- **USD pricing with live exchange rate** from bo.dolarapi.com, converted to Bolivianos for display
- **Cotizaciones (quotes)** — PDF generation with frozen prices, sent via WhatsApp
- **Notas de venta (sales notes)** — PDF + stock deduction in one click
- **Transfers** between branches with in-transit tracking
- **Reservations** that hold stock for a customer without selling it
- **Pair warnings** — flags when a branch has a left mirror but not the right
- **User accounts** with staff/admin roles, PBKDF2-hashed passwords
- **Accounting exports** — daily/monthly/yearly CSVs with IVA 13% breakdown, Spanish Excel format
- **Automated report archive** — daily (30 days), weekly (1 year), monthly (forever)

### Tech Stack

- **Backend:** Python, FastAPI, psycopg (async PostgreSQL)
- **Database:** PostgreSQL 16 with trigram fuzzy search (pg_trgm)
- **Frontend:** Vanilla JavaScript (no framework), single HTML page served from Python
- **PDF:** ReportLab
- **Exchange Rate:** bo.dolarapi.com REST API with hourly caching
- **Deployment:** Railway (app) + Railway PostgreSQL (database)

### Data Migration

The original Excel inventory (1,126 rows, semicolon-delimited, mixed Spanish decimal commas) was cleaned and migrated via a Python ETL pipeline that:
- Parsed make/model/year from free-text descriptions (78% coverage)
- Detected and separated monetary values from quantity values in ambiguous columns
- Built a seed alias table (3,000 entries) for the fuzzy search
- Generated a human-review queue for duplicates and ambiguities (nothing silently dropped)

## Running Locally

```bash
# Start PostgreSQL
docker compose up -d

# Install dependencies
pip install -r requirements.txt

# Run migrations (in order)
for f in db/0*.sql db/1*.sql; do
  docker compose exec db psql -U depo -d depo -f /work/$f
done

# Clean and load data
python3 etl/02_transform.py data/raw/INVENTARIO_ENERO_2023.csv data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/03_load.sql

# Parse vehicle fitment
python3 etl/03_fitment.py data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/07_load_fitment.sql

# Start the app
export DEPO_SECRET="$(openssl rand -hex 32)"
export DEPO_ADMIN_PASSWORD="your-first-password"
uvicorn api.main:app --reload --port 8000
```

## License

Private project. Code shared for portfolio purposes.
