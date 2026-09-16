import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { onRequest } from 'firebase-functions/v2/https';
import { createTradingService } from './service.js';

initializeApp({ databaseURL: process.env.FIREBASE_DATABASE_EMULATOR_HOST
  ? `https://${process.env.GCLOUD_PROJECT}-default-rtdb.firebaseio.com`
  : 'https://pacybits---revival-default-rtdb.europe-west1.firebasedatabase.app' });
const trade = createTradingService({ auth: getAuth(), database: getDatabase() });

export const trading = onRequest({
  region: 'europe-west1', maxInstances: 2, concurrency: 20, timeoutSeconds: 30,
  memory: '256MiB', cors: false
}, async (req, res) => {
  res.set('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).set('Allow', 'POST').json({ error: 'POST_REQUIRED' });
  if (!req.is('application/json')) return res.status(415).json({ error: 'JSON_REQUIRED' });
  const result = await trade({ authorization: req.get('authorization'), body: req.body,
    byteLength: req.rawBody?.length ?? Buffer.byteLength(JSON.stringify(req.body ?? null)) });
  return res.status(result.status).json(result.body);
});
