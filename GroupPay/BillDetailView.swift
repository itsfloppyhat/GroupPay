import SwiftUI

struct BillDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let billID: UUID
    @State private var confirmingPayment = false
    @State private var confirmingCancellation = false
    @State private var claiming: BillMember?
    @State private var guestShare: GuestShare?
    @State private var showingInvitations = false
    @State private var inviteMemberID: UUID?
    @State private var pendingAppInvite = false
    @State private var removingGuest: BillMember?
    private struct GuestShare { let url: URL; let name: String }
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
                                .font(GP.body(12, weight: .medium, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            Spacer()
                            StatusPill(bill: bill)
                        }
                        Text(bill.title).font(GP.display(30)).tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 9) {
                            if bill.status == .cancelled {
                                Text("Original split total").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                            Text(Money.string(cents: bill.totalCents))
                                .font(.custom("Caprasimo-Regular", fixedSize: totalSize)).contentTransition(.numericText()).gpAnimate(bill.totalCents).tracking(-2)
                                .minimumScaleFactor(0.7).lineLimit(1)
                            Text("\(bill.members.count) people · \(bill.splitMethod.rawValue) split · USD")
                                .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                        }
                    }.padding(.vertical, 8)
                    if bill.status != .cancelled { stages(bill) }
                    if bill.status != .cancelled && isLeader(bill) && bill.card != nil { VirtualCardView(bill: bill) }
                    actionPanel(bill)
                    Panel {
                        HStack {
                            Text("Your group").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            Spacer()
                            Text(bill.status == .cancelled ? "Closed" : "\(bill.approvedCount) of \(bill.members.count) approved")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                        ForEach(Array(bill.members.enumerated()), id: \.element.id) { index, member in
                            if isLeader(bill), bill.status == .collecting, member.accountID != bill.leaderID {
                                Button {
                                    openInvitations(for: member.id)
                                } label: {
                                    memberRow(bill, member: member, index: index, canOpen: true)
                                }.buttonStyle(.plain).disabled(store.busy)
                                    .accessibilityHint("Open invitation options for \(member.name)")
                                    .accessibilityIdentifier("inviteMember-" + member.id.uuidString)
                            } else {
                                memberRow(bill, member: member, index: index, canOpen: false)
                            }
                            if index < bill.members.count - 1 { Divider().overlay(GP.secondary.opacity(0.08)) }
                        }
                        if isLeader(bill) && bill.status == .collecting {
                            Button { openInvitations() } label: {
                                Label("Invite your group", systemImage: "person.badge.plus")
                            }.buttonStyle(PrimaryButton()).disabled(store.busy)
                                .accessibilityIdentifier("inviteYourGroup")
                            Text("Choose a person to send their own web link, or invite people who have the app. You can also tap a name above.")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                    }
                    Panel {
                        HStack {
                            Text("Receipt").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            Spacer()
                            Text("\(bill.items.count) items").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                        Divider()
                        ForEach(bill.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(item.name).font(GP.body(15, weight: .regular, relativeTo: .subheadline)).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Text(Money.string(cents: item.amountCents)).font(.subheadline.monospacedDigit()).fixedSize()
                                }
                                if bill.splitMethod == .items {
                                    Text(bill.members.filter { item.assigneeIDs.contains($0.id) }.map(\.name).joined(separator: ", "))
                                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
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
                            Text(bill.status == .cancelled ? "Original total" : bill.usesPersonalPricing ? "Total contributions" : "Total").bold()
                            Spacer()
                            Text(Money.string(cents: bill.totalCents)).bold()
                        }
                        if bill.usesPersonalPricing {
                            amountRow(bill.status == .cancelled ? "Original card amount" : "Amount for the card", bill.cardAmountCents)
                            Text(bill.status == .cancelled
                                 ? "These amounts are kept for reference. This split was cancelled before a card was created."
                                 : "The card covers the receipt and everyone’s tips. The Group Pay fee is separate and never includes tips.")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if bill.recurrence != .none && bill.status != .cancelled {
                        Panel {
                            Label("\(bill.recurrence.rawValue) split", systemImage: "repeat").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            if let next = bill.nextDueDate { Text("Next due \(next.formatted(date: .abbreviated, time: .omitted))").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary) }
                            Text("Start each cycle when you’re ready. Everyone reviews and approves again.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            if bill.status == .paid && isLeader(bill) {
                                Button("Start next cycle") { Task { await store.change(bill.id) { try $0.startNextCycle(accountID: $1) } } }
                                    .buttonStyle(PrimaryButton()).disabled(store.busy)
                            }
                        }
                    }
                    if !bill.history.isEmpty {
                        Panel {
                            Text("Payment history").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            ForEach(bill.history) { payment in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Cycle \(payment.cycle) · Test payment").font(GP.body(15, weight: .regular, relativeTo: .subheadline))
                                        Text(payment.date.formatted(date: .abbreviated, time: .shortened)).font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                                    }
                                    Spacer()
                                    Text(Money.string(cents: payment.amountCents)).font(GP.body(15, weight: .bold, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                                }
                            }
                        }
                    }
                    Text("Test mode · No real money").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(22)
            } else {
                EmptyPanel(symbol: "icloud", title: "This bill isn’t available.", subtitle: "Refresh your bills or ask the leader for a new invitation.").padding(22)
            }
        }.navigationTitle("Split details").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).gpPage()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let bill, canCancel(bill) {
                        Button("Cancel split", role: .destructive) { confirmingCancellation = true }
                            .font(GP.body(15, weight: .medium, relativeTo: .subheadline)).disabled(store.busy)
                            .accessibilityIdentifier("cancelSplit")
                    }
                }
            }
            .sheet(isPresented: $showingInvitations, onDismiss: {
                guestShare = nil
                inviteMemberID = nil
                if pendingAppInvite {
                    pendingAppInvite = false
                    if let bill { Task { await store.invite(bill) } }
                }
            }) {
                invitationSheet
            }
            .refreshable { await store.refresh() }
            .onAppear { restorePersonalTip() }
            .onChange(of: personalTipStamp) { _, _ in restorePersonalTip() }
            .confirmationDialog("Cancel this split?", isPresented: $confirmingCancellation, titleVisibility: .visible) {
                Button("Cancel split", role: .destructive) {
                    Task { if await store.cancelSplit(billID) { dismiss() } }
                }
                Button("Keep split", role: .cancel) { }
            } message: {
                Text("This removes the split from everyone’s active bills. No one can approve it or create a card. A cancelled record and any earlier payment history are kept.")
            }
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
    private func openInvitations(for memberID: UUID? = nil) {
        guestShare = nil
        inviteMemberID = memberID
        showingInvitations = true
    }

    private func memberRow(_ bill: Bill, member: BillMember, index: Int, canOpen: Bool) -> some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, index: index, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(member.name + (member.accountID == store.accountID && store.connected ? " (you)" : ""))
                    .font(GP.body(15, weight: .bold, relativeTo: .subheadline)).foregroundStyle(GP.text)
                Text(bill.status == .cancelled ? "No payment due" : member.approved ? "Approved" : member.guestInvitation != nil ? "Web guest · awaiting approval" : member.accountID == nil ? (canOpen ? "Not joined · tap to invite" : "Not joined yet") : "In app · awaiting approval")
                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(bill.status != .cancelled && member.approved ? GP.sage : GP.secondary)
            }
            Spacer()
            Text(Money.string(cents: bill.shares[member.id] ?? 0))
                .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(GP.text)
            AnimatedSymbol(name: bill.status == .cancelled ? "minus.circle" : member.approved ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(bill.status != .cancelled && member.approved ? GP.sage : GP.secondary)
            if canOpen {
                Image(systemName: "chevron.right").font(GP.body(12, weight: .bold, relativeTo: .caption)).foregroundStyle(GP.secondary)
            }
        }.gpAnimate(member.approved).padding(.vertical, 6).frame(minHeight: 54).contentShape(Rectangle())
    }

    private var invitationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let bill, isLeader(bill), bill.status == .collecting {
                        if let share = guestShare {
                            guestLinkPanel(share)
                        } else {
                            invitationOptions(bill)
                        }
                    } else {
                        EmptyPanel(symbol: "person.2", title: "Invitations are closed", subtitle: "Return to the split to check its current status.")
                    }
                }.padding(22)
            }.gpPage().navigationTitle(guestShare.map { "Web link for \($0.name)" } ?? "Invite your group")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingInvitations = false }.disabled(store.busy)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        if guestShare != nil || inviteMemberID != nil {
                            Button("All people") { guestShare = nil; inviteMemberID = nil }.disabled(store.busy)
                        }
                    }
                }
                .confirmationDialog("Remove this guest link?", isPresented: Binding(get: { removingGuest != nil }, set: { if !$0 { removingGuest = nil } }), titleVisibility: .visible) {
                    if let member = removingGuest {
                        Button("Remove link and approval", role: .destructive) {
                            Task { await store.removeGuestLink(billID: billID, memberID: member.id) }
                            removingGuest = nil
                        }
                    }
                } message: {
                    Text("The old link will close and this portion will need a new approval. You can send a fresh web link or let this person join in the app.")
                }
        }.preferredColorScheme(.light).tint(GP.mint).interactiveDismissDisabled(store.busy)
    }

    @ViewBuilder private func invitationOptions(_ bill: Bill) -> some View {
        Text("How will they join?").font(.title2.bold())
        Text("For someone without the app, choose their name below. Each web link belongs to that person’s portion.")
            .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
        ForEach(bill.members.filter { $0.accountID != bill.leaderID && (inviteMemberID == nil || $0.id == inviteMemberID) }) { member in
            Panel {
                HStack {
                    Avatar(name: member.name)
                    Text(member.name).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                    Spacer()
                    Text(Money.string(cents: bill.shares[member.id] ?? 0)).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                }
                if bill.usesPersonalPricing, member.accountID == nil || member.guestInvitation != nil {
                    Label("Web browser · No app needed", systemImage: "safari").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                    Text("Only \(member.name)’s portion opens from this link.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    Button {
                        Task {
                            if let url = await store.guestLink(billID: bill.id, memberID: member.id) {
                                guestShare = GuestShare(url: url, name: member.name)
                            }
                        }
                    } label: {
                        Label(store.busy ? "Preparing link…" : "Send web link to \(member.name)", systemImage: "square.and.arrow.up")
                    }.buttonStyle(PrimaryButton()).disabled(store.busy)
                        .accessibilityIdentifier("sendWebLink-" + member.id.uuidString)
                    if member.guestInvitation != nil {
                        Text(member.approved ? "Approved on the web" : "Web link created · awaiting approval")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        Button("Remove \(member.name)’s web link", role: .destructive) { removingGuest = member }
                            .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).disabled(store.busy)
                    }
                } else if member.accountID != nil {
                    Label(member.approved ? "Approved in the app" : "Already joined in the app", systemImage: "iphone")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    Text("This portion is assigned to their account. They can open the split and approve it in Group Pay.")
                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                } else {
                    Text("This older split uses app invitations. Create a new split to send personal web links.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                }
            }
        }
        Panel {
            Label("Have the Group Pay app?", systemImage: "iphone").font(GP.body(17, weight: .semibold, relativeTo: .headline))
            Text(bill.groupID == nil
                 ? "The app invitation gives access to this split. Each person chooses their own name after joining; it is not a personal web link."
                 : "The group invitation gives access to this saved group and its bills. It is not a personal web link.")
                .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            Button(bill.groupID == nil ? "Send app invitation" : "Manage app group invitation") {
                pendingAppInvite = true
                showingInvitations = false
            }.font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(store.busy)
            Text("Already sent an app invitation? You can still send a named web link above if that person hasn’t claimed a portion.")
                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
        }
        if let error = store.error {
            Text(error).font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.amber)
        }
    }

    private func guestLinkPanel(_ share: GuestShare) -> some View {
        Panel {
            Label("Web link for \(share.name)", systemImage: "safari").font(.title2.bold())
            Text("This link is assigned to \(share.name)’s portion. Send it to \(share.name) in the share sheet.")
                .font(GP.body(15, weight: .regular, relativeTo: .subheadline))
            Text("They can review their amount, choose a tip, and approve in their browser. No download or account needed.")
                .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            ShareLink(item: share.url, subject: Text("\(share.name)’s Group Pay portion"),
                      message: Text("Hi \(share.name), this is your personal Group Pay web link. Open it in your browser to review your portion, choose your tip, and approve. No app needed. Test mode — no real money moves.")) {
                Label("Share \(share.name)’s web link", systemImage: "square.and.arrow.up")
            }.buttonStyle(PrimaryButton())
            Text("Valid for 7 days. Anyone with this link can approve \(share.name)’s portion, so send it only to them. Their approval appears when your app refreshes.")
                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
        }
    }

    private func isLeader(_ bill: Bill) -> Bool { store.connected && bill.leaderID == store.accountID }
    private func canCancel(_ bill: Bill) -> Bool {
        isLeader(bill) && bill.canCancel
    }
    private func amountRow(_ label: String, _ cents: Int) -> some View {
        HStack { Text(label); Spacer(); Text(Money.string(cents: cents)) }.font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
    }
    private func stages(_ bill: Bill) -> some View {
        HStack(spacing: 0) {
            stage("Split", done: true, active: false)
            Rectangle().fill(GP.border).frame(height: 1)
            stage("Approve", done: bill.allApproved, active: bill.status == .collecting)
            Rectangle().fill(GP.border).frame(height: 1)
            stage("Pay", done: bill.status == .paid, active: bill.status == .cardReady)
        }.padding(.vertical, 4)
    }
    private func stage(_ title: String, done: Bool, active: Bool) -> some View {
        VStack(spacing: 8) {
            AnimatedSymbol(name: done ? "checkmark" : active ? "circle.inset.filled" : "circle")
                .font(GP.body(12, weight: .bold, relativeTo: .caption)).frame(width: 30, height: 30).background(done || active ? GP.mint.opacity(0.12) : GP.surface, in: Circle())
            Text(title).font(GP.body(12, weight: .regular, relativeTo: .caption))
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
                .font(.custom("Caprasimo-Regular", fixedSize: portionSize)).contentTransition(.numericText()).gpAnimate(charge)
            if preview {
                Text("Move the tip slider to see your amount change. This sample won’t send an approval or create a card.")
                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            } else {
                Text(member.approved && !changed ? "Your portion is approved." : "Choose your tip, then approve your total.")
                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            }
            PersonalTipEditor(foodCents: bill.foodShares[member.id] ?? 0,
                              taxCents: bill.taxShares[member.id] ?? 0,
                              feeCents: bill.feeShares[member.id] ?? 0,
                              selection: $tipSelection, disabled: store.busy)
            if charge == nil {
                Text("Check your tip amount. The full bill must stay within $100,000, including tips and fees.")
                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.amber)
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
            Text("Approve your updated tip before creating the card.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
        } else if !bill.allApproved {
            Text("Ready to confirm once everyone has approved.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
        }
    }

    @ViewBuilder private func actionPanel(_ bill: Bill) -> some View {
        if bill.status == .cancelled {
            Panel {
                Label("Split cancelled", systemImage: "xmark.circle").font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.secondary)
                Text("There’s nothing to approve or pay. The original split is kept here for reference.")
                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            }
        } else if store.isPreview {
            if bill.usesPersonalPricing, bill.status == .collecting, let member = bill.members.first {
                personalPortion(bill, member: member, preview: true)
            } else {
                Panel {
                    Label("A sample split", systemImage: "eye").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                    Text("Explore how a split works. Sign in from Profile to create your own and invite your group.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                }
            }
        } else if bill.status == .paid {
            Panel {
                Label("All settled", systemImage: "checkmark.seal.fill").font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.mint)
                Text("The test payment is complete. Everyone’s portion is covered.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            }
        } else if bill.status == .issuing {
            Panel {
                Label(isLeader(bill) ? "Creating your test card" : "The leader is creating the card", systemImage: "creditcard")
                    .font(GP.body(17, weight: .semibold, relativeTo: .headline))
                Text("Your group has approved the split. The card will be available only to the leader.")
                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                if isLeader(bill) {
                    Button(store.busy ? "Working…" : "Resume card creation") { Task { await store.confirmCard(bill.id) } }
                        .buttonStyle(PrimaryButton()).disabled(store.busy)
                }
            }
        } else if bill.status == .cardReady {
            Panel {
                Label(isLeader(bill) ? "Your test card is ready" : "Leader’s card is ready", systemImage: "checkmark.circle.fill")
                    .font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.mint)
                if isLeader(bill) {
                    Text("The card covers \(Money.string(cents: bill.cardAmountCents)) for the receipt and tips.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    if bill.usesPersonalPricing {
                        Text("The \(Money.string(cents: bill.feeCents)) Group Pay fee is separate from the card.")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    }
                    if bill.card?.provider == "marqetaSandbox" {
                        Text("Payments are coming soon. This bill hasn’t been paid.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    } else if bill.card != nil {
                        Button("Make a test payment") { confirmingPayment = true }
                            .buttonStyle(PrimaryButton()).disabled(store.busy)
                    } else {
                        Text("Pull to refresh to load your private card details.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    }
                } else {
                    Text("Only the leader can view and use the test card. Your approval is saved.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    Text("This bill hasn’t been paid yet.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                }
            }
        } else if let member = bill.members.first(where: { $0.accountID == store.accountID && store.accountID != nil }) {
            if bill.usesPersonalPricing {
                personalPortion(bill, member: member)
            } else {
                Panel {
                    Eyebrow(text: "Your part")
                    Text(Money.string(cents: bill.shares[member.id] ?? 0))
                        .font(.custom("Caprasimo-Regular", fixedSize: portionSize)).contentTransition(.numericText()).gpAnimate(bill.shares[member.id])
                    Text(member.approved ? "Your portion is approved." : "Review the receipt and approve your portion.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    if !member.approved {
                        Button("Approve my \(Money.string(cents: bill.shares[member.id] ?? 0))") {
                            Task { await store.change(bill.id) { try $0.approve(accountID: $1) } }
                        }.buttonStyle(PrimaryButton()).disabled(store.busy)
                    }
                    if isLeader(bill) { confirmationButton(bill) }
                    Text("This existing bill keeps its original agreed amounts.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                }
            }
        } else {
            Panel {
                Text("Which portion is yours?").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                Text("Choose your name, then review your part before approving.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                ForEach(bill.members.filter { $0.accountID == nil }) { member in
                    Button { claiming = member } label: {
                        HStack {
                            Avatar(name: member.name)
                            Text("I’m \(member.name)")
                            Spacer()
                            Text(Money.string(cents: bill.shares[member.id] ?? 0))
                            Image(systemName: "chevron.right")
                        }.font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                    }.disabled(store.busy)
                }
                if bill.members.allSatisfy({ $0.accountID != nil }) {
                    Text("Everyone has joined. Ask the leader if your name is missing.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.amber)
                }
            }
        }
    }
}
