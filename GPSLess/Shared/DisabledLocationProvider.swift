import MapLibre

/// The renderer receives no system location or compass updates. All visible
/// positioning is supplied by our motion engine through ordinary annotations.
final class DisabledLocationProvider: NSObject, MLNLocationManager {
    weak var delegate: MLNLocationManagerDelegate?
    var headingOrientation: CLDeviceOrientation = .portrait
    var authorizationStatus: CLAuthorizationStatus {
        return .denied
    }

    func requestAlwaysAuthorization() {
        // This app never requests location permission.
    }

    func requestWhenInUseAuthorization() {
        // This app never requests location permission.
    }

    func startUpdatingLocation() {
        // Deliberately provides no location data.
    }

    func stopUpdatingLocation() {
        // No location subscription exists.
    }

    func startUpdatingHeading() {
        // Heading comes from the selected road and gyroscope.
    }

    func stopUpdatingHeading() {
        // No compass subscription exists.
    }

    func dismissHeadingCalibrationDisplay() {
        // No system compass calibration is requested.
    }
}
