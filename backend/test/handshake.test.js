import test from 'node:test';
import assert from 'node:assert/strict';
import { accountKey, emptyState, transition } from '../src/trading.js';

function fixture() {
  let state = emptyState();
  let now = 2_000_000;
  let counter = 0;
  for (const uid of ['alice', 'bob']) {
    state.accounts[accountKey(uid)] = {
      allowed: true, coins: 100, cards: { cardA: 2, cardB: 2 },
      inventoryReady: true, inventoryVersion: 1, preserveFirstCopy: true
    };
  }
  return {
    get state() { return state; },
    call(uid, input) {
      const result = transition(state, uid, input, now, `room-${++counter}`);
      state = result.state;
      return result;
    }
  };
}

function complete(f) {
  const invite = f.call('alice', { action: 'invite' });
  const id = invite.body.room.id;
  f.call('bob', { action: 'join', roomId: id });
  let revision = f.state.rooms[id].revision;
  f.call('alice', { action: 'offer', roomId: id, revision, offer: { coins: 5, cards: ['cardA'], slots: [0] } });
  revision++;
  f.call('bob', { action: 'offer', roomId: id, revision, offer: { coins: 7, cards: ['cardB'], slots: [2] } });
  revision++;
  f.call('alice', { action: 'ready', roomId: id, revision });
  f.call('bob', { action: 'ready', roomId: id, revision });
  f.call('alice', { action: 'confirm', roomId: id, revision });
  const completed = f.call('bob', { action: 'confirm', roomId: id, revision });
  assert.equal(completed.body.room.status, 'completed');
  return id;
}

function inventoryState(account) {
  return { coins: account.coins, cards: account.cards, inventoryVersion: account.inventoryVersion };
}

test('native handshakes relay only after settlement and never settle inventory twice', () => {
  const f = fixture();
  const id = complete(f);
  const beforeA = inventoryState(structuredClone(f.state.accounts[accountKey('alice')]));
  const beforeB = inventoryState(structuredClone(f.state.accounts[accountKey('bob')]));
  const aPayload = Buffer.from('alice-handshake').toString('base64');
  const bPayload = Buffer.from('bob-handshake').toString('base64');

  let response = f.call('alice', { action: 'handshake', roomId: id, payload: aPayload });
  assert.equal(response.status, 200);
  assert.equal(response.body.room.handshakes[accountKey('alice')], aPayload);
  assert.equal(response.body.inventoryVersion, beforeA.inventoryVersion);

  response = f.call('bob', { action: 'handshake', roomId: id, payload: bPayload });
  assert.equal(response.status, 200);
  assert.equal(response.body.room.handshakes[accountKey('alice')], aPayload);
  assert.equal(response.body.room.handshakes[accountKey('bob')], bPayload);

  assert.deepEqual(inventoryState(f.state.accounts[accountKey('alice')]), beforeA);
  assert.deepEqual(inventoryState(f.state.accounts[accountKey('bob')]), beforeB);
});

test('handshake is rejected before both players have confirmed', () => {
  const f = fixture();
  const invite = f.call('alice', { action: 'invite' });
  const id = invite.body.room.id;
  f.call('bob', { action: 'join', roomId: id });
  const response = f.call('alice', {
    action: 'handshake', roomId: id, payload: Buffer.from('too-early').toString('base64')
  });
  assert.equal(response.status, 409);
  assert.equal(response.body.error, 'TRADE_NOT_COMPLETED');
});
