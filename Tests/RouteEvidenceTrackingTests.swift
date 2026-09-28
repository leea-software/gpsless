import XCTest
@testable import GPSLessCore

/// Engine 3.1–3.2: turn sequences on curvy routes, heading profiles of long
/// bends, holding the estimate before a bend the car has not turned into, and
/// counting road-bump speed corrections.
final class RouteEvidenceTrackingTests: XCTestCase {
    override func tearDown() {
        MapProjection.current = .kyiv
        super.tearDown()
    }

    private func dataset(_ segments: [(Int64, Int64, [Vector2])]) throws -> RoadGraph {
        let records = segments.enumerated().map { index, segment in
            return RoadRecord(id: index, way: Int64(index), from: segment.0, to: segment.1,
                              name: "Evidence test", kind: "residential", points: segment.2.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        return try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "evidence-test", bounds: [50, 30, 51, 31],
                                                                    roads: records, restrictions: [])))
    }

    /// A zigzag of ±40° bends at uneven spacing, like a mountain road. The
    /// engine estimate starts 250 m ahead of the car, so the first turn fits a
    /// wrong bend better; the measured spacing of the next bends must still
    /// identify the right one and place the car within 15 m.
    func testTurnSequenceIdentifiesBendsDespiteMisleadingEstimate() throws {
        let spacing = [150.0, 120, 200, 150, 260, 180, 150]
        var points = [Vector2(0, 0)]
        var heading = 0.0
        var vertices: [Double] = []
        var travelled = 0.0
        for (index, length) in spacing.enumerated() {
            let last = points[points.count - 1]
            points.append(last + Vector2(sin(heading), cos(heading)) * length)
            travelled += length
            if index < spacing.count - 1 {
                vertices.append(travelled)
                heading += (index.isMultiple(of: 2) ? 40 : -40) * .pi / 180
            }
        }
        let graph = try dataset([(1, 2, points)])
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 0),
                                  destination: RoadPosition(edge: 0, distance: travelled - 20), edges: [0])
        let matcher = RouteEvidenceMatcher(route: route, graph: graph)
        matcher.start(at: 0)
        func feature(near offset: Double) throws -> RouteFeature {
            return try XCTUnwrap(matcher.features.min { first, second in
                return abs(first.midpoint - offset) < abs(second.midpoint - offset)
            })
        }
        var decisions: [RouteEvidenceDecision] = []
        for (index, vertex) in vertices.prefix(4).enumerated() {
            let angle = (index.isMultiple(of: 2) ? 43.0 : -37.0) * .pi / 180
            let time = Double(index + 1) * 20
            let turn = TurnObservation(id: index + 1, start: time - 4, end: time - 1, startPosition: route.start,
                                       startMapHeading: 0, angle: angle, startUncertainty: 200)
            decisions.append(matcher.match(turn: turn, time: time, estimatedRouteOffset: vertex + 10 + 250,
                                           uncertainty: 200, estimatedSpeed: 10,
                                           odometer: (vertex + 10) * 1.02, distanceSinceMidpoint: 10))
        }
        let third = decisions[2]
        XCTAssertEqual(third.feature?.index, try feature(near: vertices[2]).index)
        XCTAssertEqual(try XCTUnwrap(third.anchorRouteOffset), vertices[2] + 10, accuracy: 15)
        let fourth = decisions[3]
        XCTAssertEqual(fourth.feature?.index, try feature(near: vertices[3]).index)
        XCTAssertEqual(try XCTUnwrap(fourth.anchorRouteOffset), vertices[3] + 10, accuracy: 15)
        // A few percent of far alternatives remain; 95% of the weight is close.
        XCTAssertLessThan(try XCTUnwrap(fourth.credibleRadius), 40)
    }

    /// A 100° sweeping bend drawn over 700 m, like the Lviv ring road. No
    /// single turn feature describes it, but its heading profile does: with
    /// the estimate 200 m past the bend the matched profile moves the car
    /// back to within 25 m, and the reported radius ignores the few percent
    /// of far-away fallback weight.
    func testSweepingBendProfileMovesEstimateBackToTheBend() throws {
        let bendStart = 1000.0
        let bendLength = 700.0
        let bendAngle = -100.0 * .pi / 180
        func heading(at offset: Double) -> Double {
            return bendAngle * clamp((offset - bendStart) / bendLength, 0, 1)
        }
        var points = [Vector2(0, 0)]
        var offset = 0.0
        while offset < 2500 {
            let step = offset >= bendStart && offset < bendStart + bendLength ? 25.0 : 250.0
            let direction = heading(at: offset + step / 2)
            points.append(points[points.count - 1] + Vector2(sin(direction), cos(direction)) * step)
            offset += step
        }
        let graph = try dataset([(1, 2, points)])
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 0),
                                  destination: RoadPosition(edge: 0, distance: 2400), edges: [0])
        let matcher = RouteEvidenceMatcher(route: route, graph: graph)
        matcher.start(at: 0)
        let now = bendStart + bendLength + 60
        let span = now - bendStart + 40
        let distances = stride(from: span, through: 0, by: -10).map { $0 }
        let profile = ObservedHeadingProfile(distances: distances, headings: distances.map { distance in
            return heading(at: now - distance) + 0.3
        }, sinceStart: now - bendStart, sinceMidpoint: now - bendStart - bendLength / 2, sinceEnd: now - bendStart - bendLength)
        let turn = TurnObservation(id: 1, start: 60, end: 100, startPosition: route.start,
                                   startMapHeading: 0, angle: bendAngle, startUncertainty: 150)
        let decision = matcher.match(turn: turn, time: 104, estimatedRouteOffset: now + 200, uncertainty: 300,
                                     estimatedSpeed: 17, profile: profile)
        XCTAssertNotNil(decision.feature, decision.reason)
        XCTAssertEqual(try XCTUnwrap(decision.anchorRouteOffset), now, accuracy: 25)
        XCTAssertLessThan(try XCTUnwrap(decision.credibleRadius), 80)
    }

    private func junctionRoute() throws -> (RoadGraph, SelectedRoute) {
        let graph = try dataset([
            (1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            (2, 3, [Vector2(0, 200), Vector2(300, 200)])
        ])
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 150),
                                                     destination: RoadPosition(edge: 1, distance: 280)))
        XCTAssertEqual(route.edges, [0, 1])
        return (graph, route)
    }

    /// Driving on without turning must not carry the estimate round a right
    /// angle 50 m ahead; once the gyro shows the turn it continues.
    func testEstimateWaitsAtBendUntilTheTurnIsMeasured() throws {
        let (graph, route) = try junctionRoute()
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        var offsetBeforeTurn = 0.0
        for tick in 0...900 {
            let time = Double(tick) * 0.05
            let acceleration = time < 5 ? 1.0 : 0
            var yaw = 0.0
            if time >= 30 && time < 34 {
                yaw = .pi / 8
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration,
                                            lateralAcceleration: yaw * 5, yawRate: yaw))
            if tick == 590, let estimate = engine.estimate {
                offsetBeforeTurn = try XCTUnwrap(route.offset(of: estimate.position, graph: graph))
            }
        }
        // 137 m driven by 29.5 s; the bend is 50 m ahead of the start.
        XCTAssertLessThanOrEqual(offsetBeforeTurn, 60)
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(final.needsReset, final.status)
        XCTAssertEqual(final.position.edge, 1)
        XCTAssertGreaterThan(try XCTUnwrap(route.offset(of: final.position, graph: graph)), 70)
    }

    func testRoadBumpSpeedCorrectionsAreCountedOncePerDisagreement() throws {
        let (graph, route) = try junctionRoute()
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        var time = 0.0
        func drive(until end: Double, measured: Double?) {
            while time < end {
                time += 0.05
                _ = engine.process(MotionSample(time: time, forwardAcceleration: time < 3 ? 1 : 0))
                if let measured, Int((time * 20).rounded()).isMultiple(of: 10) {
                    _ = engine.applyVibrationSpeed(VibrationSpeedObservation(time: time, speed: measured, uncertainty: 0.5,
                                                                             stoppedProbability: 0, accelerationBias: 0,
                                                                             echoStrength: 5, rollingLevel: nil,
                                                                             movingProbability: 1, wheelbase: 2.7))
                }
            }
        }
        drive(until: 4, measured: nil)
        XCTAssertEqual(engine.speedCorrectionCount, 0)
        // Inertial speed is about 3 m/s; the bumps say 6 m/s.
        drive(until: 8, measured: 6)
        XCTAssertEqual(engine.speedCorrectionCount, 1)
        let correction = try XCTUnwrap(engine.lastSpeedCorrection)
        XCTAssertEqual(correction.measured, 6)
        XCTAssertEqual(correction.before, 3, accuracy: 0.6)
        // Agreement after the correction does not count again.
        drive(until: 14, measured: 6)
        XCTAssertEqual(engine.speedCorrectionCount, 1)
    }
}
