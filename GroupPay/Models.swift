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
    case issuing = "Creating sandbox card"
    case cardReady = "Card ready"
    case paid = "Paid"
    case cancelled = "Cancelled"

    var isActive: Bool {
        switch self {
        case .collecting, .issuing, .cardReady: true
        case .paid, .cancelled: false
        }
    }
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

struct GuestPortion: Codable, Equatable, Sendable {
    let invitationID: UUID
    let billID: UUID
    let memberID: UUID
    let cycle: Int
    let title: String
    let name: String
    let foodCents: Int
    let taxCents: Int
    let feeCents: Int
    let tipCents: Int
}

struct GuestInvitation: Codable, Sendable {
    let portion: GuestPortion
    let baseURL: String
}

struct GuestApproval: Codable, Sendable {
    let portion: GuestPortion
    let approvedTipCents: Int?
    let closed: Bool
    let expired: Bool
    let token: String?
}

struct BillMember: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var accountID: String? = nil
    var customCents: Int = 0
    var approved: Bool = false
    // Missing fields preserve existing bills and use the bill's category default.
    var tipPercent: Int? = nil
    var tipOverrideCents: Int? = nil
    var guestInvitation: GuestInvitation? = nil
}

struct VirtualCard: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var lastFour: String
    var loadedCents: Int
    var remainingCents: Int
    var createdAt: Date = Date()
    var provider: String? = nil
    var providerToken: String? = nil
    var providerState: String? = nil
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
    var sandboxBackendID: String? = nil
    var pricingVersion: Int? = nil
    var groupID: UUID? = nil

    init(id: UUID = UUID(), title: String, category: BillCategory = .dining,
         items: [BillItem] = [], taxCents: Int = 0, tipCents: Int = 0,
         splitMethod: SplitMethod = .equal, members: [BillMember] = [],
         leaderID: String, status: BillStatus = .collecting, card: VirtualCard? = nil,
         recurrence: Recurrence = .none, nextDueDate: Date? = nil, cycle: Int = 1,
         history: [PaymentRecord] = [], createdAt: Date = Date(),
         pricingVersion: Int? = nil, groupID: UUID? = nil) {
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
        self.pricingVersion = pricingVersion
        self.groupID = groupID
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
    var canCancel: Bool { status == .collecting && card == nil && sandboxBackendID == nil }
    var usesPersonalPricing: Bool { pricingVersion == 2 }
    var defaultTipPercent: Int { category == .dining ? 20 : 0 }
    var baseTotalCents: Int { Self.checkedSum(items.map(\.amountCents) + [taxCents]) ?? 0 }
    var totalTipCents: Int { usesPersonalPricing ? personalPricing?.tipTotal ?? 0 : tipCents }
    var feeCents: Int { usesPersonalPricing ? personalPricing?.feeTotal ?? 0 : 0 }
    /// The service fee is collected separately; it is never loaded on a merchant card.
    var cardAmountCents: Int {
        usesPersonalPricing ? personalPricing?.cardTotal ?? 0 : Self.checkedSum(items.map(\.amountCents) + [taxCents, tipCents]) ?? 0
    }
    var totalCents: Int { usesPersonalPricing ? personalPricing?.total ?? 0 : cardAmountCents }
    var foodShares: [UUID: Int] { allocatedFood ?? [:] }
    var taxShares: [UUID: Int] {
        guard let food = allocatedFood else { return [:] }
        return Self.proportional(taxCents, weights: food, ids: members.map(\.id)) ?? [:]
    }
    var tipShares: [UUID: Int] {
        if usesPersonalPricing { return personalPricing?.tips ?? [:] }
        guard let food = allocatedFood else { return [:] }
        return Self.proportional(tipCents, weights: food, ids: members.map(\.id)) ?? [:]
    }
    var feeShares: [UUID: Int] {
        usesPersonalPricing ? personalPricing?.fees ?? [:] : Dictionary(uniqueKeysWithValues: Set(members.map(\.id)).map { ($0, 0) })
    }
    var approvedCount: Int { members.filter { $0.approved && !($0.accountID ?? "").isEmpty }.count }
    var allApproved: Bool {
        validationMessage == nil && members.allSatisfy { $0.approved && !($0.accountID ?? "").isEmpty }
    }

    var validationMessage: String? {
        if pricingVersion != nil && pricingVersion != 2 { return "Update Group Pay to open this bill's pricing." }
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
        if usesPersonalPricing && tipCents != 0 { return "Use each person's tip instead of a shared tip for this bill." }
        guard let base = Self.checkedSum(items.map(\.amountCents) + [taxCents, tipCents]), base > 0 else {
            return "The total must be between $0.01 and $100,000.00."
        }
        if splitMethod == .custom {
            let expected = usesPersonalPricing ? subtotalCents : base
            guard let customTotal = Self.checkedSum(members.map(\.customCents)), customTotal == expected else {
                return usesPersonalPricing
                    ? "Custom food amounts must add up to \(Money.string(cents: expected)), before tax, personal tips, and the fee."
                    : "Custom amounts must add up to \(Money.string(cents: expected)), including tax and tip."
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
        if usesPersonalPricing {
            if members.contains(where: { member in
                if let percent = member.tipPercent, !(0...100).contains(percent) { return true }
                if let amount = member.tipOverrideCents, !(0...Self.maximumCents).contains(amount) { return true }
                return member.tipPercent != nil && member.tipOverrideCents != nil
            }) { return "Choose a tip from 0% to 100%, or a valid tip amount, for each person." }
            guard personalPricing != nil else { return "The total including tips and fees must be between $0.01 and $100,000.00." }
        }
        return nil
    }

    var shares: [UUID: Int] {
        usesPersonalPricing ? personalPricing?.charges ?? [:] : legacyShares
    }

    private var legacyShares: [UUID: Int] {
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

    private struct PersonalPricing {
        let tips: [UUID: Int]
        let fees: [UUID: Int]
        let charges: [UUID: Int]
        let tipTotal: Int
        let feeTotal: Int
        let cardTotal: Int
        let total: Int
    }

    private var allocatedFood: [UUID: Int]? {
        guard !members.isEmpty, members.count <= 50, Set(members.map(\.id)).count == members.count,
              let subtotal = Self.checkedSum(items.map(\.amountCents)), subtotal > 0 else { return nil }
        let ids = members.map(\.id)
        switch splitMethod {
        case .equal:
            return Self.distribute(subtotal, among: ids)
        case .custom:
            guard let sum = Self.checkedSum(members.map(\.customCents)), sum > 0 else { return nil }
            let custom = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.customCents) })
            if usesPersonalPricing { return sum == subtotal ? custom : nil }
            return Self.proportional(subtotal, weights: custom, ids: ids)
        case .items:
            var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
            for item in items {
                let assigned = ids.filter { item.assigneeIDs.contains($0) }
                guard !assigned.isEmpty, assigned.count == item.assigneeIDs.count else { return nil }
                for (id, amount) in Self.distribute(item.amountCents, among: assigned) {
                    result[id, default: 0] += amount
                }
            }
            return result
        }
    }

    private var personalPricing: PersonalPricing? {
        guard usesPersonalPricing, tipCents == 0, let food = allocatedFood,
              let base = Self.checkedSum(items.map(\.amountCents) + [taxCents]), base > 0,
              let taxes = Self.proportional(taxCents, weights: food, ids: members.map(\.id)) else { return nil }
        var tips: [UUID: Int] = [:]
        var pretips: [UUID: Int] = [:]
        for member in members {
            let foodAmount = food[member.id] ?? 0
            let percent = member.tipPercent ?? defaultTipPercent
            guard (0...100).contains(percent), member.tipPercent == nil || member.tipOverrideCents == nil else { return nil }
            let tip = member.tipOverrideCents ?? (foodAmount * percent + 50) / 100
            guard (0...Self.maximumCents).contains(tip) else { return nil }
            tips[member.id] = tip
            pretips[member.id] = foodAmount + (taxes[member.id] ?? 0)
        }
        guard let tipTotal = Self.checkedSum(Array(tips.values)),
              let cardTotal = Self.checkedSum([base, tipTotal]) else { return nil }
        let feeTotal = (base + 50) / 100
        guard let total = Self.checkedSum([cardTotal, feeTotal]),
              let fees = Self.proportional(feeTotal, weights: pretips, ids: members.map(\.id)) else { return nil }
        let charges = Dictionary(uniqueKeysWithValues: members.map { member in
            let id = member.id
            return (id, (pretips[id] ?? 0) + (tips[id] ?? 0) + (fees[id] ?? 0))
        })
        return PersonalPricing(tips: tips, fees: fees, charges: charges,
                               tipTotal: tipTotal, feeTotal: feeTotal, cardTotal: cardTotal, total: total)
    }

    /// Allocate a shared amount by exact integer weights, preserving every cent.
    /// Member order is the stable tie breaker and never depends on personal tips.
    private static func proportional(_ cents: Int, weights: [UUID: Int], ids: [UUID]) -> [UUID: Int]? {
        guard (0...maximumCents).contains(cents), !ids.isEmpty, Set(ids).count == ids.count,
              let weightTotal = checkedSum(ids.map { weights[$0] ?? 0 }), weightTotal > 0 else { return nil }
        var result: [UUID: Int] = [:]
        var fractions: [(id: UUID, remainder: Int, position: Int)] = []
        var allocated = 0
        for (position, id) in ids.enumerated() {
            let product = (weights[id] ?? 0) * cents
            let amount = product / weightTotal
            result[id] = amount
            allocated += amount
            fractions.append((id, product % weightTotal, position))
        }
        fractions.sort { $0.remainder == $1.remainder ? $0.position < $1.position : $0.remainder > $1.remainder }
        for fraction in fractions.prefix(cents - allocated) { result[fraction.id, default: 0] += 1 }
        return result
    }

    private static func distribute(_ cents: Int, among ids: [UUID]) -> [UUID: Int] {
        guard !ids.isEmpty, cents >= 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, cents / ids.count + (index < cents % ids.count ? 1 : 0))
        })
    }

    mutating func inviteGuest(memberID: UUID, accountID: String, baseURL: String) throws {
        try requireLeader(accountID)
        try requireCollecting()
        guard usesPersonalPricing, validationMessage == nil,
              let index = members.firstIndex(where: { $0.id == memberID }),
              members[index].accountID == nil else {
            throw BillError("Guest links are available for unclaimed portions on new splits.")
        }
        let portion = GuestPortion(invitationID: UUID(), billID: id, memberID: memberID,
                                   cycle: cycle, title: title, name: members[index].name,
                                   foodCents: foodShares[memberID] ?? 0, taxCents: taxShares[memberID] ?? 0,
                                   feeCents: feeShares[memberID] ?? 0, tipCents: tipShares[memberID] ?? 0)
        members[index].guestInvitation = GuestInvitation(portion: portion, baseURL: baseURL)
        members[index].accountID = "guest:" + portion.invitationID.uuidString
        members[index].approved = false
    }

    mutating func applyGuestApproval(_ approval: GuestApproval, accountID: String) throws {
        try requireLeader(accountID)
        try requireCollecting()
        let portion = approval.portion
        guard portion.billID == id, portion.cycle == cycle,
              let index = members.firstIndex(where: { $0.id == portion.memberID }),
              members[index].guestInvitation?.portion == portion,
              members[index].accountID == "guest:" + portion.invitationID.uuidString,
              foodShares[portion.memberID] == portion.foodCents,
              taxShares[portion.memberID] == portion.taxCents,
              feeShares[portion.memberID] == portion.feeCents,
              let tip = approval.approvedTipCents else {
            throw BillError("This guest approval no longer matches the portion. Refresh the split.")
        }
        // A final approval survives link expiry and retry; it cannot change later.
        if members[index].approved {
            guard tipShares[portion.memberID] == tip else { throw BillError("The guest approval changed unexpectedly.") }
            return
        }
        try approve(accountID: "guest:" + portion.invitationID.uuidString, tipAmountCents: tip)
    }

    mutating func removeGuestInvitation(memberID: UUID, invitationID: UUID, accountID: String) throws {
        try requireLeader(accountID)
        try requireCollecting()
        guard let index = members.firstIndex(where: { $0.id == memberID }),
              members[index].guestInvitation?.portion.invitationID == invitationID else {
            throw BillError("This invitation has changed. Refresh the split.")
        }
        members[index].guestInvitation = nil
        members[index].accountID = nil
        members[index].approved = false
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

    mutating func setPersonalTip(accountID: String, percent: Int) throws {
        guard (0...100).contains(percent) else { throw BillError("Choose a tip from 0% to 100%.") }
        try updatePersonalTip(accountID: accountID, percent: percent, amountCents: nil)
    }

    mutating func setPersonalTip(accountID: String, amountCents: Int) throws {
        guard (0...Self.maximumCents).contains(amountCents) else { throw BillError("Enter a valid tip amount.") }
        try updatePersonalTip(accountID: accountID, percent: nil, amountCents: amountCents)
    }

    private mutating func updatePersonalTip(accountID: String, percent: Int?, amountCents: Int?) throws {
        try requireCollecting()
        guard usesPersonalPricing else { throw BillError("Personal tips are available on new bills. This bill keeps its original agreed amounts.") }
        guard !accountID.isEmpty, let index = members.firstIndex(where: { $0.accountID == accountID }) else {
            throw BillError("Join this bill before choosing your tip.")
        }
        guard members[index].tipPercent != percent || members[index].tipOverrideCents != amountCents else { return }
        var revised = self
        revised.members[index].tipPercent = percent
        revised.members[index].tipOverrideCents = amountCents
        revised.members[index].approved = false
        if let message = revised.validationMessage { throw BillError(message) }
        self = revised
    }

    mutating func approve(accountID: String, tipPercent: Int) throws {
        var revised = self
        try revised.setPersonalTip(accountID: accountID, percent: tipPercent)
        try revised.approve(accountID: accountID)
        self = revised
    }

    mutating func approve(accountID: String, tipAmountCents: Int) throws {
        var revised = self
        try revised.setPersonalTip(accountID: accountID, amountCents: tipAmountCents)
        try revised.approve(accountID: accountID)
        self = revised
    }

    /// Keep the shared record so everyone sees the terminal state. Cancellation
    /// cannot race past a persisted provider reservation or hide a funded card.
    mutating func cancel(accountID: String) throws {
        try requireLeader(accountID)
        if status == .cancelled { return }
        guard canCancel else {
            throw BillError("A split can be cancelled only before card creation begins.")
        }
        status = .cancelled
    }

    mutating func confirm(accountID: String) throws {
        try requireLeader(accountID)
        try requireCollecting()
        if let validationMessage { throw BillError(validationMessage) }
        guard allApproved else { throw BillError("Everyone must join and approve their portion first.") }
        guard card == nil else { throw BillError("This bill already has a virtual card.") }
        card = VirtualCard(lastFour: String(Int.random(in: 1000...9999)), loadedCents: cardAmountCents, remainingCents: cardAmountCents)
        status = .cardReady
    }

    /// Persist this reservation before requesting a provider card. Retrying an
    /// interrupted request resumes the same bill cycle instead of making a mock card.
    mutating func reserveSandboxCard(accountID: String) throws {
        try requireLeader(accountID)
        guard status == .collecting || status == .issuing else {
            throw BillError("This bill cycle already has a card or has been paid.")
        }
        if let validationMessage { throw BillError(validationMessage) }
        guard allApproved else { throw BillError("Everyone must join and approve their portion first.") }
        guard card == nil else { throw BillError("This bill already has a virtual card.") }
        status = .issuing
    }

    /// Accept only a fully funded active sandbox card. A repeated response for
    /// the same card is harmless and preserves the originally stored card ID.
    mutating func attachSandboxCard(accountID: String, card incoming: VirtualCard) throws {
        try requireLeader(accountID)
        guard status == .issuing || status == .cardReady else {
            throw BillError("Reserve this bill for sandbox card creation first.")
        }
        if let validationMessage { throw BillError(validationMessage) }
        guard allApproved else { throw BillError("Everyone must join and approve their portion first.") }
        guard incoming.provider == "marqetaSandbox",
              let token = incoming.providerToken, !token.isEmpty, token.count <= 64,
              token == token.trimmingCharacters(in: .whitespacesAndNewlines),
              incoming.lastFour.utf8.count == 4,
              incoming.lastFour.utf8.allSatisfy({ (48...57).contains($0) }),
              incoming.providerState == "ACTIVE",
              incoming.loadedCents == cardAmountCents,
              incoming.remainingCents == cardAmountCents else {
            throw BillError("The sandbox card response is incomplete or does not match the approved bill total.")
        }
        if status == .cardReady {
            guard let existing = card,
                  existing.provider == incoming.provider,
                  existing.providerToken == token,
                  existing.providerState == incoming.providerState,
                  existing.lastFour == incoming.lastFour,
                  existing.loadedCents == incoming.loadedCents,
                  existing.remainingCents == incoming.remainingCents else {
                throw BillError("This bill already has a different card. Refresh before trying again.")
            }
            return
        }
        guard card == nil else { throw BillError("This bill already has a virtual card.") }
        card = incoming
        status = .cardReady
    }

    mutating func pay(accountID: String) throws {
        try requireLeader(accountID)
        guard status == .cardReady, var card, card.remainingCents == cardAmountCents, card.loadedCents == cardAmountCents else {
            throw BillError("Create a funded virtual card before simulating payment.")
        }
        guard card.provider == nil || card.provider == "mock" else {
            throw BillError("This card is managed by its provider. Sandbox transaction simulation is not available yet, so its balance cannot be spent locally.")
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
        sandboxBackendID = nil
        for index in members.indices {
            if members[index].guestInvitation != nil {
                members[index].guestInvitation = nil
                members[index].accountID = nil
            }
            members[index].approved = members[index].accountID == leaderID
        }
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
        ], taxCents: 888,
             members: [BillMember(name: name, accountID: leaderID), BillMember(name: "Alex"), BillMember(name: "Sam")],
             leaderID: leaderID, pricingVersion: 2)
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
