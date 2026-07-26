"""
Cotizaciones (quotes).

    pip install reportlab

Add to the bottom of api/main.py, after the pricing/overrides lines:

    from api import quotes  # noqa: E402

Company details for the PDF header come from the app_setting table so they
can be edited without a code change. To set them once:

    UPDATE app_setting SET value = '73556438'
      WHERE key = 'store_phone';
    INSERT INTO app_setting (key, value)
      VALUES ('store_nit', '222222222')
      ON CONFLICT (key) DO UPDATE SET value = excluded.value;
"""
import io
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from reportlab.lib import colors
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph

from api.main import app, require, run
from api.pricing import current_rate, usd_to_bob, round_bob


# ------------------------------------------------------------ shop settings
def setting(key, default=""):
    r = run("SELECT value FROM app_setting WHERE key = %s", (key,))
    return r[0]["value"] if r else default


def shop_info():
    return {
        "name":  setting("store_name",  "DEPO autolamp"),
        "nit":   setting("store_nit",   ""),
        "phone": setting("store_phone", ""),
    }


# ---------------------------------------------------------------- endpoints
class QuoteLineIn(BaseModel):
    item_id: int
    qty: int


class QuoteIn(BaseModel):
    customer: str
    customer_nit: str | None = None
    customer_phone: str | None = None
    note: str | None = None
    valid_days: int = 3
    lines: list[QuoteLineIn]


@app.post("/api/quotes")
def create_quote(body: QuoteIn, request: Request):
    user = require(request)
    if not body.customer.strip():
        raise HTTPException(400, "El nombre del cliente es obligatorio.")
    if not body.lines:
        raise HTTPException(400, "Agregue al menos un producto.")

    fx = current_rate()
    if not fx["rate"]:
        raise HTTPException(400, "No hay tipo de cambio disponible.")

    # Load every requested item once, in a single query.
    ids = [l.item_id for l in body.lines]
    rows = run("""SELECT item_id, part_code, description, side, price_usd
                  FROM item WHERE item_id = ANY(%s)""", (ids,))
    by_id = {r["item_id"]: r for r in rows}
    for line in body.lines:
        it = by_id.get(line.item_id)
        if not it:
            raise HTTPException(400, f"Producto {line.item_id} no encontrado.")
        if it["price_usd"] is None:
            raise HTTPException(400,
                f"El producto '{it['description']}' no tiene precio configurado.")
        if line.qty <= 0:
            raise HTTPException(400, "La cantidad debe ser mayor a cero.")

    number = run("SELECT nextval('quote_number_seq') AS n")[0]["n"]
    q = run("""INSERT INTO quote (quote_number, customer, customer_nit,
                     customer_phone, note, fx_rate, fx_source, valid_days,
                     created_by)
                 VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                 RETURNING quote_id, quote_number, created_at, valid_days""",
              (number, body.customer.strip(), body.customer_nit, body.customer_phone,
               body.note, fx["rate"], fx["source"], body.valid_days,
               user["name"]))[0]

    for i, line in enumerate(body.lines, 1):
        it = by_id[line.item_id]
        usd = float(it["price_usd"])
        bob = usd_to_bob(usd, fx["rate"])
        run("""INSERT INTO quote_line (quote_id, line_no, item_id, part_code,
                     description, side, qty, price_usd, price_bob)
                 VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (q["quote_id"], i, line.item_id, it["part_code"], it["description"],
             it["side"], line.qty, usd, bob))

    return {"quote_id": q["quote_id"], "quote_number": q["quote_number"]}


@app.get("/api/quotes")
def list_quotes(request: Request):
    require(request)
    rows = run("SELECT * FROM v_quotes LIMIT 100")
    for r in rows:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()[:10] if k in ("fecha",) else v.isoformat()[:16]
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    return rows


@app.get("/api/quotes/{quote_id}")
def get_quote(quote_id: int, request: Request):
    require(request)
    q = run("SELECT * FROM quote WHERE quote_id = %s", (quote_id,))
    if not q:
        raise HTTPException(404, "Cotización no encontrada.")
    lines = run("SELECT * FROM quote_line WHERE quote_id = %s ORDER BY line_no",
                (quote_id,))
    for r in [q[0]] + lines:
        for k, v in r.items():
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
    return {"quote": q[0], "lines": lines}


# ---------------------------------------------------------------------- PDF
def bs(n):
    return f"{n:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def build_pdf(quote_id: int, doc_type: str = "cotizacion") -> bytes:
    """doc_type: 'cotizacion' or 'nota' - only changes the title and footer."""
    q = run("SELECT * FROM quote WHERE quote_id = %s", (quote_id,))[0]
    lines = run("SELECT * FROM quote_line WHERE quote_id = %s ORDER BY line_no",
                (quote_id,))

    def as_float(d, keys):
        for k in keys:
            if d.get(k) is not None:
                d[k] = float(d[k])
    as_float(q, ("fx_rate",))
    for line in lines:
        as_float(line, ("price_usd", "price_bob"))

    shop = shop_info()
    valid_until = q["created_at"] + timedelta(days=q["valid_days"])
    is_nota = doc_type == "nota"
    title = "NOTA DE VENTA" if is_nota else "COTIZACIÓN"
    number_label = "Nº"

    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=LETTER)
    W, H = LETTER
    M = 15 * mm
    y = H - M

    # ---- header row: logo on the left, shop meta on the right -----------
    logo = Path("media/logo.png")
    if logo.is_file():
        try:
            c.drawImage(str(logo), M, y - 24 * mm, width=45 * mm, height=24 * mm,
                        preserveAspectRatio=True, mask="auto")
        except Exception:
            pass

    x_r = W - M
    c.setFont("Helvetica", 10)
    if shop["nit"]:
        c.drawRightString(x_r, y - 6 * mm, f"NIT: {shop['nit']}")
    if shop["phone"]:
        c.drawRightString(x_r, y - 11 * mm, f"Tel: {shop['phone']}")

    # ---- big centered title --------------------------------------------
    y -= 30 * mm
    c.setFont("Helvetica-Bold", 26)
    c.drawCentredString(W / 2, y, title)
    y -= 7 * mm
    c.setFont("Helvetica", 11)
    c.drawCentredString(W / 2, y, f"{number_label} {q['quote_number']:04d}")
    y -= 5 * mm
    c.setFont("Helvetica", 9)
    c.setFillColor(colors.HexColor("#6B757C"))
    c.drawCentredString(W / 2, y, f"Fecha: {q['created_at'].strftime('%Y-%m-%d')}"
                                  f"     TC: 1 $ = {q['fx_rate']} Bs")
    if not is_nota:
        y -= 5 * mm
        c.drawCentredString(W / 2, y,
                            f"Válida hasta: {valid_until.strftime('%Y-%m-%d')} "
                            f"({q['valid_days']} días)")
    c.setFillColor(colors.black)

    # ---- CLIENTE block ---------------------------------------------------
    y -= 12 * mm
    c.setFillColor(colors.HexColor("#F1F4F5"))
    c.rect(M, y - 22 * mm, W - 2 * M, 22 * mm, stroke=0, fill=1)
    c.setFillColor(colors.black)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(M + 3 * mm, y - 5 * mm, "CLIENTE")
    c.setFont("Helvetica", 11)
    c.drawString(M + 3 * mm, y - 11 * mm, q["customer"])
    c.setFont("Helvetica", 9)
    bits = []
    if q["customer_nit"]:   bits.append(f"NIT: {q['customer_nit']}")
    if q["customer_phone"]: bits.append(f"Tel: {q['customer_phone']}")
    if bits:
        c.drawString(M + 3 * mm, y - 17 * mm, "   ".join(bits))

    # ---- lines table (no CÓDIGO column) ---------------------------------
    y = y - 30 * mm
    # columns: description | unit price | qty | total
    col = [M, W - M - 82 * mm, W - M - 52 * mm, W - M - 25 * mm, W - M]
    header_h = 7 * mm

    c.setFillColor(colors.HexColor("#14181B"))
    c.rect(M, y - header_h, W - 2 * M, header_h, stroke=0, fill=1)
    c.setFillColor(colors.white)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(col[0] + 2 * mm, y - 5 * mm, "DESCRIPCIÓN")
    c.drawRightString(col[2] - 2 * mm, y - 5 * mm, "P. UNIT. (Bs)")
    c.drawRightString(col[3] - 2 * mm, y - 5 * mm, "CANT.")
    c.drawRightString(col[4] - 2 * mm, y - 5 * mm, "TOTAL (Bs)")
    c.setFillColor(colors.black)

    y -= header_h
    body_style = ParagraphStyle("body", fontName="Helvetica", fontSize=9,
                                leading=11)
    subtotal = 0.0
    for i, line in enumerate(lines):
        desc = line["description"] + (f" ({line['side']})" if line["side"] else "")
        para = Paragraph(desc, body_style)
        w_desc = col[1] - col[0] - 4 * mm
        _, h = para.wrap(w_desc, 40 * mm)
        row_h = max(7 * mm, h + 3 * mm)

        if i % 2 == 1:
            c.setFillColor(colors.HexColor("#F8FAFB"))
            c.rect(M, y - row_h, W - 2 * M, row_h, stroke=0, fill=1)
            c.setFillColor(colors.black)

        c.setFont("Helvetica", 9)
        para.drawOn(c, col[0] + 2 * mm, y - row_h + (row_h - h) / 2)
        c.drawRightString(col[2] - 2 * mm, y - 5 * mm, bs(line["price_bob"]))
        c.drawRightString(col[3] - 2 * mm, y - 5 * mm, str(line["qty"]))
        total = line["price_bob"] * line["qty"]
        subtotal += total
        c.drawRightString(col[4] - 2 * mm, y - 5 * mm, bs(total))
        y -= row_h

        if y < 55 * mm:
            c.showPage()
            y = H - M

    # ---- totals box ------------------------------------------------------
    y -= 4 * mm
    c.setStrokeColor(colors.HexColor("#D3DADE"))
    c.line(M, y, W - M, y)
    y -= 8 * mm
    c.setFont("Helvetica-Bold", 12)
    c.drawRightString(W - M - 40 * mm, y, "TOTAL:")
    c.drawRightString(W - M - 2 * mm, y, f"{bs(subtotal)} Bs")
    c.setFont("Helvetica", 8)
    c.setFillColor(colors.HexColor("#6B757C"))
    c.drawRightString(W - M - 2 * mm, y - 5 * mm,
                      f"(≈ $ {subtotal / float(q['fx_rate']):,.2f})".replace(",", "."))
    c.setFillColor(colors.black)

    # ---- footer ----------------------------------------------------------
    c.setFont("Helvetica-Oblique", 9)
    c.setFillColor(colors.HexColor("#6B757C"))
    if is_nota:
        c.drawString(M, 30 * mm, "Nota de venta - documento no fiscal.")
        c.drawString(M, 25 * mm,
                     "Los productos han salido del inventario en la sucursal correspondiente.")
        # Cancellation policy, split across two lines to fit the page width.
        c.drawString(M, 20 * mm,
                     "La gerencia se reserva el derecho a aceptar o rechazar la anulación "
                     "de la orden de venta.")
        c.drawString(M, 16 * mm,
                     "La solicitud debe ser realizada en un plazo de 24 h.")
    else:
        c.drawString(M, 25 * mm,
                     f"Cotización válida por {q['valid_days']} días desde la fecha de emisión.")
        c.drawString(M, 20 * mm,
                     "Precios sujetos a cambio sin previo aviso una vez vencido el plazo.")
    c.drawString(M, 15 * mm,
                 f"Emitida por {q['created_by'] or ''} · Gracias por su preferencia.")

    c.showPage()
    c.save()
    return buf.getvalue()


@app.get("/api/quotes/{quote_id}/pdf")
def download_pdf(quote_id: int, request: Request):
    require(request)
    q = run("SELECT quote_number, customer FROM quote WHERE quote_id = %s",
            (quote_id,))
    if not q:
        raise HTTPException(404, "Cotización no encontrada.")
    pdf = build_pdf(quote_id)

    if not pdf.startswith(b"%PDF-") or b"%%EOF" not in pdf[-1024:]:
        raise HTTPException(500, "El PDF salió dañado. Intente de nuevo.")

    n = q[0]["quote_number"]
    import re
    slug = re.sub(r"[^A-Za-z0-9]+", "_",
                  q[0]["customer"] or "").strip("_").lower()[:40] or "cliente"
    filename = f"cotizacion_{n:04d}_{slug}.pdf"

    return Response(pdf, media_type="application/pdf",
                    headers={
                        "Content-Disposition":
                            f'attachment; filename="{filename}"',
                        "Content-Length": str(len(pdf)),
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                    })


# ================================================================ NOTA DE VENTA
# A sale note is a quote turned into an actual sale: each line becomes a
# stock movement, and the units come out of the branch chosen by the clerk.

class SaleLine(BaseModel):
    item_id: int
    branch_id: int
    qty: int
    discount: float = 0        # Bs off per unit, optional


class SaleIn(BaseModel):
    customer: str
    customer_nit: str | None = None
    customer_phone: str | None = None
    note: str | None = None
    lines: list[SaleLine]


@app.post("/api/sales")
def create_sale(body: SaleIn, request: Request):
    user = require(request)
    if not body.customer.strip():
        raise HTTPException(400, "El nombre del cliente es obligatorio.")
    if not body.lines:
        raise HTTPException(400, "Agregue al menos un producto.")

    fx = current_rate()
    if not fx["rate"]:
        raise HTTPException(400, "No hay tipo de cambio disponible.")

    ids = list({l.item_id for l in body.lines})
    items = {r["item_id"]: r for r in run(
        "SELECT item_id, part_code, description, side, price_usd "
        "FROM item WHERE item_id = ANY(%s)", (ids,))}

    # Check stock per (item, branch) before touching anything. Refuse the
    # whole sale if any line is short - a partial sale would be worse.
    from collections import defaultdict
    need = defaultdict(int)
    for l in body.lines:
        it = items.get(l.item_id)
        if not it:
            raise HTTPException(400, f"Producto {l.item_id} no encontrado.")
        if it["price_usd"] is None:
            raise HTTPException(400,
                f"'{it['description']}' no tiene precio configurado.")
        if l.qty <= 0:
            raise HTTPException(400, "Todas las cantidades deben ser mayores a cero.")
        need[(l.item_id, l.branch_id)] += l.qty

    for (item_id, branch_id), qty in need.items():
        have = run("""SELECT coalesce(sum(qty_delta), 0) AS q
                      FROM stock_movement WHERE item_id = %s AND branch_id = %s
                      AND condition = 'good'""", (item_id, branch_id))[0]["q"]
        if have < qty:
            it = items[item_id]
            b = run("SELECT name FROM branch WHERE branch_id = %s",
                    (branch_id,))[0]["name"]
            raise HTTPException(400,
                f"Solo hay {have} de '{it['description']}' en {b}; "
                f"se piden {qty}.")

    # Create a quote row (reusing the table since the shape matches) and
    # the stock_movement rows in one transaction-like pass.
    number = run("SELECT nextval('quote_number_seq') AS n")[0]["n"]
    q = run("""INSERT INTO quote (quote_number, customer, customer_nit,
                     customer_phone, note, fx_rate, fx_source, valid_days,
                     created_by)
                 VALUES (%s,%s,%s,%s,%s,%s,%s,0,%s)
                 RETURNING quote_id, quote_number""",
              (number, body.customer.strip(), body.customer_nit, body.customer_phone,
               (body.note or "") + " [NOTA_DE_VENTA]",
               fx["rate"], fx["source"], user["name"]))[0]

    for i, line in enumerate(body.lines, 1):
        it = items[line.item_id]
        usd = float(it["price_usd"])
        bob = usd_to_bob(usd, fx["rate"])
        disc = max(0.0, float(line.discount or 0))
        net_bob = round_bob(max(0.0, bob - disc))   # per-unit price after discount, to 0.50
        run("""INSERT INTO quote_line (quote_id, line_no, item_id, part_code,
                     description, side, qty, price_usd, price_bob, discount_bob)
                 VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (q["quote_id"], i, line.item_id, it["part_code"], it["description"],
             it["side"], line.qty, usd, net_bob, disc))
        # Record the sale in the ledger at the net (discounted) boliviano price,
        # so revenue reports reflect what the customer actually paid.
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                     price_usd, fx_rate, unit_price, note, created_by)
                 VALUES (%s, %s, %s, 'sale', %s, %s, %s, %s, %s)""",
            (line.item_id, line.branch_id, -line.qty, usd, fx["rate"], net_bob,
             f"nota de venta #{q['quote_number']}", user["name"]))

    return {"sale_id": q["quote_id"], "sale_number": q["quote_number"]}


@app.post("/api/sales/{sale_id}/cancel")
def cancel_sale(sale_id: int, request: Request):
    """Cancel a nota de venta: reverse every stock movement so inventory is
    restored, and stamp the nota as cancelled. Reports self-correct because
    the reversing movements net the sale to zero."""
    user = require(request)
    q = run("SELECT quote_number, cancelled_at FROM quote WHERE quote_id = %s "
            "AND note LIKE '%%[NOTA_DE_VENTA]%%'", (sale_id,))
    if not q:
        raise HTTPException(404, "Nota de venta no encontrada.")
    if q[0]["cancelled_at"]:
        raise HTTPException(400, "Esta nota ya fue anulada.")

    number = q[0]["quote_number"]
    lines = run("""SELECT item_id, qty, price_usd, price_bob
                   FROM quote_line WHERE quote_id = %s""", (sale_id,))
    # Find the branch each original sale movement came from, to return stock
    # to the right place.
    for ln in lines:
        mv = run("""SELECT branch_id, fx_rate FROM stock_movement
                    WHERE item_id = %s AND reason = 'sale'
                      AND note = %s ORDER BY movement_id LIMIT 1""",
                 (ln["item_id"], f"nota de venta #{number}"))
        branch_id = mv[0]["branch_id"] if mv else None
        fx_rate = mv[0]["fx_rate"] if mv else None
        if branch_id is None:
            continue
        # Reverse: put the units back with a positive movement, reason 'sale'
        # so it cancels the original in every sales view.
        run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                     price_usd, fx_rate, unit_price, note, created_by)
                 VALUES (%s, %s, %s, 'sale', %s, %s, %s, %s, %s)""",
            (ln["item_id"], branch_id, ln["qty"], ln["price_usd"], fx_rate,
             ln["price_bob"], f"anulación nota #{number}", user["name"]))

    run("UPDATE quote SET cancelled_at = now(), cancelled_by = %s "
        "WHERE quote_id = %s", (user["name"], sale_id))
    return {"ok": True, "sale_number": number}


@app.get("/api/sales")
def list_sales(request: Request):
    require(request)
    rows = run("""SELECT v.*, q.cancelled_at, q.cancelled_by
                  FROM v_quotes v
                  JOIN quote q USING (quote_id)
                  WHERE q.note LIKE '%%[NOTA_DE_VENTA]%%'
                  ORDER BY v.quote_number DESC
                  LIMIT 100""")
    for r in rows:
        for k, v in list(r.items()):
            if hasattr(v, "isoformat"):
                r[k] = v.isoformat()[:10] if k == "fecha" else v.isoformat()
            elif v is not None and type(v).__name__ == "Decimal":
                r[k] = float(v)
        r["cancelled"] = r.get("cancelled_at") is not None
    return rows


@app.get("/api/sales/{sale_id}/pdf")
def download_sale_pdf(sale_id: int, request: Request):
    require(request)
    q = run("SELECT quote_number, customer FROM quote WHERE quote_id = %s",
            (sale_id,))
    if not q:
        raise HTTPException(404, "Nota de venta no encontrada.")
    pdf = build_pdf(sale_id, doc_type="nota")

    if not pdf.startswith(b"%PDF-") or b"%%EOF" not in pdf[-1024:]:
        raise HTTPException(500, "El PDF salió dañado. Intente de nuevo.")

    n = q[0]["quote_number"]
    import re
    slug = re.sub(r"[^A-Za-z0-9]+", "_",
                  q[0]["customer"] or "").strip("_").lower()[:40] or "cliente"
    filename = f"nota_venta_{n:04d}_{slug}.pdf"

    return Response(pdf, media_type="application/pdf",
                    headers={
                        "Content-Disposition":
                            f'attachment; filename="{filename}"',
                        "Content-Length": str(len(pdf)),
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                    })
