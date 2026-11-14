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
        check(decoded.totalCents == 12888 && decoded.approvedCount == 1, "Cloud JSON round trip")
        print("Passed \(count) domain checks.")
    }
}
