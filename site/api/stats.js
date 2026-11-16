// KPI data for /kpi.html. Requires header "Authorization: Bearer <STATS_TOKEN>".
const { pipeline, day } = require('./_redis');

module.exports = async (req, res) => {
  const token = process.env.STATS_TOKEN;
  if (!token || req.headers.authorization !== `Bearer ${token}`) {
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
  res.setHeader('Cache-Control', 'no-store');
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
