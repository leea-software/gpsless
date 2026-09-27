import XCTest
@testable import GPSLessCore

final class TurnLandmarkTests: XCTestCase {
    private func graph(_ paths: [(Int64, Int64, [Vector2])]) throws -> RoadGraph {
        let roads = paths.enumerated().map { index, path in
            return RoadRecord(id: index, way: Int64(index), from: path.0, to: path.1,
                              name: "Landmark test", kind: "residential", points: path.2.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        let dataset = RoadDataset(generated: "landmark-test", bounds: [50, 30, 51, 31], roads: roads, restrictions: [])
        return try RoadGraph(data: JSONEncoder().encode(dataset))
    }

    func testTurnTimingUsesAngularMidpointAndIntegratesChangingAcceleration() throws {
        var history = TurnMotionHistory()
        for tick in 1...160 {
            let time = Double(tick) * 0.05
            var yaw = 0.0
            if time > 2, time <= 6 {
                yaw = .pi / 8
            }
            history.append(MotionSample(time: time, forwardAcceleration: 0.4, yawRate: yaw), duration: 0.05)
        }
        let middle = try XCTUnwrap(history.midpoint(start: 2, end: 6, angle: .pi / 2))
        XCTAssertEqual(middle, 4, accuracy: 0.001)
        XCTAssertEqual(history.accelerationMoment(from: middle, to: 8), 3.2, accuracy: 0.001)
        XCTAssertNil(history.midpoint(start: -20, end: 6, angle: .pi / 2))
    }

    func testCompoundTurnCannotSupplyAnIsolatedLandmark() {
        var history = TurnMotionHistory()
        for tick in 1...160 {
            let time = Double(tick) * 0.05
            var yaw = -Double.pi / 4
            if time <= 4 {
                yaw = .pi * 3 / 8
            }
            history.append(MotionSample(time: time, forwardAcceleration: 0, yawRate: yaw), duration: 0.05)
        }
        XCTAssertNil(history.midpoint(start: 0, end: 8, angle: .pi / 2))
    }

    func testRepeatedMatchingJunctionsRemainAmbiguousAcrossDifferentExitPaths() throws {
        let graph = try graph([
            (1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            (2, 3, [Vector2(0, 200), Vector2(0, 400)]),
            (2, 4, [Vector2(0, 200), Vector2(300, 200)]),
            (3, 5, [Vector2(0, 400), Vector2(300, 400)])
        ])
        let matches = TurnLandmark.candidates(graph: graph, start: RoadPosition(edge: 0, distance: 180),
                                             endPath: graph.pathIndex[2], angle: .pi / 2, radius: 250)
        XCTAssertEqual(matches.count, 2)
        let narrow = TurnLandmark.candidates(graph: graph, start: RoadPosition(edge: 0, distance: 180),
                                            endPath: graph.pathIndex[2], angle: .pi / 2, radius: 80)
        let corner = try XCTUnwrap(narrow.first)
        XCTAssertEqual(narrow.count, 1)
        let before = try XCTUnwrap(corner.position(at: -10, graph: graph))
        XCTAssertEqual(before.edge, 0)
        XCTAssertEqual(before.distance, 190, accuracy: 0.001)
        XCTAssertEqual(corner.position(at: 10, graph: graph), RoadPosition(edge: 2, distance: 10))
    }

    func testConditioningUpdatesSpeedAndBiasTogetherAndRejectsOutliers() throws {
        var states: [LandmarkState] = []
        for index in -20...20 {
            let bias = Double(index) * 0.002
            states.append(LandmarkState(position: 550 - 0.5 * bias * 2500 - 500,
                                        speed: 12 - bias * 50, bias: bias, weight: 1 / 41))
        }
        let update = try XCTUnwrap(TurnLandmarkConditioning.apply(states: states, elapsed: 3,
                                                                 accelerationMoment: 0, sigma: 12))
        XCTAssertGreaterThan(update.change.z, 0.005)
        XCTAssertLessThan(update.change.y, -0.25)
        XCTAssertLessThan(update.change.x, -6)
        XCTAssertLessThan(update.variance.z, 0.02 * 0.02)
        let displaced = states.map { state in
            return LandmarkState(position: state.position + 1000, speed: state.speed, bias: state.bias, weight: state.weight)
        }
        XCTAssertNil(TurnLandmarkConditioning.apply(states: displaced, elapsed: 3, accelerationMoment: 0, sigma: 12))
    }

    func testLandmarkUncertaintyStillGrowsWithSpeedBiasAndElapsedMotion() {
        let uncertainty = LandmarkMotionUncertainty(positionVariance: 144, speedVariance: 0.25,
                                                    biasVariance: 0.0001, speedBiasCovariance: 0)
        XCTAssertEqual(uncertainty.radius(after: 0), 24)
        XCTAssertGreaterThan(uncertainty.radius(after: 60), 90)
        XCTAssertGreaterThan(uncertainty.radius(after: 300), 350)
    }

    func testDistanceBetweenLandmarksCanTeachBiasAfterMapAlreadyCorrectedPosition() throws {
        var states: [LandmarkState] = []
        for index in -20...20 {
            let bias = Double(index) * 0.002
            states.append(LandmarkState(position: 36, speed: 12 - bias * 50, bias: bias, weight: 1 / 41,
                                        integratedPosition: 50 - 0.5 * bias * 2500))
        }
        let update = try XCTUnwrap(TurnLandmarkConditioning.apply(states: states, elapsed: 3,
                                                                 accelerationMoment: 0, sigma: 17))
        XCTAssertEqual(update.change.x, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(update.change.z, 0.005)
        XCTAssertLessThan(update.change.y, -0.25)
    }

    func testRawPreintegrationRetainsDistanceDiscrepancyDespiteLaterMapCorrections() throws {
        var interval = LandmarkCalibrationInterval(path: 0, distance: 100, time: 0, sigma: 12,
                                                   velocityIntegral: 0, distanceIntegral: 0)
        for _ in 0..<1200 {
            interval.append(acceleration: 0.12, duration: 0.05)
        }
        // At 50 s, true unbiased acceleration 0.1 gives 625 m. The last 10 s
        // contributes raw delta-v 1.2 and weighted acceleration moment 6.
        let current = LandmarkState(position: 155, speed: 16, bias: 0.02, weight: 1)
        let hypotheses = interval.hypotheses(current: [current], time: 60, midpoint: 50, distance: 600,
                                             recentVelocity: 1.2, recentMoment: 6)
        let hypothesis = try XCTUnwrap(hypotheses.first)
        XCTAssertEqual(hypothesis.speed, 16, accuracy: 0.001)
        XCTAssertEqual(hypothesis.position, 155, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(hypothesis.integratedPosition), 25, accuracy: 0.001)
        XCTAssertEqual(interval.velocityIntegral, 7.2, accuracy: 0.001)
    }

    func testTimedJunctionCorrectionIsRecordedAndOlderUpdatesStillDecode() throws {
        let roads = try graph([
            (1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            (2, 3, [Vector2(0, 200), Vector2(1000, 200)])
        ])
        let engine = TrackingEngine(graph: roads)
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 10 {
                acceleration = 1
            }
            if time >= 14, time < 19 {
                yaw = .pi / 10
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration,
                                             lateralAcceleration: yaw * 10, yawRate: yaw))
        }
        XCTAssertFalse(try XCTUnwrap(engine.estimate).needsReset)
        let signal = try XCTUnwrap(engine.drainRoadSignals().first { event in
            return event.stage == "accepted" && event.roadMatch?.landmarkCorrection != nil
        })
        let update = try XCTUnwrap(signal.roadMatch)
        let correction = try XCTUnwrap(update.landmarkCorrection)
        XCTAssertEqual(correction.signalID, signal.signalID)
        XCTAssertEqual(correction.observationTime, 16.475, accuracy: 0.06)
        XCTAssertEqual(correction.incomingEdge, 0)
        XCTAssertEqual(correction.outgoingEdge, 1)
        XCTAssertGreaterThanOrEqual(correction.observationSigmaMetres, 12)
        let encoded = try JSONEncoder().encode(DriveEntry(kind: "road-update", roadMatch: update))
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: encoded)
        XCTAssertEqual(decoded.roadMatch?.landmarkCorrection?.signalID, correction.signalID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var match = try XCTUnwrap(object["roadMatch"] as? [String: Any])
        match.removeValue(forKey: "landmarkCorrection")
        object["roadMatch"] = match
        let legacy = try JSONDecoder().decode(DriveEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.roadMatch?.landmarkCorrection)
    }
}
