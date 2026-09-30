import Foundation
import simd
@testable import GPSLessCore

/// Physically consistent vibration for motion tests. Every device axis has its
/// own road texture along the distance travelled; the front axle excites it at
/// distance x and the rear axle repeats it at x − wheelbase. Outputs are first
/// differences of that texture, so like a phone shaking in its mount they
/// integrate to bounded velocity and attitude. A small sensor noise floor
/// remains while parked. A moving car without this broadband
/// vibration never occurs in field recordings, and the vibration speed filter
/// deliberately treats idle-level vibration as parked.
struct SyntheticRoadVibration {
    let wheelbase: Double
    /// Tyres and suspension low-pass the road, so texture is correlated over
    /// tens of centimetres; a white 2 cm texture would hide the rear-axle
    /// repeat between 100 Hz samples at city speed.
    private let spacing = 0.25
    private let profiles: [[Double]]
    private var random: SeededRandom
    private(set) var distance = 0.0
    var accelerationAmplitude = 0.02
    var rotationAmplitude = 0.05
    var noiseFloor = 0.0001
    /// Optional tyre non-uniformity: a random profile that repeats every
    /// circumference along the road, in units of the texture's standard
    /// deviation.
    var tyreCircumference: Double? {
        didSet {
            var generator = SeededRandom(seed: 29)
            tyreProfiles = (0..<6).map { _ in
                return (0..<16).map { _ in
                    return generator.normal()
                }
            }
        }
    }
    var tyreAmplitude = 0.0
    private var tyreProfiles: [[Double]] = []
    private var previous: [Double]?

    init(wheelbase: Double = 2.7, seed: UInt64 = 11, length: Double = 3000) {
        self.wheelbase = wheelbase
        var generator = SeededRandom(seed: seed)
        let count = Int(length / spacing) + 2
        profiles = (0..<6).map { _ in
            return (0..<count).map { _ in
                return generator.normal()
            }
        }
        random = SeededRandom(seed: seed &+ 1)
    }

    mutating func advance(speed: Double, duration: Double) {
        distance += max(0, speed) * duration
    }

    /// Returns acceleration in g and rotation in rad/s, device axes.
    mutating func sample() -> (acceleration: SIMD3<Double>, rotation: SIMD3<Double>) {
        let road = (0..<6).map { channel -> Double in
            var value = profile(channel, at: distance) + profile(channel, at: distance - wheelbase)
            if let tyreCircumference {
                let points = tyreProfiles[channel]
                let position = (distance / tyreCircumference).truncatingRemainder(dividingBy: 1) * Double(points.count)
                let lower = Int(position) % points.count
                let fraction = position - Double(Int(position))
                value += tyreAmplitude * (points[lower] * (1 - fraction) + points[(lower + 1) % points.count] * fraction)
            }
            return value
        }
        let before = previous ?? road
        previous = road
        var values = [Double](repeating: 0, count: 6)
        for channel in 0..<6 {
            let amplitude = channel < 3 ? accelerationAmplitude : rotationAmplitude
            values[channel] = (road[channel] - before[channel]) * amplitude + random.normal() * noiseFloor
        }
        return (SIMD3(values[0], values[1], values[2]), SIMD3(values[3], values[4], values[5]))
    }

    private func profile(_ channel: Int, at position: Double) -> Double {
        let index = (position + wheelbase + 1) / spacing
        let lower = min(profiles[channel].count - 2, max(0, Int(index)))
        let fraction = min(1, max(0, index - Double(lower)))
        return profiles[channel][lower] * (1 - fraction) + profiles[channel][lower + 1] * fraction
    }
}
