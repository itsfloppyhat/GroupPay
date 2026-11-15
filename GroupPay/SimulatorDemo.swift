#if DEBUG && targetEnvironment(simulator)
import Foundation
@preconcurrency import Network

/// Opt-in, loopback-only recording session. Never compiled into a device build.
/// Uses the production Bill mutations and guest webpage; no iCloud or provider calls.
enum SimulatorDemoRole: String, CaseIterable, Sendable {
    case matthew, dylan
    var name: String { rawValue.capitalized }
    var accountID: String { "demo-" + rawValue }
}

private struct DemoBillSnapshot: Codable, Sendable {
    var bill: Bill
    var revision: Int
}

@MainActor
final class SimulatorDemo {
    static let shared = SimulatorDemo()
    static let baseURL = "http://127.0.0.1:8847"
    private(set) var role: SimulatorDemoRole?
    var enabled: Bool { role != nil }
    private var server: DemoHTTPServer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func start(_ role: SimulatorDemoRole) async throws {
        if role == .matthew, server == nil {
            let candidate = DemoHTTPServer()
            try await candidate.start()
            server = candidate
        }
        self.role = role
        do { _ = try await request(path: "/demo/state") }
        catch { self.role = nil; throw BillError("Start Matthew’s demo on the first simulator, then connect Dylan’s simulator.") }
    }

    func workspace() async throws -> CloudWorkspace {
        guard let role else { throw BillError("Choose a simulator demo role first.") }
        let snapshots = try JSONDecoder().decode([DemoBillSnapshot].self, from: await request(path: "/demo/state"))
        let friend = role == .matthew ? SimulatorDemoRole.dylan : .matthew
        return CloudWorkspace(bills: snapshots.map(\.bill), friends: [SavedFriend(id: friend.accountID, name: friend.name)], groups: [])
    }

    func create(_ bill: Bill) async throws -> Bill {
        let data = try await request(path: "/demo/bills", method: "POST", body: JSONEncoder().encode(bill))
        return try JSONDecoder().decode(DemoBillSnapshot.self, from: data).bill
    }

    func update(id: UUID, expectedAccountID: String, mutation: (inout Bill) throws -> Void) async throws -> Bill {
        guard role?.accountID == expectedAccountID else { throw BillError("The demo role changed.") }
        let snapshots = try JSONDecoder().decode([DemoBillSnapshot].self, from: await request(path: "/demo/state"))
        guard var snapshot = snapshots.first(where: { $0.bill.id == id }) else { throw BillError("This demo split is no longer available.") }
        try mutation(&snapshot.bill)
        let data = try await request(path: "/demo/bills/" + id.uuidString, method: "PUT", body: JSONEncoder().encode(snapshot))
        return try JSONDecoder().decode(DemoBillSnapshot.self, from: data).bill
    }

    func invitation(_ invitation: GuestInvitation, create: Bool, close: Bool) async throws -> GuestApproval {
        guard invitation.baseURL == Self.baseURL else { throw BillError("This link belongs to another session.") }
        let path = "/v1/guest-invitations" + (create ? "" : "/" + invitation.portion.invitationID.uuidString + (close ? "/close" : ""))
        let data = try await request(path: path, method: create || close ? "POST" : "GET", body: create ? JSONEncoder().encode(invitation.portion) : nil)
        return try JSONDecoder().decode(GuestApproval.self, from: data)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let role, let url = URL(string: Self.baseURL + path + "?actor=" + role.rawValue) else { throw BillError("Choose a demo role.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BillError("The demo session changed or is unavailable. Refresh and try again.")
        }
        return data
    }
}

@MainActor
private final class DemoHTTPServer {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var connections: [UUID: DemoHTTPConnection] = [:]
    private var bills: [UUID: DemoBillSnapshot] = [:]
    private struct Guest {
        let portion: GuestPortion
        let token: String
        let expires: Date
        var tip: Int?
        var closed = false
        func response(includeToken: Bool = false) -> GuestApproval {
            GuestApproval(portion: portion, approvedTipCents: tip, closed: closed, expired: expires <= .now, token: includeToken ? token : nil)
        }
    }
    private var guests: [UUID: Guest] = [:]

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 8847)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                let client = DemoHTTPConnection(connection: connection, route: { [weak self] method, target, headers, body in
                    guard let self else { return (503, "text/plain", Data()) }
                    return self.route(method, target, headers, body)
                }, finished: { [weak self] in self?.connections[id] = nil })
                self.connections[id] = client
                client.start()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let pending = self.startContinuation else { return }
                    switch state {
                    case .ready:
                        self.startContinuation = nil
                        pending.resume()
                    case .failed, .cancelled:
                        self.startContinuation = nil
                        pending.resume(throwing: BillError("The demo server port is in use. Keep only one Matthew demo open."))
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    private func route(_ method: String, _ target: String, _ headers: [String: String], _ body: Data) -> (Int, String, Data) {
        do {
            guard body.count <= 65536, let url = URLComponents(string: "http://localhost" + target) else { throw BillError("Invalid demo request.") }
            let path = url.path
            if path == "/demo/inbox", method == "GET" {
                // Local delivery stand-in for the browser-only recording phone.
                // Only links actually generated through the leader's invite UI appear here.
                let links = guests.values.filter { !$0.closed && $0.expires > .now }.map { guest in
                    let name = guest.portion.name
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    return "<a href=\"/guest#\(guest.token)\">Open \(name)’s invitation</a>"
                }.joined()
                let html = """
                <!doctype html><html lang="en"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Demo invitations</title><style>body{margin:0;padding:32px 24px;background:#071c16;color:#f4f8ef;font:18px -apple-system,sans-serif}p{line-height:1.5;color:#bdcfc4}a{display:block;background:#b9ee98;color:#071c16;border-radius:18px;padding:20px;margin-top:24px;font-weight:700;text-decoration:none}.tag{font-size:13px;color:#b9ee98}</style><main><p class="tag">SIMULATOR DEMO · NO REAL MESSAGE SENT</p><h1>Your invitation</h1><p>Matthew shared a Group Pay web link. Review your portion in Safari. No app download needed.</p>\(links.isEmpty ? "<p>No invitations yet. Refresh after Matthew creates a web link.</p>" : links)</main></html>
                """
                return (200, "text/html; charset=utf-8", Data(html.utf8))
            }
            if path == "/guest" || path == "/guest/guest.js" || path == "/guest/guest.css" {
                guard method == "GET" else { throw BillError("Invalid method.") }
                let filename = path == "/guest" ? "index.html" : String(path.split(separator: "/").last!)
                guard let file = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "guest_web") else { throw BillError("Guest resources missing.") }
                var data = try Data(contentsOf: file)
                if filename == "index.html", let html = String(data: data, encoding: .utf8) {
                    data = Data(html.replacingOccurrences(of: "Test mode · No real money moves", with: "Simulator demo · No real money moves").utf8)
                }
                let mime = filename.hasSuffix(".html") ? "text/html" : filename.hasSuffix(".js") ? "text/javascript" : "text/css"
                return (200, mime + "; charset=utf-8", data)
            }
            if path == "/guest-api/portion" {
                guard let authorization = headers["authorization"], authorization.hasPrefix("Guest "),
                      let id = guests.first(where: { $0.value.token == String(authorization.dropFirst(6)) })?.key,
                      var guest = guests[id] else { return (404, "application/json", Data("{}".utf8)) }
                if method == "POST" {
                    struct Tip: Decodable { let tipCents: Int }
                    let tip = try JSONDecoder().decode(Tip.self, from: body).tipCents
                    guard !guest.closed, guest.expires > .now,
                          (0...max(guest.portion.foodCents, guest.portion.tipCents)).contains(tip),
                          let bill = bills[guest.portion.billID]?.bill, bill.status == .collecting,
                          bill.cycle == guest.portion.cycle else { return (404, "application/json", Data("{}".utf8)) }
                    if let existing = guest.tip, existing != tip { return (409, "application/json", Data("{}".utf8)) }
                    guest.tip = tip
                    guests[id] = guest
                } else if method != "GET" { throw BillError("Invalid method.") }
                return try json(guest.response())
            }
            guard let actorName = url.queryItems?.first(where: { $0.name == "actor" })?.value,
                  let actor = SimulatorDemoRole(rawValue: actorName) else { return (401, "application/json", Data("{}".utf8)) }
            if path == "/demo/state", method == "GET" {
                let snapshots = bills.values.filter { $0.bill.members.contains { $0.accountID == actor.accountID } }.map { snapshot in
                    var copy = snapshot
                    if copy.bill.leaderID != actor.accountID { copy.bill = BillSharingProjection.redacted(copy.bill) }
                    return copy
                }
                return try json(snapshots)
            }
            if path == "/demo/bills", method == "POST" {
                let bill = try JSONDecoder().decode(Bill.self, from: body)
                guard actor == .matthew, bill.leaderID == actor.accountID, bill.validationMessage == nil,
                      bill.status == .collecting, bill.card == nil, bills[bill.id] == nil else { throw BillError("Invalid demo split.") }
                let snapshot = DemoBillSnapshot(bill: bill, revision: 1)
                bills[bill.id] = snapshot
                return try json(snapshot)
            }
            if path.hasPrefix("/demo/bills/"), method == "PUT" {
                var updated = try JSONDecoder().decode(DemoBillSnapshot.self, from: body)
                guard path == "/demo/bills/" + updated.bill.id.uuidString,
                      let previous = bills[updated.bill.id], previous.revision == updated.revision,
                      previous.bill.members.contains(where: { $0.accountID == actor.accountID }),
                      updated.bill.validationMessage == nil else { return (409, "application/json", Data("{}".utf8)) }
                if actor != .matthew {
                    // App participant may change only their own tip/approval.
                    var expected = previous.bill
                    guard let member = updated.bill.members.first(where: { $0.accountID == actor.accountID }) else { throw BillError("Missing member.") }
                    if let amount = member.tipOverrideCents { try expected.setPersonalTip(accountID: actor.accountID, amountCents: amount) }
                    else { try expected.setPersonalTip(accountID: actor.accountID, percent: member.tipPercent ?? 0) }
                    if member.approved { try expected.approve(accountID: actor.accountID) }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    guard try encoder.encode(BillSharingProjection.redacted(expected)) == encoder.encode(updated.bill) else { throw BillError("Only your portion may change.") }
                    updated.bill = expected
                }
                updated.revision += 1
                bills[updated.bill.id] = updated
                var response = updated
                if actor != .matthew { response.bill = BillSharingProjection.redacted(response.bill) }
                return try json(response)
            }
            if path.hasPrefix("/v1/guest-invitations"), actor == .matthew {
                if path == "/v1/guest-invitations", method == "POST" {
                    let portion = try JSONDecoder().decode(GuestPortion.self, from: body)
                    guard let bill = bills[portion.billID]?.bill,
                          bill.members.contains(where: { $0.guestInvitation?.portion == portion }) else { throw BillError("This portion is not reserved.") }
                    if guests[portion.invitationID] == nil {
                        let secret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
                        guests[portion.invitationID] = Guest(portion: portion, token: portion.invitationID.uuidString + "." + secret, expires: .now.addingTimeInterval(604800))
                    }
                    guard let guest = guests[portion.invitationID], guest.portion == portion else { throw BillError("This portion changed.") }
                    return try json(guest.response(includeToken: true))
                }
                let parts = path.split(separator: "/")
                guard parts.count >= 3, let id = UUID(uuidString: String(parts[2])), var guest = guests[id] else { throw BillError("Missing invitation.") }
                if method == "POST", parts.last == "close" { guest.closed = true; guests[id] = guest }
                else if method != "GET" { throw BillError("Invalid method.") }
                return try json(guest.response())
            }
            return (404, "application/json", Data("{}".utf8))
        } catch {
            return (422, "application/json", Data("{\"error\":\"invalid_demo_request\"}".utf8))
        }
    }

    private func json(_ value: GuestApproval) throws -> (Int, String, Data) {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        // Match the deployed browser contract: pending approval is explicit JSON null.
        if value.approvedTipCents == nil { object["approvedTipCents"] = NSNull() }
        return (200, "application/json", try JSONSerialization.data(withJSONObject: object))
    }

    private func json<T: Encodable>(_ value: T) throws -> (Int, String, Data) {
        (200, "application/json", try JSONEncoder().encode(value))
    }
}

@MainActor
private final class DemoHTTPConnection {
    let connection: NWConnection
    let route: (String, String, [String: String], Data) -> (Int, String, Data)
    let finished: () -> Void
    private var buffer = Data()
    init(connection: NWConnection, route: @escaping (String, String, [String: String], Data) -> (Int, String, Data), finished: @escaping () -> Void) {
        self.connection = connection; self.route = route; self.finished = finished
    }
    func start() { connection.start(queue: .main); receive() }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if self.buffer.count > 131072 { self.close(); return }
                if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: self.buffer[..<boundary.lowerBound], encoding: .utf8) {
                    let lines = header.components(separatedBy: "\r\n")
                    let start = lines[0].split(separator: " ")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? -1
                    guard start.count == 3, (0...65536).contains(length) else { self.close(); return }
                    if self.buffer.count - boundary.upperBound >= length {
                        let body = Data(self.buffer[boundary.upperBound..<(boundary.upperBound + length)])
                        let (status, mime, payload) = self.route(String(start[0]), String(start[1]), headers, body)
                        let head = "HTTP/1.1 \(status) Response\r\nContent-Type: \(mime)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
                        self.connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor in self?.close() }
                        })
                        return
                    }
                }
                if complete || error != nil { self.close() } else { self.receive() }
            }
        }
    }
    private func close() { connection.cancel(); finished() }
}
#endif
