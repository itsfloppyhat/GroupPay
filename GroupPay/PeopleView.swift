import SwiftUI

struct PeopleView: View {
    @Environment(AppStore.self) private var store
    @State private var creatingGroup = false
    @State private var removing: SavedFriend?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(overline: "Your people", title: "Good company.\nOn repeat.")
                if !store.connected {
                    EmptyPanel(symbol: "person.2", title: "Keep your people close.", subtitle: "Connect iCloud in Profile to save friends and create reusable groups.")
                } else {
                    HStack {
                        Text("Your groups").font(.title3.weight(.semibold))
                        Spacer()
                        Button { creatingGroup = true } label: { Label("New group", systemImage: "plus") }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(GP.mint).disabled(store.friends.isEmpty || store.busy)
                    }
                    if store.groups.isEmpty {
                        EmptyPanel(symbol: "person.3", title: "An invitation that lasts.", subtitle: "Save a friend below, then make a group. Once everyone accepts the group invitation, future bills arrive here without another text.")
                    }
                    ForEach(store.groups) { group in
                        Panel {
                            HStack(spacing: 14) {
                                IconTile(symbol: "person.3.fill")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.name).font(.headline)
                                    Text(group.members.map(\.name).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(GP.secondary)
                                }
                            }
                            if group.ownerID == store.accountID {
                                Button { Task { await store.invite(group) } } label: { Label("Invite or manage group", systemImage: "person.badge.plus") }
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(store.busy)
                                Text("Choose this group when starting your next split. Members accept this invitation once.")
                                    .font(.caption).foregroundStyle(GP.secondary)
                            } else {
                                Text("New bills from this group will appear automatically.")
                                    .font(.caption).foregroundStyle(GP.secondary)
                            }
                        }
                    }
                    Text("Saved friends").font(.title3.weight(.semibold))
                    if store.friends.isEmpty {
                        Text("People who join your bills can be saved here for next time.").font(.subheadline).foregroundStyle(GP.secondary)
                    }
                    ForEach(store.friends) { friend in
                        Panel(padding: 16) {
                            HStack(spacing: 12) {
                                Avatar(name: friend.name)
                                Text(friend.name).font(.headline)
                                Spacer()
                                Button { removing = friend } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                                    .foregroundStyle(GP.secondary).accessibilityLabel("Remove \(friend.name) from saved friends").disabled(store.busy)
                            }
                        }
                    }
                    if !store.friendSuggestions.isEmpty {
                        Text("People you’ve split with").font(.title3.weight(.semibold))
                        ForEach(store.friendSuggestions) { friend in
                            Panel(padding: 16) {
                                HStack(spacing: 12) {
                                    Avatar(name: friend.name)
                                    Text(friend.name).font(.headline)
                                    Spacer()
                                    Button("Save friend") { Task { await store.saveFriend(friend) } }
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(GP.mint).frame(minHeight: 44).disabled(store.busy)
                                }
                            }
                        }
                    }
                }
            }.padding(22)
        }.gpPage().navigationTitle("People").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $creatingGroup) { NewGroupView().environment(store) }
            .confirmationDialog("Remove saved friend?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let friend = removing {
                    Button("Remove \(friend.name)", role: .destructive) {
                        Task { await store.removeFriend(friend) }; removing = nil
                    }
                }
            } message: { Text("Existing groups and shared bills stay available.") }
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
                    Text("You’re included as the group organizer.").font(.subheadline).foregroundStyle(GP.secondary)
                    ForEach(store.friends) { friend in
                        Button {
                            if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) }
                        } label: {
                            Panel(padding: 18) {
                                HStack {
                                    Avatar(name: friend.name)
                                    Text(friend.name).font(.headline).foregroundStyle(GP.text)
                                    Spacer()
                                    Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(GP.mint)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("After creating the group, use Invite or manage group to send one invitation. Future bills in this group share access automatically.")
                        .font(.subheadline).foregroundStyle(GP.secondary)
                    Button(store.busy ? "Creating…" : "Create group") {
                        Task {
                            if await store.createGroup(name: name, friends: store.friends.filter { selected.contains($0.id) }) != nil { dismiss() }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || selected.count > 49)
                }.padding(22)
            }.gpPage().navigationTitle("New group").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.busy) } }
        }.preferredColorScheme(.dark).tint(GP.mint).interactiveDismissDisabled(store.busy)
    }
}
