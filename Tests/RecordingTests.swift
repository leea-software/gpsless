import Foundation
import XCTest
@testable import GPSLessCore

final class RecordingTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func header() -> DriveHeader {
        return DriveHeader(version: 3, created: Date(timeIntervalSince1970: 1_800_000_000), mapSnapshot: "test-map", initialPosition: RoadPosition(edge: 0, distance: 12), initialUncertainty: 8, seed: 7829, mount: "portrait", sessionID: "test-session", startUptime: 99.123456, metadata: ["engineVersion": "test", "hardwareModel": "test"])
    }

    func testSelectedRoutePersistsOnceInVersionFourRecording() throws {
        let route = SelectedRoute(start: RoadPosition(edge: 0, distance: 12), destination: RoadPosition(edge: 2, distance: 50), edges: [0, 1, 2])
        let recorder = DriveRecorder(directory: try temporaryDirectory())
        try recorder.begin(header: DriveHeader(version: 4, created: Date(), mapSnapshot: "test-map",
                                               initialPosition: route.start, initialUncertainty: 8, seed: 7829,
                                               mount: "portrait", route: route))
        for index in 0..<100 {
            recorder.write(DriveEntry(kind: "sample", sample: MotionSample(time: Double(index), forwardAcceleration: 0)))
        }
        recorder.finish(reason: "test")
        XCTAssertNil(recorder.failure)
        var headers: [DriveHeader] = []
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, _ in
            if let header = entry.header {
                headers.append(header)
            }
        }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?.version, 4)
        XCTAssertEqual(headers.first?.route, route)
    }

    func testRecordingPersistsAllStreamsAndFooterAcrossBuffers() throws {
        let recorder = DriveRecorder(directory: try temporaryDirectory())
        try recorder.begin(header: header())
        let calibration = CalibrationRecord(start: 99, end: 103, sampleCount: 400, forwardBias: 0.02, lateralBias: -0.01, yawBias: 0.003, forwardStandardDeviation: 0.03, yawStandardDeviation: 0.001, pitch: 0.2, roll: 0)
        recorder.write(DriveEntry(kind: "calibration", calibration: calibration))
        for index in 0..<1800 {
            let time = 103 + Double(index) * 0.01
            recorder.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: "accelerometer", time: time, values: [0.1, -1, 0.02], units: "g")))
            recorder.write(DriveEntry(kind: "sample", sample: MotionSample(time: time, forwardAcceleration: 0.1)))
        }
        recorder.finish(reason: "test-pause")
        XCTAssertNil(recorder.failure)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-t", try XCTUnwrap(recorder.url).path]
        try gzip.run()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0, "Export must be a standard readable gzip file")
        var rows: [DriveEntry] = []
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, progress in
            XCTAssertGreaterThan(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
            rows.append(entry)
        }
        XCTAssertEqual(rows.count, 3603)
        XCTAssertEqual(rows.first?.header?.metadata?["hardwareModel"], "test")
        XCTAssertEqual(rows.first?.header?.startUptime, 99.123456)
        XCTAssertEqual(rows[1].calibration?.sampleCount, 400)
        XCTAssertEqual(rows.last?.event, "test-pause")
        XCTAssertEqual(rows.last?.metrics?["rows.sensor"], 1800)
        XCTAssertEqual(rows.last?.metrics?["rows.sample"], 1800)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.sequence, index + 1)
            XCTAssertNotNil(row.receivedUptime)
        }
        XCTAssertEqual(rows[3600].sensor?.time ?? 0, 120.99, accuracy: 1e-10)
    }

    func testInterruptedFinalRowRecoversCompleteSamples() throws {
        let url = try temporaryDirectory().appendingPathComponent("interrupted.jsonl")
        let content = "{\"kind\":\"event\",\"event\":\"saved\"}\n{\"kind\":\"raw\",\"raw\":{\"time\":12"
        try Data(content.utf8).write(to: url)
        var events: [String] = []
        try RecordingReader.read(url) { entry, _ in
            events.append(entry.kind)
        }
        XCTAssertEqual(events, ["event"])
    }

    func testCorruptionInsideRecordingIsNotSilentlySkipped() throws {
        let url = try temporaryDirectory().appendingPathComponent("damaged.jsonl")
        try Data("{\"kind\":\"event\"}\nbroken\n{\"kind\":\"event\"}\n".utf8).write(to: url)
        XCTAssertThrowsError(try RecordingReader.read(url) { _, _ in
        })
    }

    func testFieldReferenceSurvivesWithoutStartingAnotherDrive() throws {
        let directory = try temporaryDirectory()
        let reference = ManualReference(observedAt: Date(timeIntervalSince1970: 1_800_000_000), observedUptime: 412.123456, coordinate: Coordinate(latitude: 50.45, longitude: 30.52), position: RoadPosition(edge: 12, distance: 33.4), previousEstimate: nil, previousRecording: "earlier.jsonl", note: "Stopped at the junction", odometerKilometres: 45678.2)
        let url = try FieldReferenceStore.save(reference, metadata: ["sourceSHA256": "test-hash"], mapSnapshot: "map-1", directory: directory)
        var recorded: DriveEntry?
        try RecordingReader.read(url) { entry, _ in
            recorded = entry
        }
        XCTAssertEqual(recorded?.reference?.observedUptime, reference.observedUptime)
        XCTAssertEqual(recorded?.reference?.odometerKilometres, 45678.2)
        XCTAssertEqual(recorded?.reference?.previousRecording, "earlier.jsonl")
        XCTAssertEqual(recorded?.details?["mapSnapshot"], "map-1")
        XCTAssertEqual(recorded?.details?["sourceSHA256"], "test-hash")
    }

    func testOriginalVersionTwoHeaderRemainsReadable() throws {
        let url = try temporaryDirectory().appendingPathComponent("v2.jsonl")
        let content = "{\"kind\":\"header\",\"header\":{\"version\":2,\"created\":\"2026-09-09T21:11:01Z\",\"mapSnapshot\":\"map\",\"initialPosition\":{\"edge\":0,\"distance\":8},\"initialUncertainty\":8,\"seed\":7829,\"mount\":\"portrait\"}}\n"
        try Data(content.utf8).write(to: url)
        var header: DriveHeader?
        try RecordingReader.read(url) { entry, _ in
            header = entry.header
        }
        XCTAssertEqual(header?.version, 2)
        XCTAssertNil(header?.metadata)
        XCTAssertEqual(header?.initialPosition.distance, 8)
    }

    func testReplayIgnoresCalibrationDiagnosticsAndPreservesExplicitStops() throws {
        let first = Coordinate(metres: Vector2(0, 0))
        let last = Coordinate(metres: Vector2(0, 2000))
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Replay road", kind: "residential", points: [[first.longitude, first.latitude], [last.longitude, last.latitude]])
        let dataset = RoadDataset(generated: "test-map", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])
        let graph = try RoadGraph(data: JSONEncoder().encode(dataset))
        let header = header()
        let live = TrackingEngine(graph: graph, seed: header.seed)
        live.start(at: header.initialPosition, uncertainty: header.initialUncertainty)
        let recorder = DriveRecorder(directory: try temporaryDirectory())
        try recorder.begin(header: header)
        recorder.write(DriveEntry(kind: "calibration-restarted", sample: MotionSample(time: 100, forwardAcceleration: 0.6)))
        for tick in 0...300 {
            let time = 104.2 + Double(tick) * 0.05
            var acceleration = 0.05
            if tick > 0 && tick <= 40 {
                acceleration += 1
            } else if tick > 80 && tick <= 120 {
                acceleration -= 1
            }
            let sample = MotionSample(time: time, forwardAcceleration: acceleration)
            _ = live.process(sample)
            recorder.write(DriveEntry(kind: "sample", sample: sample))
            if tick == 165 {
                live.confirmStop()
                recorder.write(DriveEntry(kind: "event", event: "confirmed-stop"))
            }
        }
        recorder.finish(reason: "Test complete")
        let replay = TrackingEngine(graph: graph, seed: header.seed)
        replay.start(at: header.initialPosition, uncertainty: header.initialUncertainty)
        var ignoredCalibration = false
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, _ in
            let result = entry.applyMotion(to: replay)
            if entry.kind == "calibration-restarted" {
                XCTAssertNil(result)
                ignoredCalibration = true
            }
        }
        XCTAssertTrue(ignoredCalibration)
        XCTAssertFalse(try XCTUnwrap(replay.estimate).needsReset)
        XCTAssertEqual(replay.estimate?.position, live.estimate?.position)
        XCTAssertEqual(replay.estimate?.speed, 0)
        XCTAssertEqual(replay.estimate?.uncertainty, live.estimate?.uncertainty)
        XCTAssertEqual(replay.diagnostic(at: 120).roadHypotheses.first?.accelerationBias, live.diagnostic(at: 120).roadHypotheses.first?.accelerationBias)
    }

    func testReplayAppliesOnlyAcceptedVisualSpeedRows() throws {
        let first = Coordinate(metres: Vector2(0, 0))
        let last = Coordinate(metres: Vector2(0, 2000))
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Replay road",
                              kind: "residential",
                              points: [[first.longitude, first.latitude], [last.longitude, last.latitude]])
        let dataset = RoadDataset(generated: "test-map", bounds: [50, 30, 51, 31],
                                  roads: [road], restrictions: [])
        let engine = TrackingEngine(graph: try RoadGraph(data: JSONEncoder().encode(dataset)))
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 1))
        _ = engine.process(MotionSample(time: 1.1, forwardAcceleration: 1))
        _ = engine.process(MotionSample(time: 1.2, forwardAcceleration: 1))
        let speedBefore = try XCTUnwrap(engine.estimate).speed
        let rejected = VisualSpeedDiagnostic(time: 1.1, previousTime: 0.9,
                                             region: [0, 0, 1, 1], cameraHeightMetres: 1.2,
                                             focalPixels: [520, 520], candidateCount: 4,
                                             inlierCount: 0, medianTexture: 0.01,
                                             visualSpeed: 20, uncertainty: 1.2, quality: 0.9,
                                             accepted: false, reason: "low_texture")
        XCTAssertNil(DriveEntry(kind: "visual-speed", visualSpeed: rejected).applyMotion(to: engine))
        XCTAssertEqual(engine.estimate?.speed, speedBefore)
        let accepted = VisualSpeedDiagnostic(time: 1.1, previousTime: 0.9,
                                             region: [0, 0, 1, 1], cameraHeightMetres: 1.2,
                                             focalPixels: [520, 520], candidateCount: 40,
                                             inlierCount: 32, medianTexture: 0.4,
                                             visualSpeed: 20, uncertainty: 1.2, quality: 0.9,
                                             accepted: true, reason: "accepted_auxiliary_speed")
        XCTAssertNotNil(DriveEntry(kind: "visual-speed", visualSpeed: accepted).applyMotion(to: engine))
        XCTAssertGreaterThan(try XCTUnwrap(engine.estimate).speed, speedBefore)
    }

    func testTrackingFailureCauseAndMeasurementsSurviveExport() throws {
        let recorder = DriveRecorder(directory: try temporaryDirectory())
        try recorder.begin(header: header())
        let estimate = TrackingEstimate(time: 104, position: RoadPosition(edge: 0, distance: 12), coordinate: Coordinate(latitude: 50.45, longitude: 30.52), heading: 0, speed: 0, uncertainty: 8, roadProbability: 1, status: "Motion data interrupted", anchorCount: 0, turnDegrees: 0, travelled: 0, alternatives: [], needsReset: true, failure: TrackingFailure(reason: .sensorGap, measurements: ["gapSeconds": 0.8, "maximumGapSeconds": 0.5]))
        recorder.write(DriveEntry(kind: "decision", estimate: estimate, event: estimate.status))
        recorder.finish(reason: estimate.status)
        var recovered: TrackingFailure?
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, _ in
            if let failure = entry.estimate?.failure {
                recovered = failure
            }
        }
        XCTAssertEqual(recovered?.reason, .sensorGap)
        XCTAssertEqual(recovered?.measurements["gapSeconds"], 0.8)
        XCTAssertEqual(recovered?.measurements["maximumGapSeconds"], 0.5)
    }

    func testIncompleteCompressedDriveRecoversFlushedRows() throws {
        let directory = try temporaryDirectory()
        let recorder = DriveRecorder(directory: directory)
        try recorder.begin(header: header())
        for index in 0..<2000 {
            recorder.write(DriveEntry(kind: "sample", sample: MotionSample(time: Double(index) * 0.05, forwardAcceleration: sin(Double(index)))))
        }
        let data = try Data(contentsOf: XCTUnwrap(recorder.url))
        let interrupted = directory.appendingPathComponent("interrupted.jsonl.gz")
        try Data(data.dropLast(7)).write(to: interrupted)
        recorder.finish(reason: "Original closed after snapshot")
        var count = 0
        try RecordingReader.read(interrupted) { entry, _ in
            if entry.sample != nil {
                count += 1
            }
            XCTAssertNotEqual(entry.kind, "footer")
        }
        XCTAssertGreaterThan(count, 100)
        XCTAssertLessThanOrEqual(count, 2000)
    }

    func testOneMinuteRecordingStorageBudget() throws {
        let recorder = DriveRecorder(directory: try temporaryDirectory())
        try recorder.begin(header: header())
        var random = SeededRandom(seed: 127)
        for tick in 0..<6000 {
            let time = 103 + Double(tick) * 0.01
            let acceleration = [random.normal() * 0.02, random.normal() * 0.02, random.normal() * 0.02]
            let rotation = [random.normal() * 0.005, random.normal() * 0.005, random.normal() * 0.005]
            let gravity = [random.normal() * 0.001, -0.98 + random.normal() * 0.001, -0.2 + random.normal() * 0.001]
            let magnetic = [22 + random.normal(), -16 + random.normal(), 40 + random.normal()]
            recorder.write(DriveEntry(kind: "raw", raw: RawMotion(time: time, acceleration: acceleration, rotation: rotation, gravity: gravity, quaternion: [random.normal() * 0.01, random.normal() * 0.01, random.normal() * 0.01, 0.999 + random.normal() * 0.001], magneticField: magnetic, magneticAccuracy: -1)))
            recorder.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: "accelerometer", time: time, values: zip(acceleration, gravity).map { acceleration, gravity in
                return acceleration + gravity
            }, units: "g")))
            recorder.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: "gyroscope", time: time, values: rotation, units: "rad/s")))
            if tick.isMultiple(of: 5) {
                recorder.write(DriveEntry(kind: "sample", sample: MotionSample(time: time, forwardAcceleration: acceleration[2] * 9.80665, lateralAcceleration: acceleration[0] * 9.80665, verticalAcceleration: acceleration[1] * 9.80665, yawRate: rotation[1])))
            }
            if tick.isMultiple(of: 20) {
                recorder.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: "magnetometer", time: time, values: magnetic, units: "microtesla")))
                let coordinate = Coordinate(latitude: 50.45 + time / 1_000_000, longitude: 30.52)
                let estimate = TrackingEstimate(time: time, position: RoadPosition(edge: 1, distance: time), coordinate: coordinate, heading: random.normal() * 0.01, speed: 10 + random.normal() * 0.2, uncertainty: 10 + time / 30, roadProbability: 0.94, status: "Tracking", anchorCount: 0, turnDegrees: 0, travelled: time * 10, alternatives: [coordinate], needsReset: false)
                recorder.write(DriveEntry(kind: "estimate", estimate: estimate))
                recorder.write(DriveEntry(kind: "road-update", roadMatch: RoadMatchUpdate(time: time, predictionBeforeRoadEvidence: coordinate, previousEstimate: estimate, result: estimate, adjustmentEastMetres: random.normal(), adjustmentNorthMetres: random.normal(), positionAdjustmentMetres: 1, headingResidualDegrees: 0.1)))
                let visual = VisualSpeedDiagnostic(time: time, previousTime: time - 0.2,
                                                   region: [0.08, 0.38, 0.84, 0.42],
                                                   cameraHeightMetres: 1.2,
                                                   focalPixels: [520, 520],
                                                   candidateCount: 80, inlierCount: 52,
                                                   medianTexture: 0.31,
                                                   visualSpeed: 10 + random.normal() * 0.2,
                                                   uncertainty: 1.4, quality: 0.72,
                                                   accepted: true,
                                                   reason: "accepted_auxiliary_speed",
                                                   fusedSpeedBefore: 10,
                                                   fusedSpeedAfter: 10.02,
                                                   fusedPositionChangeMetres: 0)
                recorder.write(DriveEntry(kind: "visual-speed", visualSpeed: visual))
            }
            if tick.isMultiple(of: 100) {
                recorder.write(DriveEntry(kind: "sensor", sensor: SensorReading(sensor: "barometer", time: time, values: [random.normal(), 100 + random.normal() * 0.01], units: "relative metres, kPa")))
                recorder.write(DriveEntry(kind: "context", metrics: ["batteryLevel": 0.8, "capturedUptime": time], details: ["thermalState": "nominal"], wallTime: Date()))
                let hypotheses = (0..<24).map { edge in
                    return RoadHypothesis(edge: edge, probability: 1 / 24, distance: time + Double(edge), speed: 10 + random.normal(), accelerationBias: random.normal() * 0.01, gyroBias: random.normal() * 0.001)
                }
                let stop = StopEvidence(meanAcceleration: 0.01, accelerationStandardDeviation: 0.1, verticalRMS: 0.2, yawRMS: 0.01, quietSeconds: 0, recentBraking: false, speedBelowLimit: false, nearZeroProbability: 0.02, decision: "not_settled")
                recorder.write(DriveEntry(kind: "engine-state", engineState: EngineDiagnostic(time: time, particleCount: 384, effectiveParticleCount: 300, confirmedStopped: false, unanchoredMovingTime: time, headingMismatchTime: 0, turnIntegral: 0, roadHypotheses: hypotheses, stopEvidence: stop)))
                let processing = MotionProcessingDiagnostic(time: time, gravity: gravity, gyroBias: [0.001, -0.001, 0.0001], gravityDisagreementDegrees: time * 0.01, forwardAccelerationDifference: 0.1, secondsSinceCalibration: time - 103)
                recorder.write(DriveEntry(kind: "motion-processing", motionProcessing: processing))
            }
        }
        recorder.finish(reason: "One-minute storage benchmark")
        XCTAssertNil(recorder.failure)
        let bytes = try XCTUnwrap(recorder.url).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("RECORDING_BUDGET: 60 seconds, \(bytes) compressed bytes, \(bytes * 60) projected bytes/hour")
        XCTAssertGreaterThan(bytes, 100_000)
        XCTAssertLessThan(bytes, 4_000_000, "A one-minute full-rate sensor recording must remain below 4 MB in this noisy benchmark")
    }
}
