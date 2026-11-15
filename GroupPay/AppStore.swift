import SwiftUI
import Observation
import CloudKit
import UserNotifications
import CryptoKit

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
                if bill.status == .collecting, let limit = newCardLimitCents, bill.totalCents > limit {
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
