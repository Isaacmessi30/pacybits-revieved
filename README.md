# PACYBITS revival development

Development source for a Google-authenticated trading backend and iOS client.
**There is no working modified IPA yet.** The original game has not been
connected to this backend, and real Google login/device trading is untested.

## Hosted Mac build

Open **Actions → Client build and backend checks**. A push to `main` starts
checks; **Run workflow** starts them manually. The Mac job uses Xcode 16.4 on
GitHub, so Xcode is not required on your computer.

The workflow runs backend unit tests, portable Swift checks, XCTest, and an
arm64 iPhone SDK compile targeting iOS 15. Its downloadable artifact is an
**unsigned static client library, not an installable IPA**. The workflow also compiles the Google login coordinator against GoogleSignIn
9.0.0. Wiring it into the original game and testing real login remain required.

No signing certificate, Firebase service-account key or production credentials
are needed by this workflow. There is no cloud deployment. Artifacts expire
after seven days. GitHub account Actions allowances and billing still apply.

## Components

- [Backend](backend/README.md): Google session checks, invitation/random rooms,
  offer revisions, rate limits and atomic trading settlement.
- [Client](client/README.md): Firebase Auth REST, token refresh, typed trading API
  and an iOS Google login coordinator source file.
- Database rules deny all direct client database reads and writes.

Players can import existing cards and coins once. That initial collection is
unverified; later transfers use the server ledger. Ongoing offline earnings
synchronization and original save integration remain unfinished.

## Remaining work

Connect GoogleSignIn and URL callbacks, map the original collection storage,
connect the game screens to the API, reconcile committed inventory, package an
unsigned IPA, then sign using ESign and test on real devices. Building a client
library alone does not establish that the game works.
