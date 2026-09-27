import Foundation
import simd

/// Absolute speed evidence from the phone's own vibration. Every road bump
/// excites the front axle first and the rear axle one wheelbase later, so the
/// mounted phone sees the same disturbance repeated after wheelbase / speed.
/// A causal grid filter over speed and residual acceleration bias combines that
/// delay with integrated forward acceleration and with a rolling-vibration
/// stop detector. Nothing here uses GPS or the road map.
public struct VibrationSpeedObservation: Codable, Sendable {
    public let time: Double
    /// Posterior mean and standard deviation, m/s.
    public let speed: Double
    public let uncertainty: Double
    public let stoppedProbability: Double
    /// Residual bias of the processed forward acceleration, m/s².
    public let accelerationBias: Double
    /// Strongest axle-echo correlation among supported speeds, in noise units.
    public let echoStrength: Double
    /// Broadband vibration in log10 decades above the parked calibration level.
    public let rollingLevel: Double?
    public let movingProbability: Double?
    public let wheelbase: Double

    public init(time: Double, speed: Double, uncertainty: Double, stoppedProbability: Double, accelerationBias: Double,
                echoStrength: Double, rollingLevel: Double?, movingProbability: Double?, wheelbase: Double) {
        self.time = time
        self.speed = speed
        self.uncertainty = uncertainty
        self.stoppedProbability = stoppedProbability
        self.accelerationBias = accelerationBias
        self.echoStrength = echoStrength
        self.rollingLevel = rollingLevel
        self.movingProbability = movingProbability
        self.wheelbase = wheelbase
    }
}

/// Iterative radix-2 complex FFT with precomputed twiddles.
struct RadixTwoFFT {
    let size: Int
    private let cosines: [Double]
    private let sines: [Double]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosines = (0..<size / 2).map { index in
            return cos(-2 * .pi * Double(index) / Double(size))
        }
        sines = (0..<size / 2).map { index in
            return sin(-2 * .pi * Double(index) / Double(size))
        }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { index in
            var value = 0
            for bit in 0..<bits where index & (1 << bit) != 0 {
                value |= 1 << (bits - 1 - bit)
            }
            return value
        }
    }

    /// Forward transform, X[k] = Σ x[n]·e^(−2πikn/N), in place.
    func forward(_ real: inout [Double], _ imaginary: inout [Double]) {
        for index in 0..<size where reversed[index] > index {
            real.swapAt(index, reversed[index])
            imaginary.swapAt(index, reversed[index])
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for offset in 0..<half {
                    let twiddle = offset * step
                    let even = start + offset
                    let odd = even + half
                    let oddReal = real[odd] * cosines[twiddle] - imaginary[odd] * sines[twiddle]
                    let oddImaginary = real[odd] * sines[twiddle] + imaginary[odd] * cosines[twiddle]
                    real[odd] = real[even] - oddReal
                    imaginary[odd] = imaginary[even] - oddImaginary
                    real[even] += oddReal
                    imaginary[even] += oddImaginary
                }
                start += length
            }
            length *= 2
        }
    }
}

/// Uniform 100 Hz channels and the two spectral measurements taken from them.
final class AxleEchoAnalyzer {
    static let sampleRate = 100.0
    static let window = 400
    static let transformSize = 1024
    static let maximumLag = 250
    static let rollingWindow = 100
    static let rollingTransformSize = 128
    static let whitening = 0.8
    static let minimumBandEnergy = 1e-6
    enum Channel: Int, CaseIterable {
        case accelerationX, accelerationY, accelerationZ, rotationX, rotationY, rotationZ, vertical
    }
    /// Correlated channel pairs (the first lags the second), with their sign
    /// and weight. All eleven showed the echo with a consistent sign in seven
    /// independent Kyiv drives; the weights are their stacked signal-to-noise.
    static let pairs: [(Channel, Channel, Double, Double)] = [
        (.rotationY, .rotationY, 1, 17.4), (.accelerationX, .accelerationX, 1, 14.4),
        (.vertical, .accelerationX, -1, 14.0), (.accelerationX, .accelerationZ, 1, 13.1),
        (.accelerationZ, .accelerationZ, 1, 13.1), (.rotationZ, .rotationZ, 1, 12.5),
        (.accelerationX, .vertical, -1, 11.6), (.vertical, .vertical, 1, 10.8),
        (.accelerationY, .accelerationY, 1, 10.3), (.accelerationZ, .accelerationX, 1, 7.7),
        (.rotationX, .rotationX, 1, 7.6)
    ]

    private var buffers = Array(repeating: [Double](repeating: 0, count: AxleEchoAnalyzer.window), count: 7)
    private var head = 0
    private(set) var count = 0
    private var gridTime: Double?
    private var previousTime = 0.0
    private var previousValues = [Double](repeating: 0, count: 7)
    private let transform = RadixTwoFFT(size: AxleEchoAnalyzer.transformSize)
    private let rollingTransform = RadixTwoFFT(size: AxleEchoAnalyzer.rollingTransformSize)
    private let echoWindow: [Double]
    private let rollingWindowShape: [Double]
    private let band: ClosedRange<Int>
    private let rollingBand: ClosedRange<Int>

    init() {
        echoWindow = Self.hann(Self.window)
        rollingWindowShape = Self.hann(Self.rollingWindow)
        // 1–40 Hz excludes attitude and engine-idle harmonics above 40 Hz.
        band = Int(ceil(1.0 * Double(Self.transformSize) / Self.sampleRate))...Int(floor(40.0 * Double(Self.transformSize) / Self.sampleRate))
        rollingBand = Int(ceil(3.0 * Double(Self.rollingTransformSize) / Self.sampleRate))...Int(floor(45.0 * Double(Self.rollingTransformSize) / Self.sampleRate))
    }

    static func hann(_ count: Int) -> [Double] {
        return (0..<count).map { index in
            return 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1))
        }
    }

    func reset() {
        buffers = Array(repeating: [Double](repeating: 0, count: Self.window), count: 7)
        head = 0
        count = 0
        gridTime = nil
    }

    /// Linearly resamples irregular Core Motion frames onto a 10 ms grid.
    func append(time: Double, values: [Double]) {
        guard let current = gridTime else {
            gridTime = time
            previousTime = time
            previousValues = values
            push(values)
            gridTime = time + 0.01
            return
        }
        var next = current
        while next <= time {
            let fraction = time == previousTime ? 0 : (next - previousTime) / (time - previousTime)
            push(zip(previousValues, values).map { previous, value in
                return previous + (value - previous) * fraction
            })
            next += 0.01
        }
        gridTime = next
        previousTime = time
        previousValues = values
    }

    private func push(_ values: [Double]) {
        for channel in 0..<7 {
            buffers[channel][head] = values[channel]
        }
        head = (head + 1) % Self.window
        count += 1
    }

    private func recent(_ channel: Int, _ length: Int) -> [Double] {
        var result = [Double](repeating: 0, count: length)
        for index in 0..<length {
            result[index] = buffers[channel][(head - length + index + 2 * Self.window) % Self.window]
        }
        return result
    }

    /// Weighted whitened correlation over lags 0..<maximumLag at 10 ms steps.
    func correlation() -> [Double]? {
        guard count >= Self.window else {
            return nil
        }
        var spectraReal: [[Double]] = []
        var spectraImaginary: [[Double]] = []
        var powers: [[Double]] = []
        for channel in 0..<7 {
            let values = recent(channel, Self.window)
            let mean = values.reduce(0, +) / Double(values.count)
            var real = [Double](repeating: 0, count: Self.transformSize)
            var imaginary = [Double](repeating: 0, count: Self.transformSize)
            for index in 0..<Self.window {
                real[index] = (values[index] - mean) * echoWindow[index]
            }
            transform.forward(&real, &imaginary)
            var power = [Double](repeating: 0, count: Self.transformSize / 2 + 1)
            for bin in 0...(Self.transformSize / 2) {
                if band.contains(bin) {
                    power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                } else {
                    real[bin] = 0
                    imaginary[bin] = 0
                }
            }
            // A channel without measurable vibration (a frozen or synthetic
            // signal) makes whitened correlation meaningless. Real parked
            // windows carry about six orders of magnitude more band energy.
            guard power.reduce(0, +) > Self.minimumBandEnergy else {
                return nil
            }
            spectraReal.append(real)
            spectraImaginary.append(imaginary)
            powers.append(power)
        }
        var combinedReal = [Double](repeating: 0, count: Self.transformSize)
        var combinedImaginary = [Double](repeating: 0, count: Self.transformSize)
        var weightSum = 0.0
        for (first, second, sign, weight) in Self.pairs {
            let a = first.rawValue
            let b = second.rawValue
            var normalA = 0.0
            var normalB = 0.0
            for bin in band {
                normalA += pow(powers[a][bin], 1 - Self.whitening)
                normalB += pow(powers[b][bin], 1 - Self.whitening)
            }
            let scale = sign * weight / sqrt(normalA * normalB + 1e-30)
            for bin in band {
                let denominator = pow(powers[a][bin] * powers[b][bin], Self.whitening / 2) + 1e-20
                // X_a · conj(X_b)
                let real = spectraReal[a][bin] * spectraReal[b][bin] + spectraImaginary[a][bin] * spectraImaginary[b][bin]
                let imaginary = spectraImaginary[a][bin] * spectraReal[b][bin] - spectraReal[a][bin] * spectraImaginary[b][bin]
                combinedReal[bin] += real / denominator * scale
                combinedImaginary[bin] += imaginary / denominator * scale
            }
            weightSum += weight
        }
        // Hermitian inverse: x[n] = 2·Σ Re(A_k e^{+2πikn/N}) over the band.
        // Conjugate, forward-transform, conjugate again yields the inverse.
        var real = [Double](repeating: 0, count: Self.transformSize)
        var imaginary = [Double](repeating: 0, count: Self.transformSize)
        for bin in band {
            real[bin] = combinedReal[bin] / weightSum
            imaginary[bin] = -combinedImaginary[bin] / weightSum
        }
        transform.forward(&real, &imaginary)
        return (0..<Self.maximumLag).map { lag in
            return 2 * real[lag]
        }
    }

    /// Mean log10 median broadband power (3–45 Hz) of the six device axes over
    /// the last second. A median ignores the narrow engine-idle lines.
    func rollingLevel() -> Double? {
        guard count >= Self.rollingWindow else {
            return nil
        }
        var total = 0.0
        for channel in 0..<6 {
            let values = recent(channel, Self.rollingWindow)
            let mean = values.reduce(0, +) / Double(values.count)
            var real = [Double](repeating: 0, count: Self.rollingTransformSize)
            var imaginary = [Double](repeating: 0, count: Self.rollingTransformSize)
            for index in 0..<Self.rollingWindow {
                real[index] = (values[index] - mean) * rollingWindowShape[index]
            }
            rollingTransform.forward(&real, &imaginary)
            let powers = rollingBand.map { bin in
                return real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            }.sorted()
            let middle = powers.count / 2
            var median = powers[middle]
            if powers.count.isMultiple(of: 2) {
                median = (powers[middle - 1] + powers[middle]) / 2
            }
            total += log10(median + 1e-14)
        }
        return total / 6
    }
}

/// Discrete Bayes filter over forward speed and residual acceleration bias.
final class SpeedGridFilter {
    static let speeds = (0...180).map { Double($0) * 0.2 }
    static let biases = (0...40).map { Double($0 - 20) * 0.04 }
    static let hop = 0.5
    static let movingFloor = 0.1
    let wheelbase: Double
    var echoGain = 0.5
    var speedNoise = 0.12
    /// Bias random walk per update. 0.02 lets the bias follow residual gravity
    /// drift; at 0.01 speed sagged below the echo on every field cruise.
    var biasNoise = 0.02
    var backgroundLength = 120.0
    var stopMidpoint = 0.9
    private var probability: [Double]
    private var background: [Double]?
    private var rollingHistory: [Double] = []
    /// Velocity changes and durations since the echo window's centre.
    private var recentMotion: [(velocityChange: Double, duration: Double)] = []
    private let lagIndex: [Int]
    private let lagFraction: [Double]
    private let echoSupported: [Bool]
    private var speedCount: Int { Self.speeds.count }
    private var biasCount: Int { Self.biases.count }

    init(wheelbase: Double) {
        self.wheelbase = wheelbase
        probability = []
        var indices: [Int] = []
        var fractions: [Double] = []
        var supported: [Bool] = []
        let maximumLag = Double(AxleEchoAnalyzer.maximumLag)
        for speed in Self.speeds {
            let lag = clamp(wheelbase / max(speed, 1e-3) * AxleEchoAnalyzer.sampleRate, 0, maximumLag - 2)
            indices.append(Int(lag))
            fractions.append(lag - Double(Int(lag)))
            supported.append(speed >= wheelbase / (maximumLag / AxleEchoAnalyzer.sampleRate - 0.05) && speed <= wheelbase / 0.1)
        }
        lagIndex = indices
        lagFraction = fractions
        echoSupported = supported
        resetStopped()
    }

    /// Parked: speed zero. A parked calibration has just set gravity, so the
    /// residual bias starts near zero; a wide prior would let the filter
    /// explain a real sustained acceleration as bias whenever vibration and
    /// acceleration disagree.
    func resetStopped() {
        probability = [Double](repeating: 0, count: Self.speeds.count * Self.biases.count)
        var total = 0.0
        for (column, bias) in Self.biases.enumerated() {
            let value = exp(-0.5 * pow(bias / 0.05, 2))
            probability[column] = value
            total += value
        }
        for index in probability.indices {
            probability[index] /= total
        }
        rollingHistory = []
        recentMotion = []
    }

    func resetBackground() {
        background = nil
    }

    /// A gravity correction changed the processed acceleration by `delta`.
    /// The physical bias is unchanged, so every bias hypothesis moves with it.
    func shiftBias(by delta: Double) {
        guard abs(delta) > 1e-9 else {
            return
        }
        for row in 0..<speedCount {
            let base = row * biasCount
            let original = Array(probability[base..<(base + biasCount)])
            for column in 0..<biasCount {
                probability[base + column] = Self.interpolate(Self.biases[column] - delta, grid: Self.biases, values: original)
            }
        }
        normalize()
    }

    struct Posterior {
        let speed: Double
        let uncertainty: Double
        let stoppedProbability: Double
        let bias: Double
        let echoStrength: Double
        let movingProbability: Double?
    }

    func update(velocityChange: Double, duration: Double, correlation: [Double]?, rollingLevel: Double?, baseline: Double?) -> Posterior {
        var next = [Double](repeating: 0, count: probability.count)
        for column in 0..<biasCount {
            let shift = velocityChange - Self.biases[column] * duration
            let values = (0..<speedCount).map { row in
                return probability[row * biasCount + column]
            }
            for row in 0..<speedCount {
                next[row * biasCount + column] = Self.interpolate(Self.speeds[row] - shift, grid: Self.speeds, values: values)
            }
            if shift < 0 {
                var below = 0.0
                for row in 0..<speedCount where Self.speeds[row] + shift < 0 {
                    below += values[row]
                }
                next[column] += below
            }
        }
        let scale = sqrt(duration / Self.hop)
        blurSpeeds(&next, sigma: max(0.05, speedNoise * scale / 0.2))
        blurBiases(&next, sigma: max(0.05, biasNoise * scale / 0.04))

        // The echo window is centred two seconds back. A hypothesis with speed
        // V and bias b had speed V − (Δv − b·Δt) there; comparing the echo with
        // the current speed instead lags acceleration and braking by 2 s.
        recentMotion.append((velocityChange, duration))
        let centreUpdates = Int((Double(AxleEchoAnalyzer.window) / AxleEchoAnalyzer.sampleRate / 2 / Self.hop).rounded())
        if recentMotion.count > centreUpdates {
            recentMotion.removeFirst(recentMotion.count - centreUpdates)
        }
        let changeSinceCentre = recentMotion.reduce(0) { total, item in
            return total + item.velocityChange
        }
        let timeSinceCentre = recentMotion.reduce(0) { total, item in
            return total + item.duration
        }
        var echoLikelihood: [Double]?
        var likelihood = [Double](repeating: 1, count: speedCount)
        var echoStrength = 0.0
        if let correlation {
            if let background {
                let residual = zip(correlation, background).map { value, reference in
                    return value - reference
                }
                let tail = residual[10...]
                let mean = tail.reduce(0, +) / Double(tail.count)
                let noise = sqrt(tail.reduce(0) { total, value in
                    return total + (value - mean) * (value - mean)
                } / Double(tail.count)) + 1e-12
                var supportedScores: [Double] = []
                var scores = [Double](repeating: 0, count: speedCount)
                var peak = -Double.infinity
                for row in 0..<speedCount {
                    let value = (1 - lagFraction[row]) * residual[lagIndex[row]] + lagFraction[row] * residual[lagIndex[row] + 1]
                    scores[row] = clamp(echoGain * value / noise, -20, 20)
                    if echoSupported[row] {
                        supportedScores.append(scores[row])
                        peak = max(peak, value / noise)
                    }
                }
                echoStrength = peak
                let neutral = exp(Self.median(supportedScores))
                let atCentre = (0..<speedCount).map { row in
                    return echoSupported[row] ? exp(scores[row]) : neutral
                }
                var aligned = [Double](repeating: 0, count: probability.count)
                for column in 0..<biasCount {
                    let change = changeSinceCentre - Self.biases[column] * timeSinceCentre
                    for row in 0..<speedCount {
                        aligned[row * biasCount + column] = Self.interpolateClamped(Self.speeds[row] - change, grid: Self.speeds, values: atCentre)
                    }
                }
                echoLikelihood = aligned
            }
            if let previous = background {
                background = zip(previous, correlation).map { reference, value in
                    return (1 - 1 / backgroundLength) * reference + value / backgroundLength
                }
            } else {
                background = correlation
            }
        }
        var movingProbability: Double?
        if let rollingLevel {
            rollingHistory.append(rollingLevel)
            if rollingHistory.count > 2 {
                rollingHistory.removeFirst(rollingHistory.count - 2)
            }
        }
        if let baseline, !rollingHistory.isEmpty {
            let level = rollingHistory.reduce(0, +) / Double(rollingHistory.count) - baseline
            let moving = 1 / (1 + exp(-(level - stopMidpoint) * 5))
            movingProbability = moving
            // Cap the parked likelihood ratio near 10:1. Blur returns a little
            // mass to zero on every update; an uncapped ~90:1 ratio multiplied
            // that leak into a persistent parked mode that could outvote
            // integrated acceleration when rolling vibration is unusually low.
            for row in 0..<speedCount {
                likelihood[row] *= Self.speeds[row] < 0.3 ? 1 - moving + 1e-3 : max(moving, Self.movingFloor) + 1e-3
            }
        }
        for row in 0..<speedCount {
            for column in 0..<biasCount {
                next[row * biasCount + column] *= likelihood[row] * (echoLikelihood?[row * biasCount + column] ?? 1)
            }
        }
        probability = next
        normalize()

        var mean = 0.0
        var square = 0.0
        var stopped = 0.0
        var bias = 0.0
        for row in 0..<speedCount {
            var mass = 0.0
            for column in 0..<biasCount {
                let value = probability[row * biasCount + column]
                mass += value
                bias += value * Self.biases[column]
            }
            mean += mass * Self.speeds[row]
            square += mass * Self.speeds[row] * Self.speeds[row]
            if Self.speeds[row] < 0.3 {
                stopped += mass
            }
        }
        return Posterior(speed: mean, uncertainty: sqrt(max(0, square - mean * mean)), stoppedProbability: stopped,
                         bias: bias, echoStrength: echoStrength, movingProbability: movingProbability)
    }

    private func normalize() {
        let total = probability.reduce(0, +)
        guard total > 0, total.isFinite else {
            resetStopped()
            return
        }
        for index in probability.indices {
            probability[index] /= total
        }
    }

    private func blurSpeeds(_ values: inout [Double], sigma: Double) {
        let kernel = Self.kernel(sigma)
        let radius = kernel.count / 2
        var result = [Double](repeating: 0, count: values.count)
        for row in 0..<speedCount {
            for (offset, weight) in kernel.enumerated() {
                let source = min(speedCount - 1, max(0, row + offset - radius))
                for column in 0..<biasCount {
                    result[row * biasCount + column] += weight * values[source * biasCount + column]
                }
            }
        }
        values = result
    }

    private func blurBiases(_ values: inout [Double], sigma: Double) {
        let kernel = Self.kernel(sigma)
        let radius = kernel.count / 2
        var result = [Double](repeating: 0, count: values.count)
        for row in 0..<speedCount {
            for column in 0..<biasCount {
                var total = 0.0
                for (offset, weight) in kernel.enumerated() {
                    let source = min(biasCount - 1, max(0, column + offset - radius))
                    total += weight * values[row * biasCount + source]
                }
                result[row * biasCount + column] = total
            }
        }
        values = result
    }

    /// Truncated at four standard deviations, like SciPy's gaussian_filter1d.
    static func kernel(_ sigma: Double) -> [Double] {
        let radius = Int(4 * sigma + 0.5)
        let weights = (-radius...radius).map { offset in
            return exp(-0.5 * pow(Double(offset) / sigma, 2))
        }
        let total = weights.reduce(0, +)
        return weights.map { weight in
            return weight / total
        }
    }

    /// numpy.interp with edge values outside the grid.
    static func interpolateClamped(_ x: Double, grid: [Double], values: [Double]) -> Double {
        return interpolate(min(max(x, grid[0]), grid[grid.count - 1]), grid: grid, values: values)
    }

    /// numpy.interp with zero outside the grid.
    static func interpolate(_ x: Double, grid: [Double], values: [Double]) -> Double {
        guard x >= grid[0], x <= grid[grid.count - 1] else {
            return 0
        }
        let step = grid[1] - grid[0]
        let position = (x - grid[0]) / step
        let lower = min(grid.count - 2, Int(position))
        let fraction = position - Double(lower)
        return values[lower] * (1 - fraction) + values[lower + 1] * fraction
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

/// Owns the analyzer and grid filter, timing their 0.5-second updates, the
/// parked vibration baseline and the speed/bias posterior used to aid gravity.
/// Live, raw-replay and simulation input all pass through it.
final class VehicleSpeedObserver {
    static let defaultWheelbase = 2.70
    static let supportedWheelbase = 2.0...4.0
    /// Parked field phones read about −7.6 (log10 median power); an idealized
    /// noise-free signal reads −14. Below this a sensor offers no vibration evidence.
    static let silentLevel = -12.0
    let wheelbase: Double
    private let analyzer = AxleEchoAnalyzer()
    private let filter: SpeedGridFilter
    private var baselineSamples: [(time: Double, level: Double)] = []
    private(set) var baseline: Double?
    private var nextUpdate: Double?
    private var lastUpdate = 0.0
    private var velocityChange = 0.0
    private var pendingBiasShift = 0.0
    /// Latest posterior used for gravity aiding; parked until the first update.
    private(set) var speed = 0.0
    private(set) var uncertainty = 10.0
    private(set) var stoppedProbability = 1.0
    private(set) var accelerationBias = 0.0

    /// A known parked reference carries over when only the wheelbase changes.
    init(wheelbase: Double, baseline: Double? = nil) {
        self.wheelbase = clamp(wheelbase, Self.supportedWheelbase.lowerBound, Self.supportedWheelbase.upperBound)
        filter = SpeedGridFilter(wheelbase: self.wheelbase)
        self.baseline = baseline
    }

    /// Every valid frame, including parked calibration frames.
    func receive(time: Double, totalAcceleration: SIMD3<Double>, rotation: SIMD3<Double>, gravity: SIMD3<Double>) {
        let up = -simd_normalize(gravity)
        analyzer.append(time: time, values: [totalAcceleration.x, totalAcceleration.y, totalAcceleration.z,
                                             rotation.x, rotation.y, rotation.z, simd_dot(totalAcceleration, up)])
    }

    /// Parked vibration level, sampled every half second during calibration.
    func collectBaseline(time: Double, calibrationStart: Double) {
        guard time >= calibrationStart + 1, time - (baselineSamples.last?.time ?? -.infinity) >= 0.5,
              let level = analyzer.rollingLevel() else {
            return
        }
        baselineSamples.append((time, level))
    }

    func discardBaseline() {
        baselineSamples.removeAll(keepingCapacity: true)
    }

    /// A known-parked interval establishes the vibration reference and a zero-speed state.
    func completeCalibration(start: Double, end: Double) {
        let levels = baselineSamples.filter { sample in
            return sample.time >= start + 1 && sample.time <= end
        }.map { sample in
            return sample.level
        }
        if !levels.isEmpty {
            let level = SpeedGridFilter.median(levels)
            baseline = level > Self.silentLevel ? level : nil
        }
        baselineSamples.removeAll(keepingCapacity: true)
        filter.resetStopped()
        filter.resetBackground()
        nextUpdate = nil
        velocityChange = 0
        pendingBiasShift = 0
        speed = 0
        uncertainty = 0.2
        stoppedProbability = 1
        accelerationBias = 0
    }

    /// A reused calibration keeps the baseline but restarts parked.
    func beginSession() {
        analyzer.reset()
        completeCalibration(start: .infinity, end: .infinity)
    }

    func accumulate(forwardAcceleration: Double, duration: Double) {
        guard nextUpdate != nil else {
            return
        }
        velocityChange += forwardAcceleration * duration
    }

    /// Without a physical parked vibration reference there is no independent
    /// speed or stop evidence: no observations and no gravity aiding.
    var isActive: Bool {
        return baseline != nil
    }

    func recordGravityCorrection(forwardAccelerationChange: Double) {
        pendingBiasShift += forwardAccelerationChange
    }

    /// Emits at most one observation per half second of sensor time.
    func update(at time: Double) -> VibrationSpeedObservation? {
        guard isActive else {
            return nil
        }
        guard let scheduled = nextUpdate else {
            nextUpdate = time + SpeedGridFilter.hop
            lastUpdate = time
            velocityChange = 0
            return nil
        }
        guard time >= scheduled else {
            return nil
        }
        filter.shiftBias(by: pendingBiasShift)
        pendingBiasShift = 0
        let level = analyzer.rollingLevel()
        let posterior = filter.update(velocityChange: velocityChange, duration: time - lastUpdate,
                                      correlation: analyzer.correlation(), rollingLevel: level,
                                      baseline: baseline)
        speed = posterior.speed
        uncertainty = posterior.uncertainty
        stoppedProbability = posterior.stoppedProbability
        accelerationBias = posterior.bias
        velocityChange = 0
        lastUpdate = time
        nextUpdate = scheduled + SpeedGridFilter.hop
        if let next = nextUpdate, next < time {
            nextUpdate = time + SpeedGridFilter.hop
        }
        var rollingLevel: Double?
        if let baseline, let level {
            rollingLevel = level - baseline
        }
        return VibrationSpeedObservation(time: time, speed: posterior.speed, uncertainty: posterior.uncertainty,
                                         stoppedProbability: posterior.stoppedProbability, accelerationBias: posterior.bias,
                                         echoStrength: posterior.echoStrength, rollingLevel: rollingLevel,
                                         movingProbability: posterior.movingProbability, wheelbase: wheelbase)
    }
}
