import XCTest
@testable import GPSLessCore

final class CameraStopTests: XCTestCase {
    private func engine() throws -> TrackingEngine {
        let points = [Vector2(0, 0), Vector2(0, 2000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight", kind: "residential", points: points)
        let dataset = RoadDataset(generated: "camera-test", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])
        let engine = TrackingEngine(graph: try RoadGraph(data: JSONEncoder().encode(dataset)))
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        return engine
    }

    func testCameraHoldsTwentyFiveSecondStopDespiteBiasAndAllowsDepartureWithExactReplay() throws {
        let live = try engine()
        let replay = try engine()
        for tick in 0...1000 {
            let time = Double(tick) * 0.05
            var acceleration = 0.12
            if time <= 5 {
                acceleration = 1
            } else if time <= 10 {
                acceleration = 0
            } else if time <= 15 {
                acceleration = -0.7
            } else if time > 45 {
                acceleration = 0.4
            }
            let sample = MotionSample(time: time, forwardAcceleration: acceleration)
            _ = live.process(sample)
            _ = DriveEntry(kind: "sample", sample: sample).applyMotion(to: replay)
            if time >= 17, tick.isMultiple(of: 4) {
                var speed = 0.05
                if time > 45 {
                    speed = 1.2
                }
                var diagnostic = VisualSpeedDiagnostic(time: time, previousTime: time - 0.2,
                    region: [0.1, 0.4, 0.8, 0.4], cameraHeightMetres: 1.2, focalPixels: [520, 520],
                    candidateCount: 60, inlierCount: 50, medianTexture: 0.5, visualSpeed: speed,
                    uncertainty: 1.2, quality: 0.8, accepted: true, reason: "accepted_road_plane_motion")
                let result = live.applyVisualSpeed(try XCTUnwrap(diagnostic.observation))
                diagnostic.accepted = result.accepted
                diagnostic.reason = result.reason
                let entry = DriveEntry(kind: "visual-speed", visualSpeed: diagnostic)
                let decoded = try JSONDecoder().decode(DriveEntry.self, from: JSONEncoder().encode(entry))
                _ = decoded.applyMotion(to: replay)
            }
            XCTAssertEqual(live.estimate?.speed, replay.estimate?.speed)
            XCTAssertEqual(live.estimate?.position, replay.estimate?.position)
            if time >= 21 && time <= 45 {
                XCTAssertTrue(live.diagnostic(at: time).confirmedStopped)
                XCTAssertEqual(live.estimate?.speed, 0)
            }
        }
        let correction = try XCTUnwrap(live.lastStopCorrection)
        XCTAssertEqual(correction.source, "camera")
        XCTAssertLessThanOrEqual(correction.rewindMetres, 5)
        XCTAssertFalse(live.diagnostic(at: 50).confirmedStopped)
        XCTAssertGreaterThan(try XCTUnwrap(live.estimate).speed, 1)
    }

    func testSingleThenMissingCameraFrameCannotConfirmAStop() throws {
        let engine = try engine()
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time <= 5 {
                acceleration = 1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            if tick == 200 {
                _ = engine.applyVisualSpeed(VisualSpeedObservation(time: time, speed: 0, uncertainty: 1.2, quality: 0.8))
            }
            if time > 6 {
                XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
            }
        }
        XCTAssertNil(engine.lastStopCorrection)
        XCTAssertGreaterThan(try XCTUnwrap(engine.estimate).speed, 3)
    }

    func testCameraMovementVetoesAnInertialStopAndDuplicateFramesAreRejected() throws {
        let engine = try engine()
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time <= 5 {
                acceleration = 1
            } else if time > 10 && time <= 15 {
                acceleration = -0.9
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            if time >= 14, tick.isMultiple(of: 4) {
                let observation = VisualSpeedObservation(time: time, speed: 2, uncertainty: 1.2, quality: 0.8)
                XCTAssertTrue(engine.applyVisualSpeed(observation).accepted)
                let duplicate = engine.applyVisualSpeed(observation)
                XCTAssertFalse(duplicate.accepted)
                XCTAssertEqual(duplicate.reason, "out_of_order_visual_observation")
            }
            if time > 15 {
                XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
                XCTAssertEqual(engine.diagnostic(at: time).stopEvidence?.visualMovementDetected, true)
            }
        }
        XCTAssertNil(engine.lastStopCorrection)
    }
}
