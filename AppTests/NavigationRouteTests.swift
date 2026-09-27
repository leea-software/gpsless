import XCTest
@testable import GPSLess

final class NavigationRouteTests: XCTestCase {
    @MainActor
    private func readyStore() async throws -> NavigationStore {
        // These routes are in Kyiv; the region choice persists between runs.
        UserDefaults.standard.set(MapRegion.kyiv.id, forKey: "mapRegion")
        let store = NavigationStore()
        for _ in 0..<400 {
            if store.phase == .selecting && store.graph != nil {
                return store
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Offline graph did not load")
        return store
    }

    @MainActor
    func testLockSurvivesPauseAndBlocksAllSelectionChangesUntilReset() async throws {
        let store = try await readyStore()
        store.select(Coordinate(latitude: 50.44907055, longitude: 30.52382345))
        let start = try XCTUnwrap(store.selection)
        store.chooseDestination()
        store.select(Coordinate(latitude: 50.4501, longitude: 30.5234))
        for _ in 0..<400 {
            if !store.planningRoute {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let route = try XCTUnwrap(store.selectedRoute)
        store.lockRoute()
        store.select(Coordinate(latitude: 50.451, longitude: 30.521))
        store.drag(to: Coordinate(latitude: 50.450, longitude: 30.524))
        store.reverseDirection()
        store.chooseDestination()
        XCTAssertEqual(store.selection, start)
        XCTAssertEqual(store.selectedRoute, route)
        XCTAssertFalse(store.choosingDestination)
        store.pause()
        XCTAssertTrue(store.routeLocked)
        XCTAssertEqual(store.selectedRoute, route)
        store.setPositionAgain()
        XCTAssertFalse(store.routeLocked)
        XCTAssertNil(store.selectedRoute)
        store.chooseDestination()
        XCTAssertTrue(store.choosingDestination)
    }

    @MainActor
    func testResetDiscardsAnInFlightRoutePlan() async throws {
        let store = try await readyStore()
        store.select(Coordinate(latitude: 50.44907055, longitude: 30.52382345))
        store.chooseDestination()
        store.select(Coordinate(latitude: 50.4501, longitude: 30.5234))
        XCTAssertTrue(store.planningRoute)
        store.setPositionAgain()
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(store.selectedRoute)
        XCTAssertFalse(store.routeLocked)
        XCTAssertFalse(store.planningRoute)
    }
}
