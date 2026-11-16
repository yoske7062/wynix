// Counts a download, then sends the browser to the DMG. Usage: /api/dl
const { pipeline, day, clean } = require('./_redis');

module.exports = async (req, res) => {
  const cc = clean(req.headers['x-vercel-ip-country'], 2) || 'XX';
  try {
    await pipeline([
      ['INCR', 'dl:total'],
      ['INCR', `dl:${day()}`],
      ['HINCRBY', 'dl:country', cc, 1],
    ]);
  } catch (_) { /* counting must never block the download */ }
  res.setHeader('Cache-Control', 'no-store');
  res.writeHead(302, { Location: '/downloads/WYNIX.dmg' });
  res.end();
};
