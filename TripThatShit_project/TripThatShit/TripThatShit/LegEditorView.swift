import SwiftUI
import QuickLook

struct LegEditorView: View {
    let store: TripStore
    let original: Leg?
    /// Called on close; true when the leg was deleted.
    let onClose: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var leg: Leg
    @State private var addedThisSession: [Attachment] = []
    @State private var removedThisSession: [Attachment] = []
    @State private var pickingFrom = false
    @State private var pickingTo = false
    @State private var newLinkTitle = ""
    @State private var newLinkURL = ""
    @State private var confirmDelete = false
    @State private var preview: URL?

    init(store: TripStore, original: Leg?, suggestedFrom: Place?, onClose: @escaping (Bool) -> Void) {
        self.store = store
        self.original = original
        self.onClose = onClose
        if let original {
            _leg = State(initialValue: original)
        } else {
            let start = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
            var fresh = Leg(departure: start, arrival: start.addingTimeInterval(7200))
            if let suggestedFrom { fresh.from = suggestedFrom }
            _leg = State(initialValue: fresh)
        }
    }

    private var canSave: Bool {
        !leg.from.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !leg.to.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModePicker(mode: $leg.mode)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section("Partenza") {
                    PlaceButton(place: leg.from, placeholder: "Luogo di partenza") { pickingFrom = true }
                    DatePicker("Data e ora", selection: $leg.departure)
                        .environment(\.timeZone, leg.from.timeZone)
                }

                Section {
                    PlaceButton(place: leg.to, placeholder: "Luogo di arrivo") { pickingTo = true }
                    DatePicker("Data e ora", selection: $leg.arrival, in: leg.departure...)
                        .environment(\.timeZone, leg.to.timeZone)
                } header: {
                    Text("Arrivo")
                } footer: {
                    Text("Gli orari sono nel fuso orario locale di ogni luogo.")
                }

                Section("Dettagli") {
                    field("Compagnia (es. Elron, FlixBus)", $leg.carrier)
                    field("Numero treno o volo", $leg.number)
                    field("Codice prenotazione", $leg.bookingRef)
                        .textInputAutocapitalization(.characters)
                    field("Posto o cabina", $leg.seat)
                    field("Prezzo", $leg.price)
                }

                Section("Note") {
                    TextField("Note", text: $leg.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Biglietti e file") {
                    AttachmentList(
                        store: store,
                        attachments: leg.attachments,
                        onOpen: { preview = store.url(for: $0) },
                        onDelete: { a in
                            leg.attachments.removeAll { $0.id == a.id }
                            removedThisSession.append(a)
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    AttachmentAdder(store: store) { added in
                        leg.attachments.append(contentsOf: added)
                        addedThisSession.append(contentsOf: added)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section("Link") {
                    ForEach(leg.links) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title.isEmpty ? link.url : link.title).lineLimit(1)
                                Text(link.url).font(.caption).foregroundStyle(Theme.stone).lineLimit(1)
                            }
                            Spacer()
                            Button { leg.links.removeAll { $0.id == link.id } } label: {
                                Image(systemName: "xmark").foregroundStyle(Theme.mute)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    field("Titolo (es. Biglietto online)", $newLinkTitle)
                    TextField("https://", text: $newLinkURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Aggiungi link", action: addLink)
                        .disabled(newLinkURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if original != nil {
                    Section {
                        Button("Elimina tratta", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.formCanvas)
            .navigationTitle(original == nil ? "Nuova tratta" : "Modifica tratta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: save).disabled(!canSave).fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $pickingFrom) {
                PlaceSearchView(initialQuery: leg.from.name) { setFrom($0) }
            }
            .sheet(isPresented: $pickingTo) {
                PlaceSearchView(initialQuery: leg.to.name) { setTo($0) }
            }
            .confirmationDialog("Eliminare questa tratta?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive, action: deleteLeg)
            } message: {
                Text("Verranno eliminati anche i file allegati.")
            }
            .quickLookPreview($preview)
        }
        .tint(Theme.text)
        .interactiveDismissDisabled()
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
    }

    // MARK: Actions

    private func setFrom(_ place: Place) {
        let oldTZ = leg.from.timeZone
        leg.from = place
        leg.departure = leg.departure.rebased(from: oldTZ, to: place.timeZone)
    }

    private func setTo(_ place: Place) {
        let oldTZ = leg.to.timeZone
        leg.to = place
        leg.arrival = leg.arrival.rebased(from: oldTZ, to: place.timeZone)
        if leg.arrival < leg.departure { leg.arrival = leg.departure.addingTimeInterval(3600) }
    }

    private func addLink() {
        var url = newLinkURL.trimmingCharacters(in: .whitespaces)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        leg.links.append(LinkItem(title: newLinkTitle.trimmingCharacters(in: .whitespaces), url: url))
        newLinkTitle = ""
        newLinkURL = ""
    }

    private func save() {
        if !newLinkURL.trimmingCharacters(in: .whitespaces).isEmpty { addLink() }
        if leg.arrival < leg.departure { leg.arrival = leg.departure }
        store.removeFiles(removedThisSession)
        store.upsert(leg)
        dismiss()
        onClose(false)
    }

    private func cancel() {
        store.removeFiles(addedThisSession)
        dismiss()
        onClose(false)
    }

    private func deleteLeg() {
        store.removeFiles(addedThisSession)
        if let original { store.delete(original) }
        dismiss()
        onClose(true)
    }
}

struct ModePicker: View {
    @Binding var mode: TransportMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TransportMode.allCases) { m in
                let on = m == mode
                Button { mode = m } label: {
                    VStack(spacing: 6) {
                        Image(systemName: m.symbol)
                            .font(.system(size: 18, weight: .semibold))
                        Text(m.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? .white : Theme.mute)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(on ? m.color : Theme.fill,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: mode)
    }
}

struct PlaceButton: View {
    let place: Place
    let placeholder: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: place.hasCoordinate ? "mappin.circle.fill" : "magnifyingglass")
                    .foregroundStyle(place.hasCoordinate ? Theme.text : Theme.stone)
                Text(place.name.isEmpty ? placeholder : place.name)
                    .foregroundStyle(place.name.isEmpty ? Theme.stone : Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !place.name.isEmpty && !place.hasCoordinate {
                    Text("non sulla mappa")
                        .font(.caption)
                        .foregroundStyle(Theme.stone)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
