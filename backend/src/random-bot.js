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
  if (!enabled) return transition(current, uid, input, now, id);

  if (input.action === 'botWishlist') {
    const base = transition(current, uid, { action: 'status', roomId: input.roomId }, now, id);
    if (base.status !== 200) return base;
    const state = base.state;
    const room = state.rooms[input.roomId];
    if (!room?.botPartnerUid || room.status !== 'open' || room.members.length !== 2) {
      return { state, status: 409, body: { ok: false, error: 'BOT_ROOM_REQUIRED' } };
    }
    if (!Array.isArray(input.cardIds) || input.cardIds.length > 3 ||
        input.cardIds.some(card => typeof card !== 'string' ||
          !/^[a-zA-Z0-9_-]{1,128}$/.test(card)) ||
        new Set(input.cardIds).size !== input.cardIds.length) {
      return { state, status: 400, body: { ok: false, error: 'INVALID_BOT_WISHLIST' } };
    }
    const botKey = accountKey(room.botPartnerUid);
    const bot = state.accounts[botKey];
    if (!bot) return { state, status: 409, body: { ok: false, error: 'BOT_ACCOUNT_MISSING' } };

    bot.cards = {};
    bot.coins = 0;
    bot.preserveFirstCopy = false;
    bot.inventoryReady = true;
    bot.inventoryVersion = (bot.inventoryVersion ?? 0) + 1;
    for (const card of input.cardIds) bot.cards[card] = 1;

    const peer = transition(state, room.botPartnerUid, {
      action: 'offer',
      roomId: room.id,
      revision: room.revision,
      offer: { coins: 0, cards: input.cardIds, slots: input.cardIds.map((_, index) => index) }
    }, now, id);
    if (peer.status !== 200) return peer;
    const updated = peer.state.rooms[room.id];
    return {
      state: peer.state,
      status: 200,
      body: { ok: true, room: humanView(updated, uid), queued: false }
    };
  }

  if (input.action === 'botPeerHandshake') {
    const base = transition(current, uid, { action: 'status', roomId: input.roomId }, now, id);
    if (base.status !== 200) return base;
    const state = base.state;
    const room = state.rooms[input.roomId];
    if (!room?.botPartnerUid || room.status !== 'completed' || room.members.length !== 2) {
      return { state, status: 409, body: { ok: false, error: 'BOT_COMPLETED_ROOM_REQUIRED' } };
    }
    if (typeof input.payload !== 'string' || input.payload.length === 0 ||
        input.payload.length > 12000 || !/^[A-Za-z0-9+/=]+$/.test(input.payload)) {
      return { state, status: 400, body: { ok: false, error: 'INVALID_HANDSHAKE' } };
    }
    const botKey = accountKey(room.botPartnerUid);
    room.handshakes ??= {};
    room.handshakes[botKey] = input.payload;
    const human = state.accounts[accountKey(uid)];
    return {
      state,
      status: 200,
      body: {
        ok: true,
        room: humanView(room, uid),
        inventory: { coins: human.coins, cards: human.cards },
        inventoryVersion: human.inventoryVersion ?? 0,
        preserveFirstCopy: human.preserveFirstCopy === true
      }
    };
  }

  let result = transition(current, uid, input, now, id);
  if (result.status !== 200) return result;

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
    const safeBotGift =
      humanOffer.coins === 0 && humanOffer.cards.length === 0 &&
      botOffer.coins === 0 && botOffer.cards.length <= 3;

    if (safeBotGift) {
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
    if ((updated.offers?.[botKey]?.cards?.length ?? 0) === 0 &&
        !updated.handshakes[botKey]) {
      updated.handshakes[botKey] = EMPTY_NATIVE_HANDSHAKE;
    }
  }
  if (updated) result.body.room = humanView(updated, uid);
  return result;
}
