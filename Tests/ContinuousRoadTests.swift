import XCTest
@testable import GPSLessCore

final class ContinuousRoadTests: XCTestCase {
    private func graph(_ paths: [(Int64, Int64, [Vector2])], restrictions: [TurnRestriction] = []) throws -> RoadGraph {
        let records = paths.enumerated().map { index, path in
            return RoadRecord(id: index, way: Int64(index), from: path.0, to: path.1, name: "Test road", kind: "residential", points: path.2.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        let dataset = RoadDataset(generated: "test", bounds: [50.21, 30.23, 50.64, 30.83], roads: records, restrictions: restrictions)
        return try RoadGraph(data: JSONEncoder().encode(dataset))
    }

    func testContinuousPathCrossesWayIDsWithoutIncludingTurnOrParallelRoad() throws {
        let graph = try graph([
            (1, 2, [Vector2(0, 0), Vector2(0, 100)]),
            (2, 3, [Vector2(0, 100), Vector2(0, 200)]),
            (2, 4, [Vector2(0, 100), Vector2(100, 100)]),
            (5, 6, [Vector2(10, 0), Vector2(10, 200)])
        ])
        XCTAssertEqual(graph.pathIndex[0], graph.pathIndex[1])
        XCTAssertNotEqual(graph.pathIndex[0], graph.pathIndex[2])
        XCTAssertNotEqual(graph.pathIndex[0], graph.pathIndex[3])
        let position = graph.paths[graph.pathIndex[0]].position(at: 150)
        XCTAssertEqual(position.edge, 1)
        XCTAssertEqual(position.distance, 50, accuracy: 0.001)
    }

    func testIdealStraightMotionDoesNotAcquireLargeParticleMeanDrift() throws {
        let graph = try graph([(1, 2, [Vector2(0, 0), Vector2(0, 4000)])])
        for seed: UInt64 in [7829, 1, 42, 101] {
            let engine = TrackingEngine(graph: graph, seed: seed)
            engine.start(at: RoadPosition(edge: 0, distance: 100))
            for tick in 0...1600 {
                let time = Double(tick) * 0.05
                var acceleration = 0.0
                if time > 0 && time <= 10 {
                    acceleration = 1
                }
                _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            }
            let estimate = try XCTUnwrap(engine.estimate)
            let expectedDistance = 100 + 50 + (estimate.time - 10) * 10
            XCTAssertFalse(estimate.needsReset, "Seed \(seed): \(estimate.status)")
            XCTAssertEqual(estimate.coordinate.metres.y, expectedDistance, accuracy: 10, "Seed \(seed)")
            XCTAssertEqual(estimate.speed, 10, accuracy: 0.4, "Seed \(seed)")
            // Better numerical centering must not erase modeled sensor drift.
            XCTAssertGreaterThan(estimate.uncertainty, 100)
        }
    }

    func testAmbiguousForkAndProhibitedContinuationRemainSeparate() throws {
        let paths: [(Int64, Int64, [Vector2])] = [
            (1, 2, [Vector2(0, 0), Vector2(0, 100)]),
            (2, 3, [Vector2(0, 100), Vector2(0, 200)]),
            (2, 4, [Vector2(0, 100), Vector2(30, 200)])
        ]
        let fork = try graph(paths)
        XCTAssertNotEqual(fork.pathIndex[0], fork.pathIndex[1])
        XCTAssertNotEqual(fork.pathIndex[0], fork.pathIndex[2])
        let restricted = try graph(Array(paths.prefix(2)), restrictions: [TurnRestriction(via: 2, from: 0, to: 1, only: false)])
        XCTAssertTrue(restricted.successors(of: 0).isEmpty)
        XCTAssertNotEqual(restricted.pathIndex[0], restricted.pathIndex[1])
    }

    func testStraightRoadSegmentationDoesNotStallTheMarker() throws {
        var finalPositions: [Double] = []
        for segmentLength in [4000.0, 59.0] {
            var paths: [(Int64, Int64, [Vector2])] = []
            var start = 0.0
            while start < 4000 {
                var length = segmentLength
                if paths.isEmpty {
                    length = 200
                }
                let end = min(4000, start + length)
                let index = Int64(paths.count)
                paths.append((index, index + 1, [Vector2(0, start), Vector2(0, end)]))
                start = end
            }
            let engine = TrackingEngine(graph: try graph(paths))
            engine.start(at: RoadPosition(edge: 0, distance: 100))
            var estimates: [TrackingEstimate] = []
            for tick in 0...1600 {
                let time = Double(tick) * 0.05
                var acceleration = 0.0
                if time > 0 && time <= 10 {
                    acceleration = 1
                }
                let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
                XCTAssertFalse(estimate.needsReset, estimate.status)
                if estimate.time != estimates.last?.time {
                    estimates.append(estimate)
                }
            }
            for lower in 20...70 {
                let section = estimates.filter { estimate in
                    return estimate.time >= Double(lower) && estimate.time <= Double(lower + 10)
                }
                let first = try XCTUnwrap(section.first)
                let last = try XCTUnwrap(section.last)
                var speedDistance = 0.0
                for pair in zip(section, section.dropFirst()) {
                    speedDistance += (pair.0.speed + pair.1.speed) / 2 * (pair.1.time - pair.0.time)
                }
                let markerDistance = last.coordinate.metres.y - first.coordinate.metres.y
                XCTAssertEqual(markerDistance, speedDistance, accuracy: 3, "Segment length \(segmentLength), interval \(lower)s")
                XCTAssertGreaterThan(first.roadProbability, 0.99)
                XCTAssertTrue(first.alternatives.isEmpty)
            }
            finalPositions.append(try XCTUnwrap(estimates.last).coordinate.metres.y)
        }
        XCTAssertEqual(finalPositions[0], finalPositions[1], accuracy: 5)
    }

    func testPassingSideRoadsDoesNotPenalizeForwardProgress() throws {
        var paths: [(Int64, Int64, [Vector2])] = []
        for index in 0..<30 {
            let start = Double(index) * 60
            paths.append((Int64(index), Int64(index + 1), [Vector2(0, start), Vector2(0, start + 60)]))
            if index > 0 {
                paths.append((Int64(index), Int64(100 + index), [Vector2(0, start), Vector2(200, start)]))
            }
        }
        let engine = TrackingEngine(graph: try graph(paths))
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        var estimates: [TrackingEstimate] = []
        for tick in 0...1400 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 10 {
                acceleration = 1
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            if estimate.time != estimates.last?.time {
                estimates.append(estimate)
            }
        }
        let final = try XCTUnwrap(estimates.last)
        XCTAssertEqual(final.coordinate.metres.y, 20 + 50 + 60 * 10, accuracy: 20)
        XCTAssertEqual(final.speed, 10, accuracy: 0.7)
        XCTAssertEqual(final.coordinate.metres.x, 0, accuracy: 0.01)
        let section = estimates.filter { estimate in
            return estimate.time >= 40 && estimate.time <= 60
        }
        let first = try XCTUnwrap(section.first)
        let last = try XCTUnwrap(section.last)
        var speedDistance = 0.0
        for pair in zip(section, section.dropFirst()) {
            speedDistance += (pair.0.speed + pair.1.speed) / 2 * (pair.1.time - pair.0.time)
        }
        XCTAssertEqual(last.coordinate.metres.y - first.coordinate.metres.y, speedDistance, accuracy: 5)
    }
}
