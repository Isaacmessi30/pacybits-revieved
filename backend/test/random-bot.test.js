import test from 'node:test';
import assert from 'node:assert/strict';
import { accountKey } from '../src/trading.js';
import { transitionWithRandomBot } from '../src/random-bot.js';

test('Random bot enters normal queue and completes a safe trade lifecycle', () => {
  const uid = 'real-device-user';
  let state = null;
  let now = 1_700_000_000_000;

  let result = transitionWithRandomBot(state, uid, { action: 'register' }, now++, 'room-a', true);
  assert.equal(result.status, 200);
  state = result.state;

  result = transitionWithRandomBot(state, uid, {
    action: 'importLegacyInventory',
    preserveFirstCopy: true,
    inventory: { coins: 1000, cards: { cardA: 2 } }
  }, now++, 'room-b', true);
  assert.equal(result.status, 200);
  state = result.state;

  result = transitionWithRandomBot(state, uid, {
    action: 'queue',
    scope: 'g:0:a:0'
  }, now++, 'room-c', true);

  assert.equal(result.status, 200);
  assert.equal(result.body.queued, false);
  assert.equal(result.body.room.members.length, 2);
  assert.equal(result.body.room.botPartner, true);
  assert.equal(result.body.room.testPartner, undefined);
  assert.equal(result.body.room.self, accountKey(uid));
  state = result.state;

  const roomId = result.body.room.id;
  result = transitionWithRandomBot(state, uid, {
    action: 'ready',
    roomId,
    revision: result.body.room.revision
  }, now++, 'room-d', true);

  assert.equal(result.status, 200);
  assert.equal(Object.keys(result.body.room.ready).length, 2);
  state = result.state;

  result = transitionWithRandomBot(state, uid, {
    action: 'confirm',
    roomId,
    revision: result.body.room.revision
  }, now++, 'room-e', true);

  assert.equal(result.status, 200);
  assert.equal(result.body.room.status, 'completed');
  assert.equal(result.body.room.botPartner, true);
  assert.equal(Object.keys(result.body.room.confirmed).length, 2);
  assert.equal(Object.keys(result.body.room.handshakes).length, 1);
});
