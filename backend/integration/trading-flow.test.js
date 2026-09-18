import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { createTradingHTTPServer } from '../src/http-server.js';
import { createTradingService } from '../src/service.js';

let state = null;
const identity = {
  uid: 'device-user',
  email_verified: true,
  firebase: { sign_in_provider: 'google.com' }
};

const trade = createTradingService({
  auth: {
    async verifyIdToken(token, checkRevoked) {
      assert.equal(token, 'device-token');
      assert.equal(checkRevoked, true);
      return identity;
    }
  },
  database: {
    ref(path) {
      assert.equal(path, 'revivalPrivate');
      return {
        async transaction(fn) {
          state = fn(state);
          return { committed: true };
        }
      };
    }
  },
  testPartnerEnabled: true
});

const server = createTradingHTTPServer(trade);
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
after(() => new Promise(resolve => server.close(resolve)));

const headers = {
  'Content-Type': 'application/json',
  Authorization: 'Bearer device-token'
};

async function post(body) {
  const response = await fetch(base + '/trading', {
    method: 'POST',
    headers,
    body: JSON.stringify(body)
  });
  return { status: response.status, body: await response.json() };
}

test('full HTTP Random flow reaches service and auto-pairs a test partner', async () => {
  assert.equal((await fetch(base + '/healthz')).status, 200);

  const registered = await post({ action: 'register' });
  assert.equal(registered.status, 200);
  assert.equal(registered.body.inventoryReady, false);

  const imported = await post({
    action: 'importLegacyInventory',
    preserveFirstCopy: true,
    inventory: { coins: 1000, cards: { cardA: 2 } }
  });
  assert.equal(imported.status, 200);
  assert.equal(imported.body.inventoryReady, true);

  const queued = await post({ action: 'queue', scope: 'g:0:a:0' });
  assert.equal(queued.status, 200);
  assert.equal(queued.body.queued, false);
  assert.equal(queued.body.room.status, 'open');
  assert.equal(queued.body.room.members.length, 2);
  assert.equal(queued.body.room.testPartner, true);

  const status = await post({ action: 'status', roomId: queued.body.room.id });
  assert.equal(status.status, 200);
  assert.equal(status.body.room.members.length, 2);
  assert.equal(status.body.room.id, queued.body.room.id);

  // Continue like a normal user performing a safe zero-value trade. The
  // synthetic partner mirrors Ready/Confirm only for an empty offer, so this
  // exercises the full room lifecycle without minting or consuming inventory.
  const ready = await post({
    action: 'ready',
    roomId: queued.body.room.id,
    revision: status.body.room.revision
  });
  assert.equal(ready.status, 200);
  assert.equal(ready.body.room.status, 'open');
  assert.equal(Object.keys(ready.body.room.ready).length, 2);

  const confirmed = await post({
    action: 'confirm',
    roomId: queued.body.room.id,
    revision: ready.body.room.revision
  });
  assert.equal(confirmed.status, 200);
  assert.equal(confirmed.body.room.status, 'completed');
  assert.equal(confirmed.body.room.testPartner, true);
  assert.equal(Object.keys(confirmed.body.room.confirmed).length, 2);
  assert.ok(Object.keys(confirmed.body.room.handshakes).length >= 1);

  const completedStatus = await post({ action: 'status', roomId: queued.body.room.id });
  assert.equal(completedStatus.status, 200);
  assert.equal(completedStatus.body.room.status, 'completed');
  assert.equal(completedStatus.body.room.members.length, 2);
});
