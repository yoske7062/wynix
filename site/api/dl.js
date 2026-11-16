// Counts a download, then sends the browser to the DMG. Usage: /api/dl
// Each IP counts at most 3 downloads per hour, so the counter can't be inflated by a loop.
const { pipeline, day, clean, ipKey, hit } = require('./_redis');

module.exports = async (req, res) => {
  const cc = clean(req.headers['x-vercel-ip-country'], 2) || 'XX';
  try {
    const n = await hit(`rl:dl:${ipKey(req)}`);
    if (n !== null && n <= 3) {
      await pipeline([
        ['INCR', 'dl:total'],
        ['INCR', `dl:${day()}`],
        ['HINCRBY', 'dl:country', cc, 1],
      ]);
    }
  } catch (_) { /* counting must never block the download */ }
  res.setHeader('Cache-Control', 'no-store');
  res.writeHead(302, { Location: '/downloads/WYNIX.dmg' });
  res.end();
};
