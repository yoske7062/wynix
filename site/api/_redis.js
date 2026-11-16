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

module.exports = { pipeline, day, clean };
