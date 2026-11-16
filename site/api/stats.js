// KPI data for /kpi.html. Requires header "Authorization: Bearer <STATS_TOKEN>".
// Brute-force guard: 10 wrong tries per IP per hour, 50 wrong tries per hour in total.
// It fails closed: if storage is down, no password is checked at all.
const crypto = require('crypto');
const { pipeline, day, ipKey } = require('./_redis');

const same = (a, b) => {
  const x = crypto.createHash('sha256').update(a).digest();
  const y = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(x, y);
};

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  const token = process.env.STATS_TOKEN;
  if (!token) return res.status(401).json({ error: 'unauthorized' });
  const ipFails = `rl:stats:${ipKey(req)}`;
  const fails = await pipeline([['GET', ipFails], ['GET', 'rl:stats:all']]);
  if (!fails) return res.status(503).json({ error: 'storage not connected' });
  if (Number(fails[0] || 0) >= 10 || Number(fails[1] || 0) >= 50) {
    return res.status(429).json({ error: 'too many attempts, try again in an hour' });
  }
  if (!same(String(req.headers.authorization || ''), `Bearer ${token}`)) {
    await pipeline([
      ['SET', ipFails, 0, 'EX', 3600, 'NX'], ['INCR', ipFails],
      ['SET', 'rl:stats:all', 0, 'EX', 3600, 'NX'], ['INCR', 'rl:stats:all'],
    ]);
    return res.status(401).json({ error: 'unauthorized' });
  }
  const days = [];
  for (let i = 29; i >= 0; i--) days.push(day(new Date(Date.now() - i * 86400000)));
  const head = await pipeline([['GET', 'dl:total'], ['PFCOUNT', 'installs'], ['HGETALL', 'dl:country'], ['SMEMBERS', 'versions'], ['GET', 'donors']]);
  if (!head) return res.status(503).json({ error: 'storage not connected' });
  const [dlTotal, installs, countryFlat, versions, donors] = head;
  const series = await pipeline(days.flatMap(d => [['GET', `dl:${d}`], ['PFCOUNT', `active:${d}`], ['GET', `opens:${d}`]]));
  const verCounts = versions.length ? await pipeline(versions.map(v => ['PFCOUNT', `ver:${v}`])) : [];
  const country = {};
  for (let i = 0; i < (countryFlat || []).length; i += 2) country[countryFlat[i]] = Number(countryFlat[i + 1]);
  res.status(200).json({
    downloads: Number(dlTotal || 0),
    installs: Number(installs || 0),
    donors: Number(donors || 0),
    country,
    versions: Object.fromEntries(versions.map((v, i) => [v, Number(verCounts[i] || 0)])),
    days: days.map((d, i) => ({
      day: d,
      downloads: Number(series[i * 3] || 0),
      active: Number(series[i * 3 + 1] || 0),
      opens: Number(series[i * 3 + 2] || 0),
    })),
  });
};
