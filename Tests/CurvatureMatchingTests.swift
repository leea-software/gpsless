import XCTest
@testable import GPSLessCore

final class CurvatureMatchingTests: XCTestCase {
    private func graph(points: [Vector2], segmentPoints: Int) throws -> RoadGraph {
        var roads: [RoadRecord] = []
        var start = 0
        while start < points.count - 1 {
            let end = min(points.count - 1, start + segmentPoints)
            let coordinates = points[start...end].map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            }
            let index = roads.count
            roads.append(RoadRecord(id: index, way: Int64(index), from: Int64(index), to: Int64(index + 1),
                                    name: "Profile", kind: "primary", points: coordinates))
            start = end
        }
        let dataset = RoadDataset(generated: "curvature-test", bounds: [50.21, 30.23, 50.64, 30.83], roads: roads, restrictions: [])
        return try RoadGraph(data: JSONEncoder().encode(dataset))
    }

    func testContinuousHeadingCrossesShortEdgesWithoutDependingOnSegmentation() throws {
        let radius = 1500.0
        let points = (0...400).map { index in
            let angle = Double(index) / radius
            return Vector2(radius * (1 - cos(angle)), radius * sin(angle))
        }
        let short = try graph(points: points, segmentPoints: 10)
        let whole = try graph(points: points, segmentPoints: 400)
        XCTAssertEqual(short.paths.count, 1)
        for distance in [20.0, 95.0, 100.0, 105.0, 250.0, 370.0] {
            let first = try XCTUnwrap(short.paths[0].heading(at: distance, span: 40, roads: short.edges))
            let second = try XCTUnwrap(whole.paths[0].heading(at: distance, span: 40, roads: whole.edges))
            XCTAssertEqual(first, second, accuracy: 1e-8)
            XCTAssertEqual(first, distance / radius, accuracy: 1e-5)
            let curvature = try XCTUnwrap(short.paths[0].curvature(at: distance, span: 16, roads: short.edges))
            XCTAssertEqual(curvature, 1 / radius, accuracy: 1e-8)
        }
        XCTAssertNil(short.paths[0].heading(at: 5, span: 40, roads: short.edges))
        XCTAssertNil(short.paths[0].heading(at: 395, span: 40, roads: short.edges))
    }

    func testStraightEdgeTransitionsDoNotProduceCurvatureEvidence() throws {
        let points = (0...2000).map { index in
            return Vector2(0, Double(index))
        }
        let engine = TrackingEngine(graph: try graph(points: points, segmentPoints: 10))
        engine.start(at: RoadPosition(edge: 4, distance: 0))
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 20 {
                acceleration = 1
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            XCTAssertNil(engine.lastRoadUpdate?.curvatureEvidence)
            XCTAssertEqual(estimate.anchorCount, 0)
        }
    }

    func testGentleSBendPreservesBothSignsAndRecordsItsEvidence() throws {
        var points = [Vector2(0, 0)]
        var headings = [0.0]
        var heading = 0.0
        for index in 1...2200 {
            let distance = Double(index) - 0.5
            var curvature = 0.0
            if distance >= 300 && distance < 600 {
                curvature = 0.0008 * sin(.pi * (distance - 300) / 300)
            } else if distance >= 600 && distance < 900 {
                curvature = -0.0008 * sin(.pi * (distance - 600) / 300)
            }
            heading += curvature
            points.append(points[index - 1] + Vector2(sin(heading), cos(heading)))
            headings.append(heading)
        }
        let engine = TrackingEngine(graph: try graph(points: points, segmentPoints: 10))
        engine.start(at: RoadPosition(edge: 4, distance: 0))
        var speed = 0.0
        var distance = 40.0
        var previousHeading = 0.0
        var previousUpdateTime = -Double.infinity
        var evidence: [CurvatureEvidence] = []
        var lastRecordedUpdate: RoadMatchUpdate?
        for tick in 0...1800 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 20 {
                acceleration = 1
            }
            let nextSpeed = speed + acceleration * 0.05
            distance += (speed + nextSpeed) * 0.05 / 2
            speed = nextSpeed
            let lower = Int(distance)
            let fraction = distance - Double(lower)
            let currentHeading = headings[lower] * (1 - fraction) + headings[lower + 1] * fraction
            let yaw = angleDifference(currentHeading, previousHeading) / 0.05
            previousHeading = currentHeading
            let sample = MotionSample(time: time, forwardAcceleration: acceleration,
                                      lateralAcceleration: yaw * speed, yawRate: yaw, pitch: 0.59)
            let estimate = try XCTUnwrap(engine.process(sample))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            if let update = engine.lastRoadUpdate, update.time > previousUpdateTime {
                previousUpdateTime = update.time
                if let observed = update.curvatureEvidence {
                    evidence.append(observed)
                    lastRecordedUpdate = update
                    XCTAssertGreaterThanOrEqual(observed.endTime - observed.startTime, 6)
                    XCTAssertGreaterThan(try XCTUnwrap(observed.laneToleranceDegrees), 0)
                    XCTAssertGreaterThan(observed.weightMultiplier, 0)
                    XCTAssertLessThanOrEqual(observed.weightMultiplier, 1)
                }
            }
        }
        XCTAssertGreaterThan(evidence.filter { item in
            return item.mappedDegrees > 0.1
        }.count, 2)
        XCTAssertGreaterThan(evidence.filter { item in
            return item.mappedDegrees < -0.1
        }.count, 2)
        XCTAssertEqual(engine.estimate?.anchorCount, 0)

        let update = try XCTUnwrap(lastRecordedUpdate)
        let entry = DriveEntry(kind: "road-update", roadMatch: update)
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: encoded)
        XCTAssertEqual(decoded.roadMatch?.curvatureEvidence?.mappedDegrees, update.curvatureEvidence?.mappedDegrees)
        XCTAssertEqual(decoded.roadMatch?.curvatureEvidence?.startPosition, update.curvatureEvidence?.startPosition)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var oldMatch = try XCTUnwrap(legacy["roadMatch"] as? [String: Any])
        oldMatch.removeValue(forKey: "curvatureEvidence")
        legacy["roadMatch"] = oldMatch
        let oldEntry = try JSONDecoder().decode(DriveEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldEntry.roadMatch?.curvatureEvidence)
    }

    func testLaneChangesKeepTheStraightRoadWithoutInventingTurnAnchors() throws {
        let points = (0...2500).map { index in
            return Vector2(0, Double(index))
        }
        let road = try graph(points: points, segmentPoints: 15)
        for (targetSpeed, laneDuration) in [(13.8, 3.0), (27.6, 3.0), (27.6, 8.0)] {
            let control = TrackingEngine(graph: road)
            let changingLanes = TrackingEngine(graph: road)
            control.start(at: RoadPosition(edge: 2, distance: 10))
            changingLanes.start(at: RoadPosition(edge: 2, distance: 10))
            var previousHeading = 0.0
            var maximumDifference = 0.0
            for tick in 0...1400 {
                let time = Double(tick) * 0.05
                let speed = targetSpeed * min(time / 20, 1)
                var acceleration = 0.0
                if time > 0 && time <= 20 {
                    acceleration = targetSpeed / 20
                }
                var lateralSpeed = 0.0
                var lateralAcceleration = 0.0
                for (start, width) in [(30.0, 3.5), (48.0, -3.5)] {
                    let phase = (time - start) / laneDuration
                    if phase > 0 && phase < 1 {
                        // Derivatives of the smooth lateral displacement
                        // width * (10 u^3 - 15 u^4 + 6 u^5).
                        lateralSpeed += width / laneDuration * (30 * pow(phase, 2) - 60 * pow(phase, 3) + 30 * pow(phase, 4))
                        lateralAcceleration += width / pow(laneDuration, 2) * (60 * phase - 180 * pow(phase, 2) + 120 * pow(phase, 3))
                    }
                }
                let heading = atan2(lateralSpeed, max(speed, 0.01))
                let yaw = angleDifference(heading, previousHeading) / 0.05
                previousHeading = heading
                let baseline = try XCTUnwrap(control.process(MotionSample(time: time, forwardAcceleration: acceleration)))
                let sample = MotionSample(time: time,
                                          forwardAcceleration: acceleration * cos(heading) + lateralAcceleration * sin(heading),
                                          lateralAcceleration: lateralAcceleration * cos(heading) - acceleration * sin(heading),
                                          yawRate: yaw)
                let estimate = try XCTUnwrap(changingLanes.process(sample))
                XCTAssertFalse(estimate.needsReset, estimate.status)
                XCTAssertEqual(estimate.anchorCount, 0)
                let difference = abs(estimate.coordinate.metres.y - baseline.coordinate.metres.y)
                maximumDifference = max(maximumDifference, difference)
            }
            XCTAssertLessThan(maximumDifference, 10, "Lane change distorted along-road position at \(targetSpeed) m/s over \(laneDuration) seconds")
        }
    }

    func testLateralSpeedCueRequiresAMappedBend() throws {
        let points = (0...1000).map { index in
            return Vector2(0, Double(index))
        }
        let road = try graph(points: points, segmentPoints: 15)
        let control = TrackingEngine(graph: road)
        let lateralSignal = TrackingEngine(graph: road)
        control.start(at: RoadPosition(edge: 2, distance: 10))
        lateralSignal.start(at: RoadPosition(edge: 2, distance: 10))
        for tick in 0...700 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 15 {
                acceleration = 1
            }
            var yaw = 0.0
            if time >= 20 && time < 21.5 {
                yaw = 0.1
            } else if time >= 21.5 && time < 23 {
                yaw = -0.1
            }
            let sample = MotionSample(time: time, forwardAcceleration: acceleration, yawRate: yaw)
            var disturbed = sample
            // The ratio would imply 30 m/s. Without a mapped bend it must
            // supply no speed evidence, regardless of its numerical value.
            disturbed.lateralAcceleration = yaw * 30
            let expected = try XCTUnwrap(control.process(sample))
            let actual = try XCTUnwrap(lateralSignal.process(disturbed))
            XCTAssertFalse(actual.needsReset, actual.status)
            XCTAssertEqual(actual.position, expected.position)
            XCTAssertEqual(actual.speed, expected.speed)
            XCTAssertNil(lateralSignal.lastRoadUpdate?.curvatureEvidence)
            XCTAssertEqual(actual.anchorCount, 0)
        }
    }

    func testLaneChangeBesideAShallowExitReturnsToTheThroughRoad() throws {
        let layouts = [
            [Vector2(0, 0), Vector2(0, 300)],
            [Vector2(0, 300), Vector2(0, 2000)],
            [Vector2(0, 300), Vector2(1700 * sin(.pi / 12), 300 + 1700 * cos(.pi / 12))]
        ]
        var records: [RoadRecord] = []
        for (index, points) in layouts.enumerated() {
            let coordinates = points.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            }
            var from: Int64 = 1
            if index == 0 {
                from = 0
            }
            records.append(RoadRecord(id: index, way: Int64(index), from: from, to: Int64(index + 1),
                                      name: "Fork", kind: "primary", points: coordinates))
        }
        let dataset = RoadDataset(generated: "lane-fork", bounds: [50.21, 30.23, 50.64, 30.83], roads: records, restrictions: [])
        let engine = TrackingEngine(graph: try RoadGraph(data: JSONEncoder().encode(dataset)))
        engine.start(at: RoadPosition(edge: 0, distance: 40))
        var previousHeading = 0.0
        for tick in 0...1400 {
            let time = Double(tick) * 0.05
            let speed = min(time, 20) * 0.8
            var acceleration = 0.0
            if time > 0 && time <= 20 {
                acceleration = 0.8
            }
            let phase = (time - 24.5) / 3
            var lateralSpeed = 0.0
            var lateralAcceleration = 0.0
            if phase > 0 && phase < 1 {
                lateralSpeed = 3.5 / 3 * (30 * pow(phase, 2) - 60 * pow(phase, 3) + 30 * pow(phase, 4))
                lateralAcceleration = 3.5 / 9 * (60 * phase - 180 * pow(phase, 2) + 120 * pow(phase, 3))
            }
            let heading = atan2(lateralSpeed, max(speed, 0.01))
            let yaw = angleDifference(heading, previousHeading) / 0.05
            previousHeading = heading
            let sample = MotionSample(time: time,
                                      forwardAcceleration: acceleration * cos(heading) + lateralAcceleration * sin(heading),
                                      lateralAcceleration: lateralAcceleration * cos(heading) - acceleration * sin(heading),
                                      yawRate: yaw)
            let estimate = try XCTUnwrap(engine.process(sample))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            XCTAssertEqual(estimate.anchorCount, 0)
            if time > 40 {
                XCTAssertEqual(estimate.position.edge, 1)
            }
        }
    }
}
