import Foundation

/// Lightweight info shown on the home screen, read from each trip's JSON.
struct TripSummary: Identifiable {
    let id: UUID
    let title: String
    let legCount: Int
    let stayCount: Int
    let start: Date?
    let startTZ: TimeZone
    let end: Date?
    let endTZ: TimeZone
    let from: String?
    let to: String?
    /// Legs per mode, in trip order of first appearance.
    let modeCounts: [(TransportMode, Int)]
    /// Friends on this trip, empty when it is not shared.
    let members: [Member]
    let isShared: Bool

    enum Status { case empty, upcoming, ongoing, past }

    func status(now: Date = .now) -> Status {
        guard let start, let end else { return .empty }
        if end < now { return .past }
        return start <= now ? .ongoing : .upcoming
    }

    init(id: UUID, file: TripFile, sync: SyncState?) {
        self.id = id
        title = file.title
        isShared = sync != nil
        members = sync?.members ?? []
        let legs = file.legs.sorted { $0.departure < $1.departure }
        let stays = file.stays ?? []
        legCount = legs.count
        stayCount = stays.count
        // The trip spans its legs and its stays: (date, time zone) of every start and end.
        let starts = legs.map { ($0.departure, $0.from.timeZone) } + stays.map { ($0.checkIn, $0.timeZone) }
        let ends = legs.map { ($0.arrival, $0.to.timeZone) } + stays.map { ($0.checkOut, $0.timeZone) }
        let first = starts.min { $0.0 < $1.0 }, last = ends.max { $0.0 < $1.0 }
        start = first?.0
        startTZ = first?.1 ?? .current
        end = last?.0
        endTZ = last?.1 ?? .current
        from = legs.first?.from.name
        to = legs.last?.to.name
        var order: [TransportMode] = []
        var counts: [TransportMode: Int] = [:]
        for leg in legs {
            if counts[leg.mode] == nil { order.append(leg.mode) }
            counts[leg.mode, default: 0] += 1
        }
        modeCounts = order.map { ($0, counts[$0]!) }
    }
}

/// All trips on the phone. Each trip lives in its own folder: Trips/<uuid>/trip.json + Attachments.
@Observable
final class TripLibrary {
    private(set) var trips: [TripSummary] = []

    @ObservationIgnored private let root: URL
    /// One store per trip, so the home screen and the open trip never write the same files twice.
    @ObservationIgnored private var stores: [UUID: TripStore] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        migrateSingleTrip(from: support.appendingPathComponent("Trip", isDirectory: true))
        reload()
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let now = Date.now
        trips = dirs.compactMap { dir -> TripSummary? in
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("trip.json")),
                  let file = try? JSONDecoder().decode(TripFile.self, from: data) else { return nil }
            let sync = (try? Data(contentsOf: dir.appendingPathComponent("sync.json")))
                .flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
            return TripSummary(id: id, file: file, sync: sync)
        }
        .sorted { a, b in
            // Ongoing and upcoming first (soonest first), empty drafts next, past trips last (latest first).
            func rank(_ t: TripSummary) -> Int {
                switch t.status(now: now) { case .ongoing: 0; case .upcoming: 1; case .empty: 2; case .past: 3 }
            }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 3 { return (a.end ?? .distantPast) > (b.end ?? .distantPast) }
            if ra == 2 { return a.title.localizedCompare(b.title) == .orderedAscending }
            return (a.start ?? .distantFuture) < (b.start ?? .distantFuture)
        }
    }

    func store(for id: UUID) -> TripStore {
        if let s = stores[id] { return s }
        let s = TripStore(id: id, directory: directory(for: id))
        stores[id] = s
        return s
    }

    // MARK: Create / delete

    @discardableResult
    func create(title: String) -> TripStore {
        let store = newStore()
        store.saveTitle(title.isEmpty ? "Nuovo viaggio" : title)
        reload()
        return store
    }

    @discardableResult
    func create(from package: TripPackage) -> TripStore {
        let store = newStore()
        store.load(package: package)
        reload()
        return store
    }


    func rename(_ id: UUID, to title: String) {
        store(for: id).saveTitle(title)
        reload()
    }

    func delete(_ id: UUID) {
        stores[id] = nil
        try? FileManager.default.removeItem(at: directory(for: id))
        reload()
    }

    // MARK: Shared trips

    /// Joins a friend's trip with an invite code, creating this phone's account if needed.
    func join(code: String, name: String) async throws -> TripStore {
        let account = SyncAccount.shared
        let (session, remote) = try await account.api.join(code: code, name: name)
        if !session.token.isEmpty { account.signIn(session) }
        guard let id = UUID(uuidString: remote.id) else { throw APIError.notFound }
        let store = store(for: id)
        store.adopt(remote)
        reload()
        return store
    }

    /// Leaves a shared trip on the server, then deletes it from the phone.
    func leave(_ id: UUID) async throws {
        do {
            try await SyncAccount.shared.api.leave(id)
        } catch APIError.forbidden, APIError.notFound {
            // Already out of it.
        }
        delete(id)
    }

    /// Pulls every shared trip, adds ones joined from elsewhere, and unshares ones we were removed from.
    func syncAll() async {
        let account = SyncAccount.shared
        guard account.isSignedIn, let me = try? await account.api.me() else { return }
        account.updateName(me.name)
        let local = Set(trips.map(\.id))
        let remoteIDs = Set(me.trips.compactMap { UUID(uuidString: $0.id) })
        for ref in me.trips {
            guard let id = UUID(uuidString: ref.id) else { continue }
            let store = store(for: id)
            if !local.contains(id) || !store.isShared {
                if let remote = try? await account.api.trip(id) { store.adopt(remote) }
            } else if store.syncState?.version != ref.version || store.pendingCount > 0 {
                await store.sync()
            }
        }
        for summary in trips where summary.isShared && !remoteIDs.contains(summary.id) {
            store(for: summary.id).stopSharing()
        }
        reload()
    }

    // MARK: Private

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func newStore() -> TripStore {
        store(for: UUID())
    }

    /// Earlier versions kept a single trip in Application Support/Trip. Move it into the library.
    private func migrateSingleTrip(from old: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.appendingPathComponent("trip.json").path) else { return }
        try? fm.moveItem(at: old, to: directory(for: UUID()))
    }
}
