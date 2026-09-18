import { randomUUID } from 'node:crypto';
import { applicationDefault, cert, initializeApp } from 'firebase-admin/app';
import { getDatabase } from 'firebase-admin/database';
import { accountKey, emptyState, transition } from '../src/trading.js';

function usage() {
  console.error('Usage: node scripts/join-test-partner.js (--code 357-001 | --scope random | --room ROOM_ID)');
  process.exit(2);
}
function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}
const code = argument('--code');
const explicitScope = argument('--scope');
const roomId = argument('--room');
if ([Boolean(code), Boolean(explicitScope), Boolean(roomId)].filter(Boolean).length !== 1) usage();

const scope = code
  ? `code:${code.trim().toUpperCase()}`
  : explicitScope?.trim();

if (scope && !/^[a-zA-Z0-9:_-]{1,128}$/.test(scope)) {
  throw new Error('Invalid matchmaking scope/code');
}
if (roomId && !/^[a-zA-Z0-9_-]{1,128}$/.test(roomId)) {
  throw new Error('Invalid room ID');
}

const projectId = process.env.FIREBASE_PROJECT_ID;
const databaseURL = process.env.FIREBASE_DATABASE_URL;
if (!projectId || !databaseURL) throw new Error('FIREBASE_PROJECT_ID and FIREBASE_DATABASE_URL are required');

let credential;
if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
  let serviceAccount;
  try { serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON); }
  catch { throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON'); }
  if (serviceAccount.project_id !== projectId) throw new Error('Service account project mismatch');
  credential = cert(serviceAccount);
} else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  credential = applicationDefault();
} else {
  throw new Error('Configure the same Firebase service account used by the trading backend');
}

const app = initializeApp({ projectId, databaseURL, credential }, `test-partner-${randomUUID()}`);
const database = getDatabase(app);
const now = Date.now();
const peerUid = `revival-script-${randomUUID()}`;
const peerKey = accountKey(peerUid);
const roomSeed = randomUUID();

let outcome;
const tx = await database.ref('revivalPrivate').transaction(current => {
  const state = structuredClone(current ?? emptyState());
  state.version ??= 1;
  state.accounts ??= {};
  state.rooms ??= {};
  state.queue ??= {};
  state.legacyIds ??= {};

  if (state.accounts[peerKey]) throw new Error('Synthetic test-partner collision');
  state.accounts[peerKey] = {
    allowed: true,
    coins: 0,
    cards: {},
    inventoryReady: true,
    inventoryVersion: 1,
    preserveFirstCopy: true,
    testPartner: true,
    testPartnerUid: peerUid,
    createdAt: now
  };

  const input = roomId
    ? { action: 'join', roomId }
    : { action: 'queue', scope };
  outcome = transition(state, peerUid, input, now, roomSeed);
  if (outcome.status !== 200) throw new Error(`Test partner failed: ${outcome.body?.error ?? outcome.status}`);

  if (outcome.body.room) {
    const room = outcome.state.rooms[outcome.body.room.id];
    room.testPartnerUid = peerUid;
  }
  return outcome.state;
}, undefined, false);

if (!tx.committed) throw new Error('Firebase transaction did not commit');
if (outcome?.body?.room) {
  console.log(`Synthetic test partner joined room ${outcome.body.room.id}`);
} else {
  console.log(`Synthetic test partner is waiting in scope ${scope}`);
}
process.exit(0);
