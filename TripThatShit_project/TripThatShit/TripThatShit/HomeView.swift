import SwiftUI
import UniformTypeIdentifiers

/// Switches between the trip list and an open trip.
struct RootView: View {
    @State private var library = TripLibrary()
    @State private var openTrip: TripStore?

    var body: some View {
        ZStack {
            if let store = openTrip {
                ContentView(store: store) {
                    library.reload()
                    withAnimation(.snappy) { openTrip = nil }
                }
                .id(store.id)
                .transition(.move(edge: .trailing))
            } else {
                HomeView(library: library) { store in
                    withAnimation(.snappy) { openTrip = store }
                }
                .transition(.move(edge: .leading))
            }
        }
        .onAppear { AppSettings.shared.applyAppearance() }
    }
}

// MARK: - Home

struct HomeView: View {
    let library: TripLibrary
    let onOpen: (TripStore) -> Void

    @State private var showSettings = false
    @State private var creating = false
    @State private var newTitle = ""
    @State private var importing = false
    @State private var renaming: TripSummary?
    @State private var renameText = ""
    @State private var deleting: TripSummary?
    @State private var errorText: String?
    @State private var joining = false
    @Environment(\.scenePhase) private var scenePhase

    private var active: [TripSummary] { library.trips.filter { [.ongoing, .upcoming].contains($0.status()) } }
    private var drafts: [TripSummary] { library.trips.filter { $0.status() == .empty } }
    private var past: [TripSummary] { library.trips.filter { $0.status() == .past } }

    var body: some View {
        NavigationStack {
            // A plain List (not a ScrollView) so trip cards get native swipe actions.
            List {
                header.homeRow(top: 4)

                if library.trips.isEmpty {
                    HomeEmptyState(onNew: startCreating, onImport: { importing = true }, onJoin: { joining = true })
                        .homeRow()
                } else {
                    section("In corso e in arrivo", active)
                    section("Bozze", drafts)
                    section("Passati", past)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .animation(.snappy, value: library.trips.map(\.id))
            .refreshable { await library.syncAll() }
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom) {
                if !library.trips.isEmpty {
                    Button(action: startCreating) { Label("Nuovo viaggio", systemImage: "plus") }
                        .buttonStyle(PrimaryPillStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.canvas.opacity(0.92))
                }
            }
            .toolbar { toolbar }
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.text)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $joining) { JoinTripView(library: library, onJoined: onOpen) }
        .task { await library.syncAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.syncAll() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importFile)
        .alert("Nuovo viaggio", isPresented: $creating) {
            TextField("Nome (es. Giappone 2027)", text: $newTitle)
            Button("Crea") {
                onOpen(library.create(title: newTitle.trimmingCharacters(in: .whitespaces)))
            }
            Button("Annulla", role: .cancel) {}
        }
        .alert("Rinomina viaggio", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $renameText)
            Button("Salva") {
                let title = renameText.trimmingCharacters(in: .whitespaces)
                if let id = renaming?.id, !title.isEmpty { library.rename(id, to: title) }
            }
            Button("Annulla", role: .cancel) {}
        }
        .confirmationDialog(
            "Eliminare \"\(deleting?.title ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(deleting?.isShared == true ? "Esci dal viaggio" : "Elimina viaggio", role: .destructive) {
                guard let trip = deleting else { return }
                if trip.isShared {
                    Task {
                        do { try await library.leave(trip.id) } catch {
                            errorText = "Per uscire da un viaggio condiviso serve la connessione. \(error.localizedDescription)"
                        }
                    }
                } else {
                    withAnimation { library.delete(trip.id) }
                }
            }
        } message: {
            Text(deleting?.isShared == true
                 ? "Il viaggio sparisce da questo telefono e non riceverai più le modifiche. Gli altri partecipanti lo conservano."
                 : "Tutte le tratte, i biglietti e i file di questo viaggio verranno eliminati dal telefono.")
        }
        .alert("Errore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TripThatShit")
                .font(.display(34))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
            Text(library.trips.isEmpty ? "Pianifica il tuo primo viaggio" : "I tuoi viaggi")
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func section(_ title: String, _ trips: [TripSummary]) -> some View {
        if !trips.isEmpty {
            SectionLabel(title).homeRow(top: 16)
            ForEach(trips) { trip in
                Button { onOpen(library.store(for: trip.id)) } label: { TripCard(trip: trip) }
                    .buttonStyle(CardPressStyle())
                    .contextMenu {
                        Button { renameText = trip.title; renaming = trip } label: { Label("Rinomina", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = trip } label: { Label("Elimina", systemImage: "trash") }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // Not role: .destructive, so the row stays until the deletion is confirmed.
                        Button { deleting = trip } label: { Label("Elimina", systemImage: "trash") }
                            .tint(Theme.danger)
                    }
                    .homeRow()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { joining = true } label: { Label("Unisciti con codice", systemImage: "person.badge.plus") }
                Button { importing = true } label: { Label("Importa viaggio", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("Impostazioni")
        }
    }

    // MARK: Actions

    private func startCreating() {
        newTitle = ""
        creating = true
    }


    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let package = try JSONDecoder().decode(TripPackage.self, from: Data(contentsOf: url))
            onOpen(library.create(from: package))
        } catch {
            errorText = "File non valido. Usa un file esportato da TripThatShit."
        }
    }
}

private extension View {
    /// Strips List row chrome so content looks like it sits on the plain canvas.
    func homeRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Trip card

struct TripCard: View {
    let trip: TripSummary

    var body: some View {
        let status = trip.status()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                StatusChip(trip: trip, status: status)
                if trip.isShared {
                    MemberStack(members: trip.members, size: 22)
                        .accessibilityLabel("Condiviso con \(trip.members.count) persone")
                }
                Spacer(minLength: 8)
                HStack(spacing: -6) {
                    ForEach(trip.modeCounts, id: \.0) { mode, _ in
                        ModeBadge(mode: mode, size: 26)
                    }
                    if trip.stayCount > 0 { StayBadge(size: 26) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(trip.title)
                    .font(.display(24))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let from = trip.from, let to = trip.to {
                    Text(from == to
                         ? "\(Image(systemName: "arrow.triangle.2.circlepath"))  Andata e ritorno da \(from)"
                         : "\(from)  \(Image(systemName: "arrow.right"))  \(to)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                }
            }

            if let start = trip.start, let end = trip.end {
                Text(details(start: start, end: end))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.stone)
                    .monospacedDigit()
                ModeBar(counts: trip.modeCounts)
            } else {
                Text("Nessuna tratta ancora. Tocca per aggiungerne una.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.stone)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .opacity(status == .past ? 0.7 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    private func details(start: Date, end: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = trip.startTZ
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: end)).day ?? 0) + 1
        var parts = [Fmt.range(start, trip.startTZ, end, trip.endTZ)]
        if trip.legCount > 0 { parts.append(trip.legCount == 1 ? "1 tratta" : "\(trip.legCount) tratte") }
        parts.append(days == 1 ? "1 giorno" : "\(days) giorni")
        return parts.joined(separator: "  ·  ")
    }
}

struct StatusChip: View {
    let trip: TripSummary
    let status: TripSummary.Status

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .ongoing: ("IN CORSO", Color(hex: 0x2FB866))
        case .upcoming: (Fmt.countdown(to: trip.start ?? .now).uppercased(), Theme.text)
        case .past: ("CONCLUSO", Theme.stone)
        case .empty: ("BOZZA", Theme.stone)
        }
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.fill, in: Capsule())
    }
}

/// Thin bar split by how many legs use each transport mode, in the user's colours.
struct ModeBar: View {
    let counts: [(TransportMode, Int)]

    var body: some View {
        let total = max(1, counts.reduce(0) { $0 + $1.1 })
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(counts, id: \.0) { mode, n in
                    Capsule()
                        .fill(mode.color)
                        .frame(width: max(6, (geo.size.width - CGFloat(counts.count - 1) * 3) * CGFloat(n) / CGFloat(total)))
                }
            }
        }
        .frame(height: 6)
    }
}

struct HomeEmptyState: View {
    let onNew: () -> Void
    let onImport: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: -8) {
                ForEach(TransportMode.allCases) { ModeBadge(mode: $0, size: 40) }
            }
            Text("Nessun viaggio")
                .font(.display(22))
                .foregroundStyle(Theme.text)
            Text("Crea un viaggio e aggiungi voli, treni, bus e traghetti con orari, biglietti e link. Funziona anche offline, e puoi invitare gli amici a modificarlo con te.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
            Button(action: onNew) { Label("Nuovo viaggio", systemImage: "plus") }
                .buttonStyle(PrimaryPillStyle())
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(action: onJoin) { Label("Unisciti", systemImage: "person.badge.plus") }
                    .buttonStyle(SoftPillStyle())
                Button(action: onImport) { Label("Importa", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SoftPillStyle())
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }
}

#Preview {
    RootView()
}
