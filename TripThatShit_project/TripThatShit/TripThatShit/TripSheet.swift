import SwiftUI
import UniformTypeIdentifiers

struct EditorRequest: Identifiable {
    let id = UUID()
    let leg: Leg?
}

struct StayEditorRequest: Identifiable {
    let id = UUID()
    let stay: Stay?
}

/// The persistent bottom sheet: timeline at the root, leg and stay details pushed on top.
struct TripSheet: View {
    let store: TripStore
    @Binding var path: [UUID]
    @Binding var detent: PresentationDetent
    let onShowAll: () -> Void
    let onClose: () -> Void

    @State private var editor: EditorRequest?
    @State private var stayEditor: StayEditorRequest?
    @State private var showSettings = false
    @State private var importing = false
    @State private var pendingPackage: TripPackage?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var errorText: String?
    @State private var showPeople = false

    var body: some View {
        NavigationStack(path: $path) {
            TimelineScreen(store: store, onAdd: addLeg, onAddStay: addStay, onOpen: { path = [$0] }, onPeople: { showPeople = true })
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { id in
                    if store.stay(id) != nil {
                        StayDetailView(store: store, stayID: id, onEdit: { stayEditor = StayEditorRequest(stay: $0) })
                    } else {
                        LegDetailView(store: store, legID: id, onEdit: { editor = EditorRequest(leg: $0) })
                    }
                }
        }
        .tint(Theme.text)
        .sheet(item: $editor) { req in
            LegEditorView(store: store, original: req.leg, suggestedFrom: store.legs.last?.to) { deleted in
                if deleted { path = [] }
            }
        }
        .sheet(item: $stayEditor) { req in
            StayEditorView(store: store, original: req.stay) { deleted in
                if deleted { path = [] }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingPackage = try JSONDecoder().decode(TripPackage.self, from: data)
            } catch {
                errorText = "File non valido. Usa un file esportato da questa app."
            }
        }
        .confirmationDialog(
            "Sostituire il viaggio attuale?",
            isPresented: Binding(get: { pendingPackage != nil }, set: { if !$0 { pendingPackage = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sostituisci", role: .destructive) {
                if let p = pendingPackage { store.load(package: p); path = []; onShowAll() }
                pendingPackage = nil
            }
        } message: {
            Text("Tutte le tratte, gli alloggi e i file attuali verranno sostituiti da quelli importati.")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPeople) { ShareTripView(store: store) }
        .alert("Nome del viaggio", isPresented: $renaming) {
            TextField("Nome", text: $newTitle)
            Button("Salva") { store.saveTitle(newTitle.trimmingCharacters(in: .whitespaces)) }
            Button("Annulla", role: .cancel) {}
        }
        .alert("Errore", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { newTitle = store.title; renaming = true } label: { Label("Rinomina viaggio", systemImage: "pencil") }
                Button { showPeople = true } label: {
                    Label(store.isShared ? "Partecipanti" : "Invita amici", systemImage: "person.badge.plus")
                }
                ShareLink(
                    item: TripExport(title: store.title, legs: store.legs, stays: store.stays, attachmentsDir: store.attachmentsDir),
                    preview: SharePreview(store.title)
                ) {
                    Label("Esporta come file", systemImage: "square.and.arrow.up")
                }
                Button { importing = true } label: { Label("Sostituisci da file", systemImage: "square.and.arrow.down") }
                Divider()
                Button { showSettings = true } label: { Label("Impostazioni", systemImage: "gearshape") }
                Button(action: onClose) { Label("Tutti i viaggi", systemImage: "square.stack") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPeople = true } label: {
                Image(systemName: store.isShared ? "person.2.fill" : "person.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
            }
            .accessibilityLabel(store.isShared ? "Partecipanti" : "Invita amici")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: addLeg) { Label("Tratta", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                Button(action: addStay) { Label("Alloggio", systemImage: Stay.symbol) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
            }
            .accessibilityLabel("Aggiungi")
        }
    }

    private func addLeg() {
        editor = EditorRequest(leg: nil)
        detent = .large
    }

    private func addStay() {
        stayEditor = StayEditorRequest(stay: nil)
        detent = .large
    }
}

/// Exports the whole trip, files included, as one JSON file.
/// Files are read only when the user actually shares, never while rendering.
nonisolated struct TripExport: Transferable {
    let title: String
    let legs: [Leg]
    let stays: [Stay]
    let attachmentsDir: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            var files: [String: Data] = [:]
            for a in export.legs.flatMap(\.attachments) + export.stays.flatMap(\.attachments) {
                files[a.storedName] = try? Data(contentsOf: export.attachmentsDir.appendingPathComponent(a.storedName))
            }
            let package = TripPackage(title: export.title, legs: export.legs, stays: export.stays, files: files)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Viaggio.json")
            try JSONEncoder().encode(package).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Timeline

struct TimelineScreen: View {
    let store: TripStore
    let onAdd: () -> Void
    let onAddStay: () -> Void
    let onOpen: (UUID) -> Void
    let onPeople: () -> Void

    /// A row of the timeline: a leg, or a stay shown on its check-in day.
    private enum Item: Identifiable {
        case leg(Leg)
        case stay(Stay)

        var id: UUID { switch self { case .leg(let l): l.id; case .stay(let s): s.id } }
        var date: Date { switch self { case .leg(let l): l.departure; case .stay(let s): s.checkIn } }
        var timeZone: TimeZone { switch self { case .leg(let l): l.from.timeZone; case .stay(let s): s.timeZone } }
    }

    private struct DayGroup: Identifiable {
        let id: String
        let label: String
        let items: [Item]
    }

    private var groups: [DayGroup] {
        let items = (store.legs.map(Item.leg) + store.stays.map(Item.stay)).sorted { $0.date < $1.date }
        var order: [String] = []
        var map: [String: (String, [Item])] = [:]
        for item in items {
            let key = Fmt.dayKey(item.date, item.timeZone)
            if map[key] == nil { order.append(key); map[key] = (Fmt.day(item.date, item.timeZone), []) }
            map[key]?.1.append(item)
        }
        return order.map { DayGroup(id: $0, label: map[$0]!.0, items: map[$0]!.1) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(store.title)
                    .font(.display(28))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.top, 2)

                if store.isShared {
                    Button(action: onPeople) {
                        HStack(spacing: 10) {
                            MemberStack(members: store.members, size: 24)
                            SyncStatusText(store: store)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if store.legs.isEmpty && store.stays.isEmpty {
                    EmptyState(onAdd: onAdd, onAddStay: onAddStay)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        if store.legs.isEmpty {
                            EmptyView()
                        } else if let next = store.currentOrNext(now: ctx.date) {
                            NextLegCard(leg: next, now: ctx.date)
                                .onTapGesture { onOpen(next.id) }
                        } else {
                            Card {
                                Text("Viaggio concluso")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                    }

                    ForEach(groups) { group in
                        SectionLabel(group.label)
                            .padding(.top, 14)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 60) }
                                Button { onOpen(item.id) } label: {
                                    switch item {
                                    case .leg(let leg): LegRow(leg: leg)
                                    case .stay(let stay): StayRow(stay: stay)
                                    }
                                }
                                .buttonStyle(RowPressStyle())
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.fill : .clear)
    }
}

struct LegRow: View {
    let leg: Leg

    var body: some View {
        let past = leg.arrival < .now
        HStack(spacing: 12) {
            ModeBadge(mode: leg.mode, size: 34, dimmed: past)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(leg.from.name)  \(Image(systemName: "arrow.right"))  \(leg.to.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text("\(Fmt.time(leg.departure, leg.from.timeZone)) - \(Fmt.time(leg.arrival, leg.to.timeZone))  ·  \(Fmt.duration(leg.duration))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.mute)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            PaymentIcon(payment: leg.payment)
            if leg.sleepsOnBoard {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel("Notte a bordo")
            }
            if !leg.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.stone)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.stone)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}

struct NextLegCard: View {
    let leg: Leg
    let now: Date

    var body: some View {
        let inProgress = leg.departure <= now
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(inProgress ? "IN VIAGGIO" : "PROSSIMA TRATTA")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(leg.mode.color)
                Spacer()
                Text(inProgress ? "arrivo \(Fmt.countdown(to: leg.arrival, now: now))" : Fmt.countdown(to: leg.departure, now: now))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.fill, in: Capsule())
            }
            HStack(spacing: 12) {
                ModeBadge(mode: leg.mode, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(leg.from.name)  \(Image(systemName: "arrow.right"))  \(leg.to.name)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text("\(Fmt.day(leg.departure, leg.from.timeZone))  ·  \(Fmt.time(leg.departure, leg.from.timeZone))")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.mute)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(leg.mode.color.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

struct EmptyState: View {
    let onAdd: () -> Void
    let onAddStay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nessuna tratta")
                .font(.display(22))
                .foregroundStyle(Theme.text)
            Text("Aggiungi voli, treni, bus e traghetti con orari, biglietti e link, e dove dormite. Funziona anche offline.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
            Button("Aggiungi tratta", action: onAdd)
                .buttonStyle(PrimaryPillStyle())
                .padding(.top, 4)
            Button(action: onAddStay) { Label("Aggiungi alloggio", systemImage: Stay.symbol) }
                .buttonStyle(SoftPillStyle())
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }
}
