"""
User management for the DEPO app.

Add to the very bottom of api/main.py, after the features line:

    from api import users  # noqa: E402

Rules enforced here:
  - Only admins create, edit or deactivate accounts.
  - Anyone may change their own password (needs the current one).
  - Accounts are deactivated, never deleted, so the movement history keeps
    pointing at a real person.
  - The last active admin cannot be removed or demoted, or nobody can get back in.
"""
from fastapi import HTTPException, Request
from pydantic import BaseModel

from api.main import app, hash_password, require, run, verify_password, who

MIN_PASSWORD = 6


@app.get("/api/users")
def list_users(request: Request):
    require(request, "admin")
    rows = run("SELECT * FROM v_users")
    for r in rows:
        for k in ("last_login", "creado"):
            if r.get(k) is not None and hasattr(r[k], "isoformat"):
                r[k] = r[k].isoformat()[:16].replace("T", " ")
    return rows


class NewUser(BaseModel):
    username: str
    full_name: str
    password: str
    role: str = "staff"


@app.post("/api/users")
def create_user(body: NewUser, request: Request):
    admin = require(request, "admin")
    username = body.username.strip().lower()
    if len(username) < 2 or " " in username:
        raise HTTPException(400, "El usuario debe tener al menos 2 letras y sin espacios.")
    if len(body.password) < MIN_PASSWORD:
        raise HTTPException(400, f"La clave necesita al menos {MIN_PASSWORD} caracteres.")
    if body.role not in ("staff", "admin"):
        raise HTTPException(400, "El rol debe ser staff o admin.")
    if run("SELECT 1 FROM app_user WHERE lower(username) = %s", (username,)):
        raise HTTPException(400, f"El usuario {username} ya existe.")

    return run("""INSERT INTO app_user (username, full_name, password_hash, role,
                                        must_change, created_by)
                  VALUES (%s, %s, %s, %s, true, %s)
                  RETURNING user_id, username, full_name, role, is_active""",
               (username, body.full_name.strip() or username.title(),
                hash_password(body.password), body.role, admin["name"]))[0]


class EditUser(BaseModel):
    full_name: str | None = None
    role: str | None = None
    is_active: bool | None = None
    new_password: str | None = None


def active_admins(exclude=None):
    return run("""SELECT count(*) AS n FROM app_user
                  WHERE role = 'admin' AND is_active
                    AND (%s::int IS NULL OR user_id <> %s)""",
               (exclude, exclude))[0]["n"]


@app.patch("/api/users/{user_id}")
def edit_user(user_id: int, body: EditUser, request: Request):
    require(request, "admin")
    target = run("SELECT * FROM app_user WHERE user_id = %s", (user_id,))
    if not target:
        raise HTTPException(404, "Usuario no encontrado.")
    t = target[0]

    # Never let the last admin lock everyone out.
    removing_admin = ((body.role and body.role != "admin") or
                      body.is_active is False)
    if t["role"] == "admin" and t["is_active"] and removing_admin \
            and active_admins(exclude=user_id) == 0:
        raise HTTPException(400, "Debe quedar al menos un usuario de gerencia activo.")

    sets, vals = [], []
    if body.full_name:
        sets.append("full_name = %s"); vals.append(body.full_name.strip())
    if body.role:
        if body.role not in ("staff", "admin"):
            raise HTTPException(400, "El rol debe ser staff o admin.")
        sets.append("role = %s"); vals.append(body.role)
    if body.is_active is not None:
        sets.append("is_active = %s"); vals.append(body.is_active)
    if body.new_password:
        if len(body.new_password) < MIN_PASSWORD:
            raise HTTPException(400, f"La clave necesita al menos {MIN_PASSWORD} caracteres.")
        sets.append("password_hash = %s"); vals.append(hash_password(body.new_password))
        sets.append("must_change = true")
    if not sets:
        raise HTTPException(400, "Nada que cambiar.")

    vals.append(user_id)
    return run(f"UPDATE app_user SET {', '.join(sets)} WHERE user_id = %s "
               f"RETURNING user_id, username, full_name, role, is_active",
               tuple(vals))[0]


class OwnPassword(BaseModel):
    current_password: str
    new_password: str


@app.post("/api/me/password")
def change_own_password(body: OwnPassword, request: Request):
    user = require(request)
    rows = run("SELECT user_id, password_hash FROM app_user WHERE full_name = %s "
               "AND is_active", (user["name"],))
    if not rows:
        raise HTTPException(404, "Cuenta no encontrada.")
    if not verify_password(body.current_password, rows[0]["password_hash"]):
        raise HTTPException(401, "La clave actual no es correcta.")
    if len(body.new_password) < MIN_PASSWORD:
        raise HTTPException(400, f"La clave necesita al menos {MIN_PASSWORD} caracteres.")
    if body.current_password == body.new_password:
        raise HTTPException(400, "La clave nueva debe ser distinta.")
    run("UPDATE app_user SET password_hash = %s, must_change = false "
        "WHERE user_id = %s", (hash_password(body.new_password), rows[0]["user_id"]))
    return {"ok": True}


# --------------------------------------------------------------- admin screen
USERS_PAGE = """
<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DEPO - usuarios</title>
<style>
 :root{--bg:#EDF0F2;--card:#FFF;--ink:#14181B;--muted:#6B757C;--line:#D3DADE;
       --have:#0F6B3F;--warn:#A8322A;--focus:#1C5FA8}
 *{box-sizing:border-box}
 body{margin:0;background:var(--bg);color:var(--ink);
      font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
 .wrap{max-width:860px;margin:0 auto;padding:22px 16px 70px}
 h1{font-size:19px;letter-spacing:.14em;text-transform:uppercase;margin:0 0 4px}
 .sub{color:var(--muted);font-size:13px;margin-bottom:22px}
 a{color:var(--focus)}
 input,select,button{font:inherit;color:inherit}
 input,select{padding:9px 11px;border:1px solid var(--line);border-radius:8px;
              background:var(--card)}
 button{cursor:pointer;border:1px solid var(--line);background:var(--card);
        border-radius:8px;padding:9px 13px}
 button.primary{background:var(--ink);color:#fff;border-color:var(--ink)}
 button.danger{color:var(--warn)}
 .card{background:var(--card);border:1px solid var(--line);border-radius:10px;
       padding:13px;margin-bottom:9px}
 .bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
 .who{flex:1;min-width:180px}
 .who b{display:block}
 .who span{color:var(--muted);font:13px ui-monospace,Menlo,monospace}
 .off{opacity:.55}
 .msg{font-size:13px;min-height:18px;margin-top:9px}
 .msg.bad{color:var(--warn)} .msg.good{color:var(--have)}
 h2{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);
    margin:26px 0 9px}
</style></head><body><div class="wrap">
 <h1>Usuarios</h1>
 <p class="sub"><a href="/">&larr; volver a existencias</a> ·
    las cuentas se desactivan, nunca se borran</p>
 <div id="list"></div>
 <h2>Cuenta nueva</h2>
 <div class="card"><div class="bar">
   <input id="nu" placeholder="usuario" size="10" autocapitalize="off">
   <input id="nf" placeholder="Nombre completo" style="flex:1;min-width:160px">
   <input id="np" type="password" placeholder="clave inicial" size="12">
   <select id="nr"><option value="staff">mostrador</option>
                   <option value="admin">gerencia</option></select>
   <button class="primary" id="ngo">Crear</button>
 </div><div class="msg" id="nmsg"></div></div>
 <h2>Cambiar mi clave</h2>
 <div class="card"><div class="bar">
   <input id="cp" type="password" placeholder="clave actual" size="14">
   <input id="cn" type="password" placeholder="clave nueva" size="14">
   <button class="primary" id="cgo">Cambiar</button>
 </div><div class="msg" id="cmsg"></div></div>
</div>
<script>
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function api(p,o){const r=await fetch(p,{headers:{'Content-Type':'application/json'},...o});
  const b=await r.json().catch(()=>({})); if(!r.ok) throw new Error(b.detail||'Error'); return b;}

async function load(){
  let us;
  try { us = await api('/api/users'); }
  catch(e){ $('#list').innerHTML='<p class="msg bad">'+esc(e.message)+
    ' <a href="/">Inicie sesión como gerencia</a></p>'; return; }
  $('#list').innerHTML = us.map(u=>`
    <div class="card ${u.is_active?'':'off'}"><div class="bar">
      <div class="who"><b>${esc(u.full_name)}</b>
        <span>${esc(u.username)} · ${u.role==='admin'?'gerencia':'mostrador'}${
          u.last_login?' · último ingreso '+esc(u.last_login):' · nunca ingresó'}${
          u.must_change?' · debe cambiar clave':''}</span></div>
      <select data-r="${u.user_id}">
        <option value="staff"${u.role==='staff'?' selected':''}>mostrador</option>
        <option value="admin"${u.role==='admin'?' selected':''}>gerencia</option>
      </select>
      <input type="password" placeholder="clave nueva" size="11" data-p="${u.user_id}">
      <button data-s="${u.user_id}">Guardar</button>
      <button class="danger" data-t="${u.user_id}" data-on="${u.is_active}">
        ${u.is_active?'Desactivar':'Reactivar'}</button>
    </div><div class="msg" data-m="${u.user_id}"></div></div>`).join('');

  const patch=async(id,body,el)=>{
    try{ await api('/api/users/'+id,{method:'PATCH',body:JSON.stringify(body)});
         el.className='msg good'; el.textContent='Guardado.'; load(); }
    catch(e){ el.className='msg bad'; el.textContent=e.message; }
  };
  document.querySelectorAll('[data-s]').forEach(b=>b.onclick=()=>{
    const id=b.dataset.s, pw=document.querySelector(`[data-p="${id}"]`).value;
    patch(id,{role:document.querySelector(`[data-r="${id}"]`).value,
              ...(pw?{new_password:pw}:{})},document.querySelector(`[data-m="${id}"]`));
  });
  document.querySelectorAll('[data-t]').forEach(b=>b.onclick=()=>
    patch(b.dataset.t,{is_active:b.dataset.on!=='true'},
          document.querySelector(`[data-m="${b.dataset.t}"]`)));
}

$('#ngo').onclick=async()=>{
  const m=$('#nmsg');
  try{ await api('/api/users',{method:'POST',body:JSON.stringify({
        username:$('#nu').value, full_name:$('#nf').value,
        password:$('#np').value, role:$('#nr').value})});
    m.className='msg good'; m.textContent='Cuenta creada.';
    $('#nu').value=$('#nf').value=$('#np').value=''; load();
  }catch(e){ m.className='msg bad'; m.textContent=e.message; }
};

$('#cgo').onclick=async()=>{
  const m=$('#cmsg');
  try{ await api('/api/me/password',{method:'POST',body:JSON.stringify({
        current_password:$('#cp').value, new_password:$('#cn').value})});
    m.className='msg good'; m.textContent='Clave cambiada.';
    $('#cp').value=$('#cn').value='';
  }catch(e){ m.className='msg bad'; m.textContent=e.message; }
};
load();
</script></body></html>
"""


@app.get("/usuarios")
def users_page():
    from fastapi.responses import HTMLResponse
    return HTMLResponse(USERS_PAGE)
