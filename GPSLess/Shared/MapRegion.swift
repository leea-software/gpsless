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
    static let all = [kyiv, lviv] + local

    /// Corridor maps built locally by tools/build_corridor.py for a particular
    /// journey. They are never in Git; each sits in OfflineData with an
    /// `<id>-region.json` describing it.
    static let local: [MapRegion] = {
        struct Manifest: Decodable {
            let id: String
            let name: String
            let summary: String
            let center: [Double]
            let zoom: Double
            let testingStart: [Double]
        }
        guard let folder = Bundle.main.url(forResource: "OfflineData", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { url in
            return url.lastPathComponent.hasSuffix("-region.json")
        }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.center.count == 2, manifest.testingStart.count == 2 else {
                return nil
            }
            return MapRegion(id: manifest.id, name: manifest.name, summary: manifest.summary,
                             center: Coordinate(latitude: manifest.center[0], longitude: manifest.center[1]),
                             zoom: manifest.zoom,
                             testingStart: Coordinate(latitude: manifest.testingStart[0], longitude: manifest.testingStart[1]))
        }.sorted { first, second in
            return first.name < second.name
        }
    }()

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
