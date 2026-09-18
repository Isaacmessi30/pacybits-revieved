import test from 'node:test';
import assert from 'node:assert/strict';
import { accountKey } from '../src/trading.js';
import { transitionWithTestPartner } from '../src/test-partner.js';

function fixture(enabled = true) {
  let state = null, now = 100000, count = 0;
  return {
    get state() { return state; },
    call(input, uid = 'alice') {
      const result = transitionWithTestPartner(state, uid, input, now += 4000, `room-${++count}`, enabled);
      state = result.state;
      return result;
    },
    initialize(uid = 'alice') {
      this.call({ action: 'register' }, uid);
      this.call({ action: 'importLegacyInventory', preserveFirstCopy: true,
        inventory: { coins: 100, cards: { A: 2 } } }, uid);
    }
  };
}
test('test partner joins and completes only an empty exchange without changing balances', () => {
  const f = fixture(); f.initialize();
  const original = structuredClone(f.state.accounts[accountKey('alice')]);
  const invite = f.call({ action: 'invite' });
  const room = invite.body.room;
  assert.equal(room.members.length, 2);
  assert.equal(room.self, accountKey('alice'));
  assert.equal(room.testPartner, true);
  const ready = f.call({ action: 'ready', roomId: room.id, revision: room.revision });
  assert.equal(Object.keys(ready.body.room.ready).length, 2);
  const confirm = { action: 'confirm', roomId: room.id, revision: room.revision };
  const completed = f.call(confirm);
  assert.equal(completed.body.room.status, 'completed');
  assert.ok(completed.body.room.handshakes);
  const peer = completed.body.room.members.find(member => member !== completed.body.room.self);
  assert.equal(typeof completed.body.room.handshakes[peer], 'string');
  assert.ok(completed.body.room.handshakes[peer].length > 0);
  assert.equal(f.call(confirm).body.room.status, 'completed');
  const final = f.state.accounts[accountKey('alice')];
  assert.equal(final.coins, original.coins);
  assert.deepEqual(final.cards, original.cards);
  assert.equal(final.inventoryVersion, original.inventoryVersion + 1);
});
test('test partner accepts offers for UI testing but cannot auto-settle a non-empty trade', () => {
  const f = fixture(); f.initialize();
  let room = f.call({ action: 'invite' }).body.room;
  let offered = f.call({ action: 'offer', roomId: room.id, revision: room.revision,
    offer: { coins: 1, cards: ['A'], slots: [0] } });
  assert.equal(offered.status, 200);
  room = offered.body.room;
  const ready = f.call({ action: 'ready', roomId: room.id, revision: room.revision });
  assert.equal(Object.keys(ready.body.room.ready).length, 2);
  const confirmed = f.call({ action: 'confirm', roomId: room.id, revision: room.revision });
  assert.equal(confirmed.body.room.status, 'open');
  assert.equal(f.state.accounts[accountKey('alice')].coins, 100);
  assert.deepEqual(f.state.accounts[accountKey('alice')].cards, { A: 2 });

  const normal = fixture(false); normal.initialize();
  assert.equal(normal.call({ action: 'invite', testPartner: true }).body.error, 'UNEXPECTED_FIELD');
  assert.equal(normal.call({ action: 'invite' }).body.room.members.length, 1);
});
test('unrelated players cannot join or inspect the simulated room', () => {
  const f = fixture(); f.initialize(); f.initialize('bob');
  const room = f.call({ action: 'invite' }).body.room;
  assert.equal(f.call({ action: 'join', roomId: room.id }, 'bob').status, 404);
  assert.equal(f.call({ action: 'status', roomId: room.id }, 'bob').status, 404);
});
