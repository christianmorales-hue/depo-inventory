# DEPO autolamp — Inventory Management System

A multi-branch inventory management system for an auto-lamp distributor in Bolivia, built from scratch to replace a single-computer Excel spreadsheet and phone calls between branches.

Live on Railway, used daily across two branches (~3,000 products).

## The Problem

DEPO autolamp manages ~3,000 auto lighting products across two branches (3 Marías, Teleférico Rojo). Before this system:

- Inventory lived in one Excel file on one computer
- Branches phoned the owner to check whether a product was in stock
- The same product had dozens of nicknames across staff ("CHANCHO" = a specific mirror)
- No sales history, no audit trail, no per-branch stock tracking
- Prices were quoted from memory and a paper list

## The Solution

A cloud-hosted web application with PostgreSQL, FastAPI, and a single-page JavaScript frontend. Any employee, at any branch, on any device, can search stock, quote prices, record sales, coordinate the warehouse, and reconcile the till.

## Features

### Inventory & search
- **Fuzzy search** with accent/typo tolerance and code-priority ranking — type "corola" and find "Corolla", type "BU-sur" and the exact part codes rank first
- **Automatic alias learning** — nicknames and descriptions become searchable terms
- **Multi-branch stock** on a movement ledger — every change is a recorded transaction, never a silent overwrite
- **Vehicle fitment** — make/model/year parsed from descriptions ("Por vehículo" browse)
- **Pair warnings** — flags when a branch has a left mirror but not the matching right
- **Duplicate detection** — warns before creating an item that already exists, with live fuzzy matching as you type

### Pricing
- **USD-internal pricing** with a **live exchange rate** from bo.dolarapi.com (hourly cached), converted to Bolivianos for display
- Prices shown in both Bs (primary, bold) and USD (secondary)
- Boliviano prices **rounded to the nearest 0.50 Bs** for clean invoicing
- Admins choose which rate (oficial/blue) drives the conversion

### Sales documents
- **Cotizaciones (quotes)** — branded PDF with frozen prices, 3-day validity, WhatsApp sharing
- **Notas de venta (sales notes)** — with **per-line discounts** in Bs
- **Ver** button on both — full document detail on screen (código, marca, description, branch, quantities, totals) without downloading
- **PDF and PNG export** on both — PNG for customers who can't open PDFs
- **CÓDIGO + MARCA columns** on every PDF — part codes in large bold for easy shelf picking, brand shown or "--" when absent
- **Convert cotización → nota de venta** — one-click import of a quote into the sales cart
- **Edit** past documents — loads items back into the cart; for notas, the original is anulled automatically so stock stays correct
- **Cancellations (anulaciones)** — reverse a sale; stock returns and reports self-correct

### Fulfillment & warehouse
- **Three delivery methods** chosen at sale time:
  - *Recojo en tienda* — pick the branch
  - *Entrega a domicilio* — recipient (with "same name as nota" option), city, address, drop-off date
  - *Envío bus/avión* — recipient (with "same name" option), city, bus/avión, company, Pagado / Por pagar
- **9 Bolivian cities** as dropdown options for delivery and shipping
- **Solicitud a bodega tab** — held-stock warehouse queue. A nota does **not** deduct inventory until the warehouse confirms it. Confirm deducts stock; reject cancels the nota. Each request has Ver / PDF / PNG / WhatsApp, modeled on the transfers flow.

### Operations
- **Devoluciones (returns)** — return goods to sellable ("bueno") or defective stock
- **Recepción de mercadería** — receive supplier shipments, raise stock, track cost per item
- **Transfers** between branches with in-transit tracking
- **Reservations** that hold stock for a customer without selling it
- **Caja diaria** — daily till reconciliation: opening cash + sales vs. counted cash, with discrepancy flagging and 30-day history

### Reminders
- **Pending-count badges** on nav tabs — Solicitud a bodega, Traspasos, and Reservas show a small amber badge with the number of items waiting for action, updated live

### Admin & reporting
- **Administración tab** (admin-only) — new-product creation and branch management, kept off the daily search screen
- **User accounts** with staff/admin (mostrador/gerencia) roles and PBKDF2-hashed passwords
- **Login gate** — no inventory visible until authenticated
- **Accounting exports** — daily/monthly CSVs with IVA 13% breakdown, Spanish Excel format
- **Automated report archive** — daily (30 days), weekly (1 year), monthly (forever)
- **Themes** — light, dark, and Dracula, remembered per browser

## Security

- Passwords hashed with **PBKDF2-SHA256** (200,000 rounds, per-user random salt) — never stored in plaintext
- Session tokens **HMAC-SHA256 signed** with constant-time verification and expiry
- Cookies are **httponly** and **samesite=lax**
- The signing secret is required in production; the app warns rather than shipping a guessable default

## Tech Stack

- **Backend:** Python, FastAPI, psycopg 3
- **Database:** PostgreSQL 16+ with trigram fuzzy search (`pg_trgm`) and `unaccent`
- **Frontend:** Vanilla JavaScript, single HTML page served from Python (no build step)
- **PDF:** ReportLab
- **PNG:** PyMuPDF (fitz) — renders PDFs to high-res images
- **Exchange rate:** bo.dolarapi.com REST API with hourly caching
- **Local dev:** Docker Compose (PostgreSQL)
- **Cloud:** Railway (web service + managed PostgreSQL), auto-deploy on `git push`

## Project Structure

```
depo-inventory/
├── api/                    FastAPI app
│   ├── main.py             core routes, auth, DB helper; imports PAGE from page.py
│   │                       and all route modules at the bottom
│   ├── page.py             the entire single-page frontend (HTML/CSS/JS)
│   ├── overrides.py        price-aware search, item CRUD, get-item endpoint
│   ├── pricing.py          exchange-rate fetching, USD→BOB conversion, 0.50 rounding
│   ├── quotes.py           cotizaciones + notas de venta + PDFs + PNGs + cancel
│   ├── operations.py       devoluciones, recepción, caja, dup-detect, fulfillment, bodega
│   ├── features.py         fitment, transfers, reservations, exports
│   ├── users.py            accounts and roles
│   └── reports_archive.py  scheduled report snapshots
├── db/                     SQL migrations (run in numeric order)
│   ├── 01_schema.sql       core tables + search functions (PG18-compatible)
│   ├── ...                 stocktake, admin, features, pricing, accounting,
│   │                       quotes, catalog import, better search, code-priority,
│   │                       duplicate fixes, stock count, operations,
│   │                       discount/cancel, fulfillment
│   └── 21_fulfillment.sql
├── etl/                    Python data-cleaning pipeline
├── docker-compose.yml      local PostgreSQL
├── Procfile                Railway start command
├── requirements.txt        fastapi, uvicorn, psycopg, reportlab, pymupdf
├── SETUP.md                new-computer onboarding guide
└── README.md
```

> **Architecture note:** `main.py` imports the page HTML with `from api.page import PAGE`, and imports every route module (`pricing`, `overrides`, `features`, `quotes`, `operations`, `users`, `reports_archive`) at the bottom of the file. If a route returns 404, confirm its module is imported there; if the page looks like an old version, confirm `main.py` imports `PAGE` from `page.py` rather than defining its own copy.

## Quick Start

See [SETUP.md](SETUP.md) for detailed instructions (three paths: edit-and-deploy, full local copy, separate cloud deployment).

### Minimal local setup

```bash
git clone https://github.com/christianmorales-hue/depo-inventory.git
cd depo-inventory
docker compose up -d
pip install -r requirements.txt
for f in db/[0-9]*.sql; do
  docker compose exec -T db psql -U depo -d depo -f "/work/$f"
done
export DEPO_SECRET="$(openssl rand -hex 32)"
export DEPO_ADMIN_PASSWORD="your-first-password"
uvicorn api.main:app --reload --port 8000
```

### Railway deployment

Key variables on the **web service** (not the database):

| Variable | Value |
|---|---|
| `DATABASE_URL` | Reference: `${{Postgres.DATABASE_URL}}` (internal) |
| `DEPO_SECRET` | `openssl rand -hex 32` |
| `DEPO_ADMIN_PASSWORD` | your first-login password |
| `PORT` | `8000` |

The web service reaches the database over the **internal** reference URL. From your own machine, use the **public** URL (`DATABASE_PUBLIC_URL` from Railway's Postgres → Variables) for `psql`/`pg_dump`.

## Data Migration

Three data sources imported via the ETL pipeline:

1. **Legacy Excel inventory** (2023) — 1,119 items with nicknames as aliases
2. **BIGDAM/YOITOKI catalog** — 1,080 items in USD
3. **TYG catalog** — 382 items in BOB, converted to USD at import

Plus a **physical branch count** (Teleférico Rojo, 2026) — 788 matched items adjusted, 379 new items created. Seven duplicate part_codes were resolved and a unique index now prevents future duplicates.

## Backups

The data is the one thing git can't protect. Snapshot it regularly:

```bash
export DATABASE_URL="postgresql://...the PUBLIC railway url..."
pg_dump "$DATABASE_URL" > backup_$(date +%Y%m%d).sql
```

Store the file off your laptop (cloud drive, external disk). To restore: `psql "$DATABASE_URL" < backup_YYYYMMDD.sql`.

Tag a known-good code state so you can always return to it:

```bash
git tag -a working-v1 -m "Fully working, deployed and verified"
git push origin working-v1
```

## Known Limitations

- **Photos** are not stored persistently — Railway's filesystem resets on redeploy. Cloud storage (Cloudflare R2) planned for later; the FOTO column was removed.
- **Electronic invoicing (SIN/SFE)** is intentionally deferred. Current documents are not fiscal; invoicing can be added via middleware when ready.
- **No automatic timer** on warehouse requests — confirm/reject is manual (Railway has no always-on background worker; a cron service could add timeouts later).

## License

Private project. Code shared for portfolio purposes.
