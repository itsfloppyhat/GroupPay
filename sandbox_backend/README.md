# Group Pay local card backend

This development service creates and funds **Marqeta sandbox virtual cards** for the iOS simulator. It uses Python 3.11+ and its standard library; no packages are required. It cannot contact a production Marqeta endpoint or accept connections from another device.

## Setup on this Mac

From the repository root:

```sh
python3 sandbox_backend/setup.py
python3 sandbox_backend/setup.py --credentials
python3 sandbox_backend/server.py
```

The first command creates private local settings and a random app connection token. The second asks for your sandbox URL, application token, and admin access token in your local terminal. Provider tokens are entered without echoing. They remain in `sandbox_backend/.env` with owner-only permissions and must never be committed or pasted into chat. Existing local app tokens are retained.

Use the sandbox credentials supplied in your [Marqeta developer account](https://www.marqeta.com/docs/developer-guides/core-api-quick-start). The supported API address is `https://sandbox-api.marqeta.com/v3`. HTTPS on port 443 is mandatory; all redirects and system proxy forwarding are disabled. Other hosts are rejected, including production.

For the simulator, install a Debug app with normal Xcode signing enabled so its Keychain entitlements are generated. Pair it without printing any tokens:

```sh
python3 sandbox_backend/configure_simulator.py --device <simulator-UDID>
```

Omit `--device` if exactly one simulator is booted. The helper launches the app with only its local bearer token, which the Debug simulator build saves in Keychain. Marqeta credentials are never passed to the app. Open **Profile → Configure sandbox → Save & check connection**, then **Issue a $10 test card**. This explicitly fictional test is independent of the iCloud group workflow.

For manual pairing, use `http://127.0.0.1:8787` and the **local app connection token**, not either Marqeta credential. To show that local token in your terminal:

```sh
python3 sandbox_backend/setup.py --show-client-token
```

Leave the server running while testing. Restart it after editing settings. It can start without provider credentials: connection checks show `ready: false` and card creation returns `503 not_configured`. A successful connection check confirms the local token and the presence of provider credentials; their validity is checked by the first card request.

The server binds only IPv4 loopback. A physical iPhone cannot connect to this Mac service using its own localhost address. Remote-device hosting and production deployment require a separate authenticated backend design.

## Sandbox card flow

An issuance request validates the claimed approval snapshot, creates or reuses an active virtual card product and program funding source, then creates one synthetic account, card, and GPA funding order for that bill cycle. Marqeta holds the funds in that synthetic account's general purpose account (GPA); the isolated card accesses those funds. The only customer information sent is the synthetic name “Group Pay Sandbox.” The API never forwards your iCloud account IDs to Marqeta.

The product uses `config.fulfillment.payment_instrument: VIRTUAL_PAN` and `config.card_life_cycle.activate_upon_issue: true`, with JIT funding disabled. [Create card product](https://www.marqeta.com/docs/core-api/card-products/create-card-product), [create card](https://www.marqeta.com/docs/core-api/cards/create-card).

Sandbox funds come from a program funding source through a GPA order whose amount equals the approved bill total. Completion requires a matching completed funding result; creating a card alone does not mark issuance complete. [Program funding sources](https://www.marqeta.com/docs/core-api/program-funding-sources/create-program-source), [GPA orders](https://www.marqeta.com/docs/core-api/gpa-orders/create-gpa-order).

If your sandbox does not allow creating products or funding sources, set `MARQETA_CARD_PRODUCT_TOKEN` and/or `MARQETA_FUNDING_SOURCE_TOKEN` in `.env` to existing sandbox resources, then restart. The configured product must be active, virtual, activate upon issue, and have JIT funding disabled. The program funding source must be active. These optional resources are retrieved, never automatically modified. An inactive synthetic user must be activated in the sandbox dashboard before retrying; user status is managed through transitions. [Create user](https://www.marqeta.com/docs/core-api/users/create-user).

## Local API

All `/v1/` routes require `Authorization: Bearer <GROUP_PAY_CLIENT_TOKEN>`. Requests must use a loopback Host header; browser Origin headers are rejected. JSON error responses have `{ "error": "stable_code", "message": "safe explanation" }`. Provider error bodies, credentials, PANs, and CVVs are never returned or logged.

| Method | Path | Response |
| --- | --- | --- |
| GET | `/health` | `200 {"ready": false}`; unauthenticated, configuration presence only |
| GET | `/v1/status` | `200 {"ready": false, "environment": "sandbox"}`; validates the local bearer token |
| POST | `/v1/cards` | `200` masked funded-card result below; can safely be retried with the same snapshot |
| GET | `/v1/cards/{billID}/{cycle}` | `200` saved result, `202` pending, or `404` when never attempted |

Example request body (all amounts are integer cents):

```json
{
  "billID": "8800755C-AE74-4510-93AE-A10A6C28EDFE",
  "cycle": 1,
  "amountCents": 1001,
  "currency": "USD",
  "leaderID": "leader-account-id",
  "members": [
    {"accountID": "leader-account-id", "approved": true, "shareCents": 500},
    {"accountID": "guest-account-id", "approved": true, "shareCents": 501}
  ]
}
```

A request needs a valid bill UUID, cycle 1–1,000,000, USD total 1–10,000,000 cents, and 2–50 unique claimed accounts. Every member must approve, the leader must be included, and shares must total exactly the bill amount. **These identity and approval fields are trusted assertions from the local app, not independently authenticated iCloud identities or server-verified approvals.** Anyone with the local bearer token can submit them. This is suitable only for this local, simulated-money prototype.

Example successful response:

```json
{
  "provider": "marqetaSandbox",
  "cardToken": "2c2d3721-8870-5a10-b30a-607a091d1048",
  "lastFour": "9876",
  "state": "ACTIVE",
  "loadedCents": 1001,
  "remainingCents": 1001,
  "createdAt": "2026-11-14T20:00:00Z"
}
```

A pending lookup returns `202 {"status":"pending","message":"Retry creation with the same approved bill to reconcile the original issuance."}`. POST the same approved snapshot to resume; lookup itself never creates or funds anything.

## Durable recovery

Keep `sandbox_backend/data/issuance.sqlite3` and its SQLite sidecar files. The database contains hashed approved snapshots, a sandbox application fingerprint, resource tokens, durable attempt markers, and masked completed results. It stores no provider credentials, raw iCloud identities, PANs, or CVVs. Deterministic resource UUIDs fit Marqeta's 36-character token limit.

The same bill UUID and cycle is one issuance intent. Retrying it returns the saved result or retrieves the original provider resources by token. A changed amount, leader, member set, or allocation returns `409 bill_changed`. Reordering members or changing UUID letter case has no effect. A different application token with an existing bill cycle returns `409 sandbox_changed` before contacting Marqeta; restore the original application to reconcile it. Rotating the admin access token for the same application is supported.

A durable marker is committed **before** each create request. If a network timeout or crash makes acceptance uncertain, subsequent attempts retrieve that exact resource; they never blindly repeat the load. Delayed completions can therefore recover without a duplicate card or load. Definitive client rejections such as 401/403 can be retried after setup is corrected.

If the original request never reached Marqeta and GET still returns 404, the service deliberately keeps returning `503 reconciliation_pending`. There is no automatic timeout-based deletion of that marker and no manual reset endpoint. An operator must verify the original resource's disposition before any repair. Do not delete the database, change application, or invent a new bill cycle to bypass an unresolved request.

This service implements issuance only. It does not expose card PAN/CVV, simulate purchases, provision Apple Pay, reconcile later external transactions, or collect real money. `remainingCents` is the initial funded amount saved at issuance, not a live balance after activity performed outside Group Pay.

## Offline verification

```sh
python3 -m unittest discover -s sandbox_backend -p 'test_*.py' -v
```

The suite uses a mock Marqeta transport and temporary local HTTP servers. It tests cents and approval validation, endpoint restrictions, authentication, masked results, same-intent concurrency, restart recovery, accepted-but-timed-out creation/funding, no blind duplicate funding, partial failures, and changed snapshots/applications. It makes no requests to Marqeta.

A separate credentialed check on November 14, 2026 issued an active $10.00 virtual card from the iPhone 18 Pro Max simulator. Replaying the same request returned its saved funded result without another provider creation or funding attempt. Rerun that connection test when changing credentials or hosting.
