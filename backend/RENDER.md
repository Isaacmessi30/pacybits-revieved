# Deploy trading on Render Free

This hosts the existing trading API on Render while Firebase stays on Spark.
The API persists balances, offers and receipts in Firebase, not Render's disk.
It is a small-group development server; it does not complete the IPA integration.

## Setup in Safari

1. Open https://render.com/deploy?repo=https://github.com/Isaacmessi30/pacybits-revieved
   Or use Render **New → Blueprint**, then select this repository and `main`.
2. Allow Render's GitHub app access to the private `pacybits-revieved` repository.
3. Give the Blueprint a name, such as `pacybits-revival`.
4. Review the service `pacybits-revival-trading`. Its plan must be **Free**;
   the Blueprint sets `plan: free`. No Render database is needed.
5. Fill the prompted secret `FIREBASE_SERVICE_ACCOUNT_JSON` as described below.
6. Deploy the Blueprint. Wait for the service to show **Live**.
7. Open the service's generated `https://...onrender.com/healthz` URL.
   It should show `{"ok":true}`. Send the public service URL to the assistant.

If you already created the service without the secret, open its **Environment**
page, add the secret, save it and manually deploy the latest commit.

## Firebase credential — enter only in Render

Open:
https://console.firebase.google.com/project/pacybits---revival/settings/serviceaccounts/adminsdk

Select **Generate new private key**. Download the JSON, open it in a text editor,
and copy the entire JSON contents into Render's `FIREBASE_SERVICE_ACCOUNT_JSON`
secret field. This is a server credential, **not** `GoogleService-Info.plist`.
Do not put it in GitHub, the IPA, screenshots, chat, or a public download.
The server requires the key to belong to `pacybits---revival`.

Keep Firebase Realtime Database client rules locked. Admin credentials allow the
server to validate Google sessions and run transactions without opening rules.
No certificate or Apple credentials are required for this server.

## Configuration supplied by render.yaml

- Runtime: Node.js 22
- Root directory: `backend`
- Region: Frankfurt
- Build: `npm ci --omit=dev`
- Start: `npm start`
- Health check: `/healthz`
- API: `POST /trading` with JSON and a Google-backed Firebase bearer ID token
- Automatic code deploys: off; use Manual Deploy for tested updates
- Storage: the existing Firebase RTDB in europe-west1

`/healthz` proves only that the process runs. It does not prove Firebase credential
permissions, real Google login, or working phone-to-phone trading. An authenticated
request must verify those separately. The service refuses emulator settings unless
explicitly opted into a local `demo-*` project. Never set emulator variables in Render.

## Free-plan behavior

Render sleeps after 15 minutes without requests; waking can take about one minute.
The native client will need a wake/retry flow before matchmaking (not blind retries
of trades). Service restarts do not erase the Firebase ledger. Free usage limits
and Firebase Spark quotas still apply; high external-database traffic can trigger
Render free-service restrictions. No uptime guarantee or production scale claim.

References:
- https://render.com/docs/free
- https://render.com/docs/blueprint-spec
- https://firebase.google.com/docs/admin/setup
