"""The whole interface, kept out of main.py so that file stays readable."""

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
 .wrap{max-width:1040px;margin:0 auto;padding:20px 16px 80px}
 header{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:14px}
 h1{font-size:19px;letter-spacing:.14em;text-transform:uppercase;margin:0}
 .logo{height:42px;width:auto;object-fit:contain;display:block}
 .sub{color:var(--muted);font-size:15px}
 .spacer{flex:1}
 a{color:var(--focus)}

 nav{display:flex;gap:4px;flex-wrap:wrap;margin-bottom:20px;
     border-bottom:1px solid var(--line);padding-bottom:10px}
 nav button{border:none;background:none;padding:7px 12px;border-radius:7px;
            color:var(--muted);font-size:14px}
 nav button.on{background:var(--ink);color:#fff}
 nav .pill{background:var(--amber);color:#fff;border-radius:20px;padding:1px 7px;
           font-size:11px;margin-left:5px}

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
 button.wa{border-color:#128C7E;color:#0B6B60}

 .grid{display:grid;gap:12px;align-items:center}
 .heads{padding:0 14px 7px;font-size:11px;letter-spacing:.1em;
        text-transform:uppercase;color:var(--muted)}
 .heads b:not(:nth-child(-n+3)){text-align:center;font-weight:inherit}
 .card{background:var(--card);border:1px solid var(--line);border-radius:10px;
       margin-bottom:8px;overflow:hidden}
 .row{padding:11px 14px;width:100%;text-align:left;border:none;border-radius:0;
      background:none}
 .row:hover{background:#F6F8F9}
 .thumb{width:44px;height:44px;border-radius:7px;object-fit:cover;
        background:#F1F4F5;display:block}
 .thumb.ph{display:flex;align-items:center;justify-content:center;
           color:var(--none);font-size:11px}
 .side{font:700 21px/1 ui-monospace,Menlo,monospace;text-align:center;padding:9px 0;
       border-radius:7px;background:#FBF0E2;color:var(--amber)}
 .side.no{background:#F1F4F5;color:var(--none);font-size:15px}
 .desc{font-weight:500}
 .code{font:13px ui-monospace,Menlo,monospace;color:var(--muted);margin-top:3px}
 .flag{color:var(--amber);font-size:12px;font-family:system-ui;
       border:1px solid #E8D3B4;border-radius:20px;padding:1px 7px;margin-left:6px}
 .qty{text-align:center;font:600 20px/1 ui-monospace,Menlo,monospace;color:var(--have)}
 .qty.zero{color:var(--none);font-weight:400}
 .qty small{display:block;font-size:11px;color:var(--amber);font-weight:400}
 .off{opacity:.5}

 .panel{border-top:1px solid var(--line);padding:14px;background:#F8FAFB}
 .panel h4{margin:0 0 9px;font-size:11px;letter-spacing:.1em;
           text-transform:uppercase;color:var(--muted)}
 .panel h4:not(:first-child){margin-top:18px}
 .bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
 .hist{font-size:13px;color:var(--muted);font-family:ui-monospace,Menlo,monospace}
 .hist div{padding:2px 0}
 .msg{font-size:13px;min-height:18px;margin-top:9px}
 .msg.bad{color:var(--warn)} .msg.good{color:var(--have)}
 .empty{color:var(--muted);padding:26px 4px}
 details{margin-top:22px;background:var(--card);border:1px solid var(--line);
         border-radius:10px;padding:14px}
 summary{cursor:pointer;font-size:12px;letter-spacing:.1em;text-transform:uppercase;
         color:var(--muted)}
 details .bar{margin-top:14px}
 .list .card{padding:12px 14px}
 h3{font-size:15px;margin:22px 0 10px}

 .gate{position:fixed;inset:0;background:var(--bg);display:flex;align-items:center;
       justify-content:center;z-index:50;padding:20px}
 .gate .box{background:var(--card);border:1px solid var(--line);border-radius:16px;
            padding:34px 30px;width:100%;max-width:360px;text-align:center}
 .gate img{max-width:180px;max-height:110px;object-fit:contain;margin-bottom:8px}
 .gate h2{font-size:16px;letter-spacing:.14em;text-transform:uppercase;margin:0 0 4px}
 .gate p{color:var(--muted);font-size:13px;margin:0 0 22px}
 .gate input{width:100%;padding:14px 15px;font-size:17px;margin-bottom:11px;
             border:1px solid var(--line);border-radius:10px}
 .gate button{width:100%;padding:14px;font-size:16px}
 .gate .err{color:var(--warn);font-size:13px;min-height:18px;margin-top:10px}
 .fx{font-size:15px;color:var(--muted)}
 .login{display:flex;flex-direction:column;gap:8px;min-width:230px}
 .login input[type=text],.login input[type=password],
 .login input:not([type]){padding:12px 13px;font-size:16px;width:100%;
        box-sizing:border-box}
 .showpw{display:flex;align-items:center;gap:6px;font-size:13px;
         color:var(--muted);cursor:pointer;user-select:none}
 .showpw input{width:auto;margin:0}
 .login button.primary{padding:12px;font-size:16px;background:var(--ink);
        color:#fff;border-color:var(--ink)}

 .login{display:flex;flex-direction:column;gap:8px;align-items:stretch;
        min-width:220px}
 .login input{padding:12px 13px;font-size:16px}
 .login .pwrow{position:relative;display:flex}
 .login .pwrow input{flex:1;padding-right:56px}
 .login .toggle{position:absolute;right:6px;top:50%;transform:translateY(-50%);
        border:none;background:none;color:var(--focus);font-size:13px;
        padding:6px 8px;cursor:pointer}
 .login button.primary{padding:12px;font-size:16px;background:var(--ink);
        color:#fff;border-color:var(--ink)}
 .fx b{color:var(--ink)}
 .price-cell{display:flex;flex-direction:column;justify-content:center;
        align-items:flex-end;text-align:right;padding-right:6px;line-height:1.2}
 .price-cell b{font-size:14px}
 .price-cell small{color:var(--muted);font-size:11px}
 .price-usd{color:var(--muted);font-size:12px}
 .please-login{text-align:center;padding:80px 20px;color:var(--muted);
        font-size:17px}
</style>
</head>
<body>

<div class="wrap">
  <header>
    <img src="/media/logo.png" alt="DEPO" class="logo"
         onerror="this.replaceWith(Object.assign(document.createElement('h1'),{textContent:'DEPO'}))">
    <span class="sub">Existencias por sucursal</span>
    <span class="spacer"></span>
    <span id="session"></span>
  </header>

  <div id="please-login" class="please-login" hidden>
    <p>Inicie sesión arriba a la derecha para ver el inventario.</p>
  </div>

  <div id="app" hidden>
  <nav id="nav"></nav>

  <section id="v-buscar">
    <input id="q" autofocus autocomplete="off"
           placeholder="Buscar: espejo corola, 212-1592, farol asx...">
    <p class="hint">Escriba como quiera. Acentos y errores de tipeo no importan.</p>
    <div id="heads" class="grid heads" hidden></div>
    <div id="results"></div>
    <div id="admin"></div>
  </section>

  <section id="v-vehiculo" hidden>
    <div class="bar">
      <select id="vmk"><option value="">Marca…</option></select>
      <select id="vmd"><option value="">Todos los modelos</option></select>
      <input id="vyr" type="number" placeholder="Año" style="width:100px">
      <button class="primary" id="vgo">Buscar</button>
    </div>
    <p class="hint">Los datos salen de las descripciones, así que hay huecos.
       Corrija lo que encuentre mal.</p>
    <div id="vout"></div>
  </section>

  <section id="v-traspasos" hidden>
    <h3>En tránsito</h3>
    <p class="hint">Estas piezas no cuentan en ninguna sucursal hasta que alguien
       las reciba.</p>
    <div id="tout" class="list"></div>
  </section>

  <section id="v-reservas" hidden>
    <h3>Reservas vigentes</h3>
    <p class="hint">Lo reservado se descuenta de lo disponible, pero sigue en el
       stock hasta que el cliente lo retira.</p>
    <div id="rout" class="list"></div>
  </section>

  <section id="v-cotizacion" hidden>
    <h3>Nueva cotización</h3>
    <div class="bar">
      <input id="cq" placeholder="Buscar producto para agregar…"
             style="flex:1;min-width:220px">
    </div>
    <div id="csug" class="list" style="margin-top:8px"></div>

    <h3 style="margin-top:22px">Productos en esta cotización</h3>
    <div id="ccart" class="list"></div>
    <div id="ctotal" class="sub" style="text-align:right;margin-top:8px"></div>

    <h3 style="margin-top:22px">Datos del cliente</h3>
    <div class="bar">
      <input id="cn" placeholder="Nombre del cliente"
             style="flex:2;min-width:200px">
      <input id="cni" placeholder="NIT" style="width:130px">
      <input id="cph" placeholder="Teléfono / WhatsApp" value="591"
             style="width:170px">
      <input id="cvd" type="number" min="1" max="90" value="3" style="width:80px">
      <span class="sub">días válidos</span>
    </div>
    <div class="bar" style="margin-top:12px">
      <button class="primary" id="cgo">Generar cotización</button>
      <button id="cclr">Vaciar</button>
    </div>
    <div class="msg" id="cmsg"></div>

    <h3 style="margin-top:26px">Cotizaciones anteriores</h3>
    <div id="clist" class="list"></div>
  </section>

  <section id="v-nota" hidden>
    <h3>Nueva nota de venta</h3>
    <p class="hint">Cada línea descuenta stock de la sucursal elegida al generarse.</p>
    <div class="bar">
      <input id="nq" placeholder="Buscar producto para agregar…"
             style="flex:1;min-width:220px">
    </div>
    <div id="nsug" class="list" style="margin-top:8px"></div>

    <h3 style="margin-top:22px">Productos en esta nota</h3>
    <div id="ncart" class="list"></div>
    <div id="ntotal" class="sub" style="text-align:right;margin-top:8px"></div>

    <h3 style="margin-top:22px">Datos del cliente</h3>
    <div class="bar">
      <input id="nn" placeholder="Nombre del cliente"
             style="flex:2;min-width:200px">
      <input id="nni" placeholder="NIT" style="width:130px">
      <input id="nph" placeholder="Teléfono / WhatsApp" value="591"
             style="width:170px">
    </div>
    <div class="bar" style="margin-top:12px">
      <button class="primary" id="ngo2">Registrar venta y generar PDF</button>
      <button id="nclr">Vaciar</button>
    </div>
    <div class="msg" id="nmsg2"></div>

    <h3 style="margin-top:26px">Notas de venta anteriores</h3>
    <div id="nlist" class="list"></div>
  </section>

  <section id="v-reportes" hidden>
    <h3>Ventas</h3>
    <div class="bar">
      <label class="sub">desde <input id="rd" type="date"></label>
      <label class="sub">hasta <input id="rh" type="date"></label>
    </div>
    <div class="bar" style="margin-top:12px">
      <button id="x-lines">Detalle de ventas</button>
      <button id="x-daily">Por día</button>
      <button id="x-monthly">Por mes</button>
      <button id="x-yearly">Por año</button>
    </div>
    <p class="hint">Archivos con punto y coma y decimales con coma: se abren
       directo en Excel en español.</p>
    <h3>Contabilidad</h3>
    <div class="bar">
      <button id="x-accd">Contable por día</button>
      <button id="x-accm">Contable por mes</button>
      <button id="x-top">Más vendidos</button>
      <button id="x-type">Ventas por tipo</button>
    </div>
    <p class="hint">Incluyen total bruto, neto sin IVA e IVA 13%.</p>

    <h3>Otros reportes</h3>
    <div class="bar">
      <button id="x-dead">Stock sin movimiento</button>
      <button id="x-reorder">Reponer</button>
      <button id="x-pairs">Pares incompletos</button>
      <button id="x-prices">Historial de precios</button>
    </div>
    <div class="msg" id="rmsg"></div>

    <h3>Archivo de reportes</h3>
    <p class="hint">Se generan solos cuando el periodo termina y ya no cambian.
       Diarios 30 días · semanales 1 año · mensuales para siempre.</p>
    <div class="bar"><button class="primary" id="x-gen">Generar ahora</button></div>
    <div class="msg" id="gmsg"></div>
    <div id="arch"></div>
  </section>
  </div>
</div>

<script>
const $ = s => document.querySelector(s);
let user = {}, branches = [], rows = [], openId = null, term = '';
let pairs = new Set(), transit = [], holds = [], vehicles = [], view = 'buscar';

const VIEWS = [['buscar','Buscar'],['vehiculo','Por vehículo'],
               ['traspasos','Traspasos'],['reservas','Reservas'],
               ['cotizacion','Cotización'],['nota','Nota de venta'],
               ['reportes','Reportes']];

const REASONS = [
  ['purchase',      1, 'Ingreso (compra)'],
  ['sale',         -1, 'Venta'],
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
let fx = {rate:null, source:'oficial'};

(async function start(){
  try { user = await api('/api/me'); } catch(e) { user = {}; }
  try { fx = await api('/api/fx'); } catch(e){}
  await boot();
})();

function showApp(loggedIn){
  const app = document.getElementById('app');
  const prompt = document.getElementById('please-login');
  if (app) app.hidden = !loggedIn;
  if (prompt) prompt.hidden = loggedIn;
}

async function boot(){
  drawSession();
  showApp(!!user.name);
  if (!user.name) return;         // logged out: show only the header + prompt
  await loadBranches();
  drawNav();
  await Promise.all([search(), loadSide()]);
}

async function loadBranches(){
  branches = (await api('/api/branches')).filter(b => b.is_real && b.is_active);
}

async function loadSide(){
  if (!user.name) { pairs = new Set(); transit = []; holds = []; return; }
  try {
    const [p, t, h] = await Promise.all([
      api('/api/broken-pairs'), api('/api/transfers'), api('/api/reservations')]);
    pairs = new Set(p.map(x => x.item_id + ':' + x.branch_id));
    transit = t; holds = h;
  } catch (e) { /* not logged in yet */ }
  drawNav();
}

function cols(){
  return `44px 44px minmax(0,1fr) 92px ${branches.map(() => '84px').join(' ')}`;
}

// ------------------------------------------------------------------- shell
function drawNav(){
  $('#nav').innerHTML = VIEWS.map(([k, label]) => {
    let pill = '';
    if (k === 'traspasos' && transit.length) pill = `<span class="pill">${transit.length}</span>`;
    if (k === 'reservas' && holds.length)   pill = `<span class="pill">${holds.length}</span>`;
    if (k === 'reportes' && user.role !== 'admin') return '';
    return `<button data-v="${k}" class="${view === k ? 'on' : ''}">${label}${pill}</button>`;
  }).join('');
  $('#nav').querySelectorAll('[data-v]').forEach(b =>
    b.onclick = () => go(b.dataset.v));
}

function go(v){
  view = v; drawNav();
  for (const [k] of VIEWS) $('#v-' + k).hidden = (k !== v);
  if (v === 'vehiculo')  loadVehicles();
  if (v === 'traspasos') drawTransit();
  if (v === 'reservas')  drawHolds();
  if (v === 'cotizacion') { drawCart(); loadQuotes(); }
  if (v === 'nota')      { drawNCart(); loadSales(); }
  if (v === 'reportes')  drawArchive();
}

function drawFx(){
  const el = $('#fxbox'); if (!el) return;
  if (!fx.rate) { el.textContent = 'sin tipo de cambio'; return; }
  const label = fx.source === 'blue' ? 'paralelo' : 'oficial';
  el.innerHTML = `TC ${label}: <b>${fx.rate}</b> Bs/$`;
  if (user.role === 'admin') {
    el.innerHTML += ` <button class="link" id="fxsw">cambiar</button>`;
    setTimeout(() => { const b = $('#fxsw'); if (b) b.onclick = switchFx; }, 0);
  }
}
async function switchFx(){
  const next = fx.source === 'oficial' ? 'blue' : 'oficial';
  try {
    fx = await api('/api/fx/source?source=' + next, {method:'POST'});
    drawFx(); refresh();
  } catch (e) { alert(e.message); }
}
function drawSession(){
  const el = $('#session');
  if (user.name) {
    el.innerHTML = `<span class="sub">${esc(user.name)} ·
      ${user.role === 'admin' ? 'gerencia' : 'mostrador'}</span>` +
      (user.role === 'admin' ? ' <a href="/usuarios" class="sub">usuarios</a>' : '') +
      ` · <span class="fx" id="fxbox"></span>` +
      ` <button class="link" id="out">salir</button>`;
    drawFx();
    $('#out').onclick = async () => {
      await api('/api/logout', {method:'POST'});
      user = {}; showApp(false); drawSession();
    };
  } else {
    el.innerHTML = `<div class="login">
      <input id="nm" placeholder="Usuario" autocapitalize="off" autocomplete="username">
      <input id="pw" type="password" placeholder="Clave" autocomplete="current-password">
      <label class="showpw"><input type="checkbox" id="pwck"> mostrar clave</label>
      <button class="primary" id="in">Entrar</button>
      <span class="msg bad" id="lerr"></span>
    </div>`;
    $('#in').onclick = doLogin;
    $('#pw').onkeydown = e => { if (e.key === 'Enter') doLogin(); };
    $('#pwck').onchange = () => {
      $('#pw').type = $('#pwck').checked ? 'text' : 'password';
    };
  }
  drawAdmin();
}

async function doLogin(){
  try {
    user = await api('/api/login', {method:'POST', body: JSON.stringify(
      {username: $('#nm').value.trim(), password: $('#pw').value})});
    showApp(true);
    await loadBranches();
    await loadSide(); drawSession(); draw(); drawNav();
  } catch (e) { $('#lerr').textContent = e.message; }
}

// ------------------------------------------------------------------ search
$('#q').addEventListener('input', () => {
  // Don't kick off a new search if the user is currently editing a product
  // (admin panel open with typed values that a fresh render would wipe).
  if (openId != null && document.activeElement &&
      document.activeElement.closest('#admin')) return;
  clearTimeout(window.t); window.t = setTimeout(search, 220);
});

async function search(){
  term = $('#q').value.trim();
  rows = await api('/api/search?q=' + encodeURIComponent(term));
  openId = null;
  draw();
}

async function refresh(){
  rows = await api('/api/search?q=' + encodeURIComponent(term));
  await loadSide();
  draw();
}

function qtyOf(r, id){ return (r.stock.find(s => s.branch_id === id) || {}).qty || 0; }

function draw(){
  const heads = $('#heads'), out = $('#results');
  heads.hidden = rows.length === 0;
  heads.style.gridTemplateColumns = cols();
  heads.innerHTML = `<b>Foto</b><b>Lado</b><b>Producto</b><b>Precio</b>` +
    branches.map(b => `<b>${esc(b.name)}</b>`).join('');

  if (!rows.length) {
    out.innerHTML = '<p class="empty">Sin resultados. Pruebe con menos palabras.</p>';
    return;
  }
  out.innerHTML = '';
  for (const r of rows) {
    const card = document.createElement('div');
    card.className = 'card' + (r.is_active ? '' : ' off');
    const btn = document.createElement('button');
    btn.className = 'row grid';
    btn.style.gridTemplateColumns = cols();
    const lonely = branches.some(b => pairs.has(r.item_id + ':' + b.branch_id));
    btn.innerHTML =
      (r.photo_path
        ? `<img class="thumb" src="/media/${esc(r.photo_path)}" alt="">`
        : `<div class="thumb ph">sin<br>foto</div>`) +
      `<div class="side ${r.side ? '' : 'no'}">${r.side || '—'}</div>
       <div><div class="desc">${esc(r.description)}` +
         (lonely ? '<span class="flag">falta el par</span>' : '') + `</div>
         <div class="code">${esc(r.part_code || 'sin código')}` +
         (r.is_active ? '' : ' · inactivo') + `</div></div>` +
      `<div class="price-cell">` +
        (r.price_usd != null
          ? `<b>USD ${r.price_usd}</b>` +
            (r.price_bob != null ? `<small>Bs ${r.price_bob}</small>` : '')
          : `<span class="sub">sin precio</span>`) +
      `</div>` +
      branches.map(b => {
        const q = qtyOf(r, b.branch_id);
        const held = holds.filter(h => h.description === r.description &&
                                       h.branch === b.name)
                          .reduce((a, h) => a + h.qty, 0);
        return `<div class="qty ${q ? '' : 'zero'}">${q || '—'}` +
               (held ? `<small>${held} reservado</small>` : '') + `</div>`;
      }).join('');
    btn.onclick = () => { openId = openId === r.item_id ? null : r.item_id; draw();
                          if (term.length > 2) learn(r.item_id); };
    card.appendChild(btn);
    if (openId === r.item_id) card.appendChild(panel(r));
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
  const opts = branches.map(b =>
    `<option value="${b.branch_id}">${esc(b.name)}</option>`).join('');

  // Internal message: full detail for staff.
  const waStaff = `${r.description}${r.side ? ' (' + r.side + ')' : ''}` +
    ` — ${r.part_code || 'sin código'}` +
    (r.price_bob != null ? ` — Bs ${r.price_bob}` : '') + ' — ' +
    branches.map(b => `${b.name}: ${qtyOf(r, b.branch_id)}`).join(', ');
  // Client message: friendly, price only, today's rate.
  const total = branches.reduce((a,b)=>a+qtyOf(r,b.branch_id),0);
  const waClient = `Estimad@ cliente, el producto ${r.description}` +
    `${r.side ? ' (lado ' + (r.side==='L'?'izquierdo':'derecho') + ')' : ''}` +
    (r.price_bob != null ? ` tiene un costo de ${r.price_bob} Bs` +
      ` (al tipo de cambio de hoy)` : '') +
    (total > 0 ? '. Disponible en tienda.' : '. Consúltenos disponibilidad.') +
    ' — DEPO autolamp';



  p.innerHTML = `
    <div class="bar">
      <button class="wa" id="waC">WhatsApp a cliente</button>
      <button class="wa" id="waS">WhatsApp interno</button>
      <label class="sub">Foto: <input type="file" id="ph" accept="image/*"></label>
    </div>

    <h4>Registrar movimiento</h4>
    <div class="bar">
      <select id="mb">${opts}</select>
      <select id="mr">${REASONS.map(([v,s,l],i) =>
        `<option value="${i}">${l}</option>`).join('')}</select>
      <input id="mq" type="number" min="1" value="1" style="width:80px">
      <input id="mn" placeholder="Nota (opcional)" style="flex:1;min-width:130px">
      <button class="primary" id="mgo">Guardar</button>
    </div>
    <div class="msg" id="mmsg"></div>

    <h4>Reservar para un cliente</h4>
    <div class="bar">
      <select id="hb">${opts}</select>
      <input id="hq" type="number" min="1" value="1" style="width:80px">
      <input id="hc" placeholder="Cliente" style="flex:1;min-width:130px">
      <select id="hh"><option value="24">24 h</option><option value="48" selected>48 h</option>
        <option value="72">72 h</option></select>
      <button id="hgo">Reservar</button>
    </div>
    <div class="msg" id="hmsg"></div>

    <h4>Traspasar a otra sucursal</h4>
    <div class="bar">
      <select id="tf">${opts}</select> <span class="sub">→</span>
      <select id="tt">${opts}</select>
      <input id="tq" type="number" min="1" value="1" style="width:80px">
      <button id="tgo">Enviar</button>
    </div>
    <div class="msg" id="tmsg"></div>

    <h4>Últimos movimientos</h4><div class="hist" id="mh">cargando…</div>`;

  p.querySelector('#waC').onclick = () =>
    window.open('https://wa.me/?text=' + encodeURIComponent(waClient), '_blank');
  p.querySelector('#waS').onclick = () =>
    window.open('https://wa.me/?text=' + encodeURIComponent(waStaff), '_blank');

  p.querySelector('#ph').onchange = async e => {
    const f = e.target.files[0]; if (!f) return;
    const fd = new FormData(); fd.append('file', f);
    const res = await fetch('/api/items/' + r.item_id + '/photo',
                            {method:'POST', body: fd});
    if (res.ok) refresh();
  };

  const say = (sel, ok, text) => {
    const m = p.querySelector(sel);
    m.className = 'msg ' + (ok ? 'good' : 'bad'); m.textContent = text;
  };

  p.querySelector('#mgo').onclick = async () => {
    const [reason, sign] = REASONS[p.querySelector('#mr').value];
    const n = Math.abs(parseInt(p.querySelector('#mq').value, 10) || 0);
    try {
      const res = await api('/api/stock/move', {method:'POST', body: JSON.stringify({
        item_id: r.item_id, branch_id: +p.querySelector('#mb').value,
        qty_delta: sign * n, reason, note: p.querySelector('#mn').value || null})});
      say('#mmsg', true, `Guardado. Quedan ${res.qty} unidades.`);
      refresh();
    } catch (e) { say('#mmsg', false, e.message); }
  };

  p.querySelector('#hgo').onclick = async () => {
    try {
      await api('/api/reservations', {method:'POST', body: JSON.stringify({
        item_id: r.item_id, branch_id: +p.querySelector('#hb').value,
        qty: parseInt(p.querySelector('#hq').value, 10) || 1,
        customer: p.querySelector('#hc').value || null,
        hours: +p.querySelector('#hh').value})});
      say('#hmsg', true, 'Reservado.'); refresh();
    } catch (e) { say('#hmsg', false, e.message); }
  };

  p.querySelector('#tgo').onclick = async () => {
    const from = +p.querySelector('#tf').value, to = +p.querySelector('#tt').value;
    if (from === to) return say('#tmsg', false, 'Elija sucursales distintas.');
    try {
      await api('/api/transfers', {method:'POST', body: JSON.stringify({
        item_id: r.item_id, from_branch: from, to_branch: to,
        qty: parseInt(p.querySelector('#tq').value, 10) || 1})});
      say('#tmsg', true, 'Enviado. Queda en tránsito hasta que lo reciban.');
      refresh();
    } catch (e) { say('#tmsg', false, e.message); }
  };

  api('/api/item/' + r.item_id + '/history').then(h => {
    const el = p.querySelector('#mh'); if (!el) return;
    el.innerHTML = h.length ? h.map(m =>
      `<div>${m.occurred_at.slice(0,10)} · ${esc(m.branch)} ·
       ${m.qty_delta > 0 ? '+' : ''}${m.qty_delta} · ${m.reason} ·
       ${esc(m.created_by || '')}</div>`).join('') : '<div>sin movimientos</div>';
  }).catch(() => {});

  if (user.role === 'admin') {
    const ed = document.createElement('div');
    ed.innerHTML = `<h4>Editar producto (gerencia)</h4>
      <div class="bar">
        <input id="ed" value="${esc(r.description)}" style="flex:2;min-width:200px">
        <input id="ec" value="${esc(r.part_code || '')}" placeholder="Código"
               style="width:130px">
        <input id="ep" type="number" step="0.01" value="${r.price_usd ?? ''}"
               placeholder="Precio en USD" style="width:140px">
      </div>
      <div class="bar" style="margin-top:8px">
        <input id="etp" value="${esc(r.product_type || '')}" placeholder="Tipo (espejo…)" style="width:130px">
        <input id="emk" value="${esc(r.make || '')}" placeholder="Marca" style="width:110px">
        <input id="emd" value="${esc(r.model || '')}" placeholder="Modelo" style="width:110px">
        <input id="eyr" value="${esc(r.year_text || '')}" placeholder="Año" style="width:90px">
        <input id="enk" value="${esc(r.nickname || '')}" placeholder="Apodo (CHANCHO)" style="width:130px">
        <button class="primary" id="ego">Guardar</button>
        <button class="danger" id="etog">${r.is_active ? 'Desactivar' : 'Reactivar'}</button>
      </div><div class="msg" id="emsg"></div>`;
    p.appendChild(ed);
    const save = async body => {
      try {
        await api('/api/items/' + r.item_id, {method:'PATCH', body: JSON.stringify(body)});
        say('#emsg', true, 'Guardado.'); refresh();
      } catch (e) { say('#emsg', false, e.message); }
    };
    ed.querySelector('#ego').onclick = () => {
      // Only send fields that were actually filled in. An empty price field
      // means "don't change it", never "set to null".
      const body = {description: ed.querySelector('#ed').value};
      const code = ed.querySelector('#ec').value.trim();
      if (code) body.part_code = code;
      const price = parseFloat(ed.querySelector('#ep').value);
      if (!isNaN(price)) body.price_usd = price;
      const attrs = {product_type:'#etp', make:'#emk', model:'#emd',
                     year_text:'#eyr', nickname:'#enk'};
      for (const [key, sel] of Object.entries(attrs)) {
        const v = ed.querySelector(sel).value.trim();
        if (v) body[key] = v;
      }
      save(body);
    };
    ed.querySelector('#etog').onclick = () => save({is_active: !r.is_active});
  }
  return p;
}

// ----------------------------------------------------------- vehicle search
async function loadVehicles(){
  if (vehicles.length) return;
  vehicles = await api('/api/vehicles');
  const makes = [...new Set(vehicles.map(v => v.make))].sort();
  $('#vmk').innerHTML = '<option value="">Marca…</option>' +
    makes.map(m => `<option>${esc(m)}</option>`).join('');
  $('#vmk').onchange = () => {
    const ms = vehicles.filter(v => v.make === $('#vmk').value && v.model);
    $('#vmd').innerHTML = '<option value="">Todos los modelos</option>' +
      ms.map(v => `<option>${esc(v.model)}</option>`).join('');
  };
  $('#vgo').onclick = runVehicle;
}

async function runVehicle(){
  const make = $('#vmk').value;
  if (!make) { $('#vout').innerHTML = '<p class="empty">Elija una marca.</p>'; return; }
  const qs = new URLSearchParams({make});
  if ($('#vmd').value) qs.set('model', $('#vmd').value);
  if ($('#vyr').value) qs.set('year', $('#vyr').value);
  const list = await api('/api/vehicle-parts?' + qs);
  $('#vout').innerHTML = list.length ? `<div class="list">` + list.map(p => `
     <div class="card"><div class="bar">
       <div class="side ${p.side ? '' : 'no'}" style="width:44px">${p.side || '—'}</div>
       <div style="flex:1;min-width:180px"><div class="desc">${esc(p.description)}</div>
         <div class="code">${esc(p.sku)}${p.price_bob != null
           ? ' · Bs ' + p.price_bob : ''} · ${esc(p.confidence)}</div></div>
     </div></div>`).join('') + '</div>'
   : '<p class="empty">Sin partes para ese vehículo.</p>';
}

// --------------------------------------------------------------- transfers
function drawTransit(){
  const box = $('#tout');
  if (!user.name) { box.innerHTML = '<p class="empty">Inicie sesión.</p>'; return; }
  box.innerHTML = transit.length ? transit.map(t => `
    <div class="card"><div class="bar">
      <div style="flex:1;min-width:200px">
        <div class="desc">${esc(t.description)}${t.side ? ' (' + t.side + ')' : ''}</div>
        <div class="code">${t.qty} u · ${esc(t.desde)} → ${esc(t.hacia)} ·
          enviado por ${esc(t.sent_by || '')} el ${t.sent_at.slice(0,10)}</div></div>
      <button class="primary" data-r="${t.transfer_id}">Recibir</button>
    </div></div>`).join('') : '<p class="empty">Nada en tránsito.</p>';
  box.querySelectorAll('[data-r]').forEach(b => b.onclick = async () => {
    try { await api('/api/transfers/' + b.dataset.r + '/receive', {method:'POST'});
          await loadSide(); drawTransit(); refresh();
    } catch (e) { alert(e.message); }
  });
}

// -------------------------------------------------------------- reservations
function drawHolds(){
  const box = $('#rout');
  if (!user.name) { box.innerHTML = '<p class="empty">Inicie sesión.</p>'; return; }
  box.innerHTML = holds.length ? holds.map(h => `
    <div class="card"><div class="bar">
      <div style="flex:1;min-width:200px">
        <div class="desc">${esc(h.description)}${h.side ? ' (' + h.side + ')' : ''}</div>
        <div class="code">${h.qty} u · ${esc(h.branch)} ·
          ${esc(h.customer || 'sin nombre')} · vence ${h.expires_at.slice(0,16)
          .replace('T',' ')}</div></div>
      <button class="primary" data-c="${h.reservation_id}">Entregado</button>
      <button class="danger" data-x="${h.reservation_id}">Cancelar</button>
    </div></div>`).join('') : '<p class="empty">Sin reservas vigentes.</p>';
  const close = async (id, action) => {
    try { await api(`/api/reservations/${id}/${action}`, {method:'POST'});
          await loadSide(); drawHolds(); refresh();
    } catch (e) { alert(e.message); }
  };
  box.querySelectorAll('[data-c]').forEach(b =>
    b.onclick = () => close(b.dataset.c, 'collected'));
  box.querySelectorAll('[data-x]').forEach(b =>
    b.onclick = () => close(b.dataset.x, 'cancelled'));
}

// -------------------------------------------------------------- cotización
let cart = [];   // {item_id, description, side, part_code, price_bob, qty}

async function csearch(){
  const term = $('#cq').value.trim();
  const box = $('#csug');
  if (term.length < 2) { box.innerHTML = ''; return; }
  const results = await api('/api/search?q=' + encodeURIComponent(term));
  box.innerHTML = results.slice(0, 8).map(r => `
    <div class="card"><div class="bar">
      <div class="side ${r.side?'':'no'}" style="width:44px">${r.side||'—'}</div>
      <div style="flex:1;min-width:180px">
        <div class="desc">${esc(r.description)}</div>
        <div class="code">${esc(r.part_code||'sin código')}${
          r.price_bob!=null?' · Bs '+r.price_bob:' · sin precio'}</div></div>
      <button class="primary" data-add-id="${r.item_id}">Agregar</button>
    </div></div>`).join('');
  box.querySelectorAll('[data-add-id]').forEach(b => b.onclick = async () => {
    // Always refetch by SKU so the cart price is the real current one.
    const id = parseInt(b.dataset.addId, 10);
    let fresh;
    try {
      const one = await api('/api/search?q=DEPO-' + String(id).padStart(5,'0'));
      fresh = one.find(x => x.item_id === id) || one[0];
    } catch (e) { fresh = null; }
    if (!fresh) {
      alert('No se pudo cargar el producto. Intente de nuevo.');
      return;
    }
    if (fresh.price_bob == null || fresh.price_bob === 0) {
      if (!confirm('Este producto no tiene precio configurado. ¿Agregar igual?')) return;
    }
    const existing = cart.find(c => c.item_id === fresh.item_id);
    if (existing) existing.qty += 1;
    else cart.push({
      item_id: fresh.item_id, description: fresh.description, side: fresh.side,
      part_code: fresh.part_code, price_bob: fresh.price_bob || 0, qty: 1
    });
    $('#cq').value = ''; box.innerHTML = ''; drawCart();
  });
}

function drawCart(){
  const box = $('#ccart');
  if (!cart.length) {
    box.innerHTML = '<p class="empty">Sin productos. Busque arriba y agregue.</p>';
    $('#ctotal').textContent = '';
    return;
  }
  box.innerHTML = cart.map((c,i) => `
    <div class="card"><div class="bar">
      <div class="side ${c.side?'':'no'}" style="width:44px">${c.side||'—'}</div>
      <div style="flex:1;min-width:180px">
        <div class="desc">${esc(c.description)}</div>
        <div class="code">${esc(c.part_code||'')} · Bs ${c.price_bob}</div></div>
      <input type="number" min="1" value="${c.qty}" data-q="${i}" style="width:70px">
      <span class="sub">Bs ${(c.price_bob*c.qty).toFixed(2)}</span>
      <button class="danger" data-rm="${i}">Quitar</button>
    </div></div>`).join('');
  box.querySelectorAll('[data-q]').forEach(inp => inp.oninput = () => {
    const n = parseInt(inp.value,10) || 1;
    cart[+inp.dataset.q].qty = Math.max(1, n);
    total();
  });
  box.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => {
    cart.splice(+b.dataset.rm, 1); drawCart();
  });
  total();
}
function total(){
  const t = cart.reduce((a,c) => a + c.price_bob * c.qty, 0);
  $('#ctotal').innerHTML = `<b>Total: Bs ${t.toFixed(2)}</b>`;
}

async function loadQuotes(){
  const box = $('#clist');
  const list = await api('/api/quotes');
  box.innerHTML = list.length ? list.slice(0,15).map(q => `
    <div class="card"><div class="bar">
      <div style="flex:1;min-width:180px">
        <div class="desc">Cotización Nº ${q.quote_number} · ${esc(q.customer)}</div>
        <div class="code">${q.fecha} · ${q.lineas} productos · Bs ${
          (q.total_bob||0).toFixed(2)} · válida hasta ${q.valid_until.slice(0,10)}</div>
      </div>
      <button data-pdf="${q.quote_id}">Descargar PDF</button>
      <button class="wa" data-wa='${JSON.stringify(
        {quote_id:q.quote_id, phone:q.customer_phone||'', customer:q.customer,
         number:q.quote_number, days:q.valid_days}).replace(/'/g,"&#39;")}'>WhatsApp</button>
    </div></div>`).join('') : '<p class="empty">Aún no hay cotizaciones.</p>';
  box.querySelectorAll('[data-pdf]').forEach(b => b.onclick = () =>
    downloadQuotePdf(+b.dataset.pdf));
  box.querySelectorAll('[data-wa]').forEach(b => b.onclick = () => {
    const d = JSON.parse(b.dataset.wa.replace(/&#39;/g,"'"));
    sendWaQuote(d);
  });
}

async function downloadQuotePdf(quote_id){
  try {
    const res = await fetch('/api/quotes/' + quote_id + '/pdf');
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      alert('No se pudo generar el PDF: ' + (err.detail || res.status));
      return;
    }
    const blob = await res.blob();
    if (!blob.type.includes('pdf') || blob.size < 500) {
      alert('El PDF salió vacío o dañado. Revise el servidor.');
      return;
    }
    const cd = res.headers.get('Content-Disposition') || '';
    const m = cd.match(/filename="?([^"]+)"?/);
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = m ? m[1] : `cotizacion_${quote_id}.pdf`;
    document.body.appendChild(link); link.click(); link.remove();
    URL.revokeObjectURL(url);
  } catch (e) { alert('Error de red: ' + e.message); }
}

async function sendWaQuote(d){
  // Fetch the PDF as a blob and force the correct filename. Doing it this
  // way instead of a plain <a href> stops Safari from silently appending
  // .txt to the downloaded file.
  try {
    const res = await fetch('/api/quotes/' + d.quote_id + '/pdf');
    if (!res.ok) {
      // Server returned an error - read it as JSON, not as a PDF, so the
      // user sees the actual problem instead of a broken file.
      const err = await res.json().catch(() => ({}));
      alert('No se pudo generar el PDF: ' + (err.detail || res.status));
      return;
    }
    const blob = await res.blob();
    if (!blob.type.includes('pdf') || blob.size < 500) {
      alert('El PDF salió vacío o dañado. Revise el servidor.');
      return;
    }
    const cd = res.headers.get('Content-Disposition') || '';
    const m = cd.match(/filename="?([^"]+)"?/);
    const name = m ? m[1] : `cotizacion_${d.number || d.quote_id}.pdf`;
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = name;
    document.body.appendChild(link); link.click(); link.remove();
    URL.revokeObjectURL(url);
  } catch (e) {
    alert('Error de red al descargar el PDF: ' + e.message);
    return;
  }

  const msg = `Estimad@ cliente le adjunto su cotización válida por ${d.days || 3} días.`;
  const digits = (d.phone || '').replace(/[^0-9]/g,'');
  const phone = digits.length >= 11 ? digits : '';
  const url = phone ? `https://wa.me/${phone}?text=${encodeURIComponent(msg)}`
                    : `https://wa.me/?text=${encodeURIComponent(msg)}`;
  window.open(url, '_blank');
}

$('#cq').addEventListener('input', () => {
  clearTimeout(window.ct); window.ct = setTimeout(csearch, 220);
});
$('#cclr').onclick = () => { cart = []; drawCart(); };
$('#cgo').onclick = async () => {
  const m = $('#cmsg');
  if (!cart.length) { m.className='msg bad'; m.textContent='Agregue productos primero.'; return; }
  if (!$('#cn').value.trim()) { m.className='msg bad'; m.textContent='Escriba el nombre del cliente.'; return; }
  try {
    const r = await api('/api/quotes', {method:'POST', body: JSON.stringify({
      customer: $('#cn').value, customer_nit: $('#cni').value || null,
      customer_phone: $('#cph').value || null,
      valid_days: parseInt($('#cvd').value,10) || 15,
      lines: cart.map(c => ({item_id: c.item_id, qty: c.qty}))})});
    m.className = 'msg good';
    m.textContent = `Cotización Nº ${r.quote_number} creada.`;
    // Download the PDF, then open WhatsApp with the message.
    sendWaQuote({quote_id: r.quote_id, phone: $('#cph').value,
                 customer: $('#cn').value, number: r.quote_number,
                 days: parseInt($('#cvd').value,10) || 3});
    // Reset for the next quote.
    cart = []; drawCart();
    $('#cn').value = $('#cni').value = '';
    $('#cph').value = '591';
    loadQuotes();
  } catch (e) { m.className='msg bad'; m.textContent = e.message; }
};

// -------------------------------------------------------- nota de venta
let ncart = [];  // {item_id, description, side, part_code, price_bob, qty, branch_id}

async function nsearch(){
  const term = $('#nq').value.trim();
  const box = $('#nsug');
  if (term.length < 2) { box.innerHTML = ''; return; }
  const results = await api('/api/search?q=' + encodeURIComponent(term));
  box.innerHTML = results.slice(0, 8).map(r => `
    <div class="card"><div class="bar">
      <div class="side ${r.side?'':'no'}" style="width:44px">${r.side||'—'}</div>
      <div style="flex:1;min-width:180px">
        <div class="desc">${esc(r.description)}</div>
        <div class="code">${esc(r.part_code||'sin código')}${
          r.price_bob!=null?' · Bs '+r.price_bob:' · sin precio'} · en stock: ${
          branches.map(b => b.name + ' ' + (
            (r.stock.find(s => s.branch_id === b.branch_id) || {}).qty || 0
          )).join(', ')}</div></div>
      <button class="primary" data-add-id="${r.item_id}">Agregar</button>
    </div></div>`).join('');
  box.querySelectorAll('[data-add-id]').forEach(b => b.onclick = async () => {
    // Refetch the item straight from the server. This guarantees the price
    // in the cart is whatever gerencia last set - never a stale snapshot
    // from an older search response.
    const id = parseInt(b.dataset.addId, 10);
    let fresh;
    try {
      // Search by SKU to get one authoritative row back.
      const one = await api('/api/search?q=DEPO-' + String(id).padStart(5,'0'));
      fresh = one.find(x => x.item_id === id) || one[0];
    } catch (e) { fresh = null; }
    if (!fresh) {
      alert('No se pudo cargar el producto. Intente de nuevo.');
      return;
    }
    if (fresh.price_bob == null || fresh.price_bob === 0) {
      if (!confirm('Este producto no tiene precio configurado. ¿Agregar igual?')) return;
    }
    const first = branches.find(br =>
      (fresh.stock.find(s => s.branch_id === br.branch_id) || {}).qty > 0);
    const branch_id = first ? first.branch_id : (branches[0] || {}).branch_id;
    ncart.push({
      item_id: fresh.item_id,
      description: fresh.description,
      side: fresh.side,
      part_code: fresh.part_code,
      price_bob: fresh.price_bob || 0,
      stock: fresh.stock,
      qty: 1,
      branch_id
    });
    $('#nq').value = ''; box.innerHTML = ''; drawNCart();
  });
}

function stockAt(item, branch_id){
  return (item.stock.find(s => s.branch_id === branch_id) || {}).qty || 0;
}

function drawNCart(){
  const box = $('#ncart');
  if (!ncart.length) {
    box.innerHTML = '<p class="empty">Sin productos. Busque arriba y agregue.</p>';
    $('#ntotal').textContent = '';
    return;
  }
  box.innerHTML = ncart.map((c,i) => `
    <div class="card"><div class="bar">
      <div class="side ${c.side?'':'no'}" style="width:44px">${c.side||'—'}</div>
      <div style="flex:1;min-width:180px">
        <div class="desc">${esc(c.description)}</div>
        <div class="code">${esc(c.part_code||'')} · Bs ${c.price_bob}</div></div>
      <select data-b="${i}">${branches.map(b =>
        `<option value="${b.branch_id}"${b.branch_id === c.branch_id
          ? ' selected' : ''}>${esc(b.name)} (${stockAt(c, b.branch_id)})</option>`
        ).join('')}</select>
      <input type="number" min="1" value="${c.qty}" data-q="${i}" style="width:70px">
      <span class="sub">Bs ${(c.price_bob*c.qty).toFixed(2)}</span>
      <button class="danger" data-rm="${i}">Quitar</button>
    </div></div>`).join('');
  box.querySelectorAll('[data-q]').forEach(inp => inp.oninput = () => {
    ncart[+inp.dataset.q].qty = Math.max(1, parseInt(inp.value,10) || 1);
    ntotal();
  });
  box.querySelectorAll('[data-b]').forEach(sel => sel.onchange = () => {
    ncart[+sel.dataset.b].branch_id = +sel.value;
  });
  box.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => {
    ncart.splice(+b.dataset.rm, 1); drawNCart();
  });
  ntotal();
}
function ntotal(){
  const t = ncart.reduce((a,c) => a + c.price_bob * c.qty, 0);
  $('#ntotal').innerHTML = `<b>Total: Bs ${t.toFixed(2)}</b>`;
}

async function loadSales(){
  const box = $('#nlist');
  const list = await api('/api/sales');
  box.innerHTML = list.length ? list.slice(0,15).map(q => `
    <div class="card"><div class="bar">
      <div style="flex:1;min-width:180px">
        <div class="desc">Nota Nº ${q.quote_number} · ${esc(q.customer)}</div>
        <div class="code">${q.fecha} · ${q.lineas} productos · Bs ${
          (q.total_bob||0).toFixed(2)}</div>
      </div>
      <button data-npdf="${q.quote_id}">Descargar PDF</button>
      <button class="wa" data-nwa='${JSON.stringify(
        {sale_id:q.quote_id, phone:q.customer_phone||'',
         customer:q.customer, number:q.quote_number}).replace(/'/g,"&#39;")}'>WhatsApp</button>
    </div></div>`).join('') : '<p class="empty">Aún no hay notas de venta.</p>';
  box.querySelectorAll('[data-npdf]').forEach(b => b.onclick = () =>
    downloadSalePdf(+b.dataset.npdf));
  box.querySelectorAll('[data-nwa]').forEach(b => b.onclick = () => {
    const d = JSON.parse(b.dataset.nwa.replace(/&#39;/g,"'"));
    sendWaSale(d);
  });
}

async function downloadSalePdf(sale_id){
  try {
    const res = await fetch('/api/sales/' + sale_id + '/pdf');
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      alert('No se pudo generar el PDF: ' + (err.detail || res.status));
      return;
    }
    const blob = await res.blob();
    if (!blob.type.includes('pdf') || blob.size < 500) {
      alert('El PDF salió vacío. Revise el servidor.'); return;
    }
    const cd = res.headers.get('Content-Disposition') || '';
    const m = cd.match(/filename="?([^"]+)"?/);
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = m ? m[1] : `nota_venta_${sale_id}.pdf`;
    document.body.appendChild(link); link.click(); link.remove();
    URL.revokeObjectURL(url);
  } catch (e) { alert('Error de red: ' + e.message); }
}

async function sendWaSale(d){
  await downloadSalePdf(d.sale_id);
  const msg = `Estimad@ cliente le adjunto su nota de venta.`;
  const digits = (d.phone || '').replace(/[^0-9]/g,'');
  const phone = digits.length >= 11 ? digits : '';
  const url = phone ? `https://wa.me/${phone}?text=${encodeURIComponent(msg)}`
                    : `https://wa.me/?text=${encodeURIComponent(msg)}`;
  window.open(url, '_blank');
}

$('#nq').addEventListener('input', () => {
  clearTimeout(window.nt); window.nt = setTimeout(nsearch, 220);
});
$('#nclr').onclick = () => { ncart = []; drawNCart(); };
$('#ngo2').onclick = async () => {
  const m = $('#nmsg2');
  if (!ncart.length) { m.className='msg bad'; m.textContent='Agregue productos primero.'; return; }
  if (!$('#nn').value.trim()) { m.className='msg bad'; m.textContent='Escriba el nombre del cliente.'; return; }
  try {
    const r = await api('/api/sales', {method:'POST', body: JSON.stringify({
      customer: $('#nn').value, customer_nit: $('#nni').value || null,
      customer_phone: $('#nph').value || null,
      lines: ncart.map(c => ({item_id: c.item_id, branch_id: c.branch_id,
                              qty: c.qty}))})});
    m.className = 'msg good';
    m.textContent = `Nota Nº ${r.sale_number} registrada. Stock actualizado.`;
    await sendWaSale({sale_id: r.sale_id, phone: $('#nph').value,
                      customer: $('#nn').value, number: r.sale_number});
    ncart = []; drawNCart();
    $('#nn').value = $('#nni').value = ''; $('#nph').value = '591';
    loadSales();
    // Refresh Buscar too, since stock changed.
    if (view === 'buscar') refresh();
  } catch (e) { m.className='msg bad'; m.textContent = e.message; }
};

// ------------------------------------------------------------------ reports
function dl(url){
  const a = document.createElement('a');
  a.href = url; a.download = ''; document.body.appendChild(a); a.click(); a.remove();
}
function range(){
  const p = new URLSearchParams();
  if ($('#rd').value) p.set('desde', $('#rd').value);
  if ($('#rh').value) p.set('hasta', $('#rh').value);
  return p.toString() ? '&' + p : '';
}
for (const [id, period] of [['x-lines','lines'],['x-daily','daily'],
                            ['x-monthly','monthly'],['x-yearly','yearly']])
  $('#' + id).onclick = () => dl(`/api/export/sales?period=${period}${range()}`);
for (const [id, rep] of [['x-dead','dead-stock'],['x-reorder','reorder'],
                         ['x-pairs','broken-pairs'],['x-prices','price-history'],
                         ['x-accd','acc-daily'],['x-accm','acc-monthly'],
                         ['x-top','top-products'],['x-type','by-type']])
  $('#' + id).onclick = () => dl('/api/export/' + rep);

$('#x-gen').onclick = async () => {
  const m = $('#gmsg');
  m.className = 'msg'; m.textContent = 'Generando…';
  try {
    const r = await api('/api/reports/generate', {method:'POST'});
    const n = Object.values(r.creados).reduce((a, b) => a + b, 0);
    m.className = 'msg good';
    m.textContent = n ? `${n} reporte(s) nuevo(s).` : 'Todo al día, nada nuevo.';
    drawArchive();
  } catch (e) { m.className = 'msg bad'; m.textContent = e.message; }
};

async function drawArchive(){
  const box = $('#arch'); if (!box) return;
  let data;
  try { data = await api('/api/reports/archive'); }
  catch (e) { box.innerHTML = ''; return; }
  box.innerHTML = Object.entries(data).map(([kind, g]) => `
    <details${g.files.length ? ' open' : ''}>
      <summary>${esc(g.label)} — ${g.files.length} archivo(s), se guardan ${esc(g.keep)}</summary>
      ${g.files.length ? `<div style="margin-top:12px">` + g.files.map(f => `
        <div class="bar" style="margin-bottom:6px">
          <span class="code" style="flex:1;min-width:180px">${esc(f.name)}</span>
          <span class="sub">${f.kb} KB · ${esc(f.modified)}</span>
          <button data-k="${kind}" data-f="${esc(f.name)}">Descargar</button>
        </div>`).join('') + '</div>'
        : '<p class="hint">Todavía no hay archivos. Se crean cuando termina un periodo con ventas.</p>'}
    </details>`).join('');
  box.querySelectorAll('[data-f]').forEach(b => b.onclick = () =>
    dl(`/api/reports/${b.dataset.k}/${b.dataset.f}`));
}

// -------------------------------------------------------------- admin panel
function drawAdmin(){
  const el = $('#admin');
  if (user.role !== 'admin') { el.innerHTML = ''; return; }
  el.innerHTML = `
  <details><summary>Producto nuevo</summary>
    <div class="bar">
      <input id="ntp" placeholder="Tipo: espejo, farol…" style="width:150px">
      <input id="nd" placeholder="Descripción" style="flex:2;min-width:200px">
      <input id="nc" placeholder="Código" style="width:120px">
      <select id="ns"><option value="">sin lado</option><option>L</option>
        <option>R</option></select>
      <input id="np" type="number" step="0.01" placeholder="Precio en USD" style="width:140px">
    </div>
    <div class="bar" style="margin-top:8px">
      <span class="sub">opcional:</span>
      <input id="nmk" placeholder="Marca" style="width:120px">
      <input id="nmd" placeholder="Modelo" style="width:120px">
      <input id="nyr" placeholder="Año" style="width:90px">
      <input id="nnk" placeholder="Apodo (CHANCHO)" style="width:140px">
      <button class="primary" id="ngo">Crear</button>
    </div><div class="msg" id="nmsg"></div>
  </details>
  <details><summary>Sucursales</summary>
    <div id="blist"></div>
    <div class="bar">
      <input id="bn" placeholder="Nombre de la sucursal nueva"
             style="flex:1;min-width:200px">
      <button class="primary" id="bgo">Agregar</button>
    </div><div class="msg" id="bmsg"></div>
  </details>`;

  $('#ngo').onclick = async () => {
    const m = $('#nmsg');
    try {
      await api('/api/items', {method:'POST', body: JSON.stringify({
        description: $('#nd').value, part_code: $('#nc').value || null,
        side: $('#ns').value || null,
        price_usd: parseFloat($('#np').value) || null,
        product_type: $('#ntp').value || null, make: $('#nmk').value || null,
        model: $('#nmd').value || null, year_text: $('#nyr').value || null,
        nickname: $('#nnk').value || null})});
      m.className = 'msg good'; m.textContent = 'Producto creado.';
      $('#nd').value = $('#nc').value = $('#np').value = $('#ntp').value =
        $('#nmk').value = $('#nmd').value = $('#nyr').value = $('#nnk').value = '';
      search();
    } catch (e) { m.className = 'msg bad'; m.textContent = e.message; }
  };

  renderBranches();
  $('#bgo').onclick = async () => {
    const m = $('#bmsg');
    try {
      await api('/api/branches', {method:'POST',
        body: JSON.stringify({name: $('#bn').value})});
      $('#bn').value = ''; m.className = 'msg good'; m.textContent = 'Sucursal agregada.';
      await loadBranches(); renderBranches(); draw();
    } catch (e) { m.className = 'msg bad'; m.textContent = e.message; }
  };
}

async function renderBranches(){
  const all = await api('/api/branches');
  const box = $('#blist'); if (!box) return;
  box.innerHTML = all.filter(b => b.is_real).map(b => `
    <div class="bar" style="margin-bottom:8px">
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
