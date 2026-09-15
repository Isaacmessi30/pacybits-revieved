import { randomUUID } from 'node:crypto';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { onRequest } from 'firebase-functions/v2/https';
import { transition } from './trading.js';

initializeApp({ databaseURL: process.env.FIREBASE_DATABASE_EMULATOR_HOST
  ? `https://${process.env.GCLOUD_PROJECT}-default-rtdb.firebaseio.com`
  : 'https://pacybits---revival-default-rtdb.europe-west1.firebasedatabase.app' });

export const trading = onRequest({
  region: 'europe-west1', maxInstances: 2, concurrency: 20, timeoutSeconds: 30,
  memory: '256MiB', cors: false
}, async (req, res) => {
  res.set('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).set('Allow', 'POST').json({ error: 'POST_REQUIRED' });
  if (!req.is('application/json')) return res.status(415).json({ error: 'JSON_REQUIRED' });
  const bodyLimit = req.body?.action === 'importLegacyInventory' ? 262144 : 4096;
  if ((req.rawBody?.length ?? Buffer.byteLength(JSON.stringify(req.body ?? null))) > bodyLimit) {
    return res.status(413).json({ error: 'REQUEST_TOO_LARGE' });
  }
  const match = /^Bearer ([^\s]+)$/.exec(req.get('authorization') ?? '');
  if (!match) return res.status(401).json({ error: 'AUTH_REQUIRED' });
  let identity;
  try { identity = await getAuth().verifyIdToken(match[1], true); }
  catch { return res.status(401).json({ error: 'INVALID_SESSION' }); }
  if (identity.firebase?.sign_in_provider !== 'google.com' || identity.email_verified !== true) {
    return res.status(403).json({ error: 'VERIFIED_GOOGLE_ACCOUNT_REQUIRED' });
  }
  const id = randomUUID();
  const now = Date.now();
  let outcome;
  try {
    const tx = await getDatabase().ref('revivalPrivate').transaction(current => {
      // The Admin SDK can first call back with null before it fetches existing data.
      outcome = transition(current, identity.uid, req.body, now, id);
      return outcome.state;
    }, undefined, false);
    if (!tx.committed) return res.status(409).json({ error: 'RETRY_REQUEST' });
    return res.status(outcome.status).json(outcome.body);
  } catch {
    console.error('Trading transaction failed', { requestId: id });
    return res.status(503).json({ error: 'TEMPORARILY_UNAVAILABLE', requestId: id });
  }
});
