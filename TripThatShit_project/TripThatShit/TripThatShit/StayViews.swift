import SwiftUI
import MapKit
import QuickLook

// Where we sleep. Kept apart from legs on purpose: its own row, detail page and editor,
// so neither form turns into a giant questionnaire.

/// Round bed icon, the stay counterpart of `ModeBadge`.
struct StayBadge: View {
    var size: CGFloat = 32
    var dimmed = false

    var body: some View {
        Image(systemName: Stay.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.onInverse)
            .frame(width: size, height: size)
            .background(Theme.inverse.opacity(dimmed ? 0.45 : 1), in: Circle())
            .overlay(Circle().stroke(Theme.canvas.opacity(0.7), lineWidth: 1.5))
    }
}

struct StayRow: View {
    let stay: Stay

    var body: some View {
        let past = stay.checkOut < .now
        HStack(spacing: 12) {
            StayBadge(size: 34, dimmed: past)
            VStack(alignment: .leading, spacing: 3) {
                Text(stay.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text("\(Fmt.range(stay.checkIn, stay.timeZone, stay.checkOut, stay.timeZone))  ·  \(stay.nightsText)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.mute)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            if !stay.attachments.isEmpty {
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

// MARK: - Detail

struct StayDetailView: View {
    let store: TripStore
    let stayID: UUID
    let onEdit: (Stay) -> Void

    @State private var preview: URL?
    @State private var copied = false

    var body: some View {
        Group {
            if let stay = store.stay(stayID) {
                content(stay)
            } else {
                Text("Alloggio eliminato")
                    .foregroundStyle(Theme.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .quickLookPreview($preview)
    }

    private func content(_ stay: Stay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StayBadge(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stay.title)
                            .font(.display(22))
                            .tracking(-0.2)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text(stay.nightsText)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.mute)
                    }
                    Spacer(minLength: 0)
                }

                Card {
                    HStack(alignment: .top) {
                        endpoint("Check-in", stay.checkIn, stay.timeZone, alignment: .leading)
                        Spacer(minLength: 8)
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.mute)
                            .padding(.top, 26)
                        Spacer(minLength: 8)
                        endpoint("Check-out", stay.checkOut, stay.timeZone, alignment: .trailing)
                    }
                    if let where_ = location(stay) {
                        Divider().overlay(Theme.hairline).padding(.vertical, 12)
                        Label(where_, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                }

                if hasInfo(stay) { info(stay) }

                SectionLabel("Prenotazione e file").padding(.top, 6)
                AttachmentList(store: store, attachments: stay.attachments, onOpen: { preview = store.url(for: $0) })
                AttachmentAdder(store: store) { added in
                    var updated = stay
                    updated.attachments.append(contentsOf: added)
                    store.upsertStay(updated)
                }

                if !stay.links.isEmpty {
                    SectionLabel("Link").padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(Array(stay.links.enumerated()), id: \.element.id) { i, link in
                            if i > 0 { Divider().overlay(Theme.hairline) }
                            LinkRow(link: link)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                }

                HStack(spacing: 10) {
                    if stay.place.hasCoordinate {
                        Button { openInMaps(stay) } label: {
                            Label("Indicazioni", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .buttonStyle(SoftPillStyle())
                    }
                    Button { onEdit(stay) } label: { Text("Modifica") }
                        .buttonStyle(PrimaryPillStyle())
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private func endpoint(_ label: String, _ date: Date, _ tz: TimeZone, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.stone)
            Text(Fmt.time(date, tz))
                .font(.display(32))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(Fmt.day(date, tz))
                .font(.system(size: 13))
                .foregroundStyle(Theme.mute)
        }
    }

    private func location(_ stay: Stay) -> String? {
        if !stay.address.isEmpty { return stay.address }
        if !stay.place.name.isEmpty && stay.place.name != stay.title { return stay.place.name }
        return nil
    }

    private func hasInfo(_ stay: Stay) -> Bool {
        !(stay.bookingRef.isEmpty && stay.price.isEmpty && stay.notes.isEmpty)
    }

    private func info(_ stay: Stay) -> some View {
        VStack(spacing: 0) {
            if !stay.bookingRef.isEmpty {
                InfoRow(label: "Codice prenotazione", value: stay.bookingRef) {
                    Button {
                        UIPasteboard.general.string = stay.bookingRef
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            if !stay.price.isEmpty { InfoRow(label: "Prezzo", value: stay.price) }
            if !stay.notes.isEmpty { InfoRow(label: "Note", value: stay.notes) }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    private func openInMaps(_ stay: Stay) {
        let item = MKMapItem(location: CLLocation(latitude: stay.place.latitude, longitude: stay.place.longitude), address: nil)
        item.name = stay.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

// MARK: - Editor

struct StayEditorView: View {
    let store: TripStore
    let original: Stay?
    /// Called on close; true when the stay was deleted.
    let onClose: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stay: Stay
    @State private var addedThisSession: [Attachment] = []
    @State private var removedThisSession: [Attachment] = []
    @State private var pickingPlace = false
    @State private var newLinkTitle = ""
    @State private var newLinkURL = ""
    @State private var confirmDelete = false
    @State private var preview: URL?

    init(store: TripStore, original: Stay?, onClose: @escaping (Bool) -> Void) {
        self.store = store
        self.original = original
        self.onClose = onClose
        if let original {
            _stay = State(initialValue: original)
        } else {
            _stay = State(initialValue: Self.fresh(after: store.legs.last))
        }
    }

    /// Check-in at 15:00 on the day the last leg arrives (or today), check-out the next morning at 10:00.
    private static func fresh(after leg: Leg?) -> Stay {
        let tz = leg?.to.timeZone ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let day = cal.startOfDay(for: max(leg?.arrival ?? .now, .now))
        let checkIn = cal.date(bySettingHour: 15, minute: 0, second: 0, of: day) ?? day
        let nextDay = cal.date(byAdding: .day, value: 1, to: day) ?? day
        let checkOut = cal.date(bySettingHour: 10, minute: 0, second: 0, of: nextDay) ?? nextDay
        var stay = Stay(checkIn: checkIn, checkOut: checkOut)
        stay.place.timeZoneID = tz.identifier
        return stay
    }

    private var canSave: Bool {
        !stay.name.trimmingCharacters(in: .whitespaces).isEmpty || !stay.place.name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dove dormite") {
                    PlaceButton(place: stay.place, placeholder: "Cerca hotel, ostello o indirizzo") { pickingPlace = true }
                    TextField("Nome (es. Hotel Viru, casa di Marta)", text: $stay.name)
                    TextField("Indirizzo (facoltativo)", text: $stay.address, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    DatePicker("Check-in", selection: $stay.checkIn)
                    DatePicker("Check-out", selection: $stay.checkOut, in: stay.checkIn...)
                } header: {
                    Text("Date")
                } footer: {
                    Text("\(stay.nightsText). Orari nel fuso orario del luogo.")
                }
                .environment(\.timeZone, stay.timeZone)

                Section("Prenotazione") {
                    TextField("Codice prenotazione", text: $stay.bookingRef)
                        .textInputAutocapitalization(.characters)
                    TextField("Prezzo", text: $stay.price)
                }

                Section("Note") {
                    TextField("Wi-Fi, codice del portone, colazione…", text: $stay.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Prenotazione e file") {
                    AttachmentList(
                        store: store,
                        attachments: stay.attachments,
                        onOpen: { preview = store.url(for: $0) },
                        onDelete: { a in
                            stay.attachments.removeAll { $0.id == a.id }
                            removedThisSession.append(a)
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    AttachmentAdder(store: store) { added in
                        stay.attachments.append(contentsOf: added)
                        addedThisSession.append(contentsOf: added)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section("Link") {
                    ForEach(stay.links) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title.isEmpty ? link.url : link.title).lineLimit(1)
                                Text(link.url).font(.caption).foregroundStyle(Theme.stone).lineLimit(1)
                            }
                            Spacer()
                            Button { stay.links.removeAll { $0.id == link.id } } label: {
                                Image(systemName: "xmark").foregroundStyle(Theme.mute)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Titolo (es. Booking, Airbnb)", text: $newLinkTitle)
                    TextField("https://", text: $newLinkURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Aggiungi link", action: addLink)
                        .disabled(newLinkURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if original != nil {
                    Section {
                        Button("Elimina alloggio", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.formCanvas)
            .navigationTitle(original == nil ? "Nuovo alloggio" : "Modifica alloggio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva", action: save).disabled(!canSave).fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $pickingPlace) {
                PlaceSearchView(initialQuery: stay.place.name.isEmpty ? stay.name : stay.place.name) { setPlace($0) }
            }
            .confirmationDialog("Eliminare questo alloggio?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive, action: deleteStay)
            } message: {
                Text("Verranno eliminati anche i file allegati.")
            }
            .quickLookPreview($preview)
        }
        .tint(Theme.text)
        .interactiveDismissDisabled()
    }

    // MARK: Actions

    private func setPlace(_ place: Place) {
        let oldTZ = stay.timeZone
        let previousPlaceName = stay.place.name
        stay.place = place
        // Keep the same wall-clock check-in/out when the place is in another time zone.
        stay.checkIn = stay.checkIn.rebased(from: oldTZ, to: place.timeZone)
        stay.checkOut = stay.checkOut.rebased(from: oldTZ, to: place.timeZone)
        if stay.name.isEmpty || stay.name == previousPlaceName { stay.name = place.name }
    }

    private func addLink() {
        var url = newLinkURL.trimmingCharacters(in: .whitespaces)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        stay.links.append(LinkItem(title: newLinkTitle.trimmingCharacters(in: .whitespaces), url: url))
        newLinkTitle = ""
        newLinkURL = ""
    }

    private func save() {
        if !newLinkURL.trimmingCharacters(in: .whitespaces).isEmpty { addLink() }
        stay.name = stay.name.trimmingCharacters(in: .whitespaces)
        if stay.checkOut < stay.checkIn { stay.checkOut = stay.checkIn }
        store.removeFiles(removedThisSession)
        store.upsertStay(stay)
        dismiss()
        onClose(false)
    }

    private func cancel() {
        store.removeFiles(addedThisSession)
        dismiss()
        onClose(false)
    }

    private func deleteStay() {
        store.removeFiles(addedThisSession)
        if let original { store.deleteStay(original) }
        dismiss()
        onClose(true)
    }
}
