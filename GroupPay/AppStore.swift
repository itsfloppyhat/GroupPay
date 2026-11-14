import SwiftUI
import Observation
import CloudKit
import UserNotifications

@MainActor @Observable
final class AppStore {
    var bills: [Bill] = []
    var accountID: String?
    var name = UserDefaults.standard.string(forKey: "profileName") ?? "You"
    var busy = false
    var error: String?
    var connectionIssue: String?
    var isPreview = false
    var notificationsEnabled = false
    var sharingController: UICloudSharingController?
    var lastSynced: Date?
    private let cloud = CloudService.shared
    private var session = UUID()
    private var dataRevision = 0
    private var reconnectPending = false

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
    var pendingBills: [Bill] { bills.filter { bill in
        bill.status == .collecting && bill.members.contains { $0.accountID == accountID && !$0.approved && accountID != nil }
    } }
    var activeBills: [Bill] { bills.filter { $0.status != .paid } }
    var paidTotal: Int { bills.flatMap(\.history).reduce(0) { $0 + $1.amountCents } }

    func accountChanged() async {
        session = UUID()
        reconnectPending = false
        accountID = nil
        bills = []
        sharingController = nil
        lastSynced = nil
        notificationsEnabled = false
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
            let fetched = try await cloud.fetchBills()
            let verifiedAccount = try await cloud.account()
            guard token == session, verifiedAccount.id == account.id else { return }
            accountID = account.id
            bills = fetched.sorted { $0.createdAt > $1.createdAt }
            isPreview = false
            connectionIssue = nil
            lastSynced = .now
            await cloud.syncRecurringReminders(bills)
            let permission = await UNUserNotificationCenter.current().notificationSettings()
            if permission.authorizationStatus == .authorized {
                do {
                    let enabled = try await cloud.configureNotifications()
                    if token == session { notificationsEnabled = enabled; await cloud.syncRecurringReminders(bills) }
                } catch { if token == session { self.error = error.localizedDescription } }
            }
        } catch {
            guard token == session else { return }
            accountID = nil
            if !isPreview { bills = [] }
            connectionIssue = error.localizedDescription
        }
    }
    func refresh() async {
        guard connected, !busy else { return }
        let token = session
        let revision = dataRevision
        do {
            let current = try await cloud.account()
            guard token == session else { return }
            guard current.id == accountID else { await accountChanged(); return }
            let fetched = try await cloud.fetchBills()
            let verified = try await cloud.account()
            guard token == session, verified.id == current.id, revision == dataRevision else { return }
            bills = fetched.sorted { $0.createdAt > $1.createdAt }
            lastSynced = .now
            await cloud.syncRecurringReminders(bills)
        } catch {
            guard token == session, revision == dataRevision else { return }
            accountID = nil
            bills = []
            sharingController = nil
            connectionIssue = error.localizedDescription
        }
    }
    func preview() {
        session = UUID()
        busy = false
        isPreview = true
        accountID = nil
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
                    throw NSError(domain: "GroupPay", code: 409, userInfo: [NSLocalizedDescriptionKey: "This bill has changed. Refresh and review the latest amounts before continuing."])
                }
                try action(&bill, accountID)
            }
            guard token == session else { return }
            dataRevision += 1
            if let index = bills.firstIndex(where: { $0.id == id }) { bills[index] = updated }
            await cloud.syncRecurringReminders(bills)
        } catch { if token == session { self.error = error.localizedDescription } }
    }
    func invite(_ bill: Bill) async {
        guard connected else { error = "Connect iCloud to invite people on their own devices."; return }
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
        let token = session
        do {
            let enabled = try await cloud.configureNotifications()
            if token == session { notificationsEnabled = enabled; await cloud.syncRecurringReminders(bills) }
        }
        catch { if token == session { self.error = error.localizedDescription } }
    }
}

struct CloudShareSheet: UIViewControllerRepresentable {
    let controller: UICloudSharingController
    func makeUIViewController(context: Context) -> UICloudSharingController { controller }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) { }
}
