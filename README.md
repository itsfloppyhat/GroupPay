# Group Pay

A native SwiftUI group-payment prototype. Scan a receipt, split the total, invite your group, collect approvals, and create a virtual card using local simulation or Marqeta's sandbox. All funds are simulated.

## What works

- Native multipage document camera and photo import, using on-device Vision text recognition. Restaurant and grocery sample receipts and manual entry are included.
- Editable receipt review, tax and tip, OCR total reconciliation, and exact integer-cent calculations in USD.
- Equal splits, custom final amounts, or item assignment (including shared items). Item splits allocate tax and tip proportionally and preserve the total to the cent.
- Separate iCloud identities and invite-only CloudKit sharing. Participants accept an Apple sharing invitation on their own device and claim their named portion.
- Individual approvals; only the leader can confirm once everyone has joined and approved.
- Simulated card creation for exactly the total, simulated payment, and payment history. Repeated confirmation/payment is rejected.
- Optional Marqeta sandbox issuance through a Python backend on this Mac or Cloud Run: creates an active virtual card and funds its isolated test account for the exact bill total. Provider credentials stay on the backend; the app stores only its team access code in Keychain. Interrupted requests resume the same card and funding order.
- Weekly/monthly schedules. The leader starts each cycle; participant approvals reset and the prior card is discarded. No automatic funding. Authorized local reminders prompt the leader at the next due date.
- Real CloudKit background-push registration plus local update banners, foreground refresh, and an inbox of pending approvals.
- Private data stays in the owner's private CloudKit database and invitees' shared databases. No public database or public-read share links.
- Evergreen and mint Home, Inbox, Cards, Profile, creation, receipt, and bill-detail screens with native artwork, scalable typography, and concise customer-facing messages. An explicitly read-only preview is available without iCloud. Team access is available in Profile; additional connection controls live under Advanced settings in Debug builds.

## Requirements and opening

Open `GroupPay.xcodeproj` and select the **GroupPay** scheme.

- Stable Xcode 27.2, iOS 27.2 SDK, Swift 6 language mode.
- Physical-device deployment target **iOS 27.2.1**; simulator builds target **iOS 27.2** to match Apple’s installed runtime. No beta APIs.
- Bundle ID: `com.itsfloppyhat.GroupPay`.
- Developer team: Matthew Lucas (`FYWW2S89N3`). Change this in `project.yml` when using a different team.
- CloudKit container: `iCloud.com.itsfloppyhat.GroupPay`.

The project is generated with XcodeGen. After changing `project.yml`, run `xcodegen generate`. The generated Xcode project, Info.plist, and scheme are committed source artifacts; no dependencies need downloading.

## Test on two real accounts

1. In Xcode, select your developer team and automatic signing. iCloud/CloudKit, Push Notifications, CloudKit sharing, and background remote notifications are already configured. A signed development build was verified with the Matthew Lucas team after accepting Apple's updated program agreement.
2. Install the same development build on two devices running iOS 27.2.1 or later, each signed into a different iCloud account. Devices must be registered for the development profile. Enable iCloud Drive and use the same CloudKit development environment on both devices.
3. Open Profile, enter your display name, connect iCloud, and enable notifications on both devices.
4. On the leader's device, start a split, scan/import a receipt or select a sample, review prices, add the other person's name, and choose a split method. Review and create the bill; this approves the leader's own portion.
5. From the bill details, choose **Invite people with iCloud**. Use Apple's sharing interface to send a private read/write invitation to that person's iCloud account. The app never sends messages automatically.
6. On the other device, accept the invitation, open Group Pay, choose the correct name, review the portion and receipt, and approve. Pull to refresh if an update has not arrived yet.
7. On the leader's device, confirm to create a demo card, then simulate paying the bill. Check that its balance becomes zero and history contains one payment.
8. For a recurring bill, start the next cycle from the paid bill. Check that all other members must approve again, and that payment advances the next due date.

Development schema is created by the first successful device write. Before TestFlight/App Store builds, deploy the `GroupPayBill` schema (`payload: Bytes`, `updatedBy: String`) to Production in CloudKit Console and validate production shares/subscriptions. All participants must use builds targeting the same CloudKit environment.

## Notification behavior

Shared CloudKit database subscriptions deliver background change pushes. When iOS wakes the app, it fetches the changes and posts an authorized local banner. iOS may defer/coalesce delivery; force-quitting, disabling Background App Refresh, or network/power restrictions can prevent delivery. Notifications are not guaranteed immediate alerts. Opening the app always reconciles with CloudKit. Weekly/monthly due reminders are scheduled locally for the leader after notification permission is granted.

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

Published receipt/participant amounts are immutable in this prototype. To change an amount, create a new split. The leader can revoke sharing using Apple's sharing controls. Recurring cycles require the leader to start them; CloudKit does not run a scheduled payment job. OCR is conservative English/USD and excludes discounts from line items; the review step must correct totals before sharing.

## Verification

The following are verified locally:

- Signed Debug simulator and Release device builds with the iOS 27.2 SDK, iOS 27.2.1 device deployment target, and iCloud/push entitlements. Hosted Team access was verified in the simulator using its saved Keychain code.
- 2,591 domain checks: cent conservation, proportional allocation, malformed amounts, identity/approval gates, sandbox reservation/attachment, duplicate payment prevention, recurring dates and resets, and backward-compatible JSON persistence.
- 52 offline backend tests: local and hosted authentication, exact amounts, masked responses, deployment source/secret isolation, cross-process SQLite recovery, concurrent Firestore transaction behavior, quotas, legacy migration, timeout recovery, and prevention of duplicate funding. These use a mock provider.
- Live Marqeta sandbox tests on November 14, 2026: local simulator issuance and hosted HTTPS issuance both created active cards with $10.00 in test funding. The cloud card’s available GPA balance was independently verified at $10.00; exact replay and durable lookup returned the same card. The migrated local card also remained retrievable.
- Four independent clients against real Firestore passed reservation, quota, replay, conflict, completion, and owner-fencing checks. Only isolated test records were created and removed.
- Receipt parser fixtures and Swift 6 type-check.
- Simulator UI flow: Home, Inbox, Cards, Profile, advanced connection access, bill details, receipt samples/editing, participant entry, and final review. Invalid/valid custom allocations were checked during the original build. The refreshed UI was inspected on the iPhone 18 Pro Max simulator.

Run domain checks:

```sh
xcrun swiftc -swift-version 6 GroupPay/Models.swift Tests/DomainChecks.swift -o /tmp/group-pay-domain-checks
/tmp/group-pay-domain-checks
```

Build for a device:

```sh
xcodebuild -project GroupPay.xcodeproj -scheme GroupPay -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

The iOS 27.2 runtime is installed, and an iPhone 18 Pro Max simulator is configured. The app builds for this simulator using the simulator-specific iOS 27.2 deployment setting; physical-device builds still require iOS 27.2.1. Initial UI checks used iOS 26.5 with a temporary command-line override before the newer runtime was available. Simulator builds intentionally disable CloudKit connection and offer read-only preview and draft exploration. Add `--preview` as a launch argument to open the sample dashboard immediately.

**Not yet verified:** camera capture on physical hardware; two-device invitation acceptance, approval sync, and notification delivery; production CloudKit schema deployment or TestFlight distribution. Those require the device/account setup above.

After changing sandbox credentials or backend hosting, rerun the $10 connection test before testing shared bills.
