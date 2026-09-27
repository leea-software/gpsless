import Foundation

public struct RoadRecord: Codable, Sendable {
    public var id: Int
    public var way: Int64
    public var from: Int64
    public var to: Int64
    public var name: String
    public var kind: String
    public var points: [[Double]]
}

public struct TurnRestriction: Codable, Sendable {
    public var via: Int64
    public var from: Int64
    public var to: Int64
    public var only: Bool
}

public struct RoadDataset: Codable, Sendable {
    public var generated: String
    public var bounds: [Double]
    public var roads: [RoadRecord]
    public var restrictions: [TurnRestriction]
    /// Absent for the Kyiv snapshot, which predates regions.
    public var region: String? = nil
    public var projection: MapProjection? = nil
}

public struct RoadPosition: Codable, Equatable, Sendable {
    public var edge: Int
    public var distance: Double

    public init(edge: Int, distance: Double) {
        self.edge = edge
        self.distance = distance
    }
}

public struct RoadEdge: Sendable {
    public var record: RoadRecord
    public var points: [Vector2]
    public var cumulative: [Double]

    public var length: Double {
        return cumulative.last ?? 0
    }

    public init(record: RoadRecord) {
        self.record = record
        points = record.points.map { point in
            return Coordinate(latitude: point[1], longitude: point[0]).metres
        }
        cumulative = [0]
        for index in 1..<points.count {
            cumulative.append(cumulative[index - 1] + (points[index] - points[index - 1]).length)
        }
    }

    public func point(at distance: Double) -> Vector2 {
        let distance = clamp(distance, 0, length)
        var lower = 0
        var upper = points.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if cumulative[middle] <= distance {
                lower = middle
            } else {
                upper = middle
            }
        }
        let fraction = (distance - cumulative[lower]) / max(0.001, cumulative[upper] - cumulative[lower])
        return points[lower] + (points[upper] - points[lower]) * fraction
    }

    public func heading(at distance: Double, span: Double = 10) -> Double {
        let center = clamp(distance, 0, length)
        let lower = max(0, center - span / 2)
        let upper = min(length, center + span / 2)
        return bearing(point(at: upper) - point(at: lower))
    }

    public func project(_ point: Vector2) -> (distance: Double, error: Double) {
        var best = (distance: 0.0, error: Double.infinity)
        for index in 1..<points.count {
            let vector = points[index] - points[index - 1]
            let fraction = clamp((point - points[index - 1]).dot(vector) / max(0.001, vector.dot(vector)), 0, 1)
            let projected = points[index - 1] + vector * fraction
            let error = (point - projected).length
            if error < best.error {
                best = (cumulative[index - 1] + vector.length * fraction, error)
            }
        }
        return best
    }
}

public final class RoadGraph: Sendable {
    public let dataset: RoadDataset
    public let edges: [RoadEdge]
    public let outgoing: [Int64: [Int]]
    let paths: [RoadPath]
    let pathIndex: [Int]
    let pathOffset: [Double]
    private let legalSuccessors: [[Int]]
    private let grid: [String: [Int]]
    private let restrictions: [Int64: [TurnRestriction]]

    public init(data: Data) throws {
        dataset = try JSONDecoder().decode(RoadDataset.self, from: data)
        if let projection = dataset.projection {
            guard projection.kind == "equirectangular" || projection.kind == "stereographic",
                  projection.latitude.isFinite, abs(projection.latitude) < 85,
                  projection.longitude.isFinite, abs(projection.longitude) <= 180 else {
                throw NSError(domain: "RoadGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported map projection"])
            }
        }
        // Every coordinate conversion below and during tracking uses this plane.
        MapProjection.current = dataset.projection ?? .kyiv
        guard dataset.bounds.count == 4, !dataset.roads.isEmpty else {
            throw NSError(domain: "RoadGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid road dataset"])
        }
        for record in dataset.roads {
            guard record.points.count >= 2 else {
                throw NSError(domain: "RoadGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "Road has no geometry"])
            }
            for point in record.points {
                guard point.count == 2, point[0].isFinite, point[1].isFinite,
                      abs(point[0]) <= 180, abs(point[1]) <= 90 else {
                    throw NSError(domain: "RoadGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid road coordinate"])
                }
            }
        }
        edges = dataset.roads.map { record in
            return RoadEdge(record: record)
        }
        var outgoing: [Int64: [Int]] = [:]
        var grid: [String: [Int]] = [:]
        var restrictions: [Int64: [TurnRestriction]] = [:]
        for (index, edge) in edges.enumerated() {
            guard edge.points.count >= 2, edge.record.id == index, edge.length > 0 else {
                throw NSError(domain: "RoadGraph", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid road geometry"])
            }
            outgoing[edge.record.from, default: []].append(index)
            var cells = Set<String>()
            for segment in 1..<edge.points.count {
                let first = edge.points[segment - 1]
                let second = edge.points[segment]
                for x in Int(floor(min(first.x, second.x) / 200))...Int(floor(max(first.x, second.x) / 200)) {
                    for y in Int(floor(min(first.y, second.y) / 200))...Int(floor(max(first.y, second.y) / 200)) {
                        cells.insert("\(x),\(y)")
                    }
                }
            }
            for cell in cells {
                grid[cell, default: []].append(index)
            }
        }
        for restriction in dataset.restrictions {
            restrictions[restriction.via, default: []].append(restriction)
        }
        self.outgoing = outgoing
        self.grid = grid
        self.restrictions = restrictions
        var legal: [[Int]] = []
        for index in edges.indices {
            legal.append(Self.successors(of: index, edges: edges, outgoing: outgoing, restrictions: restrictions))
        }
        legalSuccessors = legal
        let continuous = RoadPath.build(edges: edges, successors: legalSuccessors)
        paths = continuous.paths
        pathIndex = continuous.pathIndex
        pathOffset = continuous.pathOffset
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        let bounds = dataset.bounds
        return coordinate.latitude >= bounds[0] && coordinate.longitude >= bounds[1] && coordinate.latitude <= bounds[2] && coordinate.longitude <= bounds[3]
    }

    public func coordinate(_ position: RoadPosition) -> Coordinate {
        return Coordinate(metres: edges[position.edge].point(at: position.distance))
    }

    public func nearest(_ coordinate: Coordinate, maximumDistance: Double = 70) -> RoadPosition? {
        guard contains(coordinate) else {
            return nil
        }
        let point = coordinate.metres
        let radius = Int(ceil(maximumDistance / 200))
        let cellX = Int(floor(point.x / 200))
        let cellY = Int(floor(point.y / 200))
        var candidates = Set<Int>()
        for x in (cellX - radius)...(cellX + radius) {
            for y in (cellY - radius)...(cellY + radius) {
                candidates.formUnion(grid["\(x),\(y)"] ?? [])
            }
        }
        var best: RoadPosition?
        var error = maximumDistance
        for index in candidates.sorted() {
            let projection = edges[index].project(point)
            let proposed = RoadPosition(edge: index, distance: projection.distance)
            if projection.error < error && contains(self.coordinate(proposed)) {
                best = proposed
                error = projection.error
            }
        }
        return best
    }

    public func reverse(_ position: RoadPosition) -> RoadPosition? {
        let edge = edges[position.edge]
        for index in outgoing[edge.record.to] ?? [] {
            let other = edges[index]
            if other.record.way == edge.record.way && other.record.to == edge.record.from && abs(other.length - edge.length) < 0.1 {
                return RoadPosition(edge: index, distance: edge.length - position.distance)
            }
        }
        return nil
    }

    public func successors(of index: Int) -> [Int] {
        return legalSuccessors[index]
    }

    private static func successors(of index: Int, edges: [RoadEdge], outgoing: [Int64: [Int]], restrictions: [Int64: [TurnRestriction]]) -> [Int] {
        let edge = edges[index]
        var result: [Int] = []
        for candidate in outgoing[edge.record.to] ?? [] {
            let next = edges[candidate]
            if next.record.to == edge.record.from && next.record.way == edge.record.way {
                continue
            }
            var allowed = true
            for restriction in restrictions[edge.record.to] ?? [] {
                if restriction.from != edge.record.way {
                    continue
                }
                if restriction.only && restriction.to != next.record.way {
                    allowed = false
                }
                if !restriction.only && restriction.to == next.record.way {
                    allowed = false
                }
            }
            if allowed {
                result.append(candidate)
            }
        }
        return result
    }

    public func hasConflictingOnlyRestrictions(of index: Int) -> Bool {
        let edge = edges[index]
        var requiredWays = Set<Int64>()
        for restriction in restrictions[edge.record.to] ?? [] {
            if restriction.from == edge.record.way && restriction.only {
                requiredWays.insert(restriction.to)
            }
        }
        return requiredWays.count > 1
    }

    /// Drag on the selected physical road or directly connected junctions only.
    public func drag(_ position: RoadPosition, toward coordinate: Coordinate) -> RoadPosition {
        let edge = edges[position.edge]
        var candidates = [position.edge]
        if position.distance < 35 {
            candidates.append(contentsOf: outgoing[edge.record.from] ?? [])
        }
        if edge.length - position.distance < 35 {
            candidates.append(contentsOf: outgoing[edge.record.to] ?? [])
        }
        var best = position
        var bestError = Double.infinity
        for index in candidates {
            let projection = edges[index].project(coordinate.metres)
            if projection.error < bestError {
                let proposed = RoadPosition(edge: index, distance: projection.distance)
                if contains(self.coordinate(proposed)) && (self.coordinate(proposed).metres - self.coordinate(position).metres).length <= 80 {
                    best = proposed
                    bestError = projection.error
                }
            }
        }
        return best
    }
}
