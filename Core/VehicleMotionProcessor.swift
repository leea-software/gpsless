import Foundation
import simd

struct MotionProcessingDiagnostic: Codable {
    let time: Double
    let gravity: [Double]
    let gyroBias: [Double]
    let gravityDisagreementDegrees: Double
    let forwardAccelerationDifference: Double
    let secondsSinceCalibration: Double
    var gravityCorrectionDegrees: Double? = nil
    var gravityCorrectionActive: Bool? = nil
    /// Confidence (0–1) given to the vibration speed when aiding gravity.
    var speedAidWeight: Double? = nil
}

struct MotionProcessingUpdate {
    var sample: MotionSample?
    var calibration: CalibrationRecord?
    var discardedCalibrationSamples = 0
    var progress = 0.0
    var failure: String?
    var speedObservation: VibrationSpeedObservation?
}

/// Owns calibration and raw-frame processing for both the live service and
/// offline raw replay. Gyroscope propagation owns short-term attitude. Slow
/// drift is removed with the vibration speed filter: its acceleration-bias
/// estimate, learned only from axle-echo speed and parked vibration, is moved
/// into gravity, and centripetal acceleration uses its speed. Core Motion's
/// own gravity is not a reference; field drives showed it retains a forward
/// bias near 0.1 m/s².
final class VehicleMotionProcessor {
    static let method = "speed-aided-gravity-v4"
    private(set) var wheelbase: Double
    private(set) var speedObserver: VehicleSpeedObserver
    private(set) var calibrated = false
    private(set) var diagnostic: MotionProcessingDiagnostic?
    private var calibrationFrames: [RawMotion] = []
    private var recentFrames: [RawMotion] = []
    private var gravity = SIMD3<Double>(0, -1, 0)
    private var gyroBias = SIMD3<Double>.zero
    private var previous: RawMotion?
    private var calibrationTime = 0.0
    private var lastCalibration: CalibrationRecord?
    private var accumulated: [(sample: MotionSample, duration: Double)] = []
    private var lastOutputTime: Double?

    init(wheelbase: Double = VehicleSpeedObserver.defaultWheelbase) {
        self.wheelbase = wheelbase
        speedObserver = VehicleSpeedObserver(wheelbase: wheelbase)
    }

    /// A refined or corrected wheelbase keeps gravity, gyro offsets and the
    /// parked vibration reference: none of them depend on it.
    func adoptWheelbase(_ newWheelbase: Double) {
        guard newWheelbase != wheelbase else {
            return
        }
        wheelbase = newWheelbase
        speedObserver = VehicleSpeedObserver(wheelbase: newWheelbase, baseline: speedObserver.baseline)
    }

    /// Starts another drive without discarding the mount calibration. This is
    /// safe only while the app remains open and the phone stays in the same
    /// mount; the first drive in a process still performs full calibration.
    func beginSession(reusingCalibration: Bool) {
        previous = nil
        recentFrames.removeAll(keepingCapacity: true)
        accumulated.removeAll(keepingCapacity: true)
        lastOutputTime = nil
        diagnostic = nil
        if reusingCalibration {
            speedObserver.beginSession()
        } else {
            speedObserver = VehicleSpeedObserver(wheelbase: wheelbase)
            calibrated = false
            calibrationFrames.removeAll(keepingCapacity: true)
            gravity = SIMD3<Double>(0, -1, 0)
            gyroBias = .zero
            calibrationTime = 0
            lastCalibration = nil
        }
    }

    /// The calibration a reusing drive starts from, with the current gravity,
    /// so its recording can be replayed without the drive that measured it.
    func reusedCalibration() -> CalibrationRecord? {
        guard calibrated, var record = lastCalibration else {
            return nil
        }
        record.gravity = array(gravity)
        record.gyroBias = array(gyroBias)
        record.reason = "reused"
        record.vibrationBaseline = speedObserver.baseline
        return record
    }

    /// Replay counterpart of reusing the calibration: continues from a
    /// recorded calibration instead of waiting for a parked interval.
    @discardableResult
    func resume(from record: CalibrationRecord) -> Bool {
        guard let recordedGravity = record.gravity, recordedGravity.count == 3,
              let recordedGyroBias = record.gyroBias, recordedGyroBias.count == 3,
              simd_length(vector(recordedGravity)) > 0.5 else {
            return false
        }
        gravity = simd_normalize(vector(recordedGravity))
        gyroBias = vector(recordedGyroBias)
        calibrationTime = record.end
        lastCalibration = record
        calibrated = true
        calibrationFrames.removeAll(keepingCapacity: false)
        speedObserver = VehicleSpeedObserver(wheelbase: wheelbase, baseline: record.vibrationBaseline)
        beginSession(reusingCalibration: true)
        return true
    }

    func receive(_ raw: RawMotion, magneticMagnitude: Double? = nil, relativeAltitude: Double? = nil) -> MotionProcessingUpdate {
        var update = MotionProcessingUpdate()
        guard raw.time.isFinite, raw.acceleration.count == 3, raw.gravity.count == 3, raw.rotation.count == 3,
              (raw.acceleration + raw.gravity + raw.rotation).allSatisfy({ value in
                  return value.isFinite
              }), simd_length(vector(raw.gravity)) > 0.5, simd_length(vector(raw.gravity)) < 1.5,
              simd_length(vector(raw.rotation)).isFinite else {
            update.failure = "Invalid motion data · set position again"
            return update
        }
        if let previous, raw.time <= previous.time {
            return update
        }
        let preceding = previous
        previous = raw
        var dt = 0.01
        if let preceding {
            dt = raw.time - preceding.time
        }
        if dt > 0.5 {
            update.failure = "Motion data interrupted · set position again"
            return update
        }
        recentFrames.append(raw)
        recentFrames.removeAll { frame in
            return raw.time - frame.time > 2
        }
        // Time and count bounds also protect against malformed replay rates.
        if recentFrames.count > 500 {
            recentFrames.removeFirst(recentFrames.count - 500)
        }
        guard let appleSample = project(raw, gravity: vector(raw.gravity), gyroBias: .zero) else {
            update.failure = "Mount the phone upright, with its screen facing straight back. It cannot lie flat."
            return update
        }
        if !calibrated {
            if abs(appleSample.forwardAcceleration) > 0.45 || abs(appleSample.lateralAcceleration) > 0.45 || simd_length(vector(raw.rotation)) > 0.05 {
                update.discardedCalibrationSamples = calibrationFrames.count
                calibrationFrames.removeAll(keepingCapacity: true)
                speedObserver.discardBaseline()
                return update
            }
            calibrationFrames.append(raw)
            if calibrationFrames.count > 800 {
                calibrationFrames.removeFirst(calibrationFrames.count - 800)
            }
            // The parked interval also measures the idle vibration reference.
            speedObserver.receive(time: raw.time, totalAcceleration: totalAcceleration(raw),
                                  rotation: vector(raw.rotation), gravity: vector(raw.gravity))
            speedObserver.collectBaseline(time: raw.time, calibrationStart: calibrationFrames[0].time)
            let duration = raw.time - calibrationFrames[0].time
            update.progress = min(1, duration / 4)
            if duration >= 4 && calibrationFrames.count >= 150 {
                let start = calibrationFrames[0].time
                update.calibration = calibrate(calibrationFrames, reason: "startup")
                calibrationFrames.removeAll(keepingCapacity: false)
                calibrated = update.calibration != nil
                if calibrated {
                    speedObserver.completeCalibration(start: start, end: raw.time)
                    update.calibration?.vibrationBaseline = speedObserver.baseline
                    lastCalibration = update.calibration
                } else {
                    update.failure = "Cannot establish mounted orientation · remount and calibrate"
                }
                lastOutputTime = raw.time
            }
            return update
        }

        var rotation = vector(raw.rotation) - gyroBias
        if let preceding {
            rotation = (vector(preceding.rotation) + vector(raw.rotation)) / 2 - gyroBias
        }
        let rate = simd_length(rotation)
        if rate > 1e-12 {
            gravity = simd_normalize(simd_quatd(angle: -rate * dt, axis: rotation / rate).act(gravity))
        }
        let aid = aidGravity(total: totalAcceleration(raw), rotation: rotation, dt: dt)
        guard var sample = project(raw, gravity: gravity, gyroBias: gyroBias) else {
            update.failure = "Phone orientation no longer supports tracking · remount and set position"
            return update
        }
        sample.magneticMagnitude = magneticMagnitude
        sample.relativeAltitude = relativeAltitude
        speedObserver.accumulate(forwardAcceleration: sample.forwardAcceleration, duration: dt)
        speedObserver.receive(time: raw.time, totalAcceleration: totalAcceleration(raw),
                              rotation: vector(raw.rotation), gravity: gravity)
        update.speedObservation = speedObserver.update(at: raw.time)
        let appleGravity = simd_normalize(vector(raw.gravity))
        let disagreement = acos(clamp(simd_dot(gravity, appleGravity), -1, 1))
        diagnostic = MotionProcessingDiagnostic(time: raw.time, gravity: array(gravity), gyroBias: array(gyroBias),
                                               gravityDisagreementDegrees: disagreement * 180 / .pi,
                                               forwardAccelerationDifference: sample.forwardAcceleration - appleSample.forwardAcceleration,
                                               secondsSinceCalibration: raw.time - calibrationTime,
                                               gravityCorrectionDegrees: aid.degrees,
                                               gravityCorrectionActive: aid.degrees > 0,
                                               speedAidWeight: aid.weight)
        if lastOutputTime == nil {
            lastOutputTime = raw.time
            accumulated.removeAll(keepingCapacity: true)
            return update
        }
        accumulated.append((sample, dt))
        if raw.time - (lastOutputTime ?? raw.time) < 0.05 {
            return update
        }
        let duration = accumulated.reduce(0.0) { total, item in
            return total + item.duration
        }
        sample.forwardAcceleration = average(\.forwardAcceleration, duration: duration)
        sample.lateralAcceleration = average(\.lateralAcceleration, duration: duration)
        sample.verticalAcceleration = average(\.verticalAcceleration, duration: duration)
        sample.yawRate = average(\.yawRate, duration: duration)
        accumulated.removeAll(keepingCapacity: true)
        lastOutputTime = raw.time
        update.sample = sample
        return update
    }

    /// Gravity observation = total acceleration + vehicle acceleration / g.
    /// While moving, forward vehicle acceleration is the processed value minus
    /// the speed filter's bias estimate, so only independently observed bias
    /// moves gravity (20 s blend). Using the filter's dv/dt instead is
    /// circular without an axle echo: a lagging speed absorbs sustained
    /// acceleration into gravity. Lateral uses centripetal v·yaw. When rolling
    /// vibration says parked, vehicle acceleration is zero (2 s blend), gated
    /// at 3° so a departure is never absorbed. The blend is scaled by speed
    /// confidence, and the resulting change in processed forward acceleration
    /// is handed back to the filter's bias state so the same physical bias is
    /// never removed twice.
    private func aidGravity(total: SIMD3<Double>, rotation: SIMD3<Double>, dt: Double) -> (degrees: Double, weight: Double) {
        guard speedObserver.isActive, let before = Self.axes(gravity) else {
            return (0, 0)
        }
        let observer = speedObserver
        let yaw = -simd_dot(rotation, before.up)
        let forwardBefore = simd_dot(-(total - gravity) * VehicleMotionProjection.standardGravity, before.forward)
        var vehicle = before.forward * (forwardBefore - observer.accelerationBias) + before.right * (observer.speed * yaw)
        var timeConstant = 20.0
        let weight = 1 / (1 + pow(observer.uncertainty / 1.0, 2))
        if observer.stoppedProbability > 0.95 {
            guard acos(clamp(simd_dot(simd_normalize(total), gravity), -1, 1)) < 3 * .pi / 180 else {
                return (0, weight)
            }
            vehicle = .zero
            timeConstant = 2
        }
        let measured = simd_normalize(total + vehicle / VehicleMotionProjection.standardGravity)
        let gain = min(1, dt / timeConstant) * weight
        let previous = gravity
        gravity = simd_normalize(gravity + (measured - gravity) * gain)
        guard let after = Self.axes(gravity) else {
            gravity = previous
            return (0, weight)
        }
        let forwardAfter = simd_dot(-(total - gravity) * VehicleMotionProjection.standardGravity, after.forward)
        observer.recordGravityCorrection(forwardAccelerationChange: forwardAfter - forwardBefore)
        return (acos(clamp(simd_dot(previous, gravity), -1, 1)) * 180 / .pi, weight)
    }

    private static func axes(_ gravity: SIMD3<Double>) -> (forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>)? {
        let up = -simd_normalize(gravity)
        let screenForward = SIMD3<Double>(0, 0, -1)
        let projected = screenForward - up * simd_dot(screenForward, up)
        guard simd_length(projected) > 0.45 else {
            return nil
        }
        let forward = simd_normalize(projected)
        return (forward, simd_normalize(simd_cross(forward, up)), up)
    }

    /// Only a user-confirmed parked observation authorizes a new gravity/bias
    /// reference. An inferred engine stop must never call this method.
    func confirmStop() -> CalibrationRecord? {
        guard calibrated, let first = recentFrames.first, let last = recentFrames.last,
              last.time - first.time >= 1.5, recentFrames.count >= 75 else {
            return nil
        }
        let meanRotation = mean(recentFrames) { raw in
            return self.vector(raw.rotation)
        }
        let meanAcceleration = mean(recentFrames) { raw in
            return self.totalAcceleration(raw)
        }
        let settled = recentFrames.allSatisfy { raw in
            return simd_length(self.vector(raw.rotation) - meanRotation) < 0.12
        }
        let accelerationVariance = recentFrames.reduce(0.0) { total, raw in
            return total + simd_length_squared(self.totalAcceleration(raw) - meanAcceleration) / Double(recentFrames.count)
        }
        let rotationVariance = recentFrames.reduce(0.0) { total, raw in
            return total + simd_length_squared(self.vector(raw.rotation) - meanRotation) / Double(recentFrames.count)
        }
        guard settled, simd_length(meanRotation) < 0.05, sqrt(rotationVariance) < 0.025,
              sqrt(accelerationVariance) < 0.06, simd_length(meanAcceleration) > 0.8,
              simd_length(meanAcceleration) < 1.2 else {
            return nil
        }
        guard var record = calibrate(recentFrames, reason: "confirmed-stop") else {
            return nil
        }
        // Parked again with a new gravity reference: restart the speed filter
        // at zero with fresh bias hypotheses, keeping the idle vibration level.
        speedObserver.completeCalibration(start: .infinity, end: .infinity)
        record.vibrationBaseline = speedObserver.baseline
        lastCalibration = record
        return record
    }

    private func calibrate(_ frames: [RawMotion], reason: String) -> CalibrationRecord? {
        let last = frames[frames.count - 1]
        // Startup and explicit stop are known-rest observations. Average total
        // acceleration there instead of inheriting Apple's last tilt estimate.
        let newGravity = simd_normalize(mean(frames) { raw in
            return self.totalAcceleration(raw)
        })
        guard let pose = project(last, gravity: newGravity, gyroBias: .zero) else {
            return nil
        }
        let gyroCalibration = estimateGyroBias(frames, gravity: newGravity)
        let newGyroBias = gyroCalibration.bias
        gravity = newGravity
        gyroBias = newGyroBias
        let samples = frames.compactMap { raw in
            return project(raw, gravity: gravity, gyroBias: .zero)
        }
        let count = Double(samples.count)
        let yawBias = samples.reduce(0.0) { total, sample in
            return total + sample.yawRate / count
        }
        let forwardVariance = samples.reduce(0.0) { total, sample in
            return total + pow(sample.forwardAcceleration, 2) / count
        }
        let yawVariance = samples.reduce(0.0) { total, sample in
            return total + pow(sample.yawRate - yawBias, 2) / count
        }
        calibrationTime = last.time
        accumulated.removeAll(keepingCapacity: true)
        lastOutputTime = last.time
        return CalibrationRecord(start: frames[0].time, end: last.time, sampleCount: frames.count,
                                 forwardBias: 0, lateralBias: 0, yawBias: yawBias,
                                 forwardStandardDeviation: sqrt(forwardVariance), yawStandardDeviation: sqrt(yawVariance),
                                 pitch: pose.pitch, roll: pose.roll, gyroBias: array(gyroBias), gravity: array(gravity),
                                 method: Self.method, reason: reason,
                                 measuredGyroBias: array(gyroCalibration.measured),
                                 gyroBiasStandardErrorVehicle: array(gyroCalibration.standardError))
    }

    private func estimateGyroBias(_ frames: [RawMotion], gravity: SIMD3<Double>) -> (bias: SIMD3<Double>, measured: SIMD3<Double>, standardError: SIMD3<Double>) {
        let up = -gravity
        let forward = simd_normalize(SIMD3<Double>(0, 0, -1) + up * up.z)
        let right = simd_normalize(simd_cross(forward, up))
        let axes = [right, up, forward]
        let measured = mean(frames) { raw in
            return self.vector(raw.rotation)
        }
        // Device-motion rates already have Core Motion's bias correction.
        // Engine vibration over a finite window must not become a permanent
        // additional gyro offset. Estimate uncertainty from 250 ms blocks in
        // vehicle axes, retaining the correlation between device axes.
        var blocks: [SIMD3<Double>] = []
        let start = frames[0].time
        var blockIndex = 0
        var blockSum = SIMD3<Double>.zero
        var blockCount = 0
        for frame in frames {
            let nextBlockIndex = Int((frame.time - start) / 0.25)
            if nextBlockIndex != blockIndex && blockCount > 0 {
                blocks.append(blockSum / Double(blockCount))
                blockIndex = nextBlockIndex
                blockSum = .zero
                blockCount = 0
            }
            blockSum += vector(frame.rotation)
            blockCount += 1
        }
        if frames[frames.count - 1].time - start - Double(blockIndex) * 0.25 >= 0.20 && blockCount > 0 {
            blocks.append(blockSum / Double(blockCount))
        }
        var bias = SIMD3<Double>.zero
        var standardError = SIMD3<Double>.zero
        guard blocks.count >= 4 else {
            return (bias, measured, standardError)
        }
        for (index, axis) in axes.enumerated() {
            let blockMean = blocks.reduce(0.0) { total, block in
                return total + simd_dot(block, axis) / Double(blocks.count)
            }
            let variance = blocks.reduce(0.0) { total, block in
                return total + pow(simd_dot(block, axis) - blockMean, 2) / Double(blocks.count - 1)
            }
            standardError[index] = sqrt(variance / Double(blocks.count))
            let component = simd_dot(measured, axis)
            if abs(component) > 2 * standardError[index] {
                bias += axis * component
            }
        }
        return (bias, measured, standardError)
    }

    private func project(_ raw: RawMotion, gravity: SIMD3<Double>, gyroBias: SIMD3<Double>) -> MotionSample? {
        // Apple documents userAcceleration + gravity as total acceleration.
        // Reconstruct that synchronized measurement before removing OUR gravity.
        return VehicleMotionProjection.sample(time: raw.time, userAcceleration: totalAcceleration(raw) - gravity,
                                              gravity: gravity, rotationRate: vector(raw.rotation) - gyroBias)
    }

    private func totalAcceleration(_ raw: RawMotion) -> SIMD3<Double> {
        return vector(raw.acceleration) + vector(raw.gravity)
    }

    private func vector(_ values: [Double]) -> SIMD3<Double> {
        return SIMD3(values[0], values[1], values[2])
    }

    private func array(_ vector: SIMD3<Double>) -> [Double] {
        return [vector.x, vector.y, vector.z]
    }

    private func mean(_ frames: [RawMotion], value: (RawMotion) -> SIMD3<Double>) -> SIMD3<Double> {
        return frames.reduce(SIMD3<Double>.zero) { total, raw in
            return total + value(raw) / Double(frames.count)
        }
    }

    private func average(_ key: KeyPath<MotionSample, Double>, duration: Double) -> Double {
        return accumulated.reduce(0.0) { total, item in
            return total + item.sample[keyPath: key] * item.duration / duration
        }
    }
}
