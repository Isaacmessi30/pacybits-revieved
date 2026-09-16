# Server test partner

This optional simulation lets one authenticated player test the invite, readiness
and confirmation flow. It does not use a second Firebase or Game Center account.
Authentication for the real player remains required.

In Render → Environment, add `REVIVAL_TEST_PARTNER_ENABLED` with value `true`,
then deploy the latest commit. In the existing connected IPA, tap Create invite.
The server joins a fresh, isolated simulated account to that room. Leave the offer
empty, tap Ready, then Confirm trade. The partner responds inside the same database
transaction. No cards or coins move, including on retries. Nonempty offers fail
with TEST_PARTNER_EMPTY_OFFER_ONLY.

The setting affects new invitation rooms for all players while enabled. Random
matchmaking is unchanged. Remove the setting or set it to false after the test
and redeploy to restore ordinary friend invitations. Already-created test rooms
can still finish or be cancelled after the setting is disabled.

A successful test confirms one phone's authenticated server flow. It does not
verify two independent phones, real inventory transfers, or peer connectivity.
The simulator has no sign-in token, public control endpoint, or grant operation.
