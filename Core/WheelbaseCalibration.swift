import Foundation

/// Pooled wheelbase evidence: estimates in metres weighted by inverse
/// relative variance. It describes the physical car, so it survives changes of
/// the wheelbase setting and carries over between drives.
public struct WheelbaseEvidence: Codable, Equatable, Sendable {
    public var weight = 0.0
    public var weightedMetres = 0.0
    public var intervals = 0

    public init(weight: Double = 0, weightedMetres: Double = 0, intervals: Int = 0) {
        self.weight = weight
        self.weightedMetres = weightedMetres
        self.intervals = intervals
    }

    public var estimate: Double? {
        return weight > 0 ? weightedMetres / weight : nil
    }

    /// Relative standard deviation of the pooled estimate.
    public var relativeUncertainty: Double? {
        return weight > 0 ? 1 / sqrt(weight) : nil
    }

    /// Enough evidence to scale live speeds or change the setting.
    public var isConfident: Bool {
        return intervals >= 2 && (relativeUncertainty ?? 1) <= 0.015
    }

    mutating func add(metres: Double, relativeSigma: Double) {
        let contribution = 1 / (relativeSigma * relativeSigma)
        weight += contribution
        weightedMetres += contribution * metres
        intervals += 1
    }
}

struct WheelbaseCalibrationEvent: Codable {
    let time: Double
    let stage: String
    let reason: String
    let startTime: Double
    let endTime: Double
    let mappedMetres: Double
    let vibrationMetres: Double?
    /// Wheelbase the vibration speed was computed with.
    let wheelbaseMetres: Double?
    let estimateMetres: Double?
    let relativeSigma: Double?
    let pooledMetres: Double?
    let pooledRelativeSigma: Double?
    let pooledIntervals: Int
}

/// Learns the car's wheelbase on a locked route. Vibration speed is wheelbase
/// divided by the axle delay, so a wrong wheelbase scales every vibration
/// distance by one factor, while the mapped distance between two matched turn
/// midpoints is known. Each consecutive pair of midpoint anchors yields one
/// wheelbase estimate. Intervals where speed came from acceleration alone dilute
/// the correction toward the current value; it converges over repeated drives.
struct WheelbaseCalibrator {
    static let minimumMappedMetres = 150.0
    static let maximumIntervalSeconds = 900.0
    /// Relative error of vibration distance over an interval (field drives: 1–3%).
    static let distanceNoise = 0.025
    private(set) var evidence: WheelbaseEvidence
    private var history: [(time: Double, distance: Double, segment: Int)] = []
    private var segment = 0
    private var lastObservation: (time: Double, speed: Double, wheelbase: Double)?
    private var lastAnchor: (time: Double, offset: Double, sigma: Double)?
    private var events: [WheelbaseCalibrationEvent] = []

    init(prior: WheelbaseEvidence = WheelbaseEvidence()) {
        evidence = prior
    }

    /// Raw vibration speed, before any calibration scale is applied.
    mutating func record(_ observation: VibrationSpeedObservation) {
        if let last = lastObservation {
            let gap = observation.time - last.time
            guard gap > 0 else {
                return
            }
            let distance = history.last?.distance ?? 0
            if gap > 3 || observation.wheelbase != last.wheelbase {
                segment += 1
                history.append((observation.time, distance, segment))
            } else {
                history.append((observation.time, distance + (last.speed + observation.speed) / 2 * gap, segment))
            }
        } else {
            history.append((observation.time, 0, segment))
        }
        lastObservation = (observation.time, observation.speed, observation.wheelbase)
        let keepFrom = min(lastAnchor?.time ?? observation.time, observation.time - 120) - 5
        if let first = history.firstIndex(where: { entry in
            return entry.time >= keepFrom
        }), first > 1 {
            history.removeFirst(first - 1)
        }
    }

    /// A matched route turn: its angular midpoint time and mapped route offset.
    mutating func anchor(time: Double, routeOffset: Double, sigma: Double, now: Double) {
        defer {
            lastAnchor = (time, routeOffset, sigma)
        }
        guard let previous = lastAnchor else {
            return
        }
        let mapped = routeOffset - previous.offset
        func reject(_ reason: String, vibration: Double? = nil) {
            events.append(WheelbaseCalibrationEvent(time: now, stage: "rejected", reason: reason, startTime: previous.time, endTime: time,
                                                    mappedMetres: mapped, vibrationMetres: vibration, wheelbaseMetres: lastObservation?.wheelbase,
                                                    estimateMetres: nil, relativeSigma: nil, pooledMetres: evidence.estimate,
                                                    pooledRelativeSigma: evidence.relativeUncertainty, pooledIntervals: evidence.intervals))
        }
        guard mapped >= Self.minimumMappedMetres, time - previous.time <= Self.maximumIntervalSeconds, time > previous.time else {
            reject("Interval too short or too long for a distance comparison")
            return
        }
        guard let start = distance(at: previous.time), let end = distance(at: time), start.segment == end.segment,
              let wheelbase = lastObservation?.wheelbase else {
            reject("Vibration speed was interrupted between the turns")
            return
        }
        let vibration = end.distance - start.distance
        guard vibration > 50 else {
            reject("Too little measured movement between the turns", vibration: vibration)
            return
        }
        let ratio = mapped / vibration
        guard ratio >= 0.8, ratio <= 1.25 else {
            reject("Mapped and measured distances disagree beyond a wheelbase error", vibration: vibration)
            return
        }
        let relativeSigma = sqrt(previous.sigma * previous.sigma + sigma * sigma + pow(Self.distanceNoise * mapped, 2)) / mapped
        let estimate = wheelbase * ratio
        evidence.add(metres: estimate, relativeSigma: relativeSigma)
        events.append(WheelbaseCalibrationEvent(time: now, stage: "accepted", reason: "Mapped distance between matched turn midpoints",
                                                startTime: previous.time, endTime: time, mappedMetres: mapped, vibrationMetres: vibration,
                                                wheelbaseMetres: wheelbase, estimateMetres: estimate, relativeSigma: relativeSigma,
                                                pooledMetres: evidence.estimate, pooledRelativeSigma: evidence.relativeUncertainty,
                                                pooledIntervals: evidence.intervals))
    }

    /// Correction for vibration speed computed with `wheelbase`.
    func scale(for wheelbase: Double) -> Double {
        guard evidence.isConfident, let estimate = evidence.estimate else {
            return 1
        }
        return clamp(estimate / wheelbase, 0.85, 1.15)
    }

    mutating func drainEvents() -> [WheelbaseCalibrationEvent] {
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    private func distance(at time: Double) -> (distance: Double, segment: Int)? {
        guard let upper = history.firstIndex(where: { entry in
            return entry.time >= time
        }), upper > 0 else {
            return nil
        }
        let before = history[upper - 1]
        let after = history[upper]
        guard before.segment == after.segment else {
            return nil
        }
        let fraction = (time - before.time) / max(1e-9, after.time - before.time)
        return (before.distance + (after.distance - before.distance) * fraction, after.segment)
    }
}
