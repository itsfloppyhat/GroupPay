import SwiftUI

struct PeopleView: View {
    @Environment(AppStore.self) private var store
    @State private var addingFriend = false
    @State private var creatingGroup = false
    @State private var removing: SavedFriend?
    @State private var accepting: FriendInvitation?
    @State private var cancelling: FriendInvitation?
    @State private var invitationToShare: FriendInvitation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(overline: "Your people", title: "Good company.\nOn repeat.")
                Button { addingFriend = true } label: {
                    Label("Add friend", systemImage: "person.badge.plus")
                }.buttonStyle(PrimaryButton()).disabled(store.busy).accessibilityIdentifier("addFriend")
                if !store.connected {
                    EmptyPanel(symbol: "person.2", title: "Keep your people close.", subtitle: "Connect iCloud in Profile to save friends and create reusable groups.")
                } else {
                    invitations
                    HStack {
                        Text("Your groups").font(GP.display(22, relativeTo: .title3))
                        Spacer()
                        Button { creatingGroup = true } label: { Label("New group", systemImage: "plus") }
                            .font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint).disabled(store.friends.isEmpty || store.busy)
                    }
                    if store.groups.isEmpty {
                        EmptyPanel(symbol: "person.3", title: "An invitation that lasts.", subtitle: "Add friends, then make a group. Once everyone accepts the group invitation, future bills arrive here without another text.")
                    }
                    ForEach(store.groups) { group in
                        Panel {
                            HStack(spacing: 14) {
                                IconTile(symbol: "person.3.fill")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.name).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                    Text(group.members.map(\.name).joined(separator: ", "))
                                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                                }
                            }
                            if group.ownerID == store.accountID {
                                Button { Task { await store.invite(group) } } label: { Label("Invite or manage group", systemImage: "person.badge.plus") }
                                    .font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(store.busy)
                                Text("Choose this group when starting your next split. Members accept this invitation once.")
                                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            } else {
                                Text("New bills from this group will appear automatically.")
                                    .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                            }
                        }
                    }
                    Text("Saved friends").font(GP.display(22, relativeTo: .title3))
                    if store.friends.isEmpty {
                        Text("Add a friend now so they’re ready for your first split. You can also save people from past bills.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    }
                    ForEach(store.friends) { friend in
                        Panel(padding: 16) {
                            HStack(spacing: 12) {
                                Avatar(name: friend.name)
                                Text(friend.name).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                Spacer()
                                Button { removing = friend } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                                    .foregroundStyle(GP.secondary).accessibilityLabel("Remove \(friend.name) from saved friends").disabled(store.busy)
                            }
                        }
                    }
                    if !store.friendSuggestions.isEmpty {
                        Text("People you’ve split with").font(GP.display(22, relativeTo: .title3))
                        ForEach(store.friendSuggestions) { friend in
                            Panel(padding: 16) {
                                HStack(spacing: 12) {
                                    Avatar(name: friend.name)
                                    Text(friend.name).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                                    Spacer()
                                    Button("Save friend") { Task { await store.saveFriend(friend) } }
                                        .font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(store.busy)
                                }
                            }
                        }
                    }
                }
            }.padding(22)
        }.gpPage().navigationTitle("People").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $addingFriend, onDismiss: {
                guard let invitation = invitationToShare else { return }
                invitationToShare = nil
                Task { await store.invite(invitation) }
            }) {
                AddFriendView { invitationToShare = $0 }.environment(store)
            }
            .sheet(item: $accepting) { invitation in
                AddFriendView(invitation: invitation).environment(store)
            }
            .sheet(isPresented: $creatingGroup) { NewGroupView().environment(store) }
            .confirmationDialog("Remove saved friend?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let friend = removing {
                    Button("Remove \(friend.name)", role: .destructive) {
                        Task { await store.removeFriend(friend) }; removing = nil
                    }
                }
            } message: { Text("Existing groups and shared bills stay available.") }
            .confirmationDialog("Cancel friend invitation?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
                if let invitation = cancelling {
                    Button("Cancel invitation", role: .destructive) {
                        Task { await store.removeFriendInvitation(invitation) }; cancelling = nil
                    }
                }
            } message: { Text("This invitation will stop working. You can invite your friend again later.") }
    }

    @ViewBuilder private var invitations: some View {
        if !store.friendInvitations.isEmpty {
            Text("Friend invitations").font(GP.display(22, relativeTo: .title3))
            ForEach(store.friendInvitations) { invitation in
                let outgoing = invitation.owner.id == store.accountID
                Panel(padding: 18) {
                    HStack(spacing: 12) {
                        Avatar(name: outgoing ? invitation.recipientName : invitation.owner.name)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outgoing ? invitation.recipientName : invitation.owner.name).font(GP.body(17, weight: .semibold, relativeTo: .headline))
                            Text(outgoing ? "Waiting for your friend to join" : "Wants to add you as a friend")
                                .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let issue = invitation.connectionIssue {
                        Text(issue).font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.amber)
                    }
                    if outgoing {
                        HStack {
                            Button(invitation.connectionIssue == nil ? "Share invitation" : "Manage invitation") { Task { await store.invite(invitation) } }
                                .foregroundStyle(GP.mint)
                            Spacer()
                            Button("Cancel", role: .destructive) { cancelling = invitation }
                                .foregroundStyle(GP.secondary)
                        }.font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).frame(minHeight: 44).disabled(store.busy)
                    } else {
                        Button("Add friend") { accepting = invitation }
                            .buttonStyle(PrimaryButton()).disabled(store.busy)
                    }
                }
            }
        }
    }
}

private struct AddFriendView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var invitation: FriendInvitation?
    var onCreated: (FriendInvitation) -> Void = { _ in }
    @State private var yourName = ""
    @State private var friendName = ""
    @State private var issue: String?

    private var valid: Bool {
        let name = yourName.trimmingCharacters(in: .whitespacesAndNewlines)
        let friend = friendName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 100 && (invitation != nil || (!friend.isEmpty && friend.count <= 100))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(overline: "Your people", title: invitation == nil ? "Friends first.\nSplits later." : "Keep in touch.")
                    Text(invitation.map { "Add \($0.owner.name) to your saved friends. You’ll be saved in their list, too." }
                         ?? "Send a private invitation. Once your friend joins, you’ll both have each other saved for future splits.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    Panel {
                        Text("Your name").font(GP.body(15, weight: .semibold, relativeTo: .subheadline))
                        TextField("How your friends know you", text: $yourName).textContentType(.name).gpField()
                            .accessibilityIdentifier("friendInvitationYourName")
                        if invitation == nil {
                            Text("Friend’s name").font(GP.body(15, weight: .semibold, relativeTo: .subheadline)).padding(.top, 8)
                            TextField("Who would you like to add?", text: $friendName).textContentType(.name).gpField()
                                .accessibilityIdentifier("friendInvitationRecipientName")
                        }
                    }
                    Text("Adding a friend doesn’t share any bills. Choose who’s included each time you split or create a group.")
                        .font(GP.body(12, weight: .regular, relativeTo: .caption)).foregroundStyle(GP.secondary)
                    if !store.connected {
                        Label("Connect iCloud in Profile to add friends.", systemImage: "icloud")
                            .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.amber)
                    }
                    if let issue { Text(issue).font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.amber) }
                    Button(store.busy ? "Saving…" : invitation == nil ? "Create invitation" : "Add friend") {
                        Task {
                            issue = nil
                            if let invitation {
                                if await store.acceptFriendInvitation(invitation, name: yourName) { dismiss() }
                            } else if let created = await store.createFriendInvitation(name: yourName, friendName: friendName) {
                                onCreated(created)
                                dismiss()
                            }
                            if let error = store.error { issue = error; store.error = nil }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(!valid || !store.connected || store.busy)
                        .accessibilityIdentifier("saveFriendInvitation")
                }.padding(22)
            }.gpPage().navigationTitle(invitation == nil ? "Add friend" : "Friend invitation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
                .onAppear { yourName = store.name == "You" ? "" : store.name }
        }.preferredColorScheme(.light).tint(GP.mint).interactiveDismissDisabled(store.busy)
    }
}

private struct NewGroupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected = Set<String>()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeading(overline: "Together again", title: "Make it a group.")
                    TextField("Group name", text: $name).gpField()
                    Text("You’re included as the group organizer.").font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    ForEach(store.friends) { friend in
                        Button {
                            if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) }
                        } label: {
                            Panel(padding: 18) {
                                HStack {
                                    Avatar(name: friend.name)
                                    Text(friend.name).font(GP.body(17, weight: .semibold, relativeTo: .headline)).foregroundStyle(GP.text)
                                    Spacer()
                                    Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(GP.mint)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("After creating the group, use Invite or manage group to send one invitation. Future bills in this group share access automatically.")
                        .font(GP.body(15, weight: .regular, relativeTo: .subheadline)).foregroundStyle(GP.secondary)
                    Button(store.busy ? "Creating…" : "Create group") {
                        Task {
                            if await store.createGroup(name: name, friends: store.friends.filter { selected.contains($0.id) }) != nil { dismiss() }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || selected.count > 49)
                }.padding(22)
            }.gpPage().navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
        }.preferredColorScheme(.light).tint(GP.mint).interactiveDismissDisabled(store.busy)
    }
}
