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
    static let groupPayOpenBill = Notification.Name("GroupPay.openBill")
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
    private var groupLocations: [UUID: Location] = [:]
    private var friendInvitationLocations: [UUID: Location] = [:]
    private var sharingTitle = "Group Pay"
    private static let billTypes: Set<String> = ["GroupPayBill", "GroupPayBillV2"]
    private static let synchronizedTypes: Set<String> = ["GroupPayBill", "GroupPayBillV2", "GroupPayGroup", "GroupPayFriend", "GroupPayFriendInvitation"]
    private static let knownTypes: Set<String> = ["GroupPayBill", "GroupPayBillV2", "GroupPayGroup", "GroupPayFriend", "GroupPayPrivateCard", "GroupPayFriendInvitation", "GroupPayFriendReceipt"]
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
                groupLocations.removeAll()
                friendInvitationLocations.removeAll()
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
        groupLocations.removeAll()
        friendInvitationLocations.removeAll()
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
        try await fetchWorkspace().bills
    }

    /// One complete snapshot keeps bills, saved friends, and groups consistent
    /// and avoids scanning the same shared zones three times per foreground sync.
    func fetchWorkspace() async throws -> CloudWorkspace {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            var loaded = try await loadRecords()
            try validateSession(epoch, expectedID: identity)
            let connections = try await reconcileFriendInvitations(loaded, identity: identity, epoch: epoch)
            for record in connections.saved {
                loaded.removeAll { $0.1 == .private && $0.0.recordID == record.recordID }
                loaded.append((record, .private))
            }
            var result: [Bill] = []
            var nextLocations: [UUID: Location] = [:]
            for (record, scope) in loaded where Self.billTypes.contains(record.recordType) {
                var bill = try decode(record)
                if bill.groupID != nil && !bill.members.contains(where: { $0.accountID == identity }) { continue }
                // Older builds embedded the card in the shared payload. The owner
                // moves it into an unshared sibling record atomically before redaction.
                if scope == .private && bill.leaderID == identity && bill.card != nil {
                    _ = try await saveBill(bill, record: record, scope: scope)
                    try validateSession(epoch, expectedID: identity)
                }
                bill = try await withPrivateCard(bill, scope: scope)
                try validateSession(epoch, expectedID: identity)
                result.append(bill)
                nextLocations[bill.id] = Location(recordID: record.recordID, scope: scope)
            }
            locations = nextLocations
            let friends = try loaded.filter { $0.0.recordType == "GroupPayFriend" && $0.1 == .private }
                .map { try decodeFriend($0.0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            var groups: [PaymentGroup] = []
            var nextGroups: [UUID: Location] = [:]
            for (record, scope) in loaded where record.recordType == "GroupPayGroup" {
                let group = try decodeGroup(record)
                guard group.members.contains(where: { $0.id == identity }) else { continue }
                groups.append(group)
                nextGroups[group.id] = Location(recordID: record.recordID, scope: scope)
            }
            groupLocations = nextGroups
            remember(loaded)
            return CloudWorkspace(bills: result, friends: friends, groups: groups.sorted { $0.createdAt > $1.createdAt },
                                  friendInvitations: connections.pending.sorted { $0.createdAt > $1.createdAt })
        } catch { throw readable(error) }
    }

    func fetchFriends() async throws -> [SavedFriend] {
        do {
            _ = try await account()
            let epoch = accountEpoch
            let records = try await loadRecords(scopes: [.private])
            try validateSession(epoch)
            return try records.filter { $0.0.recordType == "GroupPayFriend" }.map { try decodeFriend($0.0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch { throw readable(error) }
    }

    func saveFriend(accountID: String, name: String) async throws -> SavedFriend {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accountID.isEmpty, accountID.count <= 256, accountID != identity,
                  !trimmed.isEmpty, trimmed.count <= 100 else {
                throw Failure.unavailable("Choose a joined friend and enter their name.")
            }
            // An arbitrary text field cannot impersonate an iCloud account. Friends
            // come from actual joined bill/group records visible to this account.
            let records = try await loadRecords()
            try validateSession(epoch, expectedID: identity)
            let known = try records.contains { record, _ in
                if Self.billTypes.contains(record.recordType) {
                    return try decode(record).members.contains { $0.accountID == accountID }
                }
                if record.recordType == "GroupPayGroup" {
                    let group: PaymentGroup = try decodePayload(record)
                    return group.members.contains { $0.id == accountID }
                }
                if record.recordType == "GroupPayFriend" {
                    let friend: SavedFriend = try decodePayload(record)
                    return friend.id == accountID
                }
                return false
            }
            guard known else { throw Failure.unavailable("Invite this friend to a bill and let them join before saving them.") }
            try await ensureZone()
            try validateSession(epoch, expectedID: identity)
            let recordID = friendRecordID(accountID)
            let record = try await optionalRecord(recordID, in: container.privateCloudDatabase) ??
                CKRecord(recordType: "GroupPayFriend", recordID: recordID)
            try validateSession(epoch, expectedID: identity)
            let friend = SavedFriend(id: accountID, name: trimmed)
            try encodePayload(friend, into: record)
            _ = try await save(record, in: container.privateCloudDatabase)
            try validateSession(epoch, expectedID: identity)
            return friend
        } catch { throw readable(error) }
    }

    func removeFriend(accountID: String) async throws {
        do {
            _ = try await account()
            let epoch = accountEpoch
            _ = try await container.privateCloudDatabase.deleteRecord(withID: friendRecordID(accountID))
            try validateSession(epoch)
        } catch let error as CKError where error.code == .unknownItem { return }
        catch { throw readable(error) }
    }

    func createFriendInvitation(ownerName: String, recipientName: String) async throws -> FriendInvitation {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            let invitation = FriendInvitation(owner: SavedFriend(id: identity, name: ownerName.trimmingCharacters(in: .whitespacesAndNewlines)),
                                              recipientName: recipientName.trimmingCharacters(in: .whitespacesAndNewlines))
            if let message = invitation.validationMessage { throw Failure.unavailable(message) }
            try await ensureZone()
            try validateSession(epoch, expectedID: identity)
            let record = CKRecord(recordType: "GroupPayFriendInvitation", recordID: friendInvitationRecordID(invitation.id))
            try encodePayload(invitation, into: record)
            let saved = try await save(record, in: container.privateCloudDatabase)
            try validateSession(epoch, expectedID: identity)
            friendInvitationLocations[invitation.id] = Location(recordID: saved.recordID, scope: .private)
            return invitation
        } catch { throw readable(error) }
    }

    func sharingController(for invitation: FriendInvitation) async throws -> UICloudSharingController {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard invitation.owner.id == identity else { throw Failure.ownerOnly }
            let root = try await container.privateCloudDatabase.record(for: friendInvitationRecordID(invitation.id))
            try validateSession(epoch, expectedID: identity)
            let latest = try decodeFriendInvitation(root)
            guard latest.owner.id == identity else { throw Failure.ownerOnly }
            return try await sharingController(root: root, title: "Connect with \(latest.owner.name) on Group Pay", epoch: epoch, identity: identity)
        } catch { throw readable(error) }
    }

    func acceptFriendInvitation(_ invitation: FriendInvitation, name: String) async throws {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            if friendInvitationLocations[invitation.id] == nil { _ = try await fetchWorkspace() }
            try validateSession(epoch, expectedID: identity)
            guard let location = friendInvitationLocations[invitation.id], location.scope == .shared else {
                throw Failure.unavailable("Accept the private invitation from your friend, then open People to connect.")
            }
            let database = container.sharedCloudDatabase
            let record = try await database.record(for: location.recordID)
            try validateSession(epoch, expectedID: identity)
            var latest = try decodeFriendInvitation(record)
            _ = try await validatedFriendShare(for: record, invitation: latest, scope: .shared, identity: identity, epoch: epoch)
            try latest.accept(accountID: identity, name: name)
            try encodePayload(latest, into: record)
            _ = try await save(record, in: database)
            try validateSession(epoch, expectedID: identity)
            // The shared claim comes first. If the private write fails, the next
            // refresh safely completes it using this same invitation.
            _ = try await recordFriendConnection(latest, identity: identity, epoch: epoch)
        } catch { throw readable(error) }
    }

    func removeFriendInvitation(_ invitation: FriendInvitation) async throws {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard invitation.owner.id == identity else { throw Failure.ownerOnly }
            let database = container.privateCloudDatabase
            let id = friendInvitationRecordID(invitation.id)
            guard let record = try await optionalRecord(id, in: database) else { return }
            try validateSession(epoch, expectedID: identity)
            let latest = try decodeFriendInvitation(record)
            guard latest.owner.id == identity else { throw Failure.ownerOnly }
            // Deleting the invitation revokes it. Independently saved private
            // friends remain saved if the connection had already completed.
            let result = try await database.modifyRecords(saving: [], deleting: [id], savePolicy: .ifServerRecordUnchanged, atomically: true)
            for entry in result.deleteResults.values { try entry.get() }
            try validateSession(epoch, expectedID: identity)
            friendInvitationLocations[invitation.id] = nil
        } catch { throw readable(error) }
    }

    private func reconcileFriendInvitations(_ records: [(CKRecord, CKDatabase.Scope)], identity: String, epoch: Int) async throws
        -> (pending: [FriendInvitation], saved: [CKRecord]) {
        var pending: [FriendInvitation] = []
        var saved: [CKRecord] = []
        var nextLocations: [UUID: Location] = [:]
        for (record, scope) in records where record.recordType == "GroupPayFriendInvitation" {
            // A damaged invitation must not hide the user's otherwise valid bills.
            guard let invitation = try? decodeFriendInvitation(record) else { continue }
            guard scope == .private ? invitation.owner.id == identity : invitation.owner.id != identity else { continue }
            if scope == .shared, let friend = invitation.friend, friend.id != identity { continue }
            nextLocations[invitation.id] = Location(recordID: record.recordID, scope: scope)
            do {
                if invitation.friend == nil {
                    if scope == .shared {
                        _ = try await validatedFriendShare(for: record, invitation: invitation, scope: scope, identity: identity, epoch: epoch)
                    }
                    pending.append(invitation)
                } else {
                    let receiptID = friendReceiptRecordID(invitation)
                    if let receipt = records.first(where: { $0.1 == .private && $0.0.recordID == receiptID })?.0 {
                        try validateFriendReceipt(receipt, invitation: invitation, identity: identity)
                        continue
                    }
                    _ = try await validatedFriendShare(for: record, invitation: invitation, scope: scope, identity: identity, epoch: epoch)
                    saved.append(contentsOf: try await recordFriendConnection(invitation, identity: identity, epoch: epoch))
                }
            } catch {
                try validateSession(epoch, expectedID: identity)
                var pendingInvitation = invitation
                if case Failure.unavailable(let message) = error {
                    pendingInvitation.connectionIssue = message
                } else {
                    pendingInvitation.connectionIssue = "This friend connection couldn’t be completed. Refresh to retry, or ask the sender to check the invitation."
                }
                pending.append(pendingInvitation)
            }
        }
        try validateSession(epoch, expectedID: identity)
        friendInvitationLocations = nextLocations
        return (pending, saved)
    }

    private func validatedFriendShare(for record: CKRecord, invitation: FriendInvitation, scope: CKDatabase.Scope,
                                      identity: String, epoch: Int) async throws -> CKShare {
        guard let reference = record.share,
              let share = try await container.database(with: scope).record(for: reference.recordID) as? CKShare else {
            throw Failure.unavailable("This friend invitation is no longer shared. Ask your friend for a new invitation.")
        }
        try validateSession(epoch, expectedID: identity)
        guard share.publicPermission == .none, let current = share.currentUserParticipant else { throw Failure.invalidData }
        if scope == .private {
            guard current.role == .owner, invitation.owner.id == identity else { throw Failure.invalidData }
        } else {
            // Shared-zone ownership is server-assigned and remains available
            // when Apple omits optional identity details from a participant.
            let ownerID = share.owner.userIdentity.userRecordID?.recordName ?? record.recordID.zoneID.ownerName
            guard current.role == .privateUser, current.acceptanceStatus == .accepted, current.permission == .readWrite,
                  ownerID == invitation.owner.id else { throw Failure.invalidData }
        }
        let accepted = share.participants.filter { $0.role != .owner && $0.acceptanceStatus == .accepted }
        guard accepted.count <= 1 else {
            throw Failure.unavailable("Each friend invitation is for one person. Ask the sender to remove extra people from this invitation.")
        }
        if let friend = invitation.friend {
            if scope == .shared {
                guard friend.id == identity else { throw Failure.invalidData }
            } else {
                guard accepted.contains(where: { $0.userIdentity.userRecordID?.recordName == friend.id }) else { throw Failure.invalidData }
            }
        }
        return share
    }

    private struct FriendReceipt: Codable {
        let invitationID: UUID
        let ownerID: String
        let friendID: String
    }

    /// The private receipt is retained when a friend is removed. It prevents an
    /// old shared invitation from re-adding them on another device or reinstall.
    private func recordFriendConnection(_ invitation: FriendInvitation, identity: String, epoch: Int) async throws -> [CKRecord] {
        guard let friend = invitation.connectedFriend(for: identity) else { throw Failure.invalidData }
        try await ensureZone()
        try validateSession(epoch, expectedID: identity)
        let database = container.privateCloudDatabase
        let receiptID = friendReceiptRecordID(invitation)
        if let receipt = try await optionalRecord(receiptID, in: database) {
            try validateSession(epoch, expectedID: identity)
            try validateFriendReceipt(receipt, invitation: invitation, identity: identity)
            return []
        }
        try validateSession(epoch, expectedID: identity)
        let receipt = CKRecord(recordType: "GroupPayFriendReceipt", recordID: receiptID)
        try encodePayload(FriendReceipt(invitationID: invitation.id, ownerID: invitation.owner.id, friendID: friend.id), into: receipt)
        var saving = [receipt]
        if let existing = try await optionalRecord(friendRecordID(friend.id), in: database) {
            _ = try decodeFriend(existing)
        } else {
            let record = CKRecord(recordType: "GroupPayFriend", recordID: friendRecordID(friend.id))
            try encodePayload(friend, into: record)
            saving.append(record)
        }
        try validateSession(epoch, expectedID: identity)
        let result = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        try validateSession(epoch, expectedID: identity)
        return try result.saveResults.values.map { try $0.get() }
    }

    private func validateFriendReceipt(_ record: CKRecord, invitation: FriendInvitation, identity: String) throws {
        guard record.recordType == "GroupPayFriendReceipt", record.parent == nil, record.share == nil else { throw Failure.invalidData }
        let receipt: FriendReceipt = try decodePayload(record)
        guard record.recordID == friendReceiptRecordID(invitation), receipt.invitationID == invitation.id,
              receipt.ownerID == invitation.owner.id, receipt.friendID == invitation.connectedFriend(for: identity)?.id else {
            throw Failure.invalidData
        }
    }

    func fetchGroups() async throws -> [PaymentGroup] {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            let records = try await loadRecords()
            try validateSession(epoch, expectedID: identity)
            var groups: [PaymentGroup] = []
            var nextLocations: [UUID: Location] = [:]
            for (record, scope) in records where record.recordType == "GroupPayGroup" {
                let group = try decodeGroup(record)
                // A share can be sent to the wrong Apple account. Do not expose it
                // through the app until it matches the group's named membership.
                guard group.members.contains(where: { $0.id == identity }) else { continue }
                groups.append(group)
                nextLocations[group.id] = Location(recordID: record.recordID, scope: scope)
            }
            groupLocations = nextLocations
            return groups.sorted { $0.createdAt > $1.createdAt }
        } catch { throw readable(error) }
    }

    func createGroup(name: String, members: [SavedFriend]) async throws -> PaymentGroup {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            let group = PaymentGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), ownerID: identity, members: members)
            if let message = group.validationMessage { throw Failure.unavailable(message) }
            let friends = try await fetchFriends()
            try validateSession(epoch, expectedID: identity)
            let savedIDs = Set(friends.map(\.id))
            guard group.members.allSatisfy({ $0.id == identity || savedIDs.contains($0.id) }) else {
                throw Failure.unavailable("Save these friends before creating a reusable group.")
            }
            try await ensureZone()
            try validateSession(epoch, expectedID: identity)
            let record = CKRecord(recordType: "GroupPayGroup", recordID: groupRecordID(group.id))
            try encodePayload(group, into: record)
            let saved = try await save(record, in: container.privateCloudDatabase)
            try validateSession(epoch, expectedID: identity)
            groupLocations[group.id] = Location(recordID: saved.recordID, scope: .private)
            return group
        } catch { throw readable(error) }
    }

    func create(_ bill: Bill) async throws -> Bill {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard bill.leaderID == identity else { throw Failure.accountChanged }
            try await ensureZone()
            try validateSession(epoch, expectedID: identity)
            let recordType = bill.pricingVersion == 2 ? "GroupPayBillV2" : "GroupPayBill"
            let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: bill.id.uuidString, zoneID: zoneID))
            if let groupID = bill.groupID {
                let parent = try await container.privateCloudDatabase.record(for: groupRecordID(groupID))
                try validateSession(epoch, expectedID: identity)
                let group = try decodeGroup(parent)
                guard group.ownerID == identity else { throw Failure.ownerOnly }
                guard Set(bill.members.compactMap(\.accountID)) == Set(group.members.map(\.id)),
                      bill.members.count == group.members.count else {
                    throw Failure.unavailable("A group bill must include everyone in that saved group.")
                }
                record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
            }
            let saved = try await saveBill(bill, record: record, scope: .private)
            try validateSession(epoch, expectedID: identity)
            locations[bill.id] = Location(recordID: saved.recordID, scope: .private)
            remember([(saved, .private)], replacing: false)
            return try await withPrivateCard(decode(saved), scope: .private)
        } catch { throw readable(error) }
    }

    /// A concurrent save fails visibly and never replaces another person's approval.
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
            var latest = try await withPrivateCard(decode(record), scope: location.scope)
            try validateSession(epoch, expectedID: expectedAccountID)
            try mutation(&latest)
            guard latest.id == id else { throw Failure.invalidData }
            let saved = try await saveBill(latest, record: record, scope: location.scope)
            try validateSession(epoch, expectedID: expectedAccountID)
            remember([(saved, location.scope)], replacing: false)
            let result = try await withPrivateCard(decode(saved), scope: location.scope)
            try validateSession(epoch, expectedID: expectedAccountID)
            return result
        } catch { throw readable(error) }
    }

    func sharingController(for bill: Bill) async throws -> UICloudSharingController {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard bill.leaderID == identity else { throw Failure.ownerOnly }
            if let groupID = bill.groupID {
                let group = try decodeGroup(await container.privateCloudDatabase.record(for: groupRecordID(groupID)))
                try validateSession(epoch, expectedID: identity)
                return try await sharingController(for: group)
            }
            if locations[bill.id] == nil { _ = try await fetchBills() }
            try validateSession(epoch, expectedID: identity)
            guard let location = locations[bill.id], location.scope == .private else { throw Failure.ownerOnly }
            let root = try await container.privateCloudDatabase.record(for: location.recordID)
            try validateSession(epoch, expectedID: identity)
            return try await sharingController(root: root, title: bill.title, epoch: epoch, identity: identity)
        } catch { throw readable(error) }
    }

    func sharingController(for group: PaymentGroup) async throws -> UICloudSharingController {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            guard group.ownerID == identity else { throw Failure.ownerOnly }
            let root = try await container.privateCloudDatabase.record(for: groupRecordID(group.id))
            try validateSession(epoch, expectedID: identity)
            let latest = try decodeGroup(root)
            guard latest.ownerID == identity else { throw Failure.ownerOnly }
            return try await sharingController(root: root, title: latest.name, epoch: epoch, identity: identity)
        } catch { throw readable(error) }
    }

    private func sharingController(root: CKRecord, title: String, epoch: Int, identity: String) async throws -> UICloudSharingController {
        let database = container.privateCloudDatabase
        let share: CKShare
        if let reference = root.share {
            guard let existing = try await database.record(for: reference.recordID) as? CKShare else { throw Failure.invalidData }
            share = existing
        } else {
            let newShare = CKShare(rootRecord: root)
            newShare.publicPermission = .none
            newShare[CKShare.SystemFieldKey.title] = title as CKRecordValue
            let results = try await database.modifyRecords(saving: [root, newShare], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            for result in results.saveResults.values { _ = try result.get() }
            guard let saved = try results.saveResults[newShare.recordID]?.get() as? CKShare else { throw Failure.invalidData }
            share = saved
        }
        try validateSession(epoch, expectedID: identity)
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = self
        sharingTitle = title
        return controller
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        do {
            guard metadata.containerIdentifier == Self.containerIdentifier else {
                throw Failure.unavailable("This invitation isn’t for Group Pay. Ask the bill’s owner for a new invitation.")
            }
            let identity = try await account().id
            let epoch = accountEpoch
            _ = try await container.accept(metadata)
            try validateSession(epoch, expectedID: identity)
            // Repair silent change delivery as part of accepting the invitation.
            // No new notification permission prompt is shown here.
            do {
                try await repairSubscriptions(epoch: epoch, identity: identity)
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                try validateSession(epoch, expectedID: identity)
                // Accepting the share already succeeded. Always open its data,
                // even if background notification setup needs another attempt.
                Self.report(Failure.unavailable("Your invitation was accepted. Open Profile to turn on notifications, or refresh your bills to see updates."))
            }
            NotificationCenter.default.post(name: .groupPayShareAccepted, object: nil)
        } catch {
            throw readable(error)
        }
    }

    /// Check the server subscription on reconnect instead of trusting a stale
    /// device flag after a reinstall, restored backup, or new share acceptance.
    func configureNotifications() async throws -> Bool {
        do {
            let identity = try await account().id
            let epoch = accountEpoch
            try await repairSubscriptions(epoch: epoch, identity: identity)
            UIApplication.shared.registerForRemoteNotifications()
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch { throw readable(error) }
    }

    private func repairSubscriptions(epoch: Int, identity: String) async throws {
        for (scope, suffix) in [(CKDatabase.Scope.private, "private"), (.shared, "shared")] {
            let database = container.database(with: scope)
            let subscriptions = try await database.allSubscriptions()
            try validateSession(epoch, expectedID: identity)
            let identifier = "group-pay-\(suffix)-v2"
            if !subscriptions.contains(where: { $0.subscriptionID == identifier }) {
                let subscription = CKDatabaseSubscription(subscriptionID: identifier)
                // No record-type filter: reusable group creation and both bill
                // versions must wake the app, including newly accepted zones.
                let notification = CKSubscription.NotificationInfo()
                notification.shouldSendContentAvailable = true
                subscription.notificationInfo = notification
                _ = try await database.save(subscription)
                try validateSession(epoch, expectedID: identity)
            }
            let legacyID = "group-pay-\(suffix)-v1"
            if subscriptions.contains(where: { $0.subscriptionID == legacyID }) {
                _ = try await database.deleteSubscription(withID: legacyID)
                try validateSession(epoch, expectedID: identity)
            }
        }
    }

    func receivedRemoteChange() async throws -> Bool {
        let identity = try await account().id
        let epoch = accountEpoch
        let previous = UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
        let records = try await loadRecords()
        try validateSession(epoch, expectedID: identity)
        let changes = records.filter { record, _ in
            Self.synchronizedTypes.contains(record.recordType) && record["updatedBy"] as? String != identity &&
                previous[recordKey(record)] != fingerprint(record)
        }
        remember(records)
        NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        try validateSession(epoch, expectedID: identity)
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            for (record, _) in changes where Self.billTypes.contains(record.recordType) {
                let bill = try decode(record)
                guard let notice = BillUpdateNotice.make(bill: bill, accountID: identity) else { continue }
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = .default
                content.userInfo = ["billID": bill.id.uuidString]
                // One replaceable notice per bill keeps coalesced updates useful.
                let request = UNNotificationRequest(identifier: "group-pay-bill-" + bill.id.uuidString, content: content, trigger: nil)
                try await UNUserNotificationCenter.current().add(request)
                try validateSession(epoch, expectedID: identity)
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
        let epoch = accountEpoch
        let identity = currentUserID
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
        try validateSession(epoch, expectedID: identity)
        zoneReady = true
    }

    /// Read complete paginated snapshots. No query/index setup is required for this small prototype.
    /// Production apps should persist per-zone change tokens and implement incremental reconciliation.
    private func loadRecords(scopes: [CKDatabase.Scope] = [.private, .shared]) async throws -> [(CKRecord, CKDatabase.Scope)] {
        var all: [(CKRecord, CKDatabase.Scope)] = []
        for scope in scopes {
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
                        if Self.knownTypes.contains(record.recordType) { records[record.recordID] = record }
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

    private struct PrivateCardEnvelope: Codable {
        let billID: UUID
        let cycle: Int
        let leaderID: String
        let card: VirtualCard
    }

    private func privateCardRecordID(_ bill: Bill) -> CKRecord.ID {
        CKRecord.ID(recordName: "card-\(bill.id.uuidString)-\(bill.cycle)", zoneID: zoneID)
    }

    private func friendRecordID(_ accountID: String) -> CKRecord.ID {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "friend-" + key, zoneID: zoneID)
    }

    private func groupRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "group-" + id.uuidString, zoneID: zoneID)
    }

    private func friendInvitationRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "friend-invitation-" + id.uuidString, zoneID: zoneID)
    }

    private func friendReceiptRecordID(_ invitation: FriendInvitation) -> CKRecord.ID {
        let key = SHA256.hash(data: Data((invitation.owner.id + "/" + invitation.id.uuidString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "friend-receipt-" + key, zoneID: zoneID)
    }

    private func optionalRecord(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func withPrivateCard(_ bill: Bill, scope: CKDatabase.Scope) async throws -> Bill {
        var result = BillSharingProjection.redacted(bill)
        guard scope == .private, bill.leaderID == currentUserID else { return result }
        // Legacy records can be read during an atomic migration/update.
        if let legacy = bill.card { result.card = legacy; return result }
        guard bill.status == .cardReady || bill.status == .paid else { return result }
        let identity = currentUserID
        let epoch = accountEpoch
        guard let record = try await optionalRecord(privateCardRecordID(bill), in: container.privateCloudDatabase) else {
            throw Failure.unavailable("Your private card details could not be found. Keep this bill and refresh before trying again.")
        }
        try validateSession(epoch, expectedID: identity)
        guard record.parent == nil, record.share == nil, record.recordType == "GroupPayPrivateCard" else { throw Failure.invalidData }
        let envelope: PrivateCardEnvelope = try decodePayload(record)
        guard envelope.billID == bill.id, envelope.cycle == bill.cycle, envelope.leaderID == bill.leaderID else { throw Failure.invalidData }
        result.card = envelope.card
        return result
    }

    /// The private card is a sibling without a parent/share reference. Saving it
    /// and the public status together is atomic in the leader's private zone.
    private func saveBill(_ bill: Bill, record: CKRecord, scope: CKDatabase.Scope) async throws -> CKRecord {
        let identity = currentUserID
        let epoch = accountEpoch
        let shared = BillSharingProjection.redacted(bill)
        try encodePayload(shared, into: record)
        var records = [record]
        if let card = bill.card {
            guard scope == .private, bill.leaderID == identity else { throw Failure.ownerOnly }
            let cardID = privateCardRecordID(bill)
            let privateRecord = try await optionalRecord(cardID, in: container.privateCloudDatabase) ??
                CKRecord(recordType: "GroupPayPrivateCard", recordID: cardID)
            try validateSession(epoch, expectedID: identity)
            guard privateRecord.parent == nil, privateRecord.share == nil, privateRecord.recordType == "GroupPayPrivateCard" else {
                throw Failure.invalidData
            }
            let envelope = PrivateCardEnvelope(billID: bill.id, cycle: bill.cycle, leaderID: bill.leaderID, card: card)
            try encodePayload(envelope, into: privateRecord)
            records.append(privateRecord)
        }
        let result = try await container.database(with: scope).modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        try validateSession(epoch, expectedID: identity)
        for entry in result.saveResults.values { _ = try entry.get() }
        guard let saved = try result.saveResults[record.recordID]?.get() else { throw Failure.invalidData }
        return saved
    }

    private func encodePayload<T: Encodable>(_ value: T, into record: CKRecord) throws {
        let data = try encoder.encode(value)
        guard data.count < 900_000 else {
            throw Failure.unavailable("This record is too large to sync. Create a new group or recurring bill to continue.")
        }
        record["payload"] = data as CKRecordValue
        record["updatedBy"] = currentUserID as CKRecordValue?
    }

    private func decodePayload<T: Decodable>(_ record: CKRecord) throws -> T {
        guard let data = record["payload"] as? Data else { throw Failure.invalidData }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decode(_ record: CKRecord) throws -> Bill {
        guard Self.billTypes.contains(record.recordType) else { throw Failure.invalidData }
        let bill: Bill = try decodePayload(record)
        guard bill.id.uuidString == record.recordID.recordName,
              (record.recordType == "GroupPayBillV2") == (bill.pricingVersion == 2) else { throw Failure.invalidData }
        return bill
    }

    private func decodeGroup(_ record: CKRecord) throws -> PaymentGroup {
        guard record.recordType == "GroupPayGroup" else { throw Failure.invalidData }
        let group: PaymentGroup = try decodePayload(record)
        guard record.recordID.recordName == groupRecordID(group.id).recordName, group.validationMessage == nil else {
            throw Failure.invalidData
        }
        return group
    }

    private func decodeFriend(_ record: CKRecord) throws -> SavedFriend {
        guard record.recordType == "GroupPayFriend", record.parent == nil, record.share == nil else { throw Failure.invalidData }
        let friend: SavedFriend = try decodePayload(record)
        guard record.recordID.recordName == friendRecordID(friend.id).recordName,
              !friend.id.isEmpty, friend.id.count <= 256,
              !friend.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, friend.name.count <= 100 else {
            throw Failure.invalidData
        }
        return friend
    }

    private func decodeFriendInvitation(_ record: CKRecord) throws -> FriendInvitation {
        guard record.recordType == "GroupPayFriendInvitation", record.parent == nil else { throw Failure.invalidData }
        let invitation: FriendInvitation = try decodePayload(record)
        guard record.recordID.recordName == friendInvitationRecordID(invitation.id).recordName,
              invitation.validationMessage == nil else { throw Failure.invalidData }
        return invitation
    }

    private func save(_ record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw Failure.invalidData }
        return try saved.get()
    }

    private var fingerprintsKey: String { "GroupPay.cloudFingerprints.v2.\(currentUserID ?? "signed-out")" }

    private func recordKey(_ record: CKRecord) -> String {
        record.recordID.zoneID.ownerName + "/" + record.recordID.zoneID.zoneName + "/" + record.recordID.recordName
    }

    private func fingerprint(_ record: CKRecord) -> String {
        let payload = record["payload"] as? Data ?? Data()
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func remember(_ records: [(CKRecord, CKDatabase.Scope)], replacing: Bool = true) {
        var values = replacing ? [:] : UserDefaults.standard.dictionary(forKey: fingerprintsKey) as? [String: String] ?? [:]
        for (record, _) in records where Self.synchronizedTypes.contains(record.recordType) { values[recordKey(record)] = fingerprint(record) }
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

    func itemTitle(for csc: UICloudSharingController) -> String? { sharingTitle }

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
        let rawID = response.notification.request.content.userInfo["billID"] as? String
        let billID = rawID.flatMap(UUID.init(uuidString:))
        await MainActor.run {
            NotificationCenter.default.post(name: .groupPayCloudChanged, object: nil)
            if let billID {
                NotificationCenter.default.post(name: .groupPayOpenBill, object: nil, userInfo: ["billID": billID])
            }
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
