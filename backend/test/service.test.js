import test from 'node:test';
import assert from 'node:assert/strict';
import { createTradingService } from '../src/service.js';

function fixture(identity = { uid: 'alice', email_verified: true, firebase: { sign_in_provider: 'google.com' } }) {
  let state = null;
  const verified = [];
  const trade = createTradingService({
    auth: { async verifyIdToken(...args) { verified.push(args); if (identity === null) throw Error('invalid'); return identity; } },
    database: { ref(path) {
      assert.equal(path, 'revivalPrivate');
      return { async transaction(fn) { state = fn(state); return { committed: true }; } };
    } }
  });
  return { trade, verified };
}
test('shared service verifies revocation and registers only the authenticated identity', async () => {
  const f = fixture();
  const result = await f.trade({ authorization: 'Bearer token', body: { action: 'register' }, byteLength: 21 });
  assert.equal(result.status, 200);
  assert.equal(result.body.inventoryReady, false);
  assert.deepEqual(f.verified, [['token', true]]);
});
test('shared service rejects absent, invalid, unverified and unsupported identities', async () => {
  assert.equal((await fixture().trade({ body: {}, byteLength: 2 })).status, 401);
  for (const [identity, status] of [
    [null, 401],
    [{ uid: 'alice', email_verified: false, firebase: { sign_in_provider: 'google.com' } }, 403],
    [{ uid: 'alice', email_verified: true, firebase: { sign_in_provider: 'custom' } }, 403]
  ]) assert.equal((await fixture(identity).trade({ authorization: 'Bearer token', body: {}, byteLength: 2 })).status, status);
});
test('shared service limits ordinary requests and allows bounded legacy imports', async () => {
  const f = fixture();
  assert.equal((await f.trade({ body: { action: 'status' }, byteLength: 4097 })).status, 413);
  assert.equal((await f.trade({ body: { action: 'importLegacyInventory' }, byteLength: 262145 })).status, 413);
  assert.equal(f.verified.length, 0);
});

test('Google-only trading rejects Game Center and caller-supplied provider claims', async () => {
  const gc = fixture({ uid: 'game-player', firebase: { sign_in_provider: 'gc.apple.com' } });
  assert.equal((await gc.trade({ authorization: 'Bearer token', body: { action: 'register' }, byteLength: 21 })).status, 403);
  assert.deepEqual(gc.verified, [['token', true]]);
  const custom = fixture({ uid: 'game-player', firebase: { sign_in_provider: 'custom' } });
  assert.equal((await custom.trade({ authorization: 'Bearer token', body: { action: 'register', provider: 'google.com', email_verified: true }, byteLength: 100 })).status, 403);
});
