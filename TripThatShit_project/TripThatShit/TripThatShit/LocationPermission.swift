import CoreLocation

/// Asks for location only when the user taps the locate button.
final class LocationPermission {
    private let manager = CLLocationManager()

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
