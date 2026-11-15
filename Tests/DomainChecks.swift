import Foundation

@main
@MainActor
enum DomainChecks {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }

    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: \(message)") }
        catch { count += 1 }
    }

    static func makeBill(amount: Int = 100) -> Bill {
        Bill(title: "Dinner", items: [BillItem(name: "Dinner", amountCents: amount)],
             members: [BillMember(name: "Leader", accountID: "leader"), BillMember(name: "Alex"), BillMember(name: "Sam")],
             leaderID: "leader")
    }

    static func approvedBill(amount: Int = 100) throws -> Bill {
        var bill = makeBill(amount: amount)
        try bill.claim(memberID: bill.members[1].id, accountID: "alex")
        try bill.claim(memberID: bill.members[2].id, accountID: "sam")
        try bill.approve(accountID: "alex")
        try bill.approve(accountID: "sam")
        return bill
    }

    static func sandboxChecks() throws {
        let legacyCard = VirtualCard(lastFour: "1234", loadedCents: 100, remainingCents: 100)
        let legacyData = try JSONEncoder().encode(legacyCard)
        let legacyJSON = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        check(legacyJSON["provider"] == nil && legacyJSON["providerToken"] == nil && legacyJSON["providerState"] == nil, "Legacy JSON omits new provider fields")
        let legacyDecoded = try JSONDecoder().decode(VirtualCard.self, from: legacyData)
        check(legacyDecoded.provider == nil && legacyDecoded.providerToken == nil && legacyDecoded.providerState == nil, "Old card JSON decodes absent optional fields")

        var pending = makeBill()
        let legacyBillData = try JSONEncoder().encode(pending)
        let legacyBillJSON = try JSONSerialization.jsonObject(with: legacyBillData) as! [String: Any]
        check(legacyBillJSON["sandboxBackendID"] == nil, "Legacy bill JSON omits absent backend identity")
        let legacyBill = try JSONDecoder().decode(Bill.self, from: legacyBillData)
        check(legacyBill.sandboxBackendID == nil, "Old bill JSON decodes missing backend identity")
        rejects("Cannot reserve before participants approve") { try pending.reserveSandboxCard(accountID: "leader") }
        check(pending.status == .collecting && pending.card == nil, "Failed reservation leaves state unchanged")
        var bill = try approvedBill()
        rejects("Participant cannot reserve sandbox card") { try bill.reserveSandboxCard(accountID: "alex") }
        let funded = VirtualCard(lastFour: "4321", loadedCents: 100, remainingCents: 100,
                                 provider: "marqetaSandbox", providerToken: "sandbox-card-token", providerState: "ACTIVE")
        rejects("Cannot attach before reservation") { try bill.attachSandboxCard(accountID: "leader", card: funded) }
        try bill.reserveSandboxCard(accountID: "leader")
        check(bill.status == .issuing && bill.card == nil, "Reservation locks cycle while provider request is in flight")
        bill.sandboxBackendID = "server-fingerprint"
        try bill.reserveSandboxCard(accountID: "leader")
        check(bill.status == .issuing && bill.card == nil, "Reservation retry is idempotent")
        check(bill.sandboxBackendID == "server-fingerprint", "Reservation preserves backend identity")
        var invalidReservation = try approvedBill()
        invalidReservation.title = ""
        rejects("Invalid bill cannot reserve a card") { try invalidReservation.reserveSandboxCard(accountID: "leader") }
        var revokedApproval = bill
        revokedApproval.members[1].approved = false
        rejects("Attachment rechecks current approvals") { try revokedApproval.attachSandboxCard(accountID: "leader", card: funded) }
        rejects("Approvals cannot change while issuing") { try bill.approve(accountID: "alex") }
        rejects("Claims cannot change while issuing") { try bill.claim(memberID: bill.members[1].id, accountID: "stranger") }
        rejects("Mock confirmation cannot replace in-flight sandbox request") { try bill.confirm(accountID: "leader") }
        rejects("Nonleader cannot attach card") { try bill.attachSandboxCard(accountID: "alex", card: funded) }

        var badResponse = funded
        badResponse.provider = nil
        rejects("Response requires sandbox provider") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        for token in [nil, "", " ", String(repeating: "t", count: 65)] as [String?] {
            badResponse = funded; badResponse.providerToken = token
            rejects("Response requires bounded nonempty token") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        }
        for digits in ["123", "12345", "12ab", "１２３４"] {
            badResponse = funded; badResponse.lastFour = digits
            rejects("Response requires four ASCII last digits") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        }
        for state in [nil, "UNACTIVATED", "SUSPENDED", "active"] as [String?] {
            badResponse = funded; badResponse.providerState = state
            rejects("Response requires ACTIVE provider state") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        }
        badResponse = funded; badResponse.loadedCents = 99
        rejects("Response must fund exact approved bill total") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        badResponse = funded; badResponse.remainingCents = 99
        rejects("Response must have unspent full balance") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        check(bill.status == .issuing && bill.card == nil, "Rejected responses leave reservation intact for retry")
        try bill.attachSandboxCard(accountID: "leader", card: funded)
        check(bill.status == .cardReady && bill.card?.providerToken == funded.providerToken, "Valid funded sandbox card attached")
        var repeatResponse = funded
        repeatResponse.id = UUID()
        try bill.attachSandboxCard(accountID: "leader", card: repeatResponse)
        check(bill.card?.id == funded.id, "Duplicate attachment preserves existing card identity")
        badResponse = funded; badResponse.providerToken = "another-token"
        rejects("Duplicate response cannot replace provider token") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        badResponse = funded; badResponse.providerState = "SUSPENDED"
        rejects("Duplicate response cannot hide changed provider state") { try bill.attachSandboxCard(accountID: "leader", card: badResponse) }
        rejects("Ready sandbox card cannot reserve again") { try bill.reserveSandboxCard(accountID: "leader") }
        rejects("Sandbox balance cannot be consumed locally") { try bill.pay(accountID: "leader") }
        check(bill.status == .cardReady && bill.card?.remainingCents == 100 && bill.history.isEmpty, "Rejected payment preserves actual provider balance and history")
        let persisted = try JSONDecoder().decode(Bill.self, from: JSONEncoder().encode(bill))
        check(persisted.card?.provider == "marqetaSandbox" && persisted.card?.providerState == "ACTIVE", "Provider metadata survives CloudKit JSON")

        var mockBill = try approvedBill()
        try mockBill.confirm(accountID: "leader")
        mockBill.card?.provider = "mock"
        try mockBill.pay(accountID: "leader")
        check(mockBill.status == .paid && mockBill.card?.remainingCents == 0, "Explicit mock provider retains local simulation")
        mockBill.recurrence = .monthly
        mockBill.sandboxBackendID = "previous-server-fingerprint"
        try mockBill.startNextCycle(accountID: "leader")
        check(mockBill.sandboxBackendID == nil, "Fresh cycle clears previous backend reservation identity")
    }

    static func personalPricingChecks() throws {
        func personalBill(_ cents: Int = 10_000, tax: Int = 1_000, category: BillCategory = .dining) -> Bill {
            Bill(title: "Team dinner", category: category,
                 items: [BillItem(name: "Dinner", amountCents: cents)], taxCents: tax,
                 members: [BillMember(name: "Leader", accountID: "leader"), BillMember(name: "Kyle", accountID: "kyle")],
                 leaderID: "leader", pricingVersion: 2)
        }
        var bill = personalBill()
        let leader = bill.members[0].id, kyle = bill.members[1].id
        check(bill.validationMessage == nil && bill.usesPersonalPricing, "Personal pricing is valid")
        check(bill.foodShares[leader] == 5_000 && bill.foodShares[kyle] == 5_000, "Equal split allocates food first")
        check(bill.taxShares[leader] == 500 && bill.taxShares[kyle] == 500, "Tax follows food")
        check(bill.tipShares[leader] == 1_000 && bill.tipShares[kyle] == 1_000, "Dining defaults to 20% of each food subtotal")
        check(bill.feeCents == 110 && bill.feeShares[leader] == 55 && bill.feeShares[kyle] == 55, "One percent fee includes tax but excludes tips")
        check(bill.cardAmountCents == 13_000 && bill.totalCents == 13_110, "Merchant card excludes the service fee")
        check(bill.shares[leader] == 6_555 && bill.shares[kyle] == 6_555, "Each charge includes own food tax tip and fee")
        try bill.approve(accountID: "kyle")
        let leaderCharge = bill.shares[leader]
        let originalFees = bill.feeShares
        try bill.setPersonalTip(accountID: "kyle", percent: 0)
        check(!bill.members[1].approved && bill.members[0].approved, "Changing a tip resets only that person's approval")
        check(bill.shares[leader] == leaderCharge && bill.shares[kyle] == 5_555, "A tip change never changes another person's amount")
        check(bill.feeShares == originalFees && bill.feeCents == 110, "Personal tip changes cannot change the fee")
        try bill.approve(accountID: "kyle", tipAmountCents: 750)
        check(bill.tipShares[kyle] == 750 && bill.members[1].tipPercent == nil && bill.allApproved, "Exact custom tip and approval save together")
        check(bill.cardAmountCents == 12_750 && bill.totalCents == 12_860, "Exact custom tip funds card without service fee")
        try bill.setPersonalTip(accountID: "kyle", amountCents: 750)
        check(bill.allApproved, "Saving the same tip preserves approval")
        rejects("Unjoined user cannot edit anyone's tip") { try bill.setPersonalTip(accountID: "stranger", percent: 25) }
        rejects("Negative personal tip rejected") { try bill.setPersonalTip(accountID: "kyle", amountCents: -1) }
        rejects("Negative personal percent rejected") { try bill.setPersonalTip(accountID: "kyle", percent: -1) }
        rejects("Unbounded percent rejected") { try bill.setPersonalTip(accountID: "kyle", percent: Int.max) }
        let beforeInvalid = try JSONEncoder().encode(bill)
        rejects("Oversized tip does not partially mutate bill") { try bill.approve(accountID: "kyle", tipAmountCents: Bill.maximumCents) }
        let afterInvalid = try JSONDecoder().decode(Bill.self, from: beforeInvalid)
        check(bill.tipShares == afterInvalid.tipShares && bill.allApproved, "Failed tip validation preserves prior approved amounts")
        try bill.setPersonalTip(accountID: "leader", percent: 25)
        check(!bill.members[0].approved && bill.members[1].approved, "Leader must approve after changing their own tip")
        try bill.approve(accountID: "leader")
        let cardCents = bill.cardAmountCents
        try bill.reserveSandboxCard(accountID: "leader")
        rejects("Tips freeze during issuance") { try bill.setPersonalTip(accountID: "kyle", percent: 30) }
        var card = VirtualCard(lastFour: "1234", loadedCents: bill.totalCents, remainingCents: bill.totalCents,
                               provider: "marqetaSandbox", providerToken: "test-card", providerState: "ACTIVE")
        rejects("Fee cannot be accidentally loaded on merchant card") { try bill.attachSandboxCard(accountID: "leader", card: card) }
        card.loadedCents = cardCents
        card.remainingCents = cardCents
        try bill.attachSandboxCard(accountID: "leader", card: card)
        check(bill.card?.loadedCents == cardCents && bill.status == .cardReady, "Funded merchant-only card attaches")
        rejects("Tips freeze once card is ready") { try bill.setPersonalTip(accountID: "kyle", amountCents: 0) }
        var participantView = bill
        participantView.card = nil
        check(participantView.validationMessage == nil && participantView.status == .cardReady, "Shared bill remains valid without leader's private card")

        var groceries = personalBill(category: .groceries)
        check(groceries.totalTipCents == 0 && groceries.totalCents == 11_110, "Groceries default to zero tip with the same fee")
        try groceries.approve(accountID: "kyle", tipPercent: 20)
        check(groceries.tipShares[groceries.members[1].id] == 1_000, "Nondining participant can choose a tip")
        var custom = personalBill()
        custom.splitMethod = .custom
        custom.members[0].customCents = 2_000
        custom.members[1].customCents = 8_000
        check(custom.validationMessage == nil, "Custom shares cover only the food subtotal")
        check(custom.taxShares[custom.members[0].id] == 200 && custom.taxShares[custom.members[1].id] == 800, "Custom tax follows each food share")
        check(custom.tipShares[custom.members[0].id] == 400 && custom.tipShares[custom.members[1].id] == 1_600, "Custom tips use each food share")
        check(custom.feeShares[custom.members[0].id] == 22 && custom.feeShares[custom.members[1].id] == 88, "Custom fee follows food plus tax")
        check(custom.shares[custom.members[0].id] == 2_622 && custom.shares[custom.members[1].id] == 10_488, "Custom all-in charges remain exact")
        custom.members[1].customCents = 11_110
        check(custom.validationMessage != nil && custom.shares.isEmpty, "Custom shares cannot include tax and fees again")

        var noFood = personalBill()
        noFood.splitMethod = .custom
        noFood.members[0].customCents = 10_000
        noFood.members[1].customCents = 0
        check(noFood.shares[noFood.members[1].id] == 0, "Zero-food participant has no automatic tax tip or fee")
        try noFood.setPersonalTip(accountID: "kyle", amountCents: 123)
        check(noFood.shares[noFood.members[1].id] == 123 && noFood.feeShares[noFood.members[1].id] == 0, "Optional flat tip never changes zero-food fee")

        for cents in 1...500 {
            var itemBill = makeBill(amount: cents)
            itemBill.pricingVersion = 2
            itemBill.splitMethod = .items
            itemBill.items[0].assigneeIDs = itemBill.members.map(\.id)
            itemBill.taxCents = cents / 4
            itemBill.members[1].tipPercent = 0
            itemBill.members[2].tipPercent = 37
            check(itemBill.validationMessage == nil, "Personal shared-item split is valid at small cent amounts")
            check(itemBill.foodShares.values.reduce(0, +) == cents, "Item food allocations conserve cents")
            check(itemBill.taxShares.values.reduce(0, +) == itemBill.taxCents, "Item tax allocations conserve cents")
            check(itemBill.feeCents == (cents + itemBill.taxCents + 50) / 100, "Fee rounds half-up once on total food plus tax")
            check(itemBill.feeShares.values.reduce(0, +) == itemBill.feeCents, "Allocated fees conserve cents")
            check(itemBill.tipShares.values.reduce(0, +) == itemBill.totalTipCents, "Personal tips total exactly")
            check(itemBill.shares.values.reduce(0, +) == itemBill.totalCents, "Final charges conserve every cent")
            let stableFee = itemBill.feeShares
            itemBill.members[1].tipPercent = 100
            check(itemBill.feeShares == stableFee, "Every tested personal tip change leaves exact fee allocation unchanged")
        }
        for (amount, expectedFee) in [(49, 0), (50, 1), (149, 1), (150, 2)] {
            let tiny = personalBill(amount, tax: 0, category: .groceries)
            check(tiny.feeCents == expectedFee, "Half-cent fee boundaries round up")
        }
        var halfTip = personalBill(4, tax: 0)
        try halfTip.setPersonalTip(accountID: "kyle", percent: 25)
        check(halfTip.tipShares[halfTip.members[1].id] == 1, "A person's half-cent tip rounds up independently")

        var invalid = personalBill(Int.max)
        check(invalid.validationMessage != nil && invalid.totalCents == 0 && invalid.shares.isEmpty, "Personal arithmetic rejects oversized input without overflow")
        invalid = personalBill(Bill.maximumCents, tax: 0, category: .groceries)
        check(invalid.validationMessage != nil && invalid.shares.isEmpty, "Maximum includes service fee")
        invalid = personalBill()
        invalid.tipCents = 1_000
        check(invalid.validationMessage != nil, "V2 cannot double-count legacy shared tip")
        invalid = personalBill()
        invalid.members[1].tipPercent = 10
        invalid.members[1].tipOverrideCents = 100
        check(invalid.validationMessage != nil && invalid.shares.isEmpty, "Ambiguous percentage and amount overrides rejected")
        invalid = personalBill()
        invalid.members[1].id = invalid.members[0].id
        check(invalid.validationMessage != nil && invalid.shares.isEmpty, "V2 duplicate IDs do not crash arithmetic")
        invalid = personalBill()
        invalid.pricingVersion = 999
        check(invalid.validationMessage != nil, "Unknown pricing version cannot be approved")

        var legacy = makeBill(amount: 10_000)
        legacy.taxCents = 888
        legacy.tipCents = 2_000
        let original = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(Bill.self, from: original)
        check(decoded.pricingVersion == nil && decoded.groupID == nil && decoded.members.allSatisfy { $0.tipPercent == nil && $0.tipOverrideCents == nil }, "Old bill and member JSON decode without new fields")
        check(decoded.totalCents == 12_888 && decoded.cardAmountCents == 12_888 && decoded.feeCents == 0, "Existing bills preserve original total and zero newly-added fees")
        check(decoded.shares == legacy.shares, "Existing bills preserve exact allocations for durable request retries")
        rejects("Personal edits cannot change a legacy contract") { try legacy.setPersonalTip(accountID: "leader", percent: 25) }

        var recurring = personalBill()
        recurring.groupID = UUID()
        try recurring.approve(accountID: "kyle", tipPercent: 15)
        try recurring.confirm(accountID: "leader")
        check(recurring.card?.loadedCents == recurring.cardAmountCents, "Mock card also excludes the fee")
        try recurring.pay(accountID: "leader")
        check(recurring.history.first?.amountCents == recurring.totalCents, "Payment history includes the separate service fee")
        recurring.recurrence = .monthly
        try recurring.startNextCycle(accountID: "leader")
        check(recurring.members[1].tipPercent == 15 && !recurring.members[1].approved, "Recurring cycle retains personal preference but requires fresh approval")
        let roundTrip = try JSONDecoder().decode(Bill.self, from: JSONEncoder().encode(recurring))
        check(roundTrip.groupID == recurring.groupID && roundTrip.pricingVersion == 2 && roundTrip.shares == recurring.shares, "Group and personal pricing survive JSON round trip")
    }

    static func main() throws {
        check(Money.cents(from: "12.34") == 1234, "Parse cents exactly")
        check(Money.cents(from: "$1,234.5") == 123450, "Parse dollar symbol and grouping")
        check(Money.cents(from: "0.01") == 1, "Single cent")
        for invalid in ["1.234", "12,34.00", "-5", "nan", "1e3", "", "9999999999999999999999999"] {
            check(Money.cents(from: invalid) == nil, "Reject malformed amount \(invalid)")
        }
        check(Money.string(cents: 123456) == "$1,234.56", "Group formatted money")
        check(Money.string(cents: 1) == "$0.01", "Format single cent")

        for total in 1...1000 {
            let bill = makeBill(amount: total)
            check(bill.shares.values.reduce(0, +) == total, "Equal split must conserve every cent")
            check((bill.shares.values.max() ?? 0) - (bill.shares.values.min() ?? 0) <= 1, "Equal splits differ by at most one cent")
        }
        var bill = makeBill(amount: 10001)
        check(bill.validationMessage == nil, "Valid initial bill")
        check(bill.approvedCount == 1, "Leader approves by creating bill")
        check(!bill.allApproved, "Unclaimed participants cannot be approved")
        rejects("Unjoined user cannot approve") { try bill.approve(accountID: "stranger") }
        rejects("Nonleader cannot confirm") { try bill.confirm(accountID: "stranger") }
        rejects("Leader cannot confirm prematurely") { try bill.confirm(accountID: "leader") }

        let alexID = bill.members[1].id
        let samID = bill.members[2].id
        try bill.claim(memberID: alexID, accountID: "alex")
        rejects("An account cannot occupy two member slots") { try bill.claim(memberID: samID, accountID: "alex") }
        rejects("A claimed slot cannot be stolen") { try bill.claim(memberID: alexID, accountID: "stranger") }
        try bill.claim(memberID: samID, accountID: "sam")
        try bill.approve(accountID: "alex")
        try bill.approve(accountID: "sam")
        check(bill.allApproved, "All claimed and approved")
        try bill.confirm(accountID: "leader")
        check(bill.status == .cardReady && bill.card?.loadedCents == 10001, "Card funded exactly once at bill total")
        rejects("No duplicate card confirmation") { try bill.confirm(accountID: "leader") }
        rejects("Participant cannot pay") { try bill.pay(accountID: "alex") }
        try bill.pay(accountID: "leader")
        check(bill.status == .paid && bill.card?.remainingCents == 0 && bill.history.count == 1, "Payment consumes full balance once")
        rejects("No duplicate payment") { try bill.pay(accountID: "leader") }
        rejects("One-time bill cannot recur") { try bill.startNextCycle(accountID: "leader") }
        bill.recurrence = .weekly
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        bill.nextDueDate = date
        rejects("Participant cannot start next cycle") { try bill.startNextCycle(accountID: "alex") }
        try bill.startNextCycle(accountID: "leader")
        check(bill.status == .collecting && bill.cycle == 2 && bill.card == nil, "Fresh recurring cycle")
        check(bill.approvedCount == 1 && !bill.allApproved, "Fresh approvals required every cycle")
        check(bill.nextDueDate == date, "Starting cycle retains its scheduled due date")
        check(bill.history.count == 1, "Prior payment preserved")
        rejects("Cannot confirm next cycle without new approvals") { try bill.confirm(accountID: "leader") }
        try bill.approve(accountID: "alex")
        try bill.approve(accountID: "sam")
        try bill.confirm(accountID: "leader")
        try bill.pay(accountID: "leader")
        check(bill.nextDueDate == date.addingTimeInterval(7 * 24 * 60 * 60), "Paying scheduled cycle advances next due date seven days")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let januaryEnd = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31))!
        let februaryEnd = calendar.date(from: DateComponents(year: 2027, month: 2, day: 28))!
        bill.recurrence = .monthly
        bill.nextDueDate = januaryEnd
        try bill.startNextCycle(accountID: "leader")
        try bill.approve(accountID: "alex")
        try bill.approve(accountID: "sam")
        try bill.confirm(accountID: "leader")
        try bill.pay(accountID: "leader")
        check(bill.nextDueDate == februaryEnd, "Monthly recurrence handles shorter month without skipping it")

        bill = makeBill(amount: 100)
        bill.splitMethod = .custom
        check(bill.validationMessage != nil, "Reject custom totals mismatch")
        bill.members[0].customCents = 40
        bill.members[1].customCents = 40
        bill.members[2].customCents = 20
        check(bill.validationMessage == nil && bill.shares.values.reduce(0, +) == 100, "Accept exact custom totals")
        bill.members[2].customCents = -1
        check(bill.validationMessage != nil, "Reject negative custom amount")

        bill = makeBill(amount: 101)
        bill.splitMethod = .items
        check(bill.validationMessage != nil && bill.shares.isEmpty, "Unassigned items cannot be split")
        bill.items[0].assigneeIDs = bill.members.map(\.id)
        bill.taxCents = 7
        bill.tipCents = 21
        check(bill.validationMessage == nil, "Assigned shared item is valid")
        check(bill.shares.values.reduce(0, +) == 129, "Item split plus proportional tax and tip conserves cents")
        bill.items.append(BillItem(name: "Private item", amountCents: 100, assigneeIDs: [bill.members[0].id]))
        check(bill.shares.values.reduce(0, +) == 229, "Shared and private items conserve cents")
        check((bill.shares[bill.members[0].id] ?? 0) > (bill.shares[bill.members[1].id] ?? 0), "Item owner pays higher proportional extras")
        bill.items[0].assigneeIDs.append(UUID())
        check(bill.validationMessage != nil, "Unknown assignee rejected")

        for cents in 1...500 {
            var itemBill = makeBill(amount: cents)
            itemBill.splitMethod = .items
            itemBill.items[0].assigneeIDs = itemBill.members.map(\.id)
            itemBill.taxCents = cents / 4
            itemBill.tipCents = cents / 5
            check(itemBill.shares.values.reduce(0, +) == itemBill.totalCents, "Proportional allocation conserves cents over many remainders")
        }

        var invalid = makeBill(amount: Int.max)
        check(invalid.validationMessage != nil && invalid.totalCents == 0 && invalid.shares.isEmpty, "Overflow amount safely rejected")
        invalid = makeBill(amount: Bill.maximumCents)
        invalid.taxCents = 1
        check(invalid.validationMessage != nil, "Maximum includes taxes")
        invalid = makeBill()
        invalid.members[1].id = invalid.members[0].id
        check(invalid.validationMessage != nil && invalid.shares.isEmpty, "Duplicate member IDs cannot crash dictionary")
        let encoded = try JSONEncoder().encode(Bill.demo(leaderID: "leader"))
        let decoded = try JSONDecoder().decode(Bill.self, from: encoded)
        check(decoded.totalCents == 12998 && decoded.approvedCount == 1 && decoded.pricingVersion == 2, "Cloud JSON round trip")
        try sandboxChecks()
        try personalPricingChecks()
        print("Passed \(count) domain checks.")
    }
}
