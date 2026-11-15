# Group Pay development guide

[← Project overview](../README.md)

Detailed setup, operational notes, and historical validation for the prototype. Run commands from the repository root unless a step explicitly changes directories. Named devices, cloud resources, and signing settings below describe the original development environment; use your own resources when setting up a separate deployment.

A native SwiftUI group-payment prototype. Scan a receipt, split the total, invite your group, collect approvals, and create a virtual card using local simulation or Marqeta's sandbox. All funds are simulated.

## What works

- Native multipage document camera and photo import, using on-device Vision text recognition. Restaurant and grocery sample receipts and manual entry are included.
- Editable receipt review, tax, OCR total reconciliation, and exact integer-cent calculations in USD.
- Scanned receipts suggest a category conservatively: explicit dining context can select Dining, while retail order summaries and unknown scans select Other with a 0% starting tip. Category remains editable before sharing; manually selecting Dining still defaults to 20%.
- Equal splits, custom subtotal amounts, or item assignment (including shared items). Tax follows the subtotal allocation. Each person chooses their own tip with a slider or exact amount; dining defaults to 20% of their food subtotal, other categories to 0%.
- A 1% Group Pay fee on food plus tax, excluding tips. Total contributions include the fee; the merchant card receives only food, tax, and tips. Fees and contributions are simulated accounting, not real collections.
- Add friends directly from People before creating any bill. A private friend invitation saves both people after the recipient confirms. Reusable groups share future bills after a separate, one-time group invitation.
- Separate iCloud identities and invite-only CloudKit sharing. Participants accept an Apple sharing invitation on their own device and claim their named portion.
- Individual approvals; only the leader can confirm once everyone has joined and approved.
- Personal guest webpages for people without the app: review the portion, select a tip, and approve without an account. The organizer shares the link from the person’s row and imports the approval on refresh. Requires the updated hosted backend; all contributions remain simulated.
- The leader can cancel a split before card creation starts: open its details, tap **Cancel split**, and confirm. Cancellation syncs to invitees, removes the split from active bills and approval requests, and preserves a collapsed **Cancelled splits** record. Cancelled splits cannot be approved, issued, paid, or restarted; earlier recurring payments remain in history. Issuing, funded, and paid bills cannot be cancelled through this action.
- Only the leader sees card details. Shared bills contain status and amounts; card metadata is stored separately in the leader’s private iCloud records. Everyone receives card-ready status updates. Local mock cards support simulated payment and history.
- Optional Marqeta sandbox issuance through a Python backend on this Mac or Cloud Run: creates an active virtual card and funds its isolated test account for the receipt plus personal tips, excluding the fee. Provider credentials stay on the backend; the app stores only its team access code in Keychain. Interrupted requests resume the same card and funding order.
- Weekly/monthly schedules. The leader starts each cycle; participant approvals reset and the prior card is discarded. No automatic funding. Authorized local reminders prompt the leader at the next due date.
- Real CloudKit background-push registration plus local update banners, foreground refresh, and an inbox of pending approvals.
- Private data stays in the owner's private CloudKit database and invitees' shared databases. No public database or public-read share links.
- Cream and terracotta Home, Inbox, Cards, People, Profile, creation, receipt, and bill-detail screens with Caprasimo headings and Figtree body text with native artwork, scalable typography, and concise customer-facing messages. An explicitly read-only preview is available without iCloud. Team access is available in Profile; additional connection controls live under Advanced settings in Debug builds.

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
7. You can add friends **before step 4**, without a bill: open **People → Add friend**, enter your name and your friend’s name, and create/share the private invitation. Your friend opens it, then confirms **Add friend** in People. Both accounts save the connection on sync. Pending invitations can be shared again or cancelled. Alternatively, save someone under **People you’ve split with** after an earlier bill. Create a named group, select that friend, and use **Invite or manage group** to send the group’s one-time invitation. Adding a friend does not grant access to any bills or groups.
8. After the friend accepts the group invitation, start another split and choose the **Saved group**. All selected members are already assigned to their iCloud identities and future bills inherit group access. No new text/link is needed for each bill. Group membership is fixed for this version; create another group for a different set of people. Only the organizer creates bills under their group.
9. For a locally paid recurring bill, start the next cycle and collect fresh approvals.

**Both people need build 3 or later for standalone friend invitations.** Build 4 fixes estimated-tax labels and subtotal recovery in scanned order summaries. New pricing uses `GroupPayBillV2` so old builds cannot approve a total without its tips/fee. Existing bills retain their original pricing and recovery keys. Leader cards previously embedded in legacy shared records are moved into unshared sibling records when the updated leader app fetches them.

Development schema is created by the first successful device write. Before TestFlight/App Store builds, deploy `GroupPayBill`, `GroupPayBillV2`, `GroupPayGroup`, `GroupPayFriend`, `GroupPayFriendInvitation`, `GroupPayFriendReceipt`, and `GroupPayPrivateCard` (each `payload: Bytes`, `updatedBy: String`) to Production in CloudKit Console and validate production shares/subscriptions. All participants must use builds targeting the same CloudKit environment. Friend completion receipts remain private and prevent a previously accepted invitation from restoring a removed friend on refresh or another device.

## Guest webpages (no app required)

After deploying the updated cloud backend and installing this app build, create a new split with a named, unclaimed participant. In **Split details → Your group → Invite your group**, choose **Send web link to [name]**, then **Share [name]’s web link**. You can also tap a participant’s row to open their invitation options. The separate **Send app invitation** button opens iCloud sharing; app invitees choose their own portion after joining. Web links are assigned to the selected name before the share sheet opens, and the shared message names that person. Previously sent app invitations do not prevent creating a web link while the person’s portion remains unclaimed. **Profile → Team access** must be connected to the HTTPS service. A capability check prevents reserving the portion when an older backend does not support guest pages.

The mobile page shows only that person’s bill title, name, subtotal, tax, fee, and tip. They can select a percentage or enter an exact tip, then approve their simulated total. No download, iCloud account, team code, card details, or real payment is required. Tip choices range up to 100% of their subtotal (or their original tip, if higher). Final approvals cannot be edited through the link; retrying the same approval is safe.

Keep the organizer’s app open or pull to refresh to import approvals into iCloud; the app also checks pending guest approvals before creating the card. Browser approvals do not directly push CloudKit notifications. The existing pricing rules still validate the complete bill on import, including the $100,000 total ceiling. Guest identities are excluded from saved-friend suggestions.

Links expire after seven days. Send each link only to its named recipient: possession authorizes approval of that single portion. **Remove link** closes it and clears its approval so you can send a replacement or let the person join in the app. Cancelling a split closes its links before saving the cancellation. A new recurring cycle clears guest reservations and requires new links and approvals; a previous final approval cannot approve another cycle. Removing links and cancelling guest splits require the original team connection. If closing succeeds but the iCloud update fails, retry the operation to finish.

Guest invitation snapshots and final approvals persist transactionally in Firestore, separate from issuance records. Tokens use a separate HMAC domain derived from the team secret and are sent in a URL fragment, then a `Guest` authorization header; the team secret is never sent to a guest. Rotating the team secret invalidates old links; the organizer can share the same invitation again to obtain a token under the new secret. Only the portion-specific routes accept same-origin browser requests. The existing team/card endpoints continue to reject browser origins. No real collection, bank linking, or payment processor checkout was added.

Verification:

```sh
xcrun swiftc -swift-version 6 GroupPay/Models.swift Tests/GuestChecks.swift -o /tmp/group-pay-guest-checks
/tmp/group-pay-guest-checks
cd sandbox_backend
python -m unittest test_guest test_cloud_app test_storage
node --test test_guest_web.js
```

## Notification behavior

Build 7 also recovers when CloudKit reports a missing subscription collection, and notification setup failures no longer claim that bill loading failed. On November 15, 2026, a missing development `GroupPayGroup` record type was initialized using an isolated temporary zone, which was then removed. Both private and shared subscription lists became readable on the Air across a restart. The corrected app was installed on the Air and Pro Max; the Pro Max opened without the warning. The Air disconnected after installation of the final build, before its final launch check. This verifies setup recovery, not end-to-end delivery of a new remote bill alert.

Build 5 repairs private/shared CloudKit subscriptions when connecting or accepting a share. Bill records use visible server notifications so a closed app no longer depends on a silent push waking it before it can show an alert. Background alerts use generic bill-update copy and open Inbox; the exact amount appears in the bill. Friend/group synchronization remains silent. Foreground refresh and push handling share a serialized notification ledger, produce the recipient’s amount/status notice, and acknowledge a revision only after successful enqueue. Silent background synchronization cannot consume a pending bill alert or create a second local copy of the server banner. Card notifications never include card digits.

The app refreshes every 30 seconds while active, with overlapping refreshes suppressed. Inbox also has a refresh button and shows sync failures instead of claiming everything is caught up. **Profile → Notifications → Send test notification** checks local alert presentation only; it does not test CloudKit delivery. With iPhone Mirroring, also check the app’s **Show on Mac** setting and Mac notification controls. iOS can still defer/coalesce notifications, and Focus, user settings, or network restrictions can affect delivery. Weekly/monthly due reminders are scheduled locally for the leader after notification permission is granted.

## Marqeta sandbox on this Mac

1. Create a sandbox in your [Marqeta developer account](https://app.marqeta.com/). Wait for its API credentials to become available.
2. Run `python3 sandbox_backend/setup.py --credentials` from this repository. Enter the sandbox URL, application token, and admin access token in the local terminal. Token entry is hidden; `.env` is private and excluded from Git.
3. Run `python3 sandbox_backend/server.py` and leave it running.
4. Build and install the Debug app in the simulator with normal Xcode signing enabled (do not set `CODE_SIGNING_ALLOWED=NO`; the simulator needs its generated Keychain entitlements). Run `python3 sandbox_backend/configure_simulator.py --device <simulator-UDID>` to save its local connection token without copying secrets into chat. With exactly one running simulator, omit `--device`.
5. In the Debug build of Group Pay, open **Profile → Advanced settings → Card connection → Save & check connection**. Choose **Create $10 test card**. This uses explicitly fictional participants, so it works without iCloud in the simulator. Retries recover the same request. Only the last four digits and initial test funding are shown.

For a shared bill, sandbox mode replaces the leader's final demo-card confirmation with backend issuance. The bill locks while issuance is pending; **Resume card creation** retrieves the original result after an interruption. Provider cards cannot use the local simulated-payment button. Merchant transactions, live balance reconciliation, and completing recurring cycles with Marqeta cards are not implemented yet.

The Mac service listens only at `127.0.0.1:8787`. Physical devices use the hosted service below; they cannot access the Mac through their own localhost address. See [backend setup, API contract, and recovery details](../sandbox_backend/README.md).

## Hosted team beta

The Cloud Run service lives in the dedicated Google Cloud project `group-pay-itsfloppyhat`, in `us-central1`. Its public HTTPS address is bundled as `GroupPayCardServiceURL`; no credentials are included in the app. Each tester opens **Profile → Team access**, enters the private Group Pay client code supplied by the organizer, and taps **Join**. iCloud invitation and approval steps remain the same.

The organizer can display only that team code locally using `python3 sandbox_backend/setup.py --show-client-token`. Share it privately with trusted testers; never share either Marqeta token. Simulator pairing can use `python3 sandbox_backend/configure_simulator.py --hosted` followed by **Profile → Team access → Check connection**.

The service scales to zero when idle and uses one small instance at most. Firestore retains issuance records and protects against duplicate funding across restarts and overlapping instances. Secret Manager holds the provider keys. New hosted cards are limited to $500 in test funds and the team has a combined limit of 100 new issuance intents per UTC day; exact retries do not consume another allowance. Existing migrated intents remain recoverable.

A $5 monthly Cloud Run spend cap and $5 project-wide budget alerts are configured. The cap uses estimated gross Cloud Run charges, may have enforcement delay, and does not cap database, storage, builds, or other services. Light beta use is expected to cost roughly $0–$5/month, depending on traffic and free-tier availability. See [cloud setup, recovery, limits, and operating details](../sandbox_backend/cloud/README.md).

## Simulation boundary

**No real money moves.** Local simulation calls no Marqeta endpoint. With sandbox mode enabled, the backend calls only Marqeta's sandbox API and uses test funds. The app does not receive full card numbers or security codes and cannot pay a real merchant or add a card to Apple Wallet. There is no bank linking, real balance collection, KYC, settlement, refund, or withdrawal flow. Sandbox balances shown in Group Pay are snapshots at issuance, not live balances after external activity.

CloudKit enforces invitation access, but invited users have read/write access to the shared bill. Leader roles, portion claims, and payment rules are enforced by this app, not a trusted financial server. A recipient can claim an unclaimed name; confirm the intended people when inviting. Both backends check exact amounts and approvals but trust the app's identity assertions. The hosted shared access code is for a small trusted beta group and does not independently authenticate individual iCloud participants. Do not use this architecture for real funds. Production requires independently authenticated participants, server-enforced approval revisions and authorization, and reconciliation of provider callbacks.

Published receipt items, tax, and subtotal allocations are immutable. Each member can change their own tip and reapprove while the bill is collecting approvals; tips lock once issuance starts. To change a receipt or group membership, create a new split. The leader can revoke sharing using Apple's sharing controls. Recurring cycles require the leader to start them; CloudKit does not run a scheduled payment job. OCR is conservative English/USD and excludes discounts from line items; the review step must correct totals before sharing.

Cancelled shared bills require build 6 or newer on every participant’s device. Earlier builds do not understand the new cancelled status and must be updated before syncing those records.

## Verification history

These entries record local verification performed during development; they are not a continuously passing CI status. Re-run the relevant checks after changing code:

- Signed Debug simulator and Release device builds with the iOS 27.2 SDK, iOS 26.0 minimum deployment target, and iCloud/push entitlements. Both built apps declare minimum OS version 26.0. Hosted Team access was verified in the simulator using its saved Keychain code.
- 6,682 domain checks: cent conservation, proportional allocation, malformed amounts, identity/approval/cancellation gates, sandbox reservation/attachment, duplicate payment prevention, recurring dates and resets, and backward-compatible JSON persistence. Cancellation checks cover owner-only access, terminal state, reservation/card guards, idempotence, invalid-receipt cleanup, and preserving amounts/history.
- 61 offline backend tests: local and hosted authentication, exact amounts, masked responses, deployment source/secret isolation, cross-process SQLite recovery, concurrent Firestore transaction behavior, quotas, legacy migration, timeout recovery, and prevention of duplicate funding. These use a mock provider.
- Live Marqeta sandbox tests on November 14, 2026: local simulator issuance and hosted HTTPS issuance both created active cards with $10.00 in test funding. The cloud card’s available GPA balance was independently verified at $10.00; exact replay and durable lookup returned the same card. The migrated local card also remained retrievable.
- 56 friend-invitation, saved-group, notification-copy, and shared-card-redaction checks, including cancellation notices and recipient filtering, creating a group before any bill, retrying acceptance, rejecting another recipient, and preserving invitations through persistence; 484 Swift-to-Python pricing fixtures using the actual app request encoder.
- 34 notification delivery regression checks cover duplicate suppression, refresh/push ordering, stale snapshots, enqueue retries, own edits, account isolation, first-sync/upgrade behavior, visible bill channels, and silent background synchronization.
- Build 5 was installed on the connected Air and iPhone. The Air successfully connected/refreshed, and Group Pay alerts were enabled in both iPhone settings and Mac mirroring settings. A local test was enqueued without an app error, but visible presentation and a fresh remote bill alert are not yet verified. The Air still showed only the two older paid bills; the pending split was on the sending phone.
- Hosted pricing-v2 test: $10 food + $0.80 tax + $2.50 in personal tips funded exactly $13.30 on an active card; the separate fee stayed $0.11, for $13.41 total contributions. Provider GPA balance and exact retry were verified; changing the approved tip snapshot returned a conflict, and charging the fee on tips was rejected.
- Four independent clients against real Firestore passed reservation, quota, replay, conflict, completion, and owner-fencing checks. Only isolated test records were created and removed.
- 54 receipt checks, including estimated sales tax, subtotal fallback for order summaries, savings/rewards exclusions, preserved mismatch review, restaurant/grocery itemization, printed gratuity, and conservative category hints that avoid dining tips on retail purchases. Four native Vision checks passed on the locally supplied retail screenshot: $699.99 subtotal + $45.50 tax = $745.49, categorized as Other. The screenshot is not stored in this repository.
- Simulator UI flow: updated five-tab navigation, personal tip preview (20% to25%, amount updates), receipt/fee breakdown, dinner receipt sample, participant entry, and new pricing review. The two-person sample showed $139.95 contributions, $21.60 tips, $1.17 fee, and portions of $69.98/$69.97. No simulator approvals or invitations were sent.

Run domain checks:

```sh
xcrun swiftc -swift-version 6 GroupPay/Models.swift Tests/DomainChecks.swift -o /tmp/group-pay-domain-checks
/tmp/group-pay-domain-checks
```

Run receipt checks on macOS using the same parser and Vision recognizer as the app:

```sh
xcrun swiftc -swift-version 6 GroupPay/ReceiptScanner.swift Tests/ReceiptChecks.swift -o /tmp/group-pay-receipt-checks
/tmp/group-pay-receipt-checks
```

Build for a device:

```sh
xcodebuild -project GroupPay.xcodeproj -scheme GroupPay -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

The iOS 26.5 and 27.2 runtimes are installed, with Group Pay Preview and iPhone 18 Pro Max simulators configured. All builds use the same iOS 26.0 minimum deployment target. Simulator builds disable CloudKit connection. Add `--preview` as a launch argument to open the read-only sample dashboard immediately.

Debug simulator builds also offer **Profile → Roommate recording demo**. Start **Matthew · Leader** first, then **Dylan · Saved friend** on a second simulator. This opt-in, temporary session uses the normal bill calculations and approval/card state machine with an in-memory server on `127.0.0.1:8847`. It bypasses iCloud and provider issuance, so **Make a test payment** uses simulated money. The banner identifies this mode. It is not compiled into device or Release builds, and closing the leader app loses the session.

For the browser-only third phone, create Curtis's named web link in the leader's invitation screen, then open `http://127.0.0.1:8847/demo/inbox` in that phone's Safari. This explicitly labeled simulator inbox lists only invitations generated through the app, and opens the same guest webpage used by the hosted service. It simulates delivery; it does not send a real message. Guest approval returns to the leader on refresh. This demo does not validate real iCloud sharing, message delivery, or a Marqeta transaction.

For a receipt-photo recording, import the original image into the leader simulator's Photos library, then use **Start a split → Choose a receipt photo** and review the OCR result before continuing. For the Samsung TV example, the sale price is $299.99, tax $22.50, card amount $322.49, fee $3.22, and total contributions $325.71. With three equal participants and no tips, the portions are $108.58, $108.57, and $108.56. Stop and save each recording before closing Device Hub.

**Next physical-device checks:** standalone friend invitation acceptance and mutual saved-friend sync across two accounts, the reusable-group invitation and inherited bills, leader-private card migration, and updated notification delivery. The earlier one-off bill workflow was confirmed working by the user. Production CloudKit schema deployment and TestFlight distribution remain separate steps.

After changing sandbox credentials or backend hosting, rerun the $10 connection test before testing shared bills.
