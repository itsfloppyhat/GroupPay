import SwiftUI

struct TeamAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = SandboxCardService.shared
    @State private var accessCode = ""
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    private var savedTeamConnection: Bool {
        guard let hostedURL = SandboxCardService.hostedURL else { return false }
        return service.configured && service.baseURL == hostedURL
    }

    private var canJoin: Bool {
        !busy && SandboxCardService.hostedURL != nil &&
            (savedTeamConnection || !accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(overline: "Group Pay beta", title: "Join your team.")
                    if SandboxCardService.hostedURL != nil {
                        Panel(padding: 24) {
                            IconTile(symbol: "person.2.fill", size: 52)
                            Text("Connect with your team.")
                                .font(GP.display(26, relativeTo: .title2))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Enter the code from your team organizer to connect your group’s test cards.")
                                .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            SecureField("Team access code", text: $accessCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .focused($codeFocused)
                                .submitLabel(.go)
                                .onSubmit { joinTeam() }
                                .disabled(busy)
                                .gpField()
                            if savedTeamConnection {
                                Text("Your code is saved securely. Leave this blank to check your connection.")
                                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button(action: joinTeam) {
                                HStack(spacing: 9) {
                                    if busy { ProgressView().tint(GP.background) }
                                    Text(busy ? "Joining…" : savedTeamConnection && service.enabled ? "Check connection" : "Join")
                                }
                            }.buttonStyle(PrimaryButton()).disabled(!canJoin)
                            if let status {
                                Label(status, systemImage: "checkmark.circle.fill")
                                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if savedTeamConnection && service.enabled {
                                Label("Your team access is ready.", systemImage: "checkmark.circle.fill")
                                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.mint)
                            }
                            if let error {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.amber)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Your code stays securely on this device. Joining doesn’t create a card or move money.")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        EmptyPanel(symbol: "person.2", title: "Team access isn’t available yet.",
                                   subtitle: "Ask your team organizer for an updated version of Group Pay, then try again.")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TestModeBadge()
                        Text("All cards use test funds. No real money moves.")
                            .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(22)
            }
            .gpPage()
            .navigationTitle("Team access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(busy)
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(GP.mint)
        .interactiveDismissDisabled(busy)
        .onDisappear { accessCode = "" }
    }

    private func joinTeam() {
        guard canJoin, let hostedURL = SandboxCardService.hostedURL else { return }
        busy = true
        error = nil
        status = nil
        codeFocused = false
        Task {
            defer { busy = false }
            do {
                // Changing the destination requires an explicitly entered code;
                // only an existing connection to this team can reuse Keychain.
                try service.saveConnection(url: hostedURL, token: accessCode)
                accessCode = ""
                guard try await service.health() else { throw SandboxConnectionError.unconfiguredBackend }
                service.enabled = true
                status = "You’re connected. Your team’s test cards are ready."
            } catch let failure as SandboxConnectionError {
                self.error = failure.localizedDescription
            } catch {
                self.error = "We couldn’t connect to your team. Please try again."
            }
        }
    }
}
