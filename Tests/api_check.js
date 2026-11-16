// Checks the site API abuse limits against a fake in-memory Upstash. Run: node Tests/api_check.js
const assert = require('assert');
process.env.KV_REST_API_URL = 'http://fake'; process.env.KV_REST_API_TOKEN = 't'; process.env.STATS_TOKEN = 'secret';
const db = new Map();
let down = false;
global.fetch = async (_url, opts) => {
  if (down) return { ok: false };
  const out = JSON.parse(opts.body).map(([cmd, k, ...a]) => {
    const v = db.get(k);
    switch (cmd) {
      case 'SET': if (a.includes('NX') && db.has(k)) return { result: null }; db.set(k, a[0]); return { result: 'OK' };
      case 'INCR': db.set(k, Number(v || 0) + 1); return { result: db.get(k) };
      case 'GET': return { result: v ?? null };
      case 'HINCRBY': return { result: 1 };
      case 'SMEMBERS': case 'HGETALL': return { result: [] };
      case 'SADD': case 'PFADD': (v || db.set(k, new Set()).get(k)).add(a[0]); return { result: 1 };
      default: return { result: null };
    }
  });
  return { ok: true, json: async () => out };
};
const res = () => { const r = { code: 0, headers: {}, setHeader(k, v) { r.headers[k] = v; }, writeHead(c, h) { r.code = c; Object.assign(r.headers, h); }, end() {}, status(c) { r.code = c; return r; }, json(b) { r.body = b; return r; } }; return r; };
const req = (ip, extra = {}) => ({ headers: { 'x-real-ip': ip, ...extra.headers }, query: extra.query || {} });
const dl = require('../site/api/dl.js'), version = require('../site/api/version.js'), stats = require('../site/api/stats.js');

(async () => {
  for (let i = 0; i < 10; i++) { const r = res(); await dl(req('1.1.1.1'), r); assert.strictEqual(r.code, 302); }
  assert.strictEqual(db.get('dl:total'), 3, 'one IP counts at most 3 downloads per hour');

  await version(req('2.2.2.2', { query: { id: '<script>', v: '17' } }), res());
  await version(req('2.2.2.2', { query: { id: '6F1C2E3A-1111-2222-3333-444455556666', v: 'x<b>' } }), res());
  assert(!db.has('versions'), 'malformed id or build is not counted');
  const r0 = res(); await version(req('2.2.2.2', { query: { id: '6F1C2E3A-1111-2222-3333-444455556666', v: '17' } }), r0);
  assert.strictEqual(r0.code, 200); assert(db.get('versions').has('17'));

  for (let i = 0; i < 10; i++) { const r = res(); await stats(req('3.3.3.3', { headers: { authorization: 'Bearer ' + i } }), r); assert.strictEqual(r.code, 401); }
  const locked = res(); await stats(req('3.3.3.3', { headers: { authorization: 'Bearer secret' } }), locked);
  assert.strictEqual(locked.code, 429, 'IP locked after 10 wrong tries, even with the right token');
  down = true; const r503 = res(); await stats(req('4.4.4.4', { headers: { authorization: 'Bearer x' } }), r503);
  assert.strictEqual(r503.code, 503, 'fails closed when storage is down'); down = false;
  for (let i = 0; i < 40; i++) await stats(req('5.5.5.' + i, { headers: { authorization: 'Bearer bad' } }), res());
  const g = res(); await stats(req('9.9.9.9', { headers: { authorization: 'Bearer secret' } }), g);
  assert.strictEqual(g.code, 429, 'global lock after 50 wrong tries per hour');
  db.delete('rl:stats:all'); const ok = res(); await stats(req('9.9.9.9', { headers: { authorization: 'Bearer secret' } }), ok);
  assert.notStrictEqual(ok.code, 401); assert.notStrictEqual(ok.code, 429);
  console.log('api ok');
})().catch(e => { console.error(e); process.exit(1); });
