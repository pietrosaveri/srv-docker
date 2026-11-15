import Foundation
import Security

// Shared trips. The app stays local-first: every trip still lives in its own folder and
// works offline. A shared trip also has a sync.json next to trip.json, holding the
// members, the server version and the edits waiting to be sent.

nonisolated enum SyncConfig {
    /// TRIP_SERVER in the Xcode scheme points the app at a test server.
    static let baseURL: URL = ProcessInfo.processInfo.environment["TRIP_SERVER"].flatMap(URL.init(string:))
        ?? URL(string: "https://trip.pietroserver.duckdns.org")!
    static let pollInterval: Duration = .seconds(15)

    static func inviteMessage(title: String, code: String) -> String {
        """
        Unisciti al viaggio "\(title)" su TripThatShit.
        Apri l'app, tocca ··· e poi "Unisciti con codice": \(InviteCode.pretty(code))
        \(baseURL.appendingPathComponent("join/\(code)").absoluteString)
        """
    }
}

nonisolated enum InviteCode {
    /// "abcd efgh" or "ABCD-EFGH" -> "ABCDEFGH".
    static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    static func pretty(_ code: String) -> String {
        let c = normalize(code)
        guard c.count == 8 else { return c }
        return "\(c.prefix(4))-\(c.suffix(4))"
    }

    /// Picks an invite code out of a pasted message.
    static func find(in text: String) -> String? {
        if let r = text.range(of: #"[A-Za-z0-9]{4}-[A-Za-z0-9]{4}"#, options: .regularExpression) {
            return normalize(String(text[r]))
        }
        if let r = text.range(of: #"join/([A-Za-z0-9]{8})"#, options: .regularExpression) {
            return normalize(String(text[r].dropFirst(5)))
        }
        let n = normalize(text)
        return n.count == 8 ? n : nil
    }
}

// MARK: - Models

nonisolated struct Member: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
}

nonisolated enum PendingOp: Codable, Hashable, Sendable {
    case upsert(Leg)
    case delete(UUID)
    case title(String)
    case upsertStay(Stay)
    case deleteStay(UUID)

    /// The leg or stay this op is about (nil for the title).
    private var target: UUID? {
        switch self {
        case .upsert(let l): l.id
        case .delete(let id), .deleteStay(let id): id
        case .upsertStay(let s): s.id
        case .title: nil
        }
    }

    /// Two ops on the same leg or stay (or both on the title): only the newest needs sending.
    func supersedes(_ other: PendingOp) -> Bool {
        if case .title = self, case .title = other { return true }
        guard let a = target, let b = other.target else { return false }
        return a == b
    }
}

nonisolated struct QueuedOp: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var op: PendingOp
}

/// sync.json: present only for shared trips.
nonisolated struct SyncState: Codable, Sendable {
    var version = 0
    var members: [Member] = []
    var pending: [QueuedOp] = []
    /// Attachment files the server already has.
    var uploaded: Set<String> = []
}

nonisolated struct Session: Codable, Sendable {
    var id: String
    var name: String
    var token: String
}

nonisolated struct RemoteTrip: Decodable, Sendable {
    var id: String
    var title: String
    var owner: String
    var version: Int
    var members: [Member]
    var legs: [Leg]
    var stays: [Stay]

    private enum CodingKeys: String, CodingKey { case id, title, owner, version, members, legs, stays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        owner = try c.decode(String.self, forKey: .owner)
        version = try c.decode(Int.self, forKey: .version)
        members = try c.decode([Member].self, forKey: .members)
        // One leg written by a newer app version must not hide the whole trip.
        legs = try c.decode([Lossy<Leg>].self, forKey: .legs).compactMap(\.value)
        stays = (try c.decodeIfPresent([Lossy<Stay>].self, forKey: .stays) ?? []).compactMap(\.value)
    }
}

nonisolated private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

nonisolated struct RemoteTripRef: Decodable, Sendable {
    var id: String
    var title: String
    var version: Int
}

nonisolated struct MeResponse: Decodable, Sendable {
    var id: String
    var name: String
    var trips: [RemoteTripRef]
}

// MARK: - Account

/// Who this phone is on the server. The token is kept in the Keychain.
@Observable
final class SyncAccount {
    static let shared = SyncAccount()

    private(set) var session: Session?

    var isSignedIn: Bool { session != nil }

    private init() { session = Keychain.load() }

    func signIn(_ session: Session) {
        self.session = session
        Keychain.save(session)
    }

    func updateName(_ name: String) {
        guard var s = session, s.name != name else { return }
        s.name = name
        signIn(s)
    }

    var api: API { API(token: session?.token) }
}

nonisolated private enum Keychain {
    static let service = "TripThatShit.session"

    static func load() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - API

nonisolated enum APIError: LocalizedError {
    case offline
    case unauthorized
    case forbidden
    case notFound
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .offline: "Nessuna connessione al server."
        case .unauthorized: "Accesso non valido. Riprova."
        case .forbidden: "Non hai accesso a questo viaggio."
        case .notFound: "Non trovato."
        case .http(_, let message): message
        }
    }

    /// The server rejected this request for good: retrying the same thing will not help.
    var isPermanent: Bool {
        if case .http(let status, _) = self { return (400..<500).contains(status) }
        return false
    }
}

nonisolated struct API: Sendable {
    let token: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: Account

    func register(name: String, key: String) async throws -> Session {
        try await call("POST", "api/register", json: ["name": name, "key": key])
    }

    func me() async throws -> MeResponse {
        try await call("GET", "api/me")
    }

    func rename(_ name: String) async throws {
        _ = try await raw("PATCH", "api/me", json: ["name": name])
    }

    /// Joins with an invite code. The session's token is empty when this phone already had an account.
    func join(code: String, name: String) async throws -> (Session, RemoteTrip) {
        struct User: Decodable { var id: String; var name: String; var token: String? }
        struct Response: Decodable { var user: User; var trip: RemoteTrip }
        let r: Response = try await call("POST", "api/join", json: ["code": code, "name": name])
        return (Session(id: r.user.id, name: r.user.name, token: r.user.token ?? ""), r.trip)
    }

    // MARK: Trips

    func createTrip(id: UUID, title: String, legs: [Leg], stays: [Stay]) async throws -> RemoteTrip {
        struct Body: Encodable { var title: String; var legs: [Leg]; var stays: [Stay] }
        return try await call("PUT", "api/trips/\(id.uuidString)", json: Body(title: title, legs: legs, stays: stays))
    }

    func trip(_ id: UUID) async throws -> RemoteTrip {
        try await call("GET", "api/trips/\(id.uuidString)")
    }

    func setTitle(_ id: UUID, _ title: String) async throws {
        _ = try await raw("PATCH", "api/trips/\(id.uuidString)", json: ["title": title])
    }

    func putLeg(_ id: UUID, _ leg: Leg) async throws {
        _ = try await raw("PUT", "api/trips/\(id.uuidString)/legs/\(leg.id.uuidString)", json: leg)
    }

    func deleteLeg(_ id: UUID, _ legID: UUID) async throws {
        _ = try await raw("DELETE", "api/trips/\(id.uuidString)/legs/\(legID.uuidString)")
    }

    func putStay(_ id: UUID, _ stay: Stay) async throws {
        _ = try await raw("PUT", "api/trips/\(id.uuidString)/stays/\(stay.id.uuidString)", json: stay)
    }

    func deleteStay(_ id: UUID, _ stayID: UUID) async throws {
        _ = try await raw("DELETE", "api/trips/\(id.uuidString)/stays/\(stayID.uuidString)")
    }

    func invite(_ id: UUID) async throws -> String {
        struct Response: Decodable { var code: String }
        let r: Response = try await call("POST", "api/trips/\(id.uuidString)/invites")
        return r.code
    }

    func leave(_ id: UUID) async throws {
        _ = try await raw("DELETE", "api/trips/\(id.uuidString)/members/me")
    }

    // MARK: Files

    func upload(_ id: UUID, name: String, from file: URL) async throws {
        var req = request("PUT", "api/trips/\(id.uuidString)/files/\(name)")
        req.timeoutInterval = 300
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await perform { try await Self.session.upload(for: req, fromFile: file) }
    }

    /// Downloads into a temporary file and returns its URL.
    func download(_ id: UUID, name: String) async throws -> URL {
        var req = request("GET", "api/trips/\(id.uuidString)/files/\(name)")
        req.timeoutInterval = 300
        let (tmp, response) = try await mapErrors { try await Self.session.download(for: req) }
        try check(response, body: Data())
        return tmp
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: SyncConfig.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func call<T: Decodable>(_ method: String, _ path: String, json: (any Encodable)? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await raw(method, path, json: json))
    }

    private func raw(_ method: String, _ path: String, json: (any Encodable)? = nil) async throws -> Data {
        var req = request(method, path)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(json)
        }
        return try await perform { try await Self.session.data(for: req) }
    }

    private func perform(_ op: () async throws -> (Data, URLResponse)) async throws -> Data {
        let (data, response) = try await mapErrors(op)
        try check(response, body: data)
        return data
    }

    private func mapErrors<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch is URLError { throw APIError.offline }
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            throw APIError.http(http.statusCode, Self.italian(message) ?? "Errore del server (\(http.statusCode)).")
        }
    }

    private static func italian(_ message: String?) -> String? {
        switch message {
        case "wrong server key": "Chiave del server errata."
        case "invite code not valid or expired": "Codice invito non valido o scaduto."
        case "too many attempts, try again later": "Troppi tentativi. Riprova tra un'ora."
        case "name required": "Inserisci il tuo nome."
        case "file too large (max 100 MB)": "File troppo grande (massimo 100 MB)."
        default: message
        }
    }
}
