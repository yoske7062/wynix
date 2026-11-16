const root = document.getElementById('root');
const getToken = () => { try { return localStorage.getItem('wynixToken') || ''; } catch { return ''; } };
const setToken = t => { try { localStorage.setItem('wynixToken', t); } catch {} };
const fmt = n => n.toLocaleString('es-CL');

function login(msg) {
  root.innerHTML = `<form id="f"><h1><b>W</b>YNIX KPIs</h1><input id="t" type="password" placeholder="Clave del panel" autocomplete="current-password"><button>Entrar</button>${msg ? `<p class="err">${msg}</p>` : ''}</form>`;
  document.getElementById('f').onsubmit = e => { e.preventDefault(); setToken(document.getElementById('t').value.trim()); load(); };
}

function bars(days) {
  const W = 700, H = 200, pad = 24, n = days.length, bw = (W - pad) / n;
  const max = Math.max(1, ...days.map(d => Math.max(d.downloads, d.active)));
  let g = '';
  days.forEach((d, i) => {
    const x = pad + i * bw, h1 = (d.downloads / max) * (H - 30), h2 = (d.active / max) * (H - 30);
    g += `<rect x="${x + 1}" y="${H - 20 - h1}" width="${bw / 2 - 1}" height="${h1}" rx="2" fill="#E05A83"><title>${d.day}: ${d.downloads} descargas</title></rect>`;
    g += `<rect x="${x + bw / 2}" y="${H - 20 - h2}" width="${bw / 2 - 1}" height="${h2}" rx="2" fill="#7aa7ff"><title>${d.day}: ${d.active} usuarios activos</title></rect>`;
    if (i % 5 === 0) g += `<text x="${x}" y="${H - 4}" fill="#777" font-size="10">${d.day.slice(5)}</text>`;
  });
  g += `<text x="0" y="12" fill="#777" font-size="10">${max}</text>`;
  return `<svg viewBox="0 0 ${W} ${H}">${g}</svg>`;
}

const sum = (a, k) => a.reduce((s, d) => s + d[k], 0);

async function load() {
  const t = getToken();
  if (!t) return login();
  let r;
  try { r = await fetch('/api/stats', { headers: { Authorization: 'Bearer ' + t }, cache: 'no-store' }); }
  catch { return login('Sin conexión.'); }
  if (r.status === 401) return login('Clave incorrecta.');
  if (r.status === 429) return login('Demasiados intentos. Espera una hora.');
  if (r.status === 503) { root.innerHTML = '<p class="err" style="margin-top:80px">La base de datos todavía no está conectada en Vercel.</p>'; return; }
  const s = await r.json();
  const d7 = s.days.slice(-7), today = s.days[s.days.length - 1];
  const conv = s.downloads ? Math.round((s.installs / s.downloads) * 100) : 0;
  const goal = 100, pct = Math.min(100, Math.round((s.downloads / goal) * 100));
  const countries = Object.entries(s.country).sort((a, b) => b[1] - a[1]).slice(0, 8);
  const versions = Object.entries(s.versions).sort((a, b) => Number(b[0]) - Number(a[0]));
  root.innerHTML = `
  <header><h1><b>W</b>YNIX KPIs</h1><span class="upd">Actualizado ${new Date().toLocaleString('es-CL')} · <a href="#" id="out" style="color:inherit">salir</a></span></header>
  <div class="tiles">
    <div class="tile"><span>Descargas totales</span><b>${fmt(s.downloads)}</b><small>${fmt(sum(d7, 'downloads'))} en 7 días · ${fmt(today.downloads)} hoy</small></div>
    <div class="tile"><span>Instalaciones (abrieron la app)</span><b>${fmt(s.installs)}</b><small>${conv}% de las descargas</small></div>
    <div class="tile"><span>Usuarios activos hoy</span><b>${fmt(today.active)}</b><small>${fmt(sum(d7, 'opens'))} aperturas en 7 días</small></div>
    <div class="tile"><span>Donadores</span><b>${fmt(s.donors)}</b><small>Se anota a mano por ahora</small></div>
  </div>
  <div class="grid">
    <div class="card"><h2>Últimos 30 días</h2>${bars(s.days)}
      <div class="legend"><span><i style="background:#E05A83"></i>Descargas</span><span><i style="background:#7aa7ff"></i>Usuarios activos</span></div></div>
    <div class="card"><h2>Regla: ¿cobrar o no?</h2>
      <p>Si llegamos a ${goal} descargas sin donadores, se evalúa cobrar.</p>
      <div class="rule"><div class="bar"><i style="width:${pct}%"></i></div><small style="color:var(--gray)">${fmt(s.downloads)} de ${goal} descargas · ${s.donors} donadores</small></div>
    </div>
  </div>
  <div class="grid">
    <div class="card"><h2>Descargas por país</h2><div class="list">${countries.map(([c, n]) => `<div><span>${c}</span><span>${fmt(n)}</span></div>`).join('') || '<div><span>Sin datos todavía</span></div>'}</div></div>
    <div class="card"><h2>Versiones en uso</h2><div class="list">${versions.map(([v, n]) => `<div><span>Build ${v}</span><span>${fmt(n)}</span></div>`).join('') || '<div><span>Sin datos todavía</span></div>'}</div></div>
  </div>`;
  document.getElementById('out').onclick = e => { e.preventDefault(); setToken(''); login(); };
}
load();
