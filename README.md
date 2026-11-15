# Group Pay

A native SwiftUI group-payment prototype. Scan a receipt, split the total, invite your group, collect approvals, and create one simulated virtual card for the bill.

## What works

- Native multipage document camera and photo import, using on-device Vision text recognition. Restaurant and grocery sample receipts and manual entry are included.
- Editable receipt review, tax and tip, OCR total reconciliation, and exact integer-cent calculations in USD.
- Equal splits, custom final amounts, or item assignment (including shared items). Item splits allocate tax and tip proportionally and preserve the total to the cent.
- Separate iCloud identities and invite-only CloudKit sharing. Participants accept an Apple sharing invitation on their own device and claim their named portion.
- Individual approvals; only the leader can confirm once everyone has joined and approved.
- Simulated card creation for exactly the total, simulated payment, and payment history. Repeated confirmation/payment is rejected.
- Weekly/monthly schedules. The leader starts each cycle; participant approvals reset and the prior card is discarded. No automatic funding. Authorized local reminders prompt the leader at the next due date.
- Real CloudKit background-push registration plus local update banners, foreground refresh, and an inbox of pending approvals.
- Private data stays in the owner's private CloudKit database and invitees' shared databases. No public database or public-read share links.
- Dark, mint-accented Overview, Inbox, Cards, Profile, creation, receipt, and bill-detail screens. An explicitly read-only preview is available without iCloud.

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

## Simulation boundary

**No real money moves and no Marqeta endpoint is called.** The card has a demo identifier and last four digits, not usable payment credentials. It cannot pay a merchant or be added to Apple Wallet. There is no bank linking, real balance collection, funding, KYC, settlement, refund, or withdrawal flow.

CloudKit enforces invitation access, but invited users have read/write access to the shared bill. Leader roles, portion claims, and payment rules are enforced by this app, not a trusted financial server. A recipient can claim an unclaimed name; confirm the intended people when inviting. Do not use this architecture for real funds. A production Marqeta integration needs server-enforced participant authorization, immutable approval revisions, idempotent funding/issuing operations, secrets stored only on the backend, and reconciliation of provider callbacks.

Published receipt/participant amounts are immutable in this prototype. To change an amount, create a new split. The leader can revoke sharing using Apple's sharing controls. Recurring cycles require the leader to start them; CloudKit does not run a scheduled payment job. OCR is conservative English/USD and excludes discounts from line items; the review step must correct totals before sharing.

## Verification

The following are verified locally:

- Signed Debug device build with the iOS 27.2 SDK, iOS 27.2.1 deployment target, and iCloud/push entitlements.
- 2,548 domain checks: cent conservation, proportional allocation, malformed amounts, identity/approval gates, duplicate payment prevention, recurring dates and resets, and JSON persistence.
- Receipt parser fixtures and Swift 6 type-check.
- Simulator UI flow: overview, receipt sample/editing, people, invalid/valid custom allocations, and final review. A missing sheet environment discovered during this check was fixed and retested.

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
