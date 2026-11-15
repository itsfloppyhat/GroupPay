import SwiftUI

struct ContentView: View {
    @State private var store = AppStore()
    @State private var tab = 0
    @State private var composing = false
    @State private var showingSandbox = false
    @State private var sandbox = SandboxCardService.shared
    @State private var route: [UUID] = []
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $route) { home.navigationDestination(for: UUID.self) { BillDetailView(billID: $0) } }.tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { activity }.tabItem { Label("Inbox", systemImage: "tray") }.badge(store.pendingBills.count).tag(1)
            NavigationStack { cards }.tabItem { Label("Cards", systemImage: "creditcard") }.tag(2)
            NavigationStack { profile }.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(GP.mint).preferredColorScheme(.dark)
        .environment(store)
        .sheet(isPresented: $showingSandbox) { SandboxConnectionView() }
        .sheet(isPresented: $composing) { NewBillView { id in tab = 0; route = [id] }.environment(store) }
        .sheet(isPresented: Binding(get: { store.sharingController != nil }, set: { if !$0 { store.sharingController = nil } })) {
            if let controller = store.sharingController { CloudShareSheet(controller: controller) }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--preview") { store.preview() }
            else { await store.connect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayAccountChanged)) { _ in Task { route = []; await store.accountChanged() } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayShareAccepted)) { _ in Task { await store.acceptedShare() } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayCloudError)) { note in store.error = note.userInfo?["message"] as? String }
        .onChange(of: phase) { _, new in if new == .active { Task { await store.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayCloudChanged)) { _ in Task { await store.refresh() } }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.hexagongrid.fill").foregroundStyle(GP.mint)
                        Text("group pay").font(.system(.title3, design: .rounded, weight: .bold))
                    }
                    Spacer()
                    Text("SIMULATED MONEY").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundStyle(GP.mint).padding(8).background(GP.mint.opacity(0.08), in: Capsule())
                }.padding(.top, 12)
                PageHeading(overline: "Good things, shared.", title: "Together feels\nbetter. So does paying.")
                hero
                if !store.connected { connectionPanel }
                HStack(spacing: 12) {
                    metric("GROUP SPENDING", value: Money.string(cents: store.paidTotal), symbol: "arrow.up.right")
                    metric("ACTIVE SPLITS", value: "\(store.activeBills.count)", symbol: "person.2")
                }
                HStack {
                    Text("Your splits").font(.title3.bold())
                    Spacer()
                    Text("\(store.bills.count) total").font(.caption).foregroundStyle(GP.secondary)
                }
                if store.bills.isEmpty {
                    EmptyPanel(symbol: "receipt", title: "Every good plan starts here.", subtitle: "Dinner, a grocery run, or the monthly bills. Create a split and bring everyone along.")
                }
                ForEach(store.bills) { bill in
                    NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain)
                }
                if store.bills.contains(where: { $0.recurrence != .none }) {
                    Panel {
                        Label("ON REPEAT", systemImage: "repeat").font(.caption.bold()).foregroundStyle(GP.mint)
                        Text("Same crew. Fresh approval.").font(.title3.bold())
                        Text("Recurring splits always ask everyone again before a new card is created.").font(.subheadline).foregroundStyle(GP.secondary)
                    }
                }
                Text("Built for the moments you share.").font(.caption).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }.gpPage().toolbar(.hidden, for: .navigationBar).refreshable { await store.refresh() }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("One bill.\nEveryone’s part.").font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.6)
                    Text("Scan it. Split it. Settle together.").font(.subheadline).opacity(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "viewfinder").font(.system(size: 44, weight: .ultraLight)).rotationEffect(.degrees(-10)).padding(.top, 8)
            }
            Button { composing = true } label: {
                HStack { Image(systemName: "plus"); Text("Start a split"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.subheadline.bold()).padding(17).foregroundStyle(GP.mint).background(GP.background, in: RoundedRectangle(cornerRadius: 16))
            }.accessibilityIdentifier("startSplit")
        }.padding(24).foregroundStyle(GP.background)
            .background(LinearGradient(colors: [GP.mint, Color(red: 0.59, green: 0.85, blue: 0.53)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
    }
    private var connectionPanel: some View {
        Panel(padding: 18) {
            Label(store.isPreview ? "You’re exploring a preview" : "Bring your group together", systemImage: store.isPreview ? "eye" : "icloud")
                .font(.subheadline.bold())
            Text(store.isPreview ? "Sample bills are read-only. Connect iCloud for real invitations and approvals on each person’s device." : "Use your iCloud account to privately share bills. Only invited people can open them.")
                .font(.caption).foregroundStyle(GP.secondary)
            HStack {
                Button { tab = 3 } label: { Text(store.busy ? "Connecting…" : "Connect iCloud").font(.subheadline.bold()).foregroundStyle(GP.mint) }
                Spacer()
                if !store.isPreview { Button("Explore preview") { store.preview() }.font(.caption).foregroundStyle(GP.secondary) }
            }
        }
    }
    private func metric(_ label: String, value: String, symbol: String) -> some View {
        Panel(padding: 16) {
            HStack { Image(systemName: symbol).foregroundStyle(GP.mint); Spacer() }
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            Eyebrow(text: label)
        }
    }
    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(overline: "Everyone gets a say", title: "Your inbox")
                if !store.notificationsEnabled {
                    Panel {
                        Label("Stay in the loop", systemImage: "bell.badge").font(.headline)
                        Text("Get notified when shared bills change. You can always refresh here to see the latest.").font(.subheadline).foregroundStyle(GP.secondary)
                        Button("Enable notifications") { Task { await store.enableNotifications() } }.buttonStyle(PrimaryButton()).disabled(!store.connected)
                    }
                }
                if store.pendingBills.isEmpty {
                    EmptyPanel(symbol: "checkmark.bubble", title: "You’re all caught up.", subtitle: "Open a bill invitation on this device, choose your name, and review your portion here.")
                } else {
                    Eyebrow(text: "Your approval is needed")
                    ForEach(store.pendingBills) { bill in NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain) }
                }
                if !store.bills.isEmpty {
                    Eyebrow(text: "Shared with you")
                    ForEach(store.bills) { bill in NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain) }
                }
            }.padding(22)
        }.navigationTitle("Inbox").navigationBarTitleDisplayMode(.inline).gpPage().refreshable { await store.refresh() }
    }
    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(overline: "One card. One shared bill.", title: "Group cards")
                if !store.bills.contains(where: { $0.card != nil }) {
                    EmptyPanel(symbol: "creditcard", title: "Ready when everyone is.", subtitle: "Once every person approves, the leader can create a simulated card loaded with the exact bill total.")
                }
                ForEach(store.bills.filter { $0.card != nil }) { bill in
                    NavigationLink { BillDetailView(billID: bill.id) } label: { VirtualCardView(bill: bill) }.buttonStyle(.plain)
                }
                Text("Demo cards cannot be used at merchants or added to Apple Wallet. No real funds are collected or moved.").font(.caption).foregroundStyle(GP.secondary)
            }.padding(22)
        }.navigationTitle("Cards").navigationBarTitleDisplayMode(.inline).gpPage()
    }
    private var profile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(overline: "Your corner", title: "Make yourself at home.")
                Panel {
                    HStack(spacing: 15) {
                        Avatar(name: store.name, size: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.name).font(.title2.bold())
                            Label(store.connected ? "iCloud connected" : "iCloud not connected", systemImage: store.connected ? "checkmark.icloud" : "icloud.slash").font(.caption).foregroundStyle(GP.secondary)
                        }
                    }
                    TextField("Your display name", text: $store.name).gpField().textContentType(.name)
                        .onChange(of: store.name) { _, value in UserDefaults.standard.set(value, forKey: "profileName") }
                    if !store.connected {
                        Button(store.busy ? "Connecting…" : "Connect with iCloud") { Task { await store.connect() } }.buttonStyle(PrimaryButton()).disabled(store.busy)
                    } else if let synced = store.lastSynced {
                        Text("Last synced \(synced.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(GP.secondary)
                    }
                }
                if let issue = store.connectionIssue {
                    Panel {
                        Label("iCloud setup needed", systemImage: "wrench.and.screwdriver").foregroundStyle(GP.amber).font(.headline)
                        Text(issue).font(.caption).foregroundStyle(GP.secondary).textSelection(.enabled)
                        Text("On a signed development build, enable this app’s CloudKit container and Push Notifications, and sign into iCloud on your iPhone. Setup steps are included in the project README.").font(.caption).foregroundStyle(GP.secondary)
                    }
                }
                Panel {
                    Label("Notifications", systemImage: "bell").font(.headline)
                    Text("CloudKit sends background updates. iOS controls delivery timing; opening the app always refreshes your bills.").font(.subheadline).foregroundStyle(GP.secondary)
                    Button(store.notificationsEnabled ? "Notifications enabled" : "Enable notifications") { Task { await store.enableNotifications() } }.foregroundStyle(GP.mint).disabled(!store.connected)
                }
                Panel {
                    Label("Card issuing", systemImage: "creditcard.and.123").font(.headline)
                    Text(sandbox.enabled ? "Marqeta Sandbox" : "Local simulation").font(.title3.bold()).foregroundStyle(GP.mint)
                    Text("Connect the local sandbox backend to generate Marqeta test cards. Provider credentials stay on your Mac.").font(.subheadline).foregroundStyle(GP.secondary)
                    Button("Configure sandbox") { showingSandbox = true }.font(.subheadline.bold()).foregroundStyle(GP.mint)
                }
                Panel {
                    Eyebrow(text: "The prototype promise")
                    Text("Real people. Pretend money.").font(.title3.bold())
                    Text("Invitations and approvals use iCloud. Card creation can use Marqeta’s sandbox; all funds remain test funds. Real payments and merchant transactions are not enabled.").font(.subheadline).foregroundStyle(GP.secondary)
                }
            }.padding(22)
        }.navigationTitle("Profile").navigationBarTitleDisplayMode(.inline).gpPage()
    }
}

struct BillRow: View {
    let bill: Bill
    var body: some View {
        Panel(padding: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: bill.category.systemImage).font(.title3).foregroundStyle(GP.mint).frame(width: 44, height: 44).background(GP.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text(bill.title).font(.headline).foregroundStyle(.white)
                    Text(bill.recurrence == .none ? bill.createdAt.formatted(date: .abbreviated, time: .omitted) : "\(bill.recurrence.rawValue.capitalized) · Cycle \(bill.cycle)").font(.caption).foregroundStyle(GP.secondary)
                }
                Spacer(minLength: 0)
                Text(Money.string(cents: bill.totalCents)).font(.system(.headline, design: .rounded)).foregroundStyle(.white)
            }
            HStack {
                HStack(spacing: -8) { ForEach(Array(bill.members.prefix(4).enumerated()), id: \.element.id) { index, member in Avatar(name: member.name, index: index, size: 28) } }
                Text("\(bill.approvedCount)/\(bill.members.count)").font(.caption).foregroundStyle(GP.secondary)
                Spacer()
                StatusPill(bill: bill)
            }
        }
    }
}

struct VirtualCardView: View {
    let bill: Bill
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Label("group pay", systemImage: "circle.hexagongrid.fill").font(.headline)
                Spacer()
                Text(bill.card?.provider == "marqetaSandbox" ? "MARQETA SANDBOX" : "DEMO CARD").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
            }
            HStack {
                Image(systemName: "simcard").font(.system(size: 32, weight: .thin)).rotationEffect(.degrees(90))
                Spacer()
                Image(systemName: "wave.3.right").font(.title3)
            }
            Text("••••    ••••    ••••    \(bill.card?.lastFour ?? "0000")").font(.system(size: 21, weight: .medium, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bill.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                    Text(bill.status == .paid ? "Payment completed" : bill.card?.provider == "marqetaSandbox" ? "Sandbox funds at issuance" : "Loaded for this bill").font(.caption).opacity(0.65)
                }
                Spacer()
                Text(Money.string(cents: bill.card?.remainingCents ?? 0)).font(.system(.title2, design: .rounded, weight: .semibold))
            }
        }.padding(26).foregroundStyle(GP.background)
            .background(LinearGradient(colors: [GP.mint, Color(red: 0.47, green: 0.72, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
    }
}
