import XCTest
@testable import GPSLessCore

final class RouteAlternativesAndSearchTests: XCTestCase {
    override func tearDown() {
        MapProjection.current = .kyiv
        super.tearDown()
    }

    private var offlineData: URL {
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GPSLess/OfflineData")
    }

    /// Three parallel roads between A and B: a long primary (fastest), a
    /// straight tertiary (shortest) and a secondary detour, all within 50%.
    func testAlternativesOfferFastestShortestAndDistinctRoutes() throws {
        func record(_ id: Int, _ from: Int64, _ to: Int64, _ kind: String, _ points: [Vector2]) -> RoadRecord {
            return RoadRecord(id: id, way: Int64(id), from: from, to: to, name: kind, kind: kind, points: points.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        let records = [
            record(0, 1, 2, "primary", [Vector2(0, 0), Vector2(0, 100)]),
            record(1, 2, 3, "primary", [Vector2(0, 100), Vector2(-600, 1100), Vector2(0, 2100)]),
            record(2, 2, 3, "secondary", [Vector2(0, 100), Vector2(700, 1100), Vector2(0, 2100)]),
            record(3, 2, 3, "tertiary", [Vector2(0, 100), Vector2(0, 2100)]),
            record(4, 3, 4, "primary", [Vector2(0, 2100), Vector2(0, 2300)])
        ]
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "test", bounds: [50, 30, 51, 31], roads: records, restrictions: [])))
        let options = RoutePlanner.alternatives(graph: graph, start: RoadPosition(edge: 0, distance: 10),
                                                destination: RoadPosition(edge: 4, distance: 150))
        XCTAssertEqual(options.count, 3)
        guard options.count == 3 else {
            return
        }
        XCTAssertEqual(options[0].label, "Fastest")
        XCTAssertEqual(options[0].route.edges, [0, 1, 4])
        XCTAssertEqual(options[1].label, "Shortest")
        XCTAssertEqual(options[1].route.edges, [0, 3, 4])
        XCTAssertEqual(options[2].route.edges, [0, 2, 4])
        for option in options {
            XCTAssertTrue(option.route.isValid(in: graph))
            XCTAssertLessThanOrEqual(option.seconds, options[0].seconds * 1.5)
        }
        XCTAssertLessThan(options[1].metres, options[0].metres)
        XCTAssertLessThan(options[0].seconds, options[1].seconds)
    }

    func testSlavskeRoutesIncludeTheBeskydPassAlternative() throws {
        let graph = try RoadGraph(data: Data(contentsOf: offlineData.appendingPathComponent("lviv-graph.json")))
        var start = try XCTUnwrap(graph.nearest(Coordinate(latitude: 48.8586, longitude: 23.4637), maximumDistance: 150))
        let volovets = try XCTUnwrap(graph.nearest(Coordinate(latitude: 48.7111, longitude: 23.1872), maximumDistance: 300))
        var options = RoutePlanner.alternatives(graph: graph, start: start, destination: volovets)
        if options.isEmpty, let reversed = graph.reverse(start) {
            start = reversed
            options = RoutePlanner.alternatives(graph: graph, start: start, destination: volovets)
        }
        XCTAssertGreaterThanOrEqual(options.count, 2)
        let shortest = try XCTUnwrap(options.min { first, second in
            return first.metres < second.metres
        })
        XCTAssertLessThan(shortest.metres, 36_000)
        XCTAssertTrue(options.allSatisfy { option in
            return option.route.isValid(in: graph)
        })
    }

    func testSearchFindsVillagesAndStreetsInUkrainianAndLatin() throws {
        let lviv = try PlaceSearch(data: Data(contentsOf: offlineData.appendingPathComponent("lviv-search.json")))
        let slavske = Coordinate(latitude: 48.8586, longitude: 23.4637)
        XCTAssertEqual(lviv.search("Slavske", near: slavske).first?.entry.name, "Славсько")
        XCTAssertEqual(lviv.search("славсько", near: slavske).first?.entry.name, "Славсько")
        XCTAssertEqual(lviv.search("tukholka", near: slavske).first?.entry.name, "Тухолька")
        let street = try XCTUnwrap(lviv.search("шевченка славсько", near: slavske).first)
        XCTAssertEqual(street.entry.kind, "street")
        XCTAssertEqual(street.entry.context, "Славсько")
        XCTAssertLessThan(try XCTUnwrap(street.distanceMetres), 5000)
        XCTAssertTrue(lviv.search("zzzzqqq").isEmpty)
        let kyiv = try PlaceSearch(data: Data(contentsOf: offlineData.appendingPathComponent("kyiv-search.json")))
        XCTAssertTrue(kyiv.search("khreshchatyk").contains { result in
            return result.entry.name == "вулиця Хрещатик"
        })
    }
}
