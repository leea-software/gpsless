import XCTest
import simd
@testable import GPSLessCore

final class VehicleMotionProcessorTests: XCTestCase {
    func testCalibrationDoesNotTreatOscillatingMountAsPermanentGyroBias() throws {
        let processor = VehicleMotionProcessor()
        let initialGravity = SIMD3<Double>(0, -cos(0.6), -sin(0.6))
        let frequency = 3.1 * 2 * Double.pi
        let amplitude = 0.03
        var calibration: CalibrationRecord?
        var maximumDisagreement = 0.0
        for tick in 0...12000 {
            let time = Double(tick) * 0.01
            let angle = amplitude / frequency * sin(time * frequency + 0.7)
            let rotation = SIMD3<Double>(amplitude * cos(time * frequency + 0.7), 0, 0)
            let gravity = simd_quatd(angle: -angle, axis: SIMD3(1, 0, 0)).act(initialGravity)
            let update = processor.receive(raw(time: time, total: gravity, gravity: gravity, rotation: rotation))
            XCTAssertNil(update.failure)
            if let record = update.calibration {
                calibration = record
            }
            if let diagnostic = processor.diagnostic {
                maximumDisagreement = max(maximumDisagreement, diagnostic.gravityDisagreementDegrees)
            }
        }
        let record = try XCTUnwrap(calibration)
        XCTAssertGreaterThan(abs(try XCTUnwrap(record.measuredGyroBias)[0]), 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.gyroBias)[0], 0, accuracy: 1e-8)
        XCTAssertNotNil(record.gyroBiasStandardErrorVehicle)
        XCTAssertLessThan(maximumDisagreement, 0.02)
    }

    private func raw(time: Double, total: SIMD3<Double>, gravity: SIMD3<Double>, rotation: SIMD3<Double>) -> RawMotion {
        let acceleration = total - gravity
        return RawMotion(time: time, acceleration: [acceleration.x, acceleration.y, acceleration.z],
                         rotation: [rotation.x, rotation.y, rotation.z], gravity: [gravity.x, gravity.y, gravity.z],
                         quaternion: [0, 0, 0, 1])
    }

    private func engine() throws -> TrackingEngine {
        let points = [Vector2(0, 0), Vector2(0, 5000)].map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        }
        let road = RoadRecord(id: 0, way: 1, from: 1, to: 2, name: "Straight", kind: "primary", points: points)
        let graph = try RoadGraph(data: JSONEncoder().encode(RoadDataset(generated: "test", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])))
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        return engine
    }

    func testSustainedAccelerationSurvivesChangingAppleGravityAndStopsAfterBraking() throws {
        let processor = VehicleMotionProcessor()
        let engine = try engine()
        let gravity = SIMD3<Double>(0, -1, 0)
        var road = SyntheticRoadVibration(wheelbase: processor.wheelbase)
        var speed = 0.0
        var leakage = 0.0
        var peak = 0.0
        for tick in 0...8000 {
            let time = Double(tick) * 0.01
            var acceleration = 0.0
            if time > 5 && time <= 19 {
                acceleration = (50.0 / 3.6) / 14
            } else if time > 45 && time <= 59 {
                acceleration = -(50.0 / 3.6) / 14
            }
            speed = max(0, speed + acceleration * 0.01)
            road.advance(speed: speed, duration: 0.01)
            let vibration = road.sample()
            leakage += (1 - exp(-0.01 / 6)) * (acceleration - leakage)
            let appleGravity = simd_normalize(gravity + SIMD3(0, 0, leakage / 9.80665))
            let frame = raw(time: time, total: gravity + SIMD3(0, 0, acceleration / 9.80665) + vibration.acceleration,
                            gravity: appleGravity, rotation: vibration.rotation)
            let update = processor.receive(frame)
            XCTAssertNil(update.failure)
            if let observation = update.speedObservation {
                _ = engine.applyVibrationSpeed(observation)
            }
            if let sample = update.sample {
                let estimate = try XCTUnwrap(engine.process(sample))
                XCTAssertFalse(estimate.needsReset, estimate.status)
                peak = max(peak, estimate.speed * 3.6)
                // Speed is now fused with the measured axle echo, so it carries
                // measurement noise (field error 1.5–3 km/h). A Core Motion
                // gravity leak would still cost many km/h at this tolerance.
                if time > 20 && time < 45 {
                    XCTAssertEqual(estimate.speed * 3.6, 50, accuracy: 1)
                    XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
                }
            }
        }
        XCTAssertEqual(peak, 50, accuracy: 1)
        XCTAssertEqual(engine.estimate?.speed, 0)
        XCTAssertTrue(engine.diagnostic(at: 80).confirmedStopped)
    }

    /// Parked vibration is an independent zero-speed observation, so it removes
    /// gyro drift from gravity without Core Motion's gravity or a user action.
    func testParkedVibrationRemovesSlowGyroDriftWithoutCreatingSpeed() throws {
        let processor = VehicleMotionProcessor()
        let gravity = SIMD3<Double>(0, -1, 0)
        var road = SyntheticRoadVibration(wheelbase: processor.wheelbase)
        var maximumForwardAcceleration = 0.0
        var correctionObserved = false
        for tick in 0...6500 {
            let time = Double(tick) * 0.01
            let noise = road.sample()
            var rotation = noise.rotation
            if time > 5 {
                rotation.x += -0.0015
            }
            let update = processor.receive(raw(time: time, total: gravity + noise.acceleration, gravity: gravity, rotation: rotation))
            XCTAssertNil(update.failure)
            if let sample = update.sample {
                maximumForwardAcceleration = max(maximumForwardAcceleration, abs(sample.forwardAcceleration))
            }
            if processor.diagnostic?.gravityCorrectionActive == true {
                correctionObserved = true
            }
        }
        XCTAssertTrue(correctionObserved)
        XCTAssertLessThan(maximumForwardAcceleration, 0.04)
        XCTAssertLessThan(try XCTUnwrap(processor.diagnostic).gravityDisagreementDegrees, 0.3)
    }

    func testNewDriveCanReuseCalibrationAcrossTimestampGap() throws {
        let processor = VehicleMotionProcessor()
        let gravity = SIMD3<Double>(0, -1, 0)
        for tick in 0...500 {
            _ = processor.receive(raw(time: Double(tick) * 0.01, total: gravity,
                                      gravity: gravity, rotation: .zero))
        }
        XCTAssertTrue(processor.calibrated)
        processor.beginSession(reusingCalibration: true)
        XCTAssertTrue(processor.calibrated)
        var producedSample = false
        for tick in 0...10 {
            let update = processor.receive(raw(time: 100 + Double(tick) * 0.01,
                                               total: gravity, gravity: gravity, rotation: .zero))
            XCTAssertNil(update.failure)
            if update.sample != nil {
                producedSample = true
            }
        }
        XCTAssertTrue(producedSample)
    }

    /// A drive that reuses the app's calibration records it, and a replay
    /// resuming from that row must process the drive exactly as the phone did.
    func testRecordedReusedCalibrationResumesIdentically() throws {
        let original = VehicleMotionProcessor()
        let gravity = simd_normalize(SIMD3<Double>(0.02, -0.86, -0.5))
        var road = SyntheticRoadVibration(wheelbase: original.wheelbase)
        var speed = 0.0
        for tick in 0...6000 {
            let time = Double(tick) * 0.01
            let acceleration = time > 10 && time < 20 ? 1.0 : 0
            speed += acceleration * 0.01
            road.advance(speed: speed, duration: 0.01)
            let vibration = road.sample()
            let idle = SIMD3<Double>(0, 0.004 * sin(time * 26 * .pi), 0.002 * sin(time * 52 * .pi))
            let forward = SIMD3<Double>(0, 0, acceleration / 9.80665)
            _ = original.receive(raw(time: time, total: gravity + forward + vibration.acceleration + idle,
                                     gravity: gravity, rotation: vibration.rotation))
        }
        XCTAssertTrue(original.calibrated)
        let recorded = try XCTUnwrap(original.reusedCalibration())
        XCTAssertEqual(recorded.reason, "reused")
        XCTAssertNotNil(recorded.vibrationBaseline)
        let decoded = try JSONDecoder().decode(CalibrationRecord.self, from: JSONEncoder().encode(recorded))
        let resumed = VehicleMotionProcessor()
        XCTAssertTrue(resumed.resume(from: decoded))
        original.beginSession(reusingCalibration: true)
        var compared = 0
        for tick in 0...3000 {
            let time = 200 + Double(tick) * 0.01
            let acceleration = tick > 500 && tick < 1500 ? 1.0 : 0
            speed = tick == 0 ? 0 : speed + acceleration * 0.01
            road.advance(speed: speed, duration: 0.01)
            let vibration = road.sample()
            let frame = raw(time: time, total: gravity + SIMD3(0, 0, acceleration / 9.80665) + vibration.acceleration,
                            gravity: gravity, rotation: vibration.rotation)
            let expected = original.receive(frame)
            let actual = resumed.receive(frame)
            XCTAssertEqual(expected.sample?.forwardAcceleration, actual.sample?.forwardAcceleration)
            XCTAssertEqual(expected.speedObservation?.speed, actual.speedObservation?.speed)
            if expected.speedObservation != nil {
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 40)
    }

    func testThreeAxisGyroCalibrationTracksRealRotationWithoutCreatingAcceleration() throws {
        let processor = VehicleMotionProcessor()
        let bias = SIMD3<Double>(0.002, -0.003, 0.004)
        let axis = simd_normalize(SIMD3<Double>(1, 0.5, 0.2))
        let initialGravity = SIMD3<Double>(0, -cos(0.6), -sin(0.6))
        var calibration: CalibrationRecord?
        for tick in 0...2500 {
            let time = Double(tick) * 0.01
            var angle = 0.0
            var rate = 0.0
            if time > 5 {
                angle = 0.08 * sin((time - 5) * 0.4)
                rate = 0.032 * cos((time - 5) * 0.4)
            }
            let gravity = simd_quatd(angle: -angle, axis: axis).act(initialGravity)
            let update = processor.receive(raw(time: time, total: gravity, gravity: initialGravity, rotation: bias + axis * rate))
            XCTAssertNil(update.failure)
            if let record = update.calibration {
                calibration = record
            }
            if let sample = update.sample {
                XCTAssertEqual(sample.forwardAcceleration, 0, accuracy: 0.003)
                XCTAssertEqual(sample.lateralAcceleration, 0, accuracy: 0.003)
            }
        }
        let estimatedBias = try XCTUnwrap(calibration?.gyroBias)
        for index in 0..<3 {
            XCTAssertEqual(estimatedBias[index], bias[index], accuracy: 1e-10)
        }
    }

    func testRepeatedTwentyFiveSecondStopsDoNotCreepOrPreventDeparture() throws {
        let processor = VehicleMotionProcessor()
        let engine = try engine()
        let gravity = SIMD3<Double>(0, -1, 0)
        var road = SyntheticRoadVibration(wheelbase: processor.wheelbase)
        var speed = 0.0
        var leakage = 0.0
        var maximumStoppedSpeed = 0.0
        var departureSpeeds: [Double] = []
        for tick in 0...18500 {
            let time = Double(tick) * 0.01
            var phase = -1.0
            if time > 5 {
                phase = (time - 5).truncatingRemainder(dividingBy: 60)
            }
            var acceleration = 0.0
            if phase >= 0 && phase < 10 {
                acceleration = 1
            } else if phase >= 25 && phase < 35 {
                acceleration = -1
            }
            leakage += (1 - exp(-0.01 / 6)) * (acceleration - leakage)
            let appleGravity = simd_normalize(gravity + SIMD3(0, 0, leakage / 9.80665))
            // Idling vibration is included in total acceleration, independently
            // of the deliberately wrong gravity separation above; rolling
            // vibration is added while the car moves.
            speed = max(0, speed + acceleration * 0.01)
            road.advance(speed: speed, duration: 0.01)
            let rolling = road.sample()
            let vibration = SIMD3<Double>(0, 0.02 * sin(time * 34 * .pi), 0.008 * sin(time * 26 * .pi)) + rolling.acceleration
            let total = gravity + SIMD3(0, 0, acceleration / 9.80665) + vibration
            let update = processor.receive(raw(time: time, total: total, gravity: appleGravity, rotation: rolling.rotation))
            if let observation = update.speedObservation {
                _ = engine.applyVibrationSpeed(observation)
            }
            if let sample = update.sample {
                let estimate = try XCTUnwrap(engine.process(sample))
                if estimate.needsReset {
                    XCTFail(estimate.status)
                    return
                }
                if phase > 41 && phase < 59 {
                    maximumStoppedSpeed = max(maximumStoppedSpeed, estimate.speed)
                }
                if phase > 15 && phase < 15.1 {
                    departureSpeeds.append(estimate.speed)
                }
            }
        }
        XCTAssertEqual(maximumStoppedSpeed, 0)
        XCTAssertGreaterThanOrEqual(departureSpeeds.count, 3)
        for speed in departureSpeeds {
            XCTAssertEqual(speed, 10, accuracy: 0.4)
        }
    }

    func testExplicitStopRecalibratesTiltDriftAndRemainsStopped() throws {
        let processor = VehicleMotionProcessor()
        let engine = try engine()
        let gravity = SIMD3<Double>(0, -1, 0)
        var stoppedPosition: RoadPosition?
        for tick in 0...9000 {
            let time = Double(tick) * 0.01
            var rotation = SIMD3<Double>.zero
            if time > 5 {
                rotation.x = -0.0015
            }
            let update = processor.receive(raw(time: time, total: gravity, gravity: gravity, rotation: rotation))
            if let sample = update.sample {
                _ = engine.process(sample)
            }
            if tick == 3000 {
                let calibration = try XCTUnwrap(processor.confirmStop())
                XCTAssertEqual(calibration.reason, "confirmed-stop")
                engine.confirmStop(resetMotionCalibration: true)
                XCTAssertEqual(engine.estimate?.speed, 0)
            }
            if time > 31 {
                let estimate = try XCTUnwrap(engine.estimate)
                // Allow the first publish to include motion integrated before
                // confirmation, then verify there is no continued creeping.
                if stoppedPosition == nil {
                    stoppedPosition = estimate.position
                }
                XCTAssertFalse(estimate.needsReset, estimate.status)
                XCTAssertEqual(estimate.speed, 0)
                XCTAssertEqual(estimate.position.distance, try XCTUnwrap(stoppedPosition).distance, accuracy: 0.001)
            }
        }
    }

    func testStopRecalibrationRejectsPhoneHandlingAndRawGaps() throws {
        let processor = VehicleMotionProcessor()
        let gravity = SIMD3<Double>(0, -1, 0)
        for tick in 0...700 {
            let time = Double(tick) * 0.01
            var rotation = SIMD3<Double>.zero
            if time > 5 {
                rotation.x = 0.2 * sin(time * 10)
            }
            _ = processor.receive(raw(time: time, total: gravity, gravity: gravity, rotation: rotation))
        }
        XCTAssertNil(processor.confirmStop())
        let interrupted = processor.receive(raw(time: 8, total: gravity, gravity: gravity, rotation: .zero))
        XCTAssertNotNil(interrupted.failure)
    }

    func testRecordedReferenceResetClearsOldEngineBiasAndAcceptsNewPitch() throws {
        let engine = try engine()
        for tick in 0...100 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 0.05))
        }
        engine.confirmStop()
        XCTAssertEqual(engine.diagnostic(at: 5).roadHypotheses[0].accelerationBias, 0.05, accuracy: 1e-9)
        let event = DriveEntry(kind: "event", event: "confirmed-stop", metrics: ["motionCalibrationReset": 1])
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: JSONEncoder().encode(event))
        _ = decoded.applyMotion(to: engine)
        let estimate = try XCTUnwrap(engine.process(MotionSample(time: 5.05, forwardAcceleration: 0, pitch: 0.1)))
        XCTAssertFalse(estimate.needsReset)
        XCTAssertEqual(engine.diagnostic(at: 5.05).roadHypotheses[0].accelerationBias, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.speed, 0)
    }
}
