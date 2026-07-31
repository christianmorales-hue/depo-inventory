"""
Exchange rates from bo.dolarapi.com, cached in the database.

The API is called at most once an hour, not on every request. If the API is
unreachable, the last cached rate keeps being used - the shop must not stop
working because an exchange-rate website is down.

Prices are stored in USD. Bolivianos shown to users are USD x the selling rate
(venta) of whichever source gerencia has chosen: 'oficial' or 'blue'.

Add to the bottom of api/main.py, after reports_archive:

    from api import pricing  # noqa: E402
"""
import urllib.request
import json
from datetime import datetime, timezone

from fastapi import HTTPException, Request

from api.main import app, require, run

SOURCES = {
    "oficial": "https://bo.dolarapi.com/v1/dolares/oficial",
    "blue":    "https://bo.dolarapi.com/v1/dolares/blue",
}
MAX_AGE_SECONDS = 3600


def _fetch_one(url):
    req = urllib.request.Request(url, headers={"User-Agent": "depo-inventory"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode())


def refresh_rates(force=False):
    """Update the cache if it is stale. Returns the current rows either way."""
    rows = {r["source"]: r for r in run("SELECT * FROM fx_rate")}
    for source, url in SOURCES.items():
        cached = rows.get(source)
        fresh = False
        if cached and not force:
            age = (datetime.now(timezone.utc) - cached["fetched_at"]).total_seconds()
            fresh = age < MAX_AGE_SECONDS
        if fresh:
            continue
        try:
            d = _fetch_one(url)
            run("""INSERT INTO fx_rate (source, compra, venta, casa, api_updated,
                                        fetched_at)
                   VALUES (%s, %s, %s, %s, %s, now())
                   ON CONFLICT (source) DO UPDATE SET
                     compra = excluded.compra, venta = excluded.venta,
                     casa = excluded.casa, api_updated = excluded.api_updated,
                     fetched_at = now()""",
                (source, d.get("compra"), d.get("venta"), d.get("casa"),
                 d.get("fechaActualizacion")))
        except Exception as e:
            print(f"fx {source}: could not refresh ({e}); keeping cached value")
    return {r["source"]: r for r in run("SELECT * FROM fx_rate")}


def current_rate():
    """The venta rate of the chosen source, plus context, for conversions."""
    rows = refresh_rates()
    source = run("SELECT value FROM app_setting WHERE key = 'fx_source'")
    source = source[0]["value"] if source else "oficial"
    row = rows.get(source) or next(iter(rows.values()), None)
    rate = float(row["venta"]) if row and row["venta"] else None
    return {"source": source, "rate": rate,
            "fetched_at": row["fetched_at"].isoformat() if row else None,
            "api_updated": (row["api_updated"] if row else None),
            "all": {k: {"compra": float(v["compra"]) if v["compra"] else None,
                        "venta": float(v["venta"]) if v["venta"] else None,
                        "casa": v["casa"],
                        "fetched_at": v["fetched_at"].isoformat()
                                      if v["fetched_at"] else None,
                        "api_updated": v["api_updated"]}
                    for k, v in rows.items()}}


def round_bob(value):
    """Round a Boliviano amount to the nearest 0.50, so prices come out as
    whole or half bolivianos (e.g. 234.13 -> 234.00, 234.30 -> 234.50).
    Keeps the till and quotes tidy; the exact USD value stays stored."""
    if value is None:
        return None
    return round(float(value) * 2) / 2


def usd_to_bob(price_usd, rate):
    if price_usd is None or rate is None:
        return None
    return round_bob(float(price_usd) * rate)


# ----------------------------------------------------------------- endpoints
@app.get("/api/fx")
def get_fx():
    """Public: the page needs the rate to show boliviano prices to anyone."""
    return current_rate()


@app.post("/api/fx/refresh")
def force_refresh(request: Request):
    require(request, "admin")
    refresh_rates(force=True)
    return current_rate()


@app.post("/api/fx/source")
def set_source(request: Request, source: str):
    require(request, "admin")
    if source not in SOURCES:
        raise HTTPException(400, "La fuente debe ser 'oficial' o 'blue'.")
    run("UPDATE app_setting SET value = %s WHERE key = 'fx_source'", (source,))
    return current_rate()
