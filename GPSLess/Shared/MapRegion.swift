import Foundation

/// An offline map bundled with the app. Only one region is loaded at a time:
/// its road graph also sets the measuring plane for all road geometry.
struct MapRegion: Identifiable, Equatable {
    /// File prefix in OfflineData and the recording name prefix.
    let id: String
    let name: String
    let summary: String
    let center: Coordinate
    let zoom: Double
    /// Starting road for UI tests that begin with a selection.
    let testingStart: Coordinate

    static let kyiv = MapRegion(id: "kyiv", name: "Kyiv", summary: "Kyiv city",
                                center: Coordinate(latitude: 50.4501, longitude: 30.5234), zoom: 13.5,
                                testingStart: Coordinate(latitude: 50.44907055, longitude: 30.52382345))
    static let lviv = MapRegion(id: "lviv", name: "Lviv region",
                                summary: "Lviv Oblast; tracks and the Zakarpattia side around Slavske",
                                center: Coordinate(latitude: 49.8440, longitude: 24.0263), zoom: 13,
                                testingStart: Coordinate(latitude: 49.8440, longitude: 24.0263))
    static let all = [kyiv, lviv]

    static func named(_ id: String?) -> MapRegion {
        return all.first { region in
            return region.id == id
        } ?? .kyiv
    }

    private func resource(_ suffix: String) -> URL? {
        return Bundle.main.url(forResource: "\(id)-\(suffix)", withExtension: nil, subdirectory: "OfflineData")
    }

    var graphURL: URL? {
        return resource("graph.json")
    }

    var roadsURL: URL? {
        return resource("roads.geojson")
    }

    var areasURL: URL? {
        return resource("areas.geojson")
    }

    var searchURL: URL? {
        return resource("search.json")
    }

    var poisURL: URL? {
        return resource("pois.geojson")
    }
}
