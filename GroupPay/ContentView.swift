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
        .tint(GP.mint).preferredColorScheme(.light)
        .environment(store)
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isSimulatorDemo {
                Text("Simulator demo · \(store.name) · No real money")
                    .font(GP.body(11, weight: .regular, relativeTo: .caption2)).foregroundStyle(GP.mint).frame(maxWidth: .infinity).padding(.vertical, 5).background(GP.background)
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .groupPayOpenInbox)) { _ in
            tab = 1
            Task { await store.refresh() }
        }
        .task(id: phase) {
            // Reconcile visible approvals even when iOS coalesces a background push.
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(store.isSimulatorDemo ? 1 : 30)) } catch { return }
                await store.refresh()
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill").font(.title2).foregroundStyle(GP.mint)
                    Text("group pay").font(GP.display(26, relativeTo: .title2)).tracking(-0.7)
                    Spacer(minLength: 8)
                    TestModeBadge()
                }.padding(.top, 18)
                hero
                if !store.connected { connectionBanner }
                syncIssue
                HStack(spacing: 0) {
                    metric("Active splits", value: "\(store.activeBills.count)", symbol: "person.2")
                    Rectangle().fill(GP.border).frame(width: 1, height: 48).padding(.horizontal, 20)
                    metric("Settled together", value: Money.string(cents: store.paidTotal), symbol: "checkmark.circle")
                }.padding(20).background(GP.raised, in: RoundedRectangle(cornerRadius: 28))
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your splits", detail: store.visibleBills.isEmpty ? nil : "\(store.visibleBills.count)")
                    if store.visibleBills.isEmpty {
                        EmptyPanel(symbol: "receipt", title: "Good company. Easy splits.", subtitle: "Dinner out, groceries in, or the bills you share. Your first split starts here.")
                    }
                    ForEach(store.visibleBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(SoftPressButton())
                    }
                }
                if store.visibleBills.contains(where: { $0.recurrence != .none }) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "repeat").foregroundStyle(GP.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Same crew. Fresh approval.").font(GP.body(15, weight: .semibold, relativeTo: .subheadline))
                            Text("Everyone gets a say each time a recurring bill comes around.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                    }.padding(.horizontal, 4)
                }
                cancelledSplits
            }.padding(.horizontal, 24).padding(.bottom, 30)
        }.gpPage().toolbar(.hidden, for: .navigationBar).refreshable { await store.refresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LESS MATH. MORE MOMENTS.").font(GP.body(11, weight: .bold, relativeTo: .caption2)).tracking(1.2)
                    Text("Life’s better\nshared.")
                        .font(.custom("Caprasimo-Regular", fixedSize: heroTitleSize)).tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                    Text("One bill. Everyone’s part.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    ReceiptIllustration().frame(width: 94, height: 130).accessibilityHidden(true)
                }
            }
            Button { composing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(GP.body(17, weight: .semibold, relativeTo: .body))
                    Text("Start a split").font(GP.body(17, weight: .semibold, relativeTo: .body))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(GP.body(17, weight: .medium, relativeTo: .body))
                }.padding(18).foregroundStyle(GP.raised).background(GP.mint, in: Capsule())
            }.buttonStyle(SoftPressButton()).accessibilityIdentifier("startSplit")
        }.padding(24).foregroundStyle(GP.text)
            .background {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [GP.peach, GP.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(GP.accent.opacity(0.12)).frame(width: 240).offset(x: 90, y: -100)
                }.clipShape(RoundedRectangle(cornerRadius: 30))
            }
    }

    private var connectionBanner: some View {
        Button { tab = 3 } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isPreview ? "sparkles" : "person.2.badge.plus").font(.title3).foregroundStyle(GP.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isPreview ? "A little look around" : "Bring your people along").font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.text)
                    Text(store.isPreview ? "Sample bills · Read only" : store.connected ? "Create a split to get started." : "Connect iCloud to share your first bill.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(GP.body(12, weight: .semibold, relativeTo: .caption)).foregroundStyle(GP.secondary)
            }.padding(16).background(GP.surface, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private func metric(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol).font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
            Text(value).font(GP.display(30)).contentTransition(.numericText()).gpAnimate(value).tracking(-0.7).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String, detail: String? = nil) -> some View {
        HStack {
            Text(title).font(GP.display(22, relativeTo: .title3)).tracking(-0.3)
            Spacer()
            if let detail { Text(detail).font(GP.body(12, weight: .medium, relativeTo: .caption)).foregroundStyle(GP.secondary) }
        }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("A little nudge. Then you’re all set.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                syncIssue
                if store.pendingBills.isEmpty {
                    if store.connectionIssue == nil {
                        EmptyPanel(symbol: "checkmark.bubble", title: "All caught up.", subtitle: "When someone shares a bill, you’ll find your portion here. Review it, approve it, and get back to the good stuff.")
                    }
                } else {
                    sectionHeading("Ready for your review", detail: "\(store.pendingBills.count)")
                    ForEach(store.pendingBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(SoftPressButton())
                    }
                }
                if !store.notificationsEnabled && store.connected {
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "bell")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Never miss your turn").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                Text("A heads-up when your group needs you.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                        }
                        Button(store.notificationsDenied ? "Open notification settings" : "Turn on notifications") { Task { await store.enableNotifications() } }.buttonStyle(PrimaryButton())
                    }
                }
                let reviewedBills = store.visibleBills.filter { bill in !store.pendingBills.contains(where: { $0.id == bill.id }) }
                if !reviewedBills.isEmpty {
                    sectionHeading("With your group")
                    ForEach(reviewedBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }.buttonStyle(SoftPressButton())
                    }
                }
                cancelledSplits
            }.padding(24)
        }.navigationTitle("Inbox").navigationBarTitleDisplayMode(.large).gpPage().refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh inbox").disabled(!store.connected || store.busy || store.refreshing)
                }
            }
    }

    @ViewBuilder private var cancelledSplits: some View {
        if !store.cancelledBills.isEmpty {
            DisclosureGroup {
                VStack(spacing: 12) {
                    ForEach(store.cancelledBills) { bill in
                        NavigationLink { BillDetailView(billID: bill.id) } label: { BillRow(bill: bill) }
                            .buttonStyle(.plain)
                    }
                }.padding(.top, 12)
            } label: {
                Label("Cancelled splits · \(store.cancelledBills.count)", systemImage: "archivebox")
                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
            }.tint(GP.secondary)
        }
    }

    @ViewBuilder private var syncIssue: some View {
        if store.connected, let issue = store.connectionIssue {
            Panel {
                Label("Updates paused", systemImage: "icloud.slash").font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.amber)
                Text(issue).font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                Button("Try refreshing") { Task { await store.refresh() } }
                    .font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).disabled(store.busy || store.refreshing)
            }
        }
    }

    private var cards: some View {
        let myCards = store.visibleBills.filter { $0.card != nil && $0.leaderID == store.accountID && store.connected }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("One card for every shared plan.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    Spacer(minLength: 8)
                    TestModeBadge()
                }
                if myCards.isEmpty {
                    VStack(spacing: 24) {
                        CardIllustration().frame(height: 190).padding(.top, 28).accessibilityHidden(true)
                        VStack(spacing: 10) {
                            Text("Good things take a group.").font(GP.display(26, relativeTo: .title2)).tracking(-0.5)
                            Text("Cards for bills you lead appear here. Everyone else can follow the bill’s status in their inbox.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary).lineSpacing(4)
                        }.multilineTextAlignment(.center).padding(.horizontal, 12)
                        Button("Start a split") { composing = true }.buttonStyle(PrimaryButton()).padding(.top, 6)
                    }.padding(.bottom, 12)
                }
                ForEach(myCards) { bill in
                    NavigationLink { BillDetailView(billID: bill.id) } label: { VirtualCardView(bill: bill) }.buttonStyle(.plain)
                }
                Label("Test cards only. No real money moves.", systemImage: "leaf")
                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(24)
        }.navigationTitle("Cards").navigationBarTitleDisplayMode(.large).gpPage()
    }

    private var profile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 18) {
                    Avatar(name: store.name, size: 72)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.name.isEmpty ? "Your profile" : store.name).font(GP.display(30)).tracking(-0.7)
                        Label(store.connectionLabel, systemImage: store.connected ? "checkmark.icloud" : "person.2")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    }
                }.padding(.vertical, 8)
                #if DEBUG && targetEnvironment(simulator)
                Panel {
                    Label("Roommate recording demo", systemImage: "play.rectangle").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                    Text("Start Matthew on the first simulator, then Dylan on the second. Curtis uses Safari on the third. Bills and approvals stay in this Mac’s temporary demo session.")
                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    Button("Matthew · Leader") { Task { await store.startSimulatorDemo(.matthew); if store.connected { tab = 0 } } }
                        .buttonStyle(PrimaryButton()).disabled(store.busy)
                    Button("Dylan · Saved friend") { Task { await store.startSimulatorDemo(.dylan); if store.connected { tab = 0 } } }
                        .buttonStyle(PrimaryButton()).disabled(store.busy)
                }
                #endif
                Panel {
                    Text("Display name").font(GP.body(15, weight: .semibold, relativeTo: .subheadline))
                    TextField("What should we call you?", text: $store.name).gpField().textContentType(.name)
                        .onChange(of: store.name) { _, value in UserDefaults.standard.set(value, forKey: "profileName") }
                    if !store.connected {
                        Text("Use iCloud to invite friends and keep your shared bills together.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                        Button(store.busy ? "Connecting…" : "Connect iCloud") { Task { await store.connect() } }.buttonStyle(PrimaryButton()).disabled(store.busy)
                        if let issue = store.connectionIssue {
                            Text(issue).font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !store.isPreview {
                            Button("Take a look around") { store.preview(); tab = 0 }.font(GP.body(15, weight: .medium, relativeTo: .subheadline)).foregroundStyle(GP.mint).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                    } else if let synced = store.lastSynced {
                        Label("Updated \(synced.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your preferences")
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "bell")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Notifications").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                Text(store.notificationsEnabled ? "You’re in the loop." : "Know when it’s your turn to approve.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                            Spacer(minLength: 0)
                            if store.notificationsEnabled { Image(systemName: "checkmark.circle.fill").foregroundStyle(GP.mint) }
                        }
                        if !store.notificationsEnabled {
                            if store.connected {
                                Button(store.notificationsDenied ? "Open notification settings" : "Turn on notifications") { Task { await store.enableNotifications() } }
                                    .font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                            } else {
                                Text("Connect iCloud to enable").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                        } else {
                            Button(store.sendingNotificationTest ? "Sending…" : "Send test notification") {
                                Task { await store.sendTestNotification() }
                            }.font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                                .disabled(store.sendingNotificationTest).accessibilityIdentifier("sendTestNotification")
                            Text("Check where alerts appear on your phone or mirrored Mac.")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                    }
                    Panel {
                        HStack(spacing: 14) {
                            IconTile(symbol: "creditcard")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A space to try things out").font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                Text("All cards and payments use test money.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                        }
                        TestModeBadge(label: sandbox.enabled ? "Test cards enabled" : "Test mode")
                        if SandboxCardService.hostedURL != nil {
                            Button { showingTeamAccess = true } label: {
                                HStack {
                                    Text("Team access")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(GP.body(12, weight: .regular, relativeTo: .caption))
                                }.frame(minHeight: 44)
                            }.font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                        }
                    }
                }
                #if DEBUG
                DisclosureGroup {
                    Button { showingSandbox = true } label: {
                        HStack {
                            Label("Card connection", systemImage: "slider.horizontal.3")
                            Spacer()
                            Image(systemName: "chevron.right").font(GP.body(12, weight: .regular, relativeTo: .caption))
                        }.font(GP.body(15, weight: .regular, relativeTo: .subheadline)).padding(.vertical, 14)
                    }.foregroundStyle(GP.mint)
                } label: {
                    Text("Advanced settings").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                }.tint(GP.secondary).padding(.horizontal, 4)
                #endif
                Text("A little easier, together.").font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary).frame(maxWidth: .infinity).padding(.bottom, 8)
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
                    Text(bill.title).font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.text)
                    Text(bill.recurrence == .none ? bill.createdAt.formatted(date: .abbreviated, time: .omitted) : "\(bill.recurrence.rawValue) · \(bill.cycle)")
                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
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
            Text(bill.status == .cancelled ? "No payment due" : "\(bill.approvedCount) of \(bill.members.count) approved")
                .font(GP.body(11, weight: .regular, relativeTo: .caption2)).foregroundStyle(GP.secondary)
        }
    }
}

struct VirtualCardView: View {
    let bill: Bill
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Label("group pay", systemImage: "circle.hexagongrid.fill").font(GP.display(21, relativeTo: .headline))
                Spacer()
                Text("Test card").font(GP.body(11, weight: .semibold, relativeTo: .caption2)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(GP.background.opacity(0.08), in: Capsule())
            }
            HStack(alignment: .center) {
                Image(systemName: "simcard").font(.system(size: 34, weight: .ultraLight)).rotationEffect(.degrees(90))
                Spacer()
                Text("••••  \(bill.card?.lastFour ?? "0000")").font(.system(.title3, design: .monospaced, weight: .medium))
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bill.title).font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).lineLimit(2)
                    Text(bill.status == .paid ? "Settled together" : bill.card?.provider == "marqetaSandbox" ? "Initial test balance" : "Ready for this bill")
                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.raised.opacity(0.85))
                }
                Spacer(minLength: 12)
                Text(Money.string(cents: bill.card?.remainingCents ?? 0))
                    .font(GP.display(30)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.7)
            }
        }.padding(26).foregroundStyle(GP.raised)
            .background {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [GP.mint, GP.sage], startPoint: .topLeading, endPoint: .bottomTrailing)
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
            RoundedRectangle(cornerRadius: 14).fill(GP.text.opacity(0.08)).frame(width: 80, height: 104).rotationEffect(.degrees(12)).offset(x: 8, y: 5)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "fork.knife").font(.title3).frame(maxWidth: .infinity)
                Rectangle().fill(GP.text.opacity(0.1)).frame(height: 1)
                ForEach(0..<3) { index in
                    HStack {
                        Capsule().fill(GP.text.opacity(0.16)).frame(width: index == 1 ? 22 : 32, height: 4)
                        Spacer(minLength: 4)
                        Circle().fill(GP.text.opacity(0.24)).frame(width: 4, height: 4)
                    }
                }
            }.padding(15).frame(width: 86).background(GP.raised, in: RoundedRectangle(cornerRadius: 14))
                .rotationEffect(.degrees(-8)).shadow(color: GP.text.opacity(0.12), radius: 12, x: 0, y: 8)
            Image(systemName: "checkmark").font(GP.body(12, weight: .bold, relativeTo: .caption)).foregroundStyle(GP.raised)
                .frame(width: 30, height: 30).background(GP.sage, in: Circle()).offset(x: 34, y: 53)
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
