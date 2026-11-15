import SwiftUI
import PhotosUI

private struct ReceiptLine: Identifiable {
    var id = UUID()
    var name = ""
    var amount = ""
    var assigneeIDs: [UUID] = []
}

struct NewBillView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onCreated: (UUID) -> Void = { _ in }
    @State private var step = 0
    @State private var title = ""
    @State private var category: BillCategory = .dining
    @State private var lines: [ReceiptLine] = []
    @State private var tax = "0.00"
    @State private var leaderTip = TipSelection()
    @State private var selectedGroupID: UUID?
    @State private var scannedTipCents = 0
    @State private var members = [BillMember(name: "You"), BillMember(name: "")]
    @State private var customAmounts: [UUID: String] = [:]
    @State private var method: SplitMethod = .equal
    @State private var recurrence: Recurrence = .none
    @State private var nextDue = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var showCamera = false
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var issue: String?
    @State private var rawText = ""
    @State private var detectedTotal: Int?
    @State private var totalVerified = false
    @State private var reviewed = false
    @ScaledMetric(relativeTo: .largeTitle) private var reviewTotalSize = 46.0

    private var draft: Bill {
        var people = members
        people[0].name = store.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : store.name
        people[0].accountID = store.accountID ?? "draft-owner"
        people[0].tipPercent = leaderTip.percent
        people[0].tipOverrideCents = leaderTip.customAmount.map { Money.cents(from: $0) ?? -1 }
        for index in people.indices { people[index].customCents = Money.cents(from: customAmounts[people[index].id] ?? "0") ?? -1 }
        return Bill(title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category,
                    items: lines.map { BillItem(id: $0.id, name: $0.name, amountCents: Money.cents(from: $0.amount) ?? -1, assigneeIDs: $0.assigneeIDs) },
                    taxCents: Money.cents(from: tax) ?? -1, tipCents: 0,
                    splitMethod: method, members: people, leaderID: store.accountID ?? "draft-owner",
                    recurrence: recurrence, nextDueDate: recurrence == .none ? nil : nextDue, pricingVersion: 2, groupID: selectedGroupID)
    }
    private var receiptValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lines.isEmpty &&
        lines.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Money.cents(from: $0.amount) ?? 0) > 0 } &&
        (Money.cents(from: tax) ?? -1) >= 0 && draft.baseTotalCents > 0 && draft.baseTotalCents <= Bill.maximumCents
    }
    private var totalMismatch: Bool { detectedTotal != nil && detectedTotal != draft.baseTotalCents }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in Capsule().fill(index <= step ? GP.mint : GP.raised).frame(height: 4) }
                    }
                    PageHeading(overline: "Step \(step + 1) of 3 · \(["The receipt", "Your group", "Review"][step])", title: ["Start with the bill", "Everyone’s part", "Ready to share?"][step])
                    if step == 0 { receiptStep }
                    else if step == 1 { peopleStep }
                    else { reviewStep }
                }.padding(22)
            }.safeAreaInset(edge: .bottom) { footer }
                .gpPage().navigationTitle("New split").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(GP.secondary).disabled(store.busy) }
                    if step > 0 { ToolbarItem(placement: .topBarTrailing) { Button("Back") { step -= 1; reviewed = false }.disabled(store.busy) } }
                }
                .sheet(isPresented: $showCamera) {
                    ReceiptCamera(onScan: { result in
                        showCamera = false
                        switch result { case .success(let receipt): apply(receipt); case .failure(let error): issue = error.localizedDescription }
                    }, onCancel: { showCamera = false }).ignoresSafeArea()
                }
                .alert("Receipt needs attention", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) { Button("OK", role: .cancel) { issue = nil } } message: { Text(issue ?? "") }
                .onChange(of: photo) { _, item in
                    guard let item else { return }
                    scanning = true
                    Task {
                        defer { scanning = false; photo = nil }
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptScanError.unreadableImage }
                            apply(try await ReceiptRecognizer.recognize(imageData: data))
                        } catch { issue = error.localizedDescription }
                    }
                }
                .onChange(of: draft.baseTotalCents) { _, _ in totalVerified = false }
                .onChange(of: category) { _, value in leaderTip = TipSelection(percent: value == .dining ? 20 : 0) }
                .onChange(of: selectedGroupID) { _, _ in applySelectedGroup() }
        }.preferredColorScheme(.dark).tint(GP.mint).interactiveDismissDisabled(store.busy || scanning)
    }
    private var receiptStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            if lines.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(GP.mint)
                        .frame(width: 96, height: 96)
                        .background(GP.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(GP.mint.opacity(0.12)))
                        .padding(.top, 8)
                    Text("Bring your receipt").font(.title3.weight(.semibold))
                    Text("Dinner, groceries, or something shared.\nScan it, then check the details.")
                        .font(.subheadline).foregroundStyle(GP.secondary).multilineTextAlignment(.center)
                    Button { showCamera = true } label: { Label("Scan a receipt", systemImage: "camera") }.buttonStyle(PrimaryButton()).disabled(!ReceiptCamera.isSupported || scanning)
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose a receipt photo", systemImage: "photo") }.font(.subheadline.bold()).disabled(scanning)
                    if !ReceiptCamera.isSupported { Text("Camera unavailable. Choose a photo or try a sample receipt.").font(.caption).foregroundStyle(GP.secondary).multilineTextAlignment(.center) }
                    if scanning { ProgressView("Reading your receipt…").font(.caption) }
                }.padding(24).frame(maxWidth: .infinity).background(GP.surface, in: RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 12) {
                    sampleButton("Dinner", symbol: "fork.knife", groceries: false)
                    sampleButton("Groceries", symbol: "basket", groceries: true)
                }
                Button("Enter a bill manually") { lines = [ReceiptLine()]; title = "" }.font(.subheadline).foregroundStyle(GP.secondary).frame(maxWidth: .infinity)
            } else {
                Panel {
                    Eyebrow(text: "Receipt details")
                    TextField("Restaurant or bill name", text: $title).font(.title3.weight(.semibold)).gpField()
                    Picker("Category", selection: $category) { ForEach(BillCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    HStack {
                        Text("ITEM")
                        Spacer()
                        Text("USD").padding(.trailing, 28)
                    }.font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(GP.secondary).padding(.top, 8)
                    ForEach($lines) { $line in
                        HStack {
                            TextField("Item name", text: $line.name).accessibilityLabel("Item name")
                            TextField("0.00", text: $line.amount).accessibilityLabel("Item price in dollars").keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                            Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle").foregroundStyle(GP.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Remove \(line.name)")
                        }.font(.subheadline).padding(.vertical, 9)
                        Divider()
                    }
                    Button { lines.append(ReceiptLine()) } label: { Label("Add item", systemImage: "plus") }.font(.subheadline.bold())
                    HStack { Text("Tax"); Spacer(); TextField("0.00", text: $tax).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }.font(.subheadline)
                    Divider()
                    HStack { Text("Before tips and fee").bold(); Spacer(); Text(Money.string(cents: draft.baseTotalCents)).font(.title3.bold()).foregroundStyle(GP.mint) }
                }
                if scannedTipCents > 0 {
                    Text("The receipt includes \(Money.string(cents: scannedTipCents)) in tip. It isn’t added twice: each person sets their own tip before approving. For a tip already agreed with the restaurant, use exact tip amounts that add up to it.").font(.caption).foregroundStyle(GP.amber)
                }
                if totalMismatch {
                    Panel {
                        Label("Check the total", systemImage: "exclamationmark.triangle").foregroundStyle(GP.amber).font(.headline)
                        Text("Receipt: \(Money.string(cents: detectedTotal ?? 0)). Your total: \(Money.string(cents: draft.baseTotalCents)). Check for missed items or discounts before continuing.").font(.subheadline).foregroundStyle(GP.secondary)
                        Toggle("I verified the corrected total", isOn: $totalVerified).font(.subheadline)
                    }
                }
                if !rawText.isEmpty {
                    DisclosureGroup("Original receipt text") { Text(rawText).font(.caption.monospaced()).foregroundStyle(GP.secondary).textSelection(.enabled).padding(.top, 10) }.font(.subheadline).padding(18).background(GP.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                Text("Check prices, discounts, and tax before continuing. Everyone chooses their own tip when approving.").font(.caption).foregroundStyle(GP.secondary)
            }
        }
    }
    private func sampleButton(_ title: String, symbol: String, groceries: Bool) -> some View {
        Button { sample(groceries: groceries) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(GP.mint)
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Text("Sample receipt").font(.caption).foregroundStyle(GP.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(GP.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    private var peopleStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !store.ownedGroups.isEmpty {
                Panel {
                    Picker("Saved group", selection: $selectedGroupID) {
                        Text("One-time split").tag(nil as UUID?)
                        ForEach(store.ownedGroups) { Text($0.name).tag(Optional($0.id)) }
                    }.tint(GP.mint)
                    Text("Group members accept one invitation, then future bills arrive automatically.").font(.caption).foregroundStyle(GP.secondary)
                }
            }
            Panel {
                Eyebrow(text: "Your group")
                ForEach(Array(members.indices), id: \.self) { index in
                    HStack {
                        Avatar(name: index == 0 ? store.name : members[index].name, index: index)
                        if index == 0 { Text(store.name == "You" ? "You" : "\(store.name) (you)").font(.subheadline); Spacer(); Text("Leader").font(.caption).foregroundStyle(GP.mint) }
                        else if selectedGroupID != nil {
                            Text(members[index].name).font(.subheadline)
                            Spacer()
                        } else {
                            TextField("Their name", text: $members[index].name).textContentType(.name).font(.subheadline)
                            Button { let id = members[index].id; members.remove(at: index); for i in lines.indices { lines[i].assigneeIDs.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle").foregroundStyle(GP.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Remove person")
                        }
                    }.padding(.vertical, 5)
                }
                if selectedGroupID == nil {
                    Button { members.append(BillMember(name: "")) } label: { Label("Add a person", systemImage: "person.badge.plus") }.font(.subheadline.bold()).disabled(members.count >= 50)
                    if !store.friends.isEmpty {
                        Menu("Add a saved friend") {
                            ForEach(store.friends.filter { friend in !members.contains(where: { $0.accountID == friend.id }) }) { friend in
                                Button(friend.name) { addFriend(friend) }
                            }
                        }.font(.subheadline.bold()).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(members.count >= 50)
                    }
                    Text("You’ll send invitations after creating this one-time split. Choose a saved group to reuse an accepted invitation.").font(.caption).foregroundStyle(GP.secondary)
                } else {
                    Text("Everyone in this group can see its bills. Members who accepted the group invitation don’t need another link.").font(.caption).foregroundStyle(GP.secondary)
                }
            }
            Panel {
                Eyebrow(text: "How to split")
                Picker("Split method", selection: $method) { ForEach(SplitMethod.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).tint(GP.mint)
                if method == .equal {
                    Text("Split the subtotal equally. Tax and the 1% fee are added, then each person chooses their own tip.").font(.subheadline).foregroundStyle(GP.secondary)
                } else if method == .custom {
                    Text("Assign each person’s food or item subtotal. Tax, personal tips, and the fee are added separately.").font(.caption).foregroundStyle(GP.secondary)
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        HStack {
                            Text(index == 0 ? store.name : member.name).font(.subheadline)
                            Spacer()
                            TextField("0.00", text: Binding(get: { customAmounts[member.id] ?? "" }, set: { customAmounts[member.id] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100).gpField()
                        }
                    }
                    let assigned = members.reduce(0) { $0 + min(Bill.maximumCents, max(0, Money.cents(from: customAmounts[$1.id] ?? "0") ?? 0)) }
                    Text("\(Money.string(cents: draft.subtotalCents - assigned)) left to assign").font(.caption.bold()).foregroundStyle(assigned == draft.subtotalCents ? GP.mint : GP.amber)
                } else {
                    Text("Select who shares each item. Tax and the fee follow those portions; tips are personal.").font(.caption).foregroundStyle(GP.secondary)
                    ForEach($lines) { $line in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(line.name).font(.subheadline.bold()); Spacer(); Text(Money.string(cents: Money.cents(from: line.amount) ?? 0)).font(.subheadline) }
                            ViewThatFits(in: .horizontal) {
                                HStack { assignmentButtons($line) }
                                VStack(alignment: .leading) { assignmentButtons($line) }
                            }
                        }.padding(.vertical, 8)
                    }
                }
            }
            Panel {
                Label("Repeat this bill", systemImage: "repeat").font(.headline)
                Picker("Repeat", selection: $recurrence) { ForEach(Recurrence.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if recurrence != .none {
                    DatePicker("Next due", selection: $nextDue, in: Date.now..., displayedComponents: .date).font(.subheadline)
                    Text("Start each cycle when you’re ready. Everyone approves again.").font(.caption).foregroundStyle(GP.secondary)
                }
            }
            if let validation = draft.validationMessage { Text(validation).font(.caption).foregroundStyle(GP.amber) }
        }
    }
    @ViewBuilder private func assignmentButtons(_ line: Binding<ReceiptLine>) -> some View {
        ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
            let selected = line.wrappedValue.assigneeIDs.contains(member.id)
            Button {
                if selected { line.wrappedValue.assigneeIDs.removeAll { $0 == member.id } }
                else { line.wrappedValue.assigneeIDs.append(member.id) }
            } label: {
                Text(index == 0 ? "You" : member.name.isEmpty ? "Person \(index + 1)" : member.name)
                    .font(.caption.bold()).padding(.horizontal, 11).padding(.vertical, 9).frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(selected ? GP.background : GP.secondary).background(selected ? GP.mint : GP.raised, in: Capsule())
            }.accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                HStack(spacing: 12) {
                    Image(systemName: category.systemImage).foregroundStyle(GP.mint)
                        .frame(width: 40, height: 40).background(GP.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(category.rawValue).font(.caption).foregroundStyle(GP.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(Money.string(cents: draft.totalCents)).font(.system(size: reviewTotalSize, weight: .medium, design: .rounded)).tracking(-1.5).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
                Text("\(method.rawValue) · \(recurrence.rawValue) · USD").font(.caption).foregroundStyle(GP.secondary)
                Text("Includes estimated personal tips and the 1% fee. The total updates as everyone chooses their tip.").font(.caption).foregroundStyle(GP.secondary)
                HStack { Text("Personal tips"); Spacer(); Text(Money.string(cents: draft.totalTipCents)) }.font(.subheadline)
                HStack { Text("Group Pay fee · 1%"); Spacer(); Text(Money.string(cents: draft.feeCents)) }.font(.subheadline)
                Divider()
                ForEach(Array(draft.members.enumerated()), id: \.element.id) { index, member in
                    HStack {
                        Avatar(name: member.name, index: index)
                        Text(member.name).font(.subheadline)
                        Spacer()
                        Text(Money.string(cents: draft.shares[member.id] ?? 0)).font(.subheadline.bold())
                    }
                }
            }
            if let member = draft.members.first {
                Panel {
                    PersonalTipEditor(foodCents: draft.foodShares[member.id] ?? 0, taxCents: draft.taxShares[member.id] ?? 0,
                                      feeCents: draft.feeShares[member.id] ?? 0, selection: $leaderTip)
                }
            }
            Panel {
                Text("What happens next").font(.headline)
                VStack(alignment: .leading, spacing: 18) {
                    nextStep("1", title: selectedGroupID == nil ? "Invite your group" : "Share with your group", detail: "Everyone receives their own amount, including a tip they can adjust.")
                    nextStep("2", title: "Everyone approves", detail: "Each person chooses their tip and approves their total.")
                    nextStep("3", title: "Create one test card", detail: "You confirm once the whole group is ready. Only you receive the card.")
                }.padding(.vertical, 4)
                Divider()
                Toggle("I reviewed the receipt and everyone’s portion", isOn: $reviewed).font(.subheadline).tint(GP.mint)
            }
            if !store.connected { Text("Sign in from Profile to create this split and invite your group.").font(.subheadline).foregroundStyle(GP.amber) }
            Text("Creating this split also approves your portion.").font(.caption).foregroundStyle(GP.secondary)
            Text("Test mode · No real money").font(.caption).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }
    private func nextStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(GP.mint)
                .frame(width: 26, height: 26).background(GP.mint.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(GP.secondary)
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if step < 2 {
                Button(step == 0 ? "Continue to your group" : "Review the split") { step += 1 }
                    .buttonStyle(PrimaryButton())
                    .disabled(step == 0 ? (!receiptValid || scanning || (totalMismatch && !totalVerified)) : draft.validationMessage != nil)
            } else {
                Button(store.busy ? "Creating split…" : "Create split") {
                    let bill = draft
                    Task { if await store.publish(bill) { onCreated(bill.id); dismiss() } }
                }.buttonStyle(PrimaryButton()).disabled(!reviewed || !store.connected || store.busy || draft.validationMessage != nil)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12).background(GP.background)
    }
    private func applySelectedGroup() {
        guard let id = selectedGroupID, let group = store.ownedGroups.first(where: { $0.id == id }) else {
            members = [BillMember(name: store.name), BillMember(name: "")]
            customAmounts = [:]
            for i in lines.indices { lines[i].assigneeIDs = [] }
            return
        }
        members = [BillMember(name: store.name, accountID: store.accountID)] + group.members.filter { $0.id != store.accountID }.map { BillMember(name: $0.name, accountID: $0.id) }
        customAmounts = [:]
        for i in lines.indices { lines[i].assigneeIDs = [] }
    }
    private func addFriend(_ friend: SavedFriend) {
        let member = BillMember(name: friend.name, accountID: friend.id)
        if let index = members.indices.dropFirst().first(where: { members[$0].name.isEmpty && members[$0].accountID == nil }) {
            members[index] = member
        } else { members.append(member) }
    }
    private func decimal(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, cents % 100) }
    private func apply(_ receipt: ScannedReceipt) {
        title = receipt.merchant
        category = switch receipt.suggestedCategory {
        case .dining: .dining
        case .groceries: .groceries
        case .other: .other
        }
        leaderTip = TipSelection(percent: category == .dining ? 20 : 0)
        lines = receipt.items.map { ReceiptLine(name: $0.name, amount: decimal($0.amountCents)) }
        if lines.isEmpty, let total = receipt.totalCents { lines = [ReceiptLine(name: "Receipt total", amount: decimal(max(0, total - receipt.taxCents - receipt.tipCents)))] }
        tax = decimal(receipt.taxCents); scannedTipCents = receipt.tipCents
        rawText = receipt.rawText; detectedTotal = receipt.totalCents.map { max(0, $0 - receipt.tipCents) }; totalVerified = false
    }
    private func sample(groceries: Bool) {
        category = groceries ? .groceries : .dining
        title = groceries ? "Sunday groceries" : "Dinner at Olive & Stone"
        let values: [(String, Int)] = groceries ? [("Sourdough loaf", 650), ("Avocados × 3", 525), ("Pasta & tomatoes", 1240), ("Coffee beans", 1600), ("Fresh berries", 799)] : [("Burrata to share", 1800), ("Rigatoni", 2600), ("Wild mushroom pizza", 2400), ("Roasted salmon", 3200), ("Sparkling water", 800)]
        lines = values.map { ReceiptLine(name: $0.0, amount: decimal($0.1)) }
        tax = groceries ? "1.72" : "9.18"; leaderTip = TipSelection(percent: groceries ? 0 : 20); scannedTipCents = 0
        detectedTotal = nil; rawText = "Sample receipt · entered for demonstration"; totalVerified = false
    }
}
