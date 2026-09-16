import { applicationDefault, cert, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getDatabase } from 'firebase-admin/database';
import { createTradingService } from './service.js';
import { createTradingHTTPServer } from './http-server.js';

const projectId = process.env.FIREBASE_PROJECT_ID;
const databaseURL = process.env.FIREBASE_DATABASE_URL;
if (!projectId || !databaseURL) throw new Error('FIREBASE_PROJECT_ID and FIREBASE_DATABASE_URL are required');
const emulator = process.env.FIREBASE_AUTH_EMULATOR_HOST || process.env.FIREBASE_DATABASE_EMULATOR_HOST;
if (emulator && (process.env.REVIVAL_ALLOW_EMULATORS !== 'true' || !projectId.startsWith('demo-') ||
    ![process.env.FIREBASE_AUTH_EMULATOR_HOST, process.env.FIREBASE_DATABASE_EMULATOR_HOST]
      .every(host => /^(127\.0\.0\.1|localhost):\d+$/.test(host ?? '')))) {
  throw new Error('Emulators require explicit opt-in and a local demo project');
}
let credential;
if (!emulator) {
  if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
    let serviceAccount;
    try { serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON); }
    catch { throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON'); }
    if (serviceAccount.project_id !== projectId) throw new Error('Service account project mismatch');
    credential = cert(serviceAccount);
  } else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    credential = applicationDefault();
  } else {
    throw new Error('Configure a Firebase service account in the server secret settings');
  }
}
const app = initializeApp({ projectId, databaseURL, ...(credential ? { credential } : {}) });
const trade = createTradingService({ auth: getAuth(app), database: getDatabase(app) });
const server = createTradingHTTPServer(trade);
const port = Number(process.env.PORT ?? 10000);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT');
server.listen(port, process.env.REVIVAL_BIND_HOST ?? '0.0.0.0', () => {
  console.log(`Trading API listening on port ${port}`);
});
process.once('SIGTERM', () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
});
