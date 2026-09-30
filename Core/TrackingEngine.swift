import Foundation

public struct MotionSample: Codable, Sendable {
    public var time: Double
    public var forwardAcceleration: Double
    public var lateralAcceleration: Double
    public var verticalAcceleration: Double
    public var yawRate: Double
    public var pitch: Double
    public var roll: Double
    public var gravityError: Double
    public var magneticMagnitude: Double?
    public var relativeAltitude: Double?

    public init(time: Double, forwardAcceleration: Double, lateralAcceleration: Double = 0, verticalAcceleration: Double = 0, yawRate: Double = 0, pitch: Double = 0, roll: Double = 0, gravityError: Double = 0, magneticMagnitude: Double? = nil, relativeAltitude: Double? = nil) {
        self.time = time
        self.forwardAcceleration = forwardAcceleration
        self.lateralAcceleration = lateralAcceleration
        self.verticalAcceleration = verticalAcceleration
        self.yawRate = yawRate
        self.pitch = pitch
        self.roll = roll
        self.gravityError = gravityError
        self.magneticMagnitude = magneticMagnitude
        self.relativeAltitude = relativeAltitude
    }
}

public enum TrackingFailureReason: String, Codable, Sendable {
    case sensorGap = "sensor_gap"
    case mountTilt = "mount_tilt"
    case excessiveRotation = "excessive_rotation"
    case roadEnded = "road_ended"
    case mapRestrictionConflict = "map_restriction_conflict"
    case noRoadMatch = "no_road_match"
    case headingMismatch = "heading_mismatch"
    case uncertaintyExceeded = "uncertainty_exceeded"
    case outsideCoverage = "outside_coverage"
    case routeEnded = "route_ended"
}

/// A confident road-bump speed measurement that disagreed with the inertial
/// speed by at least `TrackingEngine.speedCorrectionThreshold`.
public struct SpeedCorrection: Sendable, Equatable {
    public let time: Double
    public let before: Double
    public let measured: Double
}

public struct TrackingFailure: Codable, Sendable {
    public let reason: TrackingFailureReason
    public let measurements: [String: Double]
}

public struct TrackingEstimate: Codable, Sendable {
    public var time: Double
    public var position: RoadPosition
    public var coordinate: Coordinate
    public var heading: Double
    public var speed: Double
    /// Outer radius along the road: on GPS-logged drives the error stayed
    /// within it for 95% of moving time. Route matching and resets use it.
    public var uncertainty: Double
    public var roadProbability: Double
    public var status: String
    public var anchorCount: Int
    public var turnDegrees: Double
    public var travelled: Double
    public var alternatives: [Coordinate]
    public var needsReset: Bool
    public var failure: TrackingFailure? = nil

    /// The radius shown to the driver: half the outer radius, which held the
    /// error for 84% of moving time on the same drives. It reads like a phone
    /// GPS accuracy, which is a 68% radius; the outer one looked far worse
    /// than the position usually was.
    public var typicalError: Double {
        return uncertainty * 0.5
    }
}

private struct Particle {
    var position: RoadPosition
    var speed: Double
    var heading: Double
    var accelerationBias: Double
    var gyroBias: Double
    var weight: Double
    var curvatureReference: CurvatureReference? = nil
}

private struct CurvatureReference {
    let time: Double
    let path: Int
    let position: RoadPosition
    let mapHeading: Double
    let inertialHeading: Double
    let speed: Double
    var roughnessIntegral = 0.0
}

/// A representative scored hypothesis, paired with the road update that follows
/// it. This is likelihood evidence, not a declaration of an absolute position fix.
struct CurvatureEvidence: Codable {
    let startTime: Double
    let endTime: Double
    let startPosition: RoadPosition
    let endPosition: RoadPosition
    let observedDegrees: Double
    let mappedDegrees: Double
    let residualDegrees: Double
    let sigmaDegrees: Double
    let weightMultiplier: Double
    let laneToleranceDegrees: Double?
}

struct RoadHypothesis: Codable {
    let edge: Int
    let probability: Double
    let distance: Double
    let speed: Double
    let accelerationBias: Double
    let gyroBias: Double
}

struct EngineDiagnostic: Codable {
    let time: Double
    let particleCount: Int
    let effectiveParticleCount: Double
    let confirmedStopped: Bool
    let unanchoredMovingTime: Double
    let headingMismatchTime: Double
    let turnIntegral: Double
    let roadHypotheses: [RoadHypothesis]
    var stopEvidence: StopEvidence? = nil
}

struct StopEvidence: Codable {
    let meanAcceleration: Double
    let accelerationStandardDeviation: Double
    let verticalRMS: Double
    let yawRMS: Double
    let quietSeconds: Double
    let recentBraking: Bool
    let speedBelowLimit: Bool
    let nearZeroProbability: Double
    let decision: String
    var speedLimitKilometresPerHour: Double? = nil
    var visualStopSupported: Bool? = nil
    var visualMovementDetected: Bool? = nil
    var departureImpulseMetresPerSecond: Double? = nil
    var departureAccelerationSupported: Bool? = nil
    var vibrationStopSupported: Bool? = nil
    var vibrationMovementDetected: Bool? = nil
}

/// A policy-based correction for movement accumulated while confirming a stop.
/// It is not an independently measured stopping point or a road landmark.
struct StopCorrection: Codable {
    let time: Double
    let onsetTime: Double?
    let before: RoadPosition
    let after: RoadPosition
    let rewindMetres: Double
    let decision: String
    var source: String? = nil
}

private struct StopHistoryPoint {
    let estimate: TrackingEstimate
    let belowSpeedLimit: Bool
}

private struct MotionWindowUpdate {
    let velocityChange: Double
    let departureSpeed: Double
    let distance: Double
    let duration: Double
    let windowDuration: Double
    let meanAcceleration: Double
    let accelerationStandardDeviation: Double
    let verticalRMS: Double
    let yawRMS: Double
}

struct RoadMatchUpdate: Codable {
    let time: Double
    let predictionBeforeRoadEvidence: Coordinate
    let previousEstimate: TrackingEstimate?
    let result: TrackingEstimate
    let adjustmentEastMetres: Double
    let adjustmentNorthMetres: Double
    let positionAdjustmentMetres: Double
    let headingResidualDegrees: Double
    var curvatureEvidence: CurvatureEvidence? = nil
    var landmarkCorrection: LandmarkCorrection? = nil
}

struct RoadSignalEvent: Codable {
    let signalID: Int
    let time: Double
    let stage: String
    let reason: String
    let turnStartTime: Double
    let turnEndTime: Double
    let turnStartPosition: RoadPosition
    let observedTurnDegrees: Double
    let mappedTurnDegrees: Double
    let angleResidualDegrees: Double
    let roadMatch: RoadMatchUpdate?
}

struct TurnObservation {
    let id: Int
    let start: Double
    let end: Double
    let startPosition: RoadPosition
    let startMapHeading: Double
    let angle: Double
    let startUncertainty: Double
    var reported = false
}

/// A bounded road-constrained particle filter. No location or network inputs exist.
public final class TrackingEngine {
    static let version = "3.4.0-repeat-rejection"
    public let graph: RoadGraph
    public private(set) var estimate: TrackingEstimate?
    /// Speed corrections from road bumps since start, counted once per
    /// disagreement episode and at most every five seconds.
    public private(set) var speedCorrectionCount = 0
    public private(set) var lastSpeedCorrection: SpeedCorrection?
    public static let speedCorrectionThreshold = 5 / 3.6
    /// Vibration speed spread (m/s) up to which it pulls hypotheses fully.
    static let confidentVibrationSigma = 1.0
    /// "Position uncertain" above this outer radius, i.e. a typical error
    /// above 45 m. At the former 45 m outer radius the status showed for 92%
    /// of moving time on GPS-logged drives, when the error exceeded 50 m in 22%.
    static let uncertainStatusRadius = 90.0
    private var speedDisagreementActive = false
    private var particles: [Particle] = []
    private var random: SeededRandom
    private let population = 384
    private var previousTime: Double?
    private var reportTime = 0.0
    private var lastAnchorTime = 0.0
    private var previousPitch = 0.0
    private var previousRoll = 0.0
    private var started = false
    private var confirmedStopped = true
    private var quietTime = 0.0
    private var stopEvidence: StopEvidence?
    private static let stopSpeedLimit = 3.0 / 3.6
    private static let minimumDepartureAcceleration = 0.08
    /// Random walk of residual forward-acceleration bias, m/s²/√s. Raised from
    /// 0.0015 in engine 3.0: field gravity drift exceeded 0.2 m/s² within
    /// minutes, and vibration speed reweighting now selects the surviving bias.
    static let accelerationBiasWalk = 0.004
    private var stopHistory: [StopHistoryPoint] = []
    private(set) var lastStopCorrection: StopCorrection?
    private var acceptMotionReference = false
    private var motionWindow: [(sample: MotionSample, duration: Double)] = []
    private var brakingTime = -Double.infinity
    private var totalDistance = 0.0
    private var turnIntegral = 0.0
    private var turnQuietTime = 0.0
    private var completedTurn = 0.0
    private var anchors = 0
    private var lastAnchorDistance = 0.0
    private var mismatchTime = 0.0
    private var frozen = false
    private var unanchoredMovingTime = 0.0
    /// Moving time covered by fresh vibration speed, and ∫σ²dt of that speed.
    private var vibrationMeasuredTime = 0.0
    private var speedVarianceIntegral = 0.0
    private var initialUncertainty = 8.0
    private var completedTurnTime = -Double.infinity
    private var turnStartTime = 0.0
    private var turnStartPosition: RoadPosition?
    private var turnStartMapHeading = 0.0
    private var turnStartUncertainty = 8.0
    private var turnMotionHistory = TurnMotionHistory()
    private var landmarkUncertainty: LandmarkMotionUncertainty?
    private var lastTimedLandmark: LandmarkCalibrationInterval?
    private var lastVisualSpeedTime: Double?
    private var latestVisualObservation: VisualSpeedObservation?
    private var visualStopStart: Double?
    private var visualStopCount = 0
    private var lastVibrationTime: Double?
    private var latestVibration: VibrationSpeedObservation?
    private var wheelbasePrior = WheelbaseEvidence()
    /// When false the learned wheelbase is still recorded but never applied.
    public var appliesWheelbaseCalibration = true
    private var wheelbaseCalibrator = WheelbaseCalibrator()
    private var vibrationStopStart: Double?
    private var vibrationMoveStart: Double?
    private var nextSignalID = 0
    private var pendingTurn: TurnObservation?
    private var roadSignals: [RoadSignalEvent] = []
    private var routeEvidenceEvents: [RouteEvidenceEvent] = []
    private var pendingRouteFeature: RouteFeature?
    private var lastRouteEvidenceEnd: Double?
    private var lastRouteEvidenceTurnEndTime: Double?
    private var routeEvidenceUncertainty: Double?
    /// Published travelled distance for as long as the turn motion history,
    /// to measure distance driven since a turn and sample its heading profile.
    private var travelHistory: [(time: Double, distance: Double)] = []
    private var bendHoldTravel = 0.0
    private var bendGateReleaseRemaining = 0.0
    private var blockedRestrictionEdge: Int?
    private(set) var lastRoadUpdate: RoadMatchUpdate?
    private var pendingCurvatureEvidence: CurvatureEvidence?

    private let route: SelectedRoute?
    private let routeSuccessors: [Int: Int]
    private let routeLandmarks: [RouteTurnLandmark]
    private let routeEvidenceMatcher: RouteEvidenceMatcher?
    private var routeIndex: RouteIndex?
    private var expectedRouteLandmarkIndex = 0

    public init(graph: RoadGraph, seed: UInt64 = 7829, route: SelectedRoute? = nil) {
        self.graph = graph
        self.route = route
        var successors: [Int: Int] = [:]
        if let route {
            precondition(route.isValid(in: graph), "Selected route must match the road graph")
            for index in 1..<route.edges.count {
                successors[route.edges[index - 1]] = route.edges[index]
            }
        }
        routeSuccessors = successors
        if let route {
            let index = RouteIndex(route: route, graph: graph)
            routeIndex = index
            routeLandmarks = RouteTurnLandmark.build(route: index, graph: graph)
            routeEvidenceMatcher = RouteEvidenceMatcher(route: index, graph: graph)
        } else {
            routeLandmarks = []
            routeEvidenceMatcher = nil
        }
        random = SeededRandom(seed: seed)
    }

    /// Read-only recording snapshot. Never consumes random state or changes
    /// the filter, so diagnostics do not affect deterministic replay.
    func diagnostic(at time: Double) -> EngineDiagnostic {
        var groups: [Int: [Particle]] = [:]
        var squaredWeights = 0.0
        for particle in particles {
            groups[particle.position.edge, default: []].append(particle)
            squaredWeights += particle.weight * particle.weight
        }
        var hypotheses: [RoadHypothesis] = []
        for (edge, candidates) in groups {
            var weight = 0.0
            var distance = 0.0
            var speed = 0.0
            var accelerationBias = 0.0
            var gyroBias = 0.0
            for candidate in candidates {
                weight += candidate.weight
                distance += candidate.position.distance * candidate.weight
                speed += candidate.speed * candidate.weight
                accelerationBias += candidate.accelerationBias * candidate.weight
                gyroBias += candidate.gyroBias * candidate.weight
            }
            guard weight > 0 else {
                continue
            }
            hypotheses.append(RoadHypothesis(edge: edge, probability: weight, distance: distance / weight, speed: speed / weight, accelerationBias: accelerationBias / weight, gyroBias: gyroBias / weight))
        }
        hypotheses.sort { first, second in
            if first.probability == second.probability {
                return first.edge < second.edge
            }
            return first.probability > second.probability
        }
        return EngineDiagnostic(time: time, particleCount: particles.count, effectiveParticleCount: 1 / max(1e-12, squaredWeights), confirmedStopped: confirmedStopped, unanchoredMovingTime: unanchoredMovingTime, headingMismatchTime: mismatchTime, turnIntegral: turnIntegral, roadHypotheses: Array(hypotheses.prefix(24)), stopEvidence: stopEvidence)
    }

    public func start(at position: RoadPosition, uncertainty: Double = 8) {
        initialUncertainty = max(8, uncertainty)
        let heading = graph.edges[position.edge].heading(at: position.distance)
        particles = []
        // Cross all four sign choices within each group. Heading evidence then
        // cannot favor an acceleration-bias sign through an accidental initial
        // sample correlation. Keep each marginal's configured variance intact.
        let groupCount = population / 16
        let positionNoise = initialNoiseMagnitudes(count: groupCount)
        let headingNoise = initialNoiseMagnitudes(count: groupCount)
        let accelerationNoise = initialNoiseMagnitudes(count: groupCount)
        let gyroNoise = initialNoiseMagnitudes(count: groupCount)
        for index in 0..<population {
            let group = index / 16
            var positionOffset = positionNoise[group] * initialUncertainty / 2
            var headingOffset = headingNoise[group] * 0.035
            var accelerationBias = accelerationNoise[group] * 0.025
            var gyroBias = gyroNoise[group] * 0.001
            if index & 1 != 0 {
                positionOffset = -positionOffset
            }
            if index & 2 != 0 {
                headingOffset = -headingOffset
            }
            if index & 4 != 0 {
                accelerationBias = -accelerationBias
            }
            if index & 8 != 0 {
                gyroBias = -gyroBias
            }
            let distance = clamp(position.distance + positionOffset, 0, graph.edges[position.edge].length)
            particles.append(Particle(position: RoadPosition(edge: position.edge, distance: distance), speed: 0, heading: heading + headingOffset, accelerationBias: accelerationBias, gyroBias: gyroBias, weight: 1 / Double(population)))
        }
        previousTime = nil
        reportTime = 0
        lastAnchorTime = 0
        started = false
        confirmedStopped = true
        quietTime = 0
        stopEvidence = nil
        stopHistory = []
        lastStopCorrection = nil
        acceptMotionReference = false
        motionWindow = []
        brakingTime = -.infinity
        totalDistance = 0
        turnIntegral = 0
        turnQuietTime = 0
        completedTurn = 0
        completedTurnTime = -.infinity
        turnStartPosition = nil
        pendingTurn = nil
        turnMotionHistory = TurnMotionHistory()
        landmarkUncertainty = nil
        lastTimedLandmark = nil
        lastVisualSpeedTime = nil
        latestVisualObservation = nil
        visualStopStart = nil
        visualStopCount = 0
        lastVibrationTime = nil
        latestVibration = nil
        speedCorrectionCount = 0
        lastSpeedCorrection = nil
        speedDisagreementActive = false
        vibrationStopStart = nil
        vibrationMoveStart = nil
        wheelbaseCalibrator = WheelbaseCalibrator(prior: wheelbasePrior)
        nextSignalID = 0
        roadSignals = []
        routeEvidenceEvents = []
        pendingRouteFeature = nil
        lastRouteEvidenceEnd = nil
        lastRouteEvidenceTurnEndTime = nil
        routeEvidenceUncertainty = nil
        travelHistory = []
        bendHoldTravel = 0
        bendGateReleaseRemaining = 0
        blockedRestrictionEdge = nil
        lastRoadUpdate = nil
        pendingCurvatureEvidence = nil
        expectedRouteLandmarkIndex = 0
        routeEvidenceMatcher?.start(at: nil)
        if let routeIndex, let startOffset = routeIndex.offset(of: position) {
            while expectedRouteLandmarkIndex < routeLandmarks.count,
                  routeLandmarks[expectedRouteLandmarkIndex].end <= startOffset + 5 {
                expectedRouteLandmarkIndex += 1
            }
        }
        anchors = 0
        lastAnchorDistance = 0
        mismatchTime = 0
        frozen = false
        unanchoredMovingTime = 0
        vibrationMeasuredTime = 0
        speedVarianceIntegral = 0
        estimate = TrackingEstimate(time: 0, position: position, coordinate: graph.coordinate(position), heading: heading, speed: 0, uncertainty: initialUncertainty, roadProbability: 1, status: "Ready to move", anchorCount: 0, turnDegrees: 0, travelled: 0, alternatives: [], needsReset: false)
    }

    /// This is an explicit user observation, never inferred from quiet IMU alone.
    public func confirmStop(resetMotionCalibration: Bool = false) {
        latestVisualObservation = nil
        visualStopStart = nil
        visualStopCount = 0
        latestVibration = nil
        vibrationStopStart = nil
        vibrationMoveStart = nil
        lastVibrationTime = previousTime
        lastVisualSpeedTime = previousTime
        // The longer departure window may still contain the preceding braking.
        // Bias calibration retains its original two-second settled interval.
        var window: [(sample: MotionSample, duration: Double)] = []
        var duration = 0.0
        for item in motionWindow.reversed() {
            let remaining = 2 - duration
            if remaining <= 0 {
                break
            }
            let included = min(item.duration, remaining)
            window.append((item.sample, included))
            duration += included
        }
        if resetMotionCalibration {
            // The upstream coordinate/bias reference changed. Old residuals
            // cannot be applied to the newly calibrated samples a second time.
            for index in particles.indices {
                particles[index].accelerationBias = 0
                particles[index].gyroBias = 0
            }
            acceptMotionReference = true
            turnMotionHistory = TurnMotionHistory()
        } else if duration >= 1 {
            let acceleration = window.reduce(0.0) { total, item in
                return total + item.sample.forwardAcceleration * item.duration / duration
            }
            let variance = window.reduce(0.0) { total, item in
                return total + pow(item.sample.forwardAcceleration - acceleration, 2) * item.duration / duration
            }
            let yawBias = window.reduce(0.0) { total, item in
                return total + item.sample.yawRate * item.duration / duration
            }
            let settled = window.allSatisfy { item in
                return abs(item.sample.yawRate) < 0.025 && abs(item.sample.verticalAcceleration) < 0.2
            }
            // Learn the residual bias only from an explicit stopped observation
            // with a settled preceding interval, not from quiet coasting.
            if settled && abs(acceleration) < 0.15 && sqrt(variance) < 0.03 {
                for index in particles.indices {
                    particles[index].accelerationBias = acceleration
                    particles[index].gyroBias = yawBias
                }
            }
        }
        setStopped()
        motionWindow.removeAll(keepingCapacity: true)
        estimate?.speed = 0
        estimate?.status = "Stopped"
    }

    private func setStopped() {
        confirmedStopped = true
        lastTimedLandmark = nil
        quietTime = 0
        brakingTime = -.infinity
        stopHistory.removeAll(keepingCapacity: true)
        // Retain measurements across an inferred stop. A subsequent explicit
        // confirmation needs the settled interval to learn residual bias.
        for index in particles.indices {
            particles[index].speed = 0
            particles[index].curvatureReference = nil
        }
    }

    /// An auxiliary observation changes velocity only. Road weights, positions,
    /// and bias remain owned by the inertial/geometry engine.
    func applyVisualSpeed(_ observation: VisualSpeedObservation) -> (accepted: Bool, reason: String, before: Double, after: Double) {
        let before = particles.reduce(0.0) { total, particle in
            return total + particle.speed * particle.weight
        }
        guard !particles.isEmpty, !frozen, let previousTime else {
            return (false, "engine_unavailable", before, before)
        }
        guard observation.time.isFinite, observation.speed.isFinite,
              observation.uncertainty.isFinite, observation.quality.isFinite else {
            return (false, "invalid_visual_observation", before, before)
        }
        guard abs(observation.time - previousTime) <= 0.6 else {
            return (false, "stale_visual_observation", before, before)
        }
        if let lastVisualSpeedTime, observation.time <= lastVisualSpeedTime {
            return (false, "out_of_order_visual_observation", before, before)
        }
        guard observation.speed >= 0, observation.speed <= 55,
              observation.uncertainty >= 1, observation.uncertainty <= 20,
              observation.quality >= 0.2, observation.quality <= 1 else {
            return (false, "low_quality_visual_observation", before, before)
        }
        let previousVisualTime = lastVisualSpeedTime
        lastVisualSpeedTime = observation.time
        latestVisualObservation = observation
        if observation.speed < Self.stopSpeedLimit, observation.quality >= 0.4, observation.uncertainty <= 1.5 {
            if visualStopStart == nil || observation.time - (previousVisualTime ?? -.infinity) > 0.5 {
                visualStopStart = observation.time
                visualStopCount = 0
            }
            visualStopCount = min(100, visualStopCount + 1)
        } else {
            visualStopStart = nil
            visualStopCount = 0
        }
        if confirmedStopped {
            return (true, "accepted_stop_observation", before, before)
        }
        let gain = min(0.18, observation.quality * 0.18 / (1 + observation.uncertainty / 8))
        for index in particles.indices {
            let residual = observation.speed - particles[index].speed
            let correction = clamp(residual * gain, -1.5, 1.5)
            particles[index].speed = clamp(particles[index].speed + correction, 0, 65)
        }
        let after = particles.reduce(0.0) { total, particle in
            return total + particle.speed * particle.weight
        }
        // The display uses the selected continuous road, as normal publication
        // does. Averaging rival roads here would restore the old mismatch.
        if let position = estimate?.position {
            let path = graph.pathIndex[position.edge]
            var mass = 0.0
            var velocity = 0.0
            for particle in particles where graph.pathIndex[particle.position.edge] == path {
                mass += particle.weight
                velocity += particle.speed * particle.weight
            }
            if mass > 0 {
                estimate?.speed = velocity / mass
            }
        }
        return (true, "accepted_auxiliary_speed", before, after)
    }

    private func visualMotionEvidence(at time: Double) -> (stopped: Bool, moving: Bool, nearZero: Bool) {
        guard let observation = latestVisualObservation,
              abs(time - observation.time) <= 0.5, observation.quality >= 0.4,
              observation.uncertainty <= 1.5 else {
            return (false, false, false)
        }
        let nearZero = observation.speed < Self.stopSpeedLimit
        var stopped = false
        if let visualStopStart, visualStopCount >= 8, observation.time - visualStopStart >= 2 {
            stopped = nearZero
        }
        return (stopped, !nearZero, nearZero)
    }

    /// Wheelbase evidence from earlier drives; applies from the next `start`.
    public func seedWheelbaseCalibration(_ evidence: WheelbaseEvidence) {
        wheelbasePrior = evidence
        wheelbaseCalibrator = WheelbaseCalibrator(prior: evidence)
    }

    /// Pooled wheelbase evidence, including this drive's matched turns.
    public var wheelbaseEvidence: WheelbaseEvidence {
        return wheelbaseCalibrator.evidence
    }

    func drainWheelbaseCalibrationEvents() -> [WheelbaseCalibrationEvent] {
        return wheelbaseCalibrator.drainEvents()
    }

    /// Absolute speed from the axle-echo vibration filter. Unlike a gain-based
    /// nudge, reweighting hypotheses by the measured speed also selects their
    /// acceleration biases, so the correction persists between observations.
    /// The likelihood is tempered because consecutive half-second observations
    /// share most of their four-second analysis window.
    func applyVibrationSpeed(_ raw: VibrationSpeedObservation) -> (accepted: Bool, reason: String, before: Double, after: Double) {
        let before = particles.reduce(0.0) { total, particle in
            return total + particle.speed * particle.weight
        }
        guard !particles.isEmpty, !frozen, let previousTime else {
            return (false, "engine_unavailable", before, before)
        }
        guard raw.time.isFinite, raw.speed.isFinite, raw.uncertainty.isFinite,
              raw.stoppedProbability.isFinite, raw.speed >= 0, raw.speed <= 45,
              raw.uncertainty >= 0, raw.wheelbase.isFinite, raw.wheelbase > 0 else {
            return (false, "invalid_vibration_observation", before, before)
        }
        guard abs(raw.time - previousTime) <= 0.6 else {
            return (false, "stale_vibration_observation", before, before)
        }
        if let lastVibrationTime, raw.time <= lastVibrationTime {
            return (false, "out_of_order_vibration_observation", before, before)
        }
        // Calibration compares raw vibration distance with mapped turn spacing;
        // the engine itself uses the speed corrected by the learned wheelbase.
        wheelbaseCalibrator.record(raw)
        let scale = appliesWheelbaseCalibration ? wheelbaseCalibrator.scale(for: raw.wheelbase) : 1
        let observation = VibrationSpeedObservation(time: raw.time, speed: raw.speed * scale, uncertainty: raw.uncertainty * scale,
                                                    stoppedProbability: raw.stoppedProbability, accelerationBias: raw.accelerationBias,
                                                    echoStrength: raw.echoStrength, rollingLevel: raw.rollingLevel,
                                                    movingProbability: raw.movingProbability, wheelbase: raw.wheelbase * scale)
        lastVibrationTime = observation.time
        latestVibration = observation
        if observation.stoppedProbability > 0.9 {
            vibrationStopStart = vibrationStopStart ?? observation.time
            vibrationMoveStart = nil
        } else if observation.stoppedProbability < 0.1 && observation.speed > 1 {
            vibrationMoveStart = vibrationMoveStart ?? observation.time
            vibrationStopStart = nil
        } else {
            vibrationStopStart = nil
            vibrationMoveStart = nil
        }
        if confirmedStopped {
            speedDisagreementActive = false
            return (true, "accepted_stop_observation", before, before)
        }
        let disagrees = observation.uncertainty <= 1 && observation.stoppedProbability < 0.1 && observation.speed > 2
            && abs(observation.speed - before) >= Self.speedCorrectionThreshold
        if disagrees, !speedDisagreementActive, observation.time - (lastSpeedCorrection?.time ?? -.infinity) >= 5 {
            speedCorrectionCount += 1
            lastSpeedCorrection = SpeedCorrection(time: observation.time, before: before, measured: observation.speed)
        }
        speedDisagreementActive = disagrees
        let sigma = max(0.6, observation.uncertainty)
        var total = 0.0
        for index in particles.indices {
            let z = (particles[index].speed - observation.speed) / sigma
            particles[index].weight *= exp(-0.25 * min(25, z * z))
            total += particles[index].weight
        }
        if total > 1e-200 && total.isFinite {
            for index in particles.indices {
                particles[index].weight /= total
                particles[index].speed = clamp(particles[index].speed + (observation.speed - particles[index].speed) * vibrationPull(sigma), 0, 65)
            }
        } else {
            // Every hypothesis disagreed: adopt the measurement instead of failing.
            for index in particles.indices {
                particles[index].weight = 1 / Double(particles.count)
                particles[index].speed = observation.speed
            }
        }
        resampleIfNeeded()
        let after = particles.reduce(0.0) { total, particle in
            return total + particle.speed * particle.weight
        }
        if let position = estimate?.position {
            let path = graph.pathIndex[position.edge]
            var mass = 0.0
            var velocity = 0.0
            for particle in particles where graph.pathIndex[particle.position.edge] == path {
                mass += particle.weight
                velocity += particle.speed * particle.weight
            }
            if mass > 0 {
                estimate?.speed = velocity / mass
            }
        }
        return (true, "accepted_vibration_speed", before, after)
    }

    /// Share of the gap to the measured speed each hypothesis closes per
    /// observation. It falls with the square of the measurement's spread: a
    /// two-mode vibration posterior reports a mean between its modes with a
    /// wide spread, and in a slow turn a fixed 10% pull toward such a mean
    /// (75 ± 36 km/h) carried the engine from 30 to 110 km/h in eight seconds.
    private func vibrationPull(_ sigma: Double) -> Double {
        return 0.1 * min(1, pow(Self.confidentVibrationSigma / sigma, 2))
    }

    /// Stop needs one second of confident parked vibration; movement needs two
    /// consecutive confident moving observations. Evidence expires after 1 s.
    private func vibrationMotionEvidence(at time: Double) -> (stopped: Bool, moving: Bool, nearZero: Bool, speed: Double) {
        guard let observation = latestVibration, abs(time - observation.time) <= 1 else {
            return (false, false, false, 0)
        }
        var stopped = false
        if let vibrationStopStart {
            stopped = observation.time - vibrationStopStart >= 1
        }
        var moving = false
        if let vibrationMoveStart {
            moving = observation.time - vibrationMoveStart >= 0.5
        }
        let nearZero = observation.speed < Self.stopSpeedLimit && observation.stoppedProbability > 0.5
        return (stopped, moving, nearZero, observation.speed)
    }

    private func correctDelayedStop(at time: Double, settledSince: Double) {
        guard let estimate else {
            return
        }
        if pendingTurn != nil || turnStartPosition != nil {
            lastStopCorrection = StopCorrection(time: time, onsetTime: nil, before: estimate.position,
                                                after: estimate.position, rewindMetres: 0, decision: "pending_road_signal")
            return
        }
        let pathIndex = graph.pathIndex[estimate.position.edge]
        let path = graph.paths[pathIndex]
        var onset: TrackingEstimate?
        // Only the latest uninterrupted low-speed interval is eligible. A
        // branch change or accepted turn invalidates all earlier candidates.
        for point in stopHistory.reversed() {
            let past = point.estimate
            guard past.time >= settledSince, time - past.time <= 5,
                  point.belowSpeedLimit, past.roadProbability >= 0.95,
                  past.anchorCount == anchors,
                  graph.pathIndex[past.position.edge] == pathIndex else {
                break
            }
            onset = past
        }
        var before = estimate.position
        var after = before
        var rewind = 0.0
        var decision = "no_supported_low_speed_history"
        if let onset {
            decision = "ambiguous_road"
            if particles.allSatisfy({ particle in
                return graph.pathIndex[particle.position.edge] == pathIndex
            }) {
                let currentDistance = particles.reduce(0.0) { total, particle in
                    return total + (graph.pathOffset[particle.position.edge] + particle.position.distance) * particle.weight
                }
                before = path.position(at: currentDistance)
                after = before
                let onsetDistance = graph.pathOffset[onset.position.edge] + onset.position.distance
                let candidate = currentDistance - onsetDistance
                let maximumRewind = min(5, Self.stopSpeedLimit * (time - onset.time) + 0.5)
                decision = "movement_exceeds_delay_bound"
                if candidate >= 0, candidate <= maximumRewind,
                   candidate <= totalDistance - onset.travelled + 0.5 {
                    decision = "path_boundary"
                    if particles.allSatisfy({ particle in
                        let distance = graph.pathOffset[particle.position.edge] + particle.position.distance
                        if let routeIndex, routeIndex.offset(of: path.position(at: distance - candidate)) == nil {
                            return false
                        }
                        return distance >= candidate
                    }) {
                        for index in particles.indices {
                            let distance = graph.pathOffset[particles[index].position.edge] + particles[index].position.distance
                            particles[index].position = path.position(at: distance - candidate)
                        }
                        rewind = candidate
                        after = path.position(at: currentDistance - rewind)
                        totalDistance = max(onset.travelled, totalDistance - rewind)
                        // As in publish: with measured speed the growth is
                        // added on top of the floor, so fold in only the rest.
                        if landmarkUncertainty != nil && vibrationMeasuredTime == 0 {
                            initialUncertainty = max(initialUncertainty, estimate.uncertainty)
                        } else {
                            initialUncertainty = max(initialUncertainty, estimate.uncertainty - motionUncertaintyGrowth())
                        }
                        decision = "applied"
                    }
                }
            }
        }
        lastStopCorrection = StopCorrection(time: time, onsetTime: onset?.time, before: before,
                                            after: after, rewindMetres: rewind, decision: decision)
    }

    /// Give a gentle departure time to accumulate its impulse. Once moving,
    /// use a shorter history so braking and explicit stop calibration stay recent.
    private func updateMotionWindow(_ sample: MotionSample, dt: Double, bias: Double) -> MotionWindowUpdate {
        motionWindow.append((sample, dt))
        var duration = motionWindow.reduce(0.0) { total, item in
            return total + item.duration
        }
        var maximumDuration = 2.0
        if confirmedStopped {
            maximumDuration = 4
        }
        while duration > maximumDuration, let first = motionWindow.first {
            let excess = duration - maximumDuration
            if first.duration <= excess {
                duration -= first.duration
                motionWindow.removeFirst()
            } else {
                motionWindow[0].duration -= excess
                duration = maximumDuration
            }
        }
        var velocityChange = 0.0
        var speed = 0.0
        var distance = 0.0
        var departureDuration = 0.0
        for item in motionWindow {
            let delta = (clamp(item.sample.forwardAcceleration, -10, 7) - bias) * item.duration
            velocityChange += delta
            let nextSpeed = max(0, speed + delta)
            if nextSpeed == 0 {
                distance = 0
                departureDuration = 0
            } else {
                distance += (speed + nextSpeed) / 2 * item.duration
                departureDuration += item.duration
            }
            speed = nextSpeed
        }
        let meanAcceleration = velocityChange / duration
        let accelerationVariance = motionWindow.reduce(0.0) { total, item in
            return total + pow(clamp(item.sample.forwardAcceleration, -10, 7) - bias - meanAcceleration, 2) * item.duration / duration
        }
        let verticalSquare = motionWindow.reduce(0.0) { total, item in
            return total + pow(item.sample.verticalAcceleration, 2) * item.duration / duration
        }
        let yawSquare = motionWindow.reduce(0.0) { total, item in
            return total + pow(item.sample.yawRate, 2) * item.duration / duration
        }
        return MotionWindowUpdate(velocityChange: velocityChange, departureSpeed: speed, distance: distance,
                                  duration: departureDuration, windowDuration: duration, meanAcceleration: meanAcceleration,
                                  accelerationStandardDeviation: sqrt(accelerationVariance), verticalRMS: sqrt(verticalSquare), yawRMS: sqrt(yawSquare))
    }

    func drainRoadSignals() -> [RoadSignalEvent] {
        let result = roadSignals
        roadSignals.removeAll(keepingCapacity: true)
        return result
    }

    func drainRouteEvidenceEvents() -> [RouteEvidenceEvent] {
        let result = routeEvidenceEvents
        routeEvidenceEvents.removeAll(keepingCapacity: true)
        return result
    }

    public func process(_ sample: MotionSample) -> TrackingEstimate? {
        guard !particles.isEmpty, !frozen, sample.time.isFinite,
              sample.forwardAcceleration.isFinite, sample.yawRate.isFinite,
              sample.lateralAcceleration.isFinite, sample.pitch.isFinite, sample.roll.isFinite else {
            return estimate
        }
        guard let previous = previousTime else {
            previousTime = sample.time
            reportTime = sample.time
            lastAnchorTime = sample.time
            routeEvidenceMatcher?.start(at: sample.time)
            previousPitch = sample.pitch
            previousRoll = sample.roll
            return estimate
        }
        let dt = sample.time - previous
        if dt <= 0 {
            return estimate
        }
        previousTime = sample.time
        if dt > 0.5 {
            return freeze("Motion data interrupted · set position again", code: .sensorGap, time: sample.time, measurements: ["gapSeconds": dt, "maximumGapSeconds": 0.5])
        }
        if acceptMotionReference {
            previousPitch = sample.pitch
            previousRoll = sample.roll
            acceptMotionReference = false
        }
        let mountChange = max(abs(angleDifference(sample.pitch, previousPitch)), abs(angleDifference(sample.roll, previousRoll)))
        let tiltRate = mountChange / dt
        previousPitch = sample.pitch
        previousRoll = sample.roll
        if tiltRate > 1.2 {
            return freeze("Phone tilt changed too quickly · remount and set position", code: .mountTilt, time: sample.time, measurements: ["tiltRateRadiansPerSecond": tiltRate, "maximumTiltRateRadiansPerSecond": 1.2])
        }
        if abs(sample.yawRate) > 1.6 {
            return freeze("Rotation too fast to track · remount and set position", code: .excessiveRotation, time: sample.time, measurements: ["yawRateRadiansPerSecond": sample.yawRate, "maximumYawRateRadiansPerSecond": 1.6])
        }

        let acceleration = clamp(sample.forwardAcceleration, -10, 7)
        turnMotionHistory.append(sample, duration: dt)
        lastTimedLandmark?.append(acceleration: acceleration, duration: dt)
        let bias = particles.reduce(0.0) { total, particle in
            return total + particle.accelerationBias * particle.weight
        }
        let recentMotion = updateMotionWindow(sample, dt: dt, bias: bias)
        // A short window tolerates engine vibration and isolated sensor spikes.
        // It is evidence of settled motion, never an absolute speed observation.
        let settled = recentMotion.windowDuration >= 1.5
            && recentMotion.accelerationStandardDeviation < 0.18 && recentMotion.yawRMS < 0.025
            && recentMotion.verticalRMS < 0.45
        let quiet = settled && abs(recentMotion.meanAcceleration) < 0.11
        let visual = visualMotionEvidence(at: sample.time)
        let vibration = vibrationMotionEvidence(at: sample.time)
        if quiet {
            quietTime += dt
        } else {
            quietTime = 0
        }
        if recentMotion.velocityChange < -0.15 {
            brakingTime = sample.time
        }
        var departing = false
        // A small DC offset can accumulate the departure impulse while all
        // sensors remain quiet. Require forward acceleration as well as impulse.
        // Very weak creeping remains stopped until there is clearer motion.
        let departureAccelerationSupported = recentMotion.meanAcceleration >= Self.minimumDepartureAcceleration
        var departureSpeed = recentMotion.departureSpeed
        if confirmedStopped {
            let inertialDeparture = departureAccelerationSupported && recentMotion.departureSpeed > 0.15 && recentMotion.duration >= 0.15
                && !(visual.stopped && settled) && !(vibration.stopped && settled)
            // Rolling vibration with a measured axle-echo speed releases a stop
            // even when creeping is too gentle for the acceleration impulse.
            let vibrationDeparture = vibration.moving && !(visual.stopped && settled)
            if inertialDeparture || vibrationDeparture {
                confirmedStopped = false
                started = true
                departing = true
                stopHistory.removeAll(keepingCapacity: true)
                if vibrationDeparture {
                    departureSpeed = max(departureSpeed, vibration.speed)
                }
            }
        }
        // A recent braking event and near-zero integrated velocity are both
        // required. Quiet constant-speed driving must never reset velocity.
        let recentBraking = sample.time - brakingTime < 5
        // Clamping each uncertain velocity hypothesis to zero raises their mean
        // even at a real stop. Require a majority near zero instead of allowing
        // that artificial positive tail to prevent stop recognition forever.
        let nearZeroProbability = particles.reduce(0.0) { total, particle in
            if particle.speed < Self.stopSpeedLimit {
                return total + particle.weight
            }
            return total
        }
        let speedBelowLimit = nearZeroProbability >= 0.5
        var stopDecision = "not_settled"
        if quietTime > 1.5 {
            stopDecision = "no_recent_braking"
            if recentBraking {
                stopDecision = "speed_above_stop_limit"
                if speedBelowLimit {
                    stopDecision = "eligible"
                }
            }
        }
        let settledSeconds = quietTime
        let inertialStop = quietTime > 1.5 && speedBelowLimit && recentBraking && !visual.moving && !vibration.moving
        let cameraStop = visual.stopped && settled
        // Parked idle vibration is two decades below rolling on every field
        // drive, so it does not depend on integrated speed or recent braking.
        let vibrationStop = vibration.stopped && settled && !visual.moving
        if !confirmedStopped && !departing && (inertialStop || cameraStop || vibrationStop) {
            var settledSince = sample.time - quietTime - recentMotion.windowDuration
            if cameraStop, let visualStopStart {
                settledSince = max(visualStopStart, sample.time - recentMotion.windowDuration)
            } else if vibrationStop, let vibrationStopStart {
                settledSince = max(vibrationStopStart - 1, sample.time - recentMotion.windowDuration)
            }
            correctDelayedStop(at: sample.time, settledSince: settledSince)
            setStopped()
            stopDecision = "automatic_stop"
            lastStopCorrection?.source = "inertial"
            if cameraStop {
                stopDecision = "automatic_camera_stop"
                lastStopCorrection?.source = "camera"
            } else if vibrationStop && !inertialStop {
                stopDecision = "automatic_vibration_stop"
                lastStopCorrection?.source = "vibration"
            }
        } else if confirmedStopped {
            stopDecision = "held_stopped"
        } else if visual.moving {
            stopDecision = "camera_observes_movement"
        } else if vibration.moving {
            stopDecision = "vibration_observes_movement"
        }
        stopEvidence = StopEvidence(meanAcceleration: recentMotion.meanAcceleration,
                                    accelerationStandardDeviation: recentMotion.accelerationStandardDeviation,
                                    verticalRMS: recentMotion.verticalRMS, yawRMS: recentMotion.yawRMS,
                                    quietSeconds: settledSeconds, recentBraking: recentBraking,
                                    speedBelowLimit: speedBelowLimit, nearZeroProbability: nearZeroProbability, decision: stopDecision,
                                    speedLimitKilometresPerHour: Self.stopSpeedLimit * 3.6,
                                    visualStopSupported: visual.stopped, visualMovementDetected: visual.moving,
                                    departureImpulseMetresPerSecond: recentMotion.departureSpeed,
                                    departureAccelerationSupported: departureAccelerationSupported,
                                    vibrationStopSupported: vibration.stopped, vibrationMovementDetected: vibration.moving)
        if abs(sample.yawRate) > 0.025 {
            if turnStartPosition == nil, let estimate {
                turnStartTime = sample.time
                turnStartPosition = estimate.position
                turnStartMapHeading = graph.edges[estimate.position.edge].heading(at: estimate.position.distance)
                turnStartUncertainty = estimate.uncertainty
            }
            turnIntegral += sample.yawRate * dt
            turnQuietTime = 0
        } else if turnStartPosition != nil {
            turnQuietTime += dt
        }
        if turnQuietTime > 0.8 {
            if abs(turnIntegral) > 0.05, let startPosition = turnStartPosition {
                completedTurn = turnIntegral
                completedTurnTime = sample.time
                if let pendingTurn {
                    recordRoadSignal(pendingTurn, time: sample.time, stage: "rejected", reason: "Superseded by another observed turn", match: lastRoadUpdate)
                }
                nextSignalID += 1
                pendingTurn = TurnObservation(id: nextSignalID, start: turnStartTime, end: sample.time - turnQuietTime, startPosition: startPosition, startMapHeading: turnStartMapHeading, angle: completedTurn, startUncertainty: turnStartUncertainty)
                evaluateRouteEvidence(at: sample.time)
            }
            turnStartPosition = nil
            turnIntegral = 0
            turnQuietTime = 0
        }
        if frozen {
            return estimate
        }

        let roughness = min(4, abs(sample.verticalAcceleration) + sample.gravityError * 8)
        if !confirmedStopped {
            unanchoredMovingTime += dt
            if let vibration = latestVibration, abs(sample.time - vibration.time) <= 1 {
                vibrationMeasuredTime += dt
                speedVarianceIntegral += pow(max(0.2, vibration.uncertainty), 2) * dt
            }
        }
        // Mounting geometry is already removed by VehicleMotionProjection.
        // Only a changing tilt contributes additional motion uncertainty.
        let tiltNoise = tiltRate * 0.12
        blockedRestrictionEdge = nil
        var updated: [Particle] = []
        var predictionSum = Vector2(0, 0)
        var predictionWeight = 0.0
        var strongestCurvatureEvidence: (weight: Double, evidence: CurvatureEvidence)?
        let bendGateActive = route != nil && bendGateReleaseRemaining <= 0
        var heldWeight = 0.0
        var heldMovement = 0.0
        let totalWeight = particles.reduce(0.0) { total, particle in
            return total + particle.weight
        }
        let weights = particles.map { particle in
            return particle.weight
        }
        let accelerationNoise = centeredNoise(weights: weights)
        let gyroNoise = centeredNoise(weights: weights)
        let velocityNoise = centeredNoise(weights: weights)
        for (index, original) in particles.enumerated() {
            var particle = original
            particle.accelerationBias += accelerationNoise[index] * Self.accelerationBiasWalk * sqrt(dt)
            particle.gyroBias += gyroNoise[index] * 0.00004 * sqrt(dt)
            particle.heading += (sample.yawRate - particle.gyroBias) * dt
            // A measured U-turn can switch to the opposite directed edge at
            // the same physical position. This requires an actual opposite
            // carriageway direction in the graph, not a nearby parallel road.
            if route == nil, abs(turnIntegral) > 2.4, let reverse = graph.reverse(particle.position) {
                let originalHeading = graph.edges[particle.position.edge].heading(at: particle.position.distance)
                let reverseHeading = graph.edges[reverse.edge].heading(at: reverse.distance)
                if abs(angleDifference(particle.heading, reverseHeading)) < abs(angleDifference(particle.heading, originalHeading)) {
                    particle.position = reverse
                    lastTimedLandmark = nil
                }
            }
            if confirmedStopped {
                particle.speed = 0
            } else if departing {
                particle.speed = max(0, departureSpeed - (particle.accelerationBias - bias) * recentMotion.duration)
            } else {
                particle.speed += (acceleration - particle.accelerationBias) * dt
                particle.speed += velocityNoise[index] * (0.07 + roughness * 0.05 + tiltNoise) * sqrt(dt)
                // Braking and bias can overshoot zero. Keep the forward-only
                // state physically bounded instead of treating that numerical
                // overshoot as proof that the vehicle has reversed.
                particle.speed = clamp(particle.speed, 0, 65)
            }
            var movement = max(0, particle.speed) * dt
            if departing {
                movement = recentMotion.distance
            }
            var predictions = advance(particle, metres: movement)
            if bendGateActive, !departing, movement > 0 {
                predictions = predictions.map { prediction in
                    guard let held = holdBeforeUnturnedBend(original: particle, prediction: prediction) else {
                        return prediction
                    }
                    heldWeight += held.weight
                    heldMovement += held.weight * movement
                    return held
                }
            }
            for var prediction in predictions {
                predictionSum = predictionSum + graph.coordinate(prediction.position).metres * prediction.weight
                predictionWeight += prediction.weight
                let edge = graph.edges[prediction.position.edge]
                let pathIndex = graph.pathIndex[prediction.position.edge]
                let path = graph.paths[pathIndex]
                let pathDistance = graph.pathOffset[prediction.position.edge] + prediction.position.distance
                let span = max(12, prediction.speed * 1.2)
                let continuousHeading = path.heading(at: pathDistance, span: span, roads: graph.edges)
                let mapHeading = continuousHeading ?? edge.heading(at: prediction.position.distance, span: span)
                let nearJunction = min(pathDistance, path.length - pathDistance) < 18
                var headingSigma = 0.23 + roughness * 0.03
                if nearJunction {
                    headingSigma = 0.70
                }
                let residual = angleDifference(prediction.heading, mapHeading)
                if movement > 0.005 {
                    prediction.weight *= exp(-0.5 * pow(residual / headingSigma, 2) * dt * 1.2)
                }
                // Require a mapped bend in the observed direction before using
                // lateral acceleration / yaw as a speed cue. A brief lane change
                // on a straight road must not recalibrate the speed population.
                if abs(sample.yawRate) > 0.055 && abs(sample.lateralAcceleration) > 0.3 && roughness < 0.7,
                   let curvature = path.curvature(at: pathDistance, span: span, roads: graph.edges),
                   curvature * sample.yawRate > 0, abs(curvature * prediction.speed) > 0.025 {
                    let turnSpeed = sample.lateralAcceleration / sample.yawRate
                    if turnSpeed > 1 && turnSpeed < 45 {
                        let sigma = max(3, turnSpeed * 0.35)
                        prediction.weight *= exp(-0.5 * pow((prediction.speed - turnSpeed) / sigma, 2) * dt * 0.6)
                    }
                }
                if let evidence = scoreCurvature(&prediction, sample: sample, dt: dt, path: pathIndex, mapHeading: continuousHeading, roughness: roughness, tiltRate: tiltRate) {
                    if prediction.weight > (strongestCurvatureEvidence?.weight ?? -.infinity) {
                        strongestCurvatureEvidence = (prediction.weight, evidence)
                    }
                }
                updated.append(prediction)
            }
        }
        if let strongestCurvatureEvidence {
            pendingCurvatureEvidence = strongestCurvatureEvidence.evidence
        }
        updateBendHold(heldShare: heldWeight / max(1e-300, totalWeight),
                       heldMovement: heldMovement / max(1e-300, heldWeight), dt: dt)
        guard !updated.isEmpty else {
            if let blockedRestrictionEdge {
                let road = graph.edges[blockedRestrictionEdge].record
                return freeze("Offline map has conflicting turn rules · set position beyond this junction", code: .mapRestrictionConflict, time: sample.time, measurements: ["edge": Double(blockedRestrictionEdge), "way": Double(road.way), "junctionNode": Double(road.to)])
            }
            return freeze("Road ended · set position again", code: .roadEnded, time: sample.time)
        }
        particles = updated
        normalize()
        if frozen {
            return estimate
        }
        if particles.count > population * 4 {
            resampleIfNeeded()
        }
        if sample.time - reportTime >= 0.2 || stopDecision.hasPrefix("automatic_") {
            let elapsed = sample.time - reportTime
            reportTime = sample.time
            let beforeEvidence = Coordinate(metres: predictionSum * (1 / max(1e-100, predictionWeight)))
            publish(sample, elapsed: elapsed, beforeEvidence: beforeEvidence)
            resampleIfNeeded()
        }
        return estimate
    }

    /// Consecutive disjoint intervals preserve the order of bends, their onset
    /// and their end. A six-second interval reduces sensitivity to short steering
    /// reversals. Each particle retains its actual past state, so changing speed
    /// is not approximated by projecting today's speed backwards.
    private func scoreCurvature(_ particle: inout Particle, sample: MotionSample, dt: Double, path: Int, mapHeading: Double?, roughness: Double, tiltRate: Double) -> CurvatureEvidence? {
        guard !confirmedStopped, particle.speed > 2,
              tiltRate < 0.3, abs(sample.yawRate) < 0.6, let mapHeading else {
            particle.curvatureReference = nil
            return nil
        }
        let current = CurvatureReference(time: sample.time, path: path, position: particle.position,
                                         mapHeading: mapHeading, inertialHeading: particle.heading, speed: particle.speed)
        guard var reference = particle.curvatureReference, reference.path == path else {
            particle.curvatureReference = current
            return nil
        }
        reference.roughnessIntegral += roughness * dt
        particle.curvatureReference = reference
        let duration = sample.time - reference.time
        guard duration >= 6 else {
            return nil
        }
        particle.curvatureReference = current
        let observed = angleDifference(particle.heading, reference.inertialHeading)
        let mapped = angleDifference(mapHeading, reference.mapHeading)
        // A straight path supplies no along-road curvature observation. In
        // particular, a lane change on it must not become a curvature score
        // merely because the phone observed yaw. Heading matching still applies.
        guard abs(mapped) > 0.01 else {
            return nil
        }
        let residual = angleDifference(observed, mapped)
        // A car can briefly point across the road while changing lanes. Model
        // that unknown heading offset as nuisance motion: a 2.2 m/s lateral
        // component covers the peak of a smooth 3.5 m, three-second lane change.
        // It is a tolerance, not a detector or a claimed physical upper bound.
        // Slow lane changes are especially ambiguous, so they get less weight.
        let averageRoughness = reference.roughnessIntegral / duration
        let geometrySigma = 0.012 + 0.002 * duration + 0.20 * max(abs(observed), abs(mapped)) + averageRoughness * 0.015
        let laneTolerance = atan2(2.2, max(5, min(reference.speed, particle.speed)))
        let sigma = hypot(geometrySigma, laneTolerance)
        let multiplier = exp(-min(4, 0.5 * pow(residual / sigma, 2)) * 0.6)
        particle.weight *= multiplier
        return CurvatureEvidence(startTime: reference.time, endTime: sample.time,
                                 startPosition: reference.position, endPosition: particle.position,
                                 observedDegrees: observed * 180 / .pi, mappedDegrees: mapped * 180 / .pi,
                                 residualDegrees: residual * 180 / .pi, sigmaDegrees: sigma * 180 / .pi,
                                 weightMultiplier: multiplier, laneToleranceDegrees: laneTolerance * 180 / .pi)
    }

    /// A car cannot be past a bend it has not turned through. On the selected
    /// route a particle whose measured heading still matches its current road
    /// does not advance onto road pointing 35° or more away from that heading;
    /// it waits at the bend until the gyro shows the turn. Without this a
    /// cloud that ran ahead moved on past the bend, because every particle was
    /// equally wrong and reweighting cannot move them back. Returns nil when
    /// the particle may advance.
    private func holdBeforeUnturnedBend(original: Particle, prediction: Particle) -> Particle? {
        guard let before = gateHeading(at: original.position), let after = gateHeading(at: prediction.position) else {
            return nil
        }
        let residualBefore = abs(angleDifference(prediction.heading, before))
        let residualAfter = abs(angleDifference(prediction.heading, after))
        guard residualAfter >= Self.bendGateAngle, residualAfter - residualBefore >= Self.bendGateAngle / 2 else {
            return nil
        }
        var held = prediction
        held.position = original.position
        return held
    }

    /// The hold is shared by the whole estimate and capped at 120 m of
    /// driving, so a map geometry error or heading drift cannot stall it.
    /// Releasing particles one by one would let the held ones outweigh the
    /// released ones (which face the wrong way) and favour the slowest, so the
    /// gate then opens for everyone for the next 80 m.
    private func updateBendHold(heldShare: Double, heldMovement: Double, dt: Double) {
        if bendGateReleaseRemaining > 0 {
            bendGateReleaseRemaining -= max(0, estimate?.speed ?? 0) * dt
            return
        }
        if heldShare >= 0.5 {
            bendHoldTravel += heldMovement
            if bendHoldTravel > Self.maximumBendHold {
                bendHoldTravel = 0
                bendGateReleaseRemaining = Self.bendGateRelease
            }
        } else if heldShare == 0 {
            bendHoldTravel = 0
        }
    }

    private static let bendGateAngle = 35.0 * .pi / 180
    private static let maximumBendHold = 120.0
    private static let bendGateRelease = 80.0

    private func gateHeading(at position: RoadPosition) -> Double? {
        let path = graph.paths[graph.pathIndex[position.edge]]
        let distance = graph.pathOffset[position.edge] + position.distance
        return path.heading(at: distance, span: 12, roads: graph.edges)
            ?? graph.edges[position.edge].heading(at: position.distance, span: 12)
    }

    private func advance(_ particle: Particle, metres: Double) -> [Particle] {
        var candidate = particle
        candidate.position.distance += metres
        var active = [candidate]
        var result: [Particle] = []
        for _ in 0..<12 {
            var next: [Particle] = []
            for item in active {
                let edge = graph.edges[item.position.edge]
                if let route, item.position.edge == route.destination.edge,
                   item.position.distance >= route.destination.distance {
                    var endpoint = item
                    endpoint.position = route.destination
                    result.append(endpoint)
                    continue
                }
                if item.position.distance <= edge.length {
                    result.append(item)
                    continue
                }
                var successors = graph.successors(of: item.position.edge)
                if route != nil {
                    successors = []
                    if let next = routeSuccessors[item.position.edge] {
                        successors = [next]
                    }
                }
                if successors.isEmpty && graph.hasConflictingOnlyRestrictions(of: item.position.edge) {
                    blockedRestrictionEdge = item.position.edge
                }
                // A straight-moving candidate must not lose most of its mass
                // merely because it crossed a junction with side roads. Use
                // its inertial heading to distribute mass among legal exits.
                let logWeights = successors.map { index in
                    let heading = graph.edges[index].heading(at: 0)
                    let residual = angleDifference(item.heading, heading)
                    return -0.5 * pow(residual / 0.35, 2)
                }
                let greatestLogWeight = logWeights.max() ?? 0
                let weights = logWeights.map { value in
                    return exp(value - greatestLogWeight)
                }
                let totalWeight = weights.reduce(0, +)
                for (offset, index) in successors.enumerated() {
                    var branch = item
                    branch.position = RoadPosition(edge: index, distance: item.position.distance - edge.length)
                    branch.weight *= weights[offset] / totalWeight
                    next.append(branch)
                }
            }
            if next.count > 32 {
                next.sort { first, second in
                    let firstHeading = graph.edges[first.position.edge].heading(at: first.position.distance)
                    let secondHeading = graph.edges[second.position.edge].heading(at: second.position.distance)
                    return abs(angleDifference(first.heading, firstHeading)) < abs(angleDifference(second.heading, secondHeading))
                }
                next = Array(next.prefix(32))
            }
            active = next
            if active.isEmpty {
                break
            }
        }
        return result
    }

    private func normalize() {
        let sum = particles.reduce(0.0) { total, particle in
            return total + particle.weight
        }
        if sum < 1e-100 || !sum.isFinite {
            var measurements: [String: Double] = [:]
            if sum.isFinite {
                measurements["totalParticleWeight"] = sum
            }
            _ = freeze("No reliable road match · set position", code: .noRoadMatch, time: previousTime ?? 0, measurements: measurements)
            return
        }
        for index in particles.indices {
            particles[index].weight /= sum
        }
    }

    private func publish(_ sample: MotionSample, elapsed: Double, beforeEvidence: Coordinate,
                         landmarkCorrection: LandmarkCorrection? = nil, landmarkReason: String? = nil) {
        let previousEstimate = estimate
        var groups: [Int: Double] = [:]
        for particle in particles {
            groups[graph.pathIndex[particle.position.edge], default: 0] += particle.weight
        }
        guard let bestGroup = groups.max(by: { first, second in
            if first.value == second.value {
                return first.key > second.key
            }
            return first.value < second.value
        }) else {
            return
        }
        var distance = 0.0
        var speed = 0.0
        var sine = 0.0
        var cosine = 0.0
        for particle in particles {
            if graph.pathIndex[particle.position.edge] == bestGroup.key {
                let pathDistance = graph.pathOffset[particle.position.edge] + particle.position.distance
                distance += pathDistance * particle.weight / bestGroup.value
                speed += particle.speed * particle.weight / bestGroup.value
                sine += sin(particle.heading) * particle.weight
                cosine += cos(particle.heading) * particle.weight
            }
        }
        var position = graph.paths[bestGroup.key].position(at: distance)
        if let routeIndex, routeIndex.offset(of: position) == nil {
            // A route can leave and later rejoin the same continuous map path.
            // Averaging those separated hypotheses must not display a point
            // on a section which the selected route never visits.
            if let representative = particles.filter({ particle in
                return graph.pathIndex[particle.position.edge] == bestGroup.key
            }).max(by: { first, second in
                return first.weight < second.weight
            }) {
                position = representative.position
            }
        }
        let coordinate = graph.coordinate(position)
        var spatialVariance = 0.0
        for particle in particles {
            let offset = graph.coordinate(particle.position).metres - coordinate.metres
            spatialVariance += offset.dot(offset) * particle.weight
        }
        let advancedDistance = totalDistance + max(0, speed) * elapsed
        let heading = atan2(sine, cosine)
        let edge = graph.edges[position.edge]
        let headingError = abs(angleDifference(heading, edge.heading(at: position.distance)))
        var acceptedTurn = false
        var mappedTurn = 0.0
        if let pendingTurn {
            mappedTurn = angleDifference(edge.heading(at: position.distance), pendingTurn.startMapHeading)
        }
        let turnResidual = abs(angleDifference(completedTurn, mappedTurn))
        var expectedRouteTurnMatched = false
        if let pendingTurn, expectedRouteLandmarkIndex < routeLandmarks.count {
            let landmark = routeLandmarks[expectedRouteLandmarkIndex]
            expectedRouteTurnMatched = routeTurnMatches(pendingTurn.angle, landmark: landmark)
                && sample.time - completedTurnTime < 6
                && bestGroup.value > 0.72
                && headingError < 0.35
                && spatialVariance < 900
        }
        let routeEvidenceMatched = pendingRouteFeature != nil
        let angleMatched = routeEvidenceMatched || (pendingTurn != nil && abs(completedTurn) > 0.3 && sample.time - completedTurnTime < 6 && bestGroup.value > 0.72 && spatialVariance < 900
            && ((abs(mappedTurn) > 0.2 && turnResidual < 0.3 && headingError < 0.22 && advancedDistance - lastAnchorDistance > 20)
                || expectedRouteTurnMatched))
        var acceptedReason = landmarkReason ?? "Angle match only; prior position uncertainty retained"
        if routeEvidenceMatched {
            acceptedReason = "Selected-route feature matched; route position correction applied"
        }
        if angleMatched, landmarkCorrection == nil, let turn = pendingTurn {
            let result = applyTurnLandmark(turn, sample: sample, path: bestGroup.key, probability: bestGroup.value, speed: speed)
            // A route-feature match already moved the estimate; the timed
            // junction's "angle match only" outcome must not overwrite that.
            if result.correction != nil || !routeEvidenceMatched {
                acceptedReason = result.reason
            }
            if let correction = result.correction {
                // Recompute the displayed posterior once, before advancing any
                // publication counters or emitting events for this timestamp.
                publish(sample, elapsed: elapsed, beforeEvidence: beforeEvidence,
                        landmarkCorrection: correction, landmarkReason: acceptedReason)
                return
            }
        }
        totalDistance = advancedDistance
        travelHistory.append((sample.time, totalDistance))
        travelHistory.removeAll { point in
            return sample.time - point.time > TurnMotionHistory.retention
        }
        if angleMatched || landmarkCorrection != nil {
            anchors += 1
            lastAnchorTime = sample.time
            lastAnchorDistance = totalDistance
            // Matching a road direction does not independently measure our
            // distance from the junction. Preserve the error accumulated before
            // the match instead of claiming a fresh eight-metre position fix.
            if routeEvidenceMatched {
                resetMotionUncertaintyGrowth()
                initialUncertainty = routeEvidenceUncertainty ?? max(10, min(initialUncertainty, 22))
                routeEvidenceUncertainty = nil
            } else if landmarkCorrection == nil, let previousEstimate {
                if landmarkUncertainty != nil && vibrationMeasuredTime == 0 {
                    initialUncertainty = max(initialUncertainty, previousEstimate.uncertainty)
                } else {
                    initialUncertainty = max(initialUncertainty, previousEstimate.uncertainty - motionUncertaintyGrowth())
                }
            }
            acceptedTurn = true
            if !routeEvidenceMatched {
                completeExpectedRouteLandmark()
            }
        }
        var uncertaintyFloor = initialUncertainty
        if vibrationMeasuredTime > 0 {
            // Measured speed replaces the landmark's propagated speed/bias spread.
            uncertaintyFloor += motionUncertaintyGrowth()
        } else if let landmarkUncertainty {
            uncertaintyFloor = max(initialUncertainty, landmarkUncertainty.radius(after: unanchoredMovingTime))
        } else if started {
            // Retain a model-error floor even if resampling makes particles
            // appear tightly clustered on a featureless straight road.
            uncertaintyFloor += motionUncertaintyGrowth()
        }
        let uncertainty = max(uncertaintyFloor, sqrt(spatialVariance) * 2)
        var status = "Tracking"
        if confirmedStopped {
            status = "Stopped"
            if !started {
                status = "Waiting for forward movement"
            }
        } else if bestGroup.value < 0.65 || uncertainty > Self.uncertainStatusRadius || headingError > 0.45 {
            status = "Position uncertain"
        }
        if headingError > 0.8 && speed > 2 && route == nil {
            mismatchTime += elapsed
        } else {
            mismatchTime = max(0, mismatchTime - elapsed)
        }
        let alternatives = groups.sorted { first, second in
            return first.value > second.value
        }.prefix(4).compactMap { group -> Coordinate? in
            guard group.key != bestGroup.key else {
                return nil
            }
            let subset = particles.filter { particle in
                return graph.pathIndex[particle.position.edge] == group.key
            }
            let offset = subset.reduce(0.0) { total, particle in
                let pathDistance = graph.pathOffset[particle.position.edge] + particle.position.distance
                return total + pathDistance * particle.weight / group.value
            }
            return graph.coordinate(graph.paths[group.key].position(at: offset))
        }
        estimate = TrackingEstimate(time: sample.time, position: position, coordinate: coordinate, heading: heading, speed: max(0, speed), uncertainty: uncertainty, roadProbability: bestGroup.value, status: status, anchorCount: anchors, turnDegrees: turnIntegral * 180 / .pi, travelled: totalDistance, alternatives: alternatives, needsReset: false)
        if !confirmedStopped, let estimate {
            let nearZero = stopEvidence?.speedBelowLimit == true || visualMotionEvidence(at: sample.time).nearZero
                || vibrationMotionEvidence(at: sample.time).nearZero
            stopHistory.append(StopHistoryPoint(estimate: estimate, belowSpeedLimit: nearZero))
            stopHistory.removeAll { point in
                return sample.time - point.estimate.time > 8
            }
            if stopHistory.count > 64 {
                stopHistory.removeFirst(stopHistory.count - 64)
            }
        }
        if let estimate {
            let adjustment = coordinate.metres - beforeEvidence.metres
            lastRoadUpdate = RoadMatchUpdate(time: sample.time, predictionBeforeRoadEvidence: beforeEvidence, previousEstimate: previousEstimate, result: estimate, adjustmentEastMetres: adjustment.x, adjustmentNorthMetres: adjustment.y, positionAdjustmentMetres: adjustment.length, headingResidualDegrees: headingError * 180 / .pi, curvatureEvidence: pendingCurvatureEvidence, landmarkCorrection: landmarkCorrection)
            pendingCurvatureEvidence = nil
        }
        if var turn = pendingTurn {
            if !turn.reported {
                recordRoadSignal(turn, time: sample.time, stage: "detected", reason: "Gyroscope turn completed; checking road geometry", match: lastRoadUpdate)
                turn.reported = true
                pendingTurn = turn
            }
            if acceptedTurn {
                recordRoadSignal(turn, time: sample.time, stage: "accepted", reason: acceptedReason, match: lastRoadUpdate)
                pendingTurn = nil
                pendingRouteFeature = nil
                completedTurn = 0
            } else if abs(turn.angle) <= 0.3 || sample.time - completedTurnTime >= 6 {
                var reason = "Road hypothesis or position spread remained ambiguous"
                if abs(turn.angle) <= 0.3 {
                    reason = "Observed angle is below the turn-anchor threshold"
                } else if abs(mappedTurn) <= 0.2 || turnResidual >= 0.3 {
                    reason = "Observed angle does not match the traversed road geometry"
                } else if headingError >= 0.22 {
                    reason = "Heading does not agree with the candidate road"
                } else if totalDistance - lastAnchorDistance <= 20 {
                    reason = "Too close to the preceding anchor"
                }
                recordRoadSignal(turn, time: sample.time, stage: "rejected", reason: reason, match: lastRoadUpdate)
                pendingTurn = nil
                pendingRouteFeature = nil
                completedTurn = 0
            }
        }
        if let route, position.edge == route.destination.edge,
           position.distance >= route.destination.distance - 0.1 {
            _ = freeze("Route end estimated · reset starting point", code: .routeEnded, time: sample.time)
        } else if route == nil && mismatchTime > 5 {
            _ = freeze("Heading no longer matches the road · set position", code: .headingMismatch, time: sample.time, measurements: ["headingErrorDegrees": headingError * 180 / .pi, "mismatchSeconds": mismatchTime, "maximumMismatchSeconds": 5])
        } else if uncertainty > maximumUncertainty {
            _ = freeze("Position uncertainty too large · set position", code: .uncertaintyExceeded, time: sample.time, measurements: ["uncertaintyMetres": uncertainty, "maximumUncertaintyMetres": maximumUncertainty])
        } else if !graph.contains(coordinate) {
            _ = freeze("Outside offline map coverage · set position", code: .outsideCoverage, time: sample.time)
        }
    }

    /// On a locked route later turns can re-establish the position, so a long
    /// featureless stretch only degrades the estimate instead of ending it:
    /// on a highway the driver cannot stop to set the position again.
    private var maximumUncertainty: Double {
        return route == nil ? 350 : 10_000
    }

    /// Along-road uncertainty accumulated since the last position reset, as a
    /// radius. With vibration speed it follows the integrated speed variance
    /// with a 60-second error correlation: on field drives this bounded 120 s
    /// distance errors (worst 45–85 m) where the unmeasured t² allowance
    /// reached the 350 m reset within five minutes. Moving time without that
    /// speed keeps the t² allowance.
    private func motionUncertaintyGrowth() -> Double {
        let unmeasured = max(0, unanchoredMovingTime - vibrationMeasuredTime)
        var growth = 0.004 * pow(unmeasured, 2)
        if vibrationMeasuredTime > 0 {
            growth += 2 * sqrt(60 * speedVarianceIntegral)
        }
        return growth
    }

    private func resetMotionUncertaintyGrowth() {
        unanchoredMovingTime = 0
        vibrationMeasuredTime = 0
        speedVarianceIntegral = 0
    }

    private func applyTurnLandmark(_ turn: TurnObservation, sample: MotionSample, path: Int,
                                  probability: Double, speed: Double) -> (correction: LandmarkCorrection?, reason: String) {
        guard probability >= 0.95 else {
            return (nil, "Angle match only; timed junction hypothesis remains ambiguous")
        }
        guard !confirmedStopped, speed > 2 else {
            return (nil, "Angle match only; speed is too low for reliable timed motion correction")
        }
        guard let midpoint = turnMotionHistory.midpoint(start: turn.start, end: turn.end, angle: turn.angle) else {
            return (nil, "Angle match only; compound or extended turn has no reliable midpoint")
        }
        let radius = max(40, turn.startUncertainty + speed * (turn.end - turn.start))
        var candidates: [TurnLandmark]
        if let routeIndex, let startOffset = routeIndex.offset(of: turn.startPosition) {
            candidates = routeLandmarks.filter { candidate in
                if let previousOffset = lastTimedLandmark?.routeOffset, candidate.midpoint <= previousOffset + 20 {
                    return false
                }
                return abs(candidate.midpoint - startOffset) <= radius && abs(angleDifference(candidate.angle, turn.angle)) < 0.20
            }.map { candidate in
                return candidate.landmark(route: routeIndex, graph: graph)
            }
        } else {
            candidates = TurnLandmark.candidates(graph: graph, start: turn.startPosition, endPath: path,
                                                angle: turn.angle, radius: radius)
        }
        guard candidates.count == 1, let landmark = candidates.first else {
            return (nil, "Angle match only; no unique isolated junction between straight approaches")
        }
        if route == nil && landmark.outgoingPath != path {
            return (nil, "Angle match only; isolated junction does not reach the observed road")
        }
        var indices: [Int] = []
        var states: [LandmarkState] = []
        var calibrationDistance: Double?
        var calibrationDuration: Double?
        for (index, particle) in particles.enumerated() {
            guard graph.pathIndex[particle.position.edge] == path,
                  let offset = landmark.offset(of: particle.position, graph: graph) else {
                continue
            }
            let state = LandmarkState(position: offset, speed: particle.speed,
                                      bias: particle.accelerationBias, weight: particle.weight)
            indices.append(index)
            states.append(state)
        }
        let participatingMass = states.reduce(0.0) { total, state in
            return total + state.weight
        }
        guard participatingMass >= 0.95 else {
            return (nil, "Angle match only; timed-junction motion history remains ambiguous")
        }
        // The gyro midpoint does not exactly coincide with the mapped vertex:
        // lane choice, corner cutting and correlated heading evidence dominate
        // timing precision. Keep at least twelve metres of observation sigma.
        let sigma = max(12, speed * (turn.end - turn.start) * 0.3)
        var observationSigma = sigma
        let duration = sample.time - midpoint
        let moment = turnMotionHistory.accelerationMoment(from: midpoint, to: sample.time)
        let recentVelocity = turnMotionHistory.velocityChange(from: midpoint, to: sample.time)
        var observationElapsed = duration
        var observationMoment = moment
        var distanceSinceLandmark: Double?
        let routeOffset = landmark.routeAnchorDistance
        if let previous = lastTimedLandmark {
            if let routeOffset, let previousOffset = previous.routeOffset {
                distanceSinceLandmark = routeOffset - previousOffset
            } else if previous.path == landmark.incomingPath {
                distanceSinceLandmark = landmark.incomingDistance - previous.distance
            }
        }
        if let previous = lastTimedLandmark, let distance = distanceSinceLandmark, distance > 80,
           midpoint - previous.time > 10, midpoint - previous.time < 180 {
            let interval = midpoint - previous.time
            calibrationDistance = distance
            calibrationDuration = interval
            states = previous.hypotheses(current: states, time: sample.time, midpoint: midpoint, distance: distance,
                                         recentVelocity: recentVelocity, recentMoment: moment)
            let processVariance = 0.07 * 0.07 * pow(interval, 3) / 3 + pow(Self.accelerationBiasWalk, 2) * pow(interval, 5) / 20
            observationSigma = sqrt(pow(sigma + previous.sigma, 2) + processVariance)
            observationElapsed = 0
            observationMoment = 0
        }
        guard let update = TurnLandmarkConditioning.apply(states: states, elapsed: observationElapsed,
                                                          accelerationMoment: observationMoment, sigma: observationSigma) else {
            return (nil, "Angle match only; timed junction innovation is inconsistent with motion hypotheses")
        }
        var positions: [RoadPosition] = []
        let posterior = update.states
        var outgoingMass = 0.0
        for state in posterior {
            guard state.speed >= 0, state.speed <= 65, abs(state.bias) < 0.2 else {
                return (nil, "Angle match only; calibrated motion uncertainty exceeds the supported speed range")
            }
            guard let position = landmark.position(at: state.position, graph: graph) else {
                return (nil, "Angle match only; timed correction exceeds the supported connected geometry")
            }
            if let routeIndex, routeIndex.offset(of: position) == nil {
                return (nil, "Angle match only; timed correction falls outside the selected route")
            }
            if let route, position.edge == route.destination.edge, position.distance > route.destination.distance {
                return (nil, "Angle match only; timed correction extends past the destination")
            }
            var compatible = graph.pathIndex[position.edge] == path
            if route != nil {
                let currentHeading = particles[indices[positions.count]].heading
                compatible = abs(angleDifference(currentHeading, graph.edges[position.edge].heading(at: position.distance))) < 0.35
            }
            if compatible {
                outgoingMass += state.weight
            }
            positions.append(position)
        }
        guard outgoingMass >= 0.95 else {
            return (nil, "Angle match only; timed correction would make junction traversal ambiguous")
        }
        for (offset, index) in indices.enumerated() {
            particles[index].position = positions[offset]
            particles[index].speed = posterior[offset].speed
            particles[index].accelerationBias = posterior[offset].bias
            particles[index].curvatureReference = nil
        }
        var remainingOffset = 0.0
        for state in posterior {
            remainingOffset += (state.position - state.speed * duration + moment - state.bias * duration * duration / 2) * state.weight / participatingMass
        }
        let positionSigma = sigma + abs(remainingOffset)
        let uncertainty = LandmarkMotionUncertainty(positionVariance: max(positionSigma * positionSigma, update.variance.x),
                                                   speedVariance: update.variance.y, biasVariance: update.variance.z,
                                                   speedBiasCovariance: update.speedBiasCovariance)
        landmarkUncertainty = uncertainty
        initialUncertainty = uncertainty.radius(after: 0)
        resetMotionUncertaintyGrowth()
        lastTimedLandmark = LandmarkCalibrationInterval(path: landmark.outgoingPath, distance: landmark.outgoingDistance,
                                                        time: midpoint, sigma: sigma,
                                                        velocityIntegral: recentVelocity,
                                                        distanceIntegral: duration * recentVelocity - moment,
                                                        routeOffset: routeOffset)
        let correction = LandmarkCorrection(signalID: turn.id, observationTime: midpoint,
                                            incomingEdge: landmark.incoming, outgoingEdge: landmark.outgoing,
                                            observationSigmaMetres: observationSigma, innovationMetres: update.innovation,
                                            positionChangeMetres: update.change.x,
                                            speedChangeMetresPerSecond: update.change.y,
                                            biasChangeMetresPerSecondSquared: update.change.z,
                                            positionSigmaMetres: sqrt(uncertainty.positionVariance),
                                            speedSigmaMetresPerSecond: sqrt(update.variance.y),
                                            biasSigmaMetresPerSecondSquared: sqrt(update.variance.z),
                                            calibrationDistanceMetres: calibrationDistance,
                                            calibrationDurationSeconds: calibrationDuration,
                                            routeDistanceMetres: routeOffset)
        if route != nil {
            return (correction, "Timed route bend matched; joint position, speed and bias correction applied")
        }
        return (correction, "Timed junction matched; joint position, speed and bias correction applied")
    }

    private func recordRoadSignal(_ turn: TurnObservation, time: Double, stage: String, reason: String, match: RoadMatchUpdate?) {
        var mappedAngle = 0.0
        if let position = match?.result.position {
            mappedAngle = angleDifference(graph.edges[position.edge].heading(at: position.distance), turn.startMapHeading)
        }
        roadSignals.append(RoadSignalEvent(signalID: turn.id, time: time, stage: stage, reason: reason, turnStartTime: turn.start, turnEndTime: turn.end, turnStartPosition: turn.startPosition, observedTurnDegrees: turn.angle * 180 / .pi, mappedTurnDegrees: mappedAngle * 180 / .pi, angleResidualDegrees: angleDifference(turn.angle, mappedAngle) * 180 / .pi, roadMatch: match))
        if roadSignals.count > 32 {
            roadSignals.removeFirst(roadSignals.count - 32)
        }
    }

    private func evaluateRouteEvidence(at time: Double) {
        pendingRouteFeature = nil
        guard let route, let matcher = routeEvidenceMatcher, let turn = pendingTurn else {
            return
        }
        var weightedOffset = 0.0
        var weight = 0.0
        for particle in particles {
            guard let offset = routeIndex?.offset(of: particle.position) else {
                continue
            }
            weightedOffset += offset * particle.weight
            weight += particle.weight
        }
        guard weight > 0 else {
            return
        }
        let offsetBefore = weightedOffset / weight
        let uncertainty = estimate?.uncertainty ?? turn.startUncertainty
        let speed = estimate?.speed ?? 0
        // The gyro declares a turn complete only after 0.8 s below 1.4°/s,
        // well after the car leaves the mapped bend (20–90 m on field drives).
        // The turn's angular midpoint matched the mapped midpoint within 5 m
        // for ordinary turns, so it locates the turn on the route.
        let midpointTime = turnMotionHistory.halfAngleTime(start: turn.start, end: turn.end)
        var odometer = totalDistance
        if let last = travelHistory.last {
            odometer = last.distance + max(0, speed) * max(0, time - last.time)
        }
        let sinceMidpoint = midpointTime.map { midpoint in
            return distanceTravelled(since: midpoint, now: time, speed: speed)
        }
        let sinceEnd = distanceTravelled(since: turn.end, now: time, speed: speed)
        let decision = matcher.match(turn: turn, time: time, estimatedRouteOffset: offsetBefore,
                                     uncertainty: uncertainty, estimatedSpeed: speed, odometer: odometer,
                                     distanceSinceMidpoint: sinceMidpoint, distanceSinceEnd: sinceEnd,
                                     profile: observedHeadingProfile(turn: turn, now: time, speed: speed,
                                                                     sinceMidpoint: sinceMidpoint, sinceEnd: sinceEnd))
        guard let feature = decision.feature, let targetEstimate = decision.anchorRouteOffset,
              let anchorSigma = decision.anchorSigma else {
            routeEvidenceEvents.append(RouteEvidenceEvent(time: time, signalID: turn.id, stage: "ambiguous",
                                                           reason: decision.reason,
                                                           observedTurnDegrees: turn.angle * 180 / .pi,
                                                           matchedFeatureIndex: nil, matchedTurnDegrees: nil,
                                                           matchedRouteOffsetMetres: nil, angleResidualDegrees: nil,
                                                           routeOffsetBeforeMetres: offsetBefore,
                                                           routeOffsetAfterMetres: nil,
                                                           confidence: decision.confidence,
                                                           runnerUpConfidence: decision.runnerUpConfidence,
                                                           precedingStraightSeconds: decision.precedingStraightSeconds,
                                                           precedingStraightMetres: nil,
                                                           profileResidualDegrees: decision.profileResidual.map { residual in
                                                               return residual * 180 / .pi
                                                           },
                                                           profileLengthMetres: decision.profileLength))
            trimRouteEvidenceEvents()
            if abs(angleDifference(turn.angle, 0)) >= 150 * .pi / 180 {
                _ = freeze("Observed U-turn leaves the selected route · reset starting point", code: .headingMismatch,
                           time: time, measurements: ["observedTurnDegrees": turn.angle * 180 / .pi])
            }
            return
        }

        let routeLength = routeIndex?.length ?? route.distance(in: graph)
        // The dominant route hypothesis already combines this feature with the
        // earlier matched sequence and the odometer since then.
        let anchorName = decision.anchor ?? "end"
        let sigma = max(4, anchorSigma)
        let targetOffset = clamp(targetEstimate, 0, routeLength)
        let priorVariance = pow(max(4, uncertainty / 2), 2)
        let anchorVariance = sigma * sigma
        let distant = abs(targetOffset - offsetBefore) > 4 * sqrt(priorVariance + anchorVariance)
        // A match far outside the estimate's own uncertainty moves the car
        // only when the matcher's 95% region leaves the current position out.
        // On a highway drive one 47° turn after 11 minutes without a match
        // fitted a bend 10 km back with 90% of the weight, the rest staying
        // at the (correct) estimate; the next turn decides instead.
        if distant, let radius = decision.credibleRadius, radius > 0.5 * abs(targetOffset - offsetBefore) {
            routeEvidenceEvents.append(RouteEvidenceEvent(time: time, signalID: turn.id, stage: "ambiguous",
                                                           reason: "Distant match not separated from the current position",
                                                           observedTurnDegrees: turn.angle * 180 / .pi,
                                                           matchedFeatureIndex: feature.index,
                                                           matchedTurnDegrees: feature.angle * 180 / .pi,
                                                           matchedRouteOffsetMetres: feature.midpoint,
                                                           angleResidualDegrees: angleDifference(turn.angle, feature.angle) * 180 / .pi,
                                                           routeOffsetBeforeMetres: offsetBefore,
                                                           routeOffsetAfterMetres: nil,
                                                           confidence: decision.confidence,
                                                           runnerUpConfidence: decision.runnerUpConfidence,
                                                           precedingStraightSeconds: decision.precedingStraightSeconds,
                                                           precedingStraightMetres: nil,
                                                           anchorRouteOffsetMetres: targetOffset,
                                                           anchorSigmaMetres: sigma,
                                                           anchor: anchorName,
                                                           credibleRadiusMetres: radius,
                                                           profileResidualDegrees: decision.profileResidual.map { residual in
                                                               return residual * 180 / .pi
                                                           },
                                                           profileLengthMetres: decision.profileLength))
            trimRouteEvidenceEvents()
            return
        }
        if let midpoint = midpointTime, feature.index >= 0 {
            // Midpoints matched the map within about 5 m for ordinary turns and
            // 44 m for one U-turn loop, tighter than the position-fusion sigma.
            let length = feature.end - feature.start
            let calibrationSigma = abs(feature.angle) > 150 * .pi / 180 ? max(10, 0.25 * length) : max(5, 0.1 * length)
            wheelbaseCalibrator.anchor(time: midpoint, routeOffset: feature.midpoint, sigma: calibrationSigma, now: time)
        }
        var routeAverageSpeed: Double?
        var speedAfter = speed
        // The interval average includes any stop between the turns. Measured
        // vibration speed supersedes it; it remains only for recordings without.
        let vibrationSpeedAvailable = latestVibration.map { observation in
            return abs(time - observation.time) <= 2
        } ?? false
        if !vibrationSpeedAvailable, let previousEnd = lastRouteEvidenceEnd,
           let previousTurnEndTime = lastRouteEvidenceTurnEndTime {
            let intervalDistance = feature.end - previousEnd
            let intervalDuration = turn.end - previousTurnEndTime
            if intervalDistance >= 50, intervalDuration >= 5 {
                let average = intervalDistance / intervalDuration
                if average >= 1, average <= 45 {
                    routeAverageSpeed = average
                    for index in particles.indices {
                        particles[index].speed = clamp(particles[index].speed * 0.35 + average * 0.65, 0, 45)
                    }
                    speedAfter = particles.reduce(0.0) { total, particle in
                        return total + particle.speed * particle.weight
                    }
                }
            }
        }
        // Fuse the anchor with the estimate as a Kalman update along the route,
        // using the modeled uncertainty: after measured-speed tracking the
        // hypotheses are clustered more tightly than their real error, so
        // reweighting them cannot move the estimate. An estimate inconsistent
        // with its own uncertainty (the old speed drift) takes the anchor fully.
        var gain = priorVariance / (priorVariance + anchorVariance)
        var correction = "kalman"
        if distant {
            gain = 1
            correction = "recovery_shift"
        }
        let adjustment = gain * (targetOffset - offsetBefore)
        // The particles keep their own spread along the route; a confident
        // anchor narrows it to the anchor's, or the radius would stay wide.
        var particleVariance = 0.0
        for particle in particles {
            if let offset = routeIndex?.offset(of: particle.position) {
                particleVariance += particle.weight * pow(offset - offsetBefore, 2) / weight
            }
        }
        let contraction = min(1, sigma / max(1e-9, sqrt(particleVariance)))
        for index in particles.indices {
            guard let offset = routeIndex?.offset(of: particles[index].position) else {
                continue
            }
            let correctedOffset = clamp(offsetBefore + (offset - offsetBefore) * contraction + adjustment, 0, routeLength)
            if let corrected = routeIndex?.position(at: correctedOffset) {
                particles[index].position = corrected
                particles[index].curvatureReference = nil
            }
        }
        let offsetAfter = clamp(offsetBefore + adjustment, 0, routeLength)
        // Weaker alternative alignments widen the reported radius by as much
        // as they widen the 95% radius; a few percent of far-away
        // alternatives must not keep a confident fix at hundreds of metres.
        let alternatives = max(0, (decision.credibleRadius ?? 2 * sigma) - 2 * sigma)
        if gain < 1 {
            routeEvidenceUncertainty = max(8, 2 * sqrt(priorVariance * anchorVariance / (priorVariance + anchorVariance)) + alternatives)
        } else {
            routeEvidenceUncertainty = max(10, 2 * sigma + alternatives)
        }
        pendingRouteFeature = feature
        lastRouteEvidenceEnd = feature.end
        lastRouteEvidenceTurnEndTime = turn.end
        while expectedRouteLandmarkIndex < routeLandmarks.count,
              routeLandmarks[expectedRouteLandmarkIndex].midpoint <= feature.end + 5 {
            expectedRouteLandmarkIndex += 1
        }
        routeEvidenceEvents.append(RouteEvidenceEvent(time: time, signalID: turn.id, stage: "accepted",
                                                       reason: decision.reason,
                                                       observedTurnDegrees: turn.angle * 180 / .pi,
                                                       matchedFeatureIndex: feature.index,
                                                       matchedTurnDegrees: feature.angle * 180 / .pi,
                                                       matchedRouteOffsetMetres: feature.midpoint,
                                                       angleResidualDegrees: angleDifference(turn.angle, feature.angle) * 180 / .pi,
                                                       routeOffsetBeforeMetres: offsetBefore,
                                                       routeOffsetAfterMetres: offsetAfter,
                                                       confidence: decision.confidence,
                                                       runnerUpConfidence: decision.runnerUpConfidence,
                                                       precedingStraightSeconds: decision.precedingStraightSeconds,
                                                       precedingStraightMetres: feature.precedingStraightMetres,
                                                       routeAverageSpeedMetresPerSecond: routeAverageSpeed,
                                                       speedBeforeMetresPerSecond: speed,
                                                       speedAfterMetresPerSecond: speedAfter,
                                                       anchorRouteOffsetMetres: targetOffset,
                                                       anchorSigmaMetres: sigma,
                                                       anchor: anchorName,
                                                       correction: correction,
                                                       credibleRadiusMetres: decision.credibleRadius,
                                                       profileResidualDegrees: decision.profileResidual.map { residual in
                                                           return residual * 180 / .pi
                                                       },
                                                       profileLengthMetres: decision.profileLength))
        trimRouteEvidenceEvents()
    }

    /// The gyro heading against distance driven, from shortly before the
    /// turn began until now, when the histories reach back that far.
    private func observedHeadingProfile(turn: TurnObservation, now: Double, speed: Double,
                                        sinceMidpoint: Double?, sinceEnd: Double) -> ObservedHeadingProfile? {
        guard let first = travelHistory.first, let last = travelHistory.last,
              let earliest = turnMotionHistory.earliestTime else {
            return nil
        }
        let distanceNow = last.distance + max(0, speed) * max(0, now - last.time)
        let sinceStart = distanceTravelled(since: turn.start, now: now, speed: speed)
        var span = min(RouteEvidenceMatcher.maximumProfileLength, sinceStart + 40, distanceNow - first.distance)
        // The yaw history must cover the profile's first point too.
        while span > 20, let start = time(atDistance: distanceNow - span, now: now), start < earliest {
            span -= 20
        }
        guard span >= 20 else {
            return nil
        }
        let count = Int(min(80, max(8, (span / 5).rounded())))
        let distances = (0...count).map { index in
            return span * (1 - Double(index) / Double(count))
        }
        let times = distances.compactMap { distance in
            return time(atDistance: distanceNow - distance, now: now)
        }
        guard times.count == distances.count, let yaw = turnMotionHistory.integratedYaw(at: times) else {
            return nil
        }
        return ObservedHeadingProfile(distances: distances, headings: yaw, sinceStart: sinceStart,
                                      sinceMidpoint: sinceMidpoint, sinceEnd: sinceEnd)
    }

    /// When the published travelled distance first reached `distance`.
    private func time(atDistance distance: Double, now: Double) -> Double? {
        guard let first = travelHistory.first, let last = travelHistory.last, distance >= first.distance else {
            return nil
        }
        if distance >= last.distance {
            return min(now, last.time)
        }
        var low = 0
        var high = travelHistory.count - 1
        while low < high {
            let middle = (low + high) / 2
            if travelHistory[middle].distance >= distance {
                high = middle
            } else {
                low = middle + 1
            }
        }
        guard low > 0 else {
            return travelHistory[0].time
        }
        let before = travelHistory[low - 1]
        let after = travelHistory[low]
        let fraction = (distance - before.distance) / max(1e-9, after.distance - before.distance)
        return before.time + (after.time - before.time) * fraction
    }

    /// Published travelled distance since `start`, plus the part since the
    /// latest publication; speed × time when the history does not reach back.
    private func distanceTravelled(since start: Double, now: Double, speed: Double) -> Double {
        guard let first = travelHistory.first, let last = travelHistory.last, first.time <= start else {
            return max(0, speed) * max(0, now - start)
        }
        var distanceAtStart = last.distance
        for (index, point) in travelHistory.enumerated() where point.time >= start {
            distanceAtStart = point.distance
            if index > 0 {
                let previous = travelHistory[index - 1]
                let fraction = (start - previous.time) / max(1e-9, point.time - previous.time)
                distanceAtStart = previous.distance + (point.distance - previous.distance) * fraction
            }
            break
        }
        return max(0, last.distance - distanceAtStart) + max(0, speed) * max(0, now - max(start, last.time))
    }

    private func trimRouteEvidenceEvents() {
        if routeEvidenceEvents.count > 64 {
            routeEvidenceEvents.removeFirst(routeEvidenceEvents.count - 64)
        }
    }

    private func routeTurnMatches(_ angle: Double, landmark: RouteTurnLandmark) -> Bool {
        return abs(angle) >= .pi / 4 - 0.20
            && abs(angleDifference(angle, landmark.angle)) < 0.20
    }

    private func completeExpectedRouteLandmark() {
        guard expectedRouteLandmarkIndex < routeLandmarks.count,
              let pendingTurn,
              routeTurnMatches(pendingTurn.angle, landmark: routeLandmarks[expectedRouteLandmarkIndex]) else {
            return
        }
        expectedRouteLandmarkIndex += 1
    }

    private func initialNoiseMagnitudes(count: Int) -> [Double] {
        var values: [Double] = []
        var squares = 0.0
        for _ in 0..<count {
            let value = random.normal()
            values.append(abs(value))
            squares += value * value
        }
        let scale = sqrt(Double(count) / max(squares, 1e-12))
        return values.map { value in
            return value * scale
        }
    }

    /// Preserve a zero weighted mean without reducing the expected noise
    /// variance. Map evidence can still change the posterior mean afterwards.
    private func centeredNoise(weights: [Double]) -> [Double] {
        var values: [Double] = []
        var mean = 0.0
        var squaredWeights = 0.0
        for weight in weights {
            let value = random.normal()
            values.append(value)
            mean += value * weight
            squaredWeights += weight * weight
        }
        let varianceFactor = 1 - squaredWeights
        // One effective hypothesis has no ensemble mean to balance against.
        guard varianceFactor > 1e-6 else {
            return values
        }
        let scale = 1 / sqrt(varianceFactor)
        return values.map { value in
            return (value - mean) * scale
        }
    }

    private func resampleIfNeeded() {
        let squares = particles.reduce(0.0) { total, particle in
            return total + particle.weight * particle.weight
        }
        if particles.count <= population && 1 / squares > Double(population) * 0.60 {
            return
        }
        let stride = 1 / Double(population)
        var target = random.uniform() * stride
        var cumulative = particles[0].weight
        var index = 0
        var next: [Particle] = []
        for _ in 0..<population {
            while target > cumulative && index < particles.count - 1 {
                index += 1
                cumulative += particles[index].weight
            }
            var particle = particles[index]
            particle.weight = stride
            next.append(particle)
            target += stride
        }
        let weights = Array(repeating: stride, count: population)
        let positionNoise = centeredNoise(weights: weights)
        let velocityNoise = centeredNoise(weights: weights)
        let accelerationNoise = centeredNoise(weights: weights)
        for index in next.indices {
            next[index].position.distance = clamp(next[index].position.distance + positionNoise[index] * 0.5, 0, graph.edges[next[index].position.edge].length)
            if !confirmedStopped {
                next[index].speed = clamp(next[index].speed + velocityNoise[index] * 0.12, 0, 65)
            }
            next[index].accelerationBias += accelerationNoise[index] * 0.003
        }
        particles = next
    }

    @discardableResult
    private func freeze(_ reason: String, code: TrackingFailureReason, time: Double, measurements: [String: Double] = [:]) -> TrackingEstimate? {
        if let pendingTurn {
            recordRoadSignal(pendingTurn, time: time, stage: "rejected", reason: reason, match: lastRoadUpdate)
            self.pendingTurn = nil
        }
        frozen = true
        estimate?.status = reason
        estimate?.needsReset = true
        estimate?.time = time
        estimate?.failure = TrackingFailure(reason: code, measurements: measurements)
        return estimate
    }
}
