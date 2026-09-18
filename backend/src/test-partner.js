import { accountKey, transition } from './trading.js';

// An explicit server simulation, never a Firebase user or an authentication bypass.
// It can only accept zero-value offers, so testing cannot mint or consume inventory.
const EMPTY_NATIVE_HANDSHAKE = Buffer.from(
  '<?xml version="1.0" encoding="UTF-8"?>' +
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' +
  '<plist version="1.0"><dict><key>coins</key><integer>0</integer><key>idsLeft</key><array/>' +
  '<key>idsRight</key><array/></dict></plist>', 'utf8').toString('base64');

export function transitionWithTestPartner(current, uid, input, now, id, enabled = false) {
  let result = transition(current, uid, input, now, id);
  if (result.status !== 200) return result;

  // Legacy backend invite path.
  if (enabled && input.action === 'invite') {
    const peerUid = `revival-test-${id}`;
    const peerKey = accountKey(peerUid);
    if (result.state.accounts[peerKey]) throw new Error('Test partner identity collision');
    result.state.accounts[peerKey] = {
      allowed: true, coins: 0, cards: {}, inventoryReady: true, inventoryVersion: 0,
      preserveFirstCopy: true, testPartner: true, createdAt: now
    };
    const joined = transition(result.state, peerUid, { action: 'join', roomId: id }, now, id);
    if (joined.status !== 200) throw new Error('Test partner could not join');
    result.state = joined.state;
    result.state.rooms[id].testPartnerUid = peerUid;
  }

  // Original PACYBITS Code/Channels/Friends UI eventually creates a GameKit
  // match request. Test 7 forwards its playerGroup/playerAttributes as `scope`.
  // For live device testing, auto-pair only non-default scoped queues so the
  // ordinary Random queue is never silently replaced by a simulated player.
  if (enabled && input.action === 'queue' && input.scope && input.scope !== 'g:0:a:0'
      && !input.targetLegacyId && !result.body.room) {
    const peerUid = `revival-test-${id}`;
    const peerKey = accountKey(peerUid);
    if (result.state.accounts[peerKey]) throw new Error('Test partner identity collision');
    result.state.accounts[peerKey] = {
      allowed: true, coins: 0, cards: {}, inventoryReady: true, inventoryVersion: 0,
      preserveFirstCopy: true, testPartner: true, createdAt: now
    };
    const paired = transition(result.state, peerUid, { action: 'queue', scope: input.scope }, now, id);
    if (paired.status !== 200 || !paired.body.room) throw new Error('Scoped test partner could not join');
    result.state = paired.state;
    const room = result.state.rooms[paired.body.room.id];
    room.testPartnerUid = peerUid;
    result.body = {
      ok: true,
      room: {
        id: room.id, status: room.status, expiresAt: room.expiresAt, revision: room.revision,
        self: accountKey(uid), members: room.members, offers: room.offers,
        ready: room.ready, confirmed: room.confirmed, handshakes: room.handshakes ?? {},
        testPartner: true
      },
      queued: false
    };
  }

  const roomId = result.body.room?.id;
  const room = result.state.rooms[roomId];
  if (!room?.testPartnerUid) return result;
  const peerUid = room.testPartnerUid;
  const peerKey = accountKey(peerUid);
  if (uid === peerUid || !room.members.includes(peerKey) || room.members.length !== 2) {
    throw new Error('Invalid test partner room');
  }
  if (room.status === 'open' && input.action === 'ready') {
    const peerResult = transition(result.state, peerUid, {
      action: 'ready', roomId, revision: room.revision
    }, now, id);
    if (peerResult.status !== 200) throw new Error('Test partner ready failed');
    result.state = peerResult.state;
  }
  if (room.status === 'open' && input.action === 'confirm') {
    const humanKey = accountKey(uid);
    const humanOffer = result.state.rooms[roomId].offers[humanKey] ?? { coins: 0, cards: [] };
    const isEmpty = humanOffer.coins === 0 && humanOffer.cards.length === 0;
    if (isEmpty) {
      const peerResult = transition(result.state, peerUid, {
        action: 'confirm', roomId, revision: room.revision
      }, now, id);
      if (peerResult.status !== 200) throw new Error('Test partner confirm failed');
      result.state = peerResult.state;
    }
  }
  // Return the real player's view; never leak the simulated player's identity as self.
  const updated = result.state.rooms[roomId];
  if (updated.status === 'completed') {
    updated.handshakes ??= {};
    if (!updated.handshakes[peerKey]) updated.handshakes[peerKey] = EMPTY_NATIVE_HANDSHAKE;
  }
  result.body.room = {
    ...result.body.room, revision: updated.revision, status: updated.status,
    self: accountKey(uid), members: updated.members, offers: updated.offers,
    ready: updated.ready, confirmed: updated.confirmed, handshakes: updated.handshakes ?? {},
    signals: updated.signals ?? {},
    ...(updated.closedAt !== undefined ? { closedAt: updated.closedAt } : {}),
    testPartner: true
  };
  return result;
}
