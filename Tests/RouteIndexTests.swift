import XCTest
@testable import GPSLessCore

/// The index must answer exactly as walking the route does.
final class RouteIndexTests: XCTestCase {
    override func tearDown() {
        MapProjection.current = .kyiv
        super.tearDown()
    }

    func testIndexMatchesRouteWalk() throws {
        let segments: [(Int64, Int64, [Vector2])] = [
            (1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            (2, 3, [Vector2(0, 200), Vector2(150, 260), Vector2(300, 200)]),
            (3, 4, [Vector2(300, 200), Vector2(300, 520)]),
            (4, 5, [Vector2(300, 520), Vector2(90, 700)])
        ]
        let records = segments.enumerated().map { index, segment in
            return RoadRecord(id: index, way: Int64(index), from: segment.0, to: segment.1, name: "Index test",
                              kind: "residential", points: segment.2.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "index-test", bounds: [50, 30, 51, 31],
                                                                         roads: records, restrictions: [])))
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: RoadPosition(edge: 0, distance: 37),
                                                     destination: RoadPosition(edge: 3, distance: 120)))
        let index = RouteIndex(route: route, graph: graph)
        XCTAssertEqual(index.length, route.distance(in: graph), accuracy: 1e-9)
        for offset in stride(from: -10.0, through: index.length + 10, by: 3.7) {
            let indexed = index.position(at: offset)
            let walked = route.position(at: offset, graph: graph)
            XCTAssertEqual(indexed?.edge, walked?.edge, "offset \(offset)")
            if let indexed, let walked {
                XCTAssertEqual(indexed.distance, walked.distance, accuracy: 1e-6)
            }
        }
        for edge in route.edges {
            for distance in stride(from: 0.0, through: graph.edges[edge].length, by: 11) {
                let position = RoadPosition(edge: edge, distance: distance)
                XCTAssertEqual(try XCTUnwrap(index.offset(of: position)),
                               try XCTUnwrap(route.offset(of: position, graph: graph)), accuracy: 1e-9)
            }
        }
        XCTAssertNil(index.offset(of: RoadPosition(edge: 99, distance: 0)))
    }
}
