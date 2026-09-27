import Combine
import CoreLocation
import Foundation

/// Reference logger. Its only output is a recording row; it never receives an
/// estimator, a road graph, or the map's location provider. It keeps recording
/// while a drive continues in the background.
@MainActor
final class GPSReferenceService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "gpsReference.enabled")
            if isEnabled {
                prepareManager(requestPermission: true)
            } else {
                stopCollection(reason: "disabled")
            }
            refreshStatus()
        }
    }
    @Published private(set) var statusText = "GPS tracing off"
    @Published private(set) var referenceCount = 0
    var onRecord: ((DriveEntry, UUID) -> Void)?

    private let defaults: UserDefaults
    private let makeLocationManager: () -> CLLocationManager
    private var manager: CLLocationManager?
    private var sessionID: UUID?
    private var capture: GPSReferenceCapture?
    private var lastSample: GPSReferenceSample?
    private var lastError: String?

    init(defaults: UserDefaults = .standard, makeLocationManager: @escaping () -> CLLocationManager = {
        return CLLocationManager()
    }) {
        self.defaults = defaults
        self.makeLocationManager = makeLocationManager
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--reset-gps-tracing") {
            defaults.set(false, forKey: "gpsReference.enabled")
        }
        isEnabled = defaults.bool(forKey: "gpsReference.enabled")
        super.init()
        if isEnabled {
            prepareManager(requestPermission: false)
        }
        refreshStatus()
    }

    var recordingMetadata: [String: String] {
        return [
            "gpsTracingEnabled": String(isEnabled),
            "gpsTracingPurpose": "reference_only_never_estimator_input",
            "gpsProvider": "iOS Core Location; not raw GNSS or guaranteed ground truth",
            "gpsMaximumRecordedRateHz": "1",
            "gpsTimestampConvention": "timestamp and receivedTimestamp are Unix seconds; time is receipt uptime minus fix age",
            "gpsAuthorization": authorizationName,
            "gpsAccuracyAuthorization": accuracyName
        ]
    }

    func beginRide(sessionID: UUID) {
        stopCollection(reason: "restart")
        self.sessionID = sessionID
        referenceCount = 0
        lastSample = nil
        lastError = nil
        if isEnabled {
            prepareManager(requestPermission: false)
            recordEvent("ride_reference_state")
        }
        refreshStatus()
    }

    func endRide(reason: String) {
        stopCollection(reason: reason)
        sessionID = nil
        lastError = nil
        if isEnabled {
            prepareManager(requestPermission: false)
        }
        refreshStatus()
    }

    func refreshStatus() {
        guard isEnabled else {
            statusText = "GPS tracing off"
            return
        }
        if authorizationName == "denied" || authorizationName == "restricted" {
            statusText = "GPS trace unavailable · allow Location in Settings"
        } else if authorizationName == "not_determined" {
            statusText = "GPS trace needs location permission"
        } else if let lastError {
            statusText = lastError
        } else if sessionID == nil {
            statusText = "GPS trace ready · records during a ride"
        } else if let lastSample, let age = lastSample.ageSeconds,
                  ProcessInfo.processInfo.systemUptime - lastSample.receivedUptime < 5,
                  age >= -1, age <= 3, let accuracy = lastSample.horizontalAccuracy, accuracy >= 0 {
            if lastSample.reducedAccuracy || accuracy > 25 {
                statusText = "GPS trace · low accuracy ±\(Int(min(accuracy, 99999))) m"
            } else {
                statusText = "GPS trace · receiving ±\(Int(accuracy)) m"
            }
        } else {
            statusText = "GPS trace · waiting for a fresh fix"
        }
    }

    private var authorizationName: String {
        guard let manager else {
            return "not_determined"
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "always"
        case .authorizedWhenInUse:
            return "when_in_use"
        @unknown default:
            return "unknown"
        }
    }

    private var accuracyName: String {
        guard let manager else {
            return "unavailable"
        }
        if manager.accuracyAuthorization == .fullAccuracy {
            return "full"
        }
        return "reduced"
    }

    private func prepareManager(requestPermission: Bool) {
        guard isEnabled else {
            return
        }
        if manager == nil {
            let manager = makeLocationManager()
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
            manager.activityType = .automotiveNavigation
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = false
            self.manager = manager
            manager.delegate = self
        }
        guard let manager else {
            return
        }
        if manager.authorizationStatus == .notDetermined {
            if requestPermission {
                manager.requestWhenInUseAuthorization()
            }
        } else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if sessionID != nil, capture == nil {
                capture = GPSReferenceCapture(startTimestamp: Date().timeIntervalSince1970,
                                              startUptime: ProcessInfo.processInfo.systemUptime)
                recordEvent("started")
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            }
        }
        refreshStatus()
    }

    private func stopCollection(reason: String) {
        if capture != nil {
            recordEvent("stopped", extraDetails: ["reason": reason])
        }
        manager?.stopUpdatingLocation()
        manager?.allowsBackgroundLocationUpdates = false
        manager?.delegate = nil
        manager = nil
        capture = nil
        lastSample = nil
    }

    private func recordEvent(_ event: String, extraDetails: [String: String] = [:], metrics: [String: Double] = [:]) {
        guard let sessionID else {
            return
        }
        var details = extraDetails
        details["authorization"] = authorizationName
        details["accuracyAuthorization"] = accuracyName
        details["traceID"] = capture?.id.uuidString
        var values = metrics
        values["capturedUptime"] = ProcessInfo.processInfo.systemUptime
        values["capturedTimestamp"] = Date().timeIntervalSince1970
        values["recordedFixes"] = Double(capture?.recordedCount ?? 0)
        values["throttledFixes"] = Double(capture?.throttledCount ?? 0)
        values["lastFixReceivedUptime"] = lastSample?.receivedUptime
        values["lastFixTimestamp"] = lastSample?.timestamp
        onRecord?(DriveEntry(kind: "gps-trace-event", event: event, metrics: values, details: details), sessionID)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager, isEnabled else {
            return
        }
        lastError = nil
        recordEvent("authorization_changed")
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            if capture != nil {
                recordEvent("stopped", extraDetails: ["reason": "authorization_unavailable"])
            }
            manager.stopUpdatingLocation()
            capture = nil
            lastSample = nil
        } else {
            prepareManager(requestPermission: false)
        }
        refreshStatus()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, isEnabled, let sessionID, capture != nil,
              let location = locations.max(by: { first, second in
                  return first.timestamp < second.timestamp
              }) else {
            return
        }
        let sample = GPSReferenceSample(timestamp: location.timestamp.timeIntervalSince1970,
                                        receivedTimestamp: Date().timeIntervalSince1970,
                                        receivedUptime: ProcessInfo.processInfo.systemUptime,
                                        coordinate: Coordinate(latitude: location.coordinate.latitude,
                                                               longitude: location.coordinate.longitude),
                                        altitude: location.altitude, horizontalAccuracy: location.horizontalAccuracy,
                                        verticalAccuracy: location.verticalAccuracy, speed: location.speed,
                                        speedAccuracy: location.speedAccuracy, course: location.course,
                                        courseAccuracy: location.courseAccuracy,
                                        reducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy,
                                        simulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware ?? false,
                                        producedByAccessory: location.sourceInformation?.isProducedByAccessory ?? false,
                                        batchSize: locations.count)
        guard let recorded = capture?.record(sample), let traceID = capture?.id else {
            return
        }
        if let lastSample, recorded.receivedUptime - lastSample.receivedUptime > 3 {
            recordEvent("fix_gap", metrics: ["receiptGapSeconds": recorded.receivedUptime - lastSample.receivedUptime])
        }
        lastSample = recorded
        referenceCount += 1
        lastError = nil
        onRecord?(DriveEntry(kind: "gps-reference", gpsReference: recorded,
                            details: ["traceID": traceID.uuidString]), sessionID)
        refreshStatus()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager, isEnabled else {
            return
        }
        let nsError = error as NSError
        lastError = "GPS trace unavailable · \(error.localizedDescription)"
        recordEvent("location_error", extraDetails: ["domain": nsError.domain, "message": error.localizedDescription],
                    metrics: ["code": Double(nsError.code)])
        refreshStatus()
    }
}
