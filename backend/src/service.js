import { randomUUID } from 'node:crypto';
import { transitionWithTestPartner } from './test-partner.js';

// Shared by Firebase Functions and the standalone Render server.
export function createTradingService({ auth, database, logError = console.error, testPartnerEnabled = false }) {
  return async function trade({ authorization, body, byteLength }) {
    const limit = ['importLegacyInventory', 'replaceInventory'].includes(body?.action) ? 262144 : 4096;
    if (byteLength > limit) return { status: 413, body: { error: 'REQUEST_TOO_LARGE' } };
    const match = /^Bearer ([^\s]+)$/.exec(authorization ?? '');
    if (!match) return { status: 401, body: { error: 'AUTH_REQUIRED' } };
    let identity;
    try { identity = await auth.verifyIdToken(match[1], true); }
    catch { return { status: 401, body: { error: 'INVALID_SESSION' } }; }
    const provider = identity.firebase?.sign_in_provider;
    const allowed = provider === 'google.com' && identity.email_verified === true;
    if (!allowed) {
      return { status: 403, body: { error: 'VERIFIED_GOOGLE_ACCOUNT_REQUIRED' } };
    }
    const id = randomUUID(), now = Date.now();
    let outcome;
    try {
      const tx = await database.ref('revivalPrivate').transaction(current => {
        outcome = transitionWithTestPartner(current, identity.uid, body, now, id, testPartnerEnabled);
        return outcome.state;
      }, undefined, false);
      if (!tx.committed) return { status: 409, body: { error: 'RETRY_REQUEST' } };
      return { status: outcome.status, body: outcome.body };
    } catch {
      logError('Trading transaction failed', { requestId: id });
      return { status: 503, body: { error: 'TEMPORARILY_UNAVAILABLE', requestId: id } };
    }
  };
}
