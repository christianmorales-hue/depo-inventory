# DEPO autolamp — Inventory Management System

A multi-branch inventory management system for an auto-lamp distributor in Bolivia, built from scratch to replace a single-computer Excel spreadsheet and phone calls between branches.

Live on Railway, used daily across two branches.

## The Problem

DEPO autolamp manages ~3,000 auto lighting products across two branches. Before this system:

- Inventory lived in one Excel file on one computer
- Branches phoned the owner to check whether a product was in stock
- The same product had dozens of nicknames across staff ("CHANCHO" = a specific mirror)
- No sales history, no audit trail, no per-branch stock tracking
- Prices were quoted from memory and a paper list

## The Solution

A cloud-hosted web application with PostgreSQL, FastAPI, and a single-page JavaScript frontend. Any employee, at any branch, on any device, can search stock, quote prices, record sales, and reconcile the till.

## Features

### Inventory & search
- **Fuzzy search** with accent/typo tolerance and code-priority ranking — type "corola" and find "Corolla", type "BU-sur" and the exact part codes rank first
- **Automatic alias learning** — nicknames and descriptions become searchable terms
- **Multi-branch stock** on a movement ledger — every change is a recorded transaction, never a silent overwrite
- **Vehicle fitment** — make/model/year parsed from descriptions
- **Pair warnings** — flags when a branch has a left mirror but not the matching right
- **Duplicate detection** — warns before creating an item that already exists

### Pricing
- **USD-internal pricing** with a **live exchange rate** from bo.dolarapi.com (hourly cached), converted to Bolivianos for display
- Prices shown in both Bs and USD; admins choose which rate drives the conversion

### Sales documents
- **Cotizaciones (quotes)** — branded PDF with frozen prices, sent via WhatsApp, 3-day validity
- **Notas de venta (sales notes)** — PDF + real stock deduction, with **per-line discounts**
- **Cancellations (anulaciones)** — reverse a sale; stock returns and reports self-correct
- **Devoluciones (returns)** — return goods to sellable or defective stock

### Operations
- **Recepción de mercadería** — receive supplier shipments, raise stock, track cost per item
- **Transfers** between branches with in-transit tracking
- **Reservations** that hold stock for a customer without selling it
- **Caja diaria** — daily till reconciliation: opening cash + sales vs. counted cash, with discrepancy flagging

### Admin & reporting
- **User accounts** with staff/admin roles and PBKDF2-hashed passwords
- **Login gate** — no inventory visible until authenticated
- **Accounting exports** — daily/monthly CSVs with IVA 13% breakdown, Spanish Excel format
- **Automated report archive** — daily (30 days), weekly (1 year), monthly (forever)
- **Themes** — light, dark, and Dracula

## Tech Stack

- **Backend:** Python, FastAPI, psycopg 3
- **Database:** PostgreSQL 16+ with trigram fuzzy search (`pg_trgm`) and `unaccent`
- **Frontend:** Vanilla JavaScript, single HTML page served from Python (no build step)
- **PDF:** ReportLab
- **Exchange rate:** bo.dolarapi.com REST API with hourly caching
- **Local dev:** Docker Compose (PostgreSQL)
- **Cloud:** Railway (web service + managed PostgreSQL), auto-deploy on `git push`

## Project Structure

```
depo-inventory/
├── api/                    FastAPI app
│   ├── main.py             core routes, auth, DB helper
│   ├── page.py             the entire single-page frontend (HTML/CSS/JS)
│   ├── overrides.py        price-aware search, item CRUD
│   ├── pricing.py          exchange-rate fetching + caching
│   ├── quotes.py           cotizaciones + notas de venta + PDFs
│   ├── operations.py       devoluciones, recepcion, caja, dup-detection
│   ├── features.py         fitment, transfers, reservations, exports
│   ├── users.py            accounts and roles
│   └── reports_archive.py  scheduled report snapshots
├── db/                     SQL migrations, run in numeric order
├── etl/                    Python data-cleaning pipeline
├── docker-compose.yml      local PostgreSQL
├── Procfile                Railway start command
├── requirements.txt
├── migrate.sh              run all migrations against $DATABASE_URL
└── README.md
```

## Running Locally

Requires Docker and Python 3.11+.

```bash
# 1. Start PostgreSQL
docker compose up -d

# 2. Install dependencies
pip install -r requirements.txt

# 3. Run all migrations in order
for f in db/[0-9]*.sql; do
  docker compose exec -T db psql -U depo -d depo -f "/work/$f"
done

# 4. (Optional) clean and load the original inventory
python3 etl/02_transform.py data/raw/INVENTARIO_ENERO_2023.csv data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/03_load.sql
python3 etl/03_fitment.py data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/07_load_fitment.sql

# 5. Start the app
export DEPO_SECRET="$(openssl rand -hex 32)"
export DEPO_ADMIN_PASSWORD="your-first-password"
uvicorn api.main:app --reload --port 8000
```

Open http://localhost:8000 and log in with any username and your `DEPO_ADMIN_PASSWORD` — the first login bootstraps the admin account.

## Deploying to the Cloud (Railway)

The app runs on [Railway](https://railway.com): one web service (this repo) plus a managed PostgreSQL instance. Deployment is automatic — every `git push` to `main` rebuilds and redeploys in about 90 seconds.

### First-time setup

1. **Create the project.** On Railway: *New Project → Deploy from GitHub Repo →* select `depo-inventory`. Railway detects Python and builds using `requirements.txt` and the `Procfile`.

2. **Add the database.** In the same project: *New → Database → Add PostgreSQL*. Railway provisions it and exposes `DATABASE_URL`.

3. **Set environment variables** on the **web service** (not the database):

   | Variable | Value |
   |---|---|
   | `DATABASE_URL` | Reference variable → point at the Postgres service |
   | `DEPO_SECRET` | a random string (`openssl rand -hex 32`) |
   | `DEPO_ADMIN_PASSWORD` | your first-login password |
   | `PORT` | `8000` |

4. **Run the migrations** against the cloud database. From your machine, copy `DATABASE_PUBLIC_URL` from Railway's Postgres → Variables, then:

   ```bash
   export DATABASE_URL="postgresql://...  # the PUBLIC url from Railway"
   for f in db/[0-9]*.sql; do
     echo "--- $f ---"
     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
   done
   ```

5. **Generate a public domain.** Railway → web service → *Settings → Networking → Generate Domain*. HTTPS is automatic.

6. **Log in** at the Railway URL with your `DEPO_ADMIN_PASSWORD` to create the first admin.

### Day-to-day

```bash
git add .
git commit -m "describe the change"
git push          # Railway rebuilds and redeploys automatically
```

Code changes flow through git. **Data lives only in the Railway database** and is never touched by deploys — schema changes and data edits are applied with `psql` against `DATABASE_URL`.

### Backups

Railway backs up automatically on paid plans. On the free plan, snapshot manually:

```bash
pg_dump "$DATABASE_URL" > backup_$(date +%Y%m%d).sql
```

## Data Migration

The original Excel inventory (1,126 rows, semicolon-delimited, Spanish decimal commas) was cleaned and migrated via a Python ETL pipeline that:

- Parsed make/model/year from free-text descriptions (~78% coverage)
- Separated monetary values from quantity values in ambiguous columns
- Seeded ~3,000 aliases for the fuzzy search
- Produced a human-review queue for duplicates (nothing silently dropped)

Two later supplier catalogs (BIGDAM/YOITOKI in USD, TYG in Bs) and a physical branch count were imported the same way, bringing the catalog to ~3,000 items.

## Notes

- **Photos** are not stored persistently yet — Railway's filesystem resets on redeploy, so image storage will move to object storage (Cloudflare R2 or similar) before photo upload is re-enabled.
- **Electronic invoicing (SIN/SFE)** is intentionally deferred. Cotizaciones and notas de venta are not fiscal documents; fiscal invoicing can be added later, likely via a middleware provider.

## License

Private project. Code shared for portfolio purposes.
