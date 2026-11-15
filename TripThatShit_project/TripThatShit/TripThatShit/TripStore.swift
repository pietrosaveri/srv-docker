import SwiftUI
import MapKit

/// Precomputed map geometry for a leg (built once per change, never during rendering).
struct LegGeometry {
    let coords: [CLLocationCoordinate2D]
    let mid: CLLocationCoordinate2D
    let rect: MKMapRect
}

struct Stop: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// Local-first storage for one trip: one small JSON file plus an attachments folder.
/// Everything lives on the phone, so the app works fully offline. A shared trip also
/// queues every edit and syncs it with the server when there is a connection.
@Observable
final class TripStore {
    let id: UUID
    var title = "Il nostro viaggio"
    private(set) var legs: [Leg] = []
    /// Where we sleep, sorted by check-in.
    private(set) var stays: [Stay] = []
    private(set) var geometry: [UUID: LegGeometry] = [:]
    private(set) var stops: [Stop] = []

    /// Non-nil when the trip is shared with friends.
    private(set) var syncState: SyncState?
    private(set) var syncing = false
    private(set) var syncError: String?
    private(set) var lastSynced: Date?
    /// Bumped when attachment files appear on disk, so views re-check `hasFile`.
    private(set) var fileRevision = 0

    @ObservationIgnored let attachmentsDir: URL
    @ObservationIgnored private let dataURL: URL
    @ObservationIgnored private let syncURL: URL
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var syncGeneration = 0

    init(id: UUID, directory base: URL) {
        self.id = id
        attachmentsDir = base.appendingPathComponent("Attachments", isDirectory: true)
        dataURL = base.appendingPathComponent("trip.json")
        syncURL = base.appendingPathComponent("sync.json")
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        load()
    }

    var isShared: Bool { syncState != nil }
    var members: [Member] { syncState?.members ?? [] }
    var pendingCount: Int { syncState?.pending.count ?? 0 }

    // MARK: Queries

    func leg(_ id: UUID) -> Leg? { legs.first { $0.id == id } }
    func stay(_ id: UUID) -> Stay? { stays.first { $0.id == id } }

    /// Every attachment of the trip, legs and stays.
    var allAttachments: [Attachment] { legs.flatMap(\.attachments) + stays.flatMap(\.attachments) }

    /// Map area of a leg or a stay, for focusing the camera.
    func rect(for id: UUID) -> MKMapRect? {
        if let g = geometry[id] { return g.rect }
        if let s = stay(id), s.place.hasCoordinate {
            let p = MKMapPoint(s.place.coordinate)
            return MKMapRect(x: p.x, y: p.y, width: 0, height: 0)
        }
        return nil
    }

    /// The leg in progress, or the next one to depart.
    func currentOrNext(now: Date = .now) -> Leg? { legs.first { $0.arrival > now } }

    var allRect: MKMapRect? {
        let rects = geometry.values.map(\.rect) + stays.compactMap { rect(for: $0.id) }
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r
    }

    // MARK: Mutations

    func upsert(_ leg: Leg) {
        if let i = legs.firstIndex(where: { $0.id == leg.id }) { legs[i] = leg } else { legs.append(leg) }
        didChange()
        enqueue(.upsert(leg))
    }

    func delete(_ leg: Leg) {
        removeFiles(leg.attachments)
        legs.removeAll { $0.id == leg.id }
        didChange()
        enqueue(.delete(leg.id))
    }

    func upsertStay(_ stay: Stay) {
        if let i = stays.firstIndex(where: { $0.id == stay.id }) { stays[i] = stay } else { stays.append(stay) }
        didChange()
        enqueue(.upsertStay(stay))
    }

    func deleteStay(_ stay: Stay) {
        removeFiles(stay.attachments)
        stays.removeAll { $0.id == stay.id }
        didChange()
        enqueue(.deleteStay(stay.id))
    }

    private func didChange() {
        legs.sort { $0.departure < $1.departure }
        stays.sort { $0.checkIn < $1.checkIn }
        rebuildGeometry()
        save()
    }

    // MARK: Attachments

    func url(for attachment: Attachment) -> URL {
        attachmentsDir.appendingPathComponent(attachment.storedName)
    }

    /// Copies a picked file into the app so it stays available offline.
    func importFile(at source: URL) throws -> Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension
        let stored = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        try FileManager.default.copyItem(at: source, to: attachmentsDir.appendingPathComponent(stored))
        return Attachment(name: source.deletingPathExtension().lastPathComponent, storedName: stored)
    }

    func importData(_ data: Data, ext: String, name: String) throws -> Attachment {
        let stored = UUID().uuidString + ".\(ext)"
        try data.write(to: attachmentsDir.appendingPathComponent(stored), options: .atomic)
        return Attachment(name: name, storedName: stored)
    }

    func removeFiles(_ attachments: [Attachment]) {
        for a in attachments { try? FileManager.default.removeItem(at: url(for: a)) }
    }

    /// False while a file added by a friend is still downloading.
    func hasFile(_ attachment: Attachment) -> Bool {
        _ = fileRevision
        return FileManager.default.fileExists(atPath: url(for: attachment).path)
    }

    // MARK: Share between phones

    func load(package: TripPackage) {
        removeFiles(allAttachments)
        for (name, data) in package.files {
            try? data.write(to: attachmentsDir.appendingPathComponent(name), options: .atomic)
        }
        let old = (legs, stays)
        title = package.title
        legs = package.legs
        stays = package.stays ?? []
        didChange()
        enqueueReplacement(of: old)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: dataURL),
              let file = try? JSONDecoder().decode(TripFile.self, from: data) else { return }
        title = file.title
        legs = file.legs.sorted { $0.departure < $1.departure }
        stays = (file.stays ?? []).sorted { $0.checkIn < $1.checkIn }
        rebuildGeometry()
        if let data = try? Data(contentsOf: syncURL) {
            syncState = try? JSONDecoder().decode(SyncState.self, from: data)
        }
    }

    private func save() {
        let file = TripFile(title: title, legs: legs, stays: stays)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: dataURL, options: .atomic)
    }

    func saveTitle(_ newTitle: String) {
        title = newTitle
        save()
        enqueue(.title(newTitle))
    }

    // MARK: Geometry

    private func rebuildGeometry() {
        var geo: [UUID: LegGeometry] = [:]
        var stopMap: [String: Stop] = [:]
        for leg in legs where leg.isMappable {
            let a = leg.from.coordinate, b = leg.to.coordinate
            var coords = [a, b]
            if leg.mode == .plane {
                // Great circle, sampled so taps and the midpoint badge follow the drawn arc.
                let poly = MKGeodesicPolyline(coordinates: [a, b], count: 2)
                let n = poly.pointCount
                let pts = poly.points()
                coords = (0..<n).map { pts[$0].coordinate }
                if coords.count < 2 { coords = [a, b] }
            }
            let mid = leg.mode == .plane
                ? coords[coords.count / 2]
                : CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
            var rect = MKMapRect.null
            for c in coords {
                let p = MKMapPoint(c)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            geo[leg.id] = LegGeometry(coords: coords, mid: mid, rect: rect)

            for place in [leg.from, leg.to] {
                let key = String(format: "%.3f,%.3f", place.latitude, place.longitude)
                if stopMap[key] == nil {
                    stopMap[key] = Stop(id: key, name: place.name, coordinate: place.coordinate)
                }
            }
        }
        geometry = geo
        stops = Array(stopMap.values)
    }
}

// MARK: - Sync with friends

extension TripStore {
    /// Uploads this trip (legs and files) so friends can join it.
    func startSharing() async throws {
        let api = SyncAccount.shared.api
        do {
            _ = try await api.createTrip(id: id, title: title, legs: legs, stays: stays)
        } catch APIError.http(409, _) {
            // Already on the server (shared before, then this phone lost sync.json): fine if we are a member.
            _ = try await api.trip(id)
        }
        var state = SyncState()
        // Re-sending a leg or stay uploads the files it points to.
        state.pending = legs.filter { !$0.attachments.isEmpty }.map { QueuedOp(op: .upsert($0)) }
            + stays.filter { !$0.attachments.isEmpty }.map { QueuedOp(op: .upsertStay($0)) }
        syncState = state
        saveSync()
        await sync()
    }

    /// Turns a trip that came from the server (join, or another phone) into a local shared trip.
    func adopt(_ remote: RemoteTrip) {
        if syncState == nil { syncState = SyncState() }
        apply(remote)
        Task { await sync() }
    }

    /// Back to a plain local trip, keeping everything on the phone.
    func stopSharing() {
        syncState = nil
        syncError = nil
        try? FileManager.default.removeItem(at: syncURL)
    }

    func createInvite() async throws -> String {
        try await SyncAccount.shared.api.invite(id)
    }

    /// Sends queued edits, then pulls everyone else's. Safe to call often.
    func sync() async {
        guard isShared, SyncAccount.shared.isSignedIn else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            await syncOnce(SyncAccount.shared.api)
        } while syncAgain && isShared
    }

    private func syncOnce(_ api: API) async {
        do {
            while let next = syncState?.pending.first {
                do {
                    try await push(next.op, api)
                } catch let error as APIError where error.isPermanent {
                    syncError = error.localizedDescription // drop it, or the queue would be stuck forever
                }
                syncState?.pending.removeAll { $0.id == next.id }
                saveSync()
            }
            apply(try await api.trip(id))
            await downloadMissingFiles(api)
            syncError = nil
            lastSynced = .now
        } catch APIError.forbidden, APIError.notFound {
            // Make sure the trip itself is gone, not just one route (an older server has no stays).
            if (try? await api.trip(id)) != nil {
                syncError = "Il server non accetta questa modifica: aggiornalo. Resta in attesa sul telefono."
                return
            }
            stopSharing()
            syncError = "Non fai più parte di questo viaggio condiviso. La copia sul telefono resta."
        } catch APIError.offline {
            syncError = pendingCount > 0 ? "Offline: le modifiche partono appena torni online." : nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func push(_ op: PendingOp, _ api: API) async throws {
        switch op {
        case .title(let t):
            try await api.setTitle(id, t)
        case .delete(let legID):
            try await api.deleteLeg(id, legID)
        case .upsert(let leg):
            try await uploadFiles(leg.attachments, api)
            try await api.putLeg(id, leg)
        case .deleteStay(let stayID):
            try await api.deleteStay(id, stayID)
        case .upsertStay(let stay):
            try await uploadFiles(stay.attachments, api)
            try await api.putStay(id, stay)
        }
    }

    /// Files go up before the leg or stay that points to them, so friends never see a ticket they cannot open.
    private func uploadFiles(_ attachments: [Attachment], _ api: API) async throws {
        for a in attachments where syncState?.uploaded.contains(a.storedName) == false {
            let file = url(for: a)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try await api.upload(id, name: a.storedName, from: file)
            syncState?.uploaded.insert(a.storedName)
            saveSync()
        }
    }

    /// Server state plus any edits made here that the server has not seen yet.
    private func apply(_ remote: RemoteTrip) {
        guard var state = syncState else { return }
        var merged = Dictionary(remote.legs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var mergedStays = Dictionary(remote.stays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newTitle = remote.title
        for q in state.pending {
            switch q.op {
            case .upsert(let l): merged[l.id] = l
            case .delete(let legID): merged[legID] = nil
            case .upsertStay(let s): mergedStays[s.id] = s
            case .deleteStay(let stayID): mergedStays[stayID] = nil
            case .title(let t): newTitle = t
            }
        }
        for a in remote.legs.flatMap(\.attachments) + remote.stays.flatMap(\.attachments) {
            state.uploaded.insert(a.storedName)
        }
        state.members = remote.members
        state.version = remote.version
        syncState = state
        saveSync()

        let newLegs = merged.values.sorted { $0.departure < $1.departure }
        let newStays = mergedStays.values.sorted { $0.checkIn < $1.checkIn }
        guard newLegs != legs || newStays != stays || newTitle != title else { return }
        // Files a friend removed. Files only an open editor knows about are not in the trip yet, so they stay.
        let kept = Set((newLegs.flatMap(\.attachments) + newStays.flatMap(\.attachments)).map(\.storedName))
        removeFiles(allAttachments.filter { !kept.contains($0.storedName) })
        title = newTitle
        legs = newLegs
        stays = newStays
        rebuildGeometry()
        save()
    }

    private func downloadMissingFiles(_ api: API) async {
        let missing = allAttachments.filter { !FileManager.default.fileExists(atPath: url(for: $0).path) }
        for a in missing {
            guard let tmp = try? await api.download(id, name: a.storedName) else { continue }
            let dest = url(for: a)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { fileRevision += 1 }
        }
    }

    private func enqueue(_ op: PendingOp) {
        guard var state = syncState else { return }
        state.pending.removeAll { op.supersedes($0.op) }
        state.pending.append(QueuedOp(op: op))
        syncState = state
        saveSync()
        scheduleSync()
    }

    /// After replacing everything (import from file), tell the server about each change.
    private func enqueueReplacement(of old: ([Leg], [Stay])) {
        guard isShared else { return }
        let keepLegs = Set(legs.map(\.id)), keepStays = Set(stays.map(\.id))
        for leg in old.0 where !keepLegs.contains(leg.id) { enqueue(.delete(leg.id)) }
        for stay in old.1 where !keepStays.contains(stay.id) { enqueue(.deleteStay(stay.id)) }
        for leg in legs { enqueue(.upsert(leg)) }
        for stay in stays { enqueue(.upsertStay(stay)) }
        enqueue(.title(title))
    }

    /// Sends edits shortly after they happen, batching quick successive saves.
    private func scheduleSync() {
        syncGeneration += 1
        let generation = syncGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if generation == syncGeneration { await sync() }
        }
    }

    private func saveSync() {
        guard let syncState, let data = try? JSONEncoder().encode(syncState) else { return }
        try? data.write(to: syncURL, options: .atomic)
    }
}
