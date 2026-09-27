import Foundation

/// An ordered, directed route in the recorded offline map snapshot.
/// Routes do not repeat directed edges, so each position has one route offset.
public struct SelectedRoute: Codable, Equatable, Sendable {
    public let start: RoadPosition
    public let destination: RoadPosition
    public let edges: [Int]

    public func isValid(in graph: RoadGraph) -> Bool {
        guard edges.first == start.edge, edges.last == destination.edge,
              Set(edges).count == edges.count,
              edges.allSatisfy({ edge in
                  return graph.edges.indices.contains(edge)
              }), start.distance.isFinite, destination.distance.isFinite,
              start.distance >= 0, start.distance <= graph.edges[start.edge].length,
              destination.distance >= 0, destination.distance <= graph.edges[destination.edge].length else {
            return false
        }
        if edges.count == 1 && destination.distance <= start.distance {
            return false
        }
        for index in 1..<edges.count {
            if !graph.successors(of: edges[index - 1]).contains(edges[index]) {
                return false
            }
        }
        return true
    }

    public func coordinates(in graph: RoadGraph) -> [Coordinate] {
        var result: [Coordinate] = []
        for edgeIndex in edges {
            let edge = graph.edges[edgeIndex]
            var lower = 0.0
            var upper = edge.length
            if edgeIndex == start.edge {
                lower = start.distance
            }
            if edgeIndex == destination.edge {
                upper = destination.distance
            }
            result.append(graph.coordinate(RoadPosition(edge: edgeIndex, distance: lower)))
            for distance in edge.cumulative where distance > lower && distance < upper {
                result.append(graph.coordinate(RoadPosition(edge: edgeIndex, distance: distance)))
            }
            result.append(graph.coordinate(RoadPosition(edge: edgeIndex, distance: upper)))
        }
        return result
    }

    public func distance(in graph: RoadGraph) -> Double {
        return edges.reduce(0.0) { total, edge in
            return total + graph.edges[edge].length
        } - start.distance - graph.edges[destination.edge].length + destination.distance
    }

    func offset(of position: RoadPosition, graph: RoadGraph) -> Double? {
        var offset = -start.distance
        for edge in edges {
            if edge == position.edge {
                return offset + position.distance
            }
            offset += graph.edges[edge].length
        }
        return nil
    }

    func position(at offset: Double, graph: RoadGraph) -> RoadPosition? {
        guard offset >= 0, offset <= distance(in: graph) else {
            return nil
        }
        var remaining = offset + start.distance
        for edge in edges {
            if remaining <= graph.edges[edge].length {
                return RoadPosition(edge: edge, distance: remaining)
            }
            remaining -= graph.edges[edge].length
        }
        return nil
    }

    /// Shortest legal road distance, respecting the selected starting direction
    /// and the graph's one-way and turn restrictions. No online service or GPS.
    public static func plan(graph: RoadGraph, start: RoadPosition, destination: RoadPosition) -> SelectedRoute? {
        guard graph.edges.indices.contains(start.edge), graph.edges.indices.contains(destination.edge) else {
            return nil
        }
        if start.edge == destination.edge {
            let route = SelectedRoute(start: start, destination: destination, edges: [start.edge])
            if route.isValid(in: graph) {
                return route
            }
            return nil
        }
        var costs = [start.edge: 0.0]
        var parents: [Int: Int] = [:]
        var heap: [(cost: Double, edge: Int)] = [(0, start.edge)]
        while !heap.isEmpty {
            let item = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var index = 0
                while index * 2 + 1 < heap.count {
                    var child = index * 2 + 1
                    if child + 1 < heap.count && heap[child + 1].cost < heap[child].cost {
                        child += 1
                    }
                    if heap[index].cost <= heap[child].cost {
                        break
                    }
                    heap.swapAt(index, child)
                    index = child
                }
            }
            guard item.cost == costs[item.edge] else {
                continue
            }
            if item.edge == destination.edge {
                var path = [item.edge]
                while let parent = parents[path.last!] {
                    path.append(parent)
                }
                let route = SelectedRoute(start: start, destination: destination, edges: path.reversed())
                if route.isValid(in: graph) {
                    return route
                }
                return nil
            }
            // Unpaved tracks (bundled only around Slavske) stay usable but are
            // chosen only when they save substantial distance.
            var weight = 1.0
            if graph.edges[item.edge].record.kind == "track" {
                weight = 3
            }
            for next in graph.successors(of: item.edge) {
                let cost = item.cost + graph.edges[item.edge].length * weight
                guard cost < costs[next, default: .infinity] else {
                    continue
                }
                costs[next] = cost
                parents[next] = item.edge
                heap.append((cost, next))
                var index = heap.count - 1
                while index > 0 {
                    let parent = (index - 1) / 2
                    if heap[parent].cost <= heap[index].cost {
                        break
                    }
                    heap.swapAt(index, parent)
                    index = parent
                }
            }
        }
        return nil
    }
}
