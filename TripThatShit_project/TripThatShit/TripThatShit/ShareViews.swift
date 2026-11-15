import SwiftUI

// MARK: - Invite friends

/// Members of a trip and the invite code. Walks through creating an account and
/// sharing the trip first when needed.
struct ShareTripView: View {
    let store: TripStore

    @Environment(\.dismiss) private var dismiss
    private var account = SyncAccount.shared
    @State private var name = ""
    @State private var serverKey = ""
    @State private var code: String?
    @State private var working = false
    @State private var errorText: String?
    @State private var copied = false
    @State private var renaming = false
    @State private var newName = ""

    init(store: TripStore) { self.store = store }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.isShared ? "Partecipanti" : "Viaggia insieme")
                        .font(.display(28))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.text)

                    if !account.isSignedIn {
                        signInStep
                    } else if !store.isShared {
                        shareStep
                    } else {
                        membersCard
                        inviteCard
                        statusLine
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }.fontWeight(.semibold)
                }
            }
            .overlay { if working { ProgressView().tint(Theme.text) } }
            .disabled(working)
        }
        .tint(Theme.text)
        .presentationBackground(Theme.canvas)
        .task { await store.sync() }
        .alert("Il tuo nome", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Salva") { run { try await rename() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Lo vedono tutti i partecipanti dei tuoi viaggi condivisi.")
        }
    }

    // MARK: Steps

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chi inviti vede e modifica tratte, biglietti, foto e link di questo viaggio. Prima scegli come ti vedranno gli altri.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
            VStack(spacing: 0) {
                TextField("Il tuo nome", text: $name)
                    .textContentType(.givenName)
                    .padding(16)
                Divider().overlay(Theme.hairline)
                SecureField("Chiave del server", text: $serverKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(16)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            Text("La chiave è TRIP_APP_KEY nel file .env del server e serve solo la prima volta. Se un amico ti ha invitato, usa invece \"Unisciti con codice\" nella lista dei viaggi.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.stone)
            Button("Continua") { run { try await register() } }
                .buttonStyle(PrimaryPillStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || serverKey.isEmpty)
                .padding(.top, 4)
        }
    }

    private var shareStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Carica \"\(store.title)\" sul server: chi inviti vede e modifica tratte, biglietti, foto e link, e le modifiche arrivano a tutti. I colori dei mezzi restano personali.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
            Button { run { try await share() } } label: { Label("Condividi viaggio", systemImage: "person.2.fill") }
                .buttonStyle(PrimaryPillStyle())
                .padding(.top, 4)
        }
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.members.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 62) }
                HStack(spacing: 12) {
                    MemberAvatar(member: m, size: 36)
                    Text(m.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if m.id == account.session?.id {
                        Text("Tu").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.stone)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 30, height: 30)
                            .background(Theme.fill, in: Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard m.id == account.session?.id else { return }
                    newName = m.name
                    renaming = true
                }
                .accessibilityAddTraits(m.id == account.session?.id ? .isButton : [])
                .accessibilityHint(m.id == account.session?.id ? "Cambia il tuo nome" : "")
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    @ViewBuilder
    private var inviteCard: some View {
        SectionLabel("Invita amici").padding(.top, 8)
        if let code {
            Card {
                Text(InviteCode.pretty(code))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                Text("Il tuo amico apre TripThatShit, tocca ··· e \"Unisciti con codice\". Vale 14 giorni e per più persone.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.mute)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = InviteCode.pretty(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copiato" : "Copia", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SoftPillStyle())
                ShareLink(item: SyncConfig.inviteMessage(title: store.title, code: code)) {
                    Label("Invia", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryPillStyle())
            }
        } else {
            Button { run { code = try await store.createInvite() } } label: {
                Label("Crea codice invito", systemImage: "person.badge.plus")
            }
            .buttonStyle(PrimaryPillStyle())
        }
    }

    private var statusLine: some View {
        SyncStatusText(store: store)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }

    // MARK: Actions

    private func register() async throws {
        do {
            let session = try await API(token: nil).register(
                name: name.trimmingCharacters(in: .whitespaces),
                key: serverKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            account.signIn(session)
        } catch APIError.forbidden {
            throw APIError.http(403, "Chiave del server errata.")
        }
        try await share()
    }

    private func rename() async throws {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != account.session?.name else { return }
        try await account.api.rename(name)
        account.updateName(name)
        await store.sync() // refresh the member list
    }

    private func share() async throws {
        try await store.startSharing()
        code = try await store.createInvite()
    }

    private func run(_ action: @escaping () async throws -> Void) {
        errorText = nil
        working = true
        Task {
            defer { working = false }
            do { try await action() } catch { errorText = error.localizedDescription }
        }
    }
}

// MARK: - Join with a code

struct JoinTripView: View {
    let library: TripLibrary
    let onJoined: (TripStore) -> Void

    @Environment(\.dismiss) private var dismiss
    private var account = SyncAccount.shared
    @State private var code = ""
    @State private var name = ""
    @State private var working = false
    @State private var errorText: String?

    init(library: TripLibrary, onJoined: @escaping (TripStore) -> Void) {
        self.library = library
        self.onJoined = onJoined
    }

    private var normalized: String { InviteCode.find(in: code) ?? InviteCode.normalize(code) }
    private var canJoin: Bool {
        normalized.count == 8 && (account.isSignedIn || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Unisciti a un viaggio")
                        .font(.display(28))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.text)
                    Text("Inserisci il codice che ti ha mandato un amico. Vedrai e potrai modificare tratte, biglietti, foto e link del viaggio.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.mute)

                    VStack(spacing: 0) {
                        HStack {
                            TextField("ABCD-EFGH", text: $code)
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            PasteButton(payloadType: String.self) { strings in
                                if let s = strings.first { code = InviteCode.find(in: s).map(InviteCode.pretty) ?? s }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.capsule)
                        }
                        .padding(16)
                        if !account.isSignedIn {
                            Divider().overlay(Theme.hairline)
                            TextField("Il tuo nome", text: $name)
                                .textContentType(.givenName)
                                .padding(16)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                    }

                    Button("Unisciti", action: join)
                        .buttonStyle(PrimaryPillStyle())
                        .disabled(!canJoin)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            }
            .overlay { if working { ProgressView().tint(Theme.text) } }
            .disabled(working)
        }
        .tint(Theme.text)
        .presentationBackground(Theme.canvas)
    }

    private func join() {
        errorText = nil
        working = true
        Task {
            defer { working = false }
            do {
                let store = try await library.join(code: normalized, name: name.trimmingCharacters(in: .whitespaces))
                dismiss()
                onJoined(store)
            } catch APIError.notFound {
                errorText = "Codice invito non valido o scaduto."
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Small pieces

struct MemberAvatar: View {
    let member: Member
    var size: CGFloat = 28

    var body: some View {
        Text(member.initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.onInverse)
            .frame(width: size, height: size)
            .background(Theme.inverse, in: Circle())
            .overlay(Circle().stroke(Theme.canvas, lineWidth: 1.5))
    }
}

/// Overlapping avatars, at most four plus a count.
struct MemberStack: View {
    let members: [Member]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(members.prefix(4)) { MemberAvatar(member: $0, size: size) }
            if members.count > 4 {
                Text("+\(members.count - 4)")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: size, height: size)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.canvas, lineWidth: 1.5))
            }
        }
    }
}

struct SyncStatusText: View {
    let store: TripStore

    var body: some View {
        let (text, symbol, color): (String, String, Color) =
            if store.syncing {
                ("Sincronizzazione…", "arrow.triangle.2.circlepath", Theme.stone)
            } else if let error = store.syncError {
                (error, "exclamationmark.icloud", Theme.danger)
            } else if store.pendingCount > 0 {
                ("\(store.pendingCount) modifiche in attesa", "icloud.and.arrow.up", Theme.stone)
            } else {
                ("Sincronizzato", "checkmark.icloud", Theme.stone)
            }
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(2)
    }
}
