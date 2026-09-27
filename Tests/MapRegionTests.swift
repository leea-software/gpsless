import XCTest
@testable import GPSLessCore

final class MapRegionTests: XCTestCase {
    override func tearDown() {
        // Test graphs are built in the Kyiv plane; later tests must not inherit another.
        MapProjection.current = .kyiv
        super.tearDown()
    }

    private func haversine(_ first: Coordinate, _ second: Coordinate) -> Double {
        let radius = 6_371_008.8
        let dLatitude = (second.latitude - first.latitude) * .pi / 180
        let dLongitude = (second.longitude - first.longitude) * .pi / 180
        let a = pow(sin(dLatitude / 2), 2) + cos(first.latitude * .pi / 180) * cos(second.latitude * .pi / 180) * pow(sin(dLongitude / 2), 2)
        return 2 * radius * asin(sqrt(a))
    }

    func testKyivPlaneIsUnchanged() {
        MapProjection.current = .kyiv
        let point = Coordinate(latitude: 50.5, longitude: 30.6).metres
        XCTAssertEqual(point.x, (30.6 - 30.52) * 111_320 * cos(50.45 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(point.y, (50.5 - 50.45) * 111_320, accuracy: 1e-9)
    }

    /// Across the Lviv region the conformal plane keeps local distances and
    /// headings true, where the Kyiv plane is about 3% short east-west.
    func testStereographicPlaneKeepsCarpathianDistancesTrue() {
        MapProjection.current = MapProjection(kind: "stereographic", latitude: 49.622, longitude: 24.0465)
        let pairs = [
            (Coordinate(latitude: 48.87, longitude: 23.40), Coordinate(latitude: 48.87, longitude: 23.42)),
            (Coordinate(latitude: 48.87, longitude: 23.40), Coordinate(latitude: 48.89, longitude: 23.40)),
            (Coordinate(latitude: 50.60, longitude: 25.30), Coordinate(latitude: 50.61, longitude: 25.32))
        ]
        for (first, second) in pairs {
            let planar = (second.metres - first.metres).length
            XCTAssertEqual(planar / haversine(first, second), 1, accuracy: 0.004)
        }
        let original = Coordinate(latitude: 48.9128, longitude: 23.4706)
        let restored = Coordinate(metres: original.metres)
        XCTAssertEqual(restored.latitude, original.latitude, accuracy: 1e-9)
        XCTAssertEqual(restored.longitude, original.longitude, accuracy: 1e-9)
        MapProjection.current = .kyiv
        let eastWest = (pairs[0].1.metres - pairs[0].0.metres).length / haversine(pairs[0].0, pairs[0].1)
        XCTAssertLessThan(eastWest, 0.975)
    }

    func testLvivGraphCoversSlavskeAndPlansAlongRoads() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GPSLess/OfflineData/lviv-graph.json")
        let graph = try RoadGraph(data: Data(contentsOf: url))
        XCTAssertEqual(graph.dataset.region, "lviv")
        XCTAssertEqual(MapProjection.current.kind, "stereographic")
        let slavske = Coordinate(latitude: 48.8586, longitude: 23.4637)  // fuel station on the main road
        let tukholka = Coordinate(latitude: 48.8806, longitude: 23.2855)
        let lvivCentre = Coordinate(latitude: 49.8440, longitude: 24.0263)  // prospekt Svobody; Rynok Square is pedestrian
        for place in [slavske, tukholka, lvivCentre] {
            XCTAssertTrue(graph.contains(place))
            let position = try XCTUnwrap(graph.nearest(place, maximumDistance: 150))
            XCTAssertLessThan((graph.coordinate(position).metres - place.metres).length, 150)
        }
        let start = try XCTUnwrap(graph.nearest(slavske, maximumDistance: 150))
        let destination = try XCTUnwrap(graph.nearest(tukholka, maximumDistance: 150))
        // The nearest Slavske edge may face into a dead-end service street;
        // drivers flip direction in that case, so the test does too.
        let route = try XCTUnwrap(SelectedRoute.plan(graph: graph, start: start, destination: destination)
            ?? graph.reverse(start).flatMap { reversed in
                return SelectedRoute.plan(graph: graph, start: reversed, destination: destination)
            })
        let planned = route.distance(in: graph)
        let coordinates = route.coordinates(in: graph)
        let geodesic = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { total, pair in
            return total + haversine(pair.0, pair.1)
        }
        XCTAssertEqual(planned / geodesic, 1, accuracy: 0.002)
        XCTAssertGreaterThan(planned, haversine(slavske, tukholka))
        XCTAssertLessThan(planned, 3 * haversine(slavske, tukholka))
    }
}
