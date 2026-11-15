import Foundation

@main
struct PeopleChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let leader = SavedFriend(id: "leader", name: "Matthew")
        let guest = SavedFriend(id: "guest", name: "Kyle")
        var group = PaymentGroup(name: "Dinner friends", ownerID: leader.id, members: [leader, guest])
        check(group.validationMessage == nil, "Named friends form a valid group")
        let decoded = try JSONDecoder().decode(PaymentGroup.self, from: JSONEncoder().encode(group))
        check(decoded.id == group.id && decoded.members == group.members, "Group membership survives persistence")
        group.members.append(guest)
        check(group.validationMessage != nil, "Duplicate friends are rejected")
        group.members = [guest]
        check(group.validationMessage != nil, "Missing owner is rejected")
        group.members = [leader, SavedFriend(id: "", name: "Not joined")]
        check(group.validationMessage != nil, "Unclaimed names cannot form persistent membership")
        group.members = [leader, guest]
        group.name = "  "
        check(group.validationMessage != nil, "Blank group names are rejected")

        var bill = Bill(title: "Team dinner", items: [BillItem(name: "Dinner", amountCents: 10_000)], taxCents: 1_000,
                        members: [BillMember(name: "Matthew", accountID: "leader"), BillMember(name: "Kyle", accountID: "guest")],
                        leaderID: "leader", pricingVersion: 2)
        let waiting = BillUpdateNotice.make(bill: bill, accountID: "guest")
        check(waiting?.title.contains("$65.55") == true, "Approval request names recipient's full charge including 20% tip and 1% fee")
        check(waiting?.body.contains("personal tip") == true, "Recipient can review their own tip")
        check(BillUpdateNotice.make(bill: bill, accountID: "") == nil, "Signed-out users receive no bill detail")
        check(BillUpdateNotice.make(bill: bill, accountID: "outsider") == nil, "Unrelated accounts receive no claimed bill details")
        try bill.approve(accountID: "guest")
        let approved = BillUpdateNotice.make(bill: bill, accountID: "leader")
        check(approved?.title.contains("Everyone approved") == true, "Leader hears when approval gate is complete")
        check(BillUpdateNotice.make(bill: bill, accountID: "guest") == nil, "An already approved member is not repeatedly asked to pay")
        try bill.confirm(accountID: "leader")
        let leaderNotice = BillUpdateNotice.make(bill: bill, accountID: "leader")
        let guestNotice = BillUpdateNotice.make(bill: bill, accountID: "guest")
        check(leaderNotice?.title.contains("Card ready") == true, "Leader gets status")
        check(guestNotice?.title.contains("Card ready") == true, "Member gets status")
        check(guestNotice?.body.contains("Only the leader") == true, "Member is told who holds the card")
        check(!(guestNotice?.body.contains(bill.card!.lastFour) ?? true), "Member notice contains no card digits")
        bill.card = VirtualCard(lastFour: "9462", loadedCents: bill.cardAmountCents, remainingCents: bill.cardAmountCents,
                                provider: "marqetaSandbox", providerToken: "private-token-probe", providerState: "ACTIVE")
        let projection = BillSharingProjection.redacted(bill)
        let sharedData = try JSONEncoder().encode(projection)
        let sharedJSON = try JSONSerialization.jsonObject(with: sharedData) as! [String: Any]
        let sharedText = String(decoding: sharedData, as: UTF8.self)
        check(sharedJSON["card"] == nil, "Shared serialized bill has no card object")
        check(!sharedText.contains("private-token-probe") && !sharedText.contains("9462"), "Card token and digits never enter the shared payload")
        check(projection.status == .cardReady && projection.allApproved, "Participants retain readiness and approval status")
        check(projection.shares == bill.shares && projection.totalCents == bill.totalCents, "Privacy projection preserves everyone’s amount")
        check(bill.card?.providerToken == "private-token-probe", "Redaction does not mutate the leader's private source")
        bill.card = nil
        check(BillUpdateNotice.make(bill: bill, accountID: "guest") == guestNotice, "Status is independent of private card hydration")
        bill.status = .collecting
        bill.members[1].accountID = nil
        bill.members[1].approved = false
        check(BillUpdateNotice.make(bill: bill, accountID: "guest")?.body.contains("Choose your name") == true,
              "Unclaimed one-off invitation does not invent a recipient amount")
        print("Passed \(checks) people and notification checks.")
    }
}
