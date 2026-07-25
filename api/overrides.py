"""
Pricing-aware overrides. These REPLACE four things in main.py. Loading this
module re-registers the routes, and FastAPI uses the last registration, so the
old versions in main.py are harmlessly shadowed.

Add to the very bottom of api/main.py, AFTER `from api import pricing`:

    from api import overrides  # noqa: E402

Also delete (or leave shadowed) the old SEARCH_SQL usage - this module ships
its own query that includes the USD price and the new attribute columns.
"""
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from api.main import app, require, run
from api.pricing import current_rate, usd_to_bob

SEARCH_SQL = """
SELECT i.item_id, i.sku, i.part_code, i.side, i.description, i.price_usd,
       i.is_active, i.photo_path, i.product_type, i.make, i.model,
       i.year_text, i.nickname,
       coalesce(json_agg(json_build_object('branch_id', b.branch_id, 'qty', s.qty))
                FILTER (WHERE b.branch_id IS NOT NULL), '[]') AS stock
FROM search_items(%s, 40) r
JOIN item i ON i.item_id = r.item_id
LEFT JOIN stock_on_hand s ON s.item_id = i.item_id AND s.condition = 'good'
LEFT JOIN branch b ON b.branch_id = s.branch_id AND b.is_active
GROUP BY i.item_id, r.score
ORDER BY r.score DESC
"""
RECENT_SQL = SEARCH_SQL.replace(
    "FROM search_items(%s, 40) r\nJOIN item i ON i.item_id = r.item_id",
    "FROM item i").replace(
    "ORDER BY r.score DESC",
    "ORDER BY i.created_at DESC, i.item_id DESC LIMIT 40").replace(", r.score", "")


def _decorate(rows, rate):
    for r in rows:
        r["price_usd"] = float(r["price_usd"]) if r["price_usd"] is not None else None
        r["price_bob"] = usd_to_bob(r["price_usd"], rate)
    return rows


@app.get("/api/search")
def search(q: str = ""):
    rate = current_rate()["rate"]
    rows = run(SEARCH_SQL, (q.strip(),)) if len(q.strip()) >= 2 else run(RECENT_SQL)
    return JSONResponse(_decorate(rows, rate))


class ItemIn(BaseModel):
    description: str
    part_code: str | None = None
    side: str | None = None
    price_usd: float | None = None
    product_type: str | None = None
    make: str | None = None
    model: str | None = None
    year_text: str | None = None
    nickname: str | None = None


@app.post("/api/items")
def create_item(body: ItemIn, request: Request):
    user = require(request, "admin")
    if len(body.description.strip()) < 3:
        raise HTTPException(400, "La descripción es obligatoria.")
    side = (body.side or "").upper() or None
    if side not in (None, "L", "R"):
        raise HTTPException(400, "El lado debe ser L, R o vacío.")
    code = (body.part_code or "").strip() or None
    base = code.rsplit("-", 1)[0] if code and side and \
        code.upper().endswith(("-L", "-R")) else code

    row = run("""INSERT INTO item (sku, part_code, base_code, side, description,
                   price_usd, product_type, make, model, year_text, nickname)
                 VALUES ('DEPO-' || lpad(nextval('item_item_id_seq')::text,5,'0'),
                   %s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                 RETURNING item_id, sku""",
              (code, base, side, body.description.strip(), body.price_usd,
               _clean(body.product_type), _clean(body.make), _clean(body.model),
               _clean(body.year_text), _clean(body.nickname)),
              actor=user["name"])[0]

    # Seed aliases from the description AND the nickname, so "CHANCHO" finds it.
    for alias in filter(None, [body.description.strip(), _clean(body.nickname)]):
        run("""INSERT INTO item_alias (item_id, alias, source) VALUES (%s,%s,'manual')
               ON CONFLICT (item_id, alias) DO NOTHING""", (row["item_id"], alias))
    return row


class ItemPatch(BaseModel):
    description: str | None = None
    part_code: str | None = None
    price_usd: float | None = None
    is_active: bool | None = None
    product_type: str | None = None
    make: str | None = None
    model: str | None = None
    year_text: str | None = None
    nickname: str | None = None


@app.patch("/api/items/{item_id}")
async def update_item(item_id: int, request: Request):
    """Update an item. Works from the raw JSON body so no field gets silently
    filtered by Pydantic before reaching the SQL."""
    user = require(request, "admin")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Cuerpo JSON inválido.")
    if not isinstance(body, dict):
        raise HTTPException(400, "Se esperaba un objeto.")

    print(f"PATCH item {item_id} body: {body}")  # visible in Railway logs

    allowed = {"description", "part_code", "price_usd", "is_active",
               "product_type", "make", "model", "year_text", "nickname"}
    sets, vals = [], []
    for field in allowed:
        if field not in body:
            continue
        value = body[field]
        if field == "price_usd":
            if value is None or value == "":
                continue
            try:
                value = float(value)
            except (TypeError, ValueError):
                raise HTTPException(400, "El precio debe ser un número.")
        elif field == "is_active":
            value = bool(value)
        else:
            if value is None:
                continue
            value = _clean(str(value))
            if value is None:
                continue
        sets.append(f"{field} = %s")
        vals.append(value)

    if not sets:
        raise HTTPException(400, f"Nada que cambiar. Recibí: {list(body.keys())}")

    vals.append(item_id)
    row = run(f"UPDATE item SET {', '.join(sets)} WHERE item_id = %s "
              f"RETURNING item_id, description, part_code, price_usd, is_active",
              tuple(vals), actor=user["name"])
    if not row:
        raise HTTPException(404, "Producto no encontrado.")

    # Seed searchable aliases for the description and nickname if updated.
    for field in ("description", "nickname"):
        alias = body.get(field)
        if alias:
            alias = str(alias).strip()
            if alias:
                run("""INSERT INTO item_alias (item_id, alias, source)
                       VALUES (%s,%s,'manual')
                       ON CONFLICT (item_id, alias) DO NOTHING""",
                    (item_id, alias))
    return row[0]


class Move(BaseModel):
    item_id: int
    branch_id: int
    qty_delta: int
    reason: str
    note: str | None = None


ALLOWED = {"purchase", "sale", "transfer_in", "transfer_out", "adjustment", "defect"}


@app.post("/api/stock/move")
def move_stock(body: Move, request: Request):
    user = require(request)
    if body.qty_delta == 0:
        raise HTTPException(400, "La cantidad no puede ser cero.")
    if body.reason not in ALLOWED:
        raise HTTPException(400, "Motivo no válido.")
    current = run("""SELECT coalesce(sum(qty_delta),0) AS q FROM stock_movement
                     WHERE item_id=%s AND branch_id=%s AND condition='good'""",
                  (body.item_id, body.branch_id))[0]["q"]
    if current + body.qty_delta < 0:
        raise HTTPException(400, f"Quedan {current} unidades; no se puede "
                                 f"descontar {abs(body.qty_delta)}.")
    rate = current_rate()["rate"]
    # On a sale, freeze price_usd and the rate so the boliviano value is fixed.
    run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                   price_usd, fx_rate, note, created_by)
           SELECT %s,%s,%s,%s,
                  CASE WHEN %s='sale' THEN price_usd END,
                  CASE WHEN %s='sale' THEN %s END,
                  %s,%s
           FROM item WHERE item_id=%s""",
        (body.item_id, body.branch_id, body.qty_delta, body.reason,
         body.reason, body.reason, rate, body.note, user["name"], body.item_id))
    return {"ok": True, "qty": current + body.qty_delta}


def _clean(s):
    if s is None:
        return None
    s = s.strip()
    return s or None
