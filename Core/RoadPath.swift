import Foundation

/// Consecutive directed edges with an unambiguous, shallow continuation.
/// Distances are measured along the full path, including every edge boundary.
struct RoadPath: Sendable {
    let edges: [Int]
    let offsets: [Double]
    let length: Double

    func position(at distance: Double) -> RoadPosition {
        let distance = clamp(distance, 0, length)
        var lower = 0
        var upper = edges.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if offsets[middle] <= distance {
                lower = middle
            } else {
                upper = middle
            }
        }
        return RoadPosition(edge: edges[lower], distance: distance - offsets[lower])
    }

    /// A chord through the continuous geometry, including internal edge seams.
    /// Do not invent a continuation beyond an ambiguous fork or path endpoint.
    func heading(at distance: Double, span: Double, roads: [RoadEdge]) -> Double? {
        let halfSpan = max(1, span / 2)
        guard distance >= halfSpan, distance + halfSpan <= length else {
            return nil
        }
        let before = position(at: distance - halfSpan)
        let after = position(at: distance + halfSpan)
        let first = roads[before.edge].point(at: before.distance)
        let last = roads[after.edge].point(at: after.distance)
        let direction = last - first
        guard direction.length > 0.1 else {
            return nil
        }
        return bearing(direction)
    }

    func curvature(at distance: Double, span: Double, roads: [RoadEdge]) -> Double? {
        let separation = max(4, span)
        guard let before = heading(at: distance - separation / 2, span: separation, roads: roads),
              let after = heading(at: distance + separation / 2, span: separation, roads: roads) else {
            return nil
        }
        return angleDifference(after, before) / separation
    }

    static func build(edges: [RoadEdge], successors: [[Int]]) -> (paths: [RoadPath], pathIndex: [Int], pathOffset: [Double]) {
        var continuation = Array<Int?>(repeating: nil, count: edges.count)
        var predecessors = Array(repeating: [Int](), count: edges.count)
        for index in edges.indices {
            let heading = edges[index].heading(at: edges[index].length)
            let aligned = successors[index].filter { next in
                return abs(angleDifference(edges[next].heading(at: 0), heading)) < .pi / 6
            }
            if aligned.count == 1 {
                continuation[index] = aligned[0]
                predecessors[aligned[0]].append(index)
            }
        }
        var previous = Array<Int?>(repeating: nil, count: edges.count)
        for index in edges.indices {
            if let next = continuation[index] {
                if predecessors[next].count == 1 {
                    previous[next] = index
                } else {
                    continuation[index] = nil
                }
            }
        }
        var paths: [RoadPath] = []
        var pathIndex = Array(repeating: -1, count: edges.count)
        var pathOffset = Array(repeating: 0.0, count: edges.count)
        for start in edges.indices where previous[start] == nil {
            var members: [Int] = []
            var offsets: [Double] = []
            var length = 0.0
            var next: Int? = start
            while let index = next, pathIndex[index] == -1 {
                pathIndex[index] = paths.count
                pathOffset[index] = length
                members.append(index)
                offsets.append(length)
                length += edges[index].length
                next = continuation[index]
            }
            paths.append(RoadPath(edges: members, offsets: offsets, length: length))
        }
        // Closed cycles have no unique longitudinal origin. Keep their edges
        // separate rather than averaging across an arbitrary wrap boundary.
        for index in edges.indices where pathIndex[index] == -1 {
            pathIndex[index] = paths.count
            paths.append(RoadPath(edges: [index], offsets: [0], length: edges[index].length))
        }
        return (paths, pathIndex, pathOffset)
    }
}
