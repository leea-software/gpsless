import CoreLocation
import Foundation

/// Keeps a drive running while another app is in front or the screen is off.
/// iOS suspends an app shortly after it leaves the screen, which stops Core
/// Motion; an active background location session keeps the app running. The
/// session asks for the coarsest accuracy and its locations are discarded: the
/// estimator never receives them. Without location permission the app pauses
/// on leaving the screen, as before.
@MainActor
final class BackgroundTrackingService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var active = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// True while the app will keep receiving motion in the background.
    var keepsRunning: Bool {
        return active && isAuthorized
    }

    var recordingMetadata: [String: String] {
        return ["backgroundTracking": isAuthorized ? "location_keepalive_3km_not_estimator_input" : "unavailable_pauses_in_background"]
    }

    /// Asks once, before the parked calibration, so answering the prompt
    /// does not move the phone while it measures. UI tests never ask.
    func requestPermissionIfNeeded() {
        guard manager.authorizationStatus == .notDetermined,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    /// Starts while the app is in front, as When In Use permission requires.
    func begin() {
        active = true
        requestPermissionIfNeeded()
        startIfAllowed()
    }

    func end() {
        active = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func startIfAllowed() {
        guard active, isAuthorized else {
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startIfAllowed()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally unused: the session exists only to keep the app running.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
