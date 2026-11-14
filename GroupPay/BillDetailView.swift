import SwiftUI

struct BillDetailView: View {
    @Environment(AppStore.self) private var store
    let billID: UUID
    @State private var confirmingPayment = false
    @State private var claiming: BillMember?
    private var bill: Bill? { store.bills.first { $0.id == billID } }

    var body: some View {
        ScrollView {
            if let bill {
                VStack(alignment: .leading, spacing: 24) {
                    HStack { Eyebrow(text: bill.category.rawValue); Spacer(); StatusPill(bill: bill) }
                    Text(bill.title).font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Money.string(cents: bill.totalCents)).font(.system(size: 50, weight: .medium, design: .rounded)).tracking(-2)
                        Text("\(bill.members.count) people · \(bill.splitMethod.rawValue) split · USD").font(.subheadline).foregroundStyle(GP.secondary)
                    }
                    stages(bill)
                    if bill.card != nil { VirtualCardView(bill: bill) }
                    actionPanel(bill)
                    Panel {
                        HStack { Text("The group").font(.headline); Spacer(); Text("\(bill.approvedCount) approved").font(.caption).foregroundStyle(GP.secondary) }
                        ForEach(Array(bill.members.enumerated()), id: \.element.id) { index, member in
                            HStack(spacing: 12) {
                                Avatar(name: member.name, index: index, size: 42)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(member.name + (member.accountID == store.accountID && store.connected ? " (you)" : "")).font(.subheadline.bold())
                                    Text(member.approved ? "Approved" : member.accountID == nil ? "Invitation not claimed" : "Awaiting approval")
                                        .font(.caption).foregroundStyle(member.approved ? GP.mint : GP.secondary)
                                }
                                Spacer()
                                Text(Money.string(cents: bill.shares[member.id] ?? 0)).font(.system(.subheadline, design: .rounded, weight: .semibold))
                                Image(systemName: member.approved ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(member.approved ? GP.mint : GP.secondary)
                            }.padding(.vertical, 4)
                        }
                        if isLeader(bill) && bill.status == .collecting {
                            Button { Task { await store.invite(bill) } } label: { Label("Invite people with iCloud", systemImage: "person.badge.plus") }
                                .font(.subheadline.bold()).foregroundStyle(GP.mint).padding(.top, 8).disabled(store.busy)
                            Text("Invite the people listed above. Each person opens the invitation on their own device and chooses their name.").font(.caption).foregroundStyle(GP.secondary)
                        }
                    }
                    Panel {
                        HStack { Text("Receipt").font(.headline); Spacer(); Image(systemName: "receipt").foregroundStyle(GP.secondary) }
                        ForEach(bill.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(item.name).font(.subheadline); Spacer(); Text(Money.string(cents: item.amountCents)).font(.subheadline.monospacedDigit()) }
                                if bill.splitMethod == .items {
                                    Text(bill.members.filter { item.assigneeIDs.contains($0.id) }.map(\.name).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(GP.secondary)
                                }
                            }
                        }
                        Divider()
                        amountRow("Subtotal", bill.subtotalCents)
                        amountRow("Tax", bill.taxCents)
                        amountRow("Tip", bill.tipCents)
                        HStack { Text("Total").bold(); Spacer(); Text(Money.string(cents: bill.totalCents)).bold() }
                    }
                    if bill.recurrence != .none {
                        Panel {
                            Label("\(bill.recurrence.rawValue) split", systemImage: "repeat").font(.headline)
                            if let next = bill.nextDueDate { Text("Next due \(next.formatted(date: .abbreviated, time: .omitted))").font(.subheadline).foregroundStyle(GP.secondary) }
                            Text("Each cycle starts with fresh approvals. The leader starts the next cycle; no card is funded automatically.").font(.caption).foregroundStyle(GP.secondary)
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
                                        Text("Cycle \(payment.cycle) · Simulated payment").font(.subheadline)
                                        Text(payment.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(GP.secondary)
                                    }
                                    Spacer()
                                    Text(Money.string(cents: payment.amountCents)).font(.subheadline.bold()).foregroundStyle(GP.mint)
                                }
                            }
                        }
                    }
                    Text("All amounts and cards are simulated. No funds will leave anyone’s account.").font(.caption).foregroundStyle(GP.secondary)
                }.padding(22)
            } else {
                EmptyPanel(symbol: "icloud", title: "This bill isn’t available.", subtitle: "Refresh your bills or ask the leader for a new invitation.").padding(22)
            }
        }.navigationTitle("Split details").navigationBarTitleDisplayMode(.inline).gpPage()
            .refreshable { await store.refresh() }
            .confirmationDialog("Simulate paying this bill?", isPresented: $confirmingPayment, titleVisibility: .visible) {
                Button("Pay \(Money.string(cents: bill?.totalCents ?? 0)) in simulation") {
                    Task { await store.change(billID) { try $0.pay(accountID: $1) } }
                }
            } message: { Text("This uses the demo card’s balance and records a simulated payment. No real charge will be made.") }
            .confirmationDialog("Join as \(claiming?.name ?? "this person")?", isPresented: Binding(get: { claiming != nil }, set: { if !$0 { claiming = nil } }), titleVisibility: .visible) {
                if let member = claiming {
                    Button("Yes, I’m \(member.name)") {
                        Task { await store.change(billID) { try $0.claim(memberID: member.id, accountID: $1) } }
                        claiming = nil
                    }
                }
            } message: { Text("This links the selected portion to your iCloud account. Choose only your own name.") }
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
    @ViewBuilder private func actionPanel(_ bill: Bill) -> some View {
        if store.isPreview {
            Panel {
                Label("A little look around", systemImage: "eye").font(.headline)
                Text("This sample is read-only. Connect iCloud and create a split to invite real people and collect their approvals.").font(.subheadline).foregroundStyle(GP.secondary)
            }
        } else if bill.status == .paid {
            Panel {
                Label("All settled. Nice teamwork.", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(GP.mint)
                Text("Your simulated payment is complete. The card balance is now zero.").font(.subheadline).foregroundStyle(GP.secondary)
            }
        } else if bill.status == .cardReady {
            Panel {
                Text("The group is good to go.").font(.headline)
                Text("A demo virtual card has been loaded with the exact bill total.").font(.subheadline).foregroundStyle(GP.secondary)
                if isLeader(bill) { Button("Simulate paying the bill") { confirmingPayment = true }.buttonStyle(PrimaryButton()).disabled(store.busy) }
                else { Text("The leader will finish the payment.").font(.caption).foregroundStyle(GP.secondary) }
            }
        } else if let member = bill.members.first(where: { $0.accountID == store.accountID && store.accountID != nil }) {
            Panel {
                Eyebrow(text: "Your part")
                Text(Money.string(cents: bill.shares[member.id] ?? 0)).font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(member.approved ? "You’re in. Your portion is approved." : "Review the receipt and your portion before approving.").font(.subheadline).foregroundStyle(GP.secondary)
                if !member.approved {
                    Button("Approve my \(Money.string(cents: bill.shares[member.id] ?? 0))") {
                        Task { await store.change(bill.id) { try $0.approve(accountID: $1) } }
                    }.buttonStyle(PrimaryButton()).disabled(store.busy)
                }
                if isLeader(bill) {
                    Button { Task { await store.change(bill.id) { try $0.confirm(accountID: $1) } } } label: {
                        Label(store.busy ? "Working…" : "Confirm & create demo card", systemImage: "creditcard")
                    }.buttonStyle(PrimaryButton()).disabled(!bill.allApproved || store.busy)
                    if !bill.allApproved { Text("Everyone must join and approve before you can confirm.").font(.caption).foregroundStyle(GP.secondary) }
                }
            }
        } else {
            Panel {
                Text("Welcome to the group.").font(.headline)
                Text("Choose your name to link your portion to your iCloud account. Joining does not approve the amount.").font(.subheadline).foregroundStyle(GP.secondary)
                ForEach(bill.members.filter { $0.accountID == nil }) { member in
                    Button { claiming = member } label: {
                        HStack { Avatar(name: member.name); Text("I’m \(member.name)"); Spacer(); Text(Money.string(cents: bill.shares[member.id] ?? 0)); Image(systemName: "chevron.right") }
                            .font(.subheadline).foregroundStyle(GP.mint)
                    }.disabled(store.busy)
                }
                if bill.members.allSatisfy({ $0.accountID != nil }) { Text("All portions have been claimed. Contact the leader if your name is missing.").font(.caption).foregroundStyle(GP.amber) }
            }
        }
    }
}
