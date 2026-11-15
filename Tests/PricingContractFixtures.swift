import Foundation

@main
enum PricingContractFixtures {
    struct Fixture: Encodable {
        let name: String
        let expectedChargeCents: Int
        let expectedCardCents: Int
        let expectedFeeCents: Int
        let payload: SandboxIssuanceRequest
    }

    static func people(_ count: Int) -> [BillMember] {
        (0..<count).map { index in
            BillMember(name: "Person \(index)", accountID: "fixture-person-\(index)", approved: true)
        }
    }

    static func main() throws {
        var fixtures: [Fixture] = []
        func add(_ name: String, _ bill: Bill) throws {
            if let message = bill.validationMessage { throw BillError("\(name): \(message)") }
            guard bill.allApproved else { throw BillError("\(name): not approved") }
            fixtures.append(Fixture(name: name, expectedChargeCents: bill.totalCents,
                                    expectedCardCents: bill.cardAmountCents, expectedFeeCents: bill.feeCents,
                                    payload: SandboxIssuanceRequest(bill: bill)))
        }

        // The exact legacy fixture already used by the backend has a pinned digest.
        let legacyMembers = [BillMember(name: "Leader", accountID: "leader-private-account", customCents: 500, approved: true),
                             BillMember(name: "Guest", accountID: "guest-private-account", customCents: 501, approved: true)]
        let legacy = Bill(id: UUID(uuidString: "8800755C-AE74-4510-93AE-A10A6C28EDFE")!, title: "Legacy",
                          items: [BillItem(name: "Dinner", amountCents: 1001)], splitMethod: .custom,
                          members: legacyMembers, leaderID: "leader-private-account")
        try add("legacy-digest", legacy)

        let amounts = [1, 49, 50, 99, 101, 1001, 9999, 50_000]
        let taxes = [0, 1, 7, 825]
        for subtotal in amounts {
            for tax in taxes {
                for count in [2, 3, 7] {
                    var members = people(count)
                    let common = "\(subtotal)-\(tax)-\(count)"
                    var equal = Bill(title: "Equal", items: [BillItem(name: "Meal", amountCents: subtotal)], taxCents: tax,
                                     members: members, leaderID: "fixture-person-0", pricingVersion: 2)
                    try add("equal-default-" + common, equal)
                    // Exercise the actual mutation path before the exact same wire encoder.
                    try equal.setPersonalTip(accountID: "fixture-person-0", percent: 0)
                    try equal.approve(accountID: "fixture-person-0")
                    try add("equal-no-leader-tip-" + common, equal)
                    try equal.setPersonalTip(accountID: "fixture-person-1", amountCents: 17)
                    try equal.approve(accountID: "fixture-person-1")
                    try add("equal-exact-tip-" + common, equal)

                    // Zero-valued custom portions must not be assigned someone else's tax/fee.
                    members[0].customCents = 0
                    members[0].tipOverrideCents = 51
                    members[count-1].customCents = subtotal
                    members[count-1].tipPercent = 35
                    let custom = Bill(title: "Custom", items: [BillItem(name: "Meal", amountCents: subtotal)], taxCents: tax,
                                      splitMethod: .custom, members: members, leaderID: "fixture-person-0", pricingVersion: 2)
                    try add("custom-zero-and-exact-tip-" + common, custom)

                    var grocery = equal
                    grocery.category = .groceries
                    for index in grocery.members.indices {
                        grocery.members[index].tipPercent = nil
                        grocery.members[index].tipOverrideCents = nil
                    }
                    try add("groceries-default-" + common, grocery)
                }
            }
        }

        var members = people(3)
        members[1].tipPercent = 0
        members[2].tipOverrideCents = 179
        let itemBill = Bill(title: "Shared items", items: [
            BillItem(name: "Bread", amountCents: 1001, assigneeIDs: members.map(\.id)),
            BillItem(name: "Main", amountCents: 2499, assigneeIDs: [members[0].id]),
            BillItem(name: "Salad", amountCents: 1234, assigneeIDs: [members[1].id]),
            BillItem(name: "Coffee", amountCents: 501, assigneeIDs: [members[2].id]),
            BillItem(name: "Shared dessert", amountCents: 333, assigneeIDs: [members[0].id, members[2].id])
        ], taxCents: 471, splitMethod: .items, members: members, leaderID: "fixture-person-0", pricingVersion: 2)
        try add("item-shared-odd-cents", itemBill)
        var reversed = itemBill
        reversed.members.reverse()
        try add("item-reversed-member-order", reversed)

        // A hand-calculated check: $100 food + $8.25 tax + $20 tips + $1.08 fee.
        let handChecked = Bill(title: "Known total", items: [BillItem(name: "Dinner", amountCents: 10_000)], taxCents: 825,
                               members: people(2), leaderID: "fixture-person-0", pricingVersion: 2)
        guard handChecked.cardAmountCents == 12_825, handChecked.feeCents == 108,
              handChecked.totalCents == 12_933 else { throw BillError("Known-total regression") }
        try add("known-total", handChecked)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(fixtures))
    }
}
