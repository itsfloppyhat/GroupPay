import Foundation

@main
struct NotificationChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let notice = BillUpdateNotice(title: "Dinner · Your part is $20.20", body: "Review your portion before approving.")
        let first = BillNotificationChange(key: "owner/zone/bill", fingerprint: "revision-1", modifiedAt: Date(timeIntervalSince1970: 100), authorID: "leader", notice: notice)
        var ledger = BillNotificationLedger(accountID: "guest")
        // First-install baseline is an explicit acknowledgement, not delivery.
        ledger.acknowledge(first, for: "guest")
        check(!ledger.shouldDeliver(first, to: "guest"), "Initial history is quiet")
        var changed = first
        changed.fingerprint = "revision-2"
        changed.modifiedAt = Date(timeIntervalSince1970: 200)
        check(ledger.shouldDeliver(changed, to: "guest"), "A remote edit after baseline alerts")
        check(ledger.shouldDeliver(changed, to: "guest"), "Merely planning or fetching does not consume an update")
        // A failed notification-center enqueue does not call acknowledge.
        check(ledger.shouldDeliver(changed, to: "guest"), "An enqueue failure remains retryable on foreground refresh")
        ledger.acknowledge(changed, for: "guest")
        check(!ledger.shouldDeliver(changed, to: "guest"), "Successful enqueue consumes this revision")
        check(!ledger.shouldDeliver(changed, to: "guest"), "Later push after foreground delivery does not duplicate it")

        var fromPush = changed
        fromPush.fingerprint = "revision-3"
        fromPush.modifiedAt = Date(timeIntervalSince1970: 300)
        check(ledger.shouldDeliver(fromPush, to: "guest"), "Next pushed revision alerts")
        ledger.acknowledge(fromPush, for: "guest")
        check(!ledger.shouldDeliver(fromPush, to: "guest"), "Foreground fetch after push does not duplicate it")
        check(!ledger.shouldDeliver(changed, to: "guest"), "Late older fetch cannot notify after a newer revision")
        ledger.acknowledge(changed, for: "guest")
        check(ledger.entries[first.key]?.fingerprint == "revision-3", "Stale acknowledgement cannot roll back a newer one")

        var own = fromPush
        own.fingerprint = "own-revision-4"
        own.modifiedAt = Date(timeIntervalSince1970: 400)
        own.authorID = "guest"
        check(!ledger.shouldDeliver(own, to: "guest"), "Own approvals and tip edits never produce self notifications")
        ledger.acknowledge(own, for: "guest")
        ledger.acknowledge(fromPush, for: "guest")
        check(ledger.entries[first.key]?.fingerprint == own.fingerprint, "An in-flight enqueue cannot overwrite a newer local edit")
        check(!ledger.shouldDeliver(fromPush, to: "guest"), "Old remote state is suppressed after own edit")

        var cardReady = own
        cardReady.fingerprint = "card-ready-5"
        cardReady.modifiedAt = Date(timeIntervalSince1970: 500)
        cardReady.authorID = "leader"
        cardReady.notice = BillUpdateNotice(title: "Dinner · Card ready", body: "Only the leader can view and use it.")
        check(ledger.shouldDeliver(cardReady, to: "guest"), "Later card-ready change still alerts after own approval")

        var irrelevant = cardReady
        irrelevant.notice = nil
        check(!ledger.shouldDeliver(irrelevant, to: "guest"), "Unrelated or non-actionable record changes never alert")
        check(!ledger.shouldDeliver(cardReady, to: "another-account"), "Another signed-in account cannot use this ledger")
        ledger.acknowledge(cardReady, for: "another-account")
        check(ledger.entries[first.key]?.fingerprint == own.fingerprint, "Wrong-account acknowledgement does not mutate state")

        var migrated = BillNotificationLedger(accountID: "guest", legacyFingerprints: [first.key: first.fingerprint])
        check(!migrated.shouldDeliver(first, to: "guest"), "Upgrade does not replay already loaded historical bills")
        check(migrated.shouldDeliver(changed, to: "guest"), "Upgrade preserves changed bills since the last legacy fetch")
        var newBill = first
        newBill.key = "other-owner/zone/new-bill"
        check(migrated.shouldDeliver(newBill, to: "guest"), "A newly accepted or inherited bill after baseline alerts")
        migrated.acknowledge(newBill, for: "guest")
        let persisted = try JSONDecoder().decode(BillNotificationLedger.self, from: JSONEncoder().encode(migrated))
        check(!persisted.shouldDeliver(newBill, to: "guest"), "Delivered revisions survive app restarts")
        check(persisted.shouldDeliver(changed, to: "guest"), "Persisting one bill never consumes a different pending change")

        var noPermission = BillNotificationLedger(accountID: "guest")
        noPermission.acknowledge(newBill, for: "guest")
        check(!noPermission.shouldDeliver(newBill, to: "guest"), "Enabling notifications does not replay activity while opted out")

        let channels = CloudNotificationChannel.all
        let billTypes: Set<String> = ["GroupPayBill", "GroupPayBillV2"]
        check(Set(channels.map(\.recordType)).count == channels.count, "No record type receives both a silent and visible subscription")
        check(Set(channels.filter(\.isVisible).map(\.recordType)) == billTypes,
              "Both bill versions have an OS-visible fallback; friends and groups stay silent")
        let identifiers = ["private", "shared"].flatMap { scope in channels.map { $0.subscriptionID(scope: scope) } }
        check(Set(identifiers).count == channels.count * 2, "Private and shared notification channels have distinct identities")
        check(!CloudNotificationChannel.alertBody.contains("$"), "Generic background alerts do not invent a recipient amount")
        var backgroundDelivery = BillNotificationLedger(accountID: "guest")
        backgroundDelivery.acknowledge(newBill, for: "guest")
        check(!backgroundDelivery.shouldDeliver(newBill, to: "guest"), "An OS-presented background alert is not repeated by foreground sync")
        let foreground = BillNotificationDeliveryMode.resolve(isForeground: true, hasVisibleAlert: true)
        check(foreground.shouldEnqueueLocal && foreground.shouldAcknowledgeChanges, "Foreground visible pushes use the detailed local alert")
        let backgroundVisible = BillNotificationDeliveryMode.resolve(isForeground: false, hasVisibleAlert: true)
        check(!backgroundVisible.shouldEnqueueLocal && backgroundVisible.shouldAcknowledgeChanges,
              "Background visible pushes acknowledge the OS alert without a second local copy")
        let backgroundSilent = BillNotificationDeliveryMode.resolve(isForeground: false, hasVisibleAlert: false)
        check(!backgroundSilent.shouldEnqueueLocal && !backgroundSilent.shouldAcknowledgeChanges,
              "Unrelated background silent pushes neither deliver nor consume bill notices")
        var deferred = BillNotificationLedger(accountID: "guest")
        if backgroundSilent.shouldAcknowledgeChanges { deferred.acknowledge(newBill, for: "guest") }
        check(deferred.shouldDeliver(newBill, to: "guest"), "A silent push arriving first preserves the bill for its visible push or foreground refresh")
        let opened = BillNotificationDeliveryMode.resolve(isForeground: true, hasVisibleAlert: false, openedNotification: true)
        check(!opened.shouldEnqueueLocal && opened.shouldAcknowledgeChanges,
              "Opening a generic OS alert does not create another local alert on cold launch")
        if opened.shouldAcknowledgeChanges { deferred.acknowledge(newBill, for: "guest") }
        check(!deferred.shouldDeliver(newBill, to: "guest"), "Post-tap inbox refresh keeps the opened update acknowledged")
        print("Passed \(checks) notification delivery checks.")
    }
}
