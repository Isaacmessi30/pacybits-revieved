import { Buffer } from 'node:buffer';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function form(values) {
  return new URLSearchParams(values).toString();
}

function accountKey(uid) {
  return 'u_' + Buffer.from(uid).toString('base64url');
}

function plistEscape(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

function introPayload() {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>value</key><dict><key>clubName</key><string>${plistEscape('REVIVAL BOT')}</string><key>badgeName</key><string>pacybits_fc_logo_large.png</string></dict></dict></plist>`;
  return Buffer.from(xml, 'utf8').toString('base64');
}

export class AuthenticatedRandomBot {
  constructor({ endpoint, database, googleClientId, firebaseApiKey, googleRefreshToken, log = console.log }) {
    this.endpoint = endpoint;
    this.database = database;
    this.googleClientId = googleClientId;
    this.firebaseApiKey = firebaseApiKey;
    this.googleRefreshToken = googleRefreshToken;
    this.log = log;
    this.firebaseRefreshToken = null;
    this.firebaseIdToken = null;
    this.firebaseUID = null;
    this.expiresAt = 0;
    this.running = false;
    this.introRoom = null;
    this.offeredRoom = null;
    this.initialized = false;
  }

  async start() {
    if (this.running) return;
    this.running = true;
    while (this.running) {
      try {
        await this.tick();
      } catch (error) {
        this.log(JSON.stringify({ event: 'authBot', status: 'error', message: error?.message ?? 'unknown' }));
        await sleep(2500);
      }
    }
  }

  stop() { this.running = false; }

  async googleToFirebase() {
    const google = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form({
        client_id: this.googleClientId,
        refresh_token: this.googleRefreshToken,
        grant_type: 'refresh_token'
      })
    });
    const googleBody = await google.json();
    if (!google.ok || typeof googleBody.id_token !== 'string') throw new Error('GOOGLE_REFRESH_FAILED');

    const firebase = await fetch(
      'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=' + encodeURIComponent(this.firebaseApiKey), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          postBody: form({ id_token: googleBody.id_token, providerId: 'google.com' }),
          requestUri: 'http://localhost',
          returnSecureToken: true
        })
      });
    const body = await firebase.json();
    if (!firebase.ok || typeof body.idToken !== 'string' || typeof body.refreshToken !== 'string' ||
        typeof body.localId !== 'string') throw new Error('FIREBASE_GOOGLE_EXCHANGE_FAILED');
    this.firebaseIdToken = body.idToken;
    this.firebaseRefreshToken = body.refreshToken;
    this.firebaseUID = body.localId;
    this.expiresAt = Date.now() + Math.max(60, Number(body.expiresIn ?? 3600)) * 1000;
  }

  async refreshFirebase() {
    if (!this.firebaseRefreshToken) return this.googleToFirebase();
    const response = await fetch(
      'https://securetoken.googleapis.com/v1/token?key=' + encodeURIComponent(this.firebaseApiKey), {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form({ grant_type: 'refresh_token', refresh_token: this.firebaseRefreshToken })
      });
    const body = await response.json();
    if (!response.ok || typeof body.id_token !== 'string' || typeof body.refresh_token !== 'string') {
      this.firebaseRefreshToken = null;
      return this.googleToFirebase();
    }
    this.firebaseIdToken = body.id_token;
    this.firebaseRefreshToken = body.refresh_token;
    this.firebaseUID = body.user_id;
    this.expiresAt = Date.now() + Math.max(60, Number(body.expires_in ?? 3600)) * 1000;
  }

  async token() {
    if (!this.firebaseIdToken || Date.now() + 60000 >= this.expiresAt) await this.refreshFirebase();
    return this.firebaseIdToken;
  }

  async call(body, retry = true) {
    const token = await this.token();
    const response = await fetch(this.endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
      body: JSON.stringify(body)
    });
    const result = await response.json();
    if (response.status === 401 && retry) {
      this.firebaseIdToken = null;
      await this.refreshFirebase();
      return this.call(body, false);
    }
    if (!response.ok) {
      const error = new Error(result?.error ?? ('HTTP_' + response.status));
      error.status = response.status;
      throw error;
    }
    return result;
  }

  async markBotAccount() {
    const key = accountKey(this.firebaseUID);
    await this.database.ref('revivalPrivate').transaction(state => {
      if (!state?.accounts?.[key]) return state;
      state.accounts[key].authenticatedBot = true;
      state.accounts[key].preserveFirstCopy = false;
      return state;
    }, undefined, false);
  }

  async stock(cards) {
    if (!cards.length) return;
    const key = accountKey(this.firebaseUID);
    await this.database.ref('revivalPrivate').transaction(state => {
      const account = state?.accounts?.[key];
      if (!account) return state;
      account.cards ??= {};
      for (const card of cards) account.cards[card] = Math.max(1, account.cards[card] ?? 0);
      account.coins = 0;
      account.preserveFirstCopy = false;
      return state;
    }, undefined, false);
  }

  async ensureRegistered() {
    if (this.initialized) return;
    const registered = await this.call({ action: 'register' });
    if (registered.inventoryReady === false) {
      await this.call({
        action: 'importLegacyInventory',
        inventory: { coins: 0, cards: {} },
        preserveFirstCopy: false
      });
    }
    await this.markBotAccount();
    this.initialized = true;
    this.log(JSON.stringify({ event: 'authBot', status: 'authenticated' }));
  }

  async tick() {
    await this.ensureRegistered();
    let status = await this.call({ action: 'status' });

    if (!status.room) {
      this.introRoom = null;
      this.offeredRoom = null;
      if (!status.queued) {
        try { status = await this.call({ action: 'queue', scope: 'g:0:a:0' }); }
        catch (error) {
          if (error.message !== 'MATCHMAKING_COOLDOWN') throw error;
        }
      }
      await sleep(1400);
      return;
    }

    const room = status.room;
    if (room.status !== 'open') {
      this.introRoom = null;
      this.offeredRoom = null;
      await sleep(1400);
      return;
    }

    if (this.introRoom !== room.id) {
      status = await this.call({
        action: 'signal',
        roomId: room.id,
        signalType: 'tradingIntro',
        signalPayload: introPayload()
      });
      this.introRoom = room.id;
    }

    const current = status.room ?? room;
    const self = current.self;
    const peer = current.members.find(member => member !== self);
    if (!peer) { await sleep(1400); return; }

    const wish = Array.isArray(current.wishlists?.[peer]) ? current.wishlists[peer].slice(0, 3) : [];
    const ownOffer = current.offers?.[self] ?? { coins: 0, cards: [] };
    if (wish.length && JSON.stringify(ownOffer.cards ?? []) !== JSON.stringify([...wish].sort())) {
      await this.stock(wish);
      const refreshed = await this.call({ action: 'status', roomId: current.id });
      const r = refreshed.room;
      await this.call({
        action: 'offer',
        roomId: r.id,
        revision: r.revision,
        offer: { coins: 0, cards: wish, slots: wish.map((_, i) => i) }
      });
      this.offeredRoom = r.id;
      await sleep(900);
      return;
    }

    const fresh = current;
    if (fresh.status !== 'open') { await sleep(1400); return; }

    if (fresh.ready?.[peer] === fresh.revision && fresh.ready?.[self] !== fresh.revision) {
      await this.call({ action: 'ready', roomId: fresh.id, revision: fresh.revision });
      await sleep(1000);
      return;
    }

    if (fresh.ready?.[peer] === fresh.revision && fresh.ready?.[self] === fresh.revision &&
        fresh.confirmed?.[peer] === fresh.revision && fresh.confirmed?.[self] !== fresh.revision) {
      await this.call({ action: 'confirm', roomId: fresh.id, revision: fresh.revision });
      await sleep(1000);
      return;
    }

    await sleep(1400);
  }
}
