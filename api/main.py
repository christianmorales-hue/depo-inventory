"""
DEPO - stock availability and management.

Run it:
    pip install fastapi uvicorn "psycopg[binary]"
    export DEPO_SECRET="something-long-and-random"
    export DEPO_PASSWORD="clave-mostrador"
    export DEPO_ADMIN_PASSWORD="clave-gerencia"
    uvicorn api.main:app --reload --port 8000

Two roles:
    staff  - search, and move stock in and out of branches
    admin  - everything staff can do, plus prices, items and branches

Nothing is ever deleted. Items and branches are deactivated, which hides them
from search while keeping their history intact.
"""
import hashlib
import hmac
import os
import secrets
import time

import psycopg
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
from api.page import PAGE

DB_URL = os.environ.get("DATABASE_URL", "postgresql://depo:depo@localhost:5433/depo")
SECRET = os.environ.get("DEPO_SECRET", "dev-only-change-me").encode()
PASSWORDS = {
    "staff": os.environ.get("DEPO_PASSWORD", "mostrador"),
    "admin": os.environ.get("DEPO_ADMIN_PASSWORD", "gerencia"),
}
SESSION_HOURS = 12
PBKDF2_ROUNDS = 200_000
COOKIE = "depo_session"

app = FastAPI(title="DEPO")

@app.middleware("http")
async def no_cache(request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    return response

# ----------------------------------------------------------------- database
def run(sql, params=(), actor=None):
    """Execute a statement. `actor` is exposed to triggers as app.actor."""
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        if actor:
            cur.execute("SELECT set_config('app.actor', %s, false)", (actor,))
        cur.execute(sql, params)
        if cur.description is None:
            return []
        cols = [c.name for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


# --------------------------------------------------------------------- auth
def sign(payload: str) -> str:
    return hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()[:32]


def make_token(name: str, role: str) -> str:
    payload = f"{name}|{role}|{int(time.time()) + SESSION_HOURS * 3600}"
    return f"{payload}|{sign(payload)}"


def read_token(token: str | None):
    if not token:
        return None
    try:
        name, role, expires, sig = token.rsplit("|", 3)
    except ValueError:
        return None
    if not hmac.compare_digest(sig, sign(f"{name}|{role}|{expires}")):
        return None
    if int(expires) < time.time():
        return None
    return {"name": name, "role": role}


def who(request: Request):
    return read_token(request.cookies.get(COOKIE))


def require(request: Request, role: str = "staff"):
    user = who(request)
    if not user:
        raise HTTPException(401, "Inicie sesión para continuar.")
    if role == "admin" and user["role"] != "admin":
        raise HTTPException(403, "Esta acción necesita la clave de gerencia.")
    return user


def hash_password(password: str) -> str:
    """PBKDF2-SHA256. The password itself is never stored anywhere."""
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    return f"pbkdf2_sha256${PBKDF2_ROUNDS}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, rounds, salt_hex, hash_hex = stored.split("$")
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(),
                                 bytes.fromhex(salt_hex), int(rounds))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(dk.hex(), hash_hex)


class Login(BaseModel):
    username: str
    password: str


@app.post("/api/login")
def login(body: Login, response: Response):
    username = body.username.strip().lower()[:40]
    if len(username) < 2 or len(body.password) < 4:
        raise HTTPException(400, "Usuario y clave son obligatorios.")

    rows = run("""SELECT user_id, username, full_name, password_hash, role,
                         is_active, must_change
                  FROM app_user WHERE lower(username) = %s""", (username,))

    # First run: nobody exists yet, so whoever knows DEPO_ADMIN_PASSWORD
    # claims the first admin account. After that this branch never fires.
    if not rows and not run("SELECT 1 FROM app_user LIMIT 1"):
        if not hmac.compare_digest(body.password, PASSWORDS["admin"]):
            raise HTTPException(401, "Usuario o clave incorrectos.")
        run("""INSERT INTO app_user (username, full_name, password_hash, role,
                                     created_by)
               VALUES (%s, %s, %s, 'admin', 'primer arranque')""",
            (username, username.title(), hash_password(body.password)))
        rows = run("""SELECT user_id, username, full_name, password_hash, role,
                             is_active, must_change
                      FROM app_user WHERE lower(username) = %s""", (username,))

    if not rows:
        raise HTTPException(401, "Usuario o clave incorrectos.")
    u = rows[0]
    if not verify_password(body.password, u["password_hash"]):
        raise HTTPException(401, "Usuario o clave incorrectos.")
    if not u["is_active"]:
        raise HTTPException(403, "Esta cuenta está desactivada.")

    run("UPDATE app_user SET last_login = now() WHERE user_id = %s", (u["user_id"],))
    response.set_cookie(COOKIE, make_token(u["full_name"], u["role"]), httponly=True,
                        samesite="lax", max_age=SESSION_HOURS * 3600)
    return {"name": u["full_name"], "role": u["role"],
            "must_change": u["must_change"]}


@app.post("/api/logout")
def logout(response: Response):
    response.delete_cookie(COOKIE)
    return {"ok": True}


@app.get("/api/me")
def me(request: Request):
    return who(request) or {}


# ------------------------------------------------------------------ reading
SEARCH_SQL = """
SELECT i.item_id, i.sku, i.part_code, i.side, i.description, i.unit_price,
       i.is_active, i.photo_path,
       coalesce(json_agg(json_build_object('branch_id', b.branch_id, 'qty', s.qty))
                FILTER (WHERE b.branch_id IS NOT NULL), '[]') AS stock
FROM search_items(%s, 40) r
JOIN item i ON i.item_id = r.item_id
LEFT JOIN stock_on_hand s ON s.item_id = i.item_id AND s.condition = 'good'
LEFT JOIN branch b ON b.branch_id = s.branch_id AND b.is_active
GROUP BY i.item_id, r.score
ORDER BY r.score DESC
"""

RECENT_SQL = SEARCH_SQL.replace("FROM search_items(%s, 40) r\nJOIN item i ON i.item_id = r.item_id",
                                "FROM item i").replace("ORDER BY r.score DESC",
                                                       "ORDER BY i.created_at DESC, i.item_id DESC LIMIT 40"
                                                       ).replace(", r.score", "")


@app.get("/api/branches")
def branches(request: Request):
    show_all = who(request) and who(request)["role"] == "admin"
    return run("SELECT branch_id, code, name, is_active, is_real FROM branch"
               + ("" if show_all else " WHERE is_active")
               + " ORDER BY is_real DESC, name")


@app.get("/api/search")
def search(q: str = ""):
    rows = run(SEARCH_SQL, (q.strip(),)) if len(q.strip()) >= 2 else run(RECENT_SQL)
    for r in rows:
        r["unit_price"] = float(r["unit_price"]) if r["unit_price"] is not None else None
    return JSONResponse(rows)


@app.get("/api/item/{item_id}/history")
def history(item_id: int, request: Request):
    require(request)
    return run("""SELECT m.occurred_at, b.name AS branch, m.qty_delta, m.reason,
                         m.note, m.created_by
                  FROM stock_movement m JOIN branch b USING (branch_id)
                  WHERE m.item_id = %s ORDER BY m.occurred_at DESC LIMIT 40""",
               (item_id,))


# ------------------------------------------------------------- staff writes
class Move(BaseModel):
    item_id: int
    branch_id: int
    qty_delta: int
    reason: str
    note: str | None = None


ALLOWED_REASONS = {"purchase", "sale", "transfer_in", "transfer_out",
                   "adjustment", "defect"}


@app.post("/api/stock/move")
def move_stock(body: Move, request: Request):
    user = require(request)
    if body.qty_delta == 0:
        raise HTTPException(400, "La cantidad no puede ser cero.")
    if body.reason not in ALLOWED_REASONS:
        raise HTTPException(400, "Motivo no válido.")
    current = run("""SELECT coalesce(sum(qty_delta), 0) AS q FROM stock_movement
                     WHERE item_id = %s AND branch_id = %s AND condition = 'good'""",
                  (body.item_id, body.branch_id))[0]["q"]
    if current + body.qty_delta < 0:
        raise HTTPException(400,
                            f"Quedan {current} unidades; no se puede descontar "
                            f"{abs(body.qty_delta)}.")
    run("""INSERT INTO stock_movement (item_id, branch_id, qty_delta, reason,
                                       unit_price, note, created_by)
           SELECT %s, %s, %s, %s,
                  CASE WHEN %s = 'sale' THEN unit_price END, %s, %s
           FROM item WHERE item_id = %s""",
        (body.item_id, body.branch_id, body.qty_delta, body.reason,
         body.reason, body.note, user["name"], body.item_id))
    return {"ok": True, "qty": current + body.qty_delta}


class AliasIn(BaseModel):
    item_id: int
    alias: str


@app.post("/api/alias")
def remember_alias(a: AliasIn):
    if len(a.alias.strip()) < 3:
        return {"saved": False}
    run("""INSERT INTO item_alias (item_id, alias, source) VALUES (%s, %s, 'search')
           ON CONFLICT (item_id, alias) DO NOTHING""", (a.item_id, a.alias.strip()))
    return {"saved": True}


# ------------------------------------------------------------- admin writes
class ItemIn(BaseModel):
    description: str
    part_code: str | None = None
    side: str | None = None
    unit_price: float | None = None


@app.post("/api/items")
def create_item(body: ItemIn, request: Request):
    user = require(request, "admin")
    if len(body.description.strip()) < 3:
        raise HTTPException(400, "La descripción es obligatoria.")
    side = (body.side or "").upper() or None
    if side not in (None, "L", "R"):
        raise HTTPException(400, "El lado debe ser L, R o vacío.")
    code = (body.part_code or "").strip() or None
    base = code.rsplit("-", 1)[0] if code and side and code.upper().endswith(
        ("-L", "-R")) else code
    row = run("""INSERT INTO item (sku, part_code, base_code, side, description,
                                   unit_price)
                 VALUES ('DEPO-' || lpad(nextval('item_item_id_seq')::text, 5, '0'),
                         %s, %s, %s, %s, %s)
                 RETURNING item_id, sku""",
              (code, base, side, body.description.strip(), body.unit_price),
              actor=user["name"])[0]
    run("INSERT INTO item_alias (item_id, alias, source) VALUES (%s, %s, 'manual')",
        (row["item_id"], body.description.strip()))
    return row


class ItemPatch(BaseModel):
    description: str | None = None
    part_code: str | None = None
    unit_price: float | None = None
    is_active: bool | None = None


            (item_id, body.description.strip()))
    return row[0]


class BranchIn(BaseModel):
    code: str | None = None
    name: str
    is_active: bool | None = None


@app.post("/api/branches")
def create_branch(body: BranchIn, request: Request):
    require(request, "admin")
    code = (body.code or body.name).strip().upper().replace(" ", "_")[:20]
    if not body.name.strip():
        raise HTTPException(400, "El nombre es obligatorio.")
    if run("SELECT 1 FROM branch WHERE code = %s", (code,)):
        raise HTTPException(400, f"Ya existe una sucursal con el código {code}.")
    return run("""INSERT INTO branch (code, name) VALUES (%s, %s)
                  RETURNING branch_id, code, name, is_active""",
               (code, body.name.strip()))[0]


@app.patch("/api/branches/{branch_id}")
def update_branch(branch_id: int, body: BranchIn, request: Request):
    require(request, "admin")
    sets, vals = [], []
    if body.name:
        sets.append("name = %s"); vals.append(body.name.strip())
    if body.is_active is not None:
        sets.append("is_active = %s"); vals.append(body.is_active)
    if not sets:
        raise HTTPException(400, "Nada que cambiar.")
    vals.append(branch_id)
    return run(f"UPDATE branch SET {', '.join(sets)} WHERE branch_id = %s "
               f"RETURNING branch_id, code, name, is_active", tuple(vals))[0]


@app.get("/", response_class=HTMLResponse)
def home():
    return PAGE

from api import features
from api import users
from api import photos
from api import reports_archive
from api import pricing
from api import overrides
from api import quotes