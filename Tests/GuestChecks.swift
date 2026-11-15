import Foundation

@main
@MainActor
enum GuestChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); count += 1
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { count += 1 }
    }
    static func main() throws {
        var bill = Bill(title: "Guest dinner", items: [BillItem(name: "Meal", amountCents: 2001)],
                        taxCents: 160, members: [BillMember(name: "Leader", accountID: "leader"), BillMember(name: "Alex")],
                        leaderID: "leader", recurrence: .weekly, pricingVersion: 2)
        let memberID = bill.members[1].id
        rejects { try bill.inviteGuest(memberID: memberID, accountID: "stranger", baseURL: "https://example.test") }
        try bill.inviteGuest(memberID: memberID, accountID: "leader", baseURL: "https://example.test")
        let invitation = bill.members[1].guestInvitation!
        check(invitation.portion.foodCents == 1000, "Odd cents use native allocation")
        check(invitation.portion.feeCents == bill.feeShares[memberID], "Fee is fixed from allocation")
        check(!bill.allApproved, "Creating a link is not approval")
        rejects { try bill.claim(memberID: memberID, accountID: "app-user") }
        rejects { try bill.inviteGuest(memberID: memberID, accountID: "leader", baseURL: "https://example.test") }
        let approval = GuestApproval(portion: invitation.portion, approvedTipCents: 333, closed: false, expired: false, token: nil)
        let saved = try JSONDecoder().decode(Bill.self, from: JSONEncoder().encode(bill))
        check(saved.members[1].guestInvitation?.portion == invitation.portion, "Reservation survives persistence")
        rejects { try bill.applyGuestApproval(approval, accountID: "stranger") }
        try bill.applyGuestApproval(approval, accountID: "leader")
        check(bill.allApproved, "Guest can complete the group")
        check(bill.tipShares[memberID] == 333, "Exact guest tip imports")
        check(bill.shares[memberID] == invitation.portion.foodCents + invitation.portion.taxCents + invitation.portion.feeCents + 333, "Exact approved total imports")
        try bill.applyGuestApproval(approval, accountID: "leader")
        check(bill.tipShares[memberID] == 333, "Replayed approval is idempotent")
        rejects { try bill.applyGuestApproval(GuestApproval(portion: invitation.portion, approvedTipCents: 444, closed: false, expired: false, token: nil), accountID: "leader") }
        var changed = saved
        changed.taxCents += 100
        rejects { try changed.applyGuestApproval(approval, accountID: "leader") }
        var expired = saved
        try expired.applyGuestApproval(GuestApproval(portion: invitation.portion, approvedTipCents: 333, closed: false, expired: true, token: nil), accountID: "leader")
        check(expired.allApproved, "Final approval remains recoverable after link expiry")
        var removed = saved
        try removed.removeGuestInvitation(memberID: memberID, invitationID: invitation.portion.invitationID, accountID: "leader")
        check(removed.members[1].accountID == nil && removed.members[1].guestInvitation == nil, "Revocation frees the portion for the app")
        rejects { try removed.applyGuestApproval(approval, accountID: "leader") }
        try removed.inviteGuest(memberID: memberID, accountID: "leader", baseURL: "https://example.test")
        check(removed.members[1].guestInvitation?.portion.invitationID != invitation.portion.invitationID, "Replacement has a fresh capability")
        rejects { try removed.applyGuestApproval(approval, accountID: "leader") }
        try bill.confirm(accountID: "leader")
        rejects { try bill.applyGuestApproval(approval, accountID: "leader") }
        try bill.pay(accountID: "leader")
        try bill.startNextCycle(accountID: "leader")
        check(bill.members[1].guestInvitation == nil && bill.members[1].accountID == nil && !bill.allApproved, "New cycle requires a fresh guest invitation")
        rejects { try bill.applyGuestApproval(approval, accountID: "leader") }
        var legacy = saved
        legacy.pricingVersion = nil
        legacy.members[1].guestInvitation = nil
        legacy.members[1].accountID = nil
        rejects { try legacy.inviteGuest(memberID: memberID, accountID: "leader", baseURL: "https://example.test") }
        print("Passed \(count) guest domain checks.")
    }
}
