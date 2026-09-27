import Foundation

/// One offered route between A and B, with an estimate from typical road speeds.
public struct RouteOption: Equatable, Sendable {
    public let route: SelectedRoute
    public let metres: Double
    public let seconds: Double
    public let label: String
}

/// Offline route choice: the fastest legal route by typical road-class speed,
/// the shortest, and further routes found by penalizing roads already offered.
/// A route is offered only if it is at most 50% slower than the fastest and
/// shares less than 75% of its length with every route already offered.
public enum RoutePlanner {
    /// Typical free-flow speeds, km/h. Travel times are estimates, not traffic-aware.
    static let speeds: [String: Double] = [
        "motorway": 100, "trunk": 80, "primary": 60, "secondary": 50, "tertiary": 45,
        "motorway_link": 50, "trunk_link": 45, "primary_link": 40, "secondary_link": 35, "tertiary_link": 30,
        "unclassified": 35, "residential": 30, "living_street": 15, "service": 15, "track": 12
    ]
    static let fastestSpeed = 100.0 / 3.6

    static func seconds(_ edge: RoadEdge) -> Double {
        return edge.length / ((speeds[edge.record.kind] ?? 30) / 3.6)
    }

    public static func alternatives(graph: RoadGraph, start: RoadPosition, destination: RoadPosition, maximum: Int = 3) -> [RouteOption] {
        var destinations = [destination]
        if let reverse = graph.reverse(destination) {
            destinations.append(reverse)
        }
        let travelTime = graph.edges.map(seconds)
        guard let fastest = search(graph: graph, start: start, destinations: destinations, cost: travelTime,
                                   heuristicSpeed: fastestSpeed) else {
            return []
        }
        var options = [option(fastest, graph: graph, label: "Fastest")]
        let length = graph.edges.map { edge in
            return edge.record.kind == "track" ? edge.length * 3 : edge.length
        }
        var candidates: [(SelectedRoute, String)] = []
        if let shortest = search(graph: graph, start: start, destinations: destinations, cost: length, heuristicSpeed: 1) {
            candidates.append((shortest, "Shortest"))
        }
        var penalized = travelTime
        var attempts = 0
        while options.count < maximum && attempts < 6 {
            if candidates.isEmpty {
                attempts += 1
                for option in options {
                    for edge in option.route.edges {
                        penalized[edge] *= 1.8
                    }
                }
                guard let route = search(graph: graph, start: start, destinations: destinations, cost: penalized,
                                         heuristicSpeed: fastestSpeed) else {
                    break
                }
                candidates.append((route, "Alternative"))
            }
            let (route, label) = candidates.removeFirst()
            let candidate = option(route, graph: graph, label: label)
            guard candidate.seconds <= options[0].seconds * 1.5 else {
                continue
            }
            let distinct = options.allSatisfy { accepted in
                return sharedMetres(candidate.route, accepted.route, graph: graph) < 0.75 * candidate.metres
            }
            if distinct {
                options.append(candidate)
            } else if label == "Shortest", candidate.route.edges == options[0].route.edges {
                options[0] = RouteOption(route: options[0].route, metres: options[0].metres, seconds: options[0].seconds,
                                         label: "Fastest · shortest")
            }
        }
        return options
    }

    private static func option(_ route: SelectedRoute, graph: RoadGraph, label: String) -> RouteOption {
        var seconds = 0.0
        for (index, edgeIndex) in route.edges.enumerated() {
            let edge = graph.edges[edgeIndex]
            var used = edge.length
            if index == 0 {
                used -= route.start.distance
            }
            if index == route.edges.count - 1 {
                used -= edge.length - route.destination.distance
            }
            seconds += max(0, used) / ((speeds[edge.record.kind] ?? 30) / 3.6)
        }
        return RouteOption(route: route, metres: route.distance(in: graph), seconds: seconds, label: label)
    }

    private static func sharedMetres(_ first: SelectedRoute, _ second: SelectedRoute, graph: RoadGraph) -> Double {
        let other = Set(second.edges)
        return first.edges.reduce(0.0) { total, edge in
            return other.contains(edge) ? total + graph.edges[edge].length : total
        }
    }

    /// A* over directed edges. `cost[e]` is paid for traversing edge e; the
    /// heuristic is straight-line distance at `heuristicSpeed`, admissible for
    /// any cost at least length / heuristicSpeed.
    static func search(graph: RoadGraph, start: RoadPosition, destinations: [RoadPosition], cost: [Double],
                       heuristicSpeed: Double) -> SelectedRoute? {
        guard graph.edges.indices.contains(start.edge) else {
            return nil
        }
        for destination in destinations where destination.edge == start.edge {
            let route = SelectedRoute(start: start, destination: destination, edges: [start.edge])
            if route.isValid(in: graph) {
                return route
            }
        }
        let targets = Dictionary(destinations.map { ($0.edge, $0) }, uniquingKeysWith: { first, _ in first })
        let goal = graph.coordinate(destinations[0]).metres
        func heuristic(_ edge: Int) -> Double {
            return (graph.edges[edge].points[0] - goal).length / heuristicSpeed
        }
        var best = [Double](repeating: .infinity, count: graph.edges.count)
        var parent = [Int32](repeating: -1, count: graph.edges.count)
        // The straight-line heuristic is consistent, so each edge expands once.
        var closed = [Bool](repeating: false, count: graph.edges.count)
        var heap = MinimumHeap()
        best[start.edge] = 0
        heap.push(heuristic(start.edge), start.edge)
        while let (_, edge) = heap.pop() {
            guard !closed[edge] else {
                continue
            }
            closed[edge] = true
            let reached = best[edge]
            if edge != start.edge, let destination = targets[edge] {
                var path = [edge]
                while parent[path[path.count - 1]] >= 0 {
                    path.append(Int(parent[path[path.count - 1]]))
                }
                let route = SelectedRoute(start: start, destination: destination, edges: path.reversed())
                if route.isValid(in: graph) {
                    return route
                }
                continue
            }
            let next = reached + cost[edge]
            for successor in graph.successors(of: edge) where next < best[successor] {
                best[successor] = next
                parent[successor] = Int32(edge)
                heap.push(next + heuristic(successor), successor)
            }
        }
        return nil
    }
}

/// Binary heap of (priority, edge) with lazy deletion of stale entries.
private struct MinimumHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ priority: Double, _ edge: Int) {
        items.append((priority, edge))
        var index = items.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard items[parent].0 > items[index].0 else {
                break
            }
            items.swapAt(parent, index)
            index = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let first = items.first else {
            return nil
        }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < items.count && items[left].0 < items[smallest].0 {
                    smallest = left
                }
                if right < items.count && items[right].0 < items[smallest].0 {
                    smallest = right
                }
                if smallest == index {
                    break
                }
                items.swapAt(index, smallest)
                index = smallest
            }
        }
        return first
    }
}
