import test from 'node:test';
import assert from 'node:assert/strict';
import { accountKey, emptyState, transition, ROOM_TTL_MS, QUEUE_TTL_MS } from '../src/trading.js';

function fixture() {
  let state = emptyState();
  let now = 1_000_000;
  let counter = 0;
  for (const uid of ['alice', 'bob', 'charlie']) {
    state.accounts[accountKey(uid)] = { allowed: true, coins: 100, cards: { cardA: 2, cardB: 1 } };
  }
  return {
    get state() { return state; },
    advance(ms) { now += ms; },
    call(uid, input) {
      const before = structuredClone(state);
      const result = transition(state, uid, input, now, `room-${++counter}`);
      assert.deepEqual(state, before, 'transition must not mutate its input');
      state = result.state;
      return result;
    }
  };
}
function pair(f) {
  const first = f.call('alice', { action: 'invite' });
  assert.equal(first.status, 200);
  const id = first.body.room.id;
  const second = f.call('bob', { action: 'join', roomId: id });
  assert.equal(second.status, 200);
  return id;
}
function exchange(f, id) {
  let r = f.state.rooms[id].revision;
  assert.equal(f.call('alice', { action: 'offer', roomId: id, revision: r++, offer: { coins: 40, cards: ['cardA'] } }).status, 200);
  assert.equal(f.call('bob', { action: 'offer', roomId: id, revision: r++, offer: { coins: 10, cards: ['cardB'] } }).status, 200);
  for (const uid of ['alice', 'bob']) {
    assert.equal(f.call(uid, { action: 'ready', roomId: id, revision: r }).status, 200);
  }
  return r;
}
test('atomic exchange conserves coins and cards; repeated confirmation does not transfer twice', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  const req = { action: 'confirm', roomId: id, revision };
  assert.equal(f.call('alice', req).body.room.status, 'open');
  assert.equal(f.state.accounts[accountKey('alice')].coins, 100);
  assert.equal(f.call('bob', req).body.room.status, 'completed');
  for (let i = 0; i < 3; i++) assert.equal(f.call('bob', req).body.room.status, 'completed');
  const a = f.state.accounts[accountKey('alice')], b = f.state.accounts[accountKey('bob')];
  assert.equal(a.coins, 70); assert.equal(b.coins, 130);
  assert.deepEqual(a.cards, { cardA: 1, cardB: 2 });
  assert.deepEqual(b.cards, { cardA: 3 });
  assert.equal(a.activeRoom, undefined); assert.equal(b.activeRoom, undefined);
});
test('offers invalidate both readiness and confirmations, including a previously accepted side', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.call('alice', { action: 'confirm', roomId: id, revision });
  f.call('bob', { action: 'offer', roomId: id, revision, offer: { coins: 0, cards: [] } });
  assert.deepEqual(f.state.rooms[id].ready, {});
  assert.deepEqual(f.state.rooms[id].confirmed, {});
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision }).body.error, 'STALE_REVISION');
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision: revision + 1 }).body.error, 'BOTH_PLAYERS_MUST_BE_READY');
});
test('unapproved accounts cannot read or trade and cannot approve themselves', () => {
  const f = fixture();
  assert.equal(f.call('outsider', { action: 'status', allowed: true }).status, 403);
  assert.equal(f.state.accounts[accountKey('outsider')], undefined);
});
test('third parties cannot inspect, edit, confirm or cancel rooms', () => {
  const f = fixture(), id = pair(f);
  for (const action of ['status', 'offer', 'ready', 'confirm', 'cancel']) {
    const req = { action, roomId: id };
    if (['offer', 'ready', 'confirm'].includes(action)) req.revision = 1;
    if (action === 'offer') req.offer = { coins: 0, cards: [] };
    assert.equal(f.call('charlie', req).status, 404);
  }
});
test('join token only admits one partner and one active room is enforced', () => {
  const f = fixture(), id = pair(f);
  assert.equal(f.call('charlie', { action: 'join', roomId: id }).status, 404);
  f.advance(3001);
  assert.equal(f.call('alice', { action: 'invite' }).body.error, 'ALREADY_IN_TRADE');
});
test('forged balances, negative amounts and unknown fields are rejected', () => {
  const f = fixture(), id = pair(f);
  for (const coins of [-1, 0.5, 101, Number.MAX_SAFE_INTEGER, '10']) {
    assert.notEqual(f.call('alice', { action: 'offer', roomId: id, revision: 1, offer: { coins, cards: [] } }).status, 200);
  }
  assert.equal(f.call('alice', { action: 'status', uid: 'bob' }).body.error, 'UNEXPECTED_FIELD');
  assert.equal(f.call('alice', { action: 'offer', roomId: id, revision: 1, offer: { coins: 0, cards: [], inventory: {} } }).body.error, 'INVALID_OFFER');
});
test('unowned, repeated, unsafe and too many cards are rejected', () => {
  const f = fixture(), id = pair(f);
  for (const cards of [['missing'], ['cardA', 'cardA'], ['a', 'b', 'c', 'd'], ['../x'], ['__proto__'], [null]]) {
    assert.notEqual(f.call('alice', { action: 'offer', roomId: id, revision: 1, offer: { coins: 0, cards } }).status, 200);
  }
});
test('ownership is rechecked at settlement; failure rolls back both sides', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.call('alice', { action: 'confirm', roomId: id, revision });
  f.state.accounts[accountKey('alice')].cards.cardA = 0;
  const before = structuredClone(f.state);
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision }).body.error, 'CARD_NOT_OWNED');
  for (const uid of ['alice', 'bob']) {
    const key = accountKey(uid);
    assert.equal(f.state.accounts[key].coins, before.accounts[key].coins);
    assert.deepEqual(f.state.accounts[key].cards, before.accounts[key].cards);
  }
  assert.equal(f.state.rooms[id].confirmed[accountKey('bob')], undefined);
});
test('settlement overflow cannot cause partial balances or inventory writes', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.state.accounts[accountKey('bob')].cards.cardA = 1_000_000;
  f.call('alice', { action: 'confirm', roomId: id, revision });
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision }).body.error, 'CARD_LIMIT');
  assert.equal(f.state.accounts[accountKey('alice')].coins, 100);
  assert.equal(f.state.accounts[accountKey('bob')].coins, 100);
});
test('expired rooms release both account locks and reject confirmation', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.advance(ROOM_TTL_MS);
  assert.equal(f.call('alice', { action: 'confirm', roomId: id, revision }).body.error, 'ROOM_CLOSED');
  for (const uid of ['alice', 'bob']) assert.equal(f.state.accounts[accountKey(uid)].activeRoom, undefined);
  assert.equal(f.call('alice', { action: 'invite' }).status, 200);
});
test('cancelled rooms cannot settle and replay cannot affect the next room', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.call('alice', { action: 'cancel', roomId: id });
  f.advance(3001);
  const next = pair(f);
  assert.notEqual(next, id);
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision }).body.error, 'ROOM_CLOSED');
  assert.equal(f.state.rooms[next].status, 'open');
});
test('random matchmaking pairs two accounts once and a third stays queued', () => {
  const f = fixture();
  assert.equal(f.call('alice', { action: 'queue' }).body.queued, true);
  const match = f.call('bob', { action: 'queue' });
  assert.equal(match.body.room.members.length, 2);
  assert.deepEqual(f.state.queue, {});
  assert.equal(f.call('charlie', { action: 'queue' }).body.queued, true);
  f.advance(3001);
  assert.equal(f.call('alice', { action: 'queue' }).body.room.id, match.body.room.id);
});
test('expired or banned queue entries are never matched', () => {
  const f = fixture();
  f.call('alice', { action: 'queue' });
  f.advance(QUEUE_TTL_MS);
  assert.equal(f.call('bob', { action: 'queue' }).body.queued, true);
  f.state.accounts[accountKey('bob')].banned = true;
  assert.equal(f.call('charlie', { action: 'queue' }).body.queued, true);
  assert.equal(Object.keys(f.state.rooms).length, 0);
});
test('read/write limits are separate, persistent and replenish', () => {
  const f = fixture();
  for (let i = 0; i < 90; i++) assert.equal(f.call('alice', { action: 'status' }).status, 200);
  assert.equal(f.call('alice', { action: 'status' }).status, 429);
  assert.equal(f.call('alice', { action: 'invite' }).status, 200);
  f.advance(60_000);
  assert.equal(f.call('alice', { action: 'status' }).status, 200);
});
test('invalid offers also consume the write budget', () => {
  const f = fixture(), id = pair(f);
  for (let i = 0; i < 29; i++) assert.equal(f.call('alice', { action: 'offer', roomId: id, revision: 1, offer: { coins: -1, cards: [] } }).status, 400);
  assert.equal(f.call('alice', { action: 'cancel', roomId: id }).status, 429);
});
test('server ban prevents a previously ready account from completing', () => {
  const f = fixture(), id = pair(f), revision = exchange(f, id);
  f.state.accounts[accountKey('bob')].banned = true;
  assert.equal(f.call('bob', { action: 'confirm', roomId: id, revision }).status, 403);
  assert.equal(f.call('alice', { action: 'confirm', roomId: id, revision }).status, 403);
});
test('retries are deterministic against the same snapshot', () => {
  const f = fixture();
  const args = [f.state, 'alice', { action: 'invite' }, 1_000_000, 'fixed-id'];
  assert.deepEqual(transition(...args), transition(...args));
});
test('database empty object elision is tolerated', () => {
  const f = fixture();
  delete f.state.rooms; delete f.state.queue;
  assert.equal(f.call('alice', { action: 'invite' }).status, 200);
});
test('ready and settlement tolerate database removal of empty maps and arrays', () => {
  const f = fixture(), id = pair(f);
  delete f.state.rooms[id].ready; delete f.state.rooms[id].confirmed;
  for (const offer of Object.values(f.state.rooms[id].offers)) delete offer.cards;
  delete f.state.accounts[accountKey('alice')].cards;
  for (const action of ['ready', 'confirm']) {
    for (const uid of ['alice', 'bob']) {
      assert.equal(f.call(uid, { action, roomId: id, revision: 1 }).status, 200);
    }
  }
  assert.equal(f.state.rooms[id].status, 'completed');
});

test('registration requires one-time import before matchmaking and cannot reset inventory', () => {
  const f = fixture();
  assert.equal(f.call('newcomer', { action: 'register', uid: 'alice' }).status, 400);
  assert.equal(f.state.accounts[accountKey('newcomer')], undefined);
  assert.equal(f.call('newcomer', { action: 'register' }).body.inventoryReady, false);
  for (const action of ['invite', 'queue']) {
    f.advance(3001);
    assert.equal(f.call('newcomer', { action }).body.error, 'INVENTORY_IMPORT_REQUIRED');
  }
  const inventory = { coins: 400, cards: { cardA: 5 } };
  assert.equal(f.call('newcomer', { action: 'importLegacyInventory', inventory }).status, 200);
  assert.equal(f.call('newcomer', { action: 'register' }).body.inventoryReady, true);
  const status = f.call('newcomer', { action: 'status' }).body;
  assert.deepEqual(status.inventory, inventory);
  assert.equal(status.inventoryVersion, 1);
  assert.equal(status.inventoryOrigin, 'legacy-client-unverified');
  assert.equal(f.call('newcomer', { action: 'importLegacyInventory', inventory: { coins: 999, cards: {} } }).status, 409);
  assert.deepEqual(f.call('newcomer', { action: 'status' }).body.inventory, inventory);
});
test('legacy import rejects invalid quantities, unsafe keys and extra fields without partial writes', () => {
  const f = fixture();
  f.call('newcomer', { action: 'register' });
  for (const inventory of [
    { coins: -1, cards: {} }, { coins: 1.5, cards: {} },
    { coins: 1_000_000_001, cards: {} }, { coins: 0, cards: { cardA: 0 } },
    { coins: 0, cards: { cardA: 1_000_001 } }, { coins: 0, cards: { '../bad': 1 } },
    JSON.parse('{"coins":0,"cards":{"__proto__":1}}'),
    { coins: 0, cards: {}, allowed: true }
  ]) {
    assert.equal(f.call('newcomer', { action: 'importLegacyInventory', inventory }).status, 400);
    const a = f.state.accounts[accountKey('newcomer')];
    assert.equal(a.inventoryReady, false);
    assert.equal(a.coins, 0);
    assert.deepEqual(a.cards, {});
  }
  assert.equal(f.call('newcomer', { action: 'importLegacyInventory', inventory: { coins: 0, cards: {} } }).status, 200);
});
test('register and import cannot remove bans or overwrite established trading balances', () => {
  const f = fixture();
  f.state.accounts[accountKey('alice')].banned = true;
  assert.equal(f.call('alice', { action: 'register' }).status, 403);
  assert.equal(f.state.accounts[accountKey('alice')].banned, true);
  assert.equal(f.call('bob', { action: 'importLegacyInventory', inventory: { coins: 999, cards: {} } }).status, 409);
  assert.equal(f.state.accounts[accountKey('bob')].coins, 100);
});

test('full-collection import preserves first copies, including newly received cards', () => {
  let state = null, now = 100000;
  const call = (uid, input) => {
    const result = transition(state, uid, input, now += 4000, 'first-copy-room');
    state = result.state;
    return result;
  };
  for (const uid of ['alice', 'bob']) {
    assert.equal(call(uid, { action: 'register' }).status, 200);
    assert.equal(call(uid, { action: 'importLegacyInventory', preserveFirstCopy: true,
      inventory: { coins: 0, cards: uid === 'alice' ? { A: 2, B: 1 } : {} } }).status, 200);
  }
  assert.equal(call('alice', { action: 'status' }).body.preserveFirstCopy, true);
  const id = call('alice', { action: 'invite' }).body.room.id;
  let revision = call('bob', { action: 'join', roomId: id }).body.room.revision;
  assert.equal(call('alice', { action: 'offer', roomId: id, revision, offer: { coins: 0, cards: ['B'] } }).body.error, 'CARD_NOT_OWNED');
  revision = call('alice', { action: 'offer', roomId: id, revision, offer: { coins: 0, cards: ['A'] } }).body.room.revision;
  for (const uid of ['alice', 'bob']) assert.equal(call(uid, { action: 'ready', roomId: id, revision }).status, 200);
  for (const uid of ['alice', 'bob']) assert.equal(call(uid, { action: 'confirm', roomId: id, revision }).status, 200);
  assert.deepEqual(state.accounts[accountKey('alice')].cards, { A: 1, B: 1 });
  assert.deepEqual(state.accounts[accountKey('bob')].cards, { A: 1 });
});

test('original card positions survive sorting and moving a card invalidates readiness', () => {
  const f = fixture(), id = pair(f), key = accountKey('alice');
  let revision = f.state.rooms[id].revision;
  const offer = { coins: 0, cards: ['cardB', 'cardA'], slots: [0, 2] };
  const result = f.call('alice', { action: 'offer', roomId: id, revision, offer });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.room.offers[key], { coins: 0, cards: ['cardA', 'cardB'], slots: [2, 0] });
  revision = result.body.room.revision;
  for (const uid of ['alice', 'bob']) f.call(uid, { action: 'ready', roomId: id, revision });
  const moved = f.call('alice', { action: 'offer', roomId: id, revision, offer: { ...offer, slots: [1, 2] } });
  assert.equal(moved.status, 200);
  assert.deepEqual(moved.body.room.ready, {});
  assert.equal(moved.body.room.revision, revision + 1);
});

test('malformed original positions cannot alter an offer or inventory', () => {
  for (const slots of [[0, 0], [-1, 2], [0, 3], [true, 2], [0.5, 2], [0], null, '02']) {
    const f = fixture(), id = pair(f), room = structuredClone(f.state.rooms[id]);
    const result = f.call('alice', { action: 'offer', roomId: id, revision: room.revision,
      offer: { coins: 0, cards: ['cardA', 'cardB'], slots } });
    assert.equal(result.body.error, 'INVALID_SLOTS');
    assert.deepEqual(f.state.rooms[id].offers, room.offers);
    assert.equal(f.state.accounts[accountKey('alice')].cards.cardA, 2);
  }
});


test('explicit inventory relink is versioned, isolated and blocked while busy', () => {
  const f = fixture();
  const key = accountKey('alice');
  f.state.accounts[key].inventoryReady = true;
  f.state.accounts[key].inventoryVersion = 4;
  f.state.accounts[key].preserveFirstCopy = true;
  const beforeBob = structuredClone(f.state.accounts[accountKey('bob')]);

  let result = f.call('alice', {
    action: 'replaceInventory',
    expectedInventoryVersion: 3,
    preserveFirstCopy: true,
    inventory: { coins: 777, cards: { cardZ: 2 } }
  });
  assert.equal(result.body.error, 'STALE_INVENTORY_VERSION');
  assert.equal(f.state.accounts[key].coins, 100);

  result = f.call('alice', {
    action: 'replaceInventory',
    expectedInventoryVersion: 4,
    preserveFirstCopy: true,
    inventory: { coins: 777, cards: { cardZ: 2 } }
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.inventoryVersion, 5);
  assert.equal(result.body.inventoryOrigin, 'device-authoritative-relink');
  assert.equal(result.body.preserveFirstCopy, true);
  assert.deepEqual(result.body.inventory, { coins: 777, cards: { cardZ: 2 } });
  assert.deepEqual(f.state.accounts[accountKey('bob')], beforeBob);

  f.advance(3001);
  assert.equal(f.call('alice', { action: 'queue' }).status, 200);
  result = f.call('alice', {
    action: 'replaceInventory',
    expectedInventoryVersion: 5,
    preserveFirstCopy: true,
    inventory: { coins: 888, cards: { cardZ: 2 } }
  });
  assert.equal(result.body.error, 'ACCOUNT_BUSY');
});

test('inventory relink validates collection and cannot disable first-copy protection', () => {
  const f = fixture();
  const key = accountKey('alice');
  f.state.accounts[key].inventoryReady = true;
  f.state.accounts[key].inventoryVersion = 1;
  f.state.accounts[key].preserveFirstCopy = true;

  for (const request of [
    { inventory: { coins: -1, cards: {} }, preserveFirstCopy: true },
    { inventory: { coins: 1, cards: { bad: 0 } }, preserveFirstCopy: true },
    { inventory: { coins: 1, cards: {} }, preserveFirstCopy: false }
  ]) {
    const result = f.call('alice', {
      action: 'replaceInventory',
      expectedInventoryVersion: 1,
      ...request
    });
    assert.notEqual(result.status, 200);
    assert.equal(f.state.accounts[key].inventoryVersion, 1);
    assert.equal(f.state.accounts[key].coins, 100);
  }
});


test('random matchmaking completes a full two-player trade end to end', () => {
  const f = fixture();
  const aKey = accountKey('alice'), bKey = accountKey('bob');
  f.state.accounts[aKey].inventoryReady = true;
  f.state.accounts[bKey].inventoryReady = true;
  f.state.accounts[aKey].inventoryVersion = 1;
  f.state.accounts[bKey].inventoryVersion = 1;
  f.state.accounts[aKey].preserveFirstCopy = false;
  f.state.accounts[bKey].preserveFirstCopy = false;

  const first = f.call('alice', { action: 'queue', scope: 'random' });
  assert.equal(first.status, 200);
  assert.equal(first.body.queued, true);
  f.advance(3001);
  const second = f.call('bob', { action: 'queue', scope: 'random' });
  assert.equal(second.status, 200);
  assert.equal(second.body.room.members.length, 2);
  const roomId = second.body.room.id;

  const aliceStatus = f.call('alice', { action: 'status' });
  assert.equal(aliceStatus.body.room.id, roomId);
  let revision = aliceStatus.body.room.revision;

  let response = f.call('alice', {
    action: 'offer', roomId, revision,
    offer: { coins: 25, cards: ['cardA'], slots: [0] }
  });
  assert.equal(response.status, 200);
  revision = response.body.room.revision;

  response = f.call('bob', {
    action: 'offer', roomId, revision,
    offer: { coins: 5, cards: ['cardB'], slots: [2] }
  });
  assert.equal(response.status, 200);
  revision = response.body.room.revision;

  for (const uid of ['alice', 'bob']) {
    response = f.call(uid, { action: 'ready', roomId, revision });
    assert.equal(response.status, 200);
  }
  assert.equal(f.call('alice', { action: 'confirm', roomId, revision }).body.room.status, 'open');
  assert.equal(f.call('bob', { action: 'confirm', roomId, revision }).body.room.status, 'completed');

  const a = f.call('alice', { action: 'status', roomId }).body;
  const b = f.call('bob', { action: 'status', roomId }).body;
  assert.equal(a.room.status, 'completed');
  assert.equal(b.room.status, 'completed');
  assert.equal(a.inventoryVersion, 2);
  assert.equal(b.inventoryVersion, 2);
  assert.equal(a.inventory.coins, 80);
  assert.equal(b.inventory.coins, 120);
  assert.deepEqual(a.inventory.cards, { cardA: 1, cardB: 2 });
  assert.deepEqual(b.inventory.cards, { cardA: 3 });
});


test('presentation signals relay without changing trade revision or inventory', () => {
  const f = fixture(), id = pair(f);
  const before = structuredClone(f.state.accounts[accountKey('alice')]);
  const revision = f.state.rooms[id].revision;
  const payload = Buffer.from('signal').toString('base64');
  const sent = f.call('alice', { action: 'signal', roomId: id,
    signalType: 'emote', signalPayload: payload });
  assert.equal(sent.status, 200);
  assert.equal(sent.body.room.revision, revision);
  const aliceKey = accountKey('alice');
  assert.equal(sent.body.room.signals[aliceKey].length, 1);
  assert.equal(sent.body.room.signals[aliceKey][0].type, 'emote');
  assert.equal(f.state.accounts[aliceKey].coins, before.coins);
  assert.deepEqual(f.state.accounts[aliceKey].cards, before.cards);
});

test('presentation signal whitelist rejects arbitrary message types', () => {
  const f = fixture(), id = pair(f);
  const result = f.call('alice', { action: 'signal', roomId: id,
    signalType: 'anythingElse', signalPayload: Buffer.from('x').toString('base64') });
  assert.equal(result.body.error, 'INVALID_SIGNAL_TYPE');
});


test('authenticated bot rooms expose botPartner and persist peer wishlist state', () => {
  const f = fixture();
  f.state.accounts[accountKey('bob')].authenticatedBot = true;
  f.state.accounts[accountKey('alice')].inventoryReady = true;
  f.state.accounts[accountKey('bob')].inventoryReady = true;

  const first = f.call('alice', { action: 'queue', scope: 'g:0:a:0' });
  assert.equal(first.body.queued, true);
  f.advance(3001);
  const paired = f.call('bob', { action: 'queue', scope: 'g:0:a:0' });
  assert.equal(paired.status, 200);
  assert.equal(paired.body.room.botPartner, true);
  const roomId = paired.body.room.id;

  const human = f.call('alice', { action: 'status', roomId });
  assert.equal(human.body.room.botPartner, true);
  const wish = f.call('alice', {
    action: 'botWishlist',
    roomId,
    cardIds: ['wishA', 'wishB', 'wishC']
  });
  assert.equal(wish.status, 200);
  assert.deepEqual(wish.body.room.wishlists[accountKey('alice')], ['wishA', 'wishB', 'wishC']);
});


test('account wishlist is carried into normal matchmaking rooms', () => {
  const f = fixture();
  f.state.accounts[accountKey('alice')].inventoryReady = true;
  f.state.accounts[accountKey('bob')].inventoryReady = true;

  const saved = f.call('alice', {
    action: 'setWishlist',
    cardIds: ['wishA', 'wishB', 'wishC', 'wishD']
  });
  assert.equal(saved.status, 200);

  assert.equal(f.call('alice', { action: 'queue', scope: 'g:0:a:0' }).body.queued, true);
  f.advance(3001);
  const matched = f.call('bob', { action: 'queue', scope: 'g:0:a:0' });
  assert.equal(matched.status, 200);
  const humanKey = accountKey('alice');
  assert.deepEqual(matched.body.room.wishlists[humanKey],
    ['wishA', 'wishB', 'wishC', 'wishD']);
});
