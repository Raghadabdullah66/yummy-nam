const ALLOWED_ORIGIN = 'https://raghadabdullah66.github.io';

function cors(origin) {
  const allow = origin === ALLOWED_ORIGIN ? origin : ALLOWED_ORIGIN;
  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Vary': 'Origin',
  };
}

function json(data, status, origin) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: { 'Content-Type': 'application/json', ...cors(origin) },
  });
}

const b64url = (buf) => {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

async function sha256Hex(text) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function vapidAuthHeader(endpoint, env) {
  const aud = new URL(endpoint).origin;
  const header = b64url(new TextEncoder().encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const payload = b64url(new TextEncoder().encode(JSON.stringify({
    aud,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: env.VAPID_SUBJECT,
  })));
  const key = await crypto.subtle.importKey(
    'jwk',
    JSON.parse(env.VAPID_PRIVATE_JWK),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  );
  const sig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(header + '.' + payload)
  );
  const jwt = header + '.' + payload + '.' + b64url(sig);
  return 'vapid t=' + jwt + ', k=' + env.VAPID_PUBLIC_KEY;
}

async function sendEmptyPush(endpoint, env) {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      TTL: '3600',
      Authorization: await vapidAuthHeader(endpoint, env),
      'Content-Length': '0',
    },
  });
  return res.status;
}

async function handleReminder(request, env, origin) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'bad json' }, 400, origin);
  }
  const endpoint = body && body.subscription && body.subscription.endpoint;
  if (typeof endpoint !== 'string' || !endpoint.startsWith('https://')) {
    return json({ error: 'bad endpoint' }, 400, origin);
  }
  const key = 'r:' + (await sha256Hex(endpoint));
  if (body.cancel) {
    await env.REMINDERS.delete(key);
    return json({ ok: true, cancelled: true }, 200, origin);
  }
  const delay = Math.min(Math.max(parseInt(body.delayMinutes, 10) || 60, 1), 24 * 60);
  const dueAt = Date.now() + delay * 60 * 1000;
  await env.REMINDERS.put(key, JSON.stringify({ endpoint, dueAt }), {
    expirationTtl: delay * 60 + 3600,
  });
  return json({ ok: true, dueAt }, 200, origin);
}

async function runDueReminders(env) {
  const now = Date.now();
  let cursor;
  do {
    const page = await env.REMINDERS.list({ prefix: 'r:', cursor });
    for (const k of page.keys) {
      const raw = await env.REMINDERS.get(k.name);
      if (!raw) continue;
      const item = JSON.parse(raw);
      if (item.dueAt > now) continue;
      try {
        const status = await sendEmptyPush(item.endpoint, env);
        if (status === 404 || status === 410 || (status >= 200 && status < 300)) {
          await env.REMINDERS.delete(k.name);
        }
      } catch {
        // keep the reminder so the next cron run retries it
      }
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors(origin) });
    }
    if (request.method === 'GET' && url.pathname === '/vapid-public-key') {
      return json({ key: env.VAPID_PUBLIC_KEY }, 200, origin);
    }
    if (request.method === 'POST' && url.pathname === '/reminder') {
      return handleReminder(request, env, origin);
    }
    return json({ error: 'not found' }, 404, origin);
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(runDueReminders(env));
  },
};
