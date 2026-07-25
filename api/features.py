"""
Extra features for the DEPO app: reservations, transfers, vehicle search,
pair warnings and CSV exports.

Add this ONE line to the very bottom of api/main.py:

    from api import features  # noqa: E402

It has to be the last line, because this module imports `app`, `run` and
`require` back out of main.py, and those must already exist.
"""
import csv
import io

from fastapi import HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from api.main import app, require, run


# ------------------------------------------------------------- CSV for Excel
def spanish_csv(rows, filename):
    """Semicolon separated, comma decimals, UTF-8 BOM.

    This matches the Excel your office already uses - the original inventory
    file was written the same way. A comma-separated file would open as a
    single mangled column on a Spanish-locale machine.
    """
    buf = io.StringIO()
    buf.write("\ufeff")                       # BOM, so Excel detects UTF-8
    if not rows:
        buf.write("sin datos\r\n")
    else:
        w = csv.writer(buf, delimiter=";", lineterminator="\r\n")
        w.writerow(rows[0].keys())
        for r in rows:
            w.writerow([
                str(v).replace(".", ",") if isinstance(v, float) else
                ("" if v is None else v)
                for v in r.values()
            ])
    return Response(
        buf.getvalue().encode("utf-8"),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


PERIODS = {
    "lines":   ("v_sales_lines",   "ventas_detalle"),
    "daily":   ("v_sales_daily",   "ventas_por_dia"),
    "monthly": ("v_sales_monthly", "ventas_por_mes"),
    "yearly":  ("v_sales_yearly",  "ventas_por_anio"),
}


@app.get("/api/export/sales")
def export_sales(request: Request, period: str = "daily",
                 desde: str | None = None, hasta: str | None = None):
    """period = lines | daily | monthly | yearly"""
    require(request, "admin")
    if period not in PERIODS:
        raise HTTPException(400, "Periodo no válido.")
    view, name = PERIODS[period]

    where, params = "", []
    if period in ("lines", "daily") and (desde or hasta):
        clauses = []
        if desde:
            clauses.append("fecha >= %s"); params.append(desde)
        if hasta:
            clauses.append("fecha <= %s"); params.append(hasta)
        where = " WHERE " + " AND ".join(clauses)

    rows = run(f"SELECT * FROM {view}{where}", tuple(params))
    for r in rows:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()[:10]
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    suffix = f"_{desde or 'inicio'}_{hasta or 'hoy'}" if where else ""
    return spanish_csv(rows, f"{name}{suffix}.csv")


@app.get("/api/export/{report}")
def export_report(report: str, request: Request):
    require(request, "admin")
    views = {"dead-stock": ("v_dead_stock", "stock_sin_movimiento"),
             "reorder": ("v_reorder", "reponer"),
             "broken-pairs": ("v_broken_pairs", "pares_incompletos"),
             "price-history": ("v_price_history", "historial_precios"),
             "acc-daily": ("v_acc_daily", "contabilidad_diaria"),
             "acc-monthly": ("v_acc_monthly", "contabilidad_mensual"),
             "top-products": ("v_top_products", "mas_vendidos"),
             "by-type": ("v_by_type", "ventas_por_tipo")}
    if report not in views:
        raise HTTPException(404, "Reporte no encontrado.")
    view, name = views[report]
    rows = run(f"SELECT * FROM {view}")
    for r in rows:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()[:19]
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    return spanish_csv(rows, f"{name}.csv")


# ------------------------------------------------------------- vehicle search
@app.get("/api/vehicles")
def vehicles():
    return run("""SELECT v.make, v.model, count(*) AS partes
                  FROM vehicle v JOIN item_fitment f USING (vehicle_id)
                  JOIN item i USING (item_id) WHERE i.is_active
                  GROUP BY v.make, v.model ORDER BY v.make, v.model""")


@app.get("/api/vehicle-parts")
def vehicle_parts(make: str, model: str | None = None, year: int | None = None):
    from api.pricing import current_rate, usd_to_bob
    rate = current_rate()["rate"]
    rows = run("SELECT * FROM parts_for_vehicle(%s, %s, %s)", (make, model, year))
    for r in rows:
        usd = r.pop("unit_price", None)
        r["price_usd"] = float(usd) if usd is not None else None
        r["price_bob"] = usd_to_bob(r["price_usd"], rate)
    return rows


# --------------------------------------------------------------- reservations
class Hold(BaseModel):
    item_id: int
    branch_id: int
    qty: int
    customer: str | None = None
    note: str | None = None
    hours: int = 48


@app.post("/api/reservations")
def reserve(body: Hold, request: Request):
    user = require(request)
    avail = run("""SELECT coalesce(available, 0) AS a FROM v_available
                   WHERE item_id = %s AND branch_id = %s""",
                (body.item_id, body.branch_id))
    have = avail[0]["a"] if avail else 0
    if body.qty <= 0 or body.qty > have:
        raise HTTPException(400, f"Solo hay {have} disponibles para reservar.")
    return run("""INSERT INTO reservation (item_id, branch_id, qty, customer, note,
                                           expires_at, created_by)
                  VALUES (%s, %s, %s, %s, %s, now() + make_interval(hours => %s), %s)
                  RETURNING reservation_id, expires_at""",
               (body.item_id, body.branch_id, body.qty, body.customer, body.note,
                body.hours, user["name"]))[0]


@app.get("/api/reservations")
def list_reservations(request: Request):
    require(request)
    return run("""SELECT r.reservation_id, r.qty, r.customer, r.expires_at,
                         r.created_by, b.name AS branch, i.description, i.side
                  FROM reservation r JOIN branch b USING (branch_id)
                  JOIN item i USING (item_id)
                  WHERE r.status = 'held' AND r.expires_at > now()
                  ORDER BY r.expires_at""")


@app.post("/api/reservations/{rid}/{action}")
def close_reservation(rid: int, action: str, request: Request):
    user = require(request)
    if action not in ("collected", "cancelled"):
        raise HTTPException(400, "Acción no válida.")
    row = run("""UPDATE reservation SET status = %s WHERE reservation_id = %s
                 AND status = 'held' RETURNING item_id, branch_id, qty""",
              (action, rid))
    if not row:
        raise HTTPException(404, "Reserva no encontrada o ya cerrada.")
    if action == "collected":                 # collecting it is a sale
        r = row[0]
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                                           unit_price, note, created_by)
               SELECT %s, %s, %s, 'sale', unit_price,
                      format('reserva #%s', %s), %s
               FROM item WHERE item_id = %s""",
            (r["item_id"], r["branch_id"], -r["qty"], rid, rid, user["name"],
             r["item_id"]))
    return {"ok": True}


# ------------------------------------------------------------------ transfers
class Send(BaseModel):
    item_id: int
    from_branch: int
    to_branch: int
    qty: int
    note: str | None = None


@app.post("/api/transfers")
def send(body: Send, request: Request):
    user = require(request)
    try:
        row = run("SELECT send_transfer(%s, %s, %s, %s, %s, %s) AS transfer_id",
                  (body.item_id, body.from_branch, body.to_branch, body.qty,
                   user["name"], body.note))
    except Exception as e:
        raise HTTPException(400, str(e).split("\n")[0])
    return row[0]


@app.get("/api/transfers")
def in_transit(request: Request):
    require(request)
    return run("""SELECT t.transfer_id, t.qty, t.sent_at, t.sent_by, t.note,
                         f.name AS desde, d.name AS hacia,
                         i.description, i.side
                  FROM transfer t
                  JOIN branch f ON f.branch_id = t.from_branch
                  JOIN branch d ON d.branch_id = t.to_branch
                  JOIN item i USING (item_id)
                  WHERE t.status = 'in_transit' ORDER BY t.sent_at""")


@app.post("/api/transfers/{tid}/receive")
def receive(tid: int, request: Request):
    user = require(request)
    try:
        run("SELECT receive_transfer(%s, %s)", (tid, user["name"]))
    except Exception as e:
        raise HTTPException(400, str(e).split("\n")[0])
    return {"ok": True}


# -------------------------------------------------------------- pair warnings
@app.get("/api/broken-pairs")
def broken_pairs(request: Request):
    require(request)
    return run("SELECT * FROM v_broken_pairs ORDER BY branch, description")
