import { createServer } from 'node:http';

export function createTradingHTTPServer(trade) {
  let active = 0;
  const server = createServer(async (req, res) => {
    const reply = (status, body, extra = {}) => {
      const path = req.url?.split('?')[0] ?? '';
      const rawProbe = req.headers['x-revival-probe'];
      const safeProbes = [
        'bootstrap', 'random-tap', 'auth-start', 'auth-session-ok',
        'auth-login-start', 'auth-login-ok', 'auth-session-error',
        'register-start', 'register-ok',
        'bridge-direct-call', 'bridge-direct-failed', 'bridge-direct-return'
      ];
      const probe = safeProbes.includes(rawProbe) ? rawProbe : undefined;
      console.log(JSON.stringify({ event: 'http', method: req.method, path, status, ...(probe ? { probe } : {}) }));
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff', ...extra });
      res.end(JSON.stringify(body));
    };
    if (req.url === '/healthz' && req.method === 'GET') return reply(200, { ok: true });
    if (req.url !== '/trading') return reply(404, { error: 'NOT_FOUND' }, { Connection: 'close' });
    if (req.method !== 'POST') return reply(405, { error: 'POST_REQUIRED' }, { Allow: 'POST', Connection: 'close' });
    if (req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
      return reply(415, { error: 'JSON_REQUIRED' }, { Connection: 'close' });
    }
    if (!/^Bearer [^\s]+$/.test(req.headers.authorization ?? '')) {
      return reply(401, { error: 'AUTH_REQUIRED' }, { Connection: 'close' });
    }
    if (active >= 20) return reply(503, { error: 'SERVER_BUSY' }, { 'Retry-After': '3', Connection: 'close' });
    if (Number(req.headers['content-length']) > 262144) {
      return reply(413, { error: 'REQUEST_TOO_LARGE' }, { Connection: 'close' });
    }
    active += 1;
    try {
      const chunks = [];
      let length = 0;
      for await (const chunk of req.iterator({ destroyOnReturn: false })) {
        length += chunk.length;
        if (length > 262144) {
          reply(413, { error: 'REQUEST_TOO_LARGE' }, { Connection: 'close' });
          return;
        }
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { return reply(400, { error: 'INVALID_JSON' }); }
      const result = await trade({ authorization: req.headers.authorization, body, byteLength: length });
      reply(result.status, result.body);
    } catch {
      if (!res.headersSent && !res.destroyed) reply(503, { error: 'TEMPORARILY_UNAVAILABLE' });
    } finally { active -= 1; }
  });
  server.headersTimeout = 10000;
  server.requestTimeout = 15000;
  server.keepAliveTimeout = 5000;
  server.maxRequestsPerSocket = 100;
  return server;
}
