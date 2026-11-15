import SwiftUI

struct BillDetailView: View {
    @Environment(AppStore.self) private var store
    let billID: UUID
    @State private var confirmingPayment = false
    @State private var claiming: BillMember?
    @State private var tipSelection = TipSelection()
    @ScaledMetric(relativeTo: .largeTitle) private var totalSize = 52.0
    @ScaledMetric(relativeTo: .largeTitle) private var portionSize = 34.0
    private var bill: Bill? { store.bills.first { $0.id == billID } }
    private var tipMember: BillMember? {
        guard let bill else { return nil }
        if store.isPreview { return bill.members.first }
        guard let accountID = store.accountID else { return nil }
        return bill.members.first { $0.accountID == accountID }
    }
    private struct TipStamp: Equatable {
        let memberID: UUID
        let cycle: Int
        let percent: Int?
        let amount: Int?
    }
    private var personalTipStamp: TipStamp? {
        guard let bill, let member = tipMember else { return nil }
        return TipStamp(memberID: member.id, cycle: bill.cycle,
                        percent: member.tipPercent, amount: member.tipOverrideCents)
    }

    var body: some View {
        ScrollView {
            if let bill {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 10) {
                            Label(bill.category.rawValue, systemImage: bill.category.systemImage)
                                .font(.caption.weight(.medium)).foregroundStyle(GP.secondary)
                            Spacer()
                            StatusPill(bill: bill)
                        }
                        Text(bill.title).font(.system(.title, design: .rounded, weight: .semibold)).tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(Money.string(cents: bill.totalCents))
                                .font(.system(size: totalSize, weight: .medium, design: .rounded)).tracking(-2)
                                .minimumScaleFactor(0.7).lineLimit(1)
                            Text("\(bill.members.count) people · \(bill.splitMethod.rawValue) split · USD")
                                .font(.subheadline).foregroundStyle(GP.secondary)
                        }
                    }.padding(.vertical, 8)
                    stages(bill)
                    if isLeader(bill) && bill.card != nil { VirtualCardView(bill: bill) }
                    actionPanel(bill)
                    Panel {
                        HStack {
                            Text("Your group").font(.headline)
                            Spacer()
                            Text("\(bill.approvedCount) of \(bill.members.count) approved")
                                .font(.caption).foregroundStyle(GP.secondary)
                        }
                        ForEach(Array(bill.members.enumerated()), id: \.element.id) { index, member in
                            HStack(spacing: 12) {
                                Avatar(name: member.name, index: index, size: 42)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(member.name + (member.accountID == store.accountID && store.connected ? " (you)" : "")).font(.subheadline.bold())
                                    Text(member.approved ? "Approved" : member.accountID == nil ? "Not joined yet" : "Awaiting approval")
                                        .font(.caption).foregroundStyle(member.approved ? GP.mint : GP.secondary)
                                }
                                Spacer()
                                Text(Money.string(cents: bill.shares[member.id] ?? 0)).font(.system(.subheadline, design: .rounded, weight: .semibold))
                                Image(systemName: member.approved ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(member.approved ? GP.mint : GP.secondary)
                            }.padding(.vertical, 6)
                            if index < bill.members.count - 1 { Divider().overlay(GP.secondary.opacity(0.08)) }
                        }
                        if isLeader(bill) && bill.status == .collecting {
                            Button { Task { await store.invite(bill) } } label: {
                                Label(bill.groupID == nil ? "Invite your group" : "Manage group invitation", systemImage: "person.badge.plus")
                            }.font(.subheadline.bold()).foregroundStyle(GP.mint).padding(.top, 8).disabled(store.busy)
                            Text(bill.groupID == nil
                                 ? "Send an invitation so everyone can join and approve their part."
                                 : "Once your friends accept the group invitation, future bills appear here without another link.")
                                .font(.caption).foregroundStyle(GP.secondary)
                        }
                    }
                    Panel {
                        HStack {
                            Text("Receipt").font(.headline)
                            Spacer()
                            Text("\(bill.items.count) items").font(.caption).foregroundStyle(GP.secondary)
                        }
                        Divider()
                        ForEach(bill.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(item.name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Text(Money.string(cents: item.amountCents)).font(.subheadline.monospacedDigit()).fixedSize()
                                }
                                if bill.splitMethod == .items {
                                    Text(bill.members.filter { item.assigneeIDs.contains($0.id) }.map(\.name).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(GP.secondary)
                                }
                            }
                        }
                        Divider()
                        amountRow("Subtotal", bill.subtotalCents)
                        amountRow("Tax", bill.taxCents)
                        amountRow(bill.usesPersonalPricing ? "Personal tips" : "Tip", bill.totalTipCents)
                        if bill.usesPersonalPricing {
                            amountRow("Group Pay fee · 1%", bill.feeCents)
                        }
                        HStack {
                            Text(bill.usesPersonalPricing ? "Total contributions" : "Total").bold()
                            Spacer()
                            Text(Money.string(cents: bill.totalCents)).bold()
                        }
                        if bill.usesPersonalPricing {
                            amountRow("Amount for the card", bill.cardAmountCents)
                            Text("The card covers the receipt and everyone’s tips. The Group Pay fee is separate and never includes tips.")
                                .font(.caption).foregroundStyle(GP.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if bill.recurrence != .none {
                        Panel {
                            Label("\(bill.recurrence.rawValue) split", systemImage: "repeat").font(.headline)
                            if let next = bill.nextDueDate { Text("Next due \(next.formatted(date: .abbreviated, time: .omitted))").font(.subheadline).foregroundStyle(GP.secondary) }
                            Text("Start each cycle when you’re ready. Everyone reviews and approves again.").font(.caption).foregroundStyle(GP.secondary)
                            if bill.status == .paid && isLeader(bill) {
                                Button("Start next cycle") { Task { await store.change(bill.id) { try $0.startNextCycle(accountID: $1) } } }
                                    .buttonStyle(PrimaryButton()).disabled(store.busy)
                            }
                        }
                    }
                    if !bill.history.isEmpty {
                        Panel {
                            Text("Payment history").font(.headline)
                            ForEach(bill.history) { payment in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Cycle \(payment.cycle) · Test payment").font(.subheadline)
                                        Text(payment.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(GP.secondary)
                                    }
                                    Spacer()
                                    Text(Money.string(cents: payment.amountCents)).font(.subheadline.bold()).foregroundStyle(GP.mint)
                                }
                            }
                        }
                    }
                    Text("Test mode · No real money").font(.caption).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(22)
            } else {
                EmptyPanel(symbol: "icloud", title: "This bill isn’t available.", subtitle: "Refresh your bills or ask the leader for a new invitation.").padding(22)
            }
        }.navigationTitle("Split details").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).gpPage()
            .refreshable { await store.refresh() }
            .onAppear { restorePersonalTip() }
            .onChange(of: personalTipStamp) { _, _ in restorePersonalTip() }
            .confirmationDialog("Make a test payment?", isPresented: $confirmingPayment, titleVisibility: .visible) {
                Button("Pay \(Money.string(cents: bill?.totalCents ?? 0)) in test mode") {
                    Task { await store.change(billID) { try $0.pay(accountID: $1) } }
                }
            } message: { Text("The test card will be marked as spent. No real money will move.") }
            .confirmationDialog("Join as \(claiming?.name ?? "this person")?", isPresented: Binding(get: { claiming != nil }, set: { if !$0 { claiming = nil } }), titleVisibility: .visible) {
                if let member = claiming {
                    Button("Yes, I’m \(member.name)") {
                        Task { await store.change(billID) { try $0.claim(memberID: member.id, accountID: $1) } }
                        claiming = nil
                    }
                }
            } message: { Text("This will be your portion of the bill. You can review it before approving.") }
    }
    private func isLeader(_ bill: Bill) -> Bool { store.connected && bill.leaderID == store.accountID }
    private func amountRow(_ label: String, _ cents: Int) -> some View {
        HStack { Text(label); Spacer(); Text(Money.string(cents: cents)) }.font(.subheadline).foregroundStyle(GP.secondary)
    }
    private func stages(_ bill: Bill) -> some View {
        HStack(spacing: 0) {
            stage("Split", done: true, active: false)
            Rectangle().fill(GP.raised).frame(height: 1)
            stage("Approve", done: bill.allApproved, active: bill.status == .collecting)
            Rectangle().fill(GP.raised).frame(height: 1)
            stage("Pay", done: bill.status == .paid, active: bill.status == .cardReady)
        }.padding(.vertical, 4)
    }
    private func stage(_ title: String, done: Bool, active: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: done ? "checkmark" : active ? "circle.inset.filled" : "circle")
                .font(.caption.bold()).frame(width: 30, height: 30).background(done || active ? GP.mint.opacity(0.12) : GP.surface, in: Circle())
            Text(title).font(.caption)
        }.foregroundStyle(done || active ? GP.mint : GP.secondary).frame(width: 66)
    }
    private func restorePersonalTip() {
        guard let bill, let member = tipMember else { return }
        tipSelection = TipSelection(bill: bill, member: member)
    }

    private func personalTipChanged(_ bill: Bill, member: BillMember) -> Bool {
        let saved = TipSelection(bill: bill, member: member)
        if tipSelection.customAmount != nil, saved.customAmount != nil {
            let food = bill.foodShares[member.id] ?? 0
            return tipSelection.amountCents(foodCents: food) != saved.amountCents(foodCents: food)
        }
        return tipSelection != saved
    }

    private func draftCharge(_ bill: Bill, member: BillMember) -> Int? {
        guard bill.validationMessage == nil,
              let tip = tipSelection.amountCents(foodCents: bill.foodShares[member.id] ?? 0) else { return nil }
        let revisedTotal = bill.totalCents - (bill.tipShares[member.id] ?? 0) + tip
        guard (1...Bill.maximumCents).contains(revisedTotal) else { return nil }
        return (bill.foodShares[member.id] ?? 0) + (bill.taxShares[member.id] ?? 0) + (bill.feeShares[member.id] ?? 0) + tip
    }

    private func personalPortion(_ bill: Bill, member: BillMember, preview: Bool = false) -> some View {
        let charge = draftCharge(bill, member: member)
        let changed = personalTipChanged(bill, member: member)
        return Panel {
            Eyebrow(text: preview ? "Try your portion" : "Your part")
            Text(charge.map { Money.string(cents: $0) } ?? "—")
                .font(.system(size: portionSize, weight: .semibold, design: .rounded))
            if preview {
                Text("Move the tip slider to see your amount change. This sample won’t send an approval or create a card.")
                    .font(.subheadline).foregroundStyle(GP.secondary)
            } else {
                Text(member.approved && !changed ? "Your portion is approved." : "Choose your tip, then approve your total.")
                    .font(.subheadline).foregroundStyle(GP.secondary)
            }
            PersonalTipEditor(foodCents: bill.foodShares[member.id] ?? 0,
                              taxCents: bill.taxShares[member.id] ?? 0,
                              feeCents: bill.feeShares[member.id] ?? 0,
                              selection: $tipSelection, disabled: store.busy)
            if charge == nil {
                Text("Check your tip amount. The full bill must stay within $100,000, including tips and fees.")
                    .font(.caption).foregroundStyle(GP.amber)
            }
            if !preview {
                if !member.approved || changed {
                    Button(member.approved ? "Update approval" : "Approve my \(charge.map { Money.string(cents: $0) } ?? "total")") {
                        let selected = tipSelection
                        Task { await store.approvePortion(bill.id, selection: selected) }
                    }.buttonStyle(PrimaryButton()).disabled(store.busy || charge == nil)
                }
                if isLeader(bill) {
                    confirmationButton(bill, hasTipDraft: changed || charge == nil)
                }
            }
        }
    }

    @ViewBuilder private func confirmationButton(_ bill: Bill, hasTipDraft: Bool = false) -> some View {
        Button { Task { await store.confirmCard(bill.id) } } label: {
            Label(store.busy ? "Working…" : "Confirm & create test card", systemImage: "creditcard")
        }.buttonStyle(PrimaryButton()).disabled(!bill.allApproved || store.busy || hasTipDraft)
        if hasTipDraft {
            Text("Approve your updated tip before creating the card.").font(.caption).foregroundStyle(GP.secondary)
        } else if !bill.allApproved {
            Text("Ready to confirm once everyone has approved.").font(.caption).foregroundStyle(GP.secondary)
        }
    }

    @ViewBuilder private func actionPanel(_ bill: Bill) -> some View {
        if store.isPreview {
            if bill.usesPersonalPricing, bill.status == .collecting, let member = bill.members.first {
                personalPortion(bill, member: member, preview: true)
            } else {
                Panel {
                    Label("A sample split", systemImage: "eye").font(.headline)
                    Text("Explore how a split works. Sign in from Profile to create your own and invite your group.")
                        .font(.subheadline).foregroundStyle(GP.secondary)
                }
            }
        } else if bill.status == .paid {
            Panel {
                Label("All settled", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(GP.mint)
                Text("The test payment is complete. Everyone’s portion is covered.").font(.subheadline).foregroundStyle(GP.secondary)
            }
        } else if bill.status == .issuing {
            Panel {
                Label(isLeader(bill) ? "Creating your test card" : "The leader is creating the card", systemImage: "creditcard")
                    .font(.headline)
                Text("Your group has approved the split. The card will be available only to the leader.")
                    .font(.subheadline).foregroundStyle(GP.secondary)
                if isLeader(bill) {
                    Button(store.busy ? "Working…" : "Resume card creation") { Task { await store.confirmCard(bill.id) } }
                        .buttonStyle(PrimaryButton()).disabled(store.busy)
                }
            }
        } else if bill.status == .cardReady {
            Panel {
                Label(isLeader(bill) ? "Your test card is ready" : "Leader’s card is ready", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(GP.mint)
                if isLeader(bill) {
                    Text("The card covers \(Money.string(cents: bill.cardAmountCents)) for the receipt and tips.")
                        .font(.subheadline).foregroundStyle(GP.secondary)
                    if bill.usesPersonalPricing {
                        Text("The \(Money.string(cents: bill.feeCents)) Group Pay fee is separate from the card.")
                            .font(.caption).foregroundStyle(GP.secondary)
                    }
                    if bill.card?.provider == "marqetaSandbox" {
                        Text("Payments are coming soon. This bill hasn’t been paid.").font(.caption).foregroundStyle(GP.secondary)
                    } else if bill.card != nil {
                        Button("Make a test payment") { confirmingPayment = true }
                            .buttonStyle(PrimaryButton()).disabled(store.busy)
                    } else {
                        Text("Pull to refresh to load your private card details.").font(.caption).foregroundStyle(GP.secondary)
                    }
                } else {
                    Text("Only the leader can view and use the test card. Your approval is saved.")
                        .font(.subheadline).foregroundStyle(GP.secondary)
                    Text("This bill hasn’t been paid yet.").font(.caption).foregroundStyle(GP.secondary)
                }
            }
        } else if let member = bill.members.first(where: { $0.accountID == store.accountID && store.accountID != nil }) {
            if bill.usesPersonalPricing {
                personalPortion(bill, member: member)
            } else {
                Panel {
                    Eyebrow(text: "Your part")
                    Text(Money.string(cents: bill.shares[member.id] ?? 0))
                        .font(.system(size: portionSize, weight: .semibold, design: .rounded))
                    Text(member.approved ? "Your portion is approved." : "Review the receipt and approve your portion.")
                        .font(.subheadline).foregroundStyle(GP.secondary)
                    if !member.approved {
                        Button("Approve my \(Money.string(cents: bill.shares[member.id] ?? 0))") {
                            Task { await store.change(bill.id) { try $0.approve(accountID: $1) } }
                        }.buttonStyle(PrimaryButton()).disabled(store.busy)
                    }
                    if isLeader(bill) { confirmationButton(bill) }
                    Text("This existing bill keeps its original agreed amounts.").font(.caption).foregroundStyle(GP.secondary)
                }
            }
        } else {
            Panel {
                Text("Which portion is yours?").font(.headline)
                Text("Choose your name, then review your part before approving.").font(.subheadline).foregroundStyle(GP.secondary)
                ForEach(bill.members.filter { $0.accountID == nil }) { member in
                    Button { claiming = member } label: {
                        HStack {
                            Avatar(name: member.name)
                            Text("I’m \(member.name)")
                            Spacer()
                            Text(Money.string(cents: bill.shares[member.id] ?? 0))
                            Image(systemName: "chevron.right")
                        }.font(.subheadline).foregroundStyle(GP.mint)
                    }.disabled(store.busy)
                }
                if bill.members.allSatisfy({ $0.accountID != nil }) {
                    Text("Everyone has joined. Ask the leader if your name is missing.").font(.caption).foregroundStyle(GP.amber)
                }
            }
        }
    }
}
