import CoreLocation
import XCTest
@testable import GPSLess

private final class ReferenceLocationManager: CLLocationManager {
    var permission: CLAuthorizationStatus = .authorizedWhenInUse
    var precision: CLAccuracyAuthorization = .fullAccuracy
    var startCount = 0
    var stopCount = 0
    var permissionRequestCount = 0

    override var authorizationStatus: CLAuthorizationStatus {
        return permission
    }

    override var accuracyAuthorization: CLAccuracyAuthorization {
        return precision
    }

    override func startUpdatingLocation() {
        startCount += 1
    }

    override func stopUpdatingLocation() {
        stopCount += 1
    }

    override func requestWhenInUseAuthorization() {
        permissionRequestCount += 1
    }
}

final class GPSReferenceServiceTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "GPSReferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func location() -> CLLocation {
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: 50.45, longitude: 30.52),
                          altitude: 120, horizontalAccuracy: 5, verticalAccuracy: 8,
                          course: 90, courseAccuracy: 2, speed: 8, speedAccuracy: 0.4, timestamp: Date())
    }

    @MainActor
    func testOptInCapturesOnlyDuringRideAndRejectsPreviousManagerCallbacks() throws {
        let preferences = try defaults()
        var managers: [ReferenceLocationManager] = []
        let service = GPSReferenceService(defaults: preferences, makeLocationManager: {
            let manager = ReferenceLocationManager()
            managers.append(manager)
            return manager
        })
        var output: [(DriveEntry, UUID)] = []
        service.onRecord = { entry, sessionID in
            output.append((entry, sessionID))
        }
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(managers.isEmpty)
        service.isEnabled = true
        XCTAssertTrue(preferences.bool(forKey: "gpsReference.enabled"))
        let previewManager = try XCTUnwrap(managers.last)
        XCTAssertEqual(previewManager.startCount, 0)
        let firstRide = UUID()
        service.beginRide(sessionID: firstRide)
        let firstManager = try XCTUnwrap(managers.last)
        XCTAssertFalse(firstManager === previewManager)
        XCTAssertEqual(firstManager.startCount, 1)
        // A drive keeps running in the background, and so does its trace.
        XCTAssertTrue(firstManager.allowsBackgroundLocationUpdates)
        XCTAssertFalse(firstManager.pausesLocationUpdatesAutomatically)
        service.locationManager(firstManager, didUpdateLocations: [location()])
        let firstReference = try XCTUnwrap(output.last { item in
            return item.0.kind == "gps-reference"
        })
        XCTAssertEqual(firstReference.1, firstRide)
        XCTAssertEqual(firstReference.0.gpsReference?.speed, 8)
        service.endRide(reason: "pause")
        XCTAssertGreaterThan(firstManager.stopCount, 0)
        let countAfterPause = output.count
        service.locationManager(firstManager, didUpdateLocations: [location()])
        XCTAssertEqual(output.count, countAfterPause)
        let secondRide = UUID()
        service.beginRide(sessionID: secondRide)
        let secondManager = try XCTUnwrap(managers.last)
        let countBeforeOldCallback = output.count
        service.locationManager(firstManager, didUpdateLocations: [location()])
        XCTAssertEqual(output.count, countBeforeOldCallback)
        service.locationManager(secondManager, didUpdateLocations: [location()])
        XCTAssertEqual(output.last?.1, secondRide)
        XCTAssertEqual(output.last?.0.kind, "gps-reference")
        service.isEnabled = false
        let countAfterDisable = output.count
        service.locationManager(secondManager, didUpdateLocations: [location()])
        XCTAssertEqual(output.count, countAfterDisable)
        XCTAssertGreaterThan(secondManager.stopCount, 0)
        XCTAssertEqual(service.statusText, "GPS tracing off")
        service.endRide(reason: "finished")
    }

    @MainActor
    func testDeniedThenGrantedThenRevokedPermissionIsRecordedWithoutFabricatedFixes() throws {
        let preferences = try defaults()
        preferences.set(true, forKey: "gpsReference.enabled")
        var managers: [ReferenceLocationManager] = []
        let service = GPSReferenceService(defaults: preferences, makeLocationManager: {
            let manager = ReferenceLocationManager()
            manager.permission = .denied
            managers.append(manager)
            return manager
        })
        var output: [DriveEntry] = []
        service.onRecord = { entry, _ in
            output.append(entry)
        }
        service.beginRide(sessionID: UUID())
        let manager = try XCTUnwrap(managers.last)
        XCTAssertEqual(manager.startCount, 0)
        XCTAssertTrue(service.statusText.contains("allow Location in Settings"))
        service.locationManager(manager, didUpdateLocations: [location()])
        XCTAssertFalse(output.contains { entry in
            return entry.kind == "gps-reference"
        })
        manager.permission = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.startCount, 1)
        service.locationManager(manager, didUpdateLocations: [location()])
        XCTAssertEqual(output.last?.gpsReference?.speed, 8)
        manager.permission = .denied
        service.locationManagerDidChangeAuthorization(manager)
        let countAfterRevocation = output.count
        service.locationManager(manager, didUpdateLocations: [location()])
        XCTAssertEqual(output.count, countAfterRevocation)
        XCTAssertEqual(output.last?.details?["reason"], "authorization_unavailable")
        XCTAssertGreaterThan(manager.stopCount, 0)
        service.endRide(reason: "finished")
    }

    @MainActor
    func testPermissionPromptRequiresExplicitEnableAndErrorHasNoReferencePayload() throws {
        let preferences = try defaults()
        preferences.set(true, forKey: "gpsReference.enabled")
        var managers: [ReferenceLocationManager] = []
        let service = GPSReferenceService(defaults: preferences, makeLocationManager: {
            let manager = ReferenceLocationManager()
            manager.permission = .notDetermined
            managers.append(manager)
            return manager
        })
        XCTAssertEqual(managers[0].permissionRequestCount, 0)
        service.isEnabled = false
        service.isEnabled = true
        XCTAssertEqual(managers.last?.permissionRequestCount, 1)
        var output: [DriveEntry] = []
        service.onRecord = { entry, _ in
            output.append(entry)
        }
        service.beginRide(sessionID: UUID())
        let manager = try XCTUnwrap(managers.last)
        service.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.locationUnknown.rawValue))
        XCTAssertEqual(output.last?.kind, "gps-trace-event")
        XCTAssertEqual(output.last?.event, "location_error")
        XCTAssertNil(output.last?.gpsReference)
        service.endRide(reason: "finished")
    }
}
