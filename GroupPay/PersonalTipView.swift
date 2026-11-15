import SwiftUI

struct TipSelection: Equatable {
    var percent = 20
    var customAmount: String?

    init(percent: Int = 20, customAmount: String? = nil) {
        self.percent = percent
        self.customAmount = customAmount
    }

    init(bill: Bill, member: BillMember) {
        percent = member.tipPercent ?? (bill.category == .dining ? 20 : 0)
        if let amount = member.tipOverrideCents {
            customAmount = Self.decimal(amount)
        }
    }

    func amountCents(foodCents: Int) -> Int? {
        if let customAmount {
            guard let amount = Money.cents(from: customAmount), amount <= Bill.maximumCents else { return nil }
            return amount
        }
        guard (0...100).contains(percent), (0...Bill.maximumCents).contains(foodCents) else { return nil }
        return (foodCents * percent + 50) / 100
    }

    static func decimal(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, cents % 100) }
}

struct PersonalTipEditor: View {
    let foodCents: Int
    let taxCents: Int
    let feeCents: Int
    @Binding var selection: TipSelection
    var disabled = false

    private var tip: Int? { selection.amountCents(foodCents: foodCents) }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Your tip").font(.headline)
                Spacer()
                Text(tip.map { Money.string(cents: $0) } ?? "—")
                    .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(GP.mint)
            }
            if selection.customAmount == nil {
                HStack {
                    Text("\(selection.percent)%").font(.system(.title2, design: .rounded, weight: .semibold))
                    Spacer()
                    Text("of your \(Money.string(cents: foodCents)) subtotal").font(.caption).foregroundStyle(GP.secondary)
                }
                Slider(value: Binding(get: { Double(selection.percent) }, set: { selection.percent = Int($0) }), in: 0...100, step: 1)
                    .tint(GP.mint).accessibilityLabel("Your tip percentage")
                    .accessibilityValue("\(selection.percent) percent")
                HStack(spacing: 10) {
                    ForEach([0, 15, 20, 25], id: \.self) { percent in
                        Button { selection.percent = percent } label: {
                            Text("\(percent)%").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(selection.percent == percent ? GP.background : GP.mint)
                                .background(selection.percent == percent ? GP.mint : GP.raised, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(selection.percent == percent ? .isSelected : [])
                    }
                }
                Button("Enter a tip amount") { selection.customAmount = TipSelection.decimal(tip ?? 0) }
                    .font(.subheadline).foregroundStyle(GP.mint).frame(minHeight: 44)
            } else {
                TextField("Tip amount", text: Binding(get: { selection.customAmount ?? "" }, set: { selection.customAmount = $0 }))
                    .keyboardType(.decimalPad).gpField().accessibilityLabel("Your tip amount in dollars")
                Button("Use a percentage") { selection.customAmount = nil }
                    .font(.subheadline).foregroundStyle(GP.mint).frame(minHeight: 44)
            }
            Divider()
            price("Your subtotal", foodCents)
            price("Tax", taxCents)
            price("Group Pay fee · 1%", feeCents)
            Text("The fee is based on your subtotal plus tax. Changing your tip won’t change it.")
                .font(.caption).foregroundStyle(GP.secondary).fixedSize(horizontal: false, vertical: true)
            if let tip {
                HStack {
                    Text("You approve").font(.headline)
                    Spacer()
                    Text(Money.string(cents: foodCents + taxCents + feeCents + tip))
                        .font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(GP.mint)
                }.padding(.top, 4)
            } else {
                Text("Enter a valid tip amount.").font(.caption).foregroundStyle(GP.amber)
            }
        }.disabled(disabled)
    }

    private func price(_ title: String, _ cents: Int) -> some View {
        HStack { Text(title); Spacer(); Text(Money.string(cents: cents)).monospacedDigit() }
            .font(.subheadline).foregroundStyle(GP.secondary)
    }
}
