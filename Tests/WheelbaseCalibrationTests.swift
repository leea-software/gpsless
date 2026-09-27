import XCTest
@testable import GPSLessCore

final class WheelbaseCalibrationTests: XCTestCase {
    private func observation(time: Double, speed: Double, wheelbase: Double) -> VibrationSpeedObservation {
        return VibrationSpeedObservation(time: time, speed: speed, uncertainty: 0.3, stoppedProbability: 0, accelerationBias: 0,
                                         echoStrength: 5, rollingLevel: 2, movingProbability: 1, wheelbase: wheelbase)
    }

    /// A 2.70 m setting on a 2.82 m car reads every vibration speed 4% low;
    /// mapped spacing between matched turns recovers the physical wheelbase.
    func testMappedTurnSpacingRecoversWheelbase() {
        var calibrator = WheelbaseCalibrator()
        let trueSpeed = 12.0
        let reported = trueSpeed * 2.70 / 2.82
        var time = 0.0
        var nextTurn = 60.0
        var anchors = 0
        while time < 600 {
            calibrator.record(observation(time: time, speed: reported, wheelbase: 2.70))
            if time >= nextTurn {
                calibrator.anchor(time: nextTurn, routeOffset: trueSpeed * nextTurn, sigma: 5, now: time)
                anchors += 1
                nextTurn += 60
            }
            time += 0.5
        }
        XCTAssertEqual(anchors, 9)
        let evidence = calibrator.evidence
        XCTAssertEqual(evidence.intervals, 8)
        XCTAssertEqual(try XCTUnwrap(evidence.estimate), 2.82, accuracy: 0.005)
        XCTAssertTrue(evidence.isConfident)
        XCTAssertEqual(calibrator.scale(for: 2.70), 2.82 / 2.70, accuracy: 0.002)
        XCTAssertTrue(calibrator.drainEvents().allSatisfy { event in
            return event.stage == "accepted"
        })
    }

    func testInterruptedOrInconsistentIntervalsAreRejected() {
        var calibrator = WheelbaseCalibrator()
        for tick in 0...240 {
            let time = Double(tick) * 0.5
            // A ten-second gap in vibration speed between the two turns.
            if time > 40 && time < 50 {
                continue
            }
            calibrator.record(observation(time: time, speed: 10, wheelbase: 2.8))
        }
        calibrator.anchor(time: 10, routeOffset: 100, sigma: 5, now: 11)
        // Spans the gap: unusable whatever the distances.
        calibrator.anchor(time: 70, routeOffset: 700, sigma: 5, now: 71)
        // 900 m mapped against 400 m measured: a wrong match, not a wheelbase error.
        calibrator.anchor(time: 110, routeOffset: 1600, sigma: 5, now: 111)
        let events = calibrator.drainEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].reason, "Vibration speed was interrupted between the turns")
        XCTAssertEqual(events[1].reason, "Mapped and measured distances disagree beyond a wheelbase error")
        XCTAssertEqual(calibrator.evidence.intervals, 0)
        XCTAssertEqual(calibrator.scale(for: 2.8), 1)
    }

    /// Confident evidence from earlier drives corrects vibration speed at once;
    /// with refinement switched off the configured wheelbase is used unchanged.
    func testSeededEvidenceScalesVibrationSpeedUnlessDisabled() throws {
        let points = [Vector2(0, 0), Vector2(0, 3000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight", kind: "primary", points: points)
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "test", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])))
        var evidence = WheelbaseEvidence()
        evidence.add(metres: 2.94, relativeSigma: 0.01)
        evidence.add(metres: 2.94, relativeSigma: 0.01)
        for applies in [true, false] {
            let engine = TrackingEngine(graph: graph)
            engine.seedWheelbaseCalibration(evidence)
            engine.appliesWheelbaseCalibration = applies
            engine.start(at: RoadPosition(edge: 0, distance: 100))
            var time = 0.0
            for _ in 0..<100 {
                _ = engine.process(MotionSample(time: time, forwardAcceleration: 1))
                time += 0.05
            }
            for tick in 0..<600 {
                _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
                if tick.isMultiple(of: 10) {
                    _ = engine.applyVibrationSpeed(observation(time: time, speed: 7, wheelbase: 2.8))
                }
                time += 0.05
            }
            let speed = try XCTUnwrap(engine.estimate).speed
            XCTAssertEqual(speed, applies ? 7 * 2.94 / 2.8 : 7, accuracy: 0.3)
        }
    }
}
