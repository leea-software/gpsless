import Foundation

struct ManualReference: Codable {
    let observedAt: Date
    let observedUptime: Double
    let coordinate: Coordinate
    let position: RoadPosition
    let previousEstimate: TrackingEstimate?
    let previousRecording: String?
    let note: String
    var odometerKilometres: Double?
}

struct DriveHeader: Codable {
    let version: Int
    let created: Date
    let mapSnapshot: String
    let initialPosition: RoadPosition
    let initialUncertainty: Double
    let seed: UInt64
    let mount: String
    var sessionID: String?
    var startUptime: Double?
    var metadata: [String: String]?
    var reference: ManualReference?
    var route: SelectedRoute? = nil
}

struct RawMotion: Codable {
    let time: Double
    let acceleration: [Double]
    let rotation: [Double]
    let gravity: [Double]
    let quaternion: [Double]
    var magneticField: [Double]?
    var magneticAccuracy: Int?
}

struct SensorReading: Codable {
    let sensor: String
    let time: Double
    let values: [Double]
    let units: String
}

struct CalibrationRecord: Codable {
    let start: Double
    let end: Double
    let sampleCount: Int
    let forwardBias: Double
    let lateralBias: Double
    let yawBias: Double
    let forwardStandardDeviation: Double
    let yawStandardDeviation: Double
    let pitch: Double
    let roll: Double
    var gyroBias: [Double]? = nil
    var gravity: [Double]? = nil
    var method: String? = nil
    var reason: String? = nil
    var measuredGyroBias: [Double]? = nil
    /// Standard error in vehicle right, up and forward axes, in rad/s.
    var gyroBiasStandardErrorVehicle: [Double]? = nil
    /// Parked idle vibration level the speed observer measures against; nil
    /// when the parked interval was silent. Recorded from 0.4.2 so a drive that
    /// reuses the calibration replays without its predecessor.
    var vibrationBaseline: Double? = nil
}

/// Written only by the September 15 engine 2.1 route-gate builds. The gate was
/// superseded by RouteEvidenceMatcher; the type remains so those recordings decode.
struct RouteConstraintEvent: Codable {
    let time: Double
    let stage: String
    let reason: String
    let landmarkIndex: Int
    let landmarkStartMetres: Double
    let landmarkMidpointMetres: Double
    let landmarkEndMetres: Double
    let expectedTurnDegrees: Double
    let observedTurnDegrees: Double
    let allowedRouteOffsetMetres: Double
    let affectedProbability: Double
    let speedBeforeMetresPerSecond: Double
    let speedAfterMetresPerSecond: Double
    let waitingSeconds: Double
}

struct DriveEntry: Codable {
    var kind: String
    var header: DriveHeader?
    var sample: MotionSample?
    var raw: RawMotion?
    var estimate: TrackingEstimate?
    var event: String?
    var sensor: SensorReading?
    var calibration: CalibrationRecord?
    var motionProcessing: MotionProcessingDiagnostic?
    var reference: ManualReference?
    var engineState: EngineDiagnostic?
    var roadMatch: RoadMatchUpdate?
    var roadSignal: RoadSignalEvent?
    var routeConstraint: RouteConstraintEvent?
    var routeEvidence: RouteEvidenceEvent?
    var stopCorrection: StopCorrection?
    var visualSpeed: VisualSpeedDiagnostic?
    var vibrationSpeed: VibrationSpeedObservation?
    var wheelbaseCalibration: WheelbaseCalibrationEvent?
    var gpsReference: GPSReferenceSample?
    var metrics: [String: Double]?
    var details: [String: String]?
    var sequence: Int?
    var receivedUptime: Double?
    var wallTime: Date?

    /// Replay accepted inputs in their original sequence. Diagnostics and
    /// rejected visual observations never become engine inputs. GPS reference
    /// rows are intentionally ignored, including invalid or simulated fixes.
    /// Vibration speed rows are derived from the raw IMU on the phone; replay
    /// uses them as recorded (raw replay recomputes them).
    func applyMotion(to engine: TrackingEngine) -> TrackingEstimate? {
        if kind == "event" && event == "confirmed-stop" {
            engine.confirmStop(resetMotionCalibration: metrics?["motionCalibrationReset"] == 1)
        }
        if kind == "sample", let sample {
            return engine.process(sample)
        }
        if kind == "visual-speed", let observation = visualSpeed?.observation {
            _ = engine.applyVisualSpeed(observation)
            return engine.estimate
        }
        if kind == "vibration-speed", let vibrationSpeed {
            _ = engine.applyVibrationSpeed(vibrationSpeed)
            return engine.estimate
        }
        return nil
    }
}

/// Incremental decoding keeps multi-hour recordings out of a single giant
/// String allocation. Only an incomplete final row may be discarded.
struct RecordingReader {
    static func read(_ url: URL, visit: (DriveEntry, Double) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var pending = Data()
        var consumed = 0
        func consume(_ chunk: Data) throws {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                let row = pending.prefix(upTo: newline)
                guard row.count <= 2_000_000 else {
                    throw NSError(domain: "Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording row is too large or damaged."])
                }
                let entry = try decoder.decode(DriveEntry.self, from: row)
                try visit(entry, min(1, Double(consumed) / Double(max(1, size))))
                pending.removeSubrange(...newline)
            }
            if pending.count > 2_000_000 {
                throw NSError(domain: "Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording row is too large or damaged."])
            }
        }
        var chunk = try handle.read(upToCount: 65_536) ?? Data()
        var decompressor: GzipDecoder?
        if chunk.starts(with: [0x1f, 0x8b]) {
            decompressor = try GzipDecoder()
        }
        while !chunk.isEmpty {
            consumed += chunk.count
            if let decompressor {
                try decompressor.consume(chunk, receive: consume)
            } else {
                try consume(chunk)
            }
            chunk = try handle.read(upToCount: 65_536) ?? Data()
        }
        if !pending.isEmpty, let entry = try? decoder.decode(DriveEntry.self, from: pending) {
            try visit(entry, 1)
        }
    }
}
