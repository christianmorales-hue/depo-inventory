# Setup on a New Computer

This guide gets DEPO autolamp running on a fresh machine. Pick the path that matches what you need.

**The short version:** cloning from GitHub gives you all the code and the ability to deploy to the live cloud app immediately. It does **not** give you the data (that lives only in the Railway database) or the secrets (you re-enter those). Most of the time, you don't need a local copy of the data at all.

---

## What git carries, and what it doesn't

| Thing | In GitHub? | How you get it on a new machine |
|---|---|---|
| All code (api, db, etl) | Yes | `git clone` |
| Ability to deploy to the live app | Yes | `git push` after cloning |
| Secrets (`DEPO_SECRET`, passwords) | No | Re-enter in Railway / your shell |
| The data (items, sales, users) | No | Restore a `pg_dump` backup |
| Supplier price CSVs | No | Copy manually if needed |

The live app on Railway is the source of truth. A new computer is just another editor pointing at the same Railway project and the same database.

---

## Path A — Just edit and deploy (most common)

You want to change code and have it go live. You do **not** need Docker, a local database, or the data.

```bash
# 1. Clone
git clone https://github.com/christianmorales-hue/depo-inventory.git
cd depo-inventory

# 2. (Optional) to run psql against the cloud database, grab
#    DATABASE_PUBLIC_URL from Railway > Postgres service > Variables:
export DATABASE_URL="postgresql://...the PUBLIC url..."

# 3. Make changes, then deploy
git add .
git commit -m "describe the change"
git push        # Railway rebuilds and redeploys in ~90 seconds
```

That's it. The live app keeps all its data because that data was never in git — it's in Railway's database, untouched by deploys.

**Requirements:** git, and a GitHub login with push access to the repo.

---

## Path B — Full local development copy

You want the whole app running on your machine, with a local database, so you can experiment without touching production.

### 1. Clone and install

```bash
git clone https://github.com/christianmorales-hue/depo-inventory.git
cd depo-inventory
pip install -r requirements.txt
```

**Requirements:** git, Docker Desktop, Python 3.11+.

### 2. Start a local PostgreSQL

```bash
docker compose up -d
```

This runs Postgres on `localhost:5433` (see `docker-compose.yml`).

### 3. Build the schema

Run every migration in order. This creates the tables — but they'll be empty.

```bash
for f in db/[0-9]*.sql; do
  echo "--- $f ---"
  docker compose exec -T db psql -U depo -d depo -f "/work/$f"
done
```

### 4. Get the data (choose one)

**Option 4a — Restore a backup** (if you have a `backup_YYYYMMDD.sql`):

```bash
psql "postgresql://depo:depo@localhost:5433/depo" < backup_20260726.sql
```

**Option 4b — Copy the live data down from Railway:**

```bash
# Dump the cloud database (uses the PUBLIC url from Railway)
pg_dump "postgresql://...the PUBLIC railway url..." > full_backup.sql

# Load it into your local Postgres
psql "postgresql://depo:depo@localhost:5433/depo" < full_backup.sql
```

**Option 4c — Start empty** and load the original inventory from the ETL pipeline (only if you have the raw CSVs, which are not in git):

```bash
python3 etl/02_transform.py data/raw/INVENTARIO_ENERO_2023.csv data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/03_load.sql
python3 etl/03_fitment.py data/out
docker compose exec -w /work/data/out db psql -U depo -d depo -f /work/db/07_load_fitment.sql
```

### 5. Run the app

```bash
export DEPO_SECRET="$(openssl rand -hex 32)"
export DEPO_ADMIN_PASSWORD="your-first-password"
export DATABASE_URL="postgresql://depo:depo@localhost:5433/depo"
uvicorn api.main:app --reload --port 8000
```

Open http://localhost:8000 and log in with any username and your `DEPO_ADMIN_PASSWORD` — the first login creates the admin account.

---

## Path C — Set up a brand-new cloud deployment

You want a *separate* Railway deployment (e.g. a staging copy) from the same code. See the "Deploying to the Cloud (Railway)" section in [README.md](README.md) — it walks through creating the project, adding PostgreSQL, setting environment variables, running migrations against the cloud database, and generating a domain.

---

## Keeping backups (do this weekly)

The data is the one thing git can't protect. Snapshot it regularly:

```bash
export DATABASE_URL="postgresql://...the PUBLIC railway url..."
pg_dump "$DATABASE_URL" > backup_$(date +%Y%m%d).sql
```

Store the file somewhere safe (cloud drive, external disk). With a recent backup, you can rebuild a full local copy (Path B) or recover from any accident in minutes.

---

## Troubleshooting

- **`psql: command not found`** — install the client: `brew install libpq && brew link --force libpq` (macOS).
- **Migrations fail with `unaccent` errors on a fresh database** — make sure you're running the migrations in numeric order; `01_schema.sql` must run first, it creates the extensions and functions everything else depends on.
- **`git push` doesn't deploy** — confirm the push reached GitHub (`git status` says "up to date with origin/main") and that Railway's web service has automatic deploys enabled for the `main` branch.
- **App starts but login fails on a fresh cloud DB** — the first login only bootstraps an admin when the `app_user` table is empty; if it has stale rows, clear them: `psql "$DATABASE_URL" -c "DELETE FROM app_user;"` then log in again.
