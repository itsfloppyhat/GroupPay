import Foundation

/// The wire contract is shared by the app and the offline cross-language checks.
/// Legacy bills omit every v2 field so their durable backend identity is unchanged.
struct SandboxIssuanceRequest: Encodable {
    struct Member: Encodable {
        let accountID: String
        let approved: Bool
        let shareCents: Int
        let foodCents: Int?
        let taxCents: Int?
        let tipCents: Int?
        let feeCents: Int?
    }

    let billID: String
    let cycle: Int
    let amountCents: Int
    let currency: String
    let leaderID: String
    let members: [Member]
    let pricingVersion: Int?
    let subtotalCents: Int?
    let taxCents: Int?
    let tipCents: Int?
    let feeCents: Int?

    init(bill: Bill) {
        let personalPricing = bill.usesPersonalPricing
        let food = bill.foodShares
        let taxes = bill.taxShares
        let tips = bill.tipShares
        let fees = bill.feeShares
        let charges = bill.shares
        billID = bill.id.uuidString
        cycle = bill.cycle
        amountCents = bill.cardAmountCents
        currency = "USD"
        leaderID = bill.leaderID
        members = bill.members.map {
            Member(accountID: $0.accountID ?? "", approved: $0.approved,
                   shareCents: charges[$0.id] ?? 0,
                   foodCents: personalPricing ? food[$0.id] : nil,
                   taxCents: personalPricing ? taxes[$0.id] : nil,
                   tipCents: personalPricing ? tips[$0.id] : nil,
                   feeCents: personalPricing ? fees[$0.id] : nil)
        }
        pricingVersion = personalPricing ? 2 : nil
        subtotalCents = personalPricing ? bill.subtotalCents : nil
        taxCents = personalPricing ? bill.taxCents : nil
        tipCents = personalPricing ? bill.totalTipCents : nil
        feeCents = personalPricing ? bill.feeCents : nil
    }
}
