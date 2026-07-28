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

DB_URL = os.environ.get("DATABASE_URL", "postgresql://depo:depo@localhost:5433/depo")

# The signing secret protects every session token. In production it MUST be set.
# We only allow the weak dev fallback when running against a local database, so
# a misconfigured cloud deploy can never silently ship a guessable secret.
_secret_env = os.environ.get("DEPO_SECRET")
if not _secret_env:
    if "localhost" in DB_URL or "127.0.0.1" in DB_URL:
        _secret_env = "dev-only-change-me"
    else:
        raise RuntimeError(
            "DEPO_SECRET is not set. Refusing to start in production with a "
            "default signing secret. Set DEPO_SECRET to a long random value.")
SECRET = _secret_env.encode()
PASSWORDS = {
    "staff": os.environ.get("DEPO_PASSWORD", "mostrador"),
    "admin": os.environ.get("DEPO_ADMIN_PASSWORD", "gerencia"),
}
SESSION_HOURS = 12
PBKDF2_ROUNDS = 200_000
COOKIE = "depo_session"

app = FastAPI(title="DEPO")


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
    # secure=True so the session cookie is only ever sent over HTTPS. We keep it
    # off for local http dev (secure cookies won't transmit over plain http).
    is_prod = "localhost" not in DB_URL and "127.0.0.1" not in DB_URL
    response.set_cookie(COOKIE, make_token(u["full_name"], u["role"]), httponly=True,
                        samesite="lax", secure=is_prod, max_age=SESSION_HOURS * 3600)
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
       i.is_active,
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
                                       note, created_by)
           VALUES (%s, %s, %s, %s, %s, %s)""",
        (body.item_id, body.branch_id, body.qty_delta, body.reason,
         body.note, user["name"]))
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


@app.patch("/api/items/{item_id}")
def update_item(item_id: int, body: ItemPatch, request: Request):
    user = require(request, "admin")
    sets, vals = [], []
    for field in ("description", "part_code", "unit_price", "is_active"):
        value = getattr(body, field)
        if value is not None:
            sets.append(f"{field} = %s")
            vals.append(value)
    if not sets:
        raise HTTPException(400, "Nada que cambiar.")
    vals.append(item_id)
    row = run(f"UPDATE item SET {', '.join(sets)} WHERE item_id = %s "
              f"RETURNING item_id, description, part_code, unit_price, is_active",
              tuple(vals), actor=user["name"])
    if body.description:
        run("""INSERT INTO item_alias (item_id, alias, source) VALUES (%s, %s, 'manual')
               ON CONFLICT (item_id, alias) DO NOTHING""",
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


PAGE = r"""
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DEPO - existencias</title>
<style>
  :root{--bg:#EDF0F2;--card:#FFF;--ink:#14181B;--muted:#6B757C;--line:#D3DADE;
        --have:#0F6B3F;--none:#A7B0B6;--amber:#B45309;--focus:#1C5FA8;--warn:#A8322A;}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
       font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
  .wrap{max-width:1000px;margin:0 auto;padding:20px 16px 80px}
  header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:18px}
  h1{font-size:19px;letter-spacing:.14em;text-transform:uppercase;margin:0}
  .sub{color:var(--muted);font-size:13px}
  .spacer{flex:1}

  input,select,button{font:inherit;color:inherit}
  input,select{padding:9px 11px;border:1px solid var(--line);border-radius:8px;
               background:var(--card)}
  input:focus,select:focus,button:focus-visible{outline:2px solid var(--focus);
               outline-offset:1px}
  #q{width:100%;padding:15px 17px;font-size:19px;border-width:2px;border-radius:10px}
  .hint{color:var(--muted);font-size:13px;margin:9px 2px 18px}

  button{cursor:pointer;border:1px solid var(--line);background:var(--card);
         border-radius:8px;padding:9px 13px}
  button:hover{border-color:var(--focus)}
  button.primary{background:var(--ink);color:#fff;border-color:var(--ink)}
  button.danger{color:var(--warn)}
  button.link{border:none;background:none;padding:4px;color:var(--focus);
              text-decoration:underline}

  .grid{display:grid;gap:12px;align-items:center}
  .heads{padding:0 14px 7px;font-size:11px;letter-spacing:.1em;
         text-transform:uppercase;color:var(--muted)}
  .heads b:not(:nth-child(-n+2)){text-align:center;font-weight:inherit}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;
        margin-bottom:8px;overflow:hidden}
  .row{padding:11px 14px;width:100%;text-align:left;border:none;border-radius:0;
       background:none}
  .row:hover{background:#F6F8F9}
  .side{font:700 21px/1 ui-monospace,Menlo,monospace;text-align:center;padding:9px 0;
        border-radius:7px;background:#FBF0E2;color:var(--amber)}
  .side.no{background:#F1F4F5;color:var(--none);font-size:15px}
  .desc{font-weight:500}
  .code{font:13px ui-monospace,Menlo,monospace;color:var(--muted);margin-top:3px}
  .qty{text-align:center;font:600 20px/1 ui-monospace,Menlo,monospace;color:var(--have)}
  .qty.zero{color:var(--none);font-weight:400}
  .off{opacity:.5}

  .panel{border-top:1px solid var(--line);padding:14px;background:#F8FAFB}
  .panel h4{margin:0 0 9px;font-size:11px;letter-spacing:.1em;
            text-transform:uppercase;color:var(--muted)}
  .bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
  .bar:last-child{margin-bottom:0}
  .hist{font-size:13px;color:var(--muted);font-family:ui-monospace,Menlo,monospace}
  .hist div{padding:2px 0}
  .msg{font-size:13px;min-height:18px;margin-top:10px}
  .msg.bad{color:var(--warn)} .msg.good{color:var(--have)}
  .empty{color:var(--muted);padding:26px 4px}
  details{margin-top:26px;background:var(--card);border:1px solid var(--line);
          border-radius:10px;padding:14px}
  summary{cursor:pointer;font-size:12px;letter-spacing:.1em;text-transform:uppercase;
          color:var(--muted)}
  details .bar{margin-top:14px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>DEPO</h1><span class="sub">Existencias por sucursal</span>
    <span class="spacer"></span>
    <span id="session"></span>
  </header>

  <input id="q" autofocus autocomplete="off"
         placeholder="Buscar: espejo corola, 212-1592, farol asx...">
  <p class="hint">Escriba como quiera. Acentos y errores de tipeo no importan.</p>

  <div id="heads" class="grid heads" hidden></div>
  <div id="results"></div>
  <div id="admin"></div>
</div>

<script>
const $ = s => document.querySelector(s);
let user = {}, branches = [], rows = [], open = null, term = '';

const REASONS = [
  ['purchase',      1, 'Ingreso (compra)'],
  ['sale',         -1, 'Venta'],
  ['transfer_in',   1, 'Transferencia recibida'],
  ['transfer_out', -1, 'Transferencia enviada'],
  ['defect',       -1, 'Baja por defecto'],
  ['adjustment',    1, 'Corrección: sumar'],
  ['adjustment',   -1, 'Corrección: restar'],
];

const esc = s => String(s ?? '').replace(/[&<>"]/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

async function api(path, opts) {
  const res = await fetch(path, {headers:{'Content-Type':'application/json'}, ...opts});
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.detail || 'Error inesperado');
  return body;
}

// -------------------------------------------------------------------- boot
(async function start(){
  user = await api('/api/me');
  await loadBranches();
  drawSession();
  await search();
})();

async function loadBranches(){
  branches = (await api('/api/branches')).filter(b => b.is_real);
}

function cols(){
  return `44px minmax(0,1fr) ${branches.map(() => '78px').join(' ')}`;
}

// ----------------------------------------------------------------- session
function drawSession(){
  const el = $('#session');
  if (user.name) {
    el.innerHTML = `<span class="sub">${esc(user.name)} ·
      ${user.role === 'admin' ? 'gerencia' : 'mostrador'}</span>
      <button class="link" id="out">salir</button>`;
    $('#out').onclick = async () => {
      await api('/api/logout', {method:'POST'}); user = {}; drawSession(); draw(); drawAdmin();
    };
  } else {
    el.innerHTML = `<input id="nm" placeholder="Usuario" size="9" autocapitalize="off">
      <input id="pw" type="password" placeholder="Clave" size="10">
      <button id="in">Entrar</button> <span class="msg bad" id="lerr"></span>`;
    $('#in').onclick = doLogin;
    $('#pw').onkeydown = e => { if (e.key === 'Enter') doLogin(); };
  }
  drawAdmin();
}

async function doLogin(){
  try {
    user = await api('/api/login', {method:'POST', body: JSON.stringify(
      {username: $('#nm').value, password: $('#pw').value})});
    drawSession(); draw();
  } catch (e) { $('#lerr').textContent = e.message; }
}

// ------------------------------------------------------------------ search
$('#q').addEventListener('input', () => {
  clearTimeout(window.t); window.t = setTimeout(search, 220);
});

async function search(){
  term = $('#q').value.trim();
  rows = await api('/api/search?q=' + encodeURIComponent(term));
  open = null;
  draw();
}

function draw(){
  const heads = $('#heads'), out = $('#results');
  heads.hidden = rows.length === 0;
  heads.style.gridTemplateColumns = cols();
  heads.innerHTML = `<b>Lado</b><b>Producto</b>` +
    branches.map(b => `<b>${esc(b.name)}</b>`).join('');

  if (!rows.length) {
    out.innerHTML = '<p class="empty">Sin resultados. Pruebe con menos palabras.</p>';
    return;
  }
  out.innerHTML = '';
  for (const r of rows) {
    const qty = id => (r.stock.find(s => s.branch_id === id) || {}).qty || 0;
    const card = document.createElement('div');
    card.className = 'card' + (r.is_active ? '' : ' off');
    const btn = document.createElement('button');
    btn.className = 'row grid';
    btn.style.gridTemplateColumns = cols();
    btn.innerHTML =
      `<div class="side ${r.side ? '' : 'no'}">${r.side || '—'}</div>
       <div><div class="desc">${esc(r.description)}</div>
         <div class="code">${esc(r.part_code || 'sin código')}` +
        (r.unit_price != null ? ` · Bs ${r.unit_price}` : '') +
        (r.is_active ? '' : ' · inactivo') + `</div></div>` +
      branches.map(b => {
        const q = qty(b.branch_id);
        return `<div class="qty ${q ? '' : 'zero'}">${q || '—'}</div>`;
      }).join('');
    btn.onclick = () => { open = open === r.item_id ? null : r.item_id; draw();
                          if (term.length > 2) learn(r.item_id); };
    card.appendChild(btn);
    if (open === r.item_id) card.appendChild(panel(r));
    out.appendChild(card);
  }
}

function learn(item_id){
  api('/api/alias', {method:'POST', body: JSON.stringify({item_id, alias: term})})
    .catch(() => {});
}

// ------------------------------------------------------------ detail panel
function panel(r){
  const p = document.createElement('div');
  p.className = 'panel';

  if (!user.name) {
    p.innerHTML = '<p class="sub">Inicie sesión para registrar movimientos.</p>';
    return p;
  }

  p.innerHTML = `<h4>Registrar movimiento</h4>
    <div class="bar">
      <select id="mb">${branches.map(b =>
        `<option value="${b.branch_id}">${esc(b.name)}</option>`).join('')}</select>
      <select id="mr">${REASONS.map(([v,s,l],i) =>
        `<option value="${i}">${l}</option>`).join('')}</select>
      <input id="mq" type="number" min="1" value="1" style="width:80px">
      <input id="mn" placeholder="Nota (opcional)" style="flex:1;min-width:140px">
      <button class="primary" id="mgo">Guardar</button>
    </div>
    <div class="msg" id="mmsg"></div>
    <h4>Últimos movimientos</h4><div class="hist" id="mh">cargando…</div>`;

  p.querySelector('#mgo').onclick = async () => {
    const [reason, sign] = REASONS[p.querySelector('#mr').value];
    const n = Math.abs(parseInt(p.querySelector('#mq').value, 10) || 0);
    const msg = p.querySelector('#mmsg');
    try {
      const res = await api('/api/stock/move', {method:'POST', body: JSON.stringify({
        item_id: r.item_id, branch_id: +p.querySelector('#mb').value,
        qty_delta: sign * n, reason, note: p.querySelector('#mn').value || null})});
      msg.className = 'msg good';
      msg.textContent = `Guardado. Quedan ${res.qty} unidades.`;
      rows = await api('/api/search?q=' + encodeURIComponent(term)); draw();
    } catch (e) { msg.className = 'msg bad'; msg.textContent = e.message; }
  };

  api('/api/item/' + r.item_id + '/history').then(h => {
    const el = p.querySelector('#mh');
    if (!el) return;
    el.innerHTML = h.length ? h.map(m =>
      `<div>${m.occurred_at.slice(0,10)} · ${esc(m.branch)} ·
       ${m.qty_delta > 0 ? '+' : ''}${m.qty_delta} · ${m.reason} ·
       ${esc(m.created_by || '')}</div>`).join('') : '<div>sin movimientos</div>';
  }).catch(() => {});

  if (user.role === 'admin') {
    const ed = document.createElement('div');
    ed.innerHTML = `<h4 style="margin-top:16px">Editar producto (gerencia)</h4>
      <div class="bar">
        <input id="ed" value="${esc(r.description)}" style="flex:2;min-width:200px">
        <input id="ec" value="${esc(r.part_code || '')}" placeholder="Código"
               style="width:140px">
        <input id="ep" type="number" step="0.01" value="${r.unit_price ?? ''}"
               placeholder="Bs" style="width:100px">
        <button class="primary" id="ego">Guardar</button>
        <button class="danger" id="etog">${r.is_active ? 'Desactivar' : 'Reactivar'}</button>
      </div>
      <div class="msg" id="emsg"></div>`;
    p.appendChild(ed);
    const save = async body => {
      const msg = ed.querySelector('#emsg');
      try {
        await api('/api/items/' + r.item_id, {method:'PATCH', body: JSON.stringify(body)});
        msg.className = 'msg good'; msg.textContent = 'Guardado.';
        rows = await api('/api/search?q=' + encodeURIComponent(term)); draw();
      } catch (e) { msg.className = 'msg bad'; msg.textContent = e.message; }
    };
    ed.querySelector('#ego').onclick = () => save({
      description: ed.querySelector('#ed').value,
      part_code: ed.querySelector('#ec').value || null,
      unit_price: parseFloat(ed.querySelector('#ep').value) || null});
    ed.querySelector('#etog').onclick = () => save({is_active: !r.is_active});
  }
  return p;
}

// ------------------------------------------------------------- admin panel
function drawAdmin(){
  const el = $('#admin');
  if (user.role !== 'admin') { el.innerHTML = ''; return; }
  el.innerHTML = `
  <details>
    <summary>Producto nuevo</summary>
    <div class="bar">
      <input id="nd" placeholder="Descripción" style="flex:2;min-width:220px">
      <input id="nc" placeholder="Código" style="width:150px">
      <select id="ns"><option value="">sin lado</option><option>L</option><option>R</option></select>
      <input id="np" type="number" step="0.01" placeholder="Bs" style="width:100px">
      <button class="primary" id="ngo">Crear</button>
    </div>
    <div class="msg" id="nmsg"></div>
  </details>
  <details>
    <summary>Sucursales</summary>
    <div id="blist"></div>
    <div class="bar">
      <input id="bn" placeholder="Nombre de la sucursal nueva" style="flex:1;min-width:200px">
      <button class="primary" id="bgo">Agregar</button>
    </div>
    <div class="msg" id="bmsg"></div>
  </details>`;

  $('#ngo').onclick = async () => {
    const msg = $('#nmsg');
    try {
      await api('/api/items', {method:'POST', body: JSON.stringify({
        description: $('#nd').value, part_code: $('#nc').value || null,
        side: $('#ns').value || null,
        unit_price: parseFloat($('#np').value) || null})});
      msg.className = 'msg good'; msg.textContent = 'Producto creado.';
      $('#nd').value = $('#nc').value = $('#np').value = '';
      await search();
    } catch (e) { msg.className = 'msg bad'; msg.textContent = e.message; }
  };

  renderBranches();
  $('#bgo').onclick = async () => {
    const msg = $('#bmsg');
    try {
      await api('/api/branches', {method:'POST',
        body: JSON.stringify({name: $('#bn').value})});
      $('#bn').value = '';
      msg.className = 'msg good'; msg.textContent = 'Sucursal agregada.';
      await loadBranches(); renderBranches(); draw();
    } catch (e) { msg.className = 'msg bad'; msg.textContent = e.message; }
  };
}

async function renderBranches(){
  const all = await api('/api/branches');
  const box = $('#blist');
  if (!box) return;
  box.innerHTML = all.filter(b => b.is_real).map(b => `
    <div class="bar">
      <input value="${esc(b.name)}" data-id="${b.branch_id}" class="bname"
             style="flex:1;min-width:180px">
      <button class="bsave" data-id="${b.branch_id}">Renombrar</button>
      <button class="danger btog" data-id="${b.branch_id}" data-on="${b.is_active}">
        ${b.is_active ? 'Desactivar' : 'Reactivar'}</button>
    </div>`).join('');

  const patch = async (id, body) => {
    try {
      await api('/api/branches/' + id, {method:'PATCH', body: JSON.stringify(body)});
      await loadBranches(); renderBranches(); draw();
    } catch (e) { $('#bmsg').className = 'msg bad'; $('#bmsg').textContent = e.message; }
  };
  box.querySelectorAll('.bsave').forEach(b => b.onclick = () => patch(b.dataset.id,
    {name: box.querySelector(`.bname[data-id="${b.dataset.id}"]`).value}));
  box.querySelectorAll('.btog').forEach(b => b.onclick = () => patch(b.dataset.id,
    {name: box.querySelector(`.bname[data-id="${b.dataset.id}"]`).value,
     is_active: b.dataset.on !== 'true'}));
}
</script>
</body>
</html>
"""
