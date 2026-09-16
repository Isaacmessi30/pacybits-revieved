# Revival trading backend — private development build

This backend is implemented and tested locally. It is **not deployed or
integrated into the IPA**. Native login integration, legacy inventory mapping, and
device testing remain required. See [the IPA inspection](../analysis/trading-map.md).

## Behavior

- POST JSON to `/trading` on the Render server, or the `trading` HTTPS function
  when using Firebase Functions.
- Authenticate with `Authorization: Bearer <Firebase ID token>` from a verified
  Google account. The server checks token validity, revocation and provider.
- A verified Google user calls `register` to create an empty account, then
  `importLegacyInventory` once to keep their existing collection. Trading is
  blocked until import completes. Registration never resets balances or bans.
- Clients cannot read or write Realtime Database directly. The API returns only
  the caller's inventory and rooms they participate in.
- Every offer change increments a room revision and clears both players'
  readiness and confirmations. Both must ready and confirm the same revision.
- Only the second confirmation settles a trade, in the same transaction as both
  inventories and the room receipt. Repeating that confirmation does not settle
  twice. The server rechecks ownership and integer limits before settlement.
- One active room per account, 5-minute fixed room expiry, 60-second queue lease,
  and 3-second matchmaking cooldown. Queue renewal requires another `queue`
  request before expiry; status polling does not renew a queue lease.
- Per-account token buckets allow 90 status requests/minute and 30 mutation
  attempts/minute with matching burst capacities. Failed approved-account
  requests also consume a budget. Clients should poll status about every
  2 seconds and back off on 429/503.

Google login and these controls do not prove a human is operating the app.
There is no device attestation, CAPTCHA, IP-level flood defense or automated
abuse classifier. Account creation is open to verified Google users; multiple Google accounts
can each import once. This is not protection against account farming.

## Request contract

The client cannot supply a UID, timestamp, approval flag or room ID
when creating a room. Balance claims are accepted only by the one-time legacy
import described below. The server supplies identity, time and a random UUID.
An invitation room ID is a join secret until the partner joins; share it only
with the intended partner. Membership is fixed once the second player joins.
This prototype uses a full UUID, not the original short numeric game code.

| action | Additional fields | Result |
| --- | --- | --- |
| `register` | none | create account or return initialization status |
| `importLegacyInventory` | `inventory: {coins, cards}` | initialize the ledger once |
| `status` | optional `roomId` | own inventory, room snapshot, queue status |
| `invite` | none | one-member invitation room |
| `join` | `roomId` | join an available invitation |
| `queue` | none | queue/renew or return a matched room |
| `leaveQueue` | none | remove own queue entry |
| `offer` | `roomId`, `revision`, `offer` | revised offer; readiness reset |
| `ready` | `roomId`, `revision` | ready for this exact offer revision |
| `confirm` | `roomId`, `revision` | confirm; commit after both confirm |
| `cancel` | `roomId` | cancel an open room, release locks |

`offer` has exactly `coins` (nonnegative integer up to 1 billion) and `cards`
(at most three unique card ID strings). These are proposed revival limits;
they are not a recovered original protocol. The ledger counts tradeable
copies; the meaning of a tradeable duplicate must be mapped before migration.

Example request after obtaining a room and its current revision:

```json
{"action":"offer","roomId":"SERVER_ROOM_UUID","revision":1,"offer":{"coins":100,"cards":["CARD_ID"]}}
```

Success returns `{ "ok": true, ... }`. Errors include `STALE_REVISION`,
`CARD_NOT_OWNED`, `INSUFFICIENT_COINS`, `ACCOUNT_NOT_APPROVED`, `RATE_LIMITED`,
and `ROOM_CLOSED`. Refresh state after a stale revision or uncertain network
result. Do not apply a local inventory transfer based only on a request being
sent. Fetch the committed server inventory after completion.

## Storage and inventory trust

Private storage root: `revivalPrivate`. All client database rules deny access;
only the trusted Admin SDK accesses it.

The engine uses `accounts`, `queue`, and `rooms` beneath a versioned root.
Account keys are `u_` plus the base64url encoding of the Firebase UID. Account
records contain `allowed`, optional `banned`, `coins`, `cards`, rate limits,
optional `activeRoom`, and inventory initialization/version metadata.

The user chose to preserve existing collections and accept their unverified
origin. A newly registered account can import once: up to 30,000 distinct card
IDs, 1–1,000,000 copies each and 0–1 billion coins, within a 256 KiB request.
Other requests are limited to 4 KiB. IDs use letters, digits, underscores and
hyphens. Mapping original card IDs and tradeable duplicates remains required.
The ledger records `inventoryOrigin: legacy-client-unverified`. This validates
shape and limits, not whether the player legitimately earned those cards.

Concurrent imports cannot overwrite each other: exactly one initializes the
account. Later imports fail, including after trading. Successful settlements
increment both inventory versions. Fetch `status` after uncertain responses;
never retry migration by deleting or recreating the server ledger. A new Google
account can import separately, so this design cannot prevent import farming.
Ongoing offline earnings and synchronization back into the original game are
not implemented. Existing device saves are not changed by this backend.

Fixtures seed **only the demo emulator project**. No live account records have
been created and no import from the IPA has been performed.

## Local checks

Requires Node.js 22 and Java for the database emulator. From the workspace root:

```sh
npm --prefix backend ci
npm --prefix backend test
XDG_CONFIG_HOME=/private/tmp/pacybits-revival-config FIREBASE_EMULATORS_PATH=/private/tmp/pacybits-revival-emulators backend/node_modules/.bin/firebase emulators:exec --project demo-pacybits-revival --only auth,database,functions 'npm --prefix backend run test:emulator'
```

The emulator suite verifies HTTP authentication checks, denied direct database
access, actual database serialization, concurrent confirmations, competing
joins and competing matchmaking requests. Emulator tokens simulate Google
claims; this does **not** test a real Google OAuth login.

## Deployment and operating limits

No deployment was performed. The screenshot supplied by the user showed Spark.
Firebase Functions deployment requires Blaze. A standalone Node.js server and
`render.yaml` now support Render Free while Firebase remains on Spark. See
[Render setup](RENDER.md). Both adapters share the same authentication and
transaction service. Live deployment is pending Render account setup and the
server credential; no real Google login has been tested.

This private-beta implementation serializes the whole ledger in a Realtime
Database transaction. That makes the initial conservation and race guarantees
straightforward to test, but it is **not a scalable public-service design**:
all users contend on the same root, status calls update persistent rate limits,
closed rooms accumulate, and each operation reads the ledger. Expired rooms are
closed lazily. A scheduled cleanup/archive policy, partitioned storage and load
testing are required before widening access. Closed receipts must not be
reused as new room IDs.

The two-instance setting limits compute concurrency, not total cost or DDoS
traffic. Native caller retries/backoff, operational monitoring and upstream
request filtering remain to be built. Do not advertise this as bot-proof.

## References

- [Firebase token verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens)
- [Admin database transactions](https://firebase.google.com/docs/database/admin/save-data)
- [Functions runtime and deployment](https://firebase.google.com/docs/functions/get-started)
