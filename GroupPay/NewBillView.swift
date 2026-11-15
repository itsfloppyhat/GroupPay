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
    @State private var tip = "0.00"
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

    private var draft: Bill {
        var people = members
        people[0].name = store.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : store.name
        people[0].accountID = store.accountID ?? "draft-owner"
        for index in people.indices { people[index].customCents = Money.cents(from: customAmounts[people[index].id] ?? "0") ?? -1 }
        return Bill(title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category,
                    items: lines.map { BillItem(id: $0.id, name: $0.name, amountCents: Money.cents(from: $0.amount) ?? -1, assigneeIDs: $0.assigneeIDs) },
                    taxCents: Money.cents(from: tax) ?? -1, tipCents: Money.cents(from: tip) ?? -1,
                    splitMethod: method, members: people, leaderID: store.accountID ?? "draft-owner",
                    recurrence: recurrence, nextDueDate: recurrence == .none ? nil : nextDue)
    }
    private var receiptValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lines.isEmpty &&
        lines.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Money.cents(from: $0.amount) ?? 0) > 0 } &&
        (Money.cents(from: tax) ?? -1) >= 0 && (Money.cents(from: tip) ?? -1) >= 0 && draft.totalCents > 0
    }
    private var totalMismatch: Bool { detectedTotal != nil && detectedTotal != draft.totalCents }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in Capsule().fill(index <= step ? GP.mint : GP.raised).frame(height: 4) }
                    }
                    PageHeading(overline: "Step \(step + 1) of 3", title: ["Start with the bill.", "Find everyone’s part.", "Good to share?"][step])
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
                .onChange(of: draft.totalCents) { _, _ in totalVerified = false }
        }.preferredColorScheme(.dark).tint(GP.mint).interactiveDismissDisabled(store.busy || scanning)
    }
    private var receiptStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            if lines.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(GP.mint).padding(.top, 16)
                    Text("Less math. More moments.").font(.title3.bold())
                    Text("Scan a restaurant receipt or groceries.\nYou’ll review every item before sharing.")
                        .font(.subheadline).foregroundStyle(GP.secondary).multilineTextAlignment(.center)
                    Button { showCamera = true } label: { Label("Scan a receipt", systemImage: "camera") }.buttonStyle(PrimaryButton()).disabled(!ReceiptCamera.isSupported || scanning)
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose a receipt photo", systemImage: "photo") }.font(.subheadline.bold()).disabled(scanning)
                    if !ReceiptCamera.isSupported { Text("Camera scanning is available on supported iPhones and iPads. Import a photo or try a sample here.").font(.caption).foregroundStyle(GP.secondary).multilineTextAlignment(.center) }
                    if scanning { ProgressView("Reading receipt on this device…").font(.caption) }
                }.padding(24).frame(maxWidth: .infinity).background(GP.surface, in: RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 12) {
                    sampleButton("Dinner receipt", symbol: "fork.knife", groceries: false)
                    sampleButton("Grocery receipt", symbol: "basket", groceries: true)
                }
                Button("Enter a bill manually") { lines = [ReceiptLine()]; title = "" }.font(.subheadline).foregroundStyle(GP.secondary).frame(maxWidth: .infinity)
            } else {
                Panel {
                    Eyebrow(text: "Receipt details")
                    TextField("Restaurant or bill name", text: $title).font(.title3.bold()).gpField()
                    Picker("Category", selection: $category) { ForEach(BillCategory.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    ForEach($lines) { $line in
                        HStack {
                            TextField("Item name", text: $line.name)
                            TextField("0.00", text: $line.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                            Button { lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle").foregroundStyle(GP.secondary) }.accessibilityLabel("Remove \(line.name)")
                        }.font(.subheadline).padding(.vertical, 9)
                        Divider()
                    }
                    Button { lines.append(ReceiptLine()) } label: { Label("Add item", systemImage: "plus") }.font(.subheadline.bold())
                    HStack { Text("Tax"); Spacer(); TextField("0.00", text: $tax).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }.font(.subheadline)
                    HStack { Text("Tip"); Spacer(); TextField("0.00", text: $tip).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100) }.font(.subheadline)
                    Divider()
                    HStack { Text("Bill total").bold(); Spacer(); Text(Money.string(cents: draft.totalCents)).font(.title3.bold()).foregroundStyle(GP.mint) }
                }
                if totalMismatch {
                    Panel {
                        Label("Check the total", systemImage: "exclamationmark.triangle").foregroundStyle(GP.amber).font(.headline)
                        Text("The receipt shows \(Money.string(cents: detectedTotal ?? 0)); your edited items, tax, and tip total \(Money.string(cents: draft.totalCents)). Correct missed items or discounts before continuing.").font(.subheadline).foregroundStyle(GP.secondary)
                        Toggle("I verified the corrected total", isOn: $totalVerified).font(.subheadline)
                    }
                }
                if !rawText.isEmpty {
                    DisclosureGroup("Recognized receipt text") { Text(rawText).font(.caption.monospaced()).foregroundStyle(GP.secondary).textSelection(.enabled).padding(.top, 10) }.font(.subheadline).padding(18).background(GP.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                Text("Review item names, prices, tax, and tip. Receipt recognition may miss discounts or misread numbers.").font(.caption).foregroundStyle(GP.secondary)
            }
        }
    }
    private func sampleButton(_ title: String, symbol: String, groceries: Bool) -> some View {
        Button { sample(groceries: groceries) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(GP.mint)
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Text("TRY A SAMPLE").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(GP.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(GP.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    private var peopleStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                Eyebrow(text: "Who’s in?")
                ForEach(Array(members.indices), id: \.self) { index in
                    HStack {
                        Avatar(name: index == 0 ? store.name : members[index].name, index: index)
                        if index == 0 { Text("\(store.name) (you)").font(.subheadline); Spacer(); Text("Leader").font(.caption).foregroundStyle(GP.mint) }
                        else {
                            TextField("Their name", text: $members[index].name).textContentType(.name).font(.subheadline)
                            Button { let id = members[index].id; members.remove(at: index); for i in lines.indices { lines[i].assigneeIDs.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle").foregroundStyle(GP.secondary) }.accessibilityLabel("Remove person")
                        }
                    }.padding(.vertical, 5)
                }
                Button { members.append(BillMember(name: "")) } label: { Label("Add a person", systemImage: "person.badge.plus") }.font(.subheadline.bold()).disabled(members.count >= 50)
                Text("After creating the split, invite these people through iCloud. They’ll join and approve on their own devices.").font(.caption).foregroundStyle(GP.secondary)
            }
            Panel {
                Eyebrow(text: "Make it fair")
                Picker("Split method", selection: $method) { ForEach(SplitMethod.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).tint(GP.mint)
                if method == .equal {
                    Text("The total, including tax and tip, is shared equally. Any extra cent is allocated in group order.").font(.subheadline).foregroundStyle(GP.secondary)
                } else if method == .custom {
                    Text("Enter each person’s final amount, including tax and tip.").font(.caption).foregroundStyle(GP.secondary)
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        HStack {
                            Text(index == 0 ? store.name : member.name).font(.subheadline)
                            Spacer()
                            TextField("0.00", text: Binding(get: { customAmounts[member.id] ?? "" }, set: { customAmounts[member.id] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100).gpField()
                        }
                    }
                    let assigned = members.reduce(0) { $0 + min(Bill.maximumCents, max(0, Money.cents(from: customAmounts[$1.id] ?? "0") ?? 0)) }
                    Text("\(Money.string(cents: draft.totalCents - assigned)) left to assign").font(.caption.bold()).foregroundStyle(assigned == draft.totalCents ? GP.mint : GP.amber)
                } else {
                    Text("Select who shares each item. Tax and tip follow each person’s portion of the subtotal.").font(.caption).foregroundStyle(GP.secondary)
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
                Label("Make it a regular thing", systemImage: "repeat").font(.headline)
                Picker("Repeat", selection: $recurrence) { ForEach(Recurrence.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if recurrence != .none {
                    DatePicker("Next due", selection: $nextDue, in: Date.now..., displayedComponents: .date).font(.subheadline)
                    Text("The leader starts each new cycle. Everyone approves again before another demo card is created.").font(.caption).foregroundStyle(GP.secondary)
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
                    .font(.caption.bold()).padding(.horizontal, 11).padding(.vertical, 9)
                    .foregroundStyle(selected ? GP.background : GP.secondary).background(selected ? GP.mint : GP.raised, in: Capsule())
            }.accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                HStack { Image(systemName: category.systemImage).foregroundStyle(GP.mint); Text(title).font(.headline); Spacer() }
                Text(Money.string(cents: draft.totalCents)).font(.system(size: 42, weight: .medium, design: .rounded)).tracking(-1)
                Text("\(method.rawValue) · \(recurrence.rawValue) · USD").font(.caption).foregroundStyle(GP.secondary)
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
            Panel {
                Label("Here’s what happens next", systemImage: "arrow.triangle.branch").font(.headline)
                Text(store.sandboxIssuingEnabled ? "1. Invite your group through iCloud.\n2. Each person reviews and approves their part.\n3. You confirm and issue a funded sandbox card.\n4. Inspect the test card in the app and Marqeta." : "1. Invite your group through iCloud.\n2. Each person reviews and approves their part.\n3. You confirm and create one demo card.\n4. Simulate paying the full bill.").font(.subheadline).lineSpacing(8).foregroundStyle(GP.secondary)
                Toggle("I reviewed the receipt and everyone’s portion", isOn: $reviewed).font(.subheadline).tint(GP.mint)
            }
            if !store.connected { Text("Connect iCloud from Profile before creating this split. Sample receipts can be explored without an account.").font(.subheadline).foregroundStyle(GP.amber) }
            Text("Creating this split approves your own portion. All money and cards are simulated.").font(.caption).foregroundStyle(GP.secondary)
        }
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if step < 2 {
                Button(step == 0 ? "Next · Add your people" : "Review the split") { step += 1 }
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
    private func decimal(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, cents % 100) }
    private func apply(_ receipt: ScannedReceipt) {
        title = receipt.merchant
        lines = receipt.items.map { ReceiptLine(name: $0.name, amount: decimal($0.amountCents)) }
        if lines.isEmpty, let total = receipt.totalCents { lines = [ReceiptLine(name: "Receipt total", amount: decimal(max(0, total - receipt.taxCents - receipt.tipCents)))] }
        tax = decimal(receipt.taxCents); tip = decimal(receipt.tipCents)
        rawText = receipt.rawText; detectedTotal = receipt.totalCents; totalVerified = false
    }
    private func sample(groceries: Bool) {
        category = groceries ? .groceries : .dining
        title = groceries ? "Sunday groceries" : "Dinner at Olive & Stone"
        let values: [(String, Int)] = groceries ? [("Sourdough loaf", 650), ("Avocados × 3", 525), ("Pasta & tomatoes", 1240), ("Coffee beans", 1600), ("Fresh berries", 799)] : [("Burrata to share", 1800), ("Rigatoni", 2600), ("Wild mushroom pizza", 2400), ("Roasted salmon", 3200), ("Sparkling water", 800)]
        lines = values.map { ReceiptLine(name: $0.0, amount: decimal($0.1)) }
        tax = groceries ? "1.72" : "9.18"; tip = groceries ? "0.00" : "21.60"
        detectedTotal = nil; rawText = "Sample receipt · entered for demonstration"; totalVerified = false
    }
}
