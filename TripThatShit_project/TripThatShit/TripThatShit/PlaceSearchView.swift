import SwiftUI
import MapKit

@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { results = [] } else { completer.queryFragment = q }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { self.results = Array(completer.results.prefix(12)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

/// Search needs a connection. Without one you can still save the name (it just will not appear on the map).
struct PlaceSearchView: View {
    let initialQuery: String
    let onPick: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completer = PlaceCompleter()
    @State private var resolving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(completer.results, id: \.self) { result in
                        Button { resolve(result) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).foregroundStyle(Theme.text)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(Theme.stone)
                                }
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }

                    Section {
                        Button {
                            onPick(Place(name: query.trimmingCharacters(in: .whitespaces), latitude: 0, longitude: 0, timeZoneID: nil))
                            dismiss()
                        } label: {
                            Label("Usa \"\(query)\" senza posizione", systemImage: "text.cursor")
                                .foregroundStyle(Theme.mute)
                        }
                        .listRowBackground(Theme.surface)
                    } footer: {
                        Text("Senza posizione la tratta non compare sulla mappa. Puoi cercare di nuovo quando sei online.")
                    }
                }
                if failed {
                    Text("Impossibile trovare la posizione. Controlla la connessione.")
                        .foregroundStyle(Theme.danger)
                        .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .overlay { if resolving { ProgressView().tint(Theme.text) } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stazione, aeroporto, porto, citta")
            .searchFocused($focused)
            .onChange(of: query) { _, q in completer.update(q) }
            .navigationTitle("Cerca luogo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            }
            .onAppear {
                query = initialQuery
                focused = true
            }
        }
        .tint(Theme.text)
        .presentationBackground(Theme.canvas)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        resolving = true
        failed = false
        Task {
            defer { resolving = false }
            do {
                let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
                guard let item = response.mapItems.first else { failed = true; return }
                let c = item.location.coordinate
                onPick(Place(
                    name: item.name ?? completion.title,
                    latitude: c.latitude,
                    longitude: c.longitude,
                    timeZoneID: item.timeZone?.identifier
                ))
                dismiss()
            } catch {
                failed = true
            }
        }
    }
}
