import XCTest
import simd
@testable import GPSLessCore

final class VehicleSpeedObserverTests: XCTestCase {
    private let gravity = SIMD3<Double>(0, -1, 0)

    func testRadixTwoTransformMatchesDirectFourierSum() {
        var random = SeededRandom(seed: 3)
        let size = 64
        let input = (0..<size).map { _ in
            return random.normal()
        }
        var real = input
        var imaginary = [Double](repeating: 0, count: size)
        RadixTwoFFT(size: size).forward(&real, &imaginary)
        for bin in 0..<size {
            var expectedReal = 0.0
            var expectedImaginary = 0.0
            for (index, value) in input.enumerated() {
                let angle = -2 * Double.pi * Double(bin * index) / Double(size)
                expectedReal += value * cos(angle)
                expectedImaginary += value * sin(angle)
            }
            XCTAssertEqual(real[bin], expectedReal, accuracy: 1e-9)
            XCTAssertEqual(imaginary[bin], expectedImaginary, accuracy: 1e-9)
        }
    }

    /// The rear axle repeats the front axle's road input one wheelbase later.
    /// That delay must recover cruise speed even with a forward accelerometer
    /// bias that would otherwise drift speed by several metres per second.
    func testAxleEchoRecoversCruiseSpeedDespiteAccelerometerBias() throws {
        let processor = VehicleMotionProcessor(wheelbase: 2.7)
        var road = SyntheticRoadVibration(wheelbase: 2.7)
        var speed = 0.0
        var cruise: [VibrationSpeedObservation] = []
        for tick in 0...9000 {
            let time = Double(tick) * 0.01
            var acceleration = 0.0
            if time > 5 && time <= 15 {
                acceleration = 1.2
            }
            speed += acceleration * 0.01
            road.advance(speed: speed, duration: 0.01)
            let vibration = road.sample()
            var total = gravity + SIMD3(0, 0, acceleration / 9.80665) + vibration.acceleration
            if time > 5 {
                // Uncalibrated forward bias: 0.08 m/s² would add 6 m/s in 75 s.
                total.z += 0.08 / 9.80665
            }
            let update = processor.receive(raw(time: time, total: total, rotation: vibration.rotation))
            XCTAssertNil(update.failure)
            if let observation = update.speedObservation, time > 60 {
                cruise.append(observation)
            }
        }
        XCTAssertGreaterThan(cruise.count, 50)
        let mean = cruise.reduce(0) { total, observation in
            return total + observation.speed
        } / Double(cruise.count)
        XCTAssertEqual(mean, 12, accuracy: 0.6)
        for observation in cruise {
            XCTAssertEqual(observation.speed, 12, accuracy: 1.5)
            XCTAssertLessThan(observation.stoppedProbability, 0.01)
            XCTAssertEqual(observation.wheelbase, 2.7)
        }
    }

    /// At 120 km/h the echo delay of a 2.7 m wheelbase is 81 ms, below the
    /// former 0.1 s limit that held measured speed near 97 km/h.
    func testAxleEchoMeasuresHighwaySpeed() throws {
        let processor = VehicleMotionProcessor(wheelbase: 2.7)
        var road = SyntheticRoadVibration(wheelbase: 2.7, length: 5000)
        let target = 120 / 3.6
        var speed = 0.0
        var cruise: [VibrationSpeedObservation] = []
        for tick in 0...9000 {
            let time = Double(tick) * 0.01
            var acceleration = 0.0
            if time > 5 && speed < target {
                acceleration = 2.5
            }
            speed += acceleration * 0.01
            road.advance(speed: speed, duration: 0.01)
            let vibration = road.sample()
            var total = gravity + SIMD3(0, 0, acceleration / 9.80665) + vibration.acceleration
            if time > 5 {
                total.z += 0.08 / 9.80665
            }
            let update = processor.receive(raw(time: time, total: total, rotation: vibration.rotation))
            XCTAssertNil(update.failure)
            if let observation = update.speedObservation, time > 60 {
                cruise.append(observation)
            }
        }
        XCTAssertGreaterThan(cruise.count, 50)
        let mean = cruise.reduce(0) { total, observation in
            return total + observation.speed
        } / Double(cruise.count)
        XCTAssertEqual(mean, target, accuracy: 1)
        for observation in cruise {
            XCTAssertEqual(observation.speed, target, accuracy: 2.5)
        }
    }

    func testIdleVibrationIsObservedAsParked() throws {
        let processor = VehicleMotionProcessor()
        var road = SyntheticRoadVibration()
        var observations: [VibrationSpeedObservation] = []
        for tick in 0...3000 {
            let time = Double(tick) * 0.01
            let noise = road.sample()
            let idle = SIMD3<Double>(0, 0.004 * sin(time * 26 * .pi), 0.002 * sin(time * 52 * .pi))
            let update = processor.receive(raw(time: time, total: gravity + noise.acceleration + idle, rotation: noise.rotation))
            if let observation = update.speedObservation {
                observations.append(observation)
            }
        }
        XCTAssertGreaterThan(observations.count, 40)
        for observation in observations {
            XCTAssertGreaterThan(observation.stoppedProbability, 0.9)
            XCTAssertLessThan(observation.speed, 0.3)
        }
    }

    /// A numerically silent sensor carries no vibration evidence. The observer
    /// then stays silent and leaves gravity to gyroscope propagation.
    func testSilentSensorEmitsNoVibrationEvidence() throws {
        let processor = VehicleMotionProcessor()
        var observed = false
        for tick in 0...2000 {
            let update = processor.receive(raw(time: Double(tick) * 0.01, total: gravity, rotation: .zero))
            if update.speedObservation != nil {
                observed = true
            }
        }
        XCTAssertTrue(processor.calibrated)
        XCTAssertFalse(processor.speedObserver.isActive)
        XCTAssertFalse(observed)
    }

    func testVibrationSpeedReweightsEngineTowardMeasuredSpeed() throws {
        let engine = try engine()
        var time = 0.0
        for _ in 0..<100 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 1))
            time += 0.05
        }
        let before = try XCTUnwrap(engine.estimate).speed
        XCTAssertEqual(before, 5, accuracy: 0.6)
        for tick in 0..<400 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
            if tick.isMultiple(of: 10) {
                let result = engine.applyVibrationSpeed(observation(time: time, speed: 8, uncertainty: 0.3))
                XCTAssertTrue(result.accepted, result.reason)
            }
            time += 0.05
        }
        let after = try XCTUnwrap(engine.estimate)
        XCTAssertEqual(after.speed, 8, accuracy: 0.5)
        XCTAssertFalse(after.needsReset, after.status)
    }

    /// In a slow turn the vibration filter held two modes and reported their
    /// mean, 75 ± 36 km/h; a fixed 10% pull toward it carried the engine to
    /// 110 km/h. Six such observations would close half the gap from 30 km/h;
    /// a spread that wide must barely move the estimate.
    func testWideVibrationSpeedBarelyMovesEngine() throws {
        let engine = try engine()
        var time = 0.0
        for _ in 0..<167 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 1))
            time += 0.05
        }
        let before = try XCTUnwrap(engine.estimate).speed
        XCTAssertEqual(before, 30 / 3.6, accuracy: 0.8)
        for tick in 0..<60 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
            if tick.isMultiple(of: 10) {
                let result = engine.applyVibrationSpeed(observation(time: time, speed: 75 / 3.6, uncertainty: 36 / 3.6))
                XCTAssertTrue(result.accepted, result.reason)
            }
            time += 0.05
        }
        XCTAssertEqual(try XCTUnwrap(engine.estimate).speed, before, accuracy: 1)
    }

    /// On field drives tyre vibration correlated at 0.785, 1.57 and 2.36 axle
    /// delays, and its first tooth held the speed 1.27 times too high. With
    /// the echo and that comb equally strong, the echo's speed must score and
    /// the tooth's speed must not.
    func testRepeatingWheelCombScoresBelowTheAxleEcho() throws {
        let wheelbase = 2.85
        let filter = SpeedGridFilter(wheelbase: wheelbase)
        let speed = 13.8
        let delay = wheelbase / speed * AxleEchoAnalyzer.sampleRate * Double(AxleEchoAnalyzer.lagResolution)
        let period = 0.785 * delay
        var residual = [Double](repeating: 0, count: AxleEchoAnalyzer.maximumLag * AxleEchoAnalyzer.lagResolution)
        for centre in [delay, period, 2 * period, 3 * period] {
            for index in residual.indices {
                residual[index] += exp(-0.5 * pow((Double(index) - centre) / 3, 2))
            }
        }
        let echoRow = try XCTUnwrap(SpeedGridFilter.speeds.firstIndex { abs($0 - speed) < 0.01 })
        let toothRow = try XCTUnwrap(SpeedGridFilter.speeds.firstIndex { abs($0 - speed / 0.785) < 0.11 })
        XCTAssertGreaterThan(filter.echoEvidence(residual, row: echoRow), 0.9)
        XCTAssertLessThan(filter.echoEvidence(residual, row: toothRow), 0)
    }

    func testStaleAndOutOfOrderVibrationObservationsAreRejected() throws {
        let engine = try engine()
        for tick in 0..<40 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 1))
        }
        XCTAssertEqual(engine.applyVibrationSpeed(observation(time: 0.2, speed: 8, uncertainty: 0.3)).reason, "stale_vibration_observation")
        XCTAssertTrue(engine.applyVibrationSpeed(observation(time: 1.9, speed: 2, uncertainty: 0.3)).accepted)
        XCTAssertEqual(engine.applyVibrationSpeed(observation(time: 1.8, speed: 2, uncertainty: 0.3)).reason, "out_of_order_vibration_observation")
    }

    /// Parked vibration confirms a stop even when integrated acceleration never
    /// observed the braking, which is how the old engine drove through jams.
    func testParkedVibrationStopsEngineWithoutObservedBraking() throws {
        let engine = try engine()
        var time = 0.0
        for _ in 0..<100 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 1))
            time += 0.05
        }
        XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
        for tick in 0..<100 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
            if tick.isMultiple(of: 10) {
                _ = engine.applyVibrationSpeed(observation(time: time, speed: 0.02, uncertainty: 0.1, stopped: 0.99))
            }
            time += 0.05
        }
        XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
        XCTAssertEqual(engine.estimate?.speed, 0)
        XCTAssertEqual(engine.diagnostic(at: time).stopEvidence?.vibrationStopSupported, true)
    }

    /// Creeping is too gentle for the acceleration impulse, but rolling
    /// vibration with an echo speed releases the stop.
    func testRollingVibrationReleasesStopWhileCreeping() throws {
        let engine = try engine()
        var time = 0.0
        for _ in 0..<60 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
            time += 0.05
        }
        XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
        for tick in 0..<60 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 0.03))
            if tick.isMultiple(of: 10) {
                _ = engine.applyVibrationSpeed(observation(time: time, speed: 1.5, uncertainty: 0.3, stopped: 0.01))
            }
            time += 0.05
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
        XCTAssertGreaterThan(estimate.speed, 1)
    }

    /// Measured speed bounds position uncertainty on a long straight. Without it
    /// the t² allowance reached the 350 m reset within five minutes.
    func testMeasuredSpeedKeepsLongStraightUncertaintyBounded() throws {
        let engine = try engine()
        var time = 0.0
        for _ in 0..<200 {
            _ = engine.process(MotionSample(time: time, forwardAcceleration: 1))
            time += 0.05
        }
        for tick in 0..<7200 {
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: 0)))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            if tick.isMultiple(of: 10) {
                _ = engine.applyVibrationSpeed(observation(time: time, speed: 10, uncertainty: 0.4))
            }
            time += 0.05
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertLessThan(final.uncertainty, 200)
        XCTAssertGreaterThan(final.uncertainty, 30)
    }

    func testVibrationSpeedRowRoundTripsAndReplays() throws {
        let engine = try engine()
        for tick in 0..<100 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 1))
        }
        let entry = DriveEntry(kind: "vibration-speed", vibrationSpeed: observation(time: 4.96, speed: 7, uncertainty: 0.3))
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.vibrationSpeed?.speed, 7)
        XCTAssertEqual(decoded.vibrationSpeed?.wheelbase, 2.7)
        let before = try XCTUnwrap(engine.estimate).speed
        let estimate = try XCTUnwrap(decoded.applyMotion(to: engine))
        XCTAssertGreaterThan(estimate.speed, before)
    }

    private func observation(time: Double, speed: Double, uncertainty: Double, stopped: Double = 0) -> VibrationSpeedObservation {
        return VibrationSpeedObservation(time: time, speed: speed, uncertainty: uncertainty, stoppedProbability: stopped,
                                         accelerationBias: 0, echoStrength: 5, rollingLevel: 2, movingProbability: 1 - stopped,
                                         wheelbase: 2.7)
    }

    private func engine() throws -> TrackingEngine {
        let points = [Vector2(0, 0), Vector2(0, 6000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight", kind: "primary", points: points)
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "test", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])))
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        return engine
    }

    private func raw(time: Double, total: SIMD3<Double>, rotation: SIMD3<Double>) -> RawMotion {
        let acceleration = total - gravity
        return RawMotion(time: time, acceleration: [acceleration.x, acceleration.y, acceleration.z],
                         rotation: [rotation.x, rotation.y, rotation.z], gravity: [gravity.x, gravity.y, gravity.z],
                         quaternion: [0, 0, 0, 1])
    }
}
