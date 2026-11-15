import SwiftUI
import MapKit
import QuickLook

struct LegDetailView: View {
    let store: TripStore
    let legID: UUID
    let onEdit: (Leg) -> Void

    @State private var preview: URL?
    @State private var copied = false

    var body: some View {
        Group {
            if let leg = store.leg(legID) {
                content(leg)
            } else {
                Text("Tratta eliminata")
                    .foregroundStyle(Theme.mute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .quickLookPreview($preview)
    }

    private func content(_ leg: Leg) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(leg)
                times(leg)

                if hasInfo(leg) { info(leg) }

                SectionLabel("Pagamento").padding(.top, 6)
                PaymentCard(selection: Binding(
                    get: { leg.payment },
                    set: { var updated = leg; updated.payment = $0; store.upsert(updated) }
                ))

                SectionLabel("Biglietti e file").padding(.top, 6)
                AttachmentList(store: store, attachments: leg.attachments, onOpen: { preview = store.url(for: $0) })
                AttachmentAdder(store: store) { added in
                    var updated = leg
                    updated.attachments.append(contentsOf: added)
                    store.upsert(updated)
                }

                if !leg.links.isEmpty {
                    SectionLabel("Link").padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(Array(leg.links.enumerated()), id: \.element.id) { i, link in
                            if i > 0 { Divider().overlay(Theme.hairline) }
                            LinkRow(link: link)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                }

                HStack(spacing: 10) {
                    if leg.from.hasCoordinate {
                        Button { openInMaps(leg.from) } label: {
                            Label("Indicazioni", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .buttonStyle(SoftPillStyle())
                    }
                    Button { onEdit(leg) } label: { Text("Modifica") }
                        .buttonStyle(PrimaryPillStyle())
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Sections

    private func header(_ leg: Leg) -> some View {
        HStack(spacing: 12) {
            ModeBadge(mode: leg.mode, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(leg.title)
                    .font(.display(22))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Fmt.day(leg.departure, leg.from.timeZone))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.mute)
            }
            Spacer(minLength: 0)
            if leg.sleepsOnBoard {
                Label("Notte a bordo", systemImage: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.fill, in: Capsule())
            }
        }
    }

    private func times(_ leg: Leg) -> some View {
        Card {
            HStack(alignment: .top) {
                endpoint(time: Fmt.time(leg.departure, leg.from.timeZone),
                         place: leg.from.name,
                         day: Fmt.day(leg.departure, leg.from.timeZone),
                         alignment: .leading)
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Image(systemName: leg.mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(leg.mode.color)
                    Text(Fmt.duration(leg.duration))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.mute)
                        .fixedSize()
                }
                .padding(.top, 8)
                Spacer(minLength: 8)
                endpoint(time: Fmt.time(leg.arrival, leg.to.timeZone),
                         place: leg.to.name,
                         day: Fmt.day(leg.arrival, leg.to.timeZone),
                         alignment: .trailing)
            }
            Text("Orari locali di ogni luogo")
                .font(.system(size: 12))
                .foregroundStyle(Theme.stone)
                .padding(.top, 12)
        }
    }

    private func endpoint(time: String, place: String, day: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(time)
                .font(.display(32))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(place)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(3)
            Text(day)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mute)
        }
        .frame(maxWidth: 130, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func hasInfo(_ leg: Leg) -> Bool {
        !(leg.bookingRef.isEmpty && leg.seat.isEmpty && leg.price.isEmpty && leg.notes.isEmpty)
    }

    private func info(_ leg: Leg) -> some View {
        VStack(spacing: 0) {
            if !leg.bookingRef.isEmpty {
                InfoRow(label: "Codice prenotazione", value: leg.bookingRef) {
                    Button {
                        UIPasteboard.general.string = leg.bookingRef
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
            if !leg.seat.isEmpty { InfoRow(label: "Posto", value: leg.seat) }
            if !leg.price.isEmpty { InfoRow(label: "Prezzo", value: leg.price) }
            if !leg.notes.isEmpty { InfoRow(label: "Note", value: leg.notes) }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }

    private func openInMaps(_ place: Place) {
        let item = MKMapItem(location: CLLocation(latitude: place.latitude, longitude: place.longitude), address: nil)
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

struct InfoRow<Trailing: View>: View {
    let label: String
    let value: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.stone)
                Text(value)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(label: String, value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

struct LinkRow: View {
    let link: LinkItem

    var body: some View {
        if let url = URL(string: link.url) {
            Link(destination: url) { row }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 34, height: 34)
                .background(Theme.fill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title.isEmpty ? link.url : link.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(link.url)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.stone)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.stone)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
