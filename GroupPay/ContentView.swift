import SwiftUI

struct ContentView: View {
    @State private var store = AppStore()
    @State private var tab = 0
    @State private var composing = false
    @State private var showingSandbox = false
    @State private var showingTeamAccess = false
    @State private var sandbox = SandboxCardService.shared
    @State private var route: [UUID] = []
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize = 34

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $route) { home.navigationDestination(for: UUID.self) { BillDetailView(billID: $0) } }
                .tabItem { Label("Home", systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { activity }.tabItem { Label("Inbox", systemImage: "tray") }.badge(store.pendingBills.count).tag(1)
            NavigationStack { cards }.tabItem { Label("Cards", systemImage: "creditcard") }.tag(2)
            NavigationStack { PeopleView() }.tabItem { Label("People", systemImage: "person.2") }
                .badge(store.friendInvitations.filter { $0.owner.id != store.accountID }.count).tag(4)
            NavigationStack { profile }.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(GP.mint).preferredColorScheme(.dark)
        .environment(store)
        .sheet(isPresented: $showingSandbox) { SandboxConnectionView() }
        .sheet(isPresented: $showingTeamAccess) { TeamAccessView() }
        .sheet(isPresented: $composing) { NewBillView { id in tab = 0; route = [id] }.environment(store) }
        .sheet(isPresented: Binding(get: { store.sharingController != nil }, set: { if !$0 { store.sharingController = nil } })) {
            if let controller = store.sharingController { CloudShareSheet(controller: controller) }
        }
        .alert("Let’s try that again", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--preview") { store.preview() }
            else { await store.connect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayAccountChanged)) { _ in Task { route = []; await store.accountChanged() } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayShareAccepted)) { _ in
            Task {
                await store.acceptedShare()
                if store.friendInvitations.contains(where: { $0.owner.id != store.accountID }) { tab = 4 }
            }
        }
        .onChange(of: store.friendInvitations.map(\.id)) { old, _ in
            if store.friendInvitations.contains(where: { $0.owner.id != store.accountID && !old.contains($0.id) }) { tab = 4 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayCloudError)) { note in store.error = note.userInfo?["message"] as? String }
        .onChange(of: phase) { _, new in if new == .active { Task { await store.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayCloudChanged)) { _ in Task { await store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .groupPayOpenBill)) { note in
            let id = (note.userInfo?["billID"] as? UUID) ?? (note.userInfo?["billID"] as? String).flatMap(UUID.init(uuidString:))
            guard let id else { return }
            Task { await store.refresh(); tab = 0; route = [id] }
        }
        .task(id: phase) {
            // Reconcile visible approvals even when iOS coalesces a background push.
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await store.refresh()
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill").font(.title2).foregroundStyle(GP.mint)
                    Text("group pay").font(.system(.title2, design: .rounded, weight: .bold)).tracking(-0.7)
                    Spacer(minLength: 8)
                    TestModeBadge()
                }.padding(.top, 18)
                hero
                if !store.connected { connectionBanner }
                HStack(spacing: 0) {
                    metric("Active splits", value: "\(store.activeBills.count)", symbol: "person.2")
                    Rectangle().fill(GP.border).frame(width: 1, height: 48).padding(.horizontal, 20)
                    metric("Settled together", value: Money.string(cents: store.paidTotal), symbol: "checkmark.circle")
                }.padding(.vertical, 3)
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your splits", detail: store.bills.isEmpty ? nil : "\(store.bills.count)")
                    if store.bills.isEmpty {
                        EmptyPanel(symbol: "receipt", title: "Good company. Easy splits.", subtitle: "Dinner out, groceries in, or the bills you share. Your first split starts here.")
                    }
                    ForEach(store.bills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain)
                    }
                }
                if store.bills.contains(where: { $0.recurrence != .none }) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "repeat").foregroundStyle(GP.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Same crew. Fresh approval.").font(.subheadline.weight(.semibold))
                            Text("Everyone gets a say each time a recurring bill comes around.").font(.caption).foregroundStyle(GP.secondary)
                        }
                    }.padding(.horizontal, 4)
                }
            }.padding(.horizontal, 24).padding(.bottom, 30)
        }.gpPage().toolbar(.hidden, for: .navigationBar).refreshable { await store.refresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LESS MATH. MORE MOMENTS.").font(.caption2.weight(.bold)).tracking(1.2)
                    Text("Life’s better\nshared.")
                        .font(.system(size: heroTitleSize, weight: .semibold, design: .rounded)).tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                    Text("One bill. Everyone’s part.").font(.subheadline).foregroundStyle(GP.background.opacity(0.7))
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    ReceiptIllustration().frame(width: 94, height: 130).accessibilityHidden(true)
                }
            }
            Button { composing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                    Text("Start a split").font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.body.weight(.medium))
                }.padding(18).foregroundStyle(GP.mint).background(GP.background, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain).accessibilityIdentifier("startSplit")
        }.padding(24).foregroundStyle(GP.background)
            .background {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [GP.mint, Color(red: 0.68, green: 0.85, blue: 0.57)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(.white.opacity(0.12)).frame(width: 240).offset(x: 90, y: -100)
                }.clipShape(RoundedRectangle(cornerRadius: 30))
            }
    }

    private var connectionBanner: some View {
        Button { tab = 3 } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isPreview ? "sparkles" : "person.2.badge.plus").font(.title3).foregroundStyle(GP.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isPreview ? "A little look around" : "Bring your people along").font(.subheadline.weight(.semibold)).foregroundStyle(GP.text)
                    Text(store.isPreview ? "Sample bills · Read only" : "Connect iCloud to share your first bill.").font(.caption).foregroundStyle(GP.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(GP.secondary)
            }.padding(16).background(GP.surface, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private func metric(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(GP.secondary)
            Text(value).font(.system(.title, design: .rounded, weight: .semibold)).tracking(-0.7).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String, detail: String? = nil) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold)).tracking(-0.3)
            Spacer()
            if let detail { Text(detail).font(.caption.weight(.medium)).foregroundStyle(GP.secondary) }
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A little nudge. Then you’re all set.").font(.subheadline).foregroundStyle(GP.secondary)
                if store.pendingBills.isEmpty {
                    EmptyPanel(symbol: "checkmark.bubble", title: "All caught up.", subtitle: "When someone shares a bill, you’ll find your portion here. Review it, approve it, and get back to the good stuff.")
                } else {
                    sectionHeading("Ready for your review", detail: "\(store.pendingBills.count)")
                    ForEach(store.pendingBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain)
                    }
                }
                if !store.notificationsEnabled && store.connected {
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "bell")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Never miss your turn").font(.headline)
                                Text("A heads-up when your group needs you.").font(.caption).foregroundStyle(GP.secondary)
                            }
                        }
                        Button(store.notificationsDenied ? "Open notification settings" : "Turn on notifications") { Task { await store.enableNotifications() } }.buttonStyle(PrimaryButton())
                    }
                }
                let reviewedBills = store.bills.filter { bill in !store.pendingBills.contains(where: { $0.id == bill.id }) }
                if !reviewedBills.isEmpty {
                    sectionHeading("With your group")
                    ForEach(reviewedBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(.plain)
                    }
                }
            }.padding(24)
        }.navigationTitle("Inbox").navigationBarTitleDisplayMode(.large).gpPage().refreshable { await store.refresh() }
    }

    private var cards: some View {
        let myCards = store.bills.filter { $0.card != nil && $0.leaderID == store.accountID && store.connected }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("One card for every shared plan.").font(.subheadline).foregroundStyle(GP.secondary)
                    Spacer(minLength: 8)
                    TestModeBadge()
                }
                if myCards.isEmpty {
                    VStack(spacing: 24) {
                        CardIllustration().frame(height: 190).padding(.top, 28).accessibilityHidden(true)
                        VStack(spacing: 10) {
                            Text("Good things take a group.").font(.title2.weight(.semibold)).tracking(-0.5)
                            Text("Cards for bills you lead appear here. Everyone else can follow the bill’s status in their inbox.").font(.subheadline).foregroundStyle(GP.secondary).lineSpacing(4)
                        }.multilineTextAlignment(.center).padding(.horizontal, 12)
                        Button("Start a split") { composing = true }.buttonStyle(PrimaryButton()).padding(.top, 6)
                    }.padding(.bottom, 12)
                }
                ForEach(myCards) { bill in
                    NavigationLink { BillDetailView(billID: bill.id) } label: { VirtualCardView(bill: bill) }.buttonStyle(.plain)
                }
                Label("Test cards only. No real money moves.", systemImage: "leaf")
                    .font(.caption).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(24)
        }.navigationTitle("Cards").navigationBarTitleDisplayMode(.large).gpPage()
    }

    private var profile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Avatar(name: store.name, size: 72)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.name.isEmpty ? "Your profile" : store.name).font(.system(.title, design: .rounded, weight: .semibold)).tracking(-0.7)
                        Label(store.connected ? "Connected with iCloud" : "Your people. Your plans.", systemImage: store.connected ? "checkmark.icloud" : "person.2")
                            .font(.caption).foregroundStyle(GP.secondary)
                    }
                }.padding(.vertical, 8)
                Panel {
                    Text("Display name").font(.subheadline.weight(.semibold))
                    TextField("What should we call you?", text: $store.name).gpField().textContentType(.name)
                        .onChange(of: store.name) { _, value in UserDefaults.standard.set(value, forKey: "profileName") }
                    if !store.connected {
                        Text("Use iCloud to invite friends and keep your shared bills together.").font(.subheadline).foregroundStyle(GP.secondary)
                        Button(store.busy ? "Connecting…" : "Connect iCloud") { Task { await store.connect() } }.buttonStyle(PrimaryButton()).disabled(store.busy)
                        if let issue = store.connectionIssue {
                            Text(issue).font(.caption).foregroundStyle(GP.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !store.isPreview {
                            Button("Take a look around") { store.preview(); tab = 0 }.font(.subheadline.weight(.medium)).foregroundStyle(GP.mint).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                    } else if let synced = store.lastSynced {
                        Label("Updated \(synced.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").font(.caption).foregroundStyle(GP.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your preferences")
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "bell")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Notifications").font(.headline)
                                Text(store.notificationsEnabled ? "You’re in the loop." : "Know when it’s your turn to approve.").font(.caption).foregroundStyle(GP.secondary)
                            }
                            Spacer(minLength: 0)
                            if store.notificationsEnabled { Image(systemName: "checkmark.circle.fill").foregroundStyle(GP.mint) }
                        }
                        if !store.notificationsEnabled {
                            if store.connected {
                                Button(store.notificationsDenied ? "Open notification settings" : "Turn on notifications") { Task { await store.enableNotifications() } }
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(GP.mint)
                            } else {
                                Text("Connect iCloud to enable").font(.caption).foregroundStyle(GP.secondary)
                            }
                        }
                    }
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "creditcard")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A space to try things out").font(.headline)
                                Text("All cards and payments use test money.").font(.caption).foregroundStyle(GP.secondary)
                            }
                        }
                        TestModeBadge(label: sandbox.enabled ? "Test cards enabled" : "Test mode")
                        if SandboxCardService.hostedURL != nil {
                            Button { showingTeamAccess = true } label: {
                                HStack {
                                    Text("Team access")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.frame(minHeight: 44)
                            }.font(.subheadline.weight(.semibold)).foregroundStyle(GP.mint)
                        }
                    }
                }
                #if DEBUG
                DisclosureGroup {
                    Button { showingSandbox = true } label: {
                        HStack {
                            Label("Card connection", systemImage: "slider.horizontal.3")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.font(.subheadline).padding(.vertical, 14)
                    }.foregroundStyle(GP.mint)
                } label: {
                    Text("Advanced settings").font(.subheadline).foregroundStyle(GP.secondary)
                }.tint(GP.secondary).padding(.horizontal, 4)
                #endif
                Text("A little easier, together.").font(.caption).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.bottom, 8)
            }.padding(24)
        }.navigationTitle("Profile").navigationBarTitleDisplayMode(.large).gpPage()
    }
}

struct BillRow: View {
    let bill: Bill
    var body: some View {
        Panel(padding: 18) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: bill.category.systemImage, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(bill.title).font(.headline).foregroundStyle(GP.text)
                    Text(bill.recurrence == .none ? bill.createdAt.formatted(date: .abbreviated, time: .omitted) : "\(bill.recurrence.rawValue) · \(bill.cycle)")
                        .font(.caption).foregroundStyle(GP.secondary)
                }
                Spacer(minLength: 4)
                Text(Money.string(cents: bill.totalCents)).font(.system(.headline, design: .rounded)).foregroundStyle(GP.text).lineLimit(1).minimumScaleFactor(0.7)
            }
            Rectangle().fill(GP.border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack {
                    people
                    Spacer(minLength: 8)
                    StatusPill(bill: bill)
                }
                VStack(alignment: .leading, spacing: 12) { people; StatusPill(bill: bill) }
            }
        }.accessibilityElement(children: .combine)
    }
    private var people: some View {
        HStack(spacing: 8) {
            HStack(spacing: -9) {
                ForEach(Array(bill.members.prefix(3).enumerated()), id: \.element.id) { index, member in Avatar(name: member.name, index: index, size: 28) }
            }
            Text("\(bill.approvedCount) of \(bill.members.count) approved").font(.caption2).foregroundStyle(GP.secondary)
        }
    }
}

struct VirtualCardView: View {
    let bill: Bill
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Label("group pay", systemImage: "circle.hexagongrid.fill").font(.system(.headline, design: .rounded))
                Spacer()
                Text("Test card").font(.caption2.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(GP.background.opacity(0.08), in: Capsule())
            }
            HStack(alignment: .center) {
                Image(systemName: "simcard").font(.system(size: 34, weight: .ultraLight)).rotationEffect(.degrees(90))
                Spacer()
                Text("••••  \(bill.card?.lastFour ?? "0000")").font(.system(.title3, design: .monospaced, weight: .medium))
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bill.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(bill.status == .paid ? "Settled together" : bill.card?.provider == "marqetaSandbox" ? "Initial test balance" : "Ready for this bill")
                        .font(.caption).foregroundStyle(GP.background.opacity(0.65))
                }
                Spacer(minLength: 12)
                Text(Money.string(cents: bill.card?.remainingCents ?? 0))
                    .font(.system(.title, design: .rounded, weight: .semibold)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.7)
            }
        }.padding(26).foregroundStyle(GP.background)
            .background {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [GP.mint, Color(red: 0.59, green: 0.79, blue: 0.59)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().stroke(.white.opacity(0.12), lineWidth: 32).frame(width: 230).offset(x: 80, y: -105)
                    Circle().stroke(.white.opacity(0.09), lineWidth: 1).frame(width: 320).offset(x: 115, y: -140)
                }.clipShape(RoundedRectangle(cornerRadius: 28))
            }
            .accessibilityElement(children: .combine)
    }
}

private struct ReceiptIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(GP.background.opacity(0.08)).frame(width: 80, height: 104).rotationEffect(.degrees(12)).offset(x: 8, y: 5)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "fork.knife").font(.title3).frame(maxWidth: .infinity)
                Rectangle().fill(GP.background.opacity(0.1)).frame(height: 1)
                ForEach(0..<3) { index in
                    HStack {
                        Capsule().fill(GP.background.opacity(0.16)).frame(width: index == 1 ? 22 : 32, height: 4)
                        Spacer(minLength: 4)
                        Circle().fill(GP.background.opacity(0.24)).frame(width: 4, height: 4)
                    }
                }
            }.padding(15).frame(width: 86).background(Color(red: 0.96, green: 0.98, blue: 0.86), in: RoundedRectangle(cornerRadius: 14))
                .rotationEffect(.degrees(-8)).shadow(color: GP.background.opacity(0.12), radius: 12, x: 0, y: 8)
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(GP.mint)
                .frame(width: 30, height: 30).background(GP.background, in: Circle()).offset(x: 34, y: 53)
        }
    }
}

private struct CardIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(GP.raised).frame(width: 240, height: 145).rotationEffect(.degrees(-9)).offset(x: -12, y: -12)
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    Image(systemName: "circle.hexagongrid.fill")
                    Text("group pay").font(.system(.subheadline, design: .rounded, weight: .bold))
                    Spacer()
                }
                Image(systemName: "sparkles").font(.title2.weight(.light))
                HStack(spacing: 5) { ForEach(0..<4) { _ in Capsule().fill(GP.mint.opacity(0.25)).frame(width: 22, height: 4) } }
            }.padding(23).frame(width: 250, height: 155).foregroundStyle(GP.mint)
                .background(LinearGradient(colors: [GP.raised, GP.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(GP.mint.opacity(0.16)))
                .rotationEffect(.degrees(7)).offset(x: 12, y: 8)
        }.frame(maxWidth: .infinity)
    }
}
