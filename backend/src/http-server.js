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
        'bridge-direct-call', 'bridge-direct-failed', 'bridge-direct-return',
        'native-start', 'native-no-helper', 'native-helper-type-failed',
        'native-no-selector', 'native-callback', 'native-return', 'native-exception',
        'screen-found', 'screen-missing',
        'sender-ready', 'sender-accept', 'sender-wishlist', 'sender-picked', 'sender-other',
        'fallback-ready-pan', 'fallback-ready', 'fallback-wishlist', 'fallback-leave'
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

      const safeActions = new Set([
        'register', 'importLegacyInventory', 'replaceInventory', 'status',
        'queue', 'leaveQueue', 'invite', 'join', 'setWishlist', 'ready', 'confirm',
        'offer', 'cancel', 'signal', 'nativeHandshake', 'botWishlist', 'botPeerHandshake'
      ]);
      const action = safeActions.has(body?.action) ? body.action : 'unknown';
      const room = result.body?.room;
      const tradingLog = {
        event: 'trading',
        action,
        status: result.status,
        ...(action === 'queue' && typeof body?.scope === 'string'
          ? { scope: String(body.scope).slice(0, 128) }
          : {}),
        ...(typeof result.body?.queued === 'boolean' ? { queued: result.body.queued } : {}),
        ...(action === 'setWishlist' && Array.isArray(result.body?.wishlist)
          ? { wishlistCount: result.body.wishlist.length }
          : {}),
        ...(action === 'offer' && Array.isArray(body?.offer?.cards)
          ? { offerCardCount: body.offer.cards.length }
          : {}),
        ...(action === 'signal' && typeof body?.signalType === 'string'
          ? { signalType: body.signalType.slice(0, 64) }
          : {}),
        ...(room ? {
          roomStatus: room.status,
          members: Array.isArray(room.members) ? room.members.length : undefined,
          testPartner: room.testPartner === true,
          botPartner: room.botPartner === true,
          ...(Array.isArray(room.wishlists?.[room.self])
            ? { selfWishlistCount: room.wishlists[room.self].length }
            : {})
        } : {})
      };
      console.log(JSON.stringify(tradingLog));

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
