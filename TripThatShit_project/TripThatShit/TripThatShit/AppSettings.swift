import SwiftUI
import MapKit

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Sistema"
        case .light: "Chiaro"
        case .dark: "Scuro"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MapLook: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Mappa"
        case .hybrid: "Ibrida"
        case .satellite: "Satellite"
        }
    }

    var style: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .satellite: .imagery(elevation: .flat)
        }
    }
}

/// App-wide preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); applyAppearance() }
    }

    var mapLook: MapLook {
        didSet { defaults.set(mapLook.rawValue, forKey: Key.mapLook) }
    }

    /// Dashed great-circle line for flights (off draws a solid line).
    var dashedFlights: Bool {
        didSet { defaults.set(dashedFlights, forKey: Key.dashedFlights) }
    }

    private(set) var modeColors: [TransportMode: UInt32]

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let appearance = "appearance"
        static let mapLook = "mapLook"
        static let dashedFlights = "dashedFlights"
        static let modeColors = "modeColors"
    }

    private init() {
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        mapLook = MapLook(rawValue: defaults.string(forKey: Key.mapLook) ?? "") ?? .standard
        dashedFlights = defaults.object(forKey: Key.dashedFlights) as? Bool ?? true
        var colors: [TransportMode: UInt32] = [:]
        let stored = defaults.dictionary(forKey: Key.modeColors) as? [String: Int] ?? [:]
        for mode in TransportMode.allCases {
            colors[mode] = stored[mode.rawValue].map { UInt32($0) } ?? mode.defaultHex
        }
        modeColors = colors
    }

    // MARK: Transport colours

    func color(for mode: TransportMode) -> Color {
        Color(hex: modeColors[mode] ?? mode.defaultHex)
    }

    func setColor(_ hex: UInt32, for mode: TransportMode) {
        modeColors[mode] = hex
        saveColors()
    }

    func resetColors() {
        for mode in TransportMode.allCases { modeColors[mode] = mode.defaultHex }
        saveColors()
    }

    var colorsAreDefault: Bool {
        TransportMode.allCases.allSatisfy { modeColors[$0] == $0.defaultHex }
    }

    private func saveColors() {
        let dict = Dictionary(uniqueKeysWithValues: modeColors.map { ($0.key.rawValue, Int($0.value)) })
        defaults.set(dict, forKey: Key.modeColors)
    }

    // MARK: Appearance

    /// Applied on the windows so sheets and system UI follow too, and "Sistema" truly resets.
    func applyAppearance() {
        let style = appearance.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
