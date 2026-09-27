import XCTest
import simd
@testable import GPSLessCore

final class VisualSpeedTests: XCTestCase {
    private let width = 640
    private let height = 480
    private let focal = 520.0
    private let cameraHeight = 1.2

    private var mountedRotation: simd_quatd {
        let matrix = simd_double3x3(columns: (
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 0, 1),
            SIMD3<Double>(0, -1, 0)
        ))
        return simd_quatd(matrix)
    }

    func testKnownScaleSteadySpeed() throws {
        let diagnostic = diagnostic(speed: 10)
        XCTAssertTrue(diagnostic.accepted, diagnostic.reason)
        XCTAssertEqual(try XCTUnwrap(diagnostic.visualSpeed), 10, accuracy: 0.15)
    }

    func testAccelerationAndBrakingPairsFollowKnownScale() throws {
        let accelerating = diagnostic(speed: 4)
        let cruising = diagnostic(speed: 13)
        let braking = diagnostic(speed: 7)
        XCTAssertEqual(try XCTUnwrap(accelerating.visualSpeed), 4, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(cruising.visualSpeed), 13, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(braking.visualSpeed), 7, accuracy: 0.15)
    }

    func testPureRotationDoesNotManufactureTranslation() throws {
        let currentRotation = simd_quatd(angle: 0.08, axis: SIMD3<Double>(0, 0, 1)) * mountedRotation
        let diagnostic = diagnostic(speed: 0, currentRotation: currentRotation)
        XCTAssertTrue(diagnostic.accepted, diagnostic.reason)
        XCTAssertEqual(try XCTUnwrap(diagnostic.visualSpeed), 0, accuracy: 0.15)
    }

    func testIncorrectHeightProducesVisibleScaleError() throws {
        let diagnostic = diagnostic(speed: 10, configuredHeight: 1.5)
        XCTAssertTrue(diagnostic.accepted, diagnostic.reason)
        XCTAssertEqual(try XCTUnwrap(diagnostic.visualSpeed), 12.5, accuracy: 0.2)
        XCTAssertEqual(diagnostic.cameraHeightMetres, 1.5)
    }

    func testFieldObservedAttitudeDisagreementRejectsConfidentWrongScale() throws {
        let disagreement = 3.6 * Double.pi / 180
        let unguardedInput = frames(speed: 10, reportedPitchBias: -disagreement,
                                    attitudeDisagreement: 0)
        let unguarded = RoadPlaneVisualSpeedEstimator.estimate(previous: unguardedInput.previous,
                                                                current: unguardedInput.current,
                                                                tracks: unguardedInput.tracks,
                                                                cameraHeightMetres: cameraHeight,
                                                                region: [0.08, 0.38, 0.84, 0.5])
        XCTAssertTrue(unguarded.accepted, unguarded.reason)
        XCTAssertLessThan(try XCTUnwrap(unguarded.visualSpeed), 4)

        let guardedInput = frames(speed: 10, reportedPitchBias: -disagreement,
                                  attitudeDisagreement: disagreement)
        let guarded = RoadPlaneVisualSpeedEstimator.estimate(previous: guardedInput.previous,
                                                              current: guardedInput.current,
                                                              tracks: guardedInput.tracks,
                                                              cameraHeightMetres: cameraHeight,
                                                              region: [0.08, 0.38, 0.84, 0.5])
        XCTAssertFalse(guarded.accepted)
        XCTAssertEqual(guarded.reason, "attitude_reference_disagreement")
        XCTAssertEqual(try XCTUnwrap(guarded.attitudeDisagreementDegrees), 3.6, accuracy: 0.01)
    }

    func testModerateAttitudeDisagreementEnlargesScaleUncertainty() throws {
        let disagreement = 1 * Double.pi / 180
        let baseline = diagnostic(speed: 10)
        let input = frames(speed: 10, attitudeDisagreement: disagreement)
        let diagnostic = RoadPlaneVisualSpeedEstimator.estimate(previous: input.previous,
                                                                 current: input.current,
                                                                 tracks: input.tracks,
                                                                 cameraHeightMetres: cameraHeight,
                                                                 region: [0.08, 0.38, 0.84, 0.5])
        XCTAssertTrue(diagnostic.accepted, diagnostic.reason)
        XCTAssertGreaterThan(try XCTUnwrap(diagnostic.uncertainty), try XCTUnwrap(baseline.uncertainty))
        XCTAssertEqual(try XCTUnwrap(diagnostic.attitudeDisagreementDegrees), 1, accuracy: 0.01)
    }

    func testCameraUsesLiveGravityCalibrationAndRejectsStaleDiagnostics() throws {
        let processor = VehicleMotionProcessor()
        var cameraPose: CameraMotionPose?
        for index in 0...4400 {
            let time = Double(index) * 0.01
            let gravityTilt = clamp((time - 4) * 3.6 / 35, 0, 3.6) * Double.pi / 180
            let gravity = SIMD3<Double>(0, -cos(gravityTilt), -sin(gravityTilt))
            let raw = RawMotion(time: time, acceleration: [0, -1 - gravity.y, -gravity.z], rotation: [0, 0, 0],
                                gravity: [gravity.x, gravity.y, gravity.z], quaternion: components(mountedRotation))
            _ = processor.receive(raw)
            cameraPose = CameraMotionPose(raw: raw, processing: processor.diagnostic)
            if time < 4 {
                XCTAssertNil(cameraPose?.attitudeDisagreementRadians)
            }
        }
        XCTAssertEqual(try XCTUnwrap(cameraPose?.attitudeDisagreementRadians) * 180 / .pi, 3.6, accuracy: 0.05)
        let later = RawMotion(time: 45, acceleration: [0, 0, 0], rotation: [0, 0, 0],
                              gravity: [0, -1, 0], quaternion: components(mountedRotation))
        XCTAssertNil(CameraMotionPose(raw: later, processing: processor.diagnostic).attitudeDisagreementRadians)
    }

    func testLowTextureIsRejected() {
        let diagnostic = diagnostic(speed: 10, texture: 0.02)
        XCTAssertFalse(diagnostic.accepted)
        XCTAssertEqual(diagnostic.reason, "insufficient_road_features")
    }

    func testMovingObjectContaminationIsRejected() {
        var input = frames(speed: 10)
        for index in input.tracks.indices where index < 20 {
            var direction = -1.0
            if index.isMultiple(of: 2) {
                direction = 1.0
            }
            let track = input.tracks[index]
            input.tracks[index] = TrackedImageMotion(x: track.x, y: track.y,
                                                     deltaX: track.deltaX + 40 * direction,
                                                     deltaY: track.deltaY - 25 * direction,
                                                     texture: track.texture,
                                                     luminance: track.luminance)
        }
        let diagnostic = RoadPlaneVisualSpeedEstimator.estimate(previous: input.previous,
                                                                 current: input.current,
                                                                 tracks: input.tracks,
                                                                 cameraHeightMetres: cameraHeight,
                                                                 region: [0.08, 0.38, 0.84, 0.5])
        XCTAssertFalse(diagnostic.accepted)
        XCTAssertTrue(["inconsistent_or_moving_features", "poor_tracking_quality"].contains(diagnostic.reason))
    }

    func testVisualFusionIsBoundedAndDoesNotMovePositionImmediately() throws {
        let engine = TrackingEngine(graph: try straightGraph())
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        for tick in 0...200 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time <= 5 {
                acceleration = 1.0
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let positionBefore = try XCTUnwrap(engine.estimate).position.distance
        let result = engine.applyVisualSpeed(VisualSpeedObservation(time: 10, speed: 10,
                                                                     uncertainty: 1.2, quality: 0.9))
        XCTAssertTrue(result.accepted)
        XCTAssertGreaterThan(result.after, result.before)
        XCTAssertLessThanOrEqual(result.after - result.before, 1.5)
        XCTAssertEqual(engine.estimate?.position.distance, positionBefore)
    }

    func testStaleVisualFusionIsRejectedWithoutChangingSpeed() throws {
        let engine = TrackingEngine(graph: try straightGraph())
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 0))
        _ = engine.process(MotionSample(time: 1.1, forwardAcceleration: 0))
        let result = engine.applyVisualSpeed(VisualSpeedObservation(time: 5, speed: 20,
                                                                     uncertainty: 1.2, quality: 0.9))
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "stale_visual_observation")
        XCTAssertEqual(result.after, result.before)
    }

    private func diagnostic(speed: Double, configuredHeight: Double? = nil,
                            currentRotation: simd_quatd? = nil,
                            texture: Double = 0.5) -> VisualSpeedDiagnostic {
        let input = frames(speed: speed, currentRotation: currentRotation, texture: texture)
        return RoadPlaneVisualSpeedEstimator.estimate(previous: input.previous,
                                                      current: input.current,
                                                      tracks: input.tracks,
                                                      cameraHeightMetres: configuredHeight ?? cameraHeight,
                                                      region: [0.08, 0.38, 0.84, 0.5])
    }

    private func frames(speed: Double, currentRotation: simd_quatd? = nil,
                        texture: Double = 0.5, reportedPitchBias: Double = 0,
                        attitudeDisagreement: Double = 0) -> (previous: CameraFrameGeometry,
                                                   current: CameraFrameGeometry,
                                                   tracks: [TrackedImageMotion]) {
        let dt = 0.2
        let firstRotation = mountedRotation
        let secondRotation = currentRotation ?? mountedRotation
        let pitchBias = simd_quatd(angle: reportedPitchBias, axis: SIMD3<Double>(1, 0, 0))
        let firstReportedRotation = pitchBias * firstRotation
        let secondReportedRotation = pitchBias * secondRotation
        let firstPose = CameraMotionPose(time: 10, quaternion: components(firstReportedRotation), angularRate: 0,
                                         attitudeDisagreementRadians: attitudeDisagreement)
        let secondPose = CameraMotionPose(time: 10 + dt, quaternion: components(secondReportedRotation), angularRate: 0,
                                          attitudeDisagreementRadians: attitudeDisagreement)
        let previous = geometry(time: 10, pose: firstPose)
        let current = geometry(time: 10 + dt, pose: secondPose)
        var tracks: [TrackedImageMotion] = []
        for row in 0..<6 {
            for column in 0..<6 {
                let point = SIMD3<Double>(Double(column - 3) * 0.8,
                                          8 + Double(row) * 3,
                                          0)
                let first = project(point: point, cameraPosition: SIMD3<Double>(0, 0, cameraHeight),
                                    rotation: firstRotation)
                let second = project(point: point,
                                     cameraPosition: SIMD3<Double>(0, speed * dt, cameraHeight),
                                     rotation: secondRotation)
                tracks.append(TrackedImageMotion(x: first.x, y: first.y,
                                                 deltaX: second.x - first.x,
                                                 deltaY: second.y - first.y,
                                                 texture: texture, luminance: 0.45))
            }
        }
        return (previous, current, tracks)
    }


    private func geometry(time: Double, pose: CameraMotionPose) -> CameraFrameGeometry {
        return CameraFrameGeometry(time: time, width: width, height: height,
                                   focalX: focal, focalY: focal,
                                   principalX: Double(width) / 2,
                                   principalY: Double(height) / 2,
                                   pose: pose)
    }

    private func project(point: SIMD3<Double>, cameraPosition: SIMD3<Double>,
                         rotation: simd_quatd) -> SIMD2<Double> {
        let referenceRay = simd_normalize(point - cameraPosition)
        let deviceRay = rotation.inverse.act(referenceRay)
        let x = Double(width) / 2 + focal * deviceRay.x / -deviceRay.z
        let y = Double(height) / 2 + focal * deviceRay.y / deviceRay.z
        return SIMD2<Double>(x, y)
    }

    private func components(_ rotation: simd_quatd) -> [Double] {
        return [rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real]
    }

    private func straightGraph() throws -> RoadGraph {
        let points = [Vector2(0, 0), Vector2(0, 2000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight",
                              kind: "residential", points: points)
        let dataset = RoadDataset(generated: "visual-test", bounds: [50, 30, 51, 31],
                                  roads: [road], restrictions: [])
        return try RoadGraph(data: JSONEncoder().encode(dataset))
    }
}
