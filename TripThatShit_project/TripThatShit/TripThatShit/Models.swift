import SwiftUI
import CoreLocation

nonisolated enum TransportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case plane, train, bus, ferry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plane: "Aereo"
        case .train: "Treno"
        case .bus: "Bus"
        case .ferry: "Traghetto"
        }
    }

    var symbol: String {
        switch self {
        case .plane: "airplane"
        case .train: "train.side.front.car"
        case .bus: "bus.fill"
        case .ferry: "ferry.fill"
        }
    }

    var defaultHex: UInt32 {
        switch self {
        case .plane: 0x3D7BFF
        case .train: 0xE23B4A
        case .bus: 0x2FB866
        case .ferry: 0xEC7E00
        }
    }

    /// The user's colour for this mode (Impostazioni), falling back to the default.
    @MainActor var color: Color { AppSettings.shared.color(for: self) }
}

nonisolated struct Place: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZoneID: String?

    static let empty = Place(name: "", latitude: 0, longitude: 0, timeZoneID: nil)

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var hasCoordinate: Bool { !(latitude == 0 && longitude == 0) }
    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }
}

nonisolated struct LinkItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var url: String
}

nonisolated struct Attachment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Name shown to the user.
    var name: String
    /// File name inside the app's attachments folder.
    var storedName: String

    var symbol: String {
        switch (storedName as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp": "photo"
        case "pkpass": "wallet.pass"
        default: "doc"
        }
    }
}

nonisolated struct Leg: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var mode: TransportMode = .train
    var from: Place = .empty
    var to: Place = .empty
    var departure: Date
    var arrival: Date
    var carrier = ""
    var number = ""
    var bookingRef = ""
    var seat = ""
    var price = ""
    var notes = ""
    var links: [LinkItem] = []
    var attachments: [Attachment] = []

    var isMappable: Bool { from.hasCoordinate && to.hasCoordinate }
    var duration: TimeInterval { max(0, arrival.timeIntervalSince(departure)) }

    var title: String {
        let line = [carrier, number].filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? mode.label : "\(mode.label) \(line)"
    }
}

nonisolated struct TripFile: Codable, Sendable {
    var title: String
    var legs: [Leg]
}

/// Portable trip with every attachment embedded, used to share the trip between phones.
nonisolated struct TripPackage: Codable, Sendable {
    var version = 1
    var title: String
    var legs: [Leg]
    var files: [String: Data]
}

// MARK: - Formatting

nonisolated enum Fmt {
    static let locale = Locale(identifier: "it_IT")

    static func time(_ date: Date, _ tz: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: tz))
    }

    static func day(_ date: Date, _ tz: TimeZone) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: tz)
        style = style.weekday(.abbreviated).day().month(.abbreviated)
        return date.formatted(style)
    }

    static func dayKey(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "sab 28 nov - mer 9 dic".
    static func range(_ start: Date, _ startTZ: TimeZone, _ end: Date, _ endTZ: TimeZone) -> String {
        let a = day(start, startTZ), b = day(end, endTZ)
        return a == b ? a : "\(a) - \(b)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "tra 2 g 4 h", "tra 3 h 10 min", "tra 5 min".
    static func countdown(to date: Date, now: Date = .now) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "ora" }
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return h > 0 ? "tra \(d) g \(h) h" : "tra \(d) g" }
        if h > 0 { return m > 0 ? "tra \(h) h \(m) min" : "tra \(h) h" }
        return "tra \(m) min"
    }
}

extension Date {
    /// Keeps the same wall-clock time when the time zone changes.
    nonisolated func rebased(from old: TimeZone, to new: TimeZone) -> Date {
        guard old != new else { return self }
        var oldCal = Calendar(identifier: .gregorian); oldCal.timeZone = old
        var newCal = Calendar(identifier: .gregorian); newCal.timeZone = new
        let comps = oldCal.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return newCal.date(from: comps) ?? self
    }
}
