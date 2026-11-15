import SwiftUI
import Observation
import CloudKit
import UserNotifications
import CryptoKit

@MainActor @Observable
final class AppStore {
    var bills: [Bill] = []
    var friends: [SavedFriend] = []
    var groups: [PaymentGroup] = []
    var friendInvitations: [FriendInvitation] = []
    var accountID: String?
    var name = UserDefaults.standard.string(forKey: "profileName") ?? "You"
    var busy = false
    var error: String?
    var connectionIssue: String?
    var isPreview = false
    var notificationsEnabled = false
    var notificationsDenied = false
    var sendingNotificationTest = false
    var sharingController: UICloudSharingController?
    var lastSynced: Date?
    private let cloud = CloudService.shared
    private var session = UUID()
    private var dataRevision = 0
    private var reconnectPending = false
    private var refreshID: UUID?

    private func finish(_ token: UUID) {
        guard token == session else { return }
        busy = false
        if reconnectPending {
            reconnectPending = false
            Task { await connect() }
        }
    }
    func acceptedShare() async {
        if busy { reconnectPending = true } else { await connect() }
    }
    var connected: Bool { accountID != nil && !isPreview }
    var refreshing: Bool { refreshID != nil }
    var pendingBills: [Bill] { bills.filter { bill in
        bill.status == .collecting && bill.members.contains { $0.accountID == accountID && !$0.approved && accountID != nil }
    } }
    var activeBills: [Bill] { bills.filter { $0.status != .paid } }
    var paidTotal: Int { bills.flatMap(\.history).reduce(0) { $0 + $1.amountCents } }
    var ownedGroups: [PaymentGroup] { groups.filter { $0.ownerID == accountID } }
    var friendSuggestions: [SavedFriend] {
        var people: [String: SavedFriend] = [:]
        for member in bills.flatMap(\.members) {
            if let id = member.accountID, id != accountID, !friends.contains(where: { $0.id == id }) {
                people[id] = SavedFriend(id: id, name: member.name)
            }
        }
        return people.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func accountChanged() async {
        session = UUID()
        refreshID = nil
        reconnectPending = false
        accountID = nil
        bills = []
        friends = []
        groups = []
        friendInvitations = []
        sharingController = nil
        lastSynced = nil
        notificationsEnabled = false
        notificationsDenied = false
        isPreview = false
        busy = false
        await connect()
    }
    func connect() async {
        guard !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let account = try await cloud.account()
            let workspace = try await cloud.fetchWorkspace()
            let verifiedAccount = try await cloud.account()
            guard token == session, verifiedAccount.id == account.id else { return }
            accountID = account.id
            bills = workspace.bills.sorted { $0.createdAt > $1.createdAt }
            friends = workspace.friends
            groups = workspace.groups
            friendInvitations = workspace.friendInvitations
            isPreview = false
            connectionIssue = nil
            lastSynced = .now
            await cloud.syncRecurringReminders(bills)
            let permission = await UNUserNotificationCenter.current().notificationSettings()
            guard token == session else { return }
            notificationsDenied = permission.authorizationStatus == .denied
            if permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional {
                do {
                    let enabled = try await cloud.configureNotifications()
                    if token == session { notificationsEnabled = enabled; await cloud.syncRecurringReminders(bills) }
                } catch { if token == session { self.error = error.localizedDescription } }
            }
        } catch {
            guard token == session else { return }
            accountID = nil
            if !isPreview { bills = []; friends = []; groups = []; friendInvitations = [] }
            connectionIssue = error.localizedDescription
        }
    }
    func refresh() async {
        guard connected, !busy, refreshID == nil else { return }
        let token = session
        let requestID = UUID()
        refreshID = requestID
        defer { if refreshID == requestID { refreshID = nil } }
        let revision = dataRevision
        do {
            let current = try await cloud.account()
            guard token == session else { return }
            guard current.id == accountID else { await accountChanged(); return }
            let workspace = try await cloud.fetchWorkspace()
            let verified = try await cloud.account()
            guard token == session, verified.id == current.id, revision == dataRevision, !busy else { return }
            bills = workspace.bills.sorted { $0.createdAt > $1.createdAt }
            friends = workspace.friends
            groups = workspace.groups
            friendInvitations = workspace.friendInvitations
            connectionIssue = nil
            lastSynced = .now
            await cloud.syncRecurringReminders(bills)
            let permission = await UNUserNotificationCenter.current().notificationSettings()
            guard token == session else { return }
            notificationsDenied = permission.authorizationStatus == .denied
            let permitted = permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional
            if permitted && !notificationsEnabled {
                let enabled = try await cloud.configureNotifications()
                guard token == session else { return }
                notificationsEnabled = enabled
            } else if !permitted { notificationsEnabled = false }
        } catch {
            guard token == session, revision == dataRevision else { return }
            // Account-change notifications clear private state separately. A
            // transient network or save conflict must not sign the user out.
            connectionIssue = error.localizedDescription
        }
    }
    func preview() {
        session = UUID()
        refreshID = nil
        busy = false
        isPreview = true
        accountID = nil
        friends = []
        groups = []
        friendInvitations = []
        bills = [Bill.demo(leaderID: "preview", name: name)]
    }
    func publish(_ bill: Bill) async -> Bool {
        guard !busy else { return false }
        guard connected else { error = "Connect iCloud in Profile before sending a bill to your group."; return false }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let saved = try await cloud.create(bill)
            guard token == session else { return false }
            dataRevision += 1
            bills.insert(saved, at: 0)
            await cloud.syncRecurringReminders(bills)
            return true
        } catch { if token == session { self.error = error.localizedDescription }; return false }
    }
    func change(_ id: UUID, action: (inout Bill, String) throws -> Void) async {
        guard let accountID, connected else { error = "This is a read-only preview. Connect iCloud to use shared bills."; return }
        guard !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            guard let expected = bills.first(where: { $0.id == id }) else { return }
            let updated = try await cloud.update(id: id, expectedAccountID: accountID) { bill in
                guard bill.cycle == expected.cycle, bill.totalCents == expected.totalCents, bill.shares == expected.shares else {
                    throw BillError("This bill has changed. Refresh and review the latest amounts before continuing.")
                }
                try action(&bill, accountID)
            }
            guard token == session else { return }
            dataRevision += 1
            if let index = bills.firstIndex(where: { $0.id == id }) { bills[index] = updated }
            await cloud.syncRecurringReminders(bills)
        } catch { if token == session { self.error = error.localizedDescription } }
    }
    var sandboxIssuingEnabled: Bool { SandboxCardService.shared.enabled }

    func confirmCard(_ id: UUID) async {
        guard let expected = bills.first(where: { $0.id == id }) else { return }
        if !sandboxIssuingEnabled && expected.status != .issuing {
            await change(id) { try $0.confirm(accountID: $1) }
            // A previous sandbox reservation may have committed even if its
            // reply was lost. Recover the latest state before another attempt.
            if error != nil { await refresh() }
            return
        }
        guard let accountID, connected else { error = "Connect iCloud before confirming a shared bill."; return }
        guard !busy else { return }
        let token = session
        let backendID = SHA256.hash(data: Data(SandboxCardService.shared.baseURL.utf8)).map { String(format: "%02x", $0) }.joined()
        let newCardLimitCents = SandboxCardService.shared.newCardLimitCents
        busy = true
        defer { finish(token) }
        do {
            let reserved = try await cloud.update(id: id, expectedAccountID: accountID) { bill in
                guard bill.cycle == expected.cycle, bill.totalCents == expected.totalCents, bill.shares == expected.shares else {
                    throw BillError("This bill changed. Refresh and review the latest amounts before creating a card.")
                }
                if bill.status == .cardReady, bill.card?.provider == "marqetaSandbox" {
                    guard bill.leaderID == accountID else { throw BillError("Only the leader can recover this card.") }
                    return // An earlier attachment committed but its reply was lost.
                }
                if let original = bill.sandboxBackendID, original != backendID {
                    throw BillError("This bill started with a different card connection. Restore the original connection in settings to finish creating its card.")
                }
                if bill.status == .collecting, let limit = newCardLimitCents, bill.cardAmountCents > limit {
                    throw BillError("New team test cards can hold up to \(Money.string(cents: limit)). This bill exceeds that limit.")
                }
                try bill.reserveSandboxCard(accountID: accountID)
                bill.sandboxBackendID = backendID
            }
            guard token == session else { return }
            dataRevision += 1
            if let index = bills.firstIndex(where: { $0.id == id }) { bills[index] = reserved }
            if reserved.status == .cardReady { return }
            // The durable backend keys issuance by bill + cycle. If saving the result
            // to iCloud fails, repeating this request retrieves the same funded card.
            let currentBackendID = SHA256.hash(data: Data(SandboxCardService.shared.baseURL.utf8)).map { String(format: "%02x", $0) }.joined()
            guard currentBackendID == backendID else {
                throw BillError("Your card connection changed. Restore the original connection in settings, then resume card creation.")
            }
            let issued = try await SandboxCardService.shared.issue(for: reserved)
            guard token == session else { return }
            let card = VirtualCard(lastFour: issued.lastFour, loadedCents: issued.loadedCents,
                                   remainingCents: issued.remainingCents,
                                   createdAt: SandboxCardService.parseDate(issued.createdAt) ?? .now,
                                   provider: issued.provider, providerToken: issued.cardToken,
                                   providerState: issued.state)
            let updated = try await cloud.update(id: id, expectedAccountID: accountID) { bill in
                guard bill.cycle == reserved.cycle, bill.totalCents == reserved.totalCents, bill.shares == reserved.shares else {
                    throw BillError("The bill changed while its test card was being created. Check with the leader before continuing.")
                }
                try bill.attachSandboxCard(accountID: accountID, card: card)
            }
            guard token == session else { return }
            dataRevision += 1
            if let index = bills.firstIndex(where: { $0.id == id }) { bills[index] = updated }
        } catch {
            if token == session {
                self.error = error.localizedDescription + " Refresh this bill, then use Resume card creation if issuance has started to recover the same card."
            }
        }
    }

    func approvePortion(_ id: UUID, selection: TipSelection) async {
        guard let accountID, connected, !busy,
              let expected = bills.first(where: { $0.id == id }),
              let expectedMember = expected.members.first(where: { $0.accountID == accountID }) else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let updated = try await cloud.update(id: id, expectedAccountID: accountID) { bill in
                guard bill.cycle == expected.cycle, bill.foodShares == expected.foodShares,
                      bill.taxShares == expected.taxShares, bill.feeShares == expected.feeShares,
                      let member = bill.members.first(where: { $0.accountID == accountID }),
                      member.tipPercent == expectedMember.tipPercent,
                      member.tipOverrideCents == expectedMember.tipOverrideCents else {
                    throw BillError("Your portion changed. Refresh and review it before approving.")
                }
                if bill.usesPersonalPricing {
                    if selection.customAmount != nil {
                        guard let amount = selection.amountCents(foodCents: bill.foodShares[member.id] ?? 0) else {
                            throw BillError("Enter a valid tip amount.")
                        }
                        try bill.setPersonalTip(accountID: accountID, amountCents: amount)
                    } else {
                        try bill.setPersonalTip(accountID: accountID, percent: selection.percent)
                    }
                }
                try bill.approve(accountID: accountID)
            }
            guard token == session else { return }
            dataRevision += 1
            if let index = bills.firstIndex(where: { $0.id == id }) { bills[index] = updated }
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func createFriendInvitation(name: String, friendName: String) async -> FriendInvitation? {
        guard connected, !busy else { return nil }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let invitation = try await cloud.createFriendInvitation(ownerName: name, recipientName: friendName)
            guard token == session else { return nil }
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(self.name, forKey: "profileName")
            friendInvitations.insert(invitation, at: 0)
            dataRevision += 1
            return invitation
        } catch { if token == session { self.error = error.localizedDescription }; return nil }
    }

    func acceptFriendInvitation(_ invitation: FriendInvitation, name: String) async -> Bool {
        guard connected, !busy else { return false }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            try await cloud.acceptFriendInvitation(invitation, name: name)
            guard token == session else { return false }
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(self.name, forKey: "profileName")
            // Reconcile the saved identity before offering it in a new group.
            let workspace = try await cloud.fetchWorkspace()
            guard token == session else { return false }
            friends = workspace.friends
            friendInvitations = workspace.friendInvitations
            dataRevision += 1
            return true
        } catch { if token == session { self.error = error.localizedDescription }; return false }
    }

    func removeFriendInvitation(_ invitation: FriendInvitation) async {
        guard connected, !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            try await cloud.removeFriendInvitation(invitation)
            guard token == session else { return }
            friendInvitations.removeAll { $0.id == invitation.id }
            dataRevision += 1
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func invite(_ invitation: FriendInvitation) async {
        guard connected, !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let controller = try await cloud.sharingController(for: invitation)
            guard token == session else { return }
            sharingController = controller
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func saveFriend(_ friend: SavedFriend) async {
        guard connected, !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            _ = try await cloud.saveFriend(accountID: friend.id, name: friend.name)
            let saved = try await cloud.fetchFriends()
            guard token == session else { return }
            friends = saved
            dataRevision += 1
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func removeFriend(_ friend: SavedFriend) async {
        guard connected, !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            try await cloud.removeFriend(accountID: friend.id)
            guard token == session else { return }
            friends.removeAll { $0.id == friend.id }
            dataRevision += 1
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func createGroup(name: String, friends selected: [SavedFriend]) async -> PaymentGroup? {
        guard connected, !busy else { return nil }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            guard let accountID else { return nil }
            let group = try await cloud.createGroup(name: name, members: [SavedFriend(id: accountID, name: self.name)] + selected)
            guard token == session else { return nil }
            groups.insert(group, at: 0)
            dataRevision += 1
            return group
        } catch { if token == session { self.error = error.localizedDescription }; return nil }
    }

    func invite(_ group: PaymentGroup) async {
        guard connected, !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let controller = try await cloud.sharingController(for: group)
            guard token == session else { return }
            sharingController = controller
        } catch { if token == session { self.error = error.localizedDescription } }
    }

    func invite(_ bill: Bill) async {
        guard connected else { error = "Connect iCloud to invite people on their own devices."; return }
        guard !busy else { return }
        let token = session
        busy = true
        defer { finish(token) }
        do {
            let controller = try await cloud.sharingController(for: bill)
            if token == session { sharingController = controller }
        }
        catch { if token == session { self.error = error.localizedDescription } }
    }
    func enableNotifications() async {
        guard connected else { error = "Connect iCloud first, then enable notifications."; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            notificationsDenied = true
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return
        }
        let token = session
        do {
            let enabled = try await cloud.configureNotifications()
            if token == session { notificationsEnabled = enabled; notificationsDenied = !enabled; await cloud.syncRecurringReminders(bills) }
        }
        catch { if token == session { self.error = error.localizedDescription } }
    }

    func sendTestNotification() async {
        guard connected, !sendingNotificationTest else { return }
        sendingNotificationTest = true
        defer { sendingNotificationTest = false }
        let token = session
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard token == session else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            error = "Turn on notifications first, then send a test alert."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Group Pay notification check"
        content.body = "This is a test alert. Your phone’s notification settings control where it appears."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "group-pay-notification-check", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        do { try await center.add(request) }
        catch { if token == session { self.error = "The test alert couldn’t be sent. Check your notification settings and try again." } }
    }
}

struct CloudShareSheet: UIViewControllerRepresentable {
    let controller: UICloudSharingController
    func makeUIViewController(context: Context) -> UICloudSharingController { controller }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) { }
}
