"""
Report archive.

Writes sales reports into folders, on a schedule, and keeps them for as long
as they are useful:

    reports/diarios/    ventas_2026-07-23.csv   kept 30 days
    reports/semanales/  ventas_2026-S30.csv     kept 1 year
    reports/mensuales/  ventas_2026-07.csv      kept forever

Reports are only written for periods that have *finished*. Today's sales are
not final until today is over, so today never gets a file. Once written, a
file is never rewritten - if someone corrects a price in August, July's report
still says what July said. That is the point of an archive.

Add to the bottom of api/main.py, after the photos line:

    from api import reports_archive  # noqa: E402

Add `reports/` to .gitignore.
"""
import asyncio
import csv
import io
import re
from datetime import date, datetime, timedelta
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse

from api.main import app, require, run

ROOT = Path("reports")

KINDS = {
    "diarios":   {"folder": ROOT / "diarios",   "keep_days": 30,   "label": "Diarios"},
    "semanales": {"folder": ROOT / "semanales", "keep_days": 371,  "label": "Semanales"},
    "mensuales": {"folder": ROOT / "mensuales", "keep_days": None, "label": "Mensuales"},
}
for k in KINDS.values():
    k["folder"].mkdir(parents=True, exist_ok=True)

SAFE_NAME = re.compile(r"^ventas_[0-9A-Za-z\-]+\.csv$")


# ------------------------------------------------------------------ writing
def csv_bytes(rows):
    """Semicolon separated, comma decimals, UTF-8 BOM - opens in Spanish Excel."""
    buf = io.StringIO()
    buf.write("\ufeff")
    if not rows:
        buf.write("sin ventas en el periodo\r\n")
    else:
        w = csv.writer(buf, delimiter=";", lineterminator="\r\n")
        w.writerow(rows[0].keys())
        for r in rows:
            w.writerow([
                "" if v is None else
                (str(v).replace(".", ",") if isinstance(v, float) else v)
                for v in r.values()
            ])
    return buf.getvalue().encode("utf-8")


def sales_between(start: date, end: date):
    rows = run("SELECT * FROM v_sales_lines WHERE fecha >= %s AND fecha <= %s "
               "ORDER BY fecha, sucursal, producto", (start, end))
    for r in rows:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()[:10]
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    return rows


def write_once(path: Path, start: date, end: date) -> bool:
    """Write the file if it does not exist yet. Returns True if written."""
    if path.exists():
        return False
    rows = sales_between(start, end)
    if not rows:
        return False          # no sales, no file - the gap is the information
    path.write_bytes(csv_bytes(rows))
    return True


# ---------------------------------------------------------------- schedules
def catch_up(today: date | None = None) -> dict:
    """Write every finished period that has no file yet, then prune old ones."""
    today = today or date.today()
    made = {"diarios": 0, "semanales": 0, "mensuales": 0}

    # Daily: yesterday backwards through the retention window.
    for n in range(1, KINDS["diarios"]["keep_days"] + 1):
        d = today - timedelta(days=n)
        if write_once(KINDS["diarios"]["folder"] / f"ventas_{d}.csv", d, d):
            made["diarios"] += 1

    # Weekly: ISO weeks, Monday to Sunday, only weeks that have ended.
    monday_this_week = today - timedelta(days=today.weekday())
    for n in range(1, 54):
        start = monday_this_week - timedelta(weeks=n)
        end = start + timedelta(days=6)
        y, w, _ = start.isocalendar()
        if write_once(KINDS["semanales"]["folder"] / f"ventas_{y}-S{w:02d}.csv",
                      start, end):
            made["semanales"] += 1

    # Monthly: every month before the current one, back five years.
    y, m = today.year, today.month
    for _ in range(60):
        m -= 1
        if m == 0:
            y, m = y - 1, 12
        start = date(y, m, 1)
        end = date(y + (m == 12), m % 12 + 1, 1) - timedelta(days=1)
        if write_once(KINDS["mensuales"]["folder"] / f"ventas_{y}-{m:02d}.csv",
                      start, end):
            made["mensuales"] += 1

    prune(today)
    return made


def prune(today: date | None = None):
    """Delete reports past their retention. Monthly files are never deleted."""
    today = today or date.today()
    removed = 0
    for kind, cfg in KINDS.items():
        if cfg["keep_days"] is None:
            continue
        cutoff = datetime.combine(today - timedelta(days=cfg["keep_days"]),
                                  datetime.min.time()).timestamp()
        for f in cfg["folder"].glob("ventas_*.csv"):
            if f.stat().st_mtime < cutoff:
                f.unlink()
                removed += 1
    return removed


@app.on_event("startup")
async def scheduler():
    async def loop():
        while True:
            try:
                await asyncio.to_thread(catch_up)
            except Exception as e:            # never let the app die over a report
                print("report archive:", e)
            await asyncio.sleep(3600)
    asyncio.create_task(loop())


# ----------------------------------------------------------------- endpoints
@app.get("/api/reports/archive")
def archive(request: Request):
    require(request, "admin")
    out = {}
    for kind, cfg in KINDS.items():
        files = sorted(cfg["folder"].glob("ventas_*.csv"), reverse=True)
        out[kind] = {
            "label": cfg["label"],
            "keep": ("siempre" if cfg["keep_days"] is None
                     else f"{cfg['keep_days']} días"),
            "files": [{"name": f.name, "kb": round(f.stat().st_size / 1024, 1),
                       "modified": datetime.fromtimestamp(f.stat().st_mtime)
                                           .strftime("%Y-%m-%d %H:%M")}
                      for f in files],
        }
    return out


@app.post("/api/reports/generate")
def generate_now(request: Request):
    require(request, "admin")
    return {"creados": catch_up()}


@app.get("/api/reports/{kind}/{name}")
def download(kind: str, name: str, request: Request):
    require(request, "admin")
    if kind not in KINDS or not SAFE_NAME.match(name):
        raise HTTPException(404, "Reporte no encontrado.")
    path = KINDS[kind]["folder"] / name
    if not path.is_file():
        raise HTTPException(404, "Reporte no encontrado.")
    return FileResponse(path, media_type="text/csv; charset=utf-8", filename=name)
