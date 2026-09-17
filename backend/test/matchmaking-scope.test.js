import test from 'node:test';
import assert from 'node:assert/strict';
import { accountKey, emptyState, transition } from '../src/trading.js';

function fixture() {
  let state = emptyState();
  let now = 10_000;
  let counter = 0;
  for (const uid of ['alice', 'bob', 'charlie']) {
    state.accounts[accountKey(uid)] = { allowed: true, coins: 100, cards: { cardA: 2 } };
  }
  return {
    get state() { return state; },
    advance(ms) { now += ms; },
    call(uid, input) {
      const result = transition(state, uid, input, now, `room-${++counter}`);
      state = result.state;
      return result;
    }
  };
}

test('GameKit playerGroup/playerAttributes scopes do not cross-match', () => {
  const f = fixture();
  assert.equal(f.call('alice', { action: 'queue', scope: 'g:101:a:0' }).body.queued, true);
  assert.equal(f.call('bob', { action: 'queue', scope: 'g:202:a:0' }).body.queued, true);
  const match = f.call('charlie', { action: 'queue', scope: 'g:101:a:0' });
  assert.equal(match.status, 200);
  assert.equal(match.body.queued, false);
  assert.deepEqual(new Set(match.body.room.members), new Set([accountKey('alice'), accountKey('charlie')]));
  assert.ok(f.state.queue[accountKey('bob')]);
});

test('legacy friend targets only match the intended reciprocal PACYBITS friend', () => {
  const f = fixture();
  assert.equal(f.call('alice', { action: 'register', legacyId: 'legacy-alice' }).status, 200);
  assert.equal(f.call('bob', { action: 'register', legacyId: 'legacy-bob' }).status, 200);
  assert.equal(f.call('charlie', { action: 'register', legacyId: 'legacy-charlie' }).status, 200);

  assert.equal(f.call('alice', {
    action: 'queue', scope: 'g:0:a:0', targetLegacyId: 'legacy-bob'
  }).body.queued, true);
  assert.equal(f.call('charlie', {
    action: 'queue', scope: 'g:0:a:0', targetLegacyId: 'legacy-alice'
  }).body.queued, true);

  const match = f.call('bob', {
    action: 'queue', scope: 'g:0:a:0', targetLegacyId: 'legacy-alice'
  });
  assert.equal(match.status, 200);
  assert.equal(match.body.queued, false);
  assert.deepEqual(new Set(match.body.room.members), new Set([accountKey('alice'), accountKey('bob')]));
  assert.ok(f.state.queue[accountKey('charlie')]);
});
