import Foundation

/// A short sensor history locates the middle of a completed, single-direction
/// turn. It contains measurements only, never simulated or field-reference truth.
struct TurnMotionHistory {
    struct Interval {
        let start: Double
        let end: Double
        let acceleration: Double
        let yaw: Double
    }

    private var intervals: [Interval] = []

    mutating func append(_ sample: MotionSample, duration: Double) {
        intervals.append(Interval(start: sample.time - duration, end: sample.time,
                                  acceleration: clamp(sample.forwardAcceleration, -10, 7), yaw: sample.yawRate))
        intervals.removeAll { interval in
            return interval.end < sample.time - 60
        }
    }

    /// Time at which the yaw integral over [start, end] reaches half its total.
    /// Unlike `midpoint`, it accepts long and compound turns: it anchors
    /// route-wide evidence, never the timed joint correction.
    func halfAngleTime(start: Double, end: Double) -> Double? {
        guard end > start, let first = intervals.first, first.start <= start else {
            return nil
        }
        var total = 0.0
        for interval in intervals {
            let duration = max(0, min(end, interval.end) - max(start, interval.start))
            total += interval.yaw * duration
        }
        guard abs(total) > 1e-6 else {
            return nil
        }
        var accumulated = 0.0
        for interval in intervals {
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            guard upper > lower else {
                continue
            }
            let increment = interval.yaw * (upper - lower)
            let target = total / 2 - accumulated
            if abs(increment) > 1e-12, target / increment >= 0, target / increment <= 1 {
                return lower + target / increment * (upper - lower)
            }
            accumulated += increment
        }
        return nil
    }

    func midpoint(start: Double, end: Double, angle: Double) -> Double? {
        guard end - start >= 0.7, end - start <= 12,
              abs(angle) >= .pi / 4 - 0.20, abs(angle) <= .pi * 2 / 3 + 0.20,
              let first = intervals.first, first.start <= start else {
            return nil
        }
        var total = 0.0
        var absolute = 0.0
        for interval in intervals {
            let duration = max(0, min(end, interval.end) - max(start, interval.start))
            total += interval.yaw * duration
            absolute += abs(interval.yaw) * duration
        }
        guard abs(total - angle) < 0.12, abs(total) > 0.9 * absolute else {
            return nil
        }
        var accumulated = 0.0
        for interval in intervals {
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            guard upper > lower else {
                continue
            }
            let increment = interval.yaw * (upper - lower)
            let target = total / 2 - accumulated
            if abs(increment) > 1e-9, target / increment >= 0, target / increment <= 1 {
                return lower + target / increment * (upper - lower)
            }
            accumulated += increment
        }
        return nil
    }

    /// Backward integration from current velocity uses integral((t-start)*a(t)).
    func accelerationMoment(from start: Double, to end: Double) -> Double {
        var result = 0.0
        for interval in intervals {
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            if upper > lower {
                result += interval.acceleration * (pow(upper - start, 2) - pow(lower - start, 2)) / 2
            }
        }
        return result
    }

    func velocityChange(from start: Double, to end: Double) -> Double {
        var result = 0.0
        for interval in intervals {
            let duration = max(0, min(end, interval.end) - max(start, interval.start))
            result += interval.acceleration * duration
        }
        return result
    }
}

/// Preintegrate raw acceleration between independently timed junctions. Later
/// map reweighting must not rewrite these measurements. The resulting distance
/// constraint conditions the live joint speed/bias hypotheses.
struct LandmarkCalibrationInterval {
    let path: Int
    let distance: Double
    let time: Double
    let sigma: Double
    var velocityIntegral: Double
    var distanceIntegral: Double
    var routeOffset: Double? = nil

    mutating func append(acceleration: Double, duration: Double) {
        distanceIntegral += velocityIntegral * duration + acceleration * duration * duration / 2
        velocityIntegral += acceleration * duration
    }

    func hypotheses(current: [LandmarkState], time now: Double, midpoint: Double, distance measuredDistance: Double,
                    recentVelocity: Double, recentMoment: Double) -> [LandmarkState] {
        let recentDuration = now - midpoint
        let intervalDuration = midpoint - time
        let velocityAtMidpoint = velocityIntegral - recentVelocity
        let recentDistance = recentDuration * recentVelocity - recentMoment
        let momentAtMidpoint = distanceIntegral - velocityAtMidpoint * recentDuration - recentDistance
        return current.map { state in
            let speedAtMidpoint = state.speed - recentVelocity + state.bias * recentDuration
            let weightedAcceleration = intervalDuration * velocityAtMidpoint - momentAtMidpoint
            let distance = speedAtMidpoint * intervalDuration - weightedAcceleration + state.bias * intervalDuration * intervalDuration / 2
            return LandmarkState(position: state.position, speed: state.speed, bias: state.bias, weight: state.weight,
                                 integratedPosition: distance - measuredDistance)
        }
    }
}

/// Only isolated sharp corners between straight approaches are timed landmarks.
/// Smooth bends, roundabouts and straight graph seams remain likelihood evidence.
struct TurnLandmark {
    let incoming: Int
    let outgoing: Int
    let incomingPath: Int
    let outgoingPath: Int
    let incomingDistance: Double
    let outgoingDistance: Double
    var route: RouteIndex? = nil
    var routeAnchorDistance: Double? = nil

    static func candidates(graph: RoadGraph, start: RoadPosition, endPath: Int,
                           angle: Double, radius: Double) -> [TurnLandmark] {
        let startPath = graph.pathIndex[start.edge]
        guard startPath != endPath else {
            return []
        }
        let path = graph.paths[startPath]
        let startDistance = graph.pathOffset[start.edge] + start.distance
        var matches: [TurnLandmark] = []
        for incoming in path.edges {
            let edge = graph.edges[incoming]
            let distance = graph.pathOffset[incoming] + edge.length
            guard abs(distance - startDistance) <= radius,
                  isStraight(graph: graph, path: startPath, distance: distance, direction: -1) else {
                continue
            }
            for outgoing in graph.successors(of: incoming) {
                let outgoingPath = graph.pathIndex[outgoing]
                let outgoingDistance = graph.pathOffset[outgoing]
                let mapped = angleDifference(graph.edges[outgoing].heading(at: 0), edge.heading(at: edge.length))
                guard abs(angleDifference(mapped, angle)) < 0.20,
                      abs(mapped) >= .pi / 4, abs(mapped) <= .pi * 2 / 3,
                      isStraight(graph: graph, path: outgoingPath, distance: outgoingDistance, direction: 1) else {
                    continue
                }
                matches.append(TurnLandmark(incoming: incoming, outgoing: outgoing,
                                            incomingPath: startPath, outgoingPath: outgoingPath,
                                            incomingDistance: distance, outgoingDistance: outgoingDistance))
            }
        }
        return matches
    }

    private static func isStraight(graph: RoadGraph, path: Int, distance: Double, direction: Double) -> Bool {
        let road = graph.paths[path]
        guard distance + direction * 35 >= 0, distance + direction * 35 <= road.length else {
            return false
        }
        var reference: Double?
        for offset in [5.0, 15.0, 25.0, 30.0] {
            guard let heading = road.heading(at: distance + direction * offset, span: 8, roads: graph.edges) else {
                return false
            }
            if let reference, abs(angleDifference(heading, reference)) > 0.06 {
                return false
            }
            reference = heading
        }
        return true
    }

    func offset(of position: RoadPosition, graph: RoadGraph) -> Double? {
        if let route, let routeAnchorDistance {
            guard let offset = route.offset(of: position) else {
                return nil
            }
            return offset - routeAnchorDistance
        }
        let path = graph.pathIndex[position.edge]
        let distance = graph.pathOffset[position.edge] + position.distance
        if path == outgoingPath {
            return distance - outgoingDistance
        }
        if path == incomingPath {
            return distance - incomingDistance
        }
        return nil
    }

    func position(at offset: Double, graph: RoadGraph) -> RoadPosition? {
        if let route, let routeAnchorDistance {
            return route.position(at: routeAnchorDistance + offset)
        }
        if offset >= 0 {
            let distance = outgoingDistance + offset
            guard distance <= graph.paths[outgoingPath].length else {
                return nil
            }
            return graph.paths[outgoingPath].position(at: distance)
        }
        let distance = incomingDistance + offset
        guard distance >= 0 else {
            return nil
        }
        return graph.paths[incomingPath].position(at: distance)
    }
}

struct LandmarkState {
    var position: Double
    var speed: Double
    var bias: Double
    let weight: Double
    var integratedPosition: Double? = nil

    var vector: SIMD3<Double> {
        return SIMD3(position, speed, bias)
    }
}

struct LandmarkCorrection: Codable {
    let signalID: Int
    let observationTime: Double
    let incomingEdge: Int
    let outgoingEdge: Int
    let observationSigmaMetres: Double
    let innovationMetres: Double
    let positionChangeMetres: Double
    let speedChangeMetresPerSecond: Double
    let biasChangeMetresPerSecondSquared: Double
    let positionSigmaMetres: Double
    let speedSigmaMetresPerSecond: Double
    let biasSigmaMetresPerSecondSquared: Double
    var calibrationDistanceMetres: Double? = nil
    var calibrationDurationSeconds: Double? = nil
    var routeDistanceMetres: Double? = nil
}

/// A scalar timed-position observation conditions the existing joint ensemble.
/// It changes velocity and bias only through their covariance with position;
/// there is no second independently integrated speed estimate.
struct TurnLandmarkConditioning {
    let states: [LandmarkState]
    let innovation: Double
    let change: SIMD3<Double>
    let variance: SIMD3<Double>
    let speedBiasCovariance: Double

    static func apply(states: [LandmarkState], elapsed: Double, accelerationMoment: Double,
                      sigma: Double) -> TurnLandmarkConditioning? {
        guard !states.isEmpty, elapsed >= 0, sigma > 0 else {
            return nil
        }
        let mass = states.reduce(0.0) { sum, state in
            return sum + state.weight
        }
        guard mass > 0 else {
            return nil
        }
        var mean = SIMD3<Double>(repeating: 0)
        var observedMean = 0.0
        var observations: [Double] = []
        for state in states {
            let position = state.integratedPosition ?? state.position
            let observation = position - state.speed * elapsed + accelerationMoment - state.bias * elapsed * elapsed / 2
            observations.append(observation)
            mean += state.vector * (state.weight / mass)
            observedMean += observation * state.weight / mass
        }
        var covariance = SIMD3<Double>(repeating: 0)
        var observationVariance = 0.0
        for (index, state) in states.enumerated() {
            let residual = observations[index] - observedMean
            covariance += (state.vector - mean) * (residual * state.weight / mass)
            observationVariance += residual * residual * state.weight / mass
        }
        let measurementVariance = sigma * sigma
        let totalVariance = observationVariance + measurementVariance
        guard totalVariance.isFinite, abs(observedMean) <= 3 * sqrt(totalVariance) else {
            return nil
        }
        let gain = covariance / totalVariance
        let change = gain * -observedMean
        let contraction = 1 / (1 + sqrt(measurementVariance / totalVariance))
        var updated: [LandmarkState] = []
        var variance = SIMD3<Double>(repeating: 0)
        var speedBiasCovariance = 0.0
        let posteriorMean = mean + change
        for (index, state) in states.enumerated() {
            let vector = state.vector + change - gain * (contraction * (observations[index] - observedMean))
            guard vector.x.isFinite, vector.y >= 0, vector.y <= 65, abs(vector.z) < 0.2 else {
                return nil
            }
            let residual = vector - posteriorMean
            variance += residual * residual * (state.weight / mass)
            speedBiasCovariance += residual.y * residual.z * state.weight / mass
            updated.append(LandmarkState(position: vector.x, speed: vector.y, bias: vector.z, weight: state.weight))
        }
        return TurnLandmarkConditioning(states: updated, innovation: -observedMean, change: change,
                                        variance: variance, speedBiasCovariance: speedBiasCovariance)
    }
}

/// A real timed landmark may restart propagation, while an angle match may not.
/// Retain model allowances for residual bias and future process noise even if
/// resampling leaves an artificially narrow ensemble.
struct LandmarkMotionUncertainty {
    let positionVariance: Double
    let speedVariance: Double
    let biasVariance: Double
    let speedBiasCovariance: Double

    func radius(after time: Double) -> Double {
        let velocity = max(speedVariance, 0.15 * 0.15)
        let bias = max(biasVariance, 0.004 * 0.004)
        let covariance = clamp(speedBiasCovariance, -sqrt(velocity * bias), sqrt(velocity * bias))
        let propagated = velocity * time * time - covariance * pow(time, 3) + bias * pow(time, 4) / 4
        let process = 0.07 * 0.07 * pow(time, 3) / 3 + pow(TrackingEngine.accelerationBiasWalk, 2) * pow(time, 5) / 20
        // Unknown position/motion correlation is bounded conservatively rather
        // than silently assumed to be zero.
        return 2 * (sqrt(max(0, positionVariance)) + sqrt(max(0, propagated + process)))
    }
}
