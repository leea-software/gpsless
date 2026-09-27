import Foundation

/// Route offsets and positions without walking the route edge by edge. A
/// 660 km route has thousands of edges, and the engine looks the route up
/// every 5 m when it starts; walking took 91 s on a Mac for such a route.
final class RouteIndex: Sendable {
    let route: SelectedRoute
    let length: Double
    /// Route offset at the start of each route edge; the route starts at 0.
    private let edgeStarts: [Int: Double]
    private let starts: [Double]
    private let ends: [Double]

    init(route: SelectedRoute, graph: RoadGraph) {
        var offset = -route.start.distance
        var edgeStarts: [Int: Double] = [:]
        var starts: [Double] = []
        var ends: [Double] = []
        for edge in route.edges {
            edgeStarts[edge] = edgeStarts[edge] ?? offset
            starts.append(offset)
            offset += graph.edges[edge].length
            ends.append(offset)
        }
        self.route = route
        self.edgeStarts = edgeStarts
        self.starts = starts
        self.ends = ends
        length = route.distance(in: graph)
    }

    /// Same result as `SelectedRoute.offset(of:graph:)`.
    func offset(of position: RoadPosition) -> Double? {
        return edgeStarts[position.edge].map { start in
            return start + position.distance
        }
    }

    /// Same result as `SelectedRoute.position(at:graph:)`: the first route
    /// edge whose end is at or beyond the offset.
    func position(at offset: Double) -> RoadPosition? {
        guard offset >= 0, offset <= length, !ends.isEmpty else {
            return nil
        }
        var low = 0
        var high = ends.count - 1
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] >= offset {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return RoadPosition(edge: route.edges[low], distance: offset - starts[low])
    }
}
