import XCTest
@testable import GPSLessCore

final class VehicleMotionProjectionTests: XCTestCase {
    func testRestingMountedPhoneHasNoTranslation() throws {
        let sample = try XCTUnwrap(VehicleMotionProjection.sample(time: 10,
                                                                userAcceleration: .zero,
                                                                gravity: SIMD3(0, -1, 0),
                                                                rotationRate: .zero))
        XCTAssertEqual(sample.forwardAcceleration, 0)
        XCTAssertEqual(sample.lateralAcceleration, 0)
        XCTAssertEqual(sample.verticalAcceleration, 0)
        XCTAssertEqual(sample.yawRate, 0)
    }

    func testForwardDepartureAndBrakingHavePhysicalSigns() throws {
        // With the screen rearward, forward translation produces positive
        // device-z Core Motion user acceleration; braking produces negative z.
        let forward = try XCTUnwrap(VehicleMotionProjection.sample(time: 10,
                                                                 userAcceleration: SIMD3(0, 0, 0.1),
                                                                 gravity: SIMD3(0, -1, 0),
                                                                 rotationRate: .zero))
        let braking = try XCTUnwrap(VehicleMotionProjection.sample(time: 11,
                                                                 userAcceleration: SIMD3(0, 0, -0.1),
                                                                 gravity: SIMD3(0, -1, 0),
                                                                 rotationRate: .zero))
        XCTAssertEqual(forward.forwardAcceleration, 0.980665, accuracy: 1e-9)
        XCTAssertEqual(braking.forwardAcceleration, -0.980665, accuracy: 1e-9)
        XCTAssertEqual(forward.lateralAcceleration, 0)
        XCTAssertEqual(forward.verticalAcceleration, 0)
    }

    func testTurnAccelerationAndYawAgreeForBothDirections() throws {
        for direction in [-1.0, 1.0] {
            let sample = try XCTUnwrap(VehicleMotionProjection.sample(time: 10,
                                                                    userAcceleration: SIMD3(-0.2 * direction, 0, 0),
                                                                    gravity: SIMD3(0, -1, 0),
                                                                    rotationRate: SIMD3(0, -0.2 * direction, 0)))
            XCTAssertEqual(sample.lateralAcceleration, 1.96133 * direction, accuracy: 1e-9)
            XCTAssertEqual(sample.yawRate, 0.2 * direction, accuracy: 1e-9)
            XCTAssertEqual(sample.lateralAcceleration / sample.yawRate, 9.80665, accuracy: 1e-9)
            XCTAssertEqual(sample.forwardAcceleration, 0)
        }
    }

    func testBackwardTiltKeepsForwardMotionHorizontal() throws {
        // A 30-degree backward tilt: horizontal forward is (0, 0.5, -sqrt(3)/2).
        let cosine = sqrt(3) / 2
        let sample = try XCTUnwrap(VehicleMotionProjection.sample(time: 10,
                                                                userAcceleration: SIMD3(0, -0.05, 0.1 * cosine),
                                                                gravity: SIMD3(0, -cosine, -0.5),
                                                                rotationRate: SIMD3(0, -0.2 * cosine, -0.1)))
        XCTAssertEqual(sample.forwardAcceleration, 0.980665, accuracy: 1e-9)
        XCTAssertEqual(sample.lateralAcceleration, 0, accuracy: 1e-9)
        XCTAssertEqual(sample.verticalAcceleration, 0, accuracy: 1e-9)
        XCTAssertEqual(sample.yawRate, 0.2, accuracy: 1e-9)
        XCTAssertEqual(sample.pitch, .pi / 6, accuracy: 1e-9)
    }

    func testVerticalMotionDoesNotBecomeForwardAcceleration() throws {
        let sample = try XCTUnwrap(VehicleMotionProjection.sample(time: 10,
                                                                userAcceleration: SIMD3(0, -0.1, 0),
                                                                gravity: SIMD3(0, -1, 0),
                                                                rotationRate: .zero))
        XCTAssertEqual(sample.verticalAcceleration, 0.980665, accuracy: 1e-9)
        XCTAssertEqual(sample.forwardAcceleration, 0)
        XCTAssertEqual(sample.lateralAcceleration, 0)
    }

    func testFlatPhoneCannotProduceVehicleSample() {
        XCTAssertNil(VehicleMotionProjection.sample(time: 10,
                                                   userAcceleration: .zero,
                                                   gravity: SIMD3(0, 0, -1),
                                                   rotationRate: .zero))
    }
}
