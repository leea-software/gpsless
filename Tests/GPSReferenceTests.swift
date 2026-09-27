import XCTest
@testable import GPSLessCore

final class GPSReferenceTests: XCTestCase {
    private func sample(timestamp: Double = 1_800_000_000.123456,
                        receivedTimestamp: Double = 1_800_000_000.223456,
                        receivedUptime: Double = 100.223456,
                        speed: Double = 8.5) -> GPSReferenceSample {
        return GPSReferenceSample(timestamp: timestamp, receivedTimestamp: receivedTimestamp,
                                  receivedUptime: receivedUptime,
                                  coordinate: Coordinate(latitude: 50.45, longitude: 30.52),
                                  altitude: 125.3, horizontalAccuracy: 4, verticalAccuracy: 7,
                                  speed: speed, speedAccuracy: 0.4, course: 42, courseAccuracy: 3,
                                  reducedAccuracy: false, simulatedBySoftware: false, producedByAccessory: false)
    }

    private func recorder() throws -> DriveRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = DriveRecorder(directory: directory)
        try recorder.begin(header: DriveHeader(version: 3, created: Date(), mapSnapshot: "gps-test",
                                               initialPosition: RoadPosition(edge: 0, distance: 0),
                                               initialUncertainty: 8, seed: 7829, mount: "test"))
        return recorder
    }

    func testPreciseReferenceTimesAndInvalidValuesSurviveCompressedExport() throws {
        let recorder = try recorder()
        let valid = sample()
        let invalid = GPSReferenceSample(timestamp: 1_800_000_002.5,
                                         receivedTimestamp: 1_800_000_007.75, receivedUptime: 107.75,
                                         coordinate: Coordinate(latitude: .nan, longitude: 30),
                                         altitude: .infinity, horizontalAccuracy: -1, verticalAccuracy: -1,
                                         speed: -1, speedAccuracy: -1, course: .nan, courseAccuracy: -1,
                                         reducedAccuracy: true, simulatedBySoftware: true, producedByAccessory: true)
        recorder.write(DriveEntry(kind: "gps-reference", gpsReference: valid))
        recorder.write(DriveEntry(kind: "gps-reference", gpsReference: invalid))
        recorder.finish(reason: "test")
        XCTAssertNil(recorder.failure)
        var references: [GPSReferenceSample] = []
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, _ in
            if let reference = entry.gpsReference {
                references.append(reference)
            }
        }
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references[0].timestamp, valid.timestamp)
        XCTAssertEqual(references[0].receivedTimestamp, valid.receivedTimestamp)
        XCTAssertEqual(references[0].receivedUptime, valid.receivedUptime)
        XCTAssertEqual(try XCTUnwrap(references[0].time), 100.123456, accuracy: 0.000001)
        XCTAssertEqual(references[0].speed, 8.5)
        XCTAssertNil(references[1].coordinate)
        XCTAssertNil(references[1].altitude)
        XCTAssertNil(references[1].course)
        XCTAssertEqual(references[1].speed, -1, "Unavailable speed must not become a false zero-speed reference")
        XCTAssertTrue(references[1].qualityFlags.contains("stale_fix"))
        XCTAssertTrue(references[1].qualityFlags.contains("invalid_coordinate"))
        XCTAssertTrue(references[1].qualityFlags.contains("invalid_speed"))
        XCTAssertTrue(references[1].qualityFlags.contains("software_simulation"))
        XCTAssertTrue(references[1].qualityFlags.contains("accessory_source"))
    }

    func testRateBoundUsesReceiptUptimeAndRetainsClockAndCachedFixWarnings() throws {
        var capture = GPSReferenceCapture(startTimestamp: 1000, startUptime: 100)
        let cached = sample(timestamp: 990, receivedTimestamp: 1000, receivedUptime: 100)
        let first = try XCTUnwrap(capture.record(cached))
        XCTAssertTrue(first.qualityFlags.contains("predates_trace"))
        XCTAssertTrue(first.qualityFlags.contains("stale_fix"))
        XCTAssertNil(capture.record(sample(timestamp: 1000.2, receivedTimestamp: 1000.2, receivedUptime: 100.2)))
        let duplicate = try XCTUnwrap(capture.record(sample(timestamp: 990, receivedTimestamp: 1001, receivedUptime: 101)))
        XCTAssertTrue(duplicate.qualityFlags.contains("non_increasing_fix_timestamp"))
        let clockChange = try XCTUnwrap(capture.record(sample(timestamp: 1062, receivedTimestamp: 1062, receivedUptime: 102)))
        XCTAssertTrue(clockChange.qualityFlags.contains("wall_clock_changed"))
        XCTAssertEqual(capture.recordedCount, 3)
        XCTAssertEqual(capture.throttledCount, 1)
        let replacement = GPSReferenceCapture(startTimestamp: 1063, startUptime: 103)
        XCTAssertNotEqual(replacement.id, capture.id)
        XCTAssertEqual(replacement.recordedCount, 0)
    }

    func testFutureAndPoorAccuracyFixesRemainLabeledReferenceData() throws {
        let value = GPSReferenceSample(timestamp: 1005, receivedTimestamp: 1000, receivedUptime: 100,
                                       coordinate: Coordinate(latitude: 50, longitude: 30),
                                       altitude: 120, horizontalAccuracy: 200, verticalAccuracy: 70,
                                       speed: 20, speedAccuracy: 8, course: -1, courseAccuracy: -1,
                                       reducedAccuracy: true, simulatedBySoftware: false, producedByAccessory: false)
        XCTAssertTrue(value.qualityFlags.contains("future_fix"))
        XCTAssertTrue(value.qualityFlags.contains("poor_horizontal_accuracy"))
        XCTAssertTrue(value.qualityFlags.contains("poor_speed_accuracy"))
        XCTAssertTrue(value.qualityFlags.contains("reduced_accuracy"))
        XCTAssertEqual(value.speed, 20)
        XCTAssertEqual(value.horizontalAccuracy, 200)
    }

    func testConflictingGPSReferencesCannotChangeReplaySpeedPositionOrStopState() throws {
        let points = [Vector2(0, 0), Vector2(0, 2000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight", kind: "residential", points: points)
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "gps-test", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])))
        let baseline = TrackingEngine(graph: graph)
        let replay = TrackingEngine(graph: graph)
        baseline.start(at: RoadPosition(edge: 0, distance: 100))
        replay.start(at: RoadPosition(edge: 0, distance: 100))
        let recorder = try recorder()
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 5 {
                acceleration = 1
            } else if time >= 15 && time < 20 {
                acceleration = -1
            }
            let motion = MotionSample(time: time, forwardAcceleration: acceleration)
            _ = baseline.process(motion)
            recorder.write(DriveEntry(kind: "sample", sample: motion))
            if tick.isMultiple(of: 20) {
                var speed = 0.0
                if tick.isMultiple(of: 40) {
                    speed = 100
                }
                // Even an extra sample payload on a GPS row must be ignored.
                recorder.write(DriveEntry(kind: "gps-reference", sample: MotionSample(time: time + 0.01, forwardAcceleration: 20),
                                          gpsReference: sample(timestamp: time, receivedTimestamp: time, receivedUptime: time, speed: speed)))
                recorder.write(DriveEntry(kind: "gps-trace-event", event: "confirmed-stop"))
            }
        }
        recorder.finish(reason: "test")
        try RecordingReader.read(try XCTUnwrap(recorder.url)) { entry, _ in
            _ = entry.applyMotion(to: replay)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(baseline.estimate), try encoder.encode(replay.estimate))
        XCTAssertEqual(try encoder.encode(baseline.diagnostic(at: 30)), try encoder.encode(replay.diagnostic(at: 30)))
        XCTAssertEqual(baseline.lastStopCorrection?.decision, replay.lastStopCorrection?.decision)
    }

    func testReferenceStorageIsSmallAtOneFixPerSecond() throws {
        let recorder = try recorder()
        var capture = GPSReferenceCapture(startTimestamp: 1_800_000_000, startUptime: 100)
        for tick in 0..<600 {
            let seconds = Double(tick) / 10
            let reference = sample(timestamp: 1_800_000_000 + seconds,
                                   receivedTimestamp: 1_800_000_000 + seconds + 0.1,
                                   receivedUptime: 100 + seconds,
                                   speed: 8 + sin(seconds) * 3)
            if let recorded = capture.record(reference) {
                recorder.write(DriveEntry(kind: "gps-reference", gpsReference: recorded))
            }
        }
        recorder.finish(reason: "test")
        XCTAssertEqual(capture.recordedCount, 60)
        XCTAssertEqual(capture.throttledCount, 540)
        XCTAssertNil(recorder.failure)
        let bytes = try Data(contentsOf: XCTUnwrap(recorder.url)).count
        XCTAssertLessThan(bytes, 50_000, "One minute of reference data should be tens of KB, not MB")
        print("GPS reference benchmark: \(bytes) compressed bytes for 60 observations")
    }
}
