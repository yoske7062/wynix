// Minimal Upstash Redis REST client (env vars set by the Vercel Upstash integration).
const URL_ = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

async function pipeline(commands) {
  if (!URL_ || !TOKEN) return null; // storage not connected yet: never break downloads/updates
  const r = await fetch(`${URL_}/pipeline`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(commands),
  });
  if (!r.ok) return null;
  return (await r.json()).map(x => x.result);
}

const day = (d = new Date()) => d.toISOString().slice(0, 10);
const clean = (s, max = 40) => String(s || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, max);

// Abuse limits. Vercel sets x-real-ip from the real connection (clients can't spoof it).
// Only a truncated SHA-256 of the IP is stored, and every key expires within the hour.
const ipKey = req => require('crypto').createHash('sha256')
  .update(String(req.headers['x-real-ip'] || 'unknown')).digest('hex').slice(0, 16);

// Adds 1 to a counter that lives `ttl` seconds; returns the new count, or null if storage is down.
async function hit(key, ttl = 3600) {
  const r = await pipeline([['SET', key, 0, 'EX', ttl, 'NX'], ['INCR', key]]);
  return r ? Number(r[1]) : null;
}

module.exports = { pipeline, day, clean, ipKey, hit };
