import Foundation

/// A meaningful directional feature on the selected route. Features include
/// ordinary junction turns and longer bends. The straight distances before and
/// after each feature let later observations distinguish repeated turn angles.
struct RouteFeature: Codable, Equatable {
    let index: Int
    let start: Double
    let end: Double
    let midpoint: Double
    let angle: Double
    let precedingStraightMetres: Double
    let followingStraightMetres: Double
    let supportsTimedCorrection: Bool
}

struct RouteEvidenceEvent: Codable {
    let time: Double
    let signalID: Int
    let stage: String
    let reason: String
    let observedTurnDegrees: Double
    let matchedFeatureIndex: Int?
    let matchedTurnDegrees: Double?
    let matchedRouteOffsetMetres: Double?
    let angleResidualDegrees: Double?
    let routeOffsetBeforeMetres: Double
    let routeOffsetAfterMetres: Double?
    let confidence: Double
    let runnerUpConfidence: Double
    let precedingStraightSeconds: Double?
    let precedingStraightMetres: Double?
    var routeAverageSpeedMetresPerSecond: Double? = nil
    var speedBeforeMetresPerSecond: Double? = nil
    var speedAfterMetresPerSecond: Double? = nil
    /// Engine 3.0: where the matched turn places the car now, its standard
    /// deviation, the turn point used ("midpoint" or "end") and whether the
    /// hypotheses moved by a Kalman gain ("kalman") or fully ("recovery_shift").
    var anchorRouteOffsetMetres: Double? = nil
    var anchorSigmaMetres: Double? = nil
    var anchor: String? = nil
    var correction: String? = nil
}

struct RouteEvidenceDecision {
    let feature: RouteFeature?
    let confidence: Double
    let runnerUpConfidence: Double
    let reason: String
    let precedingStraightSeconds: Double?
    /// Route offset of the car now according to the dominant hypothesis, its
    /// standard deviation, and the spread of all hypotheses about that offset.
    var anchorRouteOffset: Double? = nil
    var anchorSigma: Double? = nil
    var mixtureSigma: Double? = nil
    var anchor: String? = nil
}

/// Tracks the car's position along the selected route from completed turns,
/// keeping several weighted hypotheses instead of deciding each turn alone.
/// Every hypothesis carries a route offset and variance, advanced by the
/// odometer. A completed turn branches each hypothesis into one child per
/// nearby mapped feature (Kalman-updated to that feature, weighted by angle
/// and position agreement) and one child for a turn the map does not explain.
/// Curvy roads repeat similar bends every 100–200 m, so one turn is rarely
/// decisive, but the measured spacing between successive bends quickly
/// eliminates wrong alignments. A small hypothesis around the engine estimate
/// with its conservative uncertainty is added before each turn so a wrong
/// sequence can still be abandoned. A feature is accepted once the hypotheses
/// that matched it hold 75% of the weight; accepted features are not
/// binding, because every hypothesis keeps its own matched sequence.
final class RouteEvidenceMatcher {
    let features: [RouteFeature]

    private struct Hypothesis {
        var offset: Double
        var variance: Double
        var weight: Double
        var lastFeatureIndex: Int?
        var lastMatchedEnd: Double?
        var matched: RouteFeature?
    }

    static let minimumObservedAngle = 30.0 * .pi / 180
    static let minimumFeatureAngle = 20.0 * .pi / 180
    static let acceptanceWeight = 0.75
    /// Odometer error per metre driven between turns: vibration distance was
    /// within 0.6–2.5% on field drives. Road joints at regular spacing can lock
    /// the axle echo to the wrong delay (30% fast for a minute on one Lviv
    /// drive), so a small share of each hypothesis allows that larger error.
    private static let odometerError = 0.06
    private static let grossOdometerError = 0.3
    private static let grossOdometerWeight = 0.05
    private static let detectionProbability = 0.85
    /// Density of observed turns the map does not explain, per metre of route.
    /// Gentle turns can come from bends drawn smoother than driven; right-angle
    /// turns away from any mapped turn are rare on a followed route.
    private static let clutterDensity = 1.0 / 1000
    private static func clutterAngleLikelihood(_ angle: Double) -> Double {
        return 0.25 * exp(-max(0, abs(angle) - minimumObservedAngle) / (20 * .pi / 180))
    }
    private static let fallbackWeight = 0.02
    private static let maximumHypotheses = 32

    private var hypotheses: [Hypothesis] = []
    private var referenceOdometer = 0.0
    private var fallbackOdometer = 0.0
    private var lastMatchTime: Double?
    private var lastTurnEndTime: Double?
    private var startTime: Double?

    init(route: SelectedRoute, graph: RoadGraph) {
        features = Self.buildFeatures(route: route, graph: graph)
    }

    func start(at time: Double?) {
        hypotheses = []
        fallbackOdometer = 0
        lastMatchTime = nil
        lastTurnEndTime = nil
        startTime = time
    }

    /// - Parameters:
    ///   - odometer: distance driven so far by the engine's speed; hypotheses
    ///     advance by its change. Without it, estimated speed times elapsed time.
    ///   - distanceSinceMidpoint: distance driven since the turn's angular
    ///     midpoint, when the motion history resolves it.
    ///   - distanceSinceEnd: distance driven since the turn ended.
    func match(turn: TurnObservation,
               time: Double,
               estimatedRouteOffset: Double,
               uncertainty: Double,
               estimatedSpeed: Double,
               odometer: Double? = nil,
               distanceSinceMidpoint: Double? = nil,
               distanceSinceEnd: Double? = nil) -> RouteEvidenceDecision {
        let precedingStraightSeconds: Double?
        if let lastTurnEndTime {
            precedingStraightSeconds = max(0, turn.start - lastTurnEndTime)
        } else if let startTime {
            precedingStraightSeconds = max(0, turn.start - startTime)
        } else {
            precedingStraightSeconds = nil
        }
        guard abs(turn.angle) >= Self.minimumObservedAngle else {
            return RouteEvidenceDecision(feature: nil, confidence: 0, runnerUpConfidence: 0,
                                         reason: "Observed direction change is below the route-evidence floor",
                                         precedingStraightSeconds: nil)
        }

        if let lastMatchTime {
            fallbackOdometer += max(0, estimatedSpeed) * max(0, time - lastMatchTime)
        }
        lastMatchTime = time
        let odometerNow = odometer ?? fallbackOdometer
        let engineVariance = pow(max(4, uncertainty / 2), 2)
        if hypotheses.isEmpty {
            hypotheses = [Hypothesis(offset: estimatedRouteOffset, variance: engineVariance, weight: 1)]
        } else {
            let driven = max(0, odometerNow - referenceOdometer)
            var propagated: [Hypothesis] = []
            for var hypothesis in hypotheses {
                hypothesis.offset += driven
                hypothesis.matched = nil
                var gross = hypothesis
                hypothesis.variance += pow(Self.odometerError * driven, 2)
                hypothesis.weight *= 1 - Self.grossOdometerWeight
                gross.variance += pow(Self.grossOdometerError * driven, 2)
                gross.weight *= Self.grossOdometerWeight
                propagated += [hypothesis, gross]
            }
            hypotheses = propagated
            // Heavy tail: the engine's own estimate with its conservative
            // uncertainty, for when every tracked sequence has gone wrong.
            let total = hypotheses.reduce(0.0) { sum, hypothesis in
                return sum + hypothesis.weight
            }
            hypotheses.append(Hypothesis(offset: estimatedRouteOffset, variance: engineVariance,
                                         weight: total * Self.fallbackWeight))
        }
        referenceOdometer = odometerNow

        let useMidpoint = distanceSinceMidpoint != nil
        let sinceTurn = distanceSinceMidpoint ?? distanceSinceEnd ?? max(0, estimatedSpeed) * max(0, time - turn.end)
        var children: [Hypothesis] = []
        for hypothesis in hypotheses {
            let turnOffset = hypothesis.offset - sinceTurn
            var clutter = hypothesis
            clutter.weight *= (1 - Self.detectionProbability) * Self.clutterDensity * Self.clutterAngleLikelihood(turn.angle)
            children.append(clutter)
            let reach = 4 * sqrt(hypothesis.variance + 70 * 70) + 20
            for feature in features {
                if let last = hypothesis.lastFeatureIndex, feature.index <= last {
                    continue
                }
                if let end = hypothesis.lastMatchedEnd, feature.start < end - 10 {
                    continue
                }
                let featureOffset = useMidpoint ? feature.midpoint : feature.end
                let innovation = featureOffset - turnOffset
                guard abs(innovation) <= reach else {
                    continue
                }
                let length = feature.end - feature.start
                let featureSigma = useMidpoint ? max(8, 0.3 * length) : max(25, 0.5 * length)
                let innovationVariance = hypothesis.variance + featureSigma * featureSigma
                let angleSigma = 12 * .pi / 180 + 0.15 * abs(feature.angle)
                let residual = angleDifference(turn.angle, feature.angle)
                let likelihood = Self.detectionProbability * exp(-0.5 * pow(residual / angleSigma, 2))
                    * exp(-0.5 * innovation * innovation / innovationVariance) / sqrt(2 * .pi * innovationVariance)
                guard likelihood > 0 else {
                    continue
                }
                let gain = hypothesis.variance / innovationVariance
                children.append(Hypothesis(offset: hypothesis.offset + gain * innovation,
                                           variance: max(1, (1 - gain) * hypothesis.variance),
                                           weight: hypothesis.weight * likelihood,
                                           lastFeatureIndex: feature.index, lastMatchedEnd: feature.end,
                                           matched: feature))
            }
        }
        hypotheses = Self.prune(children)
        guard !hypotheses.isEmpty else {
            return RouteEvidenceDecision(feature: nil, confidence: 0, runnerUpConfidence: 0,
                                         reason: "No forward route feature is physically reachable",
                                         precedingStraightSeconds: precedingStraightSeconds)
        }
        // Hypotheses that explain this turn by the same feature (or by none)
        // form one alternative, whatever their odometer spread.
        var groups: [Int: (weight: Double, feature: RouteFeature?)] = [:]
        for hypothesis in hypotheses {
            let key = hypothesis.matched?.index ?? -1
            groups[key, default: (0, hypothesis.matched)].weight += hypothesis.weight
        }
        let ranked = groups.sorted { first, second in
            return first.value.weight > second.value.weight
        }
        let best = ranked[0]
        let confidence = best.value.weight
        let runnerUp = ranked.count > 1 ? ranked[1].value.weight : 0
        let members = hypotheses.filter { hypothesis in
            return (hypothesis.matched?.index ?? -1) == best.key
        }
        let anchorOffset = members.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * hypothesis.offset
        } / confidence
        let anchorVariance = members.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * (hypothesis.variance + pow(hypothesis.offset - anchorOffset, 2))
        } / confidence
        let mixtureVariance = hypotheses.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * (hypothesis.variance + pow(hypothesis.offset - anchorOffset, 2))
        }
        guard confidence >= Self.acceptanceWeight, let feature = best.value.feature else {
            var decision = RouteEvidenceDecision(feature: nil, confidence: confidence, runnerUpConfidence: runnerUp,
                                                 reason: best.value.feature == nil && confidence >= Self.acceptanceWeight
                                                    ? "Turn not explained by the route near the tracked position"
                                                    : "Several route alignments remain plausible; retaining alternatives",
                                                 precedingStraightSeconds: precedingStraightSeconds)
            decision.mixtureSigma = sqrt(mixtureVariance)
            return decision
        }
        lastTurnEndTime = turn.end
        return RouteEvidenceDecision(feature: feature, confidence: confidence, runnerUpConfidence: runnerUp,
                                     reason: "Completed turn matched against the selected route",
                                     precedingStraightSeconds: precedingStraightSeconds,
                                     anchorRouteOffset: anchorOffset, anchorSigma: sqrt(anchorVariance),
                                     mixtureSigma: sqrt(mixtureVariance), anchor: useMidpoint ? "midpoint" : "end")
    }

    /// Merges hypotheses that agree on offset and matched sequence, keeps the
    /// strongest and normalises their weights, strongest first.
    private static func prune(_ children: [Hypothesis]) -> [Hypothesis] {
        let total = children.reduce(0.0) { sum, child in
            return sum + child.weight
        }
        guard total > 0, total.isFinite else {
            return []
        }
        var sorted = children.sorted { first, second in
            return first.offset < second.offset
        }
        var merged: [Hypothesis] = []
        for child in sorted where child.weight / total > 1e-6 {
            if var last = merged.last, abs(last.offset - child.offset) < 3,
               last.lastFeatureIndex == child.lastFeatureIndex {
                let weight = last.weight + child.weight
                let offset = (last.offset * last.weight + child.offset * child.weight) / weight
                last.variance = (last.weight * (last.variance + pow(last.offset - offset, 2))
                    + child.weight * (child.variance + pow(child.offset - offset, 2))) / weight
                if child.weight > last.weight {
                    last.matched = child.matched
                    last.lastMatchedEnd = child.lastMatchedEnd
                }
                last.offset = offset
                last.weight = weight
                merged[merged.count - 1] = last
            } else {
                merged.append(child)
            }
        }
        sorted = merged.sorted { first, second in
            return first.weight > second.weight
        }
        sorted = Array(sorted.prefix(maximumHypotheses))
        let kept = sorted.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight
        }
        return sorted.map { hypothesis in
            var normalised = hypothesis
            normalised.weight /= kept
            return normalised
        }
    }

    private static func buildFeatures(route: SelectedRoute, graph: RoadGraph) -> [RouteFeature] {
        let routeLength = route.distance(in: graph)
        guard routeLength >= 40 else {
            return []
        }
        let step = 5.0
        var headings: [(distance: Double, heading: Double)] = []
        for distance in stride(from: step, through: max(step, routeLength - step), by: step) {
            guard distance < routeLength,
                  let before = route.position(at: max(0, distance - step), graph: graph),
                  let after = route.position(at: min(routeLength, distance + step), graph: graph) else {
                continue
            }
            let vector = graph.coordinate(after).metres - graph.coordinate(before).metres
            headings.append((distance, bearing(vector)))
        }
        guard headings.count >= 2 else {
            return []
        }

        var raw: [(start: Double, end: Double, midpoint: Double, angle: Double, timed: Bool)] = []
        var firstActive: Int?
        var lastActive: Int?
        func appendFeature(lower: Int, upper: Int) {
            guard upper > lower else {
                return
            }
            let start = headings[lower].distance
            let end = headings[upper].distance
            guard end - start <= 220 else {
                return
            }
            var total = 0.0
            var absolute = 0.0
            for part in (lower + 1)...upper {
                let delta = angleDifference(headings[part].heading, headings[part - 1].heading)
                total += delta
                absolute += abs(delta)
            }
            guard abs(total) >= minimumFeatureAngle, abs(total) <= 175 * .pi / 180 else {
                return
            }
            var accumulated = 0.0
            var midpoint = (start + end) / 2
            for part in (lower + 1)...upper {
                let delta = angleDifference(headings[part].heading, headings[part - 1].heading)
                let target = total / 2 - accumulated
                if abs(delta) > 1e-9, target / delta >= 0, target / delta <= 1 {
                    midpoint = headings[part - 1].distance + step * target / delta
                    break
                }
                accumulated += delta
            }
            let monotonicity = abs(total) / max(1e-12, absolute)
            let timed = start >= 20 && end - start <= 100 && abs(total) >= 45 * .pi / 180
                && abs(total) <= 120 * .pi / 180 && monotonicity >= 0.9
            raw.append((start, end, midpoint, total, timed))
        }

        for index in 1..<headings.count {
            let delta = angleDifference(headings[index].heading, headings[index - 1].heading)
            if abs(delta) >= 0.5 * .pi / 180 {
                if firstActive == nil {
                    firstActive = index - 1
                }
                lastActive = index
            }
            if let lower = firstActive, let upper = lastActive,
               headings[index].distance - headings[upper].distance >= 15 {
                appendFeature(lower: lower, upper: upper)
                firstActive = nil
                lastActive = nil
            }
        }
        if let lower = firstActive, let upper = lastActive {
            appendFeature(lower: lower, upper: upper)
        }

        var junctionOffset = -route.start.distance
        for routeIndex in route.edges.indices {
            let incomingEdgeIndex = route.edges[routeIndex]
            let incomingEdge = graph.edges[incomingEdgeIndex]
            junctionOffset += incomingEdge.length
            guard routeIndex + 1 < route.edges.count else {
                continue
            }
            let outgoingEdgeIndex = route.edges[routeIndex + 1]
            let outgoingEdge = graph.edges[outgoingEdgeIndex]
            let incomingHeading = incomingEdge.heading(at: incomingEdge.length, span: 12)
            let outgoingHeading = outgoingEdge.heading(at: 0, span: 12)
            let junctionAngle = angleDifference(outgoingHeading, incomingHeading)
            if abs(junctionAngle) >= minimumFeatureAngle {
                raw.append((max(0, junctionOffset - 5), min(routeLength, junctionOffset + 5),
                            clamp(junctionOffset, 0, routeLength), junctionAngle, true))
            }
        }

        raw.sort { first, second in
            return first.midpoint < second.midpoint
        }
        var distinct: [(start: Double, end: Double, midpoint: Double, angle: Double, timed: Bool)] = []
        for item in raw {
            if let previous = distinct.last,
               abs(previous.midpoint - item.midpoint) < 8,
               previous.angle * item.angle > 0 {
                if abs(item.angle) > abs(previous.angle) {
                    distinct[distinct.count - 1] = item
                }
                continue
            }
            distinct.append(item)
        }
        let individual = distinct
        if individual.count >= 2 {
            for index in 0..<(individual.count - 1) {
                let first = individual[index]
                let second = individual[index + 1]
                let gap = second.start - first.end
                let combinedAngle = first.angle + second.angle
                if gap >= 0, gap <= 120, abs(combinedAngle) >= 60 * .pi / 180,
                   abs(combinedAngle) <= 300 * .pi / 180 {
                    distinct.append((first.start, second.end, (first.midpoint + second.midpoint) / 2,
                                     combinedAngle, false))
                }
            }
        }
        distinct.sort { first, second in
            return first.midpoint < second.midpoint
        }
        raw = distinct

        return raw.enumerated().map { index, item in
            var precedingEnd = 0.0
            if index > 0 {
                precedingEnd = raw[index - 1].end
            }
            var followingStart = routeLength
            if index + 1 < raw.count {
                followingStart = raw[index + 1].start
            }
            return RouteFeature(index: index, start: item.start, end: item.end, midpoint: item.midpoint,
                                angle: item.angle, precedingStraightMetres: max(0, item.start - precedingEnd),
                                followingStraightMetres: max(0, followingStart - item.end),
                                supportsTimedCorrection: item.timed)
        }
    }
}
