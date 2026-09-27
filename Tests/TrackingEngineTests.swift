import XCTest
@testable import GPSLessCore

final class TrackingEngineTests: XCTestCase {
    private func graph(restrictions: [TurnRestriction] = []) throws -> RoadGraph {
        func record(_ id: Int, _ way: Int64, _ from: Int64, _ to: Int64, _ points: [Vector2]) -> RoadRecord {
            return RoadRecord(id: id, way: way, from: from, to: to, name: "Test road", kind: "residential", points: points.map { point in
                let coordinate = Coordinate(metres: point)
                return [coordinate.longitude, coordinate.latitude]
            })
        }
        let records = [
            record(0, 10, 1, 2, [Vector2(0, 0), Vector2(0, 200)]),
            record(1, 11, 2, 3, [Vector2(0, 200), Vector2(0, 1400)]),
            record(2, 12, 2, 4, [Vector2(0, 200), Vector2(1000, 200)]),
            record(3, 10, 2, 1, [Vector2(0, 200), Vector2(0, 0)]),
            record(4, 99, 5, 6, [Vector2(15, 0), Vector2(15, 1400)])
        ]
        let dataset = RoadDataset(generated: "test", bounds: [50, 30, 51, 31], roads: records, restrictions: restrictions)
        return try RoadGraph(data: JSONEncoder().encode(dataset))
    }

    func testRoadProjectionAndDragCannotJumpToParallelRoad() throws {
        let graph = try graph()
        let selection = RoadPosition(edge: 0, distance: 60)
        let moved = graph.drag(selection, toward: Coordinate(metres: Vector2(15, 80)))
        XCTAssertEqual(moved.edge, 0)
        XCTAssertEqual(moved.distance, 80, accuracy: 0.1)
        XCTAssertNil(graph.nearest(Coordinate(metres: Vector2(500, 500)), maximumDistance: 20))
        let reverse = try XCTUnwrap(graph.reverse(selection))
        XCTAssertEqual(reverse.edge, 3)
        XCTAssertEqual(reverse.distance, 140, accuracy: 0.1)
        XCTAssertEqual(graph.edges[2].heading(at: -100), .pi / 2, accuracy: 0.001)
        XCTAssertEqual(graph.edges[2].heading(at: 2000), .pi / 2, accuracy: 0.001)
    }

    func testQuietStationaryPhoneDoesNotMoveMarker() throws {
        let graph = try graph()
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 50))
        for tick in 0...1200 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 0))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertEqual(estimate.position.distance, 50, accuracy: 2)
        XCTAssertEqual(estimate.speed, 0)
        XCTAssertFalse(estimate.needsReset)
    }

    func testConstantSpeedIsNotMistakenForAStop() throws {
        let graph = try graph()
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        for tick in 0...800 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 10 {
                acceleration = 1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertGreaterThan(estimate.speed, 8)
        XCTAssertLessThan(estimate.speed, 12)
        XCTAssertGreaterThan(estimate.travelled, 300)
        XCTAssertEqual(estimate.position.edge, 1)
    }

    func testNegativeStartupPulseDoesNotLosePositionBeforeForwardDeparture() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        for tick in 0...240 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time >= 2 && time < 3 {
                acceleration = -1.2
            } else if time >= 4 && time < 8 {
                acceleration = 1.2
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset, "At \(time)s: \(estimate.status)")
            if time < 4 {
                XCTAssertEqual(estimate.speed, 0)
                XCTAssertEqual(estimate.travelled, 0)
            }
        }
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertGreaterThan(final.speed, 4)
        XCTAssertGreaterThan(final.travelled, 20)
        XCTAssertNil(final.failure)
    }

    func testGentleDepartureRetainsItsAccelerationImpulse() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 10 {
                acceleration = 0.1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset)
        XCTAssertEqual(estimate.speed, 1, accuracy: 0.2)
        XCTAssertEqual(estimate.position.distance, 125, accuracy: 4)
        XCTAssertNotEqual(estimate.status, "Waiting for forward movement")
    }

    func testVeryWeakCreepingRemainsStoppedUntilClearerDeparture() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        var departureTime: Double?
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 10 {
                acceleration = 0.05
            } else if time > 20 && time <= 25 {
                acceleration = 0.2
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            if time <= 20 {
                XCTAssertEqual(estimate.speed, 0)
                XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
            }
            if departureTime == nil && !engine.diagnostic(at: time).confirmedStopped {
                departureTime = time
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(departureTime), 20)
        XCTAssertLessThan(try XCTUnwrap(departureTime), 22)
        let final = try XCTUnwrap(engine.estimate)
        XCTAssertGreaterThan(final.speed, 0.8)
        XCTAssertGreaterThan(final.position.distance, 105)
    }

    func testQuietResidualCannotCauseDepartureAfterLongWait() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            let acceleration = min(0.045, time * 0.0012) + 0.035 * sin(time * 9)
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset)
            XCTAssertEqual(estimate.speed, 0)
            XCTAssertEqual(estimate.position.distance, 100, accuracy: 0.001)
            XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
        }
        let evidence = try XCTUnwrap(engine.diagnostic(at: 60).stopEvidence)
        XCTAssertGreaterThan(try XCTUnwrap(evidence.departureImpulseMetresPerSecond), 0.15)
        XCTAssertEqual(evidence.departureAccelerationSupported, false)
    }

    func testLongerDepartureWindowStillRejectsStationaryVibrationAndSmallResidualBias() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        var noise = SeededRandom(seed: 29)
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            let acceleration = 0.015 + noise.normal() * 0.04 + sin(time * 10 * .pi) * 0.2
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset)
            XCTAssertEqual(estimate.speed, 0)
            XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
        }
        XCTAssertEqual(try XCTUnwrap(engine.estimate).position.distance, 100, accuracy: 0.01)
    }

    func testFixedMountingAnglesDoNotChangeProjectedTracking() throws {
        let graph = try graph()
        let upright = TrackingEngine(graph: graph)
        let tilted = TrackingEngine(graph: graph)
        for engine in [upright, tilted] {
            engine.start(at: RoadPosition(edge: 1, distance: 100))
        }
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 10 {
                acceleration = 0.8
            }
            let first = try XCTUnwrap(upright.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            let second = try XCTUnwrap(tilted.process(MotionSample(time: time, forwardAcceleration: acceleration, pitch: 0.9, roll: 0.2)))
            XCTAssertEqual(first.position, second.position)
            XCTAssertEqual(first.speed, second.speed)
            XCTAssertEqual(first.uncertainty, second.uncertainty)
            XCTAssertEqual(first.failure?.reason, second.failure?.reason)
        }
    }

    func testParticleNoiseDoesNotShiftTheStoppedBiasMean() throws {
        let graph = try graph()
        for seed: UInt64 in [7829, 1, 42] {
            let engine = TrackingEngine(graph: graph, seed: seed)
            engine.start(at: RoadPosition(edge: 1, distance: 100))
            for tick in 0...600 {
                let time = Double(tick) * 0.05
                _ = engine.process(MotionSample(time: time, forwardAcceleration: 0))
                let hypotheses = engine.diagnostic(at: time).roadHypotheses
                let accelerationBias = hypotheses.reduce(0.0) { total, hypothesis in
                    return total + hypothesis.accelerationBias * hypothesis.probability
                }
                let gyroBias = hypotheses.reduce(0.0) { total, hypothesis in
                    return total + hypothesis.gyroBias * hypothesis.probability
                }
                XCTAssertEqual(accelerationBias, 0, accuracy: 1e-12)
                XCTAssertEqual(gyroBias, 0, accuracy: 1e-12)
            }
        }
    }

    func testCoreMotionDepartureAndBrakingReachTheEngineWithCorrectSigns() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        var peakSpeed = 0.0
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var deviceAcceleration = 0.0
            if time > 0 && time <= 5 {
                deviceAcceleration = 0.1
            } else if time > 10 && time <= 15 {
                deviceAcceleration = -0.1
            }
            let sample = try XCTUnwrap(VehicleMotionProjection.sample(time: time,
                                                                    userAcceleration: SIMD3(0, 0, deviceAcceleration),
                                                                    gravity: SIMD3(0, -1, 0),
                                                                    rotationRate: .zero))
            let estimate = try XCTUnwrap(engine.process(sample))
            XCTAssertFalse(estimate.needsReset, estimate.status)
            peakSpeed = max(peakSpeed, estimate.speed)
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertEqual(peakSpeed, 4.903325, accuracy: 0.4)
        XCTAssertEqual(estimate.travelled, 49.03325, accuracy: 5)
        XCTAssertEqual(estimate.speed, 0)
        XCTAssertEqual(estimate.status, "Stopped")
    }

    func testCancellingStartupPulsesDoNotInventMovement() throws {
        let graph = try graph()
        for amplitude in [-0.3, 0.2, 0.3] {
            let engine = TrackingEngine(graph: graph)
            engine.start(at: RoadPosition(edge: 1, distance: 100))
            for tick in 0...1200 {
                let time = Double(tick) * 0.05
                var acceleration = 0.0
                if time >= 2 && time < 2.3 {
                    acceleration = amplitude
                } else if time >= 2.3 && time < 2.6 {
                    acceleration = -amplitude
                }
                _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            }
            let estimate = try XCTUnwrap(engine.estimate)
            XCTAssertFalse(estimate.needsReset)
            XCTAssertEqual(estimate.speed, 0)
            XCTAssertEqual(estimate.travelled, 0)
            XCTAssertEqual(estimate.position.distance, 100, accuracy: 1)
        }
    }

    func testGentleBrakingCanReturnToStoppedState() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 5 {
                acceleration = 0.2
            } else if time > 10 && time <= 20 {
                acceleration = -0.1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset)
        XCTAssertEqual(estimate.speed, 0)
        XCTAssertEqual(estimate.status, "Stopped")
    }

    func testAutomaticStopToleratesStationaryCarVibration() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var vertical = 0.0
            var yaw = 0.0
            if time > 0 && time <= 8 {
                acceleration = 1
            } else if time > 12 && time <= 20 {
                acceleration = -1.01
            } else if time > 20 {
                acceleration = 0.16 * sin(time * 16 * .pi)
                vertical = 0.35 * sin(time * 14 * .pi)
                yaw = 0.02 * sin(time * 12 * .pi)
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration, verticalAcceleration: vertical, yawRate: yaw)))
            XCTAssertFalse(estimate.needsReset)
            if time > 26 {
                XCTAssertEqual(estimate.speed, 0)
                XCTAssertTrue(engine.diagnostic(at: time).confirmedStopped)
            }
        }
    }

    func testBrakingToSlowCruiseDoesNotForceAnAutomaticStop() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...1000 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 5 {
                acceleration = 1
            } else if time > 10 && time <= 14 {
                acceleration = -0.9
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            if time > 15 {
                XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
                XCTAssertEqual(estimate.speed, 1.4, accuracy: 0.2)
            }
        }
    }

    func testSlowStopRewindsOnlyTheSupportedDetectionDelayAndReplaysIdentically() throws {
        let graph = try graph()
        let engine = TrackingEngine(graph: graph)
        let replay = TrackingEngine(graph: graph)
        let initial = RoadPosition(edge: 1, distance: 100)
        engine.start(at: initial, uncertainty: 2)
        replay.start(at: initial, uncertainty: 2)
        var correction: StopCorrection?
        var stoppedDistance: Double?
        for tick in 0...800 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 5 {
                acceleration = 1
            } else if time > 10 && time <= 15 {
                // Residual 0.5 m/s is below the user's 3 km/h stop policy.
                acceleration = -0.9
            }
            let sample = MotionSample(time: time, forwardAcceleration: acceleration)
            let estimate = try XCTUnwrap(engine.process(sample))
            let entry = DriveEntry(kind: "sample", sample: sample)
            let decoded = try JSONDecoder().decode(DriveEntry.self, from: JSONEncoder().encode(entry))
            let repeated = try XCTUnwrap(decoded.applyMotion(to: replay))
            XCTAssertEqual(estimate.position, repeated.position)
            XCTAssertEqual(estimate.speed, repeated.speed)
            if let event = engine.lastStopCorrection, event.time == time {
                correction = event
                let record = DriveEntry(kind: "stop-correction", stopCorrection: event)
                let restored = try JSONDecoder().decode(DriveEntry.self, from: JSONEncoder().encode(record))
                XCTAssertNil(restored.applyMotion(to: replay))
                XCTAssertEqual(restored.stopCorrection?.rewindMetres, event.rewindMetres)
                XCTAssertEqual(replay.lastStopCorrection?.rewindMetres, event.rewindMetres)
                XCTAssertEqual(estimate.anchorCount, 0)
                XCTAssertGreaterThanOrEqual(estimate.uncertainty, 2)
                XCTAssertEqual(estimate.speed, 0)
            }
            if time > 21 {
                if stoppedDistance == nil {
                    stoppedDistance = estimate.travelled
                }
                XCTAssertEqual(estimate.speed, 0)
                XCTAssertEqual(estimate.travelled, stoppedDistance)
            }
        }
        let event = try XCTUnwrap(correction)
        XCTAssertEqual(event.decision, "applied")
        XCTAssertGreaterThan(event.rewindMetres, 0.3)
        XCTAssertLessThanOrEqual(event.rewindMetres, 5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(event.onsetTime), 14.5)
        XCTAssertLessThan(event.time - (event.onsetTime ?? 0), 5)
        XCTAssertEqual(graph.pathIndex[event.before.edge], graph.pathIndex[event.after.edge])
        XCTAssertEqual(try XCTUnwrap(engine.estimate).position.distance, event.after.distance, accuracy: 0.01)
    }

    func testDelayedStopDoesNotRewindAcrossAmbiguousJunctionHypotheses() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 149), uncertainty: 2)
        for tick in 0...420 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 5 {
                acceleration = 1
            } else if time > 10 && time <= 15 {
                acceleration = -0.9
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let correction = try XCTUnwrap(engine.lastStopCorrection)
        XCTAssertEqual(correction.decision, "ambiguous_road")
        XCTAssertEqual(correction.rewindMetres, 0)
        XCTAssertEqual(correction.before, correction.after)
        XCTAssertEqual(engine.estimate?.speed, 0)
        XCTAssertFalse(try XCTUnwrap(engine.estimate).needsReset)
    }

    func testQuietMovementBelowThreeKilometresPerHourStillRequiresBrakingToStop() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time > 0 && time <= 3 {
                acceleration = 0.2
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
            if time > 5 {
                XCTAssertFalse(engine.diagnostic(at: time).confirmedStopped)
            }
        }
        XCTAssertNil(engine.lastStopCorrection)
        XCTAssertEqual(try XCTUnwrap(engine.estimate).speed, 0.6, accuracy: 0.15)
    }

    func testExplicitSettledStopLearnsBiasAndAllowsAnotherDeparture() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...100 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 0.05, yawRate: 0.005))
        }
        engine.confirmStop()
        let diagnostic = engine.diagnostic(at: 5)
        XCTAssertEqual(try XCTUnwrap(diagnostic.roadHypotheses.first).accelerationBias, 0.05, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(diagnostic.roadHypotheses.first).gyroBias, 0.005, accuracy: 1e-9)
        for tick in 101...800 {
            let time = Double(tick) * 0.05
            var acceleration = 0.05
            if time > 10 && time <= 20 {
                acceleration += 0.1
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, yawRate: 0.005))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset)
        XCTAssertEqual(estimate.speed, 1, accuracy: 0.2)
        XCTAssertEqual(estimate.position.distance, 125, accuracy: 4)
    }

    func testBrakingOvershootDoesNotInventReverseMovementOrLosePosition() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        var greatestSpeed = 0.0
        for tick in 0...240 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 3 {
                acceleration = 1
            } else if time < 6 {
                acceleration = -2
            }
            let estimate = try XCTUnwrap(engine.process(MotionSample(time: time, forwardAcceleration: acceleration)))
            XCTAssertFalse(estimate.needsReset, "At \(time)s: \(estimate.status)")
            XCTAssertGreaterThanOrEqual(estimate.speed, 0)
            greatestSpeed = max(greatestSpeed, estimate.speed)
        }
        XCTAssertGreaterThan(greatestSpeed, 2)
        XCTAssertEqual(engine.estimate?.speed, 0)
        XCTAssertEqual(engine.estimate?.status, "Stopped")
    }

    func testRollAngleWrappingIsNotMistakenForPhoneHandling() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 0, roll: .pi - 0.01))
        let estimate = try XCTUnwrap(engine.process(MotionSample(time: 1.05, forwardAcceleration: 0, roll: -.pi + 0.01)))
        XCTAssertFalse(estimate.needsReset, estimate.status)
    }

    func testObservedRightTurnChoosesConnectedRightRoad() throws {
        let graph = try graph()
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        for tick in 0...700 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 10 {
                acceleration = 1
            }
            if time >= 14 && time < 19 {
                yaw = .pi / 10
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 10, yawRate: yaw))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset, estimate.status)
        XCTAssertEqual(estimate.position.edge, 2)
        XCTAssertGreaterThan(estimate.roadProbability, 0.7)
        XCTAssertGreaterThanOrEqual(estimate.anchorCount, 1)
        let signals = engine.drainRoadSignals()
        let accepted = try XCTUnwrap(signals.first { signal in
            return signal.stage == "accepted"
        })
        XCTAssertEqual(accepted.observedTurnDegrees, 90, accuracy: 1)
        XCTAssertEqual(accepted.mappedTurnDegrees, 90, accuracy: 1)
        XCTAssertLessThan(abs(accepted.angleResidualDegrees), 2)
        let update = try XCTUnwrap(accepted.roadMatch)
        XCTAssertEqual(update.result.position.edge, 2)
        XCTAssertGreaterThan(update.result.anchorCount, update.previousEstimate?.anchorCount ?? 0)
        XCTAssertGreaterThanOrEqual(update.result.uncertainty, update.previousEstimate?.uncertainty ?? 0)
        XCTAssertGreaterThanOrEqual(update.positionAdjustmentMetres, 0)
        XCTAssertEqual((update.result.coordinate.metres - update.predictionBeforeRoadEvidence.metres).length, update.positionAdjustmentMetres, accuracy: 0.001)
    }

    func testGapAndPhoneHandlingFreezeTracking() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 50))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 0))
        _ = engine.process(MotionSample(time: 2, forwardAcceleration: 0))
        XCTAssertTrue(try XCTUnwrap(engine.estimate).needsReset)
        XCTAssertEqual(engine.estimate?.failure?.reason, .sensorGap)
        XCTAssertEqual(engine.estimate?.failure?.measurements["gapSeconds"], 1)
        engine.start(at: RoadPosition(edge: 0, distance: 50))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 0))
        _ = engine.process(MotionSample(time: 1.05, forwardAcceleration: 0, roll: 0.5))
        XCTAssertTrue(try XCTUnwrap(engine.estimate).needsReset)
        XCTAssertEqual(engine.estimate?.failure?.reason, .mountTilt)
        XCTAssertEqual(engine.estimate?.failure?.measurements["tiltRateRadiansPerSecond"] ?? 0, 10, accuracy: 0.001)
        engine.start(at: RoadPosition(edge: 0, distance: 50))
        _ = engine.process(MotionSample(time: 1, forwardAcceleration: 0))
        _ = engine.process(MotionSample(time: 1.05, forwardAcceleration: 0, yawRate: 2))
        XCTAssertEqual(engine.estimate?.failure?.reason, .excessiveRotation)
        XCTAssertEqual(engine.estimate?.failure?.measurements["yawRateRadiansPerSecond"], 2)
    }

    func testPersistentHeadingMismatchStillStopsAndRecordsItsCause() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...400 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 5 {
                acceleration = 1
            }
            if time >= 5 && time < 9 {
                yaw = 0.3
            }
            let estimate = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, yawRate: yaw))
            if estimate?.needsReset == true {
                break
            }
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertTrue(estimate.needsReset)
        XCTAssertEqual(estimate.failure?.reason, .headingMismatch)
        XCTAssertGreaterThan(estimate.failure?.measurements["mismatchSeconds"] ?? 0, 5)
    }

    func testTurnSignalWithoutMatchingRoadGeometryIsRecordedAsRejected() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 1, distance: 100))
        for tick in 0...500 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 5 {
                acceleration = 0.8
            }
            if time >= 8 && time < 12 {
                yaw = 0.09
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 4, yawRate: yaw))
        }
        let signals = engine.drainRoadSignals()
        XCTAssertTrue(signals.contains { signal in
            return signal.stage == "detected"
        })
        let rejected = try XCTUnwrap(signals.first { signal in
            return signal.stage == "rejected"
        })
        XCTAssertEqual(rejected.mappedTurnDegrees, 0, accuracy: 0.01)
        XCTAssertGreaterThan(rejected.observedTurnDegrees, 17)
        XCTAssertEqual(engine.estimate?.anchorCount, 0)
    }

    func testMeasuredUTurnChangesDirectionOnTheSameRoad() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        for tick in 0...360 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 3 {
                acceleration = 1
            }
            if time >= 5 && time < 13 {
                yaw = .pi / 8
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 3, yawRate: yaw))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset, estimate.status)
        XCTAssertEqual(estimate.position.edge, 3)
    }

    func testCurveWithAccelerationBiasAndNoise() throws {
        var curve = [Vector2(0, 0), Vector2(0, 200)]
        for step in 1...40 {
            let angle = Double(step) / 40 * .pi / 2
            curve.append(Vector2(100 * (1 - cos(angle)), 200 + 100 * sin(angle)))
        }
        curve.append(Vector2(1000, 300))
        let road = RoadRecord(id: 0, way: 50, from: 1, to: 2, name: "Curve", kind: "primary", points: curve.map { point in
            let coordinate = Coordinate(metres: point)
            return [coordinate.longitude, coordinate.latitude]
        })
        let dataset = RoadDataset(generated: "curve", bounds: [50, 30, 51, 31], roads: [road], restrictions: [])
        let graph = try RoadGraph(data: JSONEncoder().encode(dataset))
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 100))
        var random = SeededRandom(seed: 19)
        for tick in 0...1000 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            var yaw = 0.0
            if time < 10 {
                acceleration = 0.8
            }
            if time >= 17.5 && time < 17.5 + 100 * .pi / 16 {
                yaw = 0.08
            }
            acceleration += 0.015 + random.normal() * 0.03
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration, lateralAcceleration: yaw * 8, yawRate: yaw))
        }
        let estimate = try XCTUnwrap(engine.estimate)
        XCTAssertFalse(estimate.needsReset, estimate.status)
        XCTAssertEqual(estimate.position.distance, 460, accuracy: 40)
        XCTAssertEqual(estimate.speed, 8, accuracy: 2)
        XCTAssertGreaterThanOrEqual(estimate.anchorCount, 1)
    }

    func testResumeRetainsPriorUncertainty() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 100), uncertainty: 30)
        for tick in 0...100 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 0))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(engine.estimate).uncertainty, 30)
    }

    func testConfirmedStopPreservesPositionUncertainty() throws {
        let engine = TrackingEngine(graph: try graph())
        engine.start(at: RoadPosition(edge: 0, distance: 20))
        for tick in 0...1200 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 5 {
                acceleration = 0.8
            }
            _ = engine.process(MotionSample(time: time, forwardAcceleration: acceleration))
        }
        let before = try XCTUnwrap(engine.estimate).uncertainty
        engine.confirmStop()
        for tick in 1201...1220 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 0))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(engine.estimate).uncertainty, before * 0.95)
        XCTAssertEqual(try XCTUnwrap(engine.estimate).speed, 0)
    }

    func testReplayIsDeterministic() throws {
        let graph = try graph()
        let first = TrackingEngine(graph: graph, seed: 22)
        let second = TrackingEngine(graph: graph, seed: 22)
        first.start(at: RoadPosition(edge: 0, distance: 30))
        second.start(at: RoadPosition(edge: 0, distance: 30))
        for tick in 0...600 {
            let time = Double(tick) * 0.05
            var acceleration = 0.0
            if time < 6 {
                acceleration = 0.7
            }
            let sample = MotionSample(time: time, forwardAcceleration: acceleration)
            _ = first.process(sample)
            _ = first.diagnostic(at: time)
            _ = second.process(sample)
        }
        XCTAssertEqual(first.estimate?.position, second.estimate?.position)
        XCTAssertEqual(first.estimate?.uncertainty, second.estimate?.uncertainty)
    }

    func testKyivDatasetLoadsAndContainsCentralRoads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let graph = try RoadGraph(data: Data(contentsOf: root.appendingPathComponent("GPSLess/OfflineData/kyiv-graph.json")))
        XCTAssertGreaterThan(graph.edges.count, 100_000)
        let position = try XCTUnwrap(graph.nearest(Coordinate(latitude: 50.4477, longitude: 30.5225), maximumDistance: 100))
        XCTAssertTrue(graph.contains(graph.coordinate(position)))
        XCTAssertFalse(graph.dataset.restrictions.isEmpty)
        let incoming = try XCTUnwrap(graph.edges.firstIndex { edge in
            return edge.record.way == 485971662 && edge.record.to == 372861281
        })
        XCTAssertTrue(graph.hasConflictingOnlyRestrictions(of: incoming))
        XCTAssertFalse(try XCTUnwrap(graph.outgoing[372861281]).isEmpty)
        XCTAssertTrue(graph.successors(of: incoming).isEmpty)
    }

    func testContradictoryMapRulesProduceTheirOwnFailure() throws {
        let rules = [
            TurnRestriction(via: 2, from: 10, to: 11, only: true),
            TurnRestriction(via: 2, from: 10, to: 12, only: true)
        ]
        let graph = try graph(restrictions: rules)
        XCTAssertTrue(graph.hasConflictingOnlyRestrictions(of: 0))
        let engine = TrackingEngine(graph: graph)
        engine.start(at: RoadPosition(edge: 0, distance: 192))
        for tick in 0...240 {
            _ = engine.process(MotionSample(time: Double(tick) * 0.05, forwardAcceleration: 1))
        }
        XCTAssertEqual(engine.estimate?.failure?.reason, .mapRestrictionConflict)
        XCTAssertEqual(engine.estimate?.failure?.measurements["junctionNode"], 2)
        let singleRule = try self.graph(restrictions: [rules[0]])
        XCTAssertFalse(singleRule.hasConflictingOnlyRestrictions(of: 0))
        XCTAssertEqual(singleRule.successors(of: 0), [1])
    }
}
