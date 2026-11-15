import CloudKit
import CryptoKit
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let groupPayCloudChanged = Notification.Name("GroupPay.cloudChanged")
    static let groupPayCloudError = Notification.Name("GroupPay.cloudError")
    static let groupPayAccountChanged = Notification.Name("GroupPay.accountChanged")
    static let groupPayShareAccepted = Notification.Name("GroupPay.shareAccepted")
}

/// Each bill belongs to its creator's private database and is shared only with invited iCloud users.
/// CloudKit enforces share membership. Workflow roles are client-side in this simulated-money prototype.
@MainActor
final class CloudService: NSObject, UICloudSharingControllerDelegate {
    static let shared = CloudService()
    static let containerIdentifier = "iCloud.com.itsfloppyhat.GroupPay"

    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private let zoneID = CKRecordZone.ID(zoneName: "GroupPay", ownerName: CKCurrentUserDefaultName)
    private var locations: [UUID: Location] = [:]
    private var currentUserID: String?
    private var accountEpoch = 0
    private var recurringReminderTask: Task<Void, Never>?
    private static let recurringReminderPrefix = "group-pay-recurring-"
    private var zoneReady = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private struct Location {
        let recordID: CKRecord.ID
        let scope: CKDatabase.Scope
    }

    enum Failure: LocalizedError {
        case unavailable(String)
        case missingBill
        case invalidData
        case ownerOnly
        case accountChanged

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): message
            case .missingBill: "This bill is no longer available. Refresh your bills and check that its owner is still sharing it with you."
            case .invalidData: "This bill could not be read. Please update Group Pay on both devices and try again."
            case .ownerOnly: "Only the bill's owner can invite people or manage sharing."
            case .accountChanged: "Your iCloud account changed. Reconnect and review your bills before continuing."
            }
        }
    }

    func account() async throws -> (id: String, name: String) {
        // Simulator builds can run without CloudKit entitlements. Do not instantiate
        // CKContainer there: its entitlement assertion is an Objective-C exception.
        #if targetEnvironment(simulator)
        throw Failure.unavailable("To share bills and approve payments, open Group Pay on an iPhone or iPad. You can explore sample bills here.")
        #else
        do {
            guard !ProcessInfo.processInfo.arguments.contains("--preview") else {
                throw Failure.unavailable("You’re viewing sample bills. Reopen Group Pay to connect your iCloud account.")
            }
            let requestedEpoch = accountEpoch
            let status = try await container.accountStatus()
            try validateSession(requestedEpoch)
            guard status == .available else {
                if currentUserID != nil { invalidateAccount() }
                throw Failure.unavailable("Sign in to iCloud and turn on iCloud Drive in Settings, then try again.")
            }
            let id = try await container.userRecordID().recordName
            try validateSession(requestedEpoch)
            if let previousID = currentUserID, previousID != id {
                invalidateAccount()
                throw Failure.accountChanged
            }
            if currentUserID != id {
                locations.removeAll()
                zoneReady = false
            }
            currentUserID = id
            return (id, "You")
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated, currentUserID != nil {
                invalidateAccount()
            }
            throw readable(error)
        }
        #endif
    }

    func invalidateAccount() {
        accountEpoch += 1
        currentUserID = nil
        locations.removeAll()
        zoneReady = false
        // Serialize cleanup with any notification writes already in flight. A
        // subsequent account's scheduling waits for this cleanup to finish.
        let previous = recurringReminderTask
        previous?.cancel()
        recurringReminderTask = Task { @MainActor in
            await previous?.value
            await self.removeRecurringReminders()
        }
        NotificationCenter.default.post(name: .groupPayAccountChanged, object: nil)
    }

    private func validateSession(_ epoch: Int, expectedID: String? = nil) throws {
        guard accountEpoch == epoch, expectedID == nil || currentUserID == expectedID else {
            throw Failure.accountChanged
        }
    }

    func fetchBills() async throws -> [Bill] {
        do {
            _ = try await account()
            let epoch = accountEpoch
            let loaded = try await loadRecords()
            try validateSession(epoch)
            var result: [Bill] = []
            var nextLocations: [UUID: Location] = [:]
            for (record, scope) in loaded {
                let bill = try decode(record)
                result.append(bill)
                nextLocations[bill.id] = Location(recordID: record.recordID, scope: scope)
            }
            locations = nextLocations
            remember(loaded)
            return result
        } catch {
            throw readable(error)
        }
    }

    func create(_ bill: Bill) async throws -> Bill {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard bill.leaderID == identity else { throw Failure.accountChanged }
            try await ensureZone()
            try validateSession(epoch, expectedID: identity)
            let record = CKRecord(recordType: "GroupPayBill", recordID: CKRecord.ID(recordName: bill.id.uuidString, zoneID: zoneID))
            try encode(bill, into: record)
            let saved = try await save(record, in: container.privateCloudDatabase)
            try validateSession(epoch, expectedID: identity)
            locations[bill.id] = Location(recordID: saved.recordID, scope: .private)
            remember([(saved, .private)], replacing: false)
            return try decode(saved)
        } catch {
            throw readable(error)
        }
    }

    /// The caller validates cycle/revision and role inside the mutation against the latest server bill.
    /// A concurrent save fails visibly; it never silently replaces someone else's approval.
    func update(id: UUID, expectedAccountID: String, mutation: (inout Bill) throws -> Void) async throws -> Bill {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard identity == expectedAccountID else { throw Failure.accountChanged }
            if locations[id] == nil { _ = try await fetchBills() }
            try validateSession(epoch, expectedID: expectedAccountID)
            guard let location = locations[id] else { throw Failure.missingBill }
            let database = container.database(with: location.scope)
            let record = try await database.record(for: location.recordID)
            try validateSession(epoch, expectedID: expectedAccountID)
            var latest = try decode(record)
            try mutation(&latest)
            guard latest.id == id else { throw Failure.invalidData }
            try encode(latest, into: record)
            let saved = try await save(record, in: database)
            try validateSession(epoch, expectedID: expectedAccountID)
            remember([(saved, location.scope)], replacing: false)
            return try decode(saved)
        } catch {
            throw readable(error)
        }
    }

    func sharingController(for bill: Bill) async throws -> UICloudSharingController {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard bill.leaderID == identity else { throw Failure.ownerOnly }
            if locations[bill.id] == nil { _ = try await fetchBills() }
            try validateSession(epoch, expectedID: identity)
            guard let location = locations[bill.id] else { throw Failure.missingBill }
            guard location.scope == .private else { throw Failure.ownerOnly }
            let database = container.privateCloudDatabase
            let root = try await database.record(for: location.recordID)
            try validateSession(epoch, expectedID: identity)
            let share: CKShare
            if let reference = root.share {
                guard let existing = try await database.record(for: reference.recordID) as? CKShare else {
                    throw Failure.invalidData
                }
                share = existing
            } else {
                let newShare = CKShare(rootRecord: root)
                newShare.publicPermission = .none
                newShare[CKShare.SystemFieldKey.title] = "Group Pay bill" as CKRecordValue
                let results = try await database.modifyRecords(saving: [root, newShare], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                for result in results.saveResults.values { _ = try result.get() }
                guard let saved = try results.saveResults[newShare.recordID]?.get() as? CKShare else {
                    throw Failure.invalidData
                }
                share = saved
            }
            let controller = UICloudSharingController(share: share, container: container)
            try validateSession(epoch, expectedID: identity)
            controller.availablePermissions = [.allowPrivate, .allowReadWrite]
            controller.delegate = self
            return controller
        } catch {
            throw readable(error)
        }
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        do {
            guard metadata.containerIdentifier == Self.containerIdentifier else {
                throw Failure.unavailable("This invitation isn’t for Group Pay. Ask the bill’s owner for a new invitation.")
            }
            _ = try await account()
            let epoch = accountEpoch
            _ = try await container.accept(metadata)
            try validateSession(epoch)
            NotificationCenter.default.post(name: .groupPayShareAccepted, object: nil)
        } catch {
            throw readable(error)
        }
    }

    /// Register actual CloudKit pushes for both sides of a share, then request visible-banner permission.
    /// Background pushes may be delayed/coalesced by iOS; every foreground refresh also synchronizes.
    func configureNotifications() async throws -> Bool {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            let subscriptionsKey = "GroupPay.subscriptions.v1.\(identity)"
            if !UserDefaults.standard.bool(forKey: subscriptionsKey) {
                for (scope, suffix) in [(CKDatabase.Scope.private, "private"), (.shared, "shared")] {
                    let subscription = CKDatabaseSubscription(subscriptionID: "group-pay-\(suffix)-v1")
                    subscription.recordType = "GroupPayBill"
                    let notification = CKSubscription.NotificationInfo()
                    notification.shouldSendContentAvailable = true
                    subscription.notificationInfo = notification
                    _ = try await container.database(with: scope).save(subscription)
                    try validateSession(epoch, expectedID: identity)
                }
                UserDefaults.standard.set(true, forKey: subscriptionsKey)
            }
            UIApplication.shared.registerForRemoteNotifications()
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            throw readable(error)
        }
    }

    func receivedRemoteChange() async throws -> Bool {
        _ = try await account()
        let epoch = accountEpoch
        let previous = UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
        let records = try await loadRecords()
        try validateSession(epoch)
        let changes = records.filter { record, _ in
            let writer = record["updatedBy"] as? String
            return writer != currentUserID && previous[record.recordID.recordName] != fingerprint(record)
        }
        remember(records)
        NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
        if !changes.isEmpty && UIApplication.shared.applicationState != .active {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                let content = UNMutableNotificationContent()
                content.title = "Your group has an update"
                content.body = "Open Group Pay to review the latest bill, approvals, or payment."
                content.sound = .default
                // A stable identifier replaces an older pending banner if pushes are coalesced.
                let request = UNNotificationRequest(identifier: "group-pay-cloud-update", content: content, trigger: nil)
                try await UNUserNotificationCenter.current().add(request)
            }
        }
        return !changes.isEmpty
    }

    /// Calendar reminders prompt the leader to start a cycle; they never create
    /// a bill, approve a share, issue a card, or move money in the background.
    /// Permission is requested only by configureNotifications(), never here.
    func syncRecurringReminders(_ bills: [Bill]) async {
        let epoch = accountEpoch
        let identity = currentUserID
        let previous = recurringReminderTask
        previous?.cancel()
        let next = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.accountEpoch == epoch else { return }
            await self.removeRecurringReminders()
            guard !Task.isCancelled, self.accountEpoch == epoch,
                  let identity, self.currentUserID == identity else { return }

            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, self.accountEpoch == epoch,
                  self.currentUserID == identity,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let now = Date()
            let upcoming = bills.filter {
                $0.leaderID == identity && $0.recurrence != .none && $0.status == .paid && ($0.nextDueDate ?? .distantPast) > now
            }.sorted { ($0.nextDueDate ?? .distantFuture) < ($1.nextDueDate ?? .distantFuture) }.prefix(32)

            for bill in upcoming {
                guard !Task.isCancelled, self.accountEpoch == epoch,
                      self.currentUserID == identity, let dueDate = bill.nextDueDate else { return }
                let content = UNMutableNotificationContent()
                content.title = "Your recurring split is due"
                content.body = "Open Group Pay to start the next cycle of \(bill.title). Everyone will need to approve again."
                content.sound = .default
                content.userInfo = ["billID": bill.id.uuidString]

                // Include timezone and seconds so the stored due date maps to
                // one precise future calendar occurrence, rather than a repeat.
                let components = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: dueDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: Self.recurringReminderPrefix + bill.id.uuidString, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                } catch {
                    // Do not obscure successfully synced bills with an optional
                    // reminder failure. The due date remains visible in the app.
                    continue
                }
            }
        }
        recurringReminderTask = next
        await next.value
    }

    private func removeRecurringReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(Self.recurringReminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
        zoneReady = true
    }

    /// Read complete paginated snapshots. No query/index setup is required for this small prototype.
    /// Production apps should persist per-zone change tokens and implement incremental reconciliation.
    private func loadRecords() async throws -> [(CKRecord, CKDatabase.Scope)] {
        var all: [(CKRecord, CKDatabase.Scope)] = []
        for scope in [CKDatabase.Scope.private, .shared] {
            let database = container.database(with: scope)
            let zones = try await database.allRecordZones().filter { $0.zoneID.zoneName == zoneID.zoneName }
            for zone in zones {
                var token: CKServerChangeToken?
                var records: [CKRecord.ID: CKRecord] = [:]
                var more = true
                while more {
                    let batch = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token, resultsLimit: 100)
                    for (_, value) in batch.modificationResultsByID {
                        let record = try value.get().record
                        if record.recordType == "GroupPayBill" { records[record.recordID] = record }
                    }
                    for deletion in batch.deletions { records.removeValue(forKey: deletion.recordID) }
                    token = batch.changeToken
                    more = batch.moreComing
                }
                all.append(contentsOf: records.values.map { ($0, scope) })
            }
        }
        return all
    }

    private func encode(_ bill: Bill, into record: CKRecord) throws {
        let data = try encoder.encode(bill)
        guard data.count < 900_000 else {
            throw Failure.unavailable("This bill's history is too large to sync. Create a new recurring bill to continue.")
        }
        record["payload"] = data as CKRecordValue
        record["updatedBy"] = currentUserID as CKRecordValue?
    }

    private func decode(_ record: CKRecord) throws -> Bill {
        guard let data = record["payload"] as? Data else { throw Failure.invalidData }
        let bill = try JSONDecoder().decode(Bill.self, from: data)
        guard bill.id.uuidString == record.recordID.recordName else { throw Failure.invalidData }
        return bill
    }

    private func save(_ record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw Failure.invalidData }
        return try saved.get()
    }

    private var fingerprintsKey: String { "GroupPay.cloudFingerprints.\(currentUserID ?? "signed-out")" }

    private func fingerprint(_ record: CKRecord) -> String {
        let payload = record["payload"] as? Data ?? Data()
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ records: [(CKRecord, CKDatabase.Scope)], replacing: Bool = true) {
        var values = replacing ? [:] : UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
        for (record, _) in records { values[record.recordID.recordName] = fingerprint(record) }
        UserDefaults.standard.set(values, forKey: fingerprintsKey)
    }

    private func readable(_ error: Error) -> Error {
        if error is Failure || error is BillError { return error }
        if error is DecodingError || error is EncodingError { return Failure.invalidData }
        let unavailable = Failure.unavailable("We couldn’t update your bills in iCloud. Try again in a moment.")
        guard let cloudError = error as? CKError else { return unavailable }
        switch cloudError.code {
        case .notAuthenticated:
            return Failure.unavailable("Sign in to iCloud in Settings, then reconnect your account.")
        case .badContainer, .missingEntitlement, .badDatabase:
            return Failure.unavailable("Group Pay couldn’t connect to iCloud. Update or reinstall the app, then try again.")
        case .serverRecordChanged:
            return Failure.unavailable("This bill changed on another device. Refresh and review the current amounts before trying again.")
        case .permissionFailure:
            return Failure.unavailable("You no longer have permission to change this bill. Ask its owner to check your invitation and sharing access.")
        case .networkUnavailable, .networkFailure, .serviceUnavailable:
            return Failure.unavailable("iCloud is temporarily unavailable. Check your connection and try again.")
        case .partialFailure:
            if let nested = cloudError.partialErrorsByItemID?.values.first { return readable(nested) }
            return unavailable
        default:
            return unavailable
        }
    }

    func itemTitle(for csc: UICloudSharingController) -> String? { "Group Pay bill" }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Self.report(error)
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
    }

    static func report(_ error: Error) {
        NotificationCenter.default.post(name: .groupPayCloudError, object: nil, userInfo: ["message": shared.readable(error).localizedDescription])
    }
}

@MainActor
final class GroupPayAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var accountObserver: NSObjectProtocol?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in
                CloudService.shared.invalidateAccount()
            }
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = GroupPaySceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            do {
                let changed = try await CloudService.shared.receivedRemoteChange()
                completionHandler(changed ? .newData : .noData)
            } catch {
                completionHandler(.failed)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CloudService.report(CloudService.Failure.unavailable("Notifications are unavailable right now. Open Group Pay to check for updates."))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class GroupPaySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            do { try await CloudService.shared.accept(metadata) }
            catch { CloudService.report(error) }
        }
    }
}
