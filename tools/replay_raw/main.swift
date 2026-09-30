import Foundation

// Recordings made before engine 3.0 carry no wheelbase; pass the car's value
// with --wheelbase=METRES. Otherwise the header value or the default applies.
var wheelbaseOverride: Double?
var arguments: [String] = []
for argument in CommandLine.arguments {
    if argument.hasPrefix("--wheelbase=") {
        wheelbaseOverride = Double(argument.dropFirst("--wheelbase=".count))
        guard let value = wheelbaseOverride, VehicleSpeedObserver.supportedWheelbase.contains(value) else {
            fatalError("Wheelbase must be between 2 and 4 metres")
        }
    } else {
        arguments.append(argument)
    }
}
guard (5...6).contains(arguments.count), let duration = Double(arguments[4]), duration > 0 else {
    fatalError("Usage: replay-raw [--wheelbase=METRES] graph.json drive.jsonl.gz output.jsonl maximum-seconds [assumed-route.json]")
}
let graph = try RoadGraph(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
var assumedRoute: SelectedRoute?
if arguments.count == 6 {
    assumedRoute = try JSONDecoder().decode(SelectedRoute.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[5])))
    guard assumedRoute?.isValid(in: graph) == true else {
        fatalError("Assumed route does not match the road graph")
    }
}
let input = URL(fileURLWithPath: arguments[2])
let destination = URL(fileURLWithPath: arguments[3])
FileManager.default.createFile(atPath: destination.path, contents: nil)
let output = try FileHandle(forWritingTo: destination)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
var processor = VehicleMotionProcessor()
var engine: TrackingEngine?
var origin: Double?
var lastEstimate = 0.0
var lastDiagnostic = 0.0
var lastUpdate = 0.0
var failure: String?
var sampleCount = 0
var limitReached = false
var calibrationSource = "parked calibration in this recording"

let reusedCalibrationMarker = "reused-from-current-app-session"

/// The recording a reusing drive took its calibration from, next to it.
func previousRecording(of url: URL, header: DriveHeader) -> URL? {
    guard let name = header.metadata?["previousRecording"], !name.isEmpty else {
        return nil
    }
    let directory = url.deletingLastPathComponent()
    let base = name.hasSuffix(".gz") ? String(name.dropLast(3)) : name
    return [base + ".gz", base].map { candidate in
        return directory.appendingPathComponent(candidate)
    }.first { candidate in
        return FileManager.default.fileExists(atPath: candidate.path)
    }
}

/// Before 0.4.2 a drive that reused the app's calibration did not record it.
/// Running the earlier drives' raw motion through a processor rebuilds the
/// gravity, gyro bias and parked vibration baseline the app carried over.
func primedProcessor(from url: URL, depth: Int = 0) throws -> VehicleMotionProcessor? {
    guard depth < 8 else {
        return nil
    }
    var primed: VehicleMotionProcessor?
    var failed = false
    try RecordingReader.read(url) { entry, _ in
        if let header = entry.header {
            let wheelbase = header.metadata?["wheelbaseMetres"].flatMap(Double.init) ?? VehicleSpeedObserver.defaultWheelbase
            if header.metadata?["startupCalibration"] == reusedCalibrationMarker,
               let prior = previousRecording(of: url, header: header),
               let carried = try primedProcessor(from: prior, depth: depth + 1) {
                carried.adoptWheelbase(wheelbase)
                carried.beginSession(reusingCalibration: true)
                primed = carried
            } else {
                primed = VehicleMotionProcessor(wheelbase: wheelbase)
            }
            return
        }
        guard let processor = primed, !failed else {
            return
        }
        if entry.kind == "calibration", let calibration = entry.calibration, calibration.reason == "reused" {
            processor.resume(from: calibration)
        } else if entry.kind == "event", entry.event == "confirmed-stop" {
            _ = processor.confirmStop()
        } else if entry.kind == "raw", let raw = entry.raw, processor.receive(raw).failure != nil {
            failed = true
        }
    }
    return primed?.calibrated == true ? primed : nil
}

func write(_ entry: DriveEntry) throws {
    try output.write(contentsOf: encoder.encode(entry) + Data([0x0a]))
}

try RecordingReader.read(input) { entry, _ in
    guard !limitReached else {
        return
    }
    if let header = entry.header {
        guard (2...4).contains(header.version), (header.version < 4 || header.route != nil),
              header.mapSnapshot == graph.dataset.generated, graph.edges.indices.contains(header.initialPosition.edge),
              header.initialPosition.distance.isFinite, header.initialPosition.distance >= 0,
              header.initialPosition.distance <= graph.edges[header.initialPosition.edge].length,
              header.initialUncertainty.isFinite, header.initialUncertainty >= 0 else {
            throw NSError(domain: "RawReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording map does not match graph"])
        }
        if let route = header.route, !route.isValid(in: graph) {
            throw NSError(domain: "RawReplay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recorded route does not match graph"])
        }
        let route = assumedRoute ?? header.route
        if let route, route.offset(of: header.initialPosition, graph: graph) == nil {
            fatalError("Replay starting position is outside the supplied route")
        }
        let wheelbase = wheelbaseOverride ?? header.metadata?["wheelbaseMetres"].flatMap(Double.init) ?? VehicleSpeedObserver.defaultWheelbase
        processor = VehicleMotionProcessor(wheelbase: wheelbase)
        if header.metadata?["startupCalibration"] == reusedCalibrationMarker {
            if let prior = previousRecording(of: input, header: header), let carried = try primedProcessor(from: prior) {
                carried.adoptWheelbase(wheelbase)
                carried.beginSession(reusingCalibration: true)
                processor = carried
                calibrationSource = "carried over from \(prior.lastPathComponent)"
            } else {
                calibrationSource = "reused on the phone but not available; waits for a parked calibration"
            }
        }
        let tracker = TrackingEngine(graph: graph, seed: header.seed, route: route)
        if let weight = header.metadata?["wheelbaseEvidenceWeight"].flatMap(Double.init),
           let metres = header.metadata?["wheelbaseEvidenceMetres"].flatMap(Double.init),
           let intervals = header.metadata?["wheelbaseEvidenceIntervals"].flatMap(Int.init) {
            tracker.seedWheelbaseCalibration(WheelbaseEvidence(weight: weight, weightedMetres: metres * weight, intervals: intervals))
        }
        tracker.appliesWheelbaseCalibration = header.metadata?["wheelbaseCalibrationApplied"] != "false"
        tracker.start(at: header.initialPosition, uncertainty: header.initialUncertainty)
        engine = tracker
        var copy = entry
        copy.header?.route = route
        if copy.header?.metadata == nil {
            copy.header?.metadata = [:]
        }
        copy.header?.metadata?["reprocessedWithEngine"] = TrackingEngine.version
        copy.header?.metadata?["reprocessedWithMotion"] = VehicleMotionProcessor.method
        copy.header?.metadata?["reprocessedWithWheelbaseMetres"] = String(format: "%.3f", processor.wheelbase)
        copy.header?.metadata?["reprocessedCalibration"] = calibrationSource
        copy.header?.metadata?["validation"] = "Raw replay; no independent field ground truth"
        if assumedRoute != nil {
            copy.header?.metadata?["routeSource"] = "Retrospective assumed route; not selected by the driver before recording"
        }
        try write(copy)
    }
    guard let engine, failure == nil else {
        return
    }
    if entry.kind == "gps-reference" {
        try write(entry)
    }
    if entry.kind == "visual-speed", var diagnostic = entry.visualSpeed {
        if let observation = diagnostic.observation {
            let result = engine.applyVisualSpeed(observation)
            diagnostic.accepted = result.accepted
            diagnostic.reason = result.reason
            diagnostic.fusedSpeedBefore = result.before
            diagnostic.fusedSpeedAfter = result.after
            diagnostic.fusedPositionChangeMetres = 0
        }
        try write(DriveEntry(kind: "visual-speed", visualSpeed: diagnostic))
    }
    if entry.kind == "calibration", let calibration = entry.calibration, calibration.reason == "reused", sampleCount == 0,
       processor.resume(from: calibration) {
        calibrationSource = "reused calibration recorded at the start"
    }
    if entry.kind == "event", entry.event == "confirmed-stop" {
        let calibration = processor.confirmStop()
        engine.confirmStop(resetMotionCalibration: calibration != nil)
        var marker = entry
        marker.metrics = ["motionCalibrationReset": 0]
        if let calibration {
            try write(DriveEntry(kind: "calibration", calibration: calibration))
            marker.metrics = ["motionCalibrationReset": 1]
        }
        try write(marker)
    }
    guard entry.kind == "raw", let raw = entry.raw else {
        return
    }
    if origin == nil {
        origin = raw.time
    }
    guard raw.time - (origin ?? raw.time) <= duration else {
        limitReached = true
        return
    }
    let result = processor.receive(raw)
    if let error = result.failure {
        failure = error
        return
    }
    if let calibration = result.calibration {
        try write(DriveEntry(kind: "calibration", calibration: calibration))
    }
    if let observation = result.speedObservation {
        _ = engine.applyVibrationSpeed(observation)
        try write(DriveEntry(kind: "vibration-speed", vibrationSpeed: observation))
    }
    guard let sample = result.sample else {
        return
    }
    sampleCount += 1
    try write(DriveEntry(kind: "sample", sample: sample))
    guard let estimate = engine.process(sample) else {
        return
    }
    if estimate.time > lastEstimate {
        lastEstimate = estimate.time
        try write(DriveEntry(kind: "estimate", estimate: estimate))
    }
    if let update = engine.lastRoadUpdate, update.time > lastUpdate {
        lastUpdate = update.time
        try write(DriveEntry(kind: "road-update", roadMatch: update))
    }
    for signal in engine.drainRoadSignals() {
        try write(DriveEntry(kind: "road-signal", roadSignal: signal))
    }
    for evidence in engine.drainRouteEvidenceEvents() {
        try write(DriveEntry(kind: "route-evidence", routeEvidence: evidence))
    }
    for calibration in engine.drainWheelbaseCalibrationEvents() {
        try write(DriveEntry(kind: "wheelbase-calibration", wheelbaseCalibration: calibration))
    }
    if let correction = engine.lastStopCorrection, correction.time == sample.time {
        try write(DriveEntry(kind: "stop-correction", stopCorrection: correction))
    }
    if sample.time - lastDiagnostic >= 1 {
        lastDiagnostic = sample.time
        try write(DriveEntry(kind: "engine-state", engineState: engine.diagnostic(at: sample.time)))
        try write(DriveEntry(kind: "motion-processing", motionProcessing: processor.diagnostic))
    }
    if estimate.needsReset {
        failure = estimate.status
    }
}
try output.close()
let summary: [String: Any] = ["engine": TrackingEngine.version, "motionProcessing": VehicleMotionProcessor.method,
                              "samples": sampleCount, "status": engine?.estimate?.status ?? "no samples",
                              "failure": failure ?? "none", "speedCorrections": engine?.speedCorrectionCount ?? 0,
                              "noIndependentFieldGroundTruth": true, "calibration": calibrationSource]
try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) + Data([0x0a]))
