// Update feed for the app + anonymous usage count.
// The app calls /api/version?id=<random install id>&v=<build>. No personal data.
const { pipeline, day, clean } = require('./_redis');
const release = require('../version.json');

module.exports = async (req, res) => {
  const id = clean(req.query.id, 64);
  const v = clean(req.query.v, 10);
  if (id) {
    try {
      await pipeline([
        ['PFADD', 'installs', id],
        ['PFADD', `active:${day()}`, id],
        ['INCR', `opens:${day()}`],
        ['PFADD', `ver:${v || 'unknown'}`, id],
        ['SADD', 'versions', v || 'unknown'],
      ]);
    } catch (_) {}
  }
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json(release);
};
