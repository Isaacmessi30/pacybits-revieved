// All mutations run inside one database transaction; callers supply verified identity.
export const ROOM_TTL_MS = 5 * 60_000;
export const QUEUE_TTL_MS = 60_000;
const MAX_COINS = 1_000_000_000;
const MAX_COPIES = 1_000_000;
const SAFE_ID = /^[a-zA-Z0-9_-]{1,128}$/;
const ACTIONS = new Set(['register', 'importLegacyInventory', 'status', 'invite', 'join', 'queue', 'leaveQueue', 'offer', 'ready', 'confirm', 'cancel']);

export class TradeError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}
function requireValue(condition, code, status = 400) {
  if (!condition) throw new TradeError(code, status);
}
function plain(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}
function integer(value, min, max) { return Number.isSafeInteger(value) && value >= min && value <= max; }
export function accountKey(uid) {
  requireValue(typeof uid === 'string' && uid.length > 0 && uid.length <= 128, 'INVALID_UID');
  return `u_${Buffer.from(uid).toString('base64url')}`;
}
export function emptyState() { return { version: 1, accounts: {}, rooms: {}, queue: {} }; }
function account(state, key) {
  const a = state.accounts[key];
  requireValue(a && a.allowed === true && a.banned !== true, 'ACCOUNT_NOT_APPROVED', 403);
  requireValue(integer(a.coins, 0, MAX_COINS) && plain(a.cards), 'INVENTORY_NOT_READY', 409);
  return a;
}
function stopRoom(state, room, status, now) {
  room.status = status;
  room.closedAt = now;
  for (const key of room.members) {
    if (state.accounts[key]?.activeRoom === room.id) delete state.accounts[key].activeRoom;
  }
}
function expire(state, key, now) {
  const a = state.accounts[key];
  if (a?.activeRoom) {
    const room = state.rooms[a.activeRoom];
    if (!room || room.status !== 'open') delete a.activeRoom;
    else if (room.expiresAt <= now) stopRoom(state, room, 'expired', now);
  }
  if (state.queue[key]?.expiresAt <= now) delete state.queue[key];
}
function roomFor(state, key, id, now, allowClosed = false) {
  requireValue(typeof id === 'string' && SAFE_ID.test(id), 'INVALID_ROOM_ID');
  const room = state.rooms[id];
  requireValue(room && room.members.includes(key), 'ROOM_NOT_FOUND', 404);
  for (const member of room.members) account(state, member);
  if (!allowClosed) requireValue(room.status === 'open' && room.expiresAt > now, 'ROOM_CLOSED', 409);
  return room;
}
function available(state, key, now) {
  expire(state, key, now);
  const a = account(state, key);
  requireValue(a.inventoryReady !== false, 'INVENTORY_IMPORT_REQUIRED', 409);
  requireValue(!a.activeRoom, 'ALREADY_IN_TRADE', 409);
  requireValue(!state.queue[key], 'ALREADY_QUEUED', 409);
  return a;
}
function createRoom(state, creator, peer, id, now) {
  requireValue(SAFE_ID.test(id) && !state.rooms[id], 'ROOM_ID_COLLISION', 409);
  const members = peer ? [creator, peer] : [creator];
  const room = {
    id, members, status: 'open', createdAt: now, expiresAt: now + ROOM_TTL_MS,
    revision: 0, offers: {}, ready: {}, confirmed: {}
  };
  for (const key of members) {
    account(state, key).activeRoom = id;
    room.offers[key] = { coins: 0, cards: [] };
  }
  state.rooms[id] = room;
  return room;
}
function view(room, key) {
  return {
    id: room.id, status: room.status, expiresAt: room.expiresAt, revision: room.revision,
    self: key, members: room.members,
    offers: room.offers, ready: room.ready, confirmed: room.confirmed,
    ...(room.closedAt !== undefined ? { closedAt: room.closedAt } : {})
  };
}
function validOffer(input) {
  requireValue(plain(input) && Object.keys(input).sort().join(',') === 'cards,coins', 'INVALID_OFFER');
  requireValue(integer(input.coins, 0, MAX_COINS), 'INVALID_COINS');
  requireValue(Array.isArray(input.cards) && input.cards.length <= 3, 'MAX_THREE_CARDS');
  const ids = new Set();
  for (const card of input.cards) {
    requireValue(typeof card === 'string' && SAFE_ID.test(card)
      && !['__proto__', 'constructor', 'prototype'].includes(card), 'INVALID_CARD');
    requireValue(!ids.has(card), 'DUPLICATE_CARD');
    ids.add(card);
  }
  return { coins: input.coins, cards: [...input.cards].sort() };
}
function owns(a, offer) {
  requireValue(a.coins >= offer.coins, 'INSUFFICIENT_COINS', 409);
  for (const card of offer.cards) {
    requireValue(Object.hasOwn(a.cards, card) && integer(a.cards[card], 1, MAX_COPIES), 'CARD_NOT_OWNED', 409);
  }
}
function settle(state, room, now) {
  const [left, right] = room.members;
  const a = account(state, left), b = account(state, right);
  const x = room.offers[left], y = room.offers[right];
  owns(a, x); owns(b, y);
  const aCoins = a.coins - x.coins + y.coins;
  const bCoins = b.coins - y.coins + x.coins;
  requireValue(integer(aCoins, 0, MAX_COINS) && integer(bCoins, 0, MAX_COINS), 'BALANCE_LIMIT', 409);
  a.coins = aCoins; b.coins = bCoins;
  for (const card of new Set([...x.cards, ...y.cards])) {
    const aCount = (a.cards[card] ?? 0) - Number(x.cards.includes(card)) + Number(y.cards.includes(card));
    const bCount = (b.cards[card] ?? 0) - Number(y.cards.includes(card)) + Number(x.cards.includes(card));
    requireValue(integer(aCount, 0, MAX_COPIES) && integer(bCount, 0, MAX_COPIES), 'CARD_LIMIT', 409);
    if (aCount) a.cards[card] = aCount; else delete a.cards[card];
    if (bCount) b.cards[card] = bCount; else delete b.cards[card];
  }
  a.inventoryVersion = (a.inventoryVersion ?? 0) + 1;
  b.inventoryVersion = (b.inventoryVersion ?? 0) + 1;
  stopRoom(state, room, 'completed', now);
}
function rateLimit(a, now, action) {
  a.limits ??= {};
  const bucket = action === 'status' ? 'read' : 'write';
  const capacity = bucket === 'read' ? 90 : 30;
  const old = a.limits[bucket] ?? { tokens: capacity, at: now };
  const tokens = Math.min(capacity, old.tokens + Math.max(0, now - old.at) * capacity / 60_000);
  requireValue(tokens >= 1, 'RATE_LIMITED', 429);
  a.limits[bucket] = { tokens: tokens - 1, at: now };
  if (['invite', 'join', 'queue'].includes(action)) {
    requireValue(!a.lastMatchAt || now - a.lastMatchAt >= 3000, 'MATCHMAKING_COOLDOWN', 429);
    a.lastMatchAt = now;
  }
}
function execute(state, key, input, now, id) {
  const a = account(state, key);
  switch (input.action) {
    case 'register': return { inventoryReady: a.inventoryReady !== false, inventoryVersion: a.inventoryVersion ?? 0 };
    case 'importLegacyInventory': {
      requireValue(a.inventoryReady === false && a.inventoryImportedAt === undefined,
        'INVENTORY_ALREADY_INITIALIZED', 409);
      requireValue(!a.activeRoom && !state.queue[key], 'ACCOUNT_BUSY', 409);
      requireValue(plain(input.inventory) && Object.keys(input.inventory).sort().join(',') === 'cards,coins', 'INVALID_INVENTORY');
      const { coins, cards } = input.inventory;
      requireValue(integer(coins, 0, MAX_COINS) && plain(cards), 'INVALID_INVENTORY');
      requireValue(Object.keys(cards).length <= 30000, 'INVENTORY_TOO_LARGE');
      for (const [card, copies] of Object.entries(cards)) {
        requireValue(SAFE_ID.test(card) && !['__proto__', 'constructor', 'prototype'].includes(card)
          && integer(copies, 1, MAX_COPIES), 'INVALID_INVENTORY');
      }
      a.coins = coins;
      a.cards = structuredClone(cards);
      a.inventoryVersion = 1;
      a.inventoryReady = true;
      a.inventoryImportedAt = now;
      a.inventoryOrigin = 'legacy-client-unverified';
      return { inventory: { coins: a.coins, cards: a.cards }, inventoryReady: true, inventoryVersion: 1 };
    }
    case 'status': {
      const room = input.roomId
        ? roomFor(state, key, input.roomId, now, true)
        : a.activeRoom ? state.rooms[a.activeRoom] : null;
      return { room: room ? view(room, key) : null, queued: Boolean(state.queue[key]),
        inventory: { coins: a.coins, cards: a.cards }, inventoryReady: a.inventoryReady !== false,
        inventoryVersion: a.inventoryVersion ?? 0, inventoryOrigin: a.inventoryOrigin ?? 'server' };
    }
    case 'invite': {
      available(state, key, now);
      return { room: view(createRoom(state, key, null, id, now), key) };
    }
    case 'join': {
      available(state, key, now);
      requireValue(typeof input.roomId === 'string' && SAFE_ID.test(input.roomId), 'INVALID_ROOM_ID');
      const room = state.rooms[input.roomId];
      requireValue(room && room.status === 'open' && room.expiresAt > now && room.members.length === 1, 'INVITE_UNAVAILABLE', 404);
      const creator = room.members[0];
      requireValue(creator !== key, 'SELF_TRADE');
      requireValue(account(state, creator).activeRoom === room.id, 'INVITE_UNAVAILABLE', 409);
      room.members.push(key);
      room.offers[key] = { coins: 0, cards: [] };
      room.revision += 1;
      room.ready = {}; room.confirmed = {};
      a.activeRoom = room.id;
      return { room: view(room, key) };
    }
    case 'queue': {
      requireValue(a.inventoryReady !== false, 'INVENTORY_IMPORT_REQUIRED', 409);
      if (a.activeRoom) return { room: view(state.rooms[a.activeRoom], key), queued: false };
      for (const peer of Object.keys(state.queue).sort((x, y) => state.queue[x].since - state.queue[y].since)) {
        if (peer === key) continue;
        expire(state, peer, now);
        if (!state.queue[peer]) continue;
        const other = state.accounts[peer];
        if (!other?.allowed || other.banned || other.activeRoom || other.inventoryReady === false) { delete state.queue[peer]; continue; }
        account(state, peer);
        delete state.queue[key]; delete state.queue[peer];
        return { room: view(createRoom(state, peer, key, id, now), key), queued: false };
      }
      state.queue[key] = { since: state.queue[key]?.since ?? now, expiresAt: now + QUEUE_TTL_MS };
      return { room: null, queued: true };
    }
    case 'leaveQueue': delete state.queue[key]; return { queued: false };
    case 'cancel': {
      const room = roomFor(state, key, input.roomId, now, true);
      if (room.status === 'open') stopRoom(state, room, 'cancelled', now);
      return { room: view(room, key) };
    }
    default: {
      const room = roomFor(state, key, input.roomId, now, true);
      requireValue(integer(input.revision, 0, Number.MAX_SAFE_INTEGER) && input.revision === room.revision, 'STALE_REVISION', 409);
      if (room.status === 'completed' && input.action === 'confirm') return { room: view(room, key) };
      requireValue(room.status === 'open' && room.expiresAt > now, 'ROOM_CLOSED', 409);
      requireValue(room.members.length === 2, 'WAITING_FOR_PARTNER', 409);
      if (input.action === 'offer') {
        const offer = validOffer(input.offer);
        owns(a, offer);
        room.offers[key] = offer;
        room.revision += 1;
        room.ready = {}; room.confirmed = {};
      } else if (input.action === 'ready') {
        owns(a, room.offers[key]);
        room.ready[key] = room.revision;
      } else if (input.action === 'confirm') {
        requireValue(room.members.every(member => room.ready[member] === room.revision), 'BOTH_PLAYERS_MUST_BE_READY', 409);
        room.confirmed[key] = room.revision;
        if (room.members.every(member => room.confirmed[member] === room.revision)) settle(state, room, now);
      }
      return { room: view(room, key) };
    }
  }
}

export function transition(current, uid, input, now, newRoomId) {
  // Pure and deterministic so Firebase may retry it against a newer snapshot.
  const state = structuredClone(current ?? emptyState());
  requireValue(state.version === 1, 'UNSUPPORTED_LEDGER_VERSION', 500);
  state.accounts ??= {}; state.rooms ??= {}; state.queue ??= {};
  // Realtime Database removes empty arrays/objects instead of storing them.
  for (const a of Object.values(state.accounts)) a.cards ??= {};
  for (const room of Object.values(state.rooms)) {
    room.ready ??= {}; room.confirmed ??= {}; room.offers ??= {};
    for (const offer of Object.values(room.offers)) offer.cards ??= [];
  }
  const key = accountKey(uid);
  let candidate;
  try {
    requireValue(plain(input), 'INVALID_REQUEST');
    if (input.action === 'register' && !state.accounts[key]) {
      requireValue(Object.keys(input).length === 1, 'UNEXPECTED_FIELD');
      state.accounts[key] = { allowed: true, coins: 0, cards: {}, inventoryReady: false,
        inventoryVersion: 0, createdAt: now };
    }
    const a = account(state, key);
    rateLimit(a, now, input.action);
    requireValue(ACTIONS.has(input.action), 'UNKNOWN_ACTION');
    const fields = {
      register: ['action'], importLegacyInventory: ['action', 'inventory'],
      status: ['action', 'roomId'], invite: ['action'], join: ['action', 'roomId'],
      queue: ['action'], leaveQueue: ['action'], cancel: ['action', 'roomId'],
      offer: ['action', 'roomId', 'revision', 'offer'],
      ready: ['action', 'roomId', 'revision'], confirm: ['action', 'roomId', 'revision']
    };
    requireValue(Object.keys(input).every(k => fields[input.action].includes(k)), 'UNEXPECTED_FIELD');
    expire(state, key, now);
    candidate = structuredClone(state);
    const result = execute(candidate, key, input, now, newRoomId);
    return { state: candidate, status: 200, body: { ok: true, ...result } };
  } catch (error) {
    if (!(error instanceof TradeError)) throw error;
    // Retain the rate debit, but discard any partial trade mutation on failure.
    return { state, status: error.status, body: { ok: false, error: error.code } };
  }
}
