# Group Pay

A native SwiftUI group-payment prototype. Scan a receipt, split the total, invite your group, collect approvals, and create a virtual card using local simulation or Marqeta's sandbox. All funds are simulated.

## What works

- Native multipage document camera and photo import, using on-device Vision text recognition. Restaurant and grocery sample receipts and manual entry are included.
- Editable receipt review, tax, OCR total reconciliation, and exact integer-cent calculations in USD.
- Equal splits, custom subtotal amounts, or item assignment (including shared items). Tax follows the subtotal allocation. Each person chooses their own tip with a slider or exact amount; dining defaults to 20% of their food subtotal, other categories to 0%.
- A 1% Group Pay fee on food plus tax, excluding tips. Total contributions include the fee; the merchant card receives only food, tax, and tips. Fees and contributions are simulated accounting, not real collections.
- Saved friends and reusable groups in People. Accept a group invitation once; future bills created under that group inherit access.
- Separate iCloud identities and invite-only CloudKit sharing. Participants accept an Apple sharing invitation on their own device and claim their named portion.
- Individual approvals; only the leader can confirm once everyone has joined and approved.
- Only the leader sees card details. Shared bills contain status and amounts; card metadata is stored separately in the leader’s private iCloud records. Everyone receives card-ready status updates. Local mock cards support simulated payment and history.
- Optional Marqeta sandbox issuance through a Python backend on this Mac or Cloud Run: creates an active virtual card and funds its isolated test account for the receipt plus personal tips, excluding the fee. Provider credentials stay on the backend; the app stores only its team access code in Keychain. Interrupted requests resume the same card and funding order.
- Weekly/monthly schedules. The leader starts each cycle; participant approvals reset and the prior card is discarded. No automatic funding. Authorized local reminders prompt the leader at the next due date.
- Real CloudKit background-push registration plus local update banners, foreground refresh, and an inbox of pending approvals.
- Private data stays in the owner's private CloudKit database and invitees' shared databases. No public database or public-read share links.
- Evergreen and mint Home, Inbox, Cards, People, Profile, creation, receipt, and bill-detail screens with native artwork, scalable typography, and concise customer-facing messages. An explicitly read-only preview is available without iCloud. Team access is available in Profile; additional connection controls live under Advanced settings in Debug builds.

## Requirements and opening

Open `GroupPay.xcodeproj` and select the **GroupPay** scheme.

- Stable Xcode 27.2, iOS 27.2 SDK, Swift 6 language mode.
- Minimum deployment target **iOS 26.0** for both physical devices and simulators. No beta APIs.
- Bundle ID: `com.itsfloppyhat.GroupPay`.
- Developer team: Matthew Lucas (`FYWW2S89N3`). Change this in `project.yml` when using a different team.
- CloudKit container: `iCloud.com.itsfloppyhat.GroupPay`.

The project is generated with XcodeGen. After changing `project.yml`, run `xcodegen generate`. The generated Xcode project, Info.plist, and scheme are committed source artifacts; no dependencies need downloading.

## Test on two real accounts

1. In Xcode, select your developer team and automatic signing. iCloud/CloudKit, Push Notifications, CloudKit sharing, and background remote notifications are already configured. A signed development build was verified with the Matthew Lucas team after accepting Apple's updated program agreement.
2. Install the same development build on two devices running iOS 26.0 or later, each signed into a different iCloud account. Devices must be registered for the development profile. Enable iCloud Drive and use the same CloudKit development environment on both devices.
3. Open Profile, enter your display name, connect iCloud, and enable notifications on both devices.
4. On the leader’s device, connect **Profile → Team access** for hosted test cards. Start a split, scan/import a receipt or enter one manually, review food and tax, and add the other person. Choose equal, custom subtotal, or item allocation. On Review, adjust your own tip and create the split; this approves your portion.
5. Tap **Invite your group** and use Apple’s sharing interface to send the first private invitation. The recipient accepts it, chooses their name, adjusts their personal tip, and approves the exact total including the 1% fee. Saving another person’s tip does not reset your approval or change your fee.
6. On the leader’s device, confirm after everyone approves. The leader sees the funded card; the participant sees only card-ready status. With hosted cards the bill remains unpaid because merchant transaction simulation is not yet implemented. Local mock cards retain **Make a test payment**.
7. Open **People → People you’ve split with → Save friend**. Create a named group, select that friend, and use **Invite or manage group** to send the new group’s one-time invitation. The first accepted one-off bill does not automatically grant access to this new group.
8. After the friend accepts the group invitation, start another split and choose the **Saved group**. All selected members are already assigned to their iCloud identities and future bills inherit group access. No new text/link is needed for each bill. Group membership is fixed for this version; create another group for a different set of people. Only the organizer creates bills under their group.
9. For a locally paid recurring bill, start the next cycle and collect fresh approvals.

**Both people must update to build 2.** New pricing uses `GroupPayBillV2` so old builds cannot approve a total without its tips/fee. Existing bills retain their original pricing and recovery keys. Leader cards previously embedded in legacy shared records are moved into unshared sibling records when the updated leader app fetches them.

Development schema is created by the first successful device write. Before TestFlight/App Store builds, deploy `GroupPayBill`, `GroupPayBillV2`, `GroupPayGroup`, `GroupPayFriend`, and `GroupPayPrivateCard` (each `payload: Bytes`, `updatedBy: String`) to Production in CloudKit Console and validate production shares/subscriptions. All participants must use builds targeting the same CloudKit environment.

## Notification behavior

Private/shared CloudKit database subscriptions are repaired when connecting or accepting a share. They deliver background change pushes. When iOS wakes the app, it fetches changes and posts an authorized per-bill banner with the recipient’s amount and a link to that bill. Card-ready banners go to the whole group and never include card digits. The app also refreshes every 30 seconds while active, with overlapping refreshes suppressed. iOS may defer/coalesce delivery; force-quitting, disabling Background App Refresh, or network/power restrictions can prevent delivery. Notifications are not guaranteed immediate alerts. Opening the app always reconciles with CloudKit. Weekly/monthly due reminders are scheduled locally for the leader after notification permission is granted.

## Marqeta sandbox on this Mac

1. Create a sandbox in your [Marqeta developer account](https://app.marqeta.com/). Wait for its API credentials to become available.
2. Run `python3 sandbox_backend/setup.py --credentials` from this repository. Enter the sandbox URL, application token, and admin access token in the local terminal. Token entry is hidden; `.env` is private and excluded from Git.
3. Run `python3 sandbox_backend/server.py` and leave it running.
4. Build and install the Debug app in the simulator with normal Xcode signing enabled (do not set `CODE_SIGNING_ALLOWED=NO`; the simulator needs its generated Keychain entitlements). Run `python3 sandbox_backend/configure_simulator.py --device <simulator-UDID>` to save its local connection token without copying secrets into chat. With exactly one running simulator, omit `--device`.
5. In the Debug build of Group Pay, open **Profile → Advanced settings → Card connection → Save & check connection**. Choose **Create $10 test card**. This uses explicitly fictional participants, so it works without iCloud in the simulator. Retries recover the same request. Only the last four digits and initial test funding are shown.

For a shared bill, sandbox mode replaces the leader's final demo-card confirmation with backend issuance. The bill locks while issuance is pending; **Resume card creation** retrieves the original result after an interruption. Provider cards cannot use the local simulated-payment button. Merchant transactions, live balance reconciliation, and completing recurring cycles with Marqeta cards are not implemented yet.

The Mac service listens only at `127.0.0.1:8787`. Physical devices use the hosted service below; they cannot access the Mac through their own localhost address. See [backend setup, API contract, and recovery details](sandbox_backend/README.md).

## Hosted team beta

The Cloud Run service lives in the dedicated Google Cloud project `group-pay-itsfloppyhat`, in `us-central1`. Its public HTTPS address is bundled as `GroupPayCardServiceURL`; no credentials are included in the app. Each tester opens **Profile → Team access**, enters the private Group Pay client code supplied by the organizer, and taps **Join**. iCloud invitation and approval steps remain the same.

The organizer can display only that team code locally using `python3 sandbox_backend/setup.py --show-client-token`. Share it privately with trusted testers; never share either Marqeta token. Simulator pairing can use `python3 sandbox_backend/configure_simulator.py --hosted` followed by **Profile → Team access → Check connection**.

The service scales to zero when idle and uses one small instance at most. Firestore retains issuance records and protects against duplicate funding across restarts and overlapping instances. Secret Manager holds the provider keys. New hosted cards are limited to $500 in test funds and the team has a combined limit of 100 new issuance intents per UTC day; exact retries do not consume another allowance. Existing migrated intents remain recoverable.

A $5 monthly Cloud Run spend cap and $5 project-wide budget alerts are configured. The cap uses estimated gross Cloud Run charges, may have enforcement delay, and does not cap database, storage, builds, or other services. Light beta use is expected to cost roughly $0–$5/month, depending on traffic and free-tier availability. See [cloud setup, recovery, limits, and operating details](sandbox_backend/cloud/README.md).

## Simulation boundary

**No real money moves.** Local simulation calls no Marqeta endpoint. With sandbox mode enabled, the backend calls only Marqeta's sandbox API and uses test funds. The app does not receive full card numbers or security codes and cannot pay a real merchant or add a card to Apple Wallet. There is no bank linking, real balance collection, KYC, settlement, refund, or withdrawal flow. Sandbox balances shown in Group Pay are snapshots at issuance, not live balances after external activity.

CloudKit enforces invitation access, but invited users have read/write access to the shared bill. Leader roles, portion claims, and payment rules are enforced by this app, not a trusted financial server. A recipient can claim an unclaimed name; confirm the intended people when inviting. Both backends check exact amounts and approvals but trust the app's identity assertions. The hosted shared access code is for a small trusted beta group and does not independently authenticate individual iCloud participants. Do not use this architecture for real funds. Production requires independently authenticated participants, server-enforced approval revisions and authorization, and reconciliation of provider callbacks.

Published receipt items, tax, and subtotal allocations are immutable. Each member can change their own tip and reapprove while the bill is collecting approvals; tips lock once issuance starts. To change a receipt or group membership, create a new split. The leader can revoke sharing using Apple's sharing controls. Recurring cycles require the leader to start them; CloudKit does not run a scheduled payment job. OCR is conservative English/USD and excludes discounts from line items; the review step must correct totals before sharing.

## Verification

The following are verified locally:

- Signed Debug simulator and Release device builds with the iOS 27.2 SDK, iOS 26.0 minimum deployment target, and iCloud/push entitlements. Both built apps declare minimum OS version 26.0. Hosted Team access was verified in the simulator using its saved Keychain code.
- 6,645 domain checks: cent conservation, proportional allocation, malformed amounts, identity/approval gates, sandbox reservation/attachment, duplicate payment prevention, recurring dates and resets, and backward-compatible JSON persistence.
- 61 offline backend tests: local and hosted authentication, exact amounts, masked responses, deployment source/secret isolation, cross-process SQLite recovery, concurrent Firestore transaction behavior, quotas, legacy migration, timeout recovery, and prevention of duplicate funding. These use a mock provider.
- Live Marqeta sandbox tests on November 14, 2026: local simulator issuance and hosted HTTPS issuance both created active cards with $10.00 in test funding. The cloud card’s available GPA balance was independently verified at $10.00; exact replay and durable lookup returned the same card. The migrated local card also remained retrievable.
- 23 saved-group, notification-copy, and shared-card-redaction checks; 484 Swift-to-Python pricing fixtures using the actual app request encoder.
- Hosted pricing-v2 test: $10 food + $0.80 tax + $2.50 in personal tips funded exactly $13.30 on an active card; the separate fee stayed $0.11, for $13.41 total contributions. Provider GPA balance and exact retry were verified; changing the approved tip snapshot returned a conflict, and charging the fee on tips was rejected.
- Four independent clients against real Firestore passed reservation, quota, replay, conflict, completion, and owner-fencing checks. Only isolated test records were created and removed.
- Receipt parser fixtures and Swift 6 type-check.
- Simulator UI flow: updated five-tab navigation, personal tip preview (20% to25%, amount updates), receipt/fee breakdown, dinner receipt sample, participant entry, and new pricing review. The two-person sample showed $139.95 contributions, $21.60 tips, $1.17 fee, and portions of $69.98/$69.97. No simulator approvals or invitations were sent.

Run domain checks:

```sh
xcrun swiftc -swift-version 6 GroupPay/Models.swift Tests/DomainChecks.swift -o /tmp/group-pay-domain-checks
/tmp/group-pay-domain-checks
```

Build for a device:

```sh
xcodebuild -project GroupPay.xcodeproj -scheme GroupPay -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

The iOS 26.5 and 27.2 runtimes are installed, with Group Pay Preview and iPhone 18 Pro Max simulators configured. All builds use the same iOS 26.0 minimum deployment target. Simulator builds intentionally disable CloudKit connection and offer read-only preview and draft exploration. Add `--preview` as a launch argument to open the sample dashboard immediately.

**Next physical-device checks:** the new reusable-group invitation and inherited bills, leader-private card migration, and updated notification delivery across two accounts. The earlier one-off bill workflow was confirmed working by the user. Production CloudKit schema deployment and TestFlight distribution remain separate steps.

After changing sandbox credentials or backend hosting, rerun the $10 connection test before testing shared bills.
