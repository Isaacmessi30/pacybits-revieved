import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { initializeApp, deleteApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { accountKey, emptyState } from '../src/trading.js';

const project = 'demo-pacybits-revival';
// Refuse to use these fixtures or fake tokens against a live service.
assert.match(process.env.FIREBASE_AUTH_EMULATOR_HOST ?? '', /^(127\.0\.0\.1|localhost):\d+$/);
assert.match(process.env.FIREBASE_DATABASE_EMULATOR_HOST ?? '', /^(127\.0\.0\.1|localhost):\d+$/);
const app = initializeApp({ projectId: project, databaseURL: `https://${project}-default-rtdb.firebaseio.com` });
const auth = getAuth(app), db = getDatabase(app);
const endpoint = `http://127.0.0.1:5001/${project}/europe-west1/trading`;
after(async () => { await deleteApp(app); });

function token(uid, provider = 'google.com') {
  const now = Math.floor(Date.now() / 1000);
  const payload = { aud: project, iss: `https://securetoken.google.com/${project}`,
    sub: uid, user_id: uid, iat: now, auth_time: now, exp: now + 3600,
    email: `${uid}@example.test`, email_verified: true,
    firebase: { sign_in_provider: provider, identities: { email: [`${uid}@example.test`] } } };
  return `${Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url')}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.`;
}
async function call(uid, data, provider = 'google.com') {
  const r = await fetch(endpoint, { method: 'POST', headers: {
    'Content-Type': 'application/json', ...(uid ? { Authorization: `Bearer ${token(uid, provider)}` } : {})
  }, body: JSON.stringify(data) });
  return { status: r.status, body: await r.json() };
}
async function seed() {
  const state = emptyState();
  for (const uid of ['alice', 'bob', 'charlie']) {
    try { await auth.createUser({ uid, email: `${uid}@example.test`, emailVerified: true }); }
    catch (e) { if (e.code !== 'auth/uid-already-exists' && e.code !== 'auth/email-already-exists') throw e; }
    state.accounts[accountKey(uid)] = { allowed: true, coins: 100, cards: { cardA: 2, cardB: 1 } };
  }
  await db.ref('revivalPrivate').set(state);
}
async function pair() {
  const invitation = await call('alice', { action: 'invite' });
  assert.equal(invitation.status, 200, JSON.stringify(invitation.body));
  const id = invitation.body.room.id;
  assert.equal((await call('bob', { action: 'join', roomId: id })).status, 200);
  return id;
}
test('HTTP authentication rejects missing credentials and non-Google sessions', async () => {
  await seed();
  assert.equal((await call(null, { action: 'status' })).status, 401);
  assert.equal((await call('alice', { action: 'status' }, 'custom')).status, 403);
  assert.equal((await call('alice', { action: 'status' })).status, 200);
});
test('database rules reject direct authenticated reads and writes', async () => {
  const url = `http://${process.env.FIREBASE_DATABASE_EMULATOR_HOST}/revivalPrivate.json?ns=${project}-default-rtdb&auth=${token('alice')}`;
  assert.equal((await fetch(url)).status, 401);
  assert.equal((await fetch(url, { method: 'PUT', body: JSON.stringify({ forged: true }) })).status, 401);
});
test('persisted empty offers and readiness maps survive Firebase normalization', async () => {
  await seed();
  const id = await pair();
  for (const action of ['ready', 'confirm']) {
    for (const uid of ['alice', 'bob']) {
      const response = await call(uid, { action, roomId: id, revision: 1 });
      assert.equal(response.status, 200, JSON.stringify(response.body));
    }
  }
  assert.equal((await call('alice', { action: 'status', roomId: id })).body.room.status, 'completed');
});
test('simultaneous confirmations and retries transfer inventory exactly once', async () => {
  await seed();
  const id = await pair();
  assert.equal((await call('alice', { action: 'offer', roomId: id, revision: 1, offer: { coins: 40, cards: ['cardA'] } })).status, 200);
  assert.equal((await call('bob', { action: 'offer', roomId: id, revision: 2, offer: { coins: 10, cards: ['cardB'] } })).status, 200);
  for (const uid of ['alice', 'bob']) assert.equal((await call(uid, { action: 'ready', roomId: id, revision: 3 })).status, 200);
  const responses = await Promise.all(Array.from({ length: 8 }, (_, i) => call(i % 2 ? 'alice' : 'bob', { action: 'confirm', roomId: id, revision: 3 })));
  for (const response of responses) assert.equal(response.status, 200, JSON.stringify(response.body));
  const state = (await db.ref('revivalPrivate').get()).val();
  assert.equal(state.accounts[accountKey('alice')].coins, 70);
  assert.equal(state.accounts[accountKey('bob')].coins, 130);
  assert.deepEqual(state.accounts[accountKey('alice')].cards, { cardA: 1, cardB: 2 });
  assert.deepEqual(state.accounts[accountKey('bob')].cards, { cardA: 3 });
  assert.equal(state.rooms[id].status, 'completed');
});
test('simultaneous attempts to join never admit three players', async () => {
  await seed();
  const id = (await call('alice', { action: 'invite' })).body.room.id;
  const responses = await Promise.all(['bob', 'charlie'].map(uid => call(uid, { action: 'join', roomId: id })));
  assert.deepEqual(responses.map(x => x.status).sort(), [200, 404]);
  assert.equal((await db.ref(`revivalPrivate/rooms/${id}/members`).get()).val().length, 2);
});
test('simultaneous matchmaking does not double-assign an account', async () => {
  await seed();
  const responses = await Promise.all(['alice', 'bob', 'charlie'].map(uid => call(uid, { action: 'queue' })));
  for (const response of responses) assert.equal(response.status, 200);
  const state = (await db.ref('revivalPrivate').get()).val();
  assert.equal(Object.keys(state.rooms).length, 1);
  assert.equal(Object.keys(state.queue).length, 1);
  const room = Object.values(state.rooms)[0];
  assert.equal(new Set(room.members).size, 2);
  for (const member of room.members) assert.equal(state.accounts[member].activeRoom, room.id);
});

test('concurrent legacy imports initialize once and registration preserves the imported ledger', async () => {
  await seed();
  await db.ref(`revivalPrivate/accounts/${accountKey('alice')}`).remove();
  const registrations = await Promise.all([call('alice', { action: 'register' }), call('alice', { action: 'register' })]);
  for (const response of registrations) assert.equal(response.body.inventoryReady, false);
  assert.equal((await call('alice', { action: 'queue' })).status, 409);
  const inventories = [{ coins: 500, cards: { oldCard: 4 } }, { coins: 800, cards: {} }];
  const responses = await Promise.all(inventories.map(inventory => call('alice', { action: 'importLegacyInventory', inventory })));
  assert.deepEqual(responses.map(x => x.status).sort(), [200, 409]);
  const winner = inventories[responses.findIndex(x => x.status === 200)];
  await call('alice', { action: 'register' });
  const status = (await call('alice', { action: 'status' })).body;
  assert.deepEqual(status.inventory, winner);
  assert.equal(status.inventoryVersion, 1);
  assert.equal(status.inventoryOrigin, 'legacy-client-unverified');
});
