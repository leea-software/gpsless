import XCTest
@testable import GPSLessCore

final class SelectedRouteTests: XCTestCase {
    private func graph(restrictions: [TurnRestriction] = []) throws -> RoadGraph {
        let segments: [(Int64, Int64, [Vector2])] = [
            (1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            (2, 3, [Vector2(0, 200), Vector2(0, 400)]),
            (2, 4, [Vector2(0, 200), Vector2(200, 200)]),
            (3, 5, [Vector2(0, 400), Vector2(200, 400)]),
            (4, 5, [Vector2(200, 200), Vector2(200, 400)]),
            (5, 6, [Vector2(200, 400), Vector2(400, 400)])
        ]
        var records = segments.enumerated().map { index, segment in
            return RoadRecord(id: index, way: Int64(index), from: segment.0, to: segment.1,
                              name: "Route test", kind: "residential", points: segment.2.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        records.append(RoadRecord(id: 6, way: 0, from: 2, to: 1, name: "Reverse", kind: "residential", points: records[0].points.reversed()))
        return try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "route-test", bounds: [50, 30, 51, 31], roads: records, restrictions: restrictions)))
    }

    func testPlannerRespectsRestrictionsAndPartialEdges() throws {
        let graph = try graph(restrictions: [TurnRestriction(via: 2, from: 0, to: 2, only: false)])
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 5, distance: 50)))
        XCTAssertEqual(route.edges, [0, 1, 3, 5])
        XCTAssertEqual(route.distance(in: graph), 550, accuracy: 0.001)
        XCTAssertEqual(route.coordinates(in: graph).first, graph.coordinate(route.start))
        XCTAssertEqual(route.coordinates(in: graph).last, graph.coordinate(route.destination))
        XCTAssertNil(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 5, distance: 10), destination: RoadPosition(edge: 0, distance: 20)))
        XCTAssertNil(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 0, distance: 20)))
    }

    func testRouteRejectsIllegalRecordedTransitionsAndRoundTrips() throws {
        let graph = try graph()
        let invalid = SelectedRoute(start: RoadPosition(edge: 0, distance: 20), destination: RoadPosition(edge: 5, distance: 100), edges: [0, 5])
        XCTAssertFalse(invalid.isValid(in: graph))
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 2, distance: 150)))
        let decoded = try JSONDecoder().decode(SelectedRoute.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(route, decoded)
        XCTAssertTrue(decoded.isValid(in: graph))
        XCTAssertNil(route.position(at: -1, graph: graph))
        XCTAssertNil(route.position(at: 251, graph: graph))
        XCTAssertEqual(try XCTUnwrap(route.offset(of: RoadPosition(edge: 2, distance: 20), graph: graph)), 120, accuracy: 0.001)
    }

    func testRouteDisambiguatesBendsUsingSelectedSequence() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 20), destination: RoadPosition(edge: 2, distance: 180)))
        let candidates = TurnLandmark.candidates(graph: graph, start: RoadPosition(edge: 0, distance: 180), endPath: graph.pathIndex[2], angle: .pi / 2, radius: 300)
        XCTAssertEqual(candidates.count, 2)
        let bends = RouteTurnLandmark.build(route: route, graph: graph)
        XCTAssertEqual(bends.count, 1)
        XCTAssertEqual(try XCTUnwrap(bends.first).midpoint, 180, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(bends.first).angle, .pi / 2, accuracy: 0.01)
    }

    func testMissingExpectedTurnDoesNotTrapEstimateBehindRouteFeature() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 150), destination: RoadPosition(edge: 2, distance: 180)))
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        var peakSpeed = 0.0
        for tick in 0...800 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 5 {
                acceleration = 1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            if let estimate = engine.estimate {
                XCTAssertTrue(route.edges.contains(estimate.position.edge))
                peakSpeed = max(peakSpeed, estimate.speed)
            }
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(final.needsReset, final.status)
        XCTAssertGreaterThan(try XCTUnwrap(route.offset(of: final.position, graph: graph)), 60)
        XCTAssertGreaterThan(peakSpeed, 4)
    }

    func testExpectedTurnReleasesGateAndRecordsJointCorrection() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 150), destination: RoadPosition(edge: 2, distance: 180)))
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        for tick in 0...700 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 5 {
                acceleration = 1
            }
            if time >= 20 && time < 25 {
                yaw = .pi / 10
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration,
                                            lateralAcceleration: yaw * 7, yawRate: yaw))
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(final.needsReset, final.status)
        XCTAssertNotEqual(final.status, "Waiting for expected route turn")
        let evidence = engine.drainRouteEvidenceEvents()
        XCTAssertTrue(evidence.contains { event in
            return event.stage == "accepted"
        })
        let corrections = engine.drainRoadSignals().compactMap { signal in
            if signal.stage == "accepted" {
                return signal.roadMatch?.landmarkCorrection
            }
            return nil
        }
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(try XCTUnwrap(corrections.first?.routeDistanceMetres), 50, accuracy: 5)
    }

    /// After a corner the car keeps yawing slightly while it settles in its
    /// lane, so the gyro declares the turn over tens of metres later. Route
    /// evidence must anchor the turn's angular midpoint, not that late end.
    func testRouteEvidenceAnchorsTurnMidpointDespiteLaneSettlingYaw() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 50), destination: RoadPosition(edge: 2, distance: 190)))
        XCTAssertEqual(route.edges, [0, 2])
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        func travelled(_ time: Double) -> Double {
            return time < 6 ? 0.5 * time * time : 18 + 6 * (time - 6)
        }
        var accepted: [RouteEvidenceEvent] = []
        for tick in 0...900 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 6 {
                acceleration = 1
            }
            var yaw = 0.0
            if time >= 26 && time < 30 {
                yaw = .pi / 8
            } else if time >= 30 && time < 38 {
                yaw = 0.035
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 6, yawRate: yaw))
            accepted += engine.drainRouteEvidenceEvents().filter { event in
                return event.stage == "accepted"
            }
        }
        let event = try XCTUnwrap(accepted.first)
        XCTAssertEqual(event.anchor, "midpoint")
        XCTAssertEqual(try XCTUnwrap(event.anchorRouteOffsetMetres), travelled(event.time), accuracy: 12)
        XCTAssertEqual(try XCTUnwrap(event.routeOffsetAfterMetres), travelled(event.time), accuracy: 15)
    }

    func testSmallSteeringEventDoesNotBecomeRouteWideEvidence() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 150), destination: RoadPosition(edge: 2, distance: 180)))
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        for tick in 0...700 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 5 {
                acceleration = 1
            }
            if time >= 20 && time < 22 {
                yaw = 10 * .pi / 180
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration,
                                            lateralAcceleration: yaw * 7, yawRate: yaw))
        }
        let evidence = engine.drainRouteEvidenceEvents()
        XCTAssertFalse(evidence.contains { event in
            return event.stage == "accepted"
        })
    }

    func testRouteMatcherUsesWholeSequenceAndStraightSpacing() throws {
        let graph = try graph()
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 5, distance: 180), edges: [0, 2, 4, 5])
        let matcher = RouteEvidenceMatcher(route: route, graph: graph)
        XCTAssertEqual(matcher.features.count, 3)
        matcher.start(at: 0)

        let first = TurnObservation(id: 1, start: 8, end: 12,
                                    startPosition: route.start, startMapHeading: 0,
                                    angle: 78 * .pi / 180, startUncertainty: 12)
        let firstDecision = matcher.match(turn: first, time: 13, estimatedRouteOffset: 70,
                                          uncertainty: 12, estimatedSpeed: 9)
        XCTAssertEqual(firstDecision.feature?.index, 0)

        let second = TurnObservation(id: 2, start: 32, end: 36,
                                     startPosition: route.start, startMapHeading: 0,
                                     angle: -88 * .pi / 180, startUncertainty: 80)
        let secondDecision = matcher.match(turn: second, time: 37, estimatedRouteOffset: 150,
                                           uncertainty: 80, estimatedSpeed: 7)
        XCTAssertEqual(secondDecision.feature?.index, 1)
        XCTAssertEqual(try XCTUnwrap(secondDecision.precedingStraightSeconds), 20, accuracy: 0.01)

        let third = TurnObservation(id: 3, start: 58, end: 62,
                                    startPosition: route.start, startMapHeading: 0,
                                    angle: 92 * .pi / 180, startUncertainty: 120)
        let thirdDecision = matcher.match(turn: third, time: 63, estimatedRouteOffset: 250,
                                          uncertainty: 120, estimatedSpeed: 5)
        XCTAssertEqual(thirdDecision.feature?.index, 2)
    }

    func testRouteMatcherIgnoresSmallSteeringWithoutAdvancingSequence() throws {
        let graph = try graph()
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 5, distance: 180), edges: [0, 2, 4, 5])
        let matcher = RouteEvidenceMatcher(route: route, graph: graph)
        matcher.start(at: 0)
        let steering = TurnObservation(id: 1, start: 5, end: 7,
                                       startPosition: route.start, startMapHeading: 0,
                                       angle: 25 * .pi / 180, startUncertainty: 10)
        let decision = matcher.match(turn: steering, time: 8, estimatedRouteOffset: 60,
                                     uncertainty: 10, estimatedSpeed: 8)
        XCTAssertNil(decision.feature)
    }

    func testDestinationEndsTrackingInsteadOfContinuingPastB() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 20), destination: RoadPosition(edge: 0, distance: 60)))
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        for tick in 0...500 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 5 {
                acceleration = 1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertEqual(final.failure?.reason, .routeEnded)
        XCTAssertLessThanOrEqual(final.position.distance, 60)
        XCTAssertTrue(final.needsReset)
    }

    func testUnplannedUTurnCannotReverseOntoAnEdgeOutsideLockedRoute() throws {
        let graph = try graph()
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 50), destination: RoadPosition(edge: 2, distance: 180)))
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        for tick in 0...440 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 5 {
                acceleration = 1
            }
            if time >= 7 && time < 12 {
                yaw = .pi / 5
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 5, yawRate: yaw))
            if let estimate = engine.estimate {
                XCTAssertNotEqual(estimate.position.edge, 6)
                XCTAssertTrue(route.edges.contains(estimate.position.edge))
            }
        }
        XCTAssertTrue(try XCTUnwrap(engine.estimate).needsReset)
    }

    func testRouteTurnsProduceJointCorrectionsAndDistanceCalibration() throws {
        let graph = try graph()
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 100), destination: RoadPosition(edge: 5, distance: 180), edges: [0, 2, 4, 5])
        let engine = TrackingEngine(graph: graph, route: route)
        engine.start(at: route.start)
        for tick in 0...1240 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 10 {
                acceleration = 1
            }
            if time >= 14 && time < 19 {
                yaw = .pi / 10
            } else if time >= 34 && time < 39 {
                yaw = -.pi / 10
            } else if time >= 54 && time < 59 {
                yaw = .pi / 10
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 10, yawRate: yaw))
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(final.needsReset, final.status)
        let corrections = engine.drainRoadSignals().compactMap { signal in
            return signal.roadMatch?.landmarkCorrection
        }
        XCTAssertGreaterThanOrEqual(corrections.count, 2)
        XCTAssertTrue(corrections.allSatisfy { correction in
            return correction.routeDistanceMetres != nil
        })
        let interval = try XCTUnwrap(corrections.first { correction in
            return correction.calibrationDistanceMetres != nil
        })
        XCTAssertEqual(try XCTUnwrap(interval.calibrationDistanceMetres), 200, accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(interval.calibrationDurationSeconds), 20, accuracy: 0.2)
        XCTAssertTrue(interval.speedChangeMetresPerSecond.isFinite)
        XCTAssertTrue(interval.biasChangeMetresPerSecondSquared.isFinite)
        let routeEvidence = engine.drainRouteEvidenceEvents().filter { event in
            return event.stage == "accepted"
        }
        XCTAssertGreaterThanOrEqual(routeEvidence.count, 2)
        XCTAssertTrue(routeEvidence.dropFirst().contains { event in
            return event.routeAverageSpeedMetresPerSecond != nil
                && event.speedBeforeMetresPerSecond != nil
                && event.speedAfterMetresPerSecond != nil
        })
    }

    func testSmoothBendInsideOneEdgeHasGeometryMidpointButUTurnDoesNot() throws {
        for angle in [Double.pi / 2, Double.pi] {
            var points = [Vector2(0, 0), Vector2(0, 100)]
            for step in 1...30 {
                let turn = angle * Double(step) / 30
                points.append(Vector2(20 * (1 - cos(turn)), 100 + 20 * sin(turn)))
            }
            let end = try XCTUnwrap(points.last)
            points.append(end + Vector2(sin(angle), cos(angle)) * 100)
            let record = RoadRecord(id: 0, way: 0, from: 1, to: 2, name: "Curved road", kind: "residential", points: points.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
            let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "bend", bounds: [50, 30, 51, 31], roads: [record], restrictions: [])))
            let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 0), destination: RoadPosition(edge: 0, distance: graph.edges[0].length), edges: [0])
            let bends = RouteTurnLandmark.build(route: route, graph: graph)
            if angle == .pi / 2 {
                XCTAssertEqual(bends.count, 1)
                XCTAssertEqual(try XCTUnwrap(bends.first).midpoint, 100 + .pi * 5, accuracy: 3)
            } else {
                XCTAssertTrue(bends.isEmpty)
            }
        }
    }
}
