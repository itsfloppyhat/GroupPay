import Foundation

enum BillCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case dining = "Dining"
    case groceries = "Groceries"
    case other = "Other"
    var id: String { rawValue }
    var systemImage: String {
        switch self { case .dining: "fork.knife"; case .groceries: "basket"; case .other: "receipt" }
    }
}

enum SplitMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case equal = "Equally"
    case custom = "Custom amounts"
    case items = "By item"
    var id: String { rawValue }
}

enum BillStatus: String, Codable, Sendable {
    case collecting = "Awaiting approval"
    case cardReady = "Card ready"
    case paid = "Paid"
}

enum Recurrence: String, CaseIterable, Codable, Sendable, Identifiable {
    case none = "One time"
    case weekly = "Weekly"
    case monthly = "Monthly"
    var id: String { rawValue }
}

struct BillItem: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var amountCents: Int
    var assigneeIDs: [UUID] = []
}

struct BillMember: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var accountID: String? = nil
    var customCents: Int = 0
    var approved: Bool = false
}

struct VirtualCard: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var lastFour: String
    var loadedCents: Int
    var remainingCents: Int
    var createdAt: Date = Date()
}

struct PaymentRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var amountCents: Int
    var date: Date = Date()
    var cycle: Int
}

struct BillError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct Bill: Codable, Identifiable, Sendable {
    static let maximumCents = 10_000_000

    var id: UUID
    var title: String
    var category: BillCategory
    var items: [BillItem]
    var taxCents: Int
    var tipCents: Int
    var splitMethod: SplitMethod
    var members: [BillMember]
    var leaderID: String
    var status: BillStatus
    var card: VirtualCard?
    var recurrence: Recurrence
    var nextDueDate: Date?
    var cycle: Int
    var history: [PaymentRecord]
    var createdAt: Date

    init(id: UUID = UUID(), title: String, category: BillCategory = .dining,
         items: [BillItem] = [], taxCents: Int = 0, tipCents: Int = 0,
         splitMethod: SplitMethod = .equal, members: [BillMember] = [],
         leaderID: String, status: BillStatus = .collecting, card: VirtualCard? = nil,
         recurrence: Recurrence = .none, nextDueDate: Date? = nil, cycle: Int = 1,
         history: [PaymentRecord] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.category = category
        self.items = items
        self.taxCents = taxCents
        self.tipCents = tipCents
        self.splitMethod = splitMethod
        self.members = members.map { member in
            var member = member
            if !leaderID.isEmpty, member.accountID == leaderID { member.approved = true }
            return member
        }
        self.leaderID = leaderID
        self.status = status
        self.card = card
        self.recurrence = recurrence
        self.nextDueDate = nextDueDate
        self.cycle = cycle
        self.history = history
        self.createdAt = createdAt
    }

    // Guard all public arithmetic against malformed persisted or shared data.
    private static func checkedSum(_ amounts: [Int]) -> Int? {
        var total = 0
        for amount in amounts {
            guard amount >= 0, amount <= maximumCents else { return nil }
            let result = total.addingReportingOverflow(amount)
            guard !result.overflow, result.partialValue <= maximumCents else { return nil }
            total = result.partialValue
        }
        return total
    }

    var subtotalCents: Int { Self.checkedSum(items.map(\.amountCents)) ?? 0 }
    var totalCents: Int { Self.checkedSum(items.map(\.amountCents) + [taxCents, tipCents]) ?? 0 }
    var approvedCount: Int { members.filter { $0.approved && !($0.accountID ?? "").isEmpty }.count }
    var allApproved: Bool {
        validationMessage == nil && members.allSatisfy { $0.approved && !($0.accountID ?? "").isEmpty }
    }

    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this bill a name." }
        if leaderID.isEmpty { return "Connect your iCloud account before sending this bill." }
        if members.count < 2 { return "Add at least two people, including yourself." }
        if members.count > 50 { return "A bill can include up to 50 people." }
        if Set(members.map(\.id)).count != members.count { return "Each person must have a unique place in the bill." }
        if members.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "Give each person a name." }
        if members.filter({ $0.accountID == leaderID }).count != 1 { return "The bill must include its leader exactly once." }
        let accounts = members.compactMap(\.accountID)
        if accounts.contains("") || Set(accounts).count != accounts.count { return "Each person must use a separate iCloud account." }
        if items.isEmpty { return "Add at least one receipt item." }
        if items.count > 500 { return "A bill can include up to 500 receipt items." }
        if Set(items.map(\.id)).count != items.count { return "Each receipt item must have a unique identifier." }
        if items.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.amountCents <= 0 }) { return "Each receipt item needs a name and an amount above zero." }
        if taxCents < 0 || tipCents < 0 { return "Tax and tip cannot be negative." }
        guard let total = Self.checkedSum(items.map(\.amountCents) + [taxCents, tipCents]), total > 0 else {
            return "The total must be between $0.01 and $100,000.00."
        }
        if splitMethod == .custom {
            guard let customTotal = Self.checkedSum(members.map(\.customCents)), customTotal == total else {
                return "Custom amounts must add up to \(Money.string(cents: total)), including tax and tip."
            }
        }
        if splitMethod == .items {
            let memberIDs = Set(members.map(\.id))
            for item in items {
                if item.assigneeIDs.isEmpty { return "Assign every receipt item to at least one person." }
                if Set(item.assigneeIDs).count != item.assigneeIDs.count || !Set(item.assigneeIDs).isSubset(of: memberIDs) {
                    return "Receipt items can only be assigned to people on this bill, once per person."
                }
            }
        }
        return nil
    }

    var shares: [UUID: Int] {
        guard !members.isEmpty, Set(members.map(\.id)).count == members.count,
              Self.checkedSum(items.map(\.amountCents) + [taxCents, tipCents]) != nil else { return [:] }
        let memberIDs = members.map(\.id)
        switch splitMethod {
        case .equal:
            return Self.distribute(totalCents, among: memberIDs)
        case .custom:
            guard Self.checkedSum(members.map(\.customCents)) != nil else { return [:] }
            return Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.customCents) })
        case .items:
            var base = Dictionary(uniqueKeysWithValues: memberIDs.map { ($0, 0) })
            for item in items {
                let ids = memberIDs.filter { item.assigneeIDs.contains($0) }
                guard !ids.isEmpty, ids.count == item.assigneeIDs.count else { return [:] }
                for (id, amount) in Self.distribute(item.amountCents, among: ids) { base[id, default: 0] += amount }
            }
            let subtotal = subtotalCents
            guard subtotal > 0 else { return [:] }
            // Largest-remainder allocation preserves every cent and is deterministic
            // in bill-member order, including when shared items divide unevenly.
            let extras = taxCents + tipCents
            var fractions: [(id: UUID, remainder: Int, position: Int)] = []
            var allocated = 0
            for (position, id) in memberIDs.enumerated() {
                let product = (base[id] ?? 0) * extras // Each operand <= $100k: safely below Int.max.
                let amount = product / subtotal
                base[id, default: 0] += amount
                allocated += amount
                fractions.append((id, product % subtotal, position))
            }
            fractions.sort { $0.remainder == $1.remainder ? $0.position < $1.position : $0.remainder > $1.remainder }
            for fraction in fractions.prefix(extras - allocated) { base[fraction.id, default: 0] += 1 }
            return base
        }
    }

    private static func distribute(_ cents: Int, among ids: [UUID]) -> [UUID: Int] {
        guard !ids.isEmpty, cents >= 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, cents / ids.count + (index < cents % ids.count ? 1 : 0))
        })
    }

    mutating func claim(memberID: UUID, accountID: String) throws {
        try requireCollecting()
        guard !accountID.isEmpty else { throw BillError("Connect your iCloud account first.") }
        guard !members.contains(where: { $0.accountID == accountID }) else { throw BillError("Your account already belongs to this bill.") }
        guard let index = members.firstIndex(where: { $0.id == memberID }), members[index].accountID == nil else {
            throw BillError("This place has already been claimed. Choose your own name.")
        }
        members[index].accountID = accountID
        members[index].approved = false
    }

    mutating func approve(accountID: String) throws {
        try requireCollecting()
        if let validationMessage { throw BillError(validationMessage) }
        guard let index = members.firstIndex(where: { $0.accountID == accountID }), !accountID.isEmpty else {
            throw BillError("Join this bill before approving your portion.")
        }
        members[index].approved = true
    }

    mutating func confirm(accountID: String) throws {
        try requireLeader(accountID)
        try requireCollecting()
        if let validationMessage { throw BillError(validationMessage) }
        guard allApproved else { throw BillError("Everyone must join and approve their portion first.") }
        guard card == nil else { throw BillError("This bill already has a virtual card.") }
        card = VirtualCard(lastFour: String(Int.random(in: 1000...9999)), loadedCents: totalCents, remainingCents: totalCents)
        status = .cardReady
    }

    mutating func pay(accountID: String) throws {
        try requireLeader(accountID)
        guard status == .cardReady, var card, card.remainingCents == totalCents, card.loadedCents == totalCents else {
            throw BillError("Create a funded virtual card before simulating payment.")
        }
        guard !history.contains(where: { $0.cycle == cycle }) else { throw BillError("This bill cycle has already been paid.") }
        card.remainingCents = 0
        self.card = card
        history.append(PaymentRecord(amountCents: totalCents, cycle: cycle))
        status = .paid
        if recurrence != .none {
            if cycle > 1 {
                nextDueDate = Self.nextDate(after: nextDueDate ?? Date(), recurrence: recurrence)
            } else if nextDueDate == nil {
                nextDueDate = Self.nextDate(after: Date(), recurrence: recurrence)
            }
        }
    }

    mutating func startNextCycle(accountID: String) throws {
        try requireLeader(accountID)
        guard status == .paid, recurrence != .none else { throw BillError("Pay this recurring bill before starting another cycle.") }
        guard cycle < Int.max else { throw BillError("This bill cannot start another cycle.") }
        cycle += 1
        status = .collecting
        card = nil
        for index in members.indices { members[index].approved = members[index].accountID == leaderID }
        // The selected next-due date now belongs to this unpaid cycle. Move it
        // forward only after payment, so starting a cycle cannot skip its date.
    }

    private func requireLeader(_ accountID: String) throws {
        guard !accountID.isEmpty, accountID == leaderID else { throw BillError("Only the bill leader can do this.") }
    }

    private func requireCollecting() throws {
        guard status == .collecting else { throw BillError("Approvals are closed for this bill cycle.") }
    }

    private static func nextDate(after date: Date, recurrence: Recurrence) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch recurrence {
        case .none: return nil
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }

    static func demo(leaderID: String, name: String = "You") -> Bill {
        Bill(title: "Dinner at Lilia", items: [
            BillItem(name: "Wood-fired focaccia", amountCents: 1200),
            BillItem(name: "Rigatoni", amountCents: 2800),
            BillItem(name: "Grilled branzino", amountCents: 3600),
            BillItem(name: "Seasonal salad", amountCents: 1800),
            BillItem(name: "Sparkling water", amountCents: 600)
        ], taxCents: 888, tipCents: 2000,
             members: [BillMember(name: name, accountID: leaderID), BillMember(name: "Alex"), BillMember(name: "Sam")],
             leaderID: leaderID)
    }
}

enum Money {
    static func string(cents: Int) -> String {
        let magnitude = cents.magnitude
        let dollars = String(magnitude / 100)
        let grouped = dollars.reversed().enumerated().map { index, digit in
            (index > 0 && index % 3 == 0 ? "," : "") + String(digit)
        }.joined().reversed()
        let fraction = String(magnitude % 100)
        return "\(cents < 0 ? "−" : "")$\(String(grouped)).\(fraction.count == 1 ? "0" : "")\(fraction)"
    }

    static func cents(from text: String) -> Int? {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("$") { input.removeFirst(); input = input.trimmingCharacters(in: .whitespaces) }
        guard input.range(of: #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = input.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = Int(parts[0]) else { return nil }
        let multiplied = dollars.multipliedReportingOverflow(by: 100)
        guard !multiplied.overflow else { return nil }
        let decimal = parts.count == 2 ? String(parts[1]) : "0"
        guard let fraction = Int(decimal.count == 1 ? decimal + "0" : decimal) else { return nil }
        let result = multiplied.partialValue.addingReportingOverflow(fraction)
        return result.overflow ? nil : result.partialValue
    }
}
