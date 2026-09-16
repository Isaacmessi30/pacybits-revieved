import { accountKey, transition } from './trading.js';

// An explicit server simulation, never a Firebase user or an authentication bypass.
// It can only accept zero-value offers, so testing cannot mint or consume inventory.
export function transitionWithTestPartner(current, uid, input, now, id, enabled = false) {
  let result = transition(current, uid, input, now, id);
  if (result.status !== 200) return result;
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
  const roomId = result.body.room?.id;
  const room = result.state.rooms[roomId];
  if (!room?.testPartnerUid) return result;
  const peerUid = room.testPartnerUid;
  const peerKey = accountKey(peerUid);
  if (uid === peerUid || !room.members.includes(peerKey) || room.members.length !== 2) {
    throw new Error('Invalid test partner room');
  }
  if (room.status === 'open' && ['ready', 'confirm'].includes(input.action)) {
    const peerResult = transition(result.state, peerUid, {
      action: input.action, roomId, revision: room.revision
    }, now, id);
    if (peerResult.status !== 200) throw new Error('Test partner action failed');
    result.state = peerResult.state;
  }
  // Return the real player's view; never leak the simulated player's identity as self.
  const updated = result.state.rooms[roomId];
  result.body.room = {
    ...result.body.room, revision: updated.revision, status: updated.status,
    self: accountKey(uid), members: updated.members, offers: updated.offers,
    ready: updated.ready, confirmed: updated.confirmed,
    ...(updated.closedAt !== undefined ? { closedAt: updated.closedAt } : {}),
    testPartner: true
  };
  return result;
}
