import Foundation

/// Only this projection is serialized into a shared CloudKit bill. Card
/// metadata belongs in a separate, unshared record in the leader's database.
enum BillSharingProjection {
    static func redacted(_ bill: Bill) -> Bill {
        var result = bill
        result.card = nil
        return result
    }
}

struct CloudWorkspace: Sendable {
    var bills: [Bill]
    var friends: [SavedFriend]
    var groups: [PaymentGroup]
}

/// A saved, previously joined iCloud identity. This address book stays private.
struct SavedFriend: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String

    var accountID: String { id }
}

/// One private invitation grants access to this group's future child bills.
/// Membership is fixed for this version; create a new group for a different set.
struct PaymentGroup: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var ownerID: String
    var members: [SavedFriend]
    var createdAt: Date = Date()

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 {
            return "Give your group a name of up to 100 characters."
        }
        if members.count < 2 || members.count > 50 { return "Choose between 2 and 50 people, including yourself." }
        if ownerID.isEmpty || members.filter({ $0.id == ownerID }).count != 1 {
            return "The group must include its organizer."
        }
        if Set(members.map(\.id)).count != members.count { return "Each friend can join the group once." }
        if members.contains(where: {
            $0.id.isEmpty || $0.id.count > 256 || $0.id != $0.id.trimmingCharacters(in: .whitespacesAndNewlines) ||
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.count > 100
        }) { return "Each person needs a name and a connected iCloud account." }
        return nil
    }
}

/// Notification copy contains the recipient's payable amount, never card details.
struct BillUpdateNotice: Equatable, Sendable {
    let title: String
    let body: String

    static func make(bill: Bill, accountID: String) -> BillUpdateNotice? {
        guard !accountID.isEmpty else { return nil }
        let member = bill.members.first { $0.accountID == accountID }
        let isLeader = bill.leaderID == accountID
        switch bill.status {
        case .collecting:
            if let member, !member.approved {
                let amount = Money.string(cents: bill.shares[member.id] ?? 0)
                let detail = bill.pricingVersion == 2 && bill.category == .dining
                    ? "Review your food, tax, personal tip, and 1% fee before approving."
                    : "Review your portion before approving."
                return BillUpdateNotice(title: "\(bill.title) · Your part is \(amount)", body: detail)
            }
            if isLeader {
                return BillUpdateNotice(title: bill.allApproved ? "Everyone approved \(bill.title)" : "\(bill.title) · Approval update",
                                        body: bill.allApproved ? "Your group is ready. Open Group Pay to create the test card." : "\(bill.approvedCount) of \(bill.members.count) people have approved.")
            }
            if member == nil, bill.members.contains(where: { $0.accountID == nil }) {
                return BillUpdateNotice(title: "You’re invited to \(bill.title)", body: "Choose your name to see your portion, adjust your tip, and approve.")
            }
            return nil
        case .issuing:
            return nil
        case .cardReady:
            guard member != nil || isLeader else { return nil }
            return BillUpdateNotice(title: "\(bill.title) · Card ready",
                                    body: isLeader ? "Your test card is ready in Group Pay." : "The group’s test card is ready. Only the leader can view and use it.")
        case .paid:
            guard member != nil || isLeader else { return nil }
            return BillUpdateNotice(title: "\(bill.title) · All settled", body: "The test payment is complete. No real money moved.")
        }
    }
}
