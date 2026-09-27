import Foundation

/// A route bend's angular centre is measured from its complete road geometry,
/// including internal graph seams. It is not assumed to be an OSM junction.
struct RouteTurnLandmark {
    let start: Double
    let end: Double
    let midpoint: Double
    let angle: Double
    let incoming: Int
    let outgoing: Int

    static func build(route: SelectedRoute, graph: RoadGraph) -> [RouteTurnLandmark] {
        return build(route: RouteIndex(route: route, graph: graph), graph: graph)
    }

    static func build(route routeIndex: RouteIndex, graph: RoadGraph) -> [RouteTurnLandmark] {
        let length = routeIndex.length
        guard length >= 60 else {
            return []
        }
        var headings: [(distance: Double, heading: Double)] = []
        for distance in stride(from: 5.0, through: length - 5, by: 5) {
            guard let before = routeIndex.position(at: distance - 5),
                  let after = routeIndex.position(at: distance + 5) else {
                continue
            }
            let vector = graph.coordinate(after).metres - graph.coordinate(before).metres
            headings.append((distance, bearing(vector)))
        }
        var result: [RouteTurnLandmark] = []
        var first: Int?
        var lastActive = 0
        for index in 1..<headings.count {
            let delta = angleDifference(headings[index].heading, headings[index - 1].heading)
            if abs(delta) >= 0.5 * .pi / 180 {
                if first == nil {
                    first = index - 1
                }
                lastActive = index
            }
            guard let lower = first, headings[index].distance - headings[lastActive].distance >= 20 else {
                continue
            }
            first = nil
            let upper = lastActive
            let start = headings[lower].distance
            let end = headings[upper].distance
            guard start >= 20, end - start <= 100 else {
                continue
            }
            var total = 0.0
            var absolute = 0.0
            for part in (lower + 1)...upper {
                let delta = angleDifference(headings[part].heading, headings[part - 1].heading)
                total += delta
                absolute += abs(delta)
            }
            // U-turns, compound bends and tiny steering events are not timed
            // anchors. Route knowledge does not make their midpoint reliable.
            guard abs(total) >= .pi / 4, abs(total) <= .pi * 2 / 3,
                  abs(total) >= 0.9 * absolute else {
                continue
            }
            var accumulated = 0.0
            var midpoint: Double?
            for part in (lower + 1)...upper {
                let delta = angleDifference(headings[part].heading, headings[part - 1].heading)
                let target = total / 2 - accumulated
                if abs(delta) > 1e-9, target / delta >= 0, target / delta <= 1 {
                    midpoint = headings[part - 1].distance + 5 * target / delta
                    break
                }
                accumulated += delta
            }
            guard let midpoint,
                  let incoming = routeIndex.position(at: start),
                  let outgoing = routeIndex.position(at: end) else {
                continue
            }
            result.append(RouteTurnLandmark(start: start, end: end, midpoint: midpoint, angle: total,
                                           incoming: incoming.edge, outgoing: outgoing.edge))
        }
        return result
    }

    func landmark(route: RouteIndex, graph: RoadGraph) -> TurnLandmark {
        return TurnLandmark(incoming: incoming, outgoing: outgoing,
                            incomingPath: graph.pathIndex[incoming], outgoingPath: graph.pathIndex[outgoing],
                            incomingDistance: graph.pathOffset[incoming], outgoingDistance: graph.pathOffset[outgoing],
                            route: route, routeAnchorDistance: midpoint)
    }
}
