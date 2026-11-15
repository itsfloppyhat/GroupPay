import Foundation
import Observation
import Security
import SwiftUI

struct SandboxIssuedCard: Codable, Sendable {
    let provider: String
    let cardToken: String
    let lastFour: String
    let state: String
    let loadedCents: Int
    let remainingCents: Int
    let createdAt: String
}

private final class SandboxNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the local backend credential to a redirect destination.
        completionHandler(nil)
    }
}

enum SandboxConnectionError: LocalizedError {
    case invalidURL, insecureDeviceURL, missingToken, invalidToken, tokenForNewServer
    case keychain(OSStatus), notConfigured, invalidBill, invalidResponse
    case unavailable, timedOut, unauthorized, conflict, unconfiguredBackend, rejected(Int), redirect
    case reconciliationPending, sandboxUnavailable, sandboxAccessDenied, missingLaunchSettings
    case amountLimit, dailyLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Check the connection address and try again."
        case .insecureDeviceURL:
            "This connection isn’t secure. Use the secure address supplied for this device."
        case .missingToken:
            "Enter your Group Pay access code to continue."
        case .invalidToken:
            "The access code doesn’t look complete. Copy it again and try once more."
        case .tokenForNewServer:
            "Enter your access code again for this connection."
        case .keychain(let status):
            if status == errSecMissingEntitlement {
                "Your connection couldn’t be saved securely. Update or reinstall Group Pay, then try again."
            } else {
                "Your connection couldn’t be saved securely. Unlock this device and try again."
            }
        case .missingLaunchSettings:
            "Connection details are missing. Open Connection details to finish setup."
        case .notConfigured:
            "Connect to your team before creating a test card."
        case .invalidBill:
            "Review the bill and collect everyone’s approval before creating a card."
        case .invalidResponse:
            "We couldn’t confirm this card’s details. Retry this same bill to check its status instead of creating a new bill."
        case .unavailable:
            "The card service couldn’t be reached. Check your connection and try again."
        case .timedOut:
            "Creating your card is taking longer than expected. Retry this same bill to check its status."
        case .unauthorized:
            "That access code wasn’t accepted. Ask your team organizer for the current code, then try again."
        case .conflict:
            "This bill’s card request needs to be reviewed. Keep this bill and check the card service before trying again."
        case .unconfiguredBackend:
            "The card service isn’t ready yet. Ask your team organizer to finish setup."
        case .reconciliationPending:
            "Your test card is still being prepared. Retry this same bill to check its status."
        case .sandboxUnavailable:
            "The test card service is temporarily unavailable. Retry this same bill in a moment."
        case .sandboxAccessDenied:
            "The card service couldn’t authorize this request. Ask your team organizer to check the connection, then retry this same bill."
        case .amountLimit:
            "New test cards can cover up to $500. Choose a bill within that limit."
        case .dailyLimitReached:
            "Your team has reached today’s test card limit. It resets at midnight UTC. Existing card requests can still be checked."
        case .redirect:
            "The connection address has changed. Check your team setup and try again."
        case .rejected:
            "We couldn’t create the card. Retry this same bill in a moment."
        }
    }
}

@MainActor @Observable
final class SandboxCardService {
    static let shared = SandboxCardService()
    private static let endpointKey = "GroupPay.sandbox.backendURL"
    private static let enabledKey = "GroupPay.sandbox.enabled"
    private static let keychainService = "com.itsfloppyhat.GroupPay.sandbox"
    private static let keychainAccount = "local-backend-token"
    private static let testBillKey = "GroupPay.sandbox.testBillID"

    /// A public service address is safe to bundle. Credentials are entered by
    /// the user and remain in this device's Keychain.
    static var hostedURL: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GroupPayCardServiceURL") as? String,
              let url = try? validatedURL(value), url.scheme?.lowercased() == "https" else { return nil }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    private(set) var baseURL: String
    private(set) var setupError: String?
    private(set) var maxAmountCents: Int?
    private var hasToken: Bool
    private let session: URLSession

    var configured: Bool { hasToken && (try? Self.validatedURL(baseURL)) != nil }

    /// Limit only fresh reservations; an existing issuance must remain recoverable.
    var newCardLimitCents: Int? {
        if let maxAmountCents { return maxAmountCents }
        return baseURL == Self.hostedURL ? 50_000 : nil
    }

    private init() {
        // A bundled address never migrates an existing connection. Bills that
        // are already issuing remain bound to their original service.
        let savedURL = UserDefaults.standard.string(forKey: Self.endpointKey)
        baseURL = savedURL ?? Self.hostedURL ?? "http://127.0.0.1:8787"
        // Keychain items can survive reinstalling the app. Do not reuse an
        // orphaned credential with a newly bundled destination.
        let tokenExists = savedURL != nil && Self.readToken() != nil
        hasToken = tokenExists
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) && tokenExists
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SandboxNoRedirects(), delegateQueue: nil)
        #if DEBUG && targetEnvironment(simulator)
        // An explicit development launch may pair this simulator with the local
        // backend. Only its client bearer is accepted; provider secrets stay on
        // the Mac. A health check must succeed before sandbox issuance is enabled.
        if ProcessInfo.processInfo.arguments.contains("--configure-sandbox") {
            enabled = false
            let environment = ProcessInfo.processInfo.environment
            do {
                guard let url = environment["GROUP_PAY_BACKEND_URL"],
                      let token = environment["GROUP_PAY_BACKEND_TOKEN"], !token.isEmpty else {
                    throw SandboxConnectionError.missingLaunchSettings
                }
                try saveConnection(url: url, token: token)
            } catch let error as SandboxConnectionError {
                setupError = error.localizedDescription
            } catch {
                setupError = "Your connection couldn’t be saved. Open Connection details and try again."
            }
        }
        #endif
    }

    func saveConnection(url: String, token: String) throws {
        let parsed = try Self.validatedURL(url)
        let normalized = parsed.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let provided = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret: String
        if provided.isEmpty {
            guard let existing = Self.readToken() else { throw SandboxConnectionError.missingToken }
            guard normalized == baseURL else { throw SandboxConnectionError.tokenForNewServer }
            secret = existing
        } else {
            guard (32...256).contains(provided.utf8.count),
                  provided.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw SandboxConnectionError.invalidToken
            }
            secret = provided
        }
        try Self.writeToken(secret)
        baseURL = normalized
        UserDefaults.standard.set(normalized, forKey: Self.endpointKey)
        hasToken = true
        setupError = nil
        maxAmountCents = nil
        // Saving a new destination does not silently opt in to issuing provider cards.
        enabled = false
    }

    func clearConnection() throws {
        let result = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SandboxConnectionError.keychain(result) }
        hasToken = false
        enabled = false
        UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        baseURL = Self.hostedURL ?? "http://127.0.0.1:8787"
        setupError = nil
        maxAmountCents = nil
    }

    func health() async throws -> Bool {
        let checkedURL = baseURL
        let data = try await request(path: "v1/status", method: "GET")
        struct Health: Decodable { let ready: Bool; let environment: String?; let maxAmountCents: Int? }
        guard let response = try? JSONDecoder().decode(Health.self, from: data),
              response.environment == nil || response.environment == "sandbox" else { throw SandboxConnectionError.invalidResponse }
        if let limit = response.maxAmountCents, !(1...Bill.maximumCents).contains(limit) {
            throw SandboxConnectionError.invalidResponse
        }
        guard baseURL == checkedURL else { throw SandboxConnectionError.notConfigured }
        maxAmountCents = response.ready ? response.maxAmountCents : nil
        return response.ready
    }

    func issue(for bill: Bill) async throws -> SandboxIssuedCard {
        guard bill.status == .issuing, bill.card == nil, bill.allApproved,
              bill.cardAmountCents > 0, bill.totalCents <= Bill.maximumCents else { throw SandboxConnectionError.invalidBill }
        let payload = SandboxIssuanceRequest(bill: bill)
        let data = try await request(path: "v1/cards", method: "POST", body: JSONEncoder().encode(payload))
        guard let card = try? JSONDecoder().decode(SandboxIssuedCard.self, from: data),
              card.provider == "marqetaSandbox", card.state == "ACTIVE",
              card.loadedCents == bill.cardAmountCents, card.remainingCents == bill.cardAmountCents,
              card.lastFour.utf8.count == 4, card.lastFour.utf8.allSatisfy({ (48...57).contains($0) }),
              !card.cardToken.isEmpty, card.cardToken.utf8.count <= 40,
              card.cardToken.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              Self.parseDate(card.createdAt) != nil else { throw SandboxConnectionError.invalidResponse }
        return card
    }

    func checkGuestAvailability() async throws {
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorDemo.shared.enabled { return }
        #endif
        let data = try await request(path: "v1/status", method: "GET")
        struct Status: Decodable { let supportsGuestApprovals: Bool? }
        guard let status = try? JSONDecoder().decode(Status.self, from: data), status.supportsGuestApprovals == true else {
            throw BillError("Guest webpages aren’t available on this team connection yet. Ask your organizer to update the service.")
        }
    }

    func guestInvitation(_ invitation: GuestInvitation, create: Bool = false, close: Bool = false) async throws -> GuestApproval {
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorDemo.shared.enabled { return try await SimulatorDemo.shared.invitation(invitation, create: create, close: close) }
        #endif
        guard baseURL == invitation.baseURL else {
            throw BillError("Restore the original team connection to manage this guest invitation.")
        }
        let path = "v1/guest-invitations" + (create ? "" : "/" + invitation.portion.invitationID.uuidString + (close ? "/close" : ""))
        let data = try await request(path: path, method: create || close ? "POST" : "GET",
                                     body: create ? JSONEncoder().encode(invitation.portion) : nil)
        guard let result = try? JSONDecoder().decode(GuestApproval.self, from: data),
              result.portion == invitation.portion else { throw SandboxConnectionError.invalidResponse }
        return result
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func persistedTestBillID() -> UUID {
        if let value = UserDefaults.standard.string(forKey: testBillKey), let id = UUID(uuidString: value) { return id }
        return newTestBillID()
    }

    static func newTestBillID() -> UUID {
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: testBillKey)
        return id
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard configured, let token = Self.readToken() else { throw SandboxConnectionError.notConfigured }
        let endpoint = try Self.validatedURL(baseURL).appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .timedOut { throw SandboxConnectionError.timedOut }
            if error.code == .cancelled { throw CancellationError() }
            throw SandboxConnectionError.unavailable
        } catch { throw SandboxConnectionError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw SandboxConnectionError.invalidResponse }
        guard data.count <= 65_536 else { throw SandboxConnectionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Decode only an allowlisted machine code. Never read or echo an
            // arbitrary provider/backend message, which could contain secrets.
            enum BackendCode: String, Decodable {
                case notConfigured = "not_configured"
                case reconciliationPending = "reconciliation_pending"
                case fundingPending = "funding_pending"
                case sandboxUnavailable = "sandbox_unavailable"
                case sandboxAccessDenied = "sandbox_access_denied"
                case amountLimit = "amount_limit"
                case dailyLimitReached = "daily_limit_reached"
            }
            struct ErrorEnvelope: Decodable { let error: BackendCode }
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
            if http.statusCode == 422, code == .amountLimit { throw SandboxConnectionError.amountLimit }
            if http.statusCode == 429, code == .dailyLimitReached { throw SandboxConnectionError.dailyLimitReached }
            if http.statusCode == 503 {
                switch code {
                case .notConfigured: throw SandboxConnectionError.unconfiguredBackend
                case .reconciliationPending, .fundingPending: throw SandboxConnectionError.reconciliationPending
                case .sandboxUnavailable: throw SandboxConnectionError.sandboxUnavailable
                default: break
                }
            }
            if http.statusCode == 502, code == .sandboxAccessDenied {
                throw SandboxConnectionError.sandboxAccessDenied
            }
            switch http.statusCode {
            case 300..<400: throw SandboxConnectionError.redirect
            case 401, 403: throw SandboxConnectionError.unauthorized
            case 409: throw SandboxConnectionError.conflict
            default: throw SandboxConnectionError.rejected(http.statusCode)
            }
        }
        return data
    }

    static func validatedURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || (1...65535).contains(components.port!),
              let url = components.url else { throw SandboxConnectionError.invalidURL }
        if components.scheme?.lowercased() == "https" { return url }
        #if targetEnvironment(simulator)
        if components.scheme?.lowercased() == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host.lowercased()) { return url }
        #endif
        throw SandboxConnectionError.insecureDeviceURL
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount,
         kSecAttrSynchronizable as String: false]
    }

    private static func readToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var result = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let query = keychainQuery.merging(attributes) { _, new in new }
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw SandboxConnectionError.keychain(result) }
    }
}

struct SandboxConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = SandboxCardService.shared
    @State private var endpoint = SandboxCardService.shared.baseURL
    @State private var clientToken = ""
    @State private var showConnectionDetails = !SandboxCardService.shared.configured
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    #if targetEnvironment(simulator)
    @State private var testBillID = SandboxCardService.persistedTestBillID()
    @State private var testCard: SandboxIssuedCard?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Panel {
                        HStack(spacing: 12) {
                            Image(systemName: "creditcard").font(.title2).foregroundStyle(GP.mint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Test mode").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                Text("Marqeta test cards").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                            }
                        }
                        Toggle("Use test cards", isOn: Binding(
                            get: { service.enabled },
                            set: { requested in
                                if requested { checkConnection() }
                                else { service.enabled = false; status = nil }
                            }
                        )).disabled(!service.configured || busy)
                        Text("Creates cards with test funds after everyone approves. No real money moves, and these cards can’t pay a business.")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    }
                    Panel {
                        HStack {
                            Text("Connection").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            Spacer()
                            Text(service.configured ? "Saved" : "Not set up")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(service.configured ? GP.mint : GP.secondary)
                        }
                        DisclosureGroup("Connection details", isExpanded: $showConnectionDetails) {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Connection address", text: $endpoint)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).gpField()
                                SecureField(service.configured ? "Token saved · leave blank to keep it" : "Group Pay connection token", text: $clientToken)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().gpField()
                                Text("Use only the local Group Pay token. Your Marqeta application and admin credentials stay on your Mac; never enter them here.")
                                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                                if service.configured {
                                    Button("Remove saved connection", role: .destructive) {
                                        do {
                                            try service.clearConnection()
                                            endpoint = service.baseURL
                                            clientToken = ""
                                            status = nil; error = nil
                                        } catch { self.error = error.localizedDescription }
                                    }.font(GP.body(15, weight: .regular, relativeTo: .subheadline)).disabled(busy)
                                }
                            }.padding(.top, 12)
                        }.font(GP.body(15, weight: .regular, relativeTo: .subheadline))
                        Button(busy ? "Checking…" : "Save & check connection") { checkConnection() }
                            .buttonStyle(PrimaryButton()).disabled(busy)
                        if let status {
                            Label(status, systemImage: "checkmark.circle").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                        }
                        if let error = error ?? service.setupError {
                            Label(error, systemImage: "exclamationmark.triangle").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.amber)
                        }
                    }
                    #if targetEnvironment(simulator)
                    testPanel
                    #endif
                }.padding(22)
            }.gpPage().navigationTitle("Test cards").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
        }.preferredColorScheme(.light).tint(GP.mint).interactiveDismissDisabled(busy)
    }

    private func checkConnection() {
        guard !busy else { return }
        busy = true; error = nil; status = nil
        service.enabled = false
        Task {
            defer { busy = false }
            do {
                try service.saveConnection(url: endpoint, token: clientToken)
                clientToken = ""
                guard try await service.health() else { throw SandboxConnectionError.unconfiguredBackend }
                service.enabled = true
                status = "Ready to create test cards."
            } catch { self.error = error.localizedDescription }
        }
    }

    #if targetEnvironment(simulator)
    private var testPanel: some View {
        Panel {
            Label("Try a $10 card", systemImage: "creditcard").font(GP.body(17, weight: .semibold, relativeTo: .headline))
            Text("Uses a sample bill and test participants. No real money moves.")
                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
            if let card = testCard {
                Text("•••• \(card.lastFour)").font(.title2.monospaced().bold())
                Text("\(card.state.capitalized) · \(Money.string(cents: card.loadedCents)) in test funds").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                Button("New test") {
                    testBillID = SandboxCardService.newTestBillID()
                    testCard = nil; error = nil
                }.disabled(busy)
            } else {
                Button(busy ? "Working…" : "Create $10 test card") { issueTestCard() }
                    .buttonStyle(PrimaryButton()).disabled(!service.configured || !service.enabled || busy)
                Text("Trying again keeps the same test, even after reopening this screen.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
            }
        }
    }

    private func issueTestCard() {
        busy = true; error = nil
        var bill = Bill(id: testBillID, title: "Sandbox connection test",
                        items: [BillItem(name: "Test item", amountCents: 1_000)],
                        members: [BillMember(name: "Test leader", accountID: "sandbox-test-leader", approved: true),
                                  BillMember(name: "Test participant", accountID: "sandbox-test-participant", approved: true)],
                        leaderID: "sandbox-test-leader")
        Task {
            defer { busy = false }
            do {
                try bill.reserveSandboxCard(accountID: "sandbox-test-leader")
                testCard = try await service.issue(for: bill)
            }
            catch { self.error = error.localizedDescription }
        }
    }
    #endif
}
