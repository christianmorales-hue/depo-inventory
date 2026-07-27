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

A cloud-hosted web application with PostgreSQL, FastAPI, and a single-page JavaScript frontend. Any employee, at any branch, on any device, can search stock, quote prices, record sales, and reconcile the till.

## Features

### Inventory & search
- **Fuzzy search** with accent/typo tolerance and code-priority ranking — type "corola" and find "Corolla", type "BU-sur" and the exact part codes rank first
- **Automatic alias learning** — nicknames and descriptions become searchable terms
- **Multi-branch stock** on a movement ledger — every change is a recorded transaction, never a silent overwrite
- **Vehicle fitment** — make/model/year parsed from descriptions
- **Pair warnings** — flags when a branch has a left mirror but not the matching right
- **Duplicate detection** — warns before creating an item that already exists, with live fuzzy matching as you type

### Pricing
- **USD-internal pricing** with a **live exchange rate** from bo.dolarapi.com (hourly cached), converted to Bolivianos for display
- Prices shown in both Bs (primary, bold) and USD (secondary) in the search results
- Boliviano prices **rounded to the nearest 0.50 Bs** for clean invoicing
- Admins choose which rate (oficial/blue) drives the conversion

### Sales documents
- **Cotizaciones (quotes)** — branded PDF with frozen prices, 3-day validity, WhatsApp sharing
- **Notas de venta (sales notes)** — PDF + stock deduction, with **per-line discounts** in Bs
- **Convert cotización → nota de venta** — one-click import of a quote into the sales cart
- **Cancellations (anulaciones)** — reverse a sale; stock returns and reports self-correct
- **Edit** past documents — loads items back into the cart; for notas, anulación happens automatically
- **PDF and PNG export** — both formats available for every document, for customers who can't open PDFs
- **CÓDIGO + MARCA columns** on every PDF — part codes in bold for easy shelf picking, brand shown or "--" when absent

### Fulfillment & warehouse
- **Three delivery methods** at sale time: Recojo en tienda (pick branch), Entrega a domicilio (recipient, city, address, date), Envío bus/avión (recipient, city, transport, company, paid/unpaid)
- **Solicitud a bodega tab** — warehouse sees pending orders, confirms (stock deducts) or rejects (nota cancels), with Ver/PDF/PNG/WhatsApp per request
- **Held-stock model** — notas don't deduct inventory until the warehouse confirms, preventing premature stock loss
- **9 Bolivian cities** as dropdown options for delivery and shipping

### Operations
- **Devoluciones (returns)** — return goods to sellable ("bueno") or defective stock
- **Recepción de mercadería** — receive supplier shipments, raise stock, track cost per item
- **Transfers** between branches with in-transit tracking
- **Reservations** that hold stock for a customer without selling it
- **Caja diaria** — daily till reconciliation: opening cash + sales vs. counted cash, with discrepancy flagging and 30-day history

### Admin & reporting
- **User accounts** with staff/admin (gerencia/mostrador) roles and PBKDF2-hashed passwords
- **Login gate** — no inventory visible until authenticated
- **Accounting exports** — daily/monthly CSVs with IVA 13% breakdown, Spanish Excel format
- **Automated report archive** — daily (30 days), weekly (1 year), monthly (forever)
- **Themes** — light, dark, and Dracula, remembered per browser

### UI polish
- Responsive single-page app, works on desktop and mobile
- Number inputs without browser spinner arrows (theme-friendly)
- Theme-aware colors everywhere — buttons, search rows, badges, panels, and the logo all adapt
- Company logo with rounded border, visible in all themes
- Exchange rate shown as "TC oficial: X Bs/USD"

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
│   ├── main.py             core routes, auth, DB helper
│   ├── page.py             the entire single-page frontend (HTML/CSS/JS)
│   ├── overrides.py        price-aware search, item CRUD, get-item endpoint
│   ├── pricing.py          exchange-rate fetching, USD→BOB conversion, 0.50 rounding
│   ├── quotes.py           cotizaciones + notas de venta + PDFs + PNGs + cancel
│   ├── operations.py       devoluciones, recepción, caja, dup-detection, fulfillment, bodega
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
│   ├── 02_transform.py     clean the raw Excel export
│   ├── 03_fitment.py       parse vehicle fitment from descriptions
│   ├── 04_import_catalog.py    supplier catalog importer (USD or BOB)
│   └── 05_import_stock_count.py physical branch count importer
├── docker-compose.yml      local PostgreSQL
├── Procfile                Railway start command
├── requirements.txt        fastapi, uvicorn, psycopg, reportlab, pymupdf
├── SETUP.md                new-computer onboarding guide
└── README.md
```

## Quick Start

See [SETUP.md](SETUP.md) for detailed instructions covering three paths:
- **Path A:** Clone and deploy (edit code, push, Railway auto-deploys — no local DB needed)
- **Path B:** Full local development copy (Docker + PostgreSQL + data restore)
- **Path C:** Separate cloud deployment (staging copy on Railway)

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

See the "Deploying to the Cloud" section in [SETUP.md](SETUP.md). Key variables on the web service:

| Variable | Value |
|---|---|
| `DATABASE_URL` | Reference → Postgres service |
| `DEPO_SECRET` | `openssl rand -hex 32` |
| `DEPO_ADMIN_PASSWORD` | your first-login password |
| `PORT` | `8000` |

## Data Migration

Three data sources imported via the ETL pipeline:

1. **Legacy Excel inventory** (2023) — 1,119 items with nicknames as aliases
2. **BIGDAM/YOITOKI catalog** — 1,080 items in USD
3. **TYG catalog** — 382 items in BOB, converted to USD at import

Plus a **physical branch count** (Teleférico Rojo, March 2026) — 788 matched items adjusted, 379 new items created.

Seven duplicate part_codes were resolved (three merged, four split), and a unique index now prevents future duplicates at the database level.

## Backups

```bash
export DATABASE_URL="postgresql://...the PUBLIC railway url..."
pg_dump "$DATABASE_URL" > backup_$(date +%Y%m%d).sql
```

Do this weekly. The data is the one thing git can't protect.

## Known Limitations

- **Photos** are not stored persistently — Railway's filesystem resets on redeploy. Cloud storage (Cloudflare R2) planned for later.
- **Electronic invoicing (SIN/SFE)** is intentionally deferred. Current documents are not fiscal; invoicing can be added via middleware (NuboFact, Siat.bo) when ready.
- **No automatic timer** for warehouse requests — confirmation/rejection is manual. A Railway cron worker could enforce timeouts later if needed.

## License

Private project. Code shared for portfolio purposes.
