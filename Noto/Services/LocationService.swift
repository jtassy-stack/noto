import CoreLocation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "LocationService")

/// Requests a single "when in use" location fix, then stops updating.
/// If the user denies permission, `location` stays nil and callers receive `geo: nil`.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published var location: CLLocation?
    @Published var authStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        authStatus = CLLocationManager().authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Requests "when in use" authorization and fetches one location update, then stops.
    /// Safe to call multiple times — no-ops if already authorized and a location is available.
    func requestOnce() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            logger.info("Location access denied or restricted — skipping geo")
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.location = loc
            self?.manager.stopUpdatingLocation()
            logger.info("Location acquired: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self?.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.warning("Location error: \(error.localizedDescription) — proceeding without geo")
    }
}
