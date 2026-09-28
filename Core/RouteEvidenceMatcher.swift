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
    /// Engine 3.2: radius around the anchor holding 95% of all route
    /// hypotheses, and the RMS heading residual of the matched profile.
    var credibleRadiusMetres: Double? = nil
    var profileResidualDegrees: Double? = nil
    var profileLengthMetres: Double? = nil
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
    /// Radius around the anchor that holds 95% of all hypotheses' mass. Unlike
    /// the mixture spread it ignores a few percent of far-away alternatives.
    var credibleRadius: Double? = nil
    var profileResidual: Double? = nil
    var profileLength: Double? = nil
}

/// The car's heading over the road just driven: gyro yaw integrated against
/// the odometer. `distances` count back from now (descending to 0) and
/// `headings` are the integrated yaw there, in radians clockwise.
struct ObservedHeadingProfile {
    let distances: [Double]
    let headings: [Double]
    /// Distance driven since the turn started, passed its angular midpoint
    /// and ended.
    let sinceStart: Double
    let sinceMidpoint: Double?
    let sinceEnd: Double

    var length: Double {
        return distances.first ?? 0
    }
}

/// The selected route's heading every 5 m, clockwise from north and
/// unwrapped, from a 20 m chord so polyline vertices read as the smooth
/// bends a car drives.
struct RouteHeadingProfile {
    static let step = 5.0
    private let headings: [Double]

    init(route: RouteIndex, graph: RoadGraph) {
        let length = route.length
        var headings: [Double] = []
        var previous: Double?
        let count = Int(length / Self.step)
        headings.reserveCapacity(count + 1)
        for index in 0...max(0, count) {
            let offset = Double(index) * Self.step
            guard let before = route.position(at: clamp(offset - 10, 0, length)),
                  let after = route.position(at: clamp(offset + 10, 0, length)) else {
                headings.append(previous ?? 0)
                continue
            }
            let vector = graph.edges[after.edge].point(at: after.distance) - graph.edges[before.edge].point(at: before.distance)
            guard vector.length > 0.5 else {
                headings.append(previous ?? 0)
                continue
            }
            var heading = bearing(vector)
            if let previous {
                heading = previous + angleDifference(heading, previous)
            }
            headings.append(heading)
            previous = heading
        }
        self.headings = headings
    }

    func heading(at offset: Double) -> Double {
        guard !headings.isEmpty else {
            return 0
        }
        let position = clamp(offset / Self.step, 0, Double(headings.count - 1))
        let lower = Int(position)
        let upper = min(headings.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return headings[lower] + (headings[upper] - headings[lower]) * fraction
    }
}

/// Tracks the car's position along the selected route from completed turns,
/// keeping several weighted hypotheses instead of deciding each turn alone.
/// Every hypothesis carries a route offset and variance, advanced by the
/// odometer. A completed turn compares the gyro heading profile of the road
/// just driven, from before the turn until now, with the route's heading at
/// every plausible offset. Each hypothesis branches into its best-fitting
/// places (its prior times the profile fit) and one child for a turn the map
/// does not explain. Matching the whole profile uses every bend the car
/// drives, including long sweeping curves and S-bends that no single turn
/// feature describes; field drives matched within 10–25 m of GPS. Gentle
/// turns fit many places and move the hypotheses little. A small hypothesis
/// around the engine estimate with its conservative uncertainty is added
/// before each turn so a wrong sequence can still be abandoned. A turn is
/// accepted once 75% of the weight agrees on the car's place and most of it
/// matched a mapped bend of the observed direction.
final class RouteEvidenceMatcher {
    let features: [RouteFeature]
    private let routeHeadings: RouteHeadingProfile
    private let routeLength: Double

    private struct Hypothesis {
        var offset: Double
        var variance: Double
        var weight: Double
        /// Route offset where the last matched turn ended; a later turn must
        /// start beyond it.
        var lastMatchedEnd: Double?
        /// Whether this turn matched a mapped bend in the observed direction.
        var matched = false
    }

    static let minimumObservedAngle = 15.0 * .pi / 180
    static let turnaroundAngle = 150.0 * .pi / 180
    static let turnaroundSigma = 25.0
    static let turningPerStep = 1.0 * .pi / 180
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
    /// Heading residual at the true place once the constant offset is
    /// removed: 1–3° RMS on the Lviv drives, up to 7° through compound bends.
    /// Residuals are correlated over about 40 m of road.
    private static let headingSigma = 5.0 * .pi / 180
    private static let correlationLength = 40.0
    /// A turn that fits nowhere better than this RMS is treated as unmapped
    /// (a lane shift, road works or a detour). Gentle unmapped turns are
    /// common; right-angle turns away from any mapped bend are rare on a
    /// followed route.
    private static let clutterResidual = 9.0 * .pi / 180
    private static let clutterScale = 0.2
    private static func clutterAngleLikelihood(_ angle: Double) -> Double {
        return exp(-max(0, abs(angle) - 30 * .pi / 180) / (20 * .pi / 180))
    }
    /// True places fitted within 1–7° RMS on field drives and a wide arc
    /// through a sharply drawn corner within 11°; service roads missing
    /// from the map fitted at 22°. Such a fit must not move the estimate.
    private static let maximumAcceptedResidual = 14.0 * .pi / 180
    /// The odometer may be off by a few percent, or much more while the axle
    /// echo is locked wrongly; the profile is matched at each of these scales.
    private static let scales = [0.8, 0.87, 0.93, 1.0, 1.07, 1.15, 1.25]
    private static let profileMargin = 40.0
    static let maximumProfileLength = 2000.0
    private static let fallbackWeight = 0.02
    private static let maximumHypotheses = 32
    private static let maximumChildren = 3

    private var hypotheses: [Hypothesis] = []
    private var referenceOdometer = 0.0
    private var fallbackOdometer = 0.0
    private var lastMatchTime: Double?
    private var lastTurnEndTime: Double?
    private var startTime: Double?

    convenience init(route: SelectedRoute, graph: RoadGraph) {
        self.init(route: RouteIndex(route: route, graph: graph), graph: graph)
    }

    init(route: RouteIndex, graph: RoadGraph) {
        features = Self.buildFeatures(route: route, graph: graph)
        routeHeadings = RouteHeadingProfile(route: route, graph: graph)
        routeLength = route.length
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
    ///   - profile: the measured heading profile; without it the turn is
    ///     modelled as a constant-rate turn from its angle and timing.
    func match(turn: TurnObservation,
               time: Double,
               estimatedRouteOffset: Double,
               uncertainty: Double,
               estimatedSpeed: Double,
               odometer: Double? = nil,
               distanceSinceMidpoint: Double? = nil,
               distanceSinceEnd: Double? = nil,
               profile measured: ObservedHeadingProfile? = nil) -> RouteEvidenceDecision {
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
                hypothesis.matched = false
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

        let observed = measured ?? Self.rampProfile(turn: turn, time: time, speed: estimatedSpeed,
                                                    sinceMidpoint: distanceSinceMidpoint, sinceEnd: distanceSinceEnd)
        let fit = ProfileFit(observed: observed, route: routeHeadings)
        let effective = max(1, observed.length / Self.correlationLength)
        let clutterLikelihood = Self.clutterScale * Self.clutterAngleLikelihood(turn.angle)
            * exp(-0.5 * effective * pow(Self.clutterResidual / Self.headingSigma, 2))
        let minimumMappedAngle = max(10 * .pi / 180, 0.5 * abs(turn.angle))
        // Where the turn lies relative to the car now: measured by the
        // odometer along a measured profile or from the turn's angular
        // midpoint, only estimated from its end time and speed otherwise.
        let placement = measured != nil ? 5.0 : (distanceSinceMidpoint != nil ? 8.0 : 25.0)
        var children: [Hypothesis] = []
        for hypothesis in hypotheses {
            var clutter = hypothesis
            clutter.weight *= (1 - Self.detectionProbability) * clutterLikelihood
            children.append(clutter)
            let sigma = sqrt(hypothesis.variance + placement * placement)
            let floor = hypothesis.variance * placement * placement / (hypothesis.variance + placement * placement)
            var lower = max(0, hypothesis.offset - 4 * sigma - 30)
            let upper = min(routeLength, hypothesis.offset + 4 * sigma + 30)
            if let end = hypothesis.lastMatchedEnd {
                lower = max(lower, end - 10 + 0.8 * observed.sinceStart)
            }
            let first = Int((lower / RouteHeadingProfile.step).rounded(.up))
            let last = Int((upper / RouteHeadingProfile.step).rounded(.down))
            guard last >= first else {
                continue
            }
            let normaliser = log(sigma * sqrt(2 * .pi))
            let density = (first...last).map { cell -> Double in
                let offset = Double(cell) * RouteHeadingProfile.step
                let z = (offset - hypothesis.offset) / sigma
                let logLikelihood = -0.5 * effective * fit.meanSquaredResidual(cell: cell) / pow(Self.headingSigma, 2)
                return exp(-0.5 * z * z - normaliser + logLikelihood)
            }
            for basin in Self.basins(density, firstCell: first).prefix(Self.maximumChildren) {
                let mapped = routeHeadings.heading(at: basin.mean - observed.sinceEnd)
                    - routeHeadings.heading(at: basin.mean - observed.sinceStart)
                let bend = mapped * turn.angle > 0 && abs(mapped) >= minimumMappedAngle
                children.append(Hypothesis(offset: basin.mean, variance: max(floor, basin.variance),
                                           weight: hypothesis.weight * Self.detectionProbability * basin.mass,
                                           lastMatchedEnd: bend ? basin.mean - observed.sinceEnd : hypothesis.lastMatchedEnd,
                                           matched: bend))
            }
        }
        hypotheses = Self.prune(children)
        guard !hypotheses.isEmpty else {
            return RouteEvidenceDecision(feature: nil, confidence: 0, runnerUpConfidence: 0,
                                         reason: "No forward route position is physically reachable",
                                         precedingStraightSeconds: precedingStraightSeconds)
        }
        // Hypotheses that matched a mapped bend and agree on the car's place
        // form one alternative, whichever earlier sequence they came from.
        let lead = hypotheses.first { hypothesis in
            return hypothesis.matched
        } ?? hypotheses[0]
        let reach = max(30, 3 * sqrt(lead.variance))
        let members = hypotheses.filter { hypothesis in
            return hypothesis.matched == lead.matched && abs(hypothesis.offset - lead.offset) <= reach
        }
        let confidence = members.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight
        }
        let unmatchedWeight = hypotheses.reduce(0.0) { sum, hypothesis in
            return sum + (hypothesis.matched ? 0 : hypothesis.weight)
        }
        let runnerUp = hypotheses.first { hypothesis in
            return hypothesis.matched != lead.matched || abs(hypothesis.offset - lead.offset) > reach
        }?.weight ?? 0
        let anchorOffset = members.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * hypothesis.offset
        } / confidence
        let anchorVariance = members.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * (hypothesis.variance + pow(hypothesis.offset - anchorOffset, 2))
        } / confidence
        let mixtureVariance = hypotheses.reduce(0.0) { sum, hypothesis in
            return sum + hypothesis.weight * (hypothesis.variance + pow(hypothesis.offset - anchorOffset, 2))
        }
        let residual = sqrt(fit.meanSquaredResidual(cell: Int((anchorOffset / RouteHeadingProfile.step).rounded())))
        guard lead.matched, confidence >= Self.acceptanceWeight, residual <= Self.maximumAcceptedResidual else {
            // A reversal can be driven either way round (a left loop, a right
            // one through a car park, a three-point turn), so its heading
            // profile need not match the mapped one; the route reversing
            // nearby is what identifies it. Otherwise the engine stops.
            if abs(angleDifference(turn.angle, 0)) >= Self.turnaroundAngle,
               let turnaround = routeTurnaround(near: estimatedRouteOffset - observed.sinceEnd,
                                                reach: max(150, 1.5 * uncertainty)) {
                let anchorOffset = min(routeLength, turnaround.end + observed.sinceEnd)
                hypotheses = [Hypothesis(offset: anchorOffset, variance: pow(Self.turnaroundSigma, 2), weight: 1,
                                         lastMatchedEnd: turnaround.end, matched: true)]
                lastTurnEndTime = turn.end
                let feature = RouteFeature(index: -1, start: turnaround.start, end: turnaround.end,
                                           midpoint: (turnaround.start + turnaround.end) / 2,
                                           angle: routeHeadings.heading(at: turnaround.end) - routeHeadings.heading(at: turnaround.start),
                                           precedingStraightMetres: 0, followingStraightMetres: 0, supportsTimedCorrection: false)
                var decision = RouteEvidenceDecision(feature: feature, confidence: 1, runnerUpConfidence: 0,
                                                     reason: "U-turn matched to the route's turnaround",
                                                     precedingStraightSeconds: precedingStraightSeconds,
                                                     anchorRouteOffset: anchorOffset, anchorSigma: Self.turnaroundSigma,
                                                     mixtureSigma: Self.turnaroundSigma, anchor: "end")
                decision.profileResidual = residual
                decision.profileLength = observed.length
                return decision
            }
            var reason = "Several route alignments remain plausible; retaining alternatives"
            if unmatchedWeight >= Self.acceptanceWeight {
                reason = "Turn not explained by the route near the tracked position"
            } else if lead.matched && confidence >= Self.acceptanceWeight {
                reason = "Best route fit is too poor to move the estimate"
            }
            var decision = RouteEvidenceDecision(feature: nil, confidence: confidence, runnerUpConfidence: runnerUp,
                                                 reason: reason, precedingStraightSeconds: precedingStraightSeconds)
            decision.mixtureSigma = sqrt(mixtureVariance)
            decision.profileResidual = residual
            decision.profileLength = observed.length
            return decision
        }
        lastTurnEndTime = turn.end
        let sinceMidpoint = observed.sinceMidpoint ?? (observed.sinceStart + observed.sinceEnd) / 2
        let feature = matchedFeature(turn: turn, midpoint: anchorOffset - sinceMidpoint)
            ?? RouteFeature(index: -1, start: anchorOffset - observed.sinceStart, end: anchorOffset - observed.sinceEnd,
                            midpoint: anchorOffset - sinceMidpoint, angle: turn.angle, precedingStraightMetres: 0,
                            followingStraightMetres: 0, supportsTimedCorrection: false)
        var decision = RouteEvidenceDecision(feature: feature, confidence: confidence, runnerUpConfidence: runnerUp,
                                             reason: "Completed turn matched against the selected route",
                                             precedingStraightSeconds: precedingStraightSeconds,
                                             anchorRouteOffset: anchorOffset, anchorSigma: sqrt(anchorVariance),
                                             mixtureSigma: sqrt(mixtureVariance),
                                             anchor: observed.sinceMidpoint != nil ? "midpoint" : "end")
        decision.credibleRadius = credibleRadius(around: anchorOffset, mass: 0.95)
        decision.profileResidual = residual
        decision.profileLength = observed.length
        return decision
    }

    /// The route's reversal (150° within 150 m) whose end lies nearest to
    /// `offset`, within `reach`.
    private func routeTurnaround(near offset: Double, reach: Double) -> (start: Double, end: Double)? {
        let step = RouteHeadingProfile.step
        let span = 150.0
        var best: (start: Double, end: Double)?
        var candidate = max(0, offset - reach - span)
        while candidate <= min(routeLength, offset + reach + span) {
            let heading = routeHeadings.heading(at: candidate)
            var start: Double?
            var back = candidate - step
            while back >= max(0, candidate - span) {
                if abs(heading - routeHeadings.heading(at: back)) >= Self.turnaroundAngle {
                    start = back
                    break
                }
                back -= step
            }
            guard var start else {
                candidate += step
                continue
            }
            // Widen to where the heading stops changing on either side.
            var end = candidate
            while end + step <= min(routeLength, candidate + 60),
                  abs(routeHeadings.heading(at: end + step) - routeHeadings.heading(at: end)) > Self.turningPerStep {
                end += step
            }
            while start - step >= max(0, back - 60),
                  abs(routeHeadings.heading(at: start) - routeHeadings.heading(at: start - step)) > Self.turningPerStep {
                start -= step
            }
            if abs(end - offset) <= reach, abs(end - offset) < abs((best?.end ?? .infinity) - offset) {
                best = (start, end)
            }
            candidate = end + span
        }
        return best
    }

    /// The discrete route feature the matched turn corresponds to, if any;
    /// its mapped midpoint calibrates the wheelbase.
    private func matchedFeature(turn: TurnObservation, midpoint: Double) -> RouteFeature? {
        return features.filter { feature in
            return feature.angle * turn.angle > 0
                && abs(angleDifference(feature.angle, turn.angle)) <= 25 * .pi / 180
                && abs(feature.midpoint - midpoint) <= max(20, 0.5 * (feature.end - feature.start))
        }.min { first, second in
            return abs(first.midpoint - midpoint) < abs(second.midpoint - midpoint)
        }
    }

    /// Smallest radius around `centre` holding `mass` of all hypotheses.
    private func credibleRadius(around centre: Double, mass target: Double) -> Double {
        func mass(within radius: Double) -> Double {
            return hypotheses.reduce(0.0) { sum, hypothesis in
                let sigma = sqrt(max(1, hypothesis.variance))
                let upper = (centre + radius - hypothesis.offset) / (sigma * sqrt(2))
                let lower = (centre - radius - hypothesis.offset) / (sigma * sqrt(2))
                return sum + hypothesis.weight * 0.5 * (erf(upper) - erf(lower))
            }
        }
        var low = 0.0
        var high = 1000.0
        while mass(within: high) < target && high < routeLength * 2 {
            high *= 2
        }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if mass(within: middle) >= target {
                high = middle
            } else {
                low = middle
            }
        }
        return high
    }

    /// The car's measured heading, sampled against distance, compared with
    /// the route's heading when the car is at a given offset now.
    private final class ProfileFit {
        let observed: ObservedHeadingProfile
        let route: RouteHeadingProfile
        private var cache: [Int: Double] = [:]

        init(observed: ObservedHeadingProfile, route: RouteHeadingProfile) {
            self.observed = observed
            self.route = route
        }

        /// Mean squared heading residual, after removing the constant
        /// heading offset, at the best odometer scale.
        func meanSquaredResidual(cell: Int) -> Double {
            if let cached = cache[cell] {
                return cached
            }
            let offset = Double(cell) * RouteHeadingProfile.step
            let count = Double(observed.distances.count)
            var best = Double.infinity
            for scale in RouteEvidenceMatcher.scales {
                var sum = 0.0
                var squares = 0.0
                for index in observed.distances.indices {
                    let residual = observed.headings[index] - route.heading(at: offset - scale * observed.distances[index])
                    sum += residual
                    squares += residual * residual
                }
                best = min(best, max(0, squares / count - pow(sum / count, 2)))
            }
            cache[cell] = best
            return best
        }
    }

    /// Splits a density sampled every 5 m into its separate peaks, merging
    /// peaks divided only by a shallow dip. Heaviest first.
    private static func basins(_ density: [Double], firstCell: Int) -> [(mass: Double, mean: Double, variance: Double)] {
        guard !density.isEmpty else {
            return []
        }
        var peaks: [Int] = []
        for index in density.indices {
            let left = index > 0 ? density[index - 1] : -1
            let right = index + 1 < density.count ? density[index + 1] : -1
            if density[index] > 0, density[index] >= left, density[index] > right {
                peaks.append(index)
            }
        }
        var bounds: [Int] = [0]
        if peaks.count > 1 {
            var kept = peaks[0]
            for peak in peaks.dropFirst() {
                let valley = (kept...peak).min { first, second in
                    return density[first] < density[second]
                } ?? kept
                if density[valley] < 0.3 * min(density[kept], density[peak]) {
                    bounds.append(valley)
                    kept = peak
                } else if density[peak] > density[kept] {
                    kept = peak
                }
            }
        }
        bounds.append(density.count)
        var result: [(mass: Double, mean: Double, variance: Double)] = []
        for part in 0..<(bounds.count - 1) {
            let range = bounds[part]..<bounds[part + 1]
            var mass = 0.0
            var moment = 0.0
            for index in range {
                mass += density[index]
                moment += density[index] * Double(firstCell + index) * RouteHeadingProfile.step
            }
            guard mass > 0, mass.isFinite else {
                continue
            }
            let mean = moment / mass
            var spread = 0.0
            for index in range {
                spread += density[index] * pow(Double(firstCell + index) * RouteHeadingProfile.step - mean, 2)
            }
            let step = RouteHeadingProfile.step
            result.append((mass * step, mean, max(16, spread / mass + step * step / 12)))
        }
        guard let heaviest = result.map(\.mass).max() else {
            return []
        }
        return result.filter { basin in
            return basin.mass >= 1e-3 * heaviest
        }.sorted { first, second in
            return first.mass > second.mass
        }
    }

    /// A constant-rate turn from the observation's angle and timing, for
    /// callers without a measured profile.
    private static func rampProfile(turn: TurnObservation, time: Double, speed: Double,
                                    sinceMidpoint: Double?, sinceEnd: Double?) -> ObservedHeadingProfile {
        let speed = max(1, speed)
        let length = max(5, speed * max(0, turn.end - turn.start))
        let end = sinceEnd ?? speed * max(0, time - turn.end)
        let middle = sinceMidpoint ?? end + length / 2
        let start = middle + length / 2
        let finish = max(0, middle - length / 2)
        let span = start + profileMargin
        let count = Int(min(80, max(8, span / 5)))
        let distances = (0...count).map { index in
            return span * (1 - Double(index) / Double(count))
        }
        let headings = distances.map { distance -> Double in
            if distance >= start {
                return 0
            }
            if distance <= finish {
                return turn.angle
            }
            return turn.angle * (start - distance) / max(1e-9, start - finish)
        }
        return ObservedHeadingProfile(distances: distances, headings: headings, sinceStart: start,
                                      sinceMidpoint: middle, sinceEnd: finish)
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
            if var last = merged.last, abs(last.offset - child.offset) < 3, last.matched == child.matched,
               abs((last.lastMatchedEnd ?? -1e9) - (child.lastMatchedEnd ?? -1e9)) < 10 {
                let weight = last.weight + child.weight
                let offset = (last.offset * last.weight + child.offset * child.weight) / weight
                last.variance = (last.weight * (last.variance + pow(last.offset - offset, 2))
                    + child.weight * (child.variance + pow(child.offset - offset, 2))) / weight
                if child.weight > last.weight {
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

    private static func buildFeatures(route index: RouteIndex, graph: RoadGraph) -> [RouteFeature] {
        let route = index.route
        let routeLength = index.length
        guard routeLength >= 40 else {
            return []
        }
        let step = 5.0
        var headings: [(distance: Double, heading: Double)] = []
        for distance in stride(from: step, through: max(step, routeLength - step), by: step) {
            guard distance < routeLength,
                  let before = index.position(at: max(0, distance - step)),
                  let after = index.position(at: min(routeLength, distance + step)) else {
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
