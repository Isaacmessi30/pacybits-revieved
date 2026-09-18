import { accountKey, transition } from './trading.js';

const BOT_UID = 'revival-random-bot-v1';
const EMPTY_NATIVE_HANDSHAKE = Buffer.from(
  '<?xml version="1.0" encoding="UTF-8"?>' +
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' +
  '<plist version="1.0"><dict><key>coins</key><integer>0</integer><key>idsLeft</key><array/>' +
  '<key>idsRight</key><array/></dict></plist>', 'utf8').toString('base64');

function ensureBotAccount(state, now) {
  const key = accountKey(BOT_UID);
  if (!state.accounts[key]) {
    state.accounts[key] = {
      allowed: true,
      coins: 0,
      cards: {},
      inventoryReady: true,
      inventoryVersion: 1,
      preserveFirstCopy: true,
      botPartner: true,
      createdAt: now
    };
  }
  return key;
}

function humanView(room, uid) {
  return {
    id: room.id,
    status: room.status,
    expiresAt: room.expiresAt,
    revision: room.revision,
    self: accountKey(uid),
    members: room.members,
    offers: room.offers,
    ready: room.ready,
    confirmed: room.confirmed,
    handshakes: room.handshakes ?? {},
    signals: room.signals ?? {},
    ...(room.closedAt !== undefined ? { closedAt: room.closedAt } : {}),
    botPartner: true
  };
}

export function transitionWithRandomBot(current, uid, input, now, id, enabled = false) {
  let result = transition(current, uid, input, now, id);
  if (result.status !== 200 || !enabled) return result;

  if (input.action === 'queue' && input.scope && !input.targetLegacyId && !result.body.room) {
    const botKey = ensureBotAccount(result.state, now);
    const bot = result.state.accounts[botKey];

    if (bot.activeRoom) {
      const busyRoom = result.state.rooms[bot.activeRoom];
      if (busyRoom?.status === 'open' && busyRoom.expiresAt > now) {
        return result;
      }
      delete bot.activeRoom;
    }
    delete result.state.queue[botKey];

    const paired = transition(
      result.state,
      BOT_UID,
      { action: 'queue', scope: input.scope },
      now,
      id
    );
    if (paired.status !== 200 || !paired.body.room) {
      throw new Error('Random bot could not join queue');
    }

    result.state = paired.state;
    const roomId = paired.body.room.id;
    const room = result.state.rooms[roomId];
    room.botPartnerUid = BOT_UID;

    result.body = {
      ok: true,
      room: humanView(room, uid),
      queued: false
    };
  }

  const roomId = result.body.room?.id;
  const room = result.state.rooms[roomId];
  if (!room?.botPartnerUid) return result;

  const botKey = accountKey(room.botPartnerUid);
  if (uid === room.botPartnerUid || !room.members.includes(botKey) || room.members.length !== 2) {
    throw new Error('Invalid random bot room');
  }

  if (room.status === 'open' && input.action === 'ready') {
    const peer = transition(result.state, room.botPartnerUid, {
      action: 'ready',
      roomId,
      revision: room.revision
    }, now, id);
    if (peer.status !== 200) throw new Error('Random bot ready failed');
    result.state = peer.state;
  }

  if (room.status === 'open' && input.action === 'confirm') {
    const humanKey = accountKey(uid);
    const current = result.state.rooms[roomId];
    const humanOffer = current.offers[humanKey] ?? { coins: 0, cards: [] };
    const botOffer = current.offers[botKey] ?? { coins: 0, cards: [] };
    const safeZeroValue =
      humanOffer.coins === 0 && humanOffer.cards.length === 0 &&
      botOffer.coins === 0 && botOffer.cards.length === 0;

    if (safeZeroValue) {
      const peer = transition(result.state, room.botPartnerUid, {
        action: 'confirm',
        roomId,
        revision: current.revision
      }, now, id);
      if (peer.status !== 200) throw new Error('Random bot confirm failed');
      result.state = peer.state;
    }
  }

  const updated = result.state.rooms[roomId];
  if (updated?.status === 'completed') {
    updated.handshakes ??= {};
    if (!updated.handshakes[botKey]) updated.handshakes[botKey] = EMPTY_NATIVE_HANDSHAKE;
  }
  if (updated) result.body.room = humanView(updated, uid);
  return result;
}
