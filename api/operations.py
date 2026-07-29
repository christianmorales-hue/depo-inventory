"""
Devoluciones, recepción de mercadería, caja diaria, and duplicate detection.

Add to the bottom of api/main.py, after the other imports:

    from api import operations  # noqa: E402
"""
from datetime import date

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from api.main import app, require, run
from api.pricing import current_rate, usd_to_bob


def _floats(rows, keys):
    for r in rows:
        for k in keys:
            if r.get(k) is not None and type(r[k]).__name__ == "Decimal":
                r[k] = float(r[k])
    return rows


# ===================================================== DUPLICATE DETECTION
@app.get("/api/items/similar")
def similar_items(q: str, request: Request):
    """Fuzzy-match a proposed description/code against existing items, so the
    user can be warned before creating a duplicate."""
    require(request, "admin")
    if len(q.strip()) < 3:
        return JSONResponse([])
    rows = run("""
        SELECT i.item_id, i.sku, i.part_code, i.description,
               word_similarity(norm_text(%s), norm_text(i.description)) AS sim
        FROM item i
        WHERE i.is_active
          AND (norm_text(i.description) %% norm_text(%s)
               OR norm_text(coalesce(i.part_code,'')) LIKE '%%' || norm_text(%s) || '%%')
        ORDER BY sim DESC NULLS LAST
        LIMIT 5
    """, (q, q, q))
    return JSONResponse(_floats(rows, ["sim"]))


# ===================================================== DEVOLUCIONES
class DevLine(BaseModel):
    item_id: int
    branch_id: int
    qty: int
    condition: str = "good"           # good = back to sellable stock, defect = not
    price_bob: float | None = None


class DevIn(BaseModel):
    quote_id: int | None = None
    customer: str | None = None
    reason: str | None = None
    refund_bob: float | None = None
    lines: list[DevLine]


@app.post("/api/devoluciones")
def create_devolucion(body: DevIn, request: Request):
    user = require(request)
    if not body.lines:
        raise HTTPException(400, "Agregue al menos un producto.")

    numero = run("SELECT nextval('devolucion_numero_seq') AS n")[0]["n"]
    dev = run("""INSERT INTO devolucion (numero, quote_id, customer, reason,
                     refund_bob, created_by)
                 VALUES (%s,%s,%s,%s,%s,%s)
                 RETURNING devolucion_id, numero""",
              (numero, body.quote_id, body.customer, body.reason,
               body.refund_bob, user["name"]))[0]

    for i, ln in enumerate(body.lines, 1):
        if ln.qty <= 0:
            raise HTTPException(400, "Las cantidades deben ser mayores a cero.")
        cond = "good" if ln.condition == "good" else "defect"
        run("""INSERT INTO devolucion_line (devolucion_id, line_no, item_id,
                     branch_id, qty, condition, price_bob)
                 VALUES (%s,%s,%s,%s,%s,%s,%s)""",
            (dev["devolucion_id"], i, ln.item_id, ln.branch_id, ln.qty, cond,
             ln.price_bob))
        # Put stock back. Good returns go to sellable stock; defective returns
        # are logged separately so they don't get re-sold by accident.
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta,
                     condition, reason, note, created_by)
               VALUES (%s,%s,%s,%s,'adjustment',%s,%s)""",
            (ln.item_id, ln.branch_id, ln.qty, cond,
             f"devolución #{numero}" + (" (defectuoso)" if cond == "defect" else ""),
             user["name"]))

    return {"devolucion_id": dev["devolucion_id"], "numero": dev["numero"]}


@app.get("/api/devoluciones")
def list_devoluciones(request: Request):
    require(request)
    rows = run("""SELECT d.devolucion_id, d.numero, d.customer, d.reason,
                         d.refund_bob, d.created_at::date AS fecha, d.created_by,
                         (SELECT count(*) FROM devolucion_line l
                           WHERE l.devolucion_id = d.devolucion_id) AS lineas
                  FROM devolucion d ORDER BY d.numero DESC LIMIT 100""")
    return JSONResponse(_floats(
        [{**r, "fecha": r["fecha"].isoformat()} for r in rows], ["refund_bob"]))


# ===================================================== RECEPCIÓN
class RecLine(BaseModel):
    item_id: int
    qty: int
    cost_usd: float | None = None


class RecIn(BaseModel):
    supplier: str | None = None
    invoice_ref: str | None = None
    branch_id: int
    note: str | None = None
    lines: list[RecLine]


@app.post("/api/recepciones")
def create_recepcion(body: RecIn, request: Request):
    user = require(request, "admin")
    if not body.lines:
        raise HTTPException(400, "Agregue al menos un producto.")

    fx = current_rate()
    numero = run("SELECT nextval('recepcion_numero_seq') AS n")[0]["n"]
    total_usd = sum((ln.cost_usd or 0) * ln.qty for ln in body.lines)

    rec = run("""INSERT INTO recepcion (numero, supplier, invoice_ref, branch_id,
                     note, total_usd, fx_rate, created_by)
                 VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                 RETURNING recepcion_id, numero""",
              (numero, body.supplier, body.invoice_ref, body.branch_id,
               body.note, total_usd, fx["rate"], user["name"]))[0]

    for i, ln in enumerate(body.lines, 1):
        if ln.qty <= 0:
            raise HTTPException(400, "Las cantidades deben ser mayores a cero.")
        run("""INSERT INTO recepcion_line (recepcion_id, line_no, item_id, qty,
                     cost_usd) VALUES (%s,%s,%s,%s,%s)""",
            (rec["recepcion_id"], i, ln.item_id, ln.qty, ln.cost_usd))
        # Raise stock.
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta,
                     condition, reason, note, created_by)
               VALUES (%s,%s,%s,'good','purchase',%s,%s)""",
            (ln.item_id, body.branch_id, ln.qty,
             f"recepción #{numero}" + (f" {body.supplier}" if body.supplier else ""),
             user["name"]))
        # Remember last cost on the item, for margin reporting.
        if ln.cost_usd is not None:
            run("UPDATE item SET cost_usd = %s WHERE item_id = %s",
                (ln.cost_usd, ln.item_id))

    return {"recepcion_id": rec["recepcion_id"], "numero": rec["numero"]}


@app.get("/api/recepciones")
def list_recepciones(request: Request):
    require(request)
    rows = run("""SELECT r.recepcion_id, r.numero, r.supplier, r.invoice_ref,
                         b.name AS sucursal, r.total_usd,
                         r.created_at::date AS fecha, r.created_by,
                         (SELECT count(*) FROM recepcion_line l
                           WHERE l.recepcion_id = r.recepcion_id) AS lineas
                  FROM recepcion r LEFT JOIN branch b USING (branch_id)
                  ORDER BY r.numero DESC LIMIT 100""")
    return JSONResponse(_floats(
        [{**r, "fecha": r["fecha"].isoformat()} for r in rows], ["total_usd"]))


# ===================================================== CAJA DIARIA
class CajaOpen(BaseModel):
    branch_id: int
    opening_bob: float = 0
    fecha: str | None = None          # defaults to today


class CajaClose(BaseModel):
    branch_id: int
    counted_bob: float
    note: str | None = None
    fecha: str | None = None


@app.post("/api/caja/open")
def open_caja(body: CajaOpen, request: Request):
    user = require(request)
    f = body.fecha or date.today().isoformat()
    run("""INSERT INTO caja (branch_id, fecha, opening_bob, created_by)
           VALUES (%s,%s,%s,%s)
           ON CONFLICT (branch_id, fecha)
           DO UPDATE SET opening_bob = excluded.opening_bob""",
        (body.branch_id, f, body.opening_bob, user["name"]))
    return {"ok": True}


@app.post("/api/caja/close")
def close_caja(body: CajaClose, request: Request):
    require(request)
    f = body.fecha or date.today().isoformat()
    row = run("""UPDATE caja SET counted_bob = %s, note = %s, closed_at = now()
                 WHERE branch_id = %s AND fecha = %s
                 RETURNING caja_id""",
              (body.counted_bob, body.note, body.branch_id, f))
    if not row:
        raise HTTPException(400, "Primero abra la caja del día.")
    return {"ok": True}


@app.get("/api/caja")
def get_caja(request: Request, branch_id: int, fecha: str | None = None):
    require(request)
    f = fecha or date.today().isoformat()
    rows = run("SELECT * FROM v_caja_expected WHERE branch_id = %s AND fecha = %s",
               (branch_id, f))
    if not rows:
        return JSONResponse({"fecha": f, "branch_id": branch_id, "abierta": False})
    r = rows[0]
    for k in ("opening_bob", "counted_bob", "ventas_bob", "esperado_bob",
              "diferencia_bob"):
        if r.get(k) is not None and type(r[k]).__name__ == "Decimal":
            r[k] = float(r[k])
    r["fecha"] = r["fecha"].isoformat()
    r["closed_at"] = r["closed_at"].isoformat() if r["closed_at"] else None
    r["abierta"] = True
    return JSONResponse(r)


@app.get("/api/caja/history")
def caja_history(request: Request, branch_id: int):
    require(request)
    rows = run("""SELECT * FROM v_caja_expected WHERE branch_id = %s
                  ORDER BY fecha DESC LIMIT 30""", (branch_id,))
    for r in rows:
        for k in ("opening_bob", "counted_bob", "ventas_bob", "esperado_bob",
                  "diferencia_bob"):
            if r.get(k) is not None and type(r[k]).__name__ == "Decimal":
                r[k] = float(r[k])
        r["fecha"] = r["fecha"].isoformat()
        r["closed_at"] = r["closed_at"].isoformat() if r["closed_at"] else None
    return JSONResponse(rows)


# ===================================================== FULFILLMENT + BODEGA
from datetime import date as _date

BOLIVIAN_CITIES = ["La Paz", "Santa Cruz", "Cochabamba", "Sucre", "Oruro",
                   "Potosí", "Tarija", "Trinidad", "Cobija"]


class Fulfillment(BaseModel):
    method: str                      # 'recojo' | 'entrega' | 'envio'
    branch_id: int | None = None     # recojo
    recipient: str | None = None     # entrega / envio
    city: str | None = None
    provincia: str | None = None     # optional, for countryside deliveries
    address: str | None = None       # entrega
    dropoff_date: str | None = None  # entrega
    transport: str | None = None     # envio: 'bus' | 'avion'
    company: str | None = None       # envio
    payment: str | None = None       # envio: 'pagado' | 'por_pagar'


@app.post("/api/notas/{quote_id}/fulfillment")
def save_fulfillment(quote_id: int, body: Fulfillment, request: Request):
    """Store how the customer receives an order, and open a warehouse request
    so the store can prepare and confirm the goods."""
    user = require(request)
    q = run("SELECT quote_number FROM quote WHERE quote_id = %s", (quote_id,))
    if not q:
        raise HTTPException(404, "Nota no encontrada.")

    dd = None
    if body.dropoff_date:
        try:
            dd = _date.fromisoformat(body.dropoff_date)
        except ValueError:
            dd = None

    run("""INSERT INTO nota_fulfillment (quote_id, method, branch_id, recipient,
                 city, provincia, address, dropoff_date, transport, company,
                 payment)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
           ON CONFLICT (quote_id) DO UPDATE SET
             method=excluded.method, branch_id=excluded.branch_id,
             recipient=excluded.recipient, city=excluded.city,
             provincia=excluded.provincia,
             address=excluded.address, dropoff_date=excluded.dropoff_date,
             transport=excluded.transport, company=excluded.company,
             payment=excluded.payment""",
        (quote_id, body.method, body.branch_id, body.recipient, body.city,
         body.provincia, body.address, dd, body.transport, body.company,
         body.payment))

    # Open a warehouse request if there isn't one yet.
    existing = run("SELECT bodega_id FROM bodega_request WHERE quote_id = %s",
                   (quote_id,))
    if not existing:
        numero = run("SELECT nextval('bodega_numero_seq') AS n")[0]["n"]
        run("""INSERT INTO bodega_request (quote_id, numero, created_by)
               VALUES (%s,%s,%s)""", (quote_id, numero, user["name"]))
    return {"ok": True}


@app.get("/api/bodega")
def list_bodega(request: Request, status: str = "pendiente"):
    require(request)
    rows = run("""
        SELECT br.bodega_id, br.numero, br.status, br.created_at, br.created_by,
               br.resolved_at, br.resolved_by,
               q.quote_id, q.quote_number, q.customer, q.customer_phone,
               f.method, f.city, f.provincia, f.address, f.recipient, f.transport,
               f.company, f.payment, f.dropoff_date,
               fb.name AS pickup_branch,
               (SELECT count(*) FROM quote_line ql WHERE ql.quote_id = q.quote_id) AS lineas
        FROM bodega_request br
        JOIN quote q ON q.quote_id = br.quote_id
        LEFT JOIN nota_fulfillment f ON f.quote_id = q.quote_id
        LEFT JOIN branch fb ON fb.branch_id = f.branch_id
        WHERE (%s = 'all' OR br.status = %s)
        ORDER BY br.created_at DESC LIMIT 100
    """, (status, status))
    for r in rows:
        for k, v in list(r.items()):
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    return JSONResponse(rows)


@app.get("/api/bodega/{bodega_id}")
def get_bodega(bodega_id: int, request: Request):
    require(request)
    br = run("SELECT * FROM bodega_request WHERE bodega_id = %s", (bodega_id,))
    if not br:
        raise HTTPException(404, "Solicitud no encontrada.")
    quote_id = br[0]["quote_id"]
    lines = run("""SELECT ql.part_code, ql.description, ql.side, ql.qty,
                          ql.price_bob, i.make AS brand
                   FROM quote_line ql LEFT JOIN item i ON i.item_id = ql.item_id
                   WHERE ql.quote_id = %s ORDER BY ql.line_no""", (quote_id,))
    f = run("""SELECT f.*, b.name AS pickup_branch
               FROM nota_fulfillment f LEFT JOIN branch b ON b.branch_id = f.branch_id
               WHERE f.quote_id = %s""", (quote_id,))
    q = run("SELECT quote_number, customer, customer_phone FROM quote WHERE quote_id = %s",
            (quote_id,))[0]
    def clean(rows):
        for r in rows:
            for k, v in list(r.items()):
                if hasattr(v, "isoformat"):
                    r[k] = v.isoformat()
                elif v is not None and type(v).__name__ == "Decimal":
                    r[k] = float(v)
        return rows
    return JSONResponse({
        "request": clean(br)[0],
        "quote": q,
        "lines": clean(lines),
        "fulfillment": (clean(f)[0] if f else None),
    })


@app.post("/api/bodega/{bodega_id}/confirm")
def confirm_bodega(bodega_id: int, request: Request):
    """Warehouse confirms the request: NOW deduct stock (the goods physically
    leave), then mark the nota's sale as active. Until this point no stock
    moved."""
    user = require(request)
    br = run("SELECT * FROM bodega_request WHERE bodega_id = %s", (bodega_id,))
    if not br:
        raise HTTPException(404, "Solicitud no encontrada.")
    if br[0]["status"] != "pendiente":
        raise HTTPException(400, "Esta solicitud ya fue resuelta.")

    quote_id = br[0]["quote_id"]
    number = run("SELECT quote_number FROM quote WHERE quote_id = %s",
                 (quote_id,))[0]["quote_number"]
    # If stock hasn't been deducted yet (held sale), do it now.
    already = run("""SELECT 1 FROM stock_movement
                     WHERE note = %s AND reason = 'sale' LIMIT 1""",
                  (f"nota de venta #{number}",))
    if not already:
        lines = run("SELECT * FROM quote_line WHERE quote_id = %s", (quote_id,))
        f = run("SELECT branch_id FROM nota_fulfillment WHERE quote_id = %s",
                (quote_id,))
        default_branch = f[0]["branch_id"] if f and f[0]["branch_id"] else None
        for ln in lines:
            branch_id = default_branch
            if branch_id is None:
                b = run("""SELECT branch_id FROM stock_on_hand
                           WHERE item_id = %s AND condition='good' AND qty > 0
                           ORDER BY qty DESC LIMIT 1""", (ln["item_id"],))
                branch_id = b[0]["branch_id"] if b else run(
                    "SELECT branch_id FROM branch WHERE is_real ORDER BY branch_id LIMIT 1"
                )[0]["branch_id"]
            run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                         price_usd, fx_rate, unit_price, note, created_by)
                   VALUES (%s,%s,%s,'sale',%s,%s,%s,%s,%s)""",
                (ln["item_id"], branch_id, -ln["qty"], ln["price_usd"],
                 None, ln["price_bob"],
                 f"nota de venta #{number}", user["name"]))

    run("""UPDATE bodega_request SET status='confirmado', resolved_at=now(),
             resolved_by=%s WHERE bodega_id=%s""", (user["name"], bodega_id))
    return {"ok": True}


@app.post("/api/bodega/{bodega_id}/reject")
def reject_bodega(bodega_id: int, request: Request):
    """Warehouse rejects: cancel the nota (return stock if any moved) and mark
    the request rejected."""
    user = require(request)
    br = run("SELECT * FROM bodega_request WHERE bodega_id = %s", (bodega_id,))
    if not br:
        raise HTTPException(404, "Solicitud no encontrada.")
    if br[0]["status"] != "pendiente":
        raise HTTPException(400, "Esta solicitud ya fue resuelta.")
    quote_id = br[0]["quote_id"]
    number = run("SELECT quote_number FROM quote WHERE quote_id = %s",
                 (quote_id,))[0]["quote_number"]
    # Reverse any sale movements that exist for this nota.
    moved = run("""SELECT item_id, branch_id, qty_delta, price_usd, unit_price
                   FROM stock_movement
                   WHERE note = %s AND reason = 'sale'""",
                (f"nota de venta #{number}",))
    for m in moved:
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                     price_usd, unit_price, note, created_by)
               VALUES (%s,%s,%s,'sale',%s,%s,%s,%s)""",
            (m["item_id"], m["branch_id"], -m["qty_delta"], m["price_usd"],
             m["unit_price"], f"anulación nota #{number}", user["name"]))
    run("UPDATE quote SET cancelled_at=now(), cancelled_by=%s WHERE quote_id=%s",
        (user["name"], quote_id))
    run("""UPDATE bodega_request SET status='rechazado', resolved_at=now(),
             resolved_by=%s WHERE bodega_id=%s""", (user["name"], bodega_id))
    return {"ok": True}


@app.get("/api/cities")
def cities(request: Request):
    require(request)
    return BOLIVIAN_CITIES
