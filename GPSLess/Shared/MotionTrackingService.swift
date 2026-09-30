import CoreMotion
import Foundation

final class MotionTrackingService {
    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "software.leea.gpsless.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var engine: TrackingEngine?
    private var recorder: DriveRecorder?
    private var generation = UUID()
    private var processor = VehicleMotionProcessor()
    private var magneticMagnitude: Double?
    private var altitude: Double?
    private var lastEngineTime = 0.0
    private var lastReportTime = 0.0
    private var lastDiagnosticTime = 0.0
    private var lastMotionTime: Double?
    private var lastStatus = ""
    private var lastAnchorCount = 0
    private var lastRoadUpdateTime = 0.0

    var onCalibration: ((Double, String) -> Void)?
    var onUpdate: ((TrackingEstimate, MotionSample, String?, Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFinished: ((URL?) -> Void)?
    var onVibrationSpeed: ((VibrationSpeedObservation) -> Void)?
    /// A road-bump measurement corrected the inertial speed; carries the count so far.
    var onSpeedCorrection: ((SpeedCorrection, Int) -> Void)?
    var onWheelbaseEvidence: ((WheelbaseEvidence) -> Void)?

    func start(graph: RoadGraph, position: RoadPosition, uncertainty: Double, metadata: [String: String], sessionID: UUID, route: SelectedRoute? = nil, reuseCalibration: Bool = false, wheelbase: Double = VehicleSpeedObserver.defaultWheelbase, wheelbaseEvidence: WheelbaseEvidence? = nil, refinesWheelbase: Bool = true) {
        stop(reason: "Restart")
        guard manager.isDeviceMotionAvailable else {
            onFailure?("Motion sensors are unavailable. Use a physical iPhone for tracking.")
            return
        }
        let token = sessionID
        queue.addOperation {
            self.generation = token
            self.engine = TrackingEngine(graph: graph, route: route)
            if let wheelbaseEvidence {
                self.engine?.seedWheelbaseCalibration(wheelbaseEvidence)
            }
            self.engine?.appliesWheelbaseCalibration = refinesWheelbase
            self.engine?.start(at: position, uncertainty: uncertainty)
            if reuseCalibration && self.processor.calibrated {
                self.processor.adoptWheelbase(wheelbase)
                self.processor.beginSession(reusingCalibration: true)
            } else {
                self.processor = VehicleMotionProcessor(wheelbase: wheelbase)
                self.processor.beginSession(reusingCalibration: false)
            }
            self.lastEngineTime = 0
            self.lastReportTime = 0
            self.lastDiagnosticTime = 0
            self.lastMotionTime = nil
            self.lastStatus = ""
            self.lastAnchorCount = 0
            self.lastRoadUpdateTime = 0
            self.magneticMagnitude = nil
            self.altitude = nil
            let recorder = DriveRecorder()
            do {
                var metadata = metadata
                metadata["deviceMotionAvailable"] = String(self.manager.isDeviceMotionAvailable)
                metadata["accelerometerAvailable"] = String(self.manager.isAccelerometerAvailable)
                metadata["gyroAvailable"] = String(self.manager.isGyroAvailable)
                metadata["magnetometerAvailable"] = String(self.manager.isMagnetometerAvailable)
                metadata["relativeAltitudeAvailable"] = String(CMAltimeter.isRelativeAltitudeAvailable())
                metadata["referenceFrame"] = "xArbitraryZVertical"
                metadata["requestedRatesHz"] = "deviceMotion=100,accelerometer=100,gyro=100,magnetometer=5,engine=20,estimate=5,diagnostic=1"
                metadata["axes"] = "device x right, y top, z out of screen; vehicle forward=-screen normal projected horizontal, right=forward cross up; yaw clockwise positive"
                metadata["accelerationConvention"] = VehicleMotionProjection.convention
                metadata["motionProcessing"] = VehicleMotionProcessor.method
                metadata["wheelbaseMetres"] = String(format: "%.3f", self.processor.wheelbase)
                metadata["wheelbaseCalibrationApplied"] = String(refinesWheelbase)
                if let wheelbaseEvidence, let estimate = wheelbaseEvidence.estimate {
                    metadata["wheelbaseEvidenceWeight"] = String(wheelbaseEvidence.weight)
                    metadata["wheelbaseEvidenceMetres"] = String(estimate)
                    metadata["wheelbaseEvidenceIntervals"] = String(wheelbaseEvidence.intervals)
                }
                metadata["vibrationSpeedModel"] = "axle echo: rear axle repeats front-axle road input after wheelbase/speed; 4 s whitened multi-axis correlation every 0.5 s; speed/bias grid filter; parked-idle vibration baseline"
                if reuseCalibration && self.processor.calibrated {
                    metadata["startupCalibration"] = "reused-from-current-app-session"
                } else {
                    metadata["startupCalibration"] = "required"
                }
                metadata["processedUnits"] = "physical acceleration=-(CoreMotion userAcceleration+CoreMotion gravity-gyro-propagated gravity)*9.80665 in vehicle axes, m/s^2; calibrated yaw rad/s clockwise positive"
                metadata["rawUnits"] = "acceleration g; rotation rad/s; quaternion x,y,z,w; magnetic field microtesla; pressure kPa; relative altitude m; timestamps seconds since boot"
                var recordingVersion = 3
                if route != nil {
                    recordingVersion = 4
                }
                try recorder.begin(header: DriveHeader(version: recordingVersion, created: Date(), mapSnapshot: graph.dataset.generated, initialPosition: position, initialUncertainty: uncertainty, seed: 7829, mount: "portrait, screen facing straight back, vehicle stopped", sessionID: token.uuidString, startUptime: ProcessInfo.processInfo.systemUptime, metadata: metadata, reference: nil, route: route))
                if reuseCalibration && self.processor.calibrated, let reused = self.processor.reusedCalibration() {
                    // Replays start from this instead of the previous drive.
                    recorder.write(DriveEntry(kind: "calibration", calibration: reused, wallTime: Date()))
                }
                self.recorder = recorder
            } catch {
                DispatchQueue.main.async {
                    self.onFailure?("Cannot create drive recording: \(error.localizedDescription)")
                }
                return
            }
            self.manager.deviceMotionUpdateInterval = 0.01
            self.manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: self.queue) { [weak self] motion, error in
                guard let self, self.generation == token else {
                    return
                }
                if let error {
                    self.fail(error.localizedDescription)
                    return
                }
                guard let motion else {
                    return
                }
                self.receive(motion)
            }
            if self.manager.isAccelerometerAvailable {
                self.manager.accelerometerUpdateInterval = 0.01
                self.manager.startAccelerometerUpdates(to: self.queue) { [weak self] data, error in
                    guard let self, self.generation == token else {
                        return
                    }
                    if let error {
                        self.recordSensorError("accelerometer", error: error)
                    }
                    if let data {
                        let vector = data.acceleration
                        self.recordSensor("accelerometer", time: data.timestamp, values: [vector.x, vector.y, vector.z], units: "g")
                    }
                }
            }
            if self.manager.isGyroAvailable {
                self.manager.gyroUpdateInterval = 0.01
                self.manager.startGyroUpdates(to: self.queue) { [weak self] data, error in
                    guard let self, self.generation == token else {
                        return
                    }
                    if let error {
                        self.recordSensorError("gyroscope", error: error)
                    }
                    if let data {
                        let vector = data.rotationRate
                        self.recordSensor("gyroscope", time: data.timestamp, values: [vector.x, vector.y, vector.z], units: "rad/s")
                    }
                }
            }
            if self.manager.isMagnetometerAvailable {
                self.manager.magnetometerUpdateInterval = 0.2
                self.manager.startMagnetometerUpdates(to: self.queue) { [weak self] data, error in
                    guard let self, self.generation == token else {
                        return
                    }
                    if let error {
                        self.recordSensorError("magnetometer", error: error)
                    }
                    if let data {
                        let field = data.magneticField
                        self.magneticMagnitude = sqrt(field.x * field.x + field.y * field.y + field.z * field.z)
                        self.recordSensor("magnetometer", time: data.timestamp, values: [field.x, field.y, field.z], units: "microtesla")
                    }
                }
            }
            if CMAltimeter.isRelativeAltitudeAvailable() {
                self.altimeter.startRelativeAltitudeUpdates(to: self.queue) { [weak self] data, error in
                    guard let self, self.generation == token else {
                        return
                    }
                    if let error {
                        self.recordSensorError("barometer", error: error)
                    }
                    if let data {
                        self.altitude = data.relativeAltitude.doubleValue
                        self.recordSensor("barometer", time: data.timestamp, values: [data.relativeAltitude.doubleValue, data.pressure.doubleValue], units: "relative metres, kPa")
                    }
                }
            }
        }
    }

    func stop(reason: String) {
        queue.addOperation {
            self.stopSensors()
            self.recorder?.finish(reason: reason)
            let url = self.recorder?.url
            self.recorder = nil
            self.engine = nil
            if let url {
                DispatchQueue.main.async {
                    self.onFinished?(url)
                }
            }
        }
    }

    func confirmStop() {
        queue.addOperation {
            guard let engine = self.engine else {
                return
            }
            let calibration = self.processor.confirmStop()
            if let calibration {
                self.recorder?.write(DriveEntry(kind: "calibration", calibration: calibration, wallTime: Date()))
            }
            engine.confirmStop(resetMotionCalibration: calibration != nil)
            var reset = 0.0
            if calibration != nil {
                reset = 1
            }
            self.recorder?.write(DriveEntry(kind: "event", event: "confirmed-stop", engineState: engine.diagnostic(at: self.lastEngineTime), metrics: ["motionCalibrationReset": reset]))
        }
    }

    func recordContext(metrics: [String: Double], details: [String: String]) {
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.addOperation {
            var metrics = metrics
            metrics["capturedUptime"] = uptime
            self.recorder?.write(DriveEntry(kind: "context", metrics: metrics, details: details, wallTime: date))
        }
    }

    /// The reference sidecar can only append GPS rows to its original drive.
    /// It deliberately has no call to the motion processor or tracking engine.
    func recordGPSReference(_ entry: DriveEntry, sessionID: UUID) {
        guard entry.kind == "gps-reference" || entry.kind == "gps-trace-event" else {
            return
        }
        queue.addOperation {
            guard self.generation == sessionID else {
                return
            }
            self.recorder?.write(entry)
        }
    }

    private func recordSensor(_ sensor: String, time: Double, values: [Double], units: String) {
        recorder?.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: sensor, time: time, values: values, units: units)))
    }

    private func recordSensorError(_ sensor: String, error: Error) {
        recorder?.write(DriveEntry(kind: "sensor-error", event: error.localizedDescription, details: ["sensor": sensor], wallTime: Date()))
    }

    private func stopSensors() {
        generation = UUID()
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func receive(_ motion: CMDeviceMotion) {
        let gravity = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        let rotation = SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
        let attitude = motion.attitude.quaternion
        let magnetic = motion.magneticField
        let raw = RawMotion(time: motion.timestamp, acceleration: [motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z], rotation: [rotation.x, rotation.y, rotation.z], gravity: [gravity.x, gravity.y, gravity.z], quaternion: [attitude.x, attitude.y, attitude.z, attitude.w], magneticField: [magnetic.field.x, magnetic.field.y, magnetic.field.z], magneticAccuracy: Int(magnetic.accuracy.rawValue))
        recorder?.write(DriveEntry(kind: "raw", raw: raw))
        if let previous = lastMotionTime, motion.timestamp - previous > 0.03 {
            recorder?.write(DriveEntry(kind: "sensor-gap", metrics: ["previousTime": previous, "time": motion.timestamp, "gapSeconds": motion.timestamp - previous]))
        }
        lastMotionTime = motion.timestamp
        let update = processor.receive(raw, magneticMagnitude: magneticMagnitude, relativeAltitude: altitude)
        if let failure = update.failure {
            recorder?.write(DriveEntry(kind: "motion-processing-error", event: failure))
            fail(failure)
            return
        }
        if update.discardedCalibrationSamples > 0 {
            recorder?.write(DriveEntry(kind: "calibration-restarted", metrics: ["discardedSamples": Double(update.discardedCalibrationSamples)]))
        }
        if let calibration = update.calibration {
            recorder?.write(DriveEntry(kind: "calibration", calibration: calibration, wallTime: Date()))
            DispatchQueue.main.async {
                self.onCalibration?(1, "Calibrated · ready to drive")
            }
        } else if !processor.calibrated && motion.timestamp - lastReportTime > 0.1 {
            lastReportTime = motion.timestamp
            DispatchQueue.main.async {
                self.onCalibration?(update.progress, "Keep the car stopped and the phone mounted")
            }
        }
        if let observation = update.speedObservation, let engine {
            let corrections = engine.speedCorrectionCount
            _ = engine.applyVibrationSpeed(observation)
            recorder?.write(DriveEntry(kind: "vibration-speed", vibrationSpeed: observation))
            let correction = engine.speedCorrectionCount > corrections ? engine.lastSpeedCorrection : nil
            if let correction {
                recorder?.write(DriveEntry(kind: "speed-correction", metrics: ["time": correction.time, "speedBefore": correction.before,
                                                                               "speedMeasured": correction.measured,
                                                                               "count": Double(engine.speedCorrectionCount)]))
            }
            let count = engine.speedCorrectionCount
            DispatchQueue.main.async {
                self.onVibrationSpeed?(observation)
                if let correction {
                    self.onSpeedCorrection?(correction, count)
                }
            }
        }
        guard let sample = update.sample else {
            return
        }
        lastEngineTime = sample.time
        recorder?.write(DriveEntry(kind: "sample", sample: sample))
        guard let result = engine?.process(sample) else {
            return
        }
        if let update = engine?.lastRoadUpdate, update.time > lastRoadUpdateTime {
            lastRoadUpdateTime = update.time
            recorder?.write(DriveEntry(kind: "road-update", roadMatch: update))
        }
        for signal in engine?.drainRoadSignals() ?? [] {
            recorder?.write(DriveEntry(kind: "road-signal", roadSignal: signal))
        }
        for evidence in engine?.drainRouteEvidenceEvents() ?? [] {
            recorder?.write(DriveEntry(kind: "route-evidence", routeEvidence: evidence))
        }
        let calibrations = engine?.drainWheelbaseCalibrationEvents() ?? []
        for calibration in calibrations {
            recorder?.write(DriveEntry(kind: "wheelbase-calibration", wheelbaseCalibration: calibration))
        }
        if calibrations.contains(where: { event in
            return event.stage == "accepted"
        }), let evidence = engine?.wheelbaseEvidence {
            DispatchQueue.main.async {
                self.onWheelbaseEvidence?(evidence)
            }
        }
        if let correction = engine?.lastStopCorrection, correction.time == sample.time {
            recorder?.write(DriveEntry(kind: "stop-correction", stopCorrection: correction))
        }
        if result.status != lastStatus || result.anchorCount != lastAnchorCount {
            recorder?.write(DriveEntry(kind: "decision", estimate: result, event: result.status, engineState: engine?.diagnostic(at: sample.time)))
            lastStatus = result.status
            lastAnchorCount = result.anchorCount
        }
        if sample.time - lastDiagnosticTime >= 1 {
            lastDiagnosticTime = sample.time
            recorder?.write(DriveEntry(kind: "engine-state", engineState: engine?.diagnostic(at: sample.time)))
            recorder?.write(DriveEntry(kind: "motion-processing", motionProcessing: processor.diagnostic))
        }
        if sample.time - lastReportTime >= 0.2 || result.needsReset {
            lastReportTime = sample.time
            recorder?.write(DriveEntry(kind: "estimate", estimate: result))
            let notice = recorder?.failure
            let bytes = recorder?.bytesOnDisk ?? 0
            DispatchQueue.main.async {
                self.onUpdate?(result, sample, notice, bytes)
            }
        }
        if result.needsReset {
            stopSensors()
            recorder?.finish(reason: result.status)
            let url = recorder?.url
            DispatchQueue.main.async {
                self.onFinished?(url)
            }
        }
    }

    private func fail(_ message: String) {
        stopSensors()
        recorder?.finish(reason: message)
        let url = recorder?.url
        DispatchQueue.main.async {
            self.onFailure?(message)
            self.onFinished?(url)
        }
    }
}
