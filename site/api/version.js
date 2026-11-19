// Update feed for the app + anonymous usage count.
// The app calls /api/version?id=<random install id>&v=<build>. No personal data.
// Only well-formed ids (UUID) and builds (digits) are counted, at most 30 per IP per hour.
const { pipeline, day, ipKey, hit } = require('./_redis');
const release = require('../version.json');

const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

module.exports = async (req, res) => {
  const id = String(req.query.id || '');
  const v = String(req.query.v || '');
  if (UUID.test(id) && /^\d{1,5}$/.test(v)) {
    try {
      const n = await hit(`rl:ver:${ipKey(req)}`);
      if (n !== null && n <= 30) {
        await pipeline([
          ['PFADD', 'installs', id],
          ['PFADD', `active:${day()}`, id],
          ['INCR', `opens:${day()}`],
          ['PFADD', `ver:${v}`, id],
          ['SADD', 'versions', v],
        ]);
      }
    } catch (_) {}
  }
  res.setHeader('Cache-Control', 'no-store');
  // Builds <= 0.21 only accept downloads from wynix.vercel.app; keep them updatable.
  const old = req.headers.host === 'wynix.vercel.app';
  res.status(200).json(old ? { ...release, url: 'https://wynix.vercel.app/api/dl' } : release);
};
