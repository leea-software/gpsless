import Foundation
import simd

// Compiled with the unmodified Core sources. Ground truth never enters here.
struct SimulationInput: Decodable {
    let mode: String
    let mapSnapshot: String
    let initialPosition: RoadPosition
    let initialUncertainty: Double
    let seed: UInt64
    let route: [Int]?
    let wheelbase: Double?
}

struct ReplayRow: Encodable {
    let time: Double
    let sample: MotionSample
    let estimate: TrackingEstimate?
    let signals: [RoadSignalEvent]
    let roadMatch: RoadMatchUpdate?
    let diagnostic: EngineDiagnostic?
    let stopCorrection: StopCorrection?
}

enum SimulationError: Error {
    case invalidInput(String)
}

func run() throws {
    guard CommandLine.arguments.count == 5 else {
        throw SimulationError.invalidInput("Expected graph, config, stream, output paths")
    }
    let urls = CommandLine.arguments.dropFirst().map { path in
        return URL(fileURLWithPath: path)
    }
    let graph = try RoadGraph(data: Data(contentsOf: urls[0]))
    let input = try JSONDecoder().decode(SimulationInput.self, from: Data(contentsOf: urls[1]))
    guard input.mapSnapshot == graph.dataset.generated,
          graph.edges.indices.contains(input.initialPosition.edge),
          input.initialPosition.distance >= 0,
          input.initialPosition.distance <= graph.edges[input.initialPosition.edge].length,
          input.initialUncertainty.isFinite,
          input.initialUncertainty >= 0 else {
        throw SimulationError.invalidInput("Map snapshot or initial road position mismatch")
    }
    if let route = input.route {
        guard route.first == input.initialPosition.edge else {
            throw SimulationError.invalidInput("Route must start on selected edge")
        }
        for pair in zip(route, route.dropFirst()) {
            guard graph.edges.indices.contains(pair.0), graph.successors(of: pair.0).contains(pair.1) else {
                throw SimulationError.invalidInput("Route contains an illegal transition")
            }
        }
    }
    var selectedRoute: SelectedRoute?
    if let edges = input.route, let last = edges.last {
        selectedRoute = SelectedRoute(start: input.initialPosition,
                                      destination: RoadPosition(edge: last, distance: graph.edges[last].length),
                                      edges: edges)
    }
    let engine = TrackingEngine(graph: graph, seed: input.seed, route: selectedRoute)
    engine.start(at: input.initialPosition, uncertainty: input.initialUncertainty)
    FileManager.default.createFile(atPath: urls[3].path, contents: nil)
    let output = try FileHandle(forWritingTo: urls[3])
    defer {
        try? output.close()
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var origin: Double?
    var lastOutput = -Double.infinity
    var lastUpdate = -Double.infinity
    var lastDiagnostic = -Double.infinity
    // Synthetic streams do not model the axle echo yet, so vibration speed
    // contributes only its parked/rolling evidence there.
    let processor = VehicleMotionProcessor(wheelbase: input.wheelbase ?? VehicleSpeedObserver.defaultWheelbase)
    var count = 0

    func process(_ sample: MotionSample) throws {
        if origin == nil {
            origin = sample.time
        }
        guard sample.time.isFinite, sample.forwardAcceleration.isFinite,
              sample.lateralAcceleration.isFinite, sample.yawRate.isFinite else {
            throw SimulationError.invalidInput("Non-finite sensor sample")
        }
        count += 1
        let estimate = engine.process(sample)
        let signals = engine.drainRoadSignals()
        var update: RoadMatchUpdate?
        if let candidate = engine.lastRoadUpdate, candidate.time > lastUpdate {
            lastUpdate = candidate.time
            update = candidate
        }
        var diagnostic: EngineDiagnostic?
        if sample.time - lastDiagnostic >= 1 {
            lastDiagnostic = sample.time
            diagnostic = engine.diagnostic(at: sample.time)
        }
        // Retain every processed sample, but only new estimates/diagnostics.
        var freshEstimate: TrackingEstimate?
        if let estimate, estimate.time > lastOutput {
            lastOutput = estimate.time
            freshEstimate = estimate
        }
        var stopCorrection: StopCorrection?
        if let correction = engine.lastStopCorrection, correction.time == sample.time {
            stopCorrection = correction
        }
        let row = ReplayRow(time: sample.time - (origin ?? sample.time), sample: sample,
                            estimate: freshEstimate, signals: signals,
                            roadMatch: update, diagnostic: diagnostic, stopCorrection: stopCorrection)
        try output.write(contentsOf: encoder.encode(row) + Data([0x0a]))
    }

    try RecordingReader.read(urls[2]) { entry, _ in
        if input.mode == "recorded" {
            if entry.kind == "event", entry.event == "confirmed-stop" {
                engine.confirmStop(resetMotionCalibration: entry.metrics?["motionCalibrationReset"] == 1)
            }
            if entry.kind == "sample", let sample = entry.sample {
                try process(sample)
            }
            if entry.kind == "visual-speed", let observation = entry.visualSpeed?.observation {
                _ = engine.applyVisualSpeed(observation)
            }
            if entry.kind == "vibration-speed", let observation = entry.vibrationSpeed {
                _ = engine.applyVibrationSpeed(observation)
            }
            return
        }
        guard input.mode == "raw", entry.kind == "raw", let raw = entry.raw else {
            throw SimulationError.invalidInput("Expected valid synthetic raw device motion")
        }
        let update = processor.receive(raw)
        if let failure = update.failure {
            throw SimulationError.invalidInput(failure)
        }
        if let observation = update.speedObservation {
            _ = engine.applyVibrationSpeed(observation)
        }
        if let sample = update.sample {
            try process(sample)
        }
    }
    guard count > 0 else {
        throw SimulationError.invalidInput("No driving samples: check stream/calibration")
    }
    let result: [String: Any] = ["engine": TrackingEngine.version, "sampleCount": count,
                                "timeOrigin": origin ?? 0,
                                "failure": engine.estimate?.failure?.reason.rawValue ?? "none"]
    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result) + Data([0x0a]))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Simulation bridge: \(error)\n".utf8))
    exit(1)
}
