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

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a server URL with a host and optional port, without a path, username, password, query, or fragment."
        case .insecureDeviceURL:
            "Use HTTPS on a physical device. The simulator can also reach the Mac’s local backend at http://127.0.0.1:8787."
        case .missingToken:
            "Enter the local backend’s Group Pay client token. Do not enter Marqeta API credentials here."
        case .invalidToken:
            "The client token must contain 32–256 letters, digits, hyphens, or underscores. Copy GROUP_PAY_CLIENT_TOKEN from the local backend settings."
        case .tokenForNewServer:
            "Re-enter the local client token when changing servers. Existing credentials are not automatically sent to a different server."
        case .keychain(let status):
            if status == errSecMissingEntitlement {
                "This app build cannot access Keychain. Install a simulator build with automatic signing enabled, then run the connection helper again."
            } else {
                "The connection credential could not be saved securely. Unlock this device and try again."
            }
        case .missingLaunchSettings:
            "The connection helper did not supply its local settings. Run the simulator connection helper again."
        case .notConfigured:
            "Set up the sandbox connection in Profile before creating a Marqeta card."
        case .invalidBill:
            "Review the bill and collect everyone’s approval before creating a sandbox card."
        case .invalidResponse:
            "The backend returned an unexpected card result. Retry this same bill to recover its status; do not create a replacement bill."
        case .unavailable:
            "The sandbox backend could not be reached. Start it on your Mac and check the server URL."
        case .timedOut:
            "The card request timed out. Retry this same bill to recover its result; the backend may already have created the card."
        case .unauthorized:
            "The backend rejected the client token. Check GROUP_PAY_CLIENT_TOKEN in the Mac’s local backend settings."
        case .conflict:
            "The backend already has a different or incomplete request for this bill cycle. Keep this bill and review the backend status before trying again."
        case .unconfiguredBackend:
            "The backend is not ready. Add your Marqeta sandbox credentials to its local settings file and restart it."
        case .reconciliationPending:
            "The sandbox card or its funding is still pending. Retry this same bill to recover the original request; do not create a new test or replacement bill."
        case .sandboxUnavailable:
            "Marqeta’s sandbox is temporarily unavailable. Retry this same bill to recover its original request; a card or funding order may already exist."
        case .sandboxAccessDenied:
            "Marqeta rejected the backend’s sandbox credentials or permissions. Check the Marqeta settings on your Mac, then retry this same bill."
        case .redirect:
            "The server redirected this request. Enter its direct HTTPS address; credentials were not forwarded."
        case .rejected(let status):
            "The sandbox backend could not complete this request (HTTP \(status)). Retry the same bill after checking its local configuration."
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

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    private(set) var baseURL: String
    private(set) var setupError: String?
    private var hasToken: Bool
    private let session: URLSession

    var configured: Bool { hasToken && (try? Self.validatedURL(baseURL)) != nil }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Self.endpointKey) ?? "http://127.0.0.1:8787"
        let tokenExists = Self.readToken() != nil
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
                setupError = "The local connection could not be saved. Run the simulator connection helper again."
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
        // Saving a new destination does not silently opt in to issuing provider cards.
        enabled = false
    }

    func clearConnection() throws {
        let result = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SandboxConnectionError.keychain(result) }
        hasToken = false
        enabled = false
        UserDefaults.standard.removeObject(forKey: Self.endpointKey)
        baseURL = "http://127.0.0.1:8787"
        setupError = nil
    }

    func health() async throws -> Bool {
        let data = try await request(path: "v1/status", method: "GET")
        struct Health: Decodable { let ready: Bool; let environment: String? }
        guard let response = try? JSONDecoder().decode(Health.self, from: data),
              response.environment == nil || response.environment == "sandbox" else { throw SandboxConnectionError.invalidResponse }
        return response.ready
    }

    func issue(for bill: Bill) async throws -> SandboxIssuedCard {
        guard bill.status == .issuing, bill.card == nil, bill.allApproved,
              bill.totalCents > 0, bill.totalCents <= Bill.maximumCents else { throw SandboxConnectionError.invalidBill }
        struct Member: Encodable { let accountID: String; let approved: Bool; let shareCents: Int }
        struct Issuance: Encodable {
            let billID: String
            let cycle: Int
            let amountCents: Int
            let currency: String
            let leaderID: String
            let members: [Member]
        }
        let payload = Issuance(billID: bill.id.uuidString, cycle: bill.cycle, amountCents: bill.totalCents,
                               currency: "USD", leaderID: bill.leaderID,
                               members: bill.members.map { Member(accountID: $0.accountID ?? "", approved: $0.approved, shareCents: bill.shares[$0.id] ?? 0) })
        let data = try await request(path: "v1/cards", method: "POST", body: JSONEncoder().encode(payload))
        guard let card = try? JSONDecoder().decode(SandboxIssuedCard.self, from: data),
              card.provider == "marqetaSandbox", card.state == "ACTIVE",
              card.loadedCents == bill.totalCents, card.remainingCents == bill.totalCents,
              card.lastFour.utf8.count == 4, card.lastFour.utf8.allSatisfy({ (48...57).contains($0) }),
              !card.cardToken.isEmpty, card.cardToken.utf8.count <= 40,
              card.cardToken.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              Self.parseDate(card.createdAt) != nil else { throw SandboxConnectionError.invalidResponse }
        return card
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
            }
            struct ErrorEnvelope: Decodable { let error: BackendCode }
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
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
                VStack(alignment: .leading, spacing: 22) {
                    PageHeading(overline: "Marqeta sandbox", title: "Connect your card lab.")
                    Panel {
                        Text("Your Mac handles the API keys.").font(.headline)
                        Text("Only the local backend’s client token belongs here. Marqeta application and admin tokens stay in the backend’s settings, never in this app or iCloud.")
                            .font(.subheadline).foregroundStyle(GP.secondary)
                        TextField("Backend URL", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).gpField()
                        SecureField(service.configured ? "Client token · blank keeps saved token" : "Local backend client token", text: $clientToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().gpField()
                        Button(busy ? "Checking…" : "Save & check connection") { checkConnection() }
                            .buttonStyle(PrimaryButton()).disabled(busy)
                        if let status { Label(status, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(GP.mint) }
                        if let error = error ?? service.setupError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(GP.amber)
                        }
                    }
                    Panel {
                        Toggle("Create cards with Marqeta sandbox", isOn: Binding(
                            get: { service.enabled },
                            set: { requested in
                                if requested { checkConnection() }
                                else { service.enabled = false; status = nil }
                            }
                        )).disabled(!service.configured || busy)
                        Text("When enabled, the leader’s confirmation requests a real sandbox card through this backend. A failed request stays pending; the app does not replace it with a pretend card.")
                            .font(.caption).foregroundStyle(GP.secondary)
                        Text("Sandbox cards and funds cannot pay a real merchant. The local backend trusts this test app’s approval data and is not a production payment service.")
                            .font(.caption).foregroundStyle(GP.secondary)
                        #if targetEnvironment(simulator)
                        Text("The default address reaches a backend running on this Mac.").font(.caption).foregroundStyle(GP.secondary)
                        #else
                        Text("Physical devices need a reachable HTTPS backend. The Mac’s 127.0.0.1 address is available only from its simulator.").font(.caption).foregroundStyle(GP.secondary)
                        #endif
                    }
                    #if targetEnvironment(simulator)
                    testPanel
                    #endif
                    if service.configured {
                        Button("Remove saved connection", role: .destructive) {
                            do {
                                try service.clearConnection()
                                endpoint = service.baseURL
                                clientToken = ""
                                status = nil; error = nil
                            } catch { self.error = error.localizedDescription }
                        }.font(.subheadline).disabled(busy)
                    }
                }.padding(22)
            }.gpPage().navigationTitle("Sandbox connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
        }.preferredColorScheme(.dark).tint(GP.mint).interactiveDismissDisabled(busy)
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
                status = "Sandbox backend connected."
            } catch { self.error = error.localizedDescription }
        }
    }

    #if targetEnvironment(simulator)
    private var testPanel: some View {
        Panel {
            Label("Try one sandbox card", systemImage: "creditcard").font(.headline)
            Text("Uses test participants and a $10.00 test bill. No real money moves. This tests the configured Marqeta connection without requiring iCloud in the simulator.")
                .font(.caption).foregroundStyle(GP.secondary)
            if let card = testCard {
                Text("•••• \(card.lastFour)").font(.title2.monospaced().bold())
                Text("\(card.state) · \(Money.string(cents: card.loadedCents)) sandbox funds").font(.subheadline).foregroundStyle(GP.mint)
                Button("New test") {
                    testBillID = SandboxCardService.newTestBillID()
                    testCard = nil; error = nil
                }.disabled(busy)
            } else {
                Button(busy ? "Working…" : "Issue a $10 test card") { issueTestCard() }
                    .buttonStyle(PrimaryButton()).disabled(!service.configured || !service.enabled || busy)
                Text("Retries recover the same test request, including after reopening this screen.").font(.caption).foregroundStyle(GP.secondary)
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
