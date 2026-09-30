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
    /// Learned tyre circumference ÷ wheelbase; nil until learned in this drive.
    public let tyreRatio: Double?

    public init(time: Double, speed: Double, uncertainty: Double, stoppedProbability: Double, accelerationBias: Double,
                echoStrength: Double, rollingLevel: Double?, movingProbability: Double?, wheelbase: Double, tyreRatio: Double? = nil) {
        self.time = time
        self.speed = speed
        self.uncertainty = uncertainty
        self.stoppedProbability = stoppedProbability
        self.accelerationBias = accelerationBias
        self.echoStrength = echoStrength
        self.rollingLevel = rollingLevel
        self.movingProbability = movingProbability
        self.wheelbase = wheelbase
        self.tyreRatio = tyreRatio
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
    /// Correlation values per 10 ms lag step. At highway speed the echo delay
    /// is 7–10 samples, so one sample is 10–14% of speed; linear
    /// interpolation between samples of a 40 Hz band-limited peak sampled at
    /// 100 Hz flattens it, so the correlation is evaluated band-limited at
    /// 2.5 ms steps instead.
    static let lagResolution = 4
    static let fineTransformSize = transformSize * lagResolution
    static let rollingWindow = 100
    static let rollingTransformSize = 128
    static let whitening = 0.8
    static let minimumBandEnergy = 1e-6
    enum Channel: Int, CaseIterable {
        case accelerationX, accelerationY, accelerationZ, rotationX, rotationY, rotationZ, vertical
    }
    /// Correlated channel pairs (the first lags the second), with their sign
    /// and weight. Engine 3.6 keeps the six channels correlated with
    /// themselves: on 10 GPS-referenced drives their echo peaks sat within 1%
    /// of the true delay, while cross-channel pairs peaked 2–15% away (the two
    /// sensors respond to a bump with different phase) and lateral
    /// acceleration 2–5% early, which read highway speed high. The weights are
    /// the mean per-pair echo signature at the true delay; it was the same on
    /// every drive and speed band (cosine 0.95–0.99).
    static let pairs: [(Channel, Channel, Double, Double)] = [
        (.accelerationX, .accelerationX, 1, 45.2), (.rotationZ, .rotationZ, 1, 41.3),
        (.vertical, .vertical, 1, 35.6), (.rotationY, .rotationY, 1, 31.8),
        (.rotationX, .rotationX, 1, 27.5), (.accelerationZ, .accelerationZ, 1, 24.4)
    ]
    /// Narrow spectral lines are capped at this multiple of the median power
    /// within ±2 Hz before whitening. An engine order (12.3 Hz while crawling
    /// at 30 km/h, 190 times the median) correlates at fixed delays every
    /// 81 ms and held vibration speed near 85 km/h; capping, unlike removing
    /// the bins, leaves no comb artifact and keeps broadband echo energy.
    static let lineCap = 8.0
    static let lineNeighbourhood = 20
    static let lineBlock = 5
    /// Below this window-centre speed the window is not resampled to
    /// distance: speed changes are then a large share of speed, and the
    /// echo is rarely measurable anyway.
    static let distanceMinimumSpeed = 3.0

    /// Median by insertion sort into a small buffer; windows here hold at
    /// most nine values.
    static func median(of values: ArraySlice<Double>) -> Double {
        var sorted: [Double] = []
        sorted.reserveCapacity(values.count)
        for value in values {
            var index = sorted.count
            while index > 0 && sorted[index - 1] > value {
                index -= 1
            }
            sorted.insert(value, at: index)
        }
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Seven vibration channels, then integrated forward acceleration (m/s)
    /// for resampling the window to distance.
    private var buffers = Array(repeating: [Double](repeating: 0, count: AxleEchoAnalyzer.window), count: 8)
    private var head = 0
    private(set) var count = 0
    private var gridTime: Double?
    private var previousTime = 0.0
    private var previousValues = [Double](repeating: 0, count: 8)
    private let transform = RadixTwoFFT(size: AxleEchoAnalyzer.transformSize)
    private let fineTransform = RadixTwoFFT(size: AxleEchoAnalyzer.fineTransformSize)
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
        buffers = Array(repeating: [Double](repeating: 0, count: Self.window), count: 8)
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
        for channel in 0..<min(8, values.count) {
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

    /// Weighted whitened correlation over lags 0..<maximumLag, with
    /// `lagResolution` values per 10 ms step. With the current speed, the
    /// window is first resampled to equal distance steps (see
    /// `distanceSamples`), so a lag still reads as time at the window-centre
    /// speed.
    func correlation(currentSpeed: Double? = nil) -> [Double]? {
        guard count >= Self.window else {
            return nil
        }
        let positions = currentSpeed.flatMap { speed in
            return distanceSamples(currentSpeed: speed)
        }
        var spectraReal: [[Double]] = []
        var spectraImaginary: [[Double]] = []
        var powers: [[Double]] = []
        for channel in 0..<7 {
            var values = recent(channel, Self.window)
            if let positions {
                let source = values
                values = positions.map { position in
                    let index = min(Self.window - 2, max(0, Int(position)))
                    let fraction = min(1, max(0, position - Double(index)))
                    return source[index] * (1 - fraction) + source[index + 1] * fraction
                }
            }
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
            // Local level within ±2 Hz: the median of 5-bin block medians,
            // which a cluster of line bins cannot raise and which avoids
            // sorting a 41-bin window for every bin.
            let first = band.lowerBound
            let blockCount = (band.count + Self.lineBlock - 1) / Self.lineBlock
            var blockMedians = [Double](repeating: 0, count: blockCount)
            for block in 0..<blockCount {
                let start = first + block * Self.lineBlock
                let end = min(band.upperBound, start + Self.lineBlock - 1)
                blockMedians[block] = Self.median(of: power[start...end])
            }
            let reach = Self.lineNeighbourhood / Self.lineBlock
            let original = power
            for bin in band {
                let block = (bin - first) / Self.lineBlock
                let level = Self.median(of: blockMedians[max(0, block - reach)...min(blockCount - 1, block + reach)])
                let limit = Self.lineCap * level
                if original[bin] > limit {
                    let scale = sqrt(limit / original[bin])
                    real[bin] *= scale
                    imaginary[bin] *= scale
                    power[bin] = limit
                }
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
        // The same bins in an R-times longer transform give x at n/R.
        var real = [Double](repeating: 0, count: Self.fineTransformSize)
        var imaginary = [Double](repeating: 0, count: Self.fineTransformSize)
        for bin in band {
            real[bin] = combinedReal[bin] / weightSum
            imaginary[bin] = -combinedImaginary[bin] / weightSum
        }
        fineTransform.forward(&real, &imaginary)
        return (0..<(Self.maximumLag * Self.lagResolution)).map { lag in
            return 2 * real[lag]
        }
    }

    /// Fractional sample positions that resample the window to equal steps of
    /// the window-centre speed × 10 ms along the road, from the integrated
    /// forward acceleration in channel 7. The axle echo is a fixed distance,
    /// so it stays one sharp peak while the car speeds up or brakes, whereas
    /// engine lines and mount resonances, fixed in time, smear. On an
    /// interchange approach where an engine line had held vibration speed
    /// near 85 km/h at about 30, this lowered the median reading on the
    /// straight from 35 to 21 km/h. Nil when the speed is too low or changes
    /// by less than 2% within the window.
    func distanceSamples(currentSpeed: Double) -> [Double]? {
        guard count >= Self.window else {
            return nil
        }
        let velocity = recent(7, Self.window)
        let centre = Self.window / 2
        let centreSpeed = currentSpeed - (velocity[Self.window - 1] - velocity[centre])
        guard centreSpeed >= Self.distanceMinimumSpeed else {
            return nil
        }
        let speeds = velocity.map { value in
            return centreSpeed + value - velocity[centre]
        }
        let slowest = speeds.min() ?? 0
        let fastest = speeds.max() ?? 0
        guard slowest >= 0.5 * centreSpeed, fastest - slowest >= 0.02 * centreSpeed else {
            return nil
        }
        var distance = [Double](repeating: 0, count: Self.window)
        for index in 1..<Self.window {
            distance[index] = distance[index - 1] + 0.5 * (speeds[index - 1] + speeds[index]) / Self.sampleRate
        }
        let step = centreSpeed / Self.sampleRate
        var positions = [Double](repeating: 0, count: Self.window)
        var source = 0
        for index in 0..<Self.window {
            let target = distance[centre] + Double(index - centre) * step
            if target <= distance[0] {
                positions[index] = 0
                continue
            }
            if target >= distance[Self.window - 1] {
                positions[index] = Double(Self.window - 1)
                continue
            }
            while source < Self.window - 2 && distance[source + 1] < target {
                source += 1
            }
            let span = distance[source + 1] - distance[source]
            positions[index] = Double(source) + (span > 0 ? (target - distance[source]) / span : 0)
        }
        return positions
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

/// Tyre circumference ÷ wheelbase, learned while driving. A tyre is never
/// perfectly round or balanced, so the car shakes once per wheel revolution
/// and the correlation repeats every circumference / speed. On field drives
/// of one car that period sat at 0.785 axle delays at every speed, and at
/// 110–120 km/h, where the axle echo is weak, it was read as the echo:
/// vibration speed held 135–140 km/h. Once the ratio is known, that
/// repetition is evidence for the true speed instead.
///
/// Each window where the echo is strong at a confident speed adds the
/// correlation at r and 2r axle delays for every candidate ratio r. The echo
/// peak's own ripples sit at fixed times beside it, so at one steady speed
/// they too repeat at a fixed ratio: a synthetic cruise without any tyre
/// vibration learned 0.745. The tyre's ratio is the same at every speed, the
/// ripples' is not, so windows are pooled per 2 m/s band, each band weighs
/// the same, and three bands must each peak within 0.02 of the pooled ratio.
/// On 11 field drives with enough such windows every band from 12 to 22 m/s
/// peaked at 0.775–0.815 and the pooled ratio was 0.785–0.805. Above 24 m/s
/// the tyre period lies within 20 ms of the echo and its bands peaked at the
/// range ends, so they are not used.
struct TyreRatioEvidence {
    /// 0.55–0.90: typical tyres are 1.9–2.4 m around and wheelbases 2.4–3.1 m;
    /// above 0.9 the echo peak itself would be counted.
    static let ratios = (0...70).map { Double($0) * 0.005 + 0.55 }
    static let bands = stride(from: 12.0, to: 24.0, by: 2.0).map { $0 }
    static let requiredWindows = 120
    static let requiredBands = 3
    static let bandWindows = 20
    static let bandAgreement = 0.02
    /// The best ratio's mean correlation must stand this many noise units
    /// above the median ratio's.
    static let requiredMargin = 1.0
    private(set) var sums = [[Double]](repeating: [Double](repeating: 0, count: TyreRatioEvidence.ratios.count),
                                       count: TyreRatioEvidence.bands.count)
    private(set) var counts = [Int](repeating: 0, count: TyreRatioEvidence.bands.count)

    var windows: Int {
        return counts.reduce(0, +)
    }

    var ratio: Double? {
        let full = counts.indices.filter { band in
            return counts[band] >= Self.bandWindows
        }
        guard windows >= Self.requiredWindows, full.count >= Self.requiredBands else {
            return nil
        }
        let means = Self.ratios.indices.map { index in
            return full.reduce(0) { total, band in
                return total + sums[band][index] / Double(counts[band])
            } / Double(full.count)
        }
        guard let best = means.indices.max(by: { means[$0] < means[$1] }),
              means[best] - SpeedGridFilter.median(means) >= Self.requiredMargin else {
            return nil
        }
        let agreeing = full.filter { band in
            guard let peak = sums[band].indices.max(by: { sums[band][$0] < sums[band][$1] }) else {
                return false
            }
            return abs(Self.ratios[peak] - Self.ratios[best]) <= Self.bandAgreement + 1e-9
        }
        return agreeing.count >= Self.requiredBands ? Self.ratios[best] : nil
    }

    /// `correlation(lag)` is the residual correlation in noise units, nil
    /// beyond the analysed lags; `delay` is the echo delay in lag steps.
    mutating func add(speed: Double, delay: Double, correlation: (Double) -> Double?) {
        guard speed < Self.bands[Self.bands.count - 1] + 2, let band = Self.bands.lastIndex(where: { $0 <= speed }) else {
            return
        }
        for (index, ratio) in Self.ratios.enumerated() {
            sums[band][index] += (correlation(ratio * delay) ?? 0) + (correlation(2 * ratio * delay) ?? 0)
        }
        counts[band] += 1
    }
}

/// Discrete Bayes filter over forward speed and residual acceleration bias.
final class SpeedGridFilter {
    /// 0–40 m/s (144 km/h). On a highway drive a 45 m/s grid let a false
    /// echo 1.4 times the true speed hold 158 km/h at 113 km/h for a minute.
    static let speeds = (0...200).map { Double($0) * 0.2 }
    /// Shortest usable axle delay. The former 0.1 s (101 km/h with a 2.82 m
    /// wheelbase) pulled faster driving towards that speed: on a highway drive
    /// vibration speed read 14 km/h low at 105–115 km/h and 45 km/h low above,
    /// although the echo stayed at its expected delay up to 125 km/h and
    /// correlation noise at 60–90 ms was within 25% of that at 100–150 ms.
    static let minimumEchoDelay = 0.06
    /// Above 90 km/h the echo weakened (median peak 2.2σ at 105–115 km/h
    /// against 3.5σ in town) while repeating vibration kept false peaks near
    /// 0.67 and 1.35 times the speed at 3.5σ. Evidence weight falls to this
    /// share by 115 km/h, for every hypothesis alike, so the filter leans on
    /// integrated acceleration instead of jumping between peaks.
    static let highwayEchoShare = 0.45
    static let highwayEchoSpeeds = 25.0...32.0
    /// Below about 20 km/h the echo is rarely measurable: on field drives the
    /// strongest correlation peak lay within 8% of the true delay in 10% of
    /// windows, close to chance, while short-delay correlation in slow turns
    /// supported speeds three to six times too high. Evidence weight falls to
    /// this share below the range, for every hypothesis alike.
    static let lowSpeedEchoShare = 0.4
    static let lowSpeedEchoSpeeds = 3.0...5.5
    /// A true axle echo is one delay. Tyre non-uniformity repeats every wheel
    /// revolution, and its correlation repeats at every multiple of that
    /// period: on field drives a comb sat at 0.785, 1.57 and 2.36 times the
    /// axle delay, and its first tooth held the speed 1.2–1.36 times too high
    /// for up to a minute at 45–60 km/h. Evidence at a delay is reduced by
    /// this multiple of the mean positive evidence at twice and three times it.
    /// Engine 3.4 used 2; with tyre evidence (engine 3.7) a weight fitted to
    /// GPS speed on 13 drives was 1.0–1.3, and 1.3 halved the time with speed
    /// more than 10 km/h off on the highway drive.
    static let repeatPenalty = 1.3
    /// Tyre-period evidence, relative to the echo, once the ratio is learned.
    /// A logistic fit to GPS speed on 13 drives gave 0.6. It applies only
    /// while the predicted speed is above `tyreSpeeds`: crawling at 30 km/h
    /// with an engine line every 81 ms, a known ratio otherwise read the line
    /// as the tyre period of 98 km/h. It is exempt from the highway share,
    /// because above 90 km/h the tyre period is the stronger evidence.
    static let tyreShare = 0.5
    static let tyreSpeeds = 12.0...16.0
    /// Windows that teach the tyre ratio: confident speed, and an echo peak of
    /// at least `tyreLearningEcho` noise units within −5%/+8% of its delay.
    static let tyreLearningSpread = 0.6
    static let tyreLearningEcho = 3.0
    /// A car turning at yaw rate ω with speed v accelerates v·ω sideways,
    /// independently of vibration. In turns above 0.1 rad/s (5.7°/s) on
    /// GPS-logged drives, lateral acceleration ÷ yaw rate gave a median 0.99
    /// times GPS speed with a residual of about 0.3 m/s², growing with the
    /// yaw rate. On an interchange ramp driven at 30 km/h it showed a
    /// vibration speed of 110 km/h to be false. The z-score is capped at 3
    /// because turn entries and exits, where lateral acceleration lags the
    /// yaw rate, gave about one outlier in ten.
    static let centripetalMinimumYawRate = 0.1

    static func turnLikelihood(_ turn: Turn, speed: Double) -> Double {
        guard abs(turn.yawRate) >= centripetalMinimumYawRate else {
            return 1
        }
        let sigma = 0.25 + 0.6 * abs(turn.yawRate)
        let z = (turn.lateralAcceleration - speed * turn.yawRate) / sigma
        return exp(-0.5 * min(9, z * z))
    }
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
    private(set) var tyreEvidence = TyreRatioEvidence()
    private let lagIndex: [Int]
    private let lagFraction: [Double]
    private let echoSupported: [Bool]
    /// Unclamped axle delay per speed row, in fine lag steps.
    private let echoLags: [Double]
    private var speedCount: Int { Self.speeds.count }
    private var biasCount: Int { Self.biases.count }

    init(wheelbase: Double) {
        self.wheelbase = wheelbase
        probability = []
        var indices: [Int] = []
        var fractions: [Double] = []
        var supported: [Bool] = []
        var delays: [Double] = []
        let maximumLag = Double(AxleEchoAnalyzer.maximumLag)
        let resolution = Double(AxleEchoAnalyzer.lagResolution)
        for speed in Self.speeds {
            let delay = wheelbase / max(speed, 1e-3) * AxleEchoAnalyzer.sampleRate * resolution
            delays.append(delay)
            let lag = clamp(delay, 0, maximumLag * resolution - 2)
            indices.append(Int(lag))
            fractions.append(lag - Double(Int(lag)))
            supported.append(speed >= wheelbase / (maximumLag / AxleEchoAnalyzer.sampleRate - 0.05)
                             && speed <= wheelbase / Self.minimumEchoDelay)
        }
        lagIndex = indices
        lagFraction = fractions
        echoSupported = supported
        echoLags = delays
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

    func resetTyreEvidence() {
        tyreEvidence = TyreRatioEvidence()
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

    /// Mean lateral acceleration (m/s², right positive) and yaw rate (rad/s,
    /// clockwise positive) over the update interval.
    struct Turn {
        let lateralAcceleration: Double
        let yawRate: Double
    }

    struct Posterior {
        let speed: Double
        let uncertainty: Double
        let stoppedProbability: Double
        let bias: Double
        let echoStrength: Double
        let movingProbability: Double?
        let tyreRatio: Double?
    }

    func update(velocityChange: Double, duration: Double, correlation: [Double]?, rollingLevel: Double?, baseline: Double?,
                turn: Turn? = nil) -> Posterior {
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
        var learning: (residual: [Double], noise: Double)?
        if let correlation {
            if let background {
                let residual = zip(correlation, background).map { value, reference in
                    return value - reference
                }
                let predicted = Self.meanSpeed(next)
                let ratio = tyreEvidence.ratio
                let tail = residual[(10 * AxleEchoAnalyzer.lagResolution)...]
                let mean = tail.reduce(0, +) / Double(tail.count)
                let noise = sqrt(tail.reduce(0) { total, value in
                    return total + (value - mean) * (value - mean)
                } / Double(tail.count)) + 1e-12
                var supportedScores: [Double] = []
                var scores = [Double](repeating: 0, count: speedCount)
                var peak = -Double.infinity
                for row in 0..<speedCount {
                    let value = (1 - lagFraction[row]) * residual[lagIndex[row]] + lagFraction[row] * residual[lagIndex[row] + 1]
                    let evidence = rowEvidence(residual, row: row, predictedSpeed: predicted, tyreRatio: ratio)
                    scores[row] = clamp(evidence / noise, -20, 20)
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
                learning = (residual, noise)
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
        if let turn {
            for row in 0..<speedCount {
                likelihood[row] *= Self.turnLikelihood(turn, speed: Self.speeds[row])
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
        let spread = sqrt(max(0, square - mean * mean))
        if let learning, spread <= Self.tyreLearningSpread, stopped < 0.01 {
            // The echo window is centred two seconds back.
            let centreSpeed = mean - (changeSinceCentre - bias * timeSinceCentre)
            learnTyreRatio(learning.residual, noise: learning.noise, centreSpeed: centreSpeed)
        }
        return Posterior(speed: mean, uncertainty: spread, stoppedProbability: stopped,
                         bias: bias, echoStrength: echoStrength, movingProbability: movingProbability, tyreRatio: tyreEvidence.ratio)
    }

    /// Adds a window to the tyre-ratio evidence when the echo is strong near
    /// the delay of the confident centre speed.
    private func learnTyreRatio(_ residual: [Double], noise: Double, centreSpeed: Double) {
        guard centreSpeed >= Self.tyreSpeeds.lowerBound else {
            return
        }
        func correlation(_ lag: Double) -> Double? {
            guard lag >= 0, lag < Double(residual.count - 2) else {
                return nil
            }
            let index = Int(lag)
            let fraction = lag - Double(index)
            return ((1 - fraction) * residual[index] + fraction * residual[index + 1]) / noise
        }
        let expected = wheelbase / centreSpeed * AxleEchoAnalyzer.sampleRate * Double(AxleEchoAnalyzer.lagResolution)
        var delay = expected
        var strongest = -Double.infinity
        for lag in Int(expected * 0.95)...Int(expected * 1.08) {
            if let value = correlation(Double(lag)), value > strongest {
                strongest = value
                delay = Double(lag)
            }
        }
        guard strongest >= Self.tyreLearningEcho else {
            return
        }
        tyreEvidence.add(speed: centreSpeed, delay: delay, correlation: correlation)
    }

    /// Mean residual correlation at one and two tyre periods of a speed row.
    func tyreEvidence(_ residual: [Double], row: Int, ratio: Double) -> Double {
        guard echoSupported[row] else {
            return 0
        }
        let ramp = clamp((Self.speeds[row] - Self.tyreSpeeds.lowerBound) / (Self.tyreSpeeds.upperBound - Self.tyreSpeeds.lowerBound), 0, 1)
        guard ramp > 0 else {
            return 0
        }
        var total = 0.0
        var count = 0
        for multiple in [1.0, 2.0] {
            let lag = echoLags[row] * ratio * multiple
            guard lag < Double(residual.count - 2) else {
                continue
            }
            let index = Int(lag)
            let fraction = lag - Double(index)
            total += (1 - fraction) * residual[index] + fraction * residual[index + 1]
            count += 1
        }
        return count > 0 ? ramp * total / Double(count) : 0
    }

    /// Weighted evidence for a speed row before noise normalisation: the axle
    /// echo, tempered by the predicted speed, plus the tyre period once its
    /// ratio is known and the predicted speed is high enough.
    func rowEvidence(_ residual: [Double], row: Int, predictedSpeed: Double, tyreRatio: Double?) -> Double {
        var evidence = echoGain * echoScale(predictedSpeed) * echoEvidence(residual, row: row)
        let tyre = clamp((predictedSpeed - Self.tyreSpeeds.lowerBound) / (Self.tyreSpeeds.upperBound - Self.tyreSpeeds.lowerBound), 0, 1)
        if let tyreRatio, tyre > 0 {
            evidence += Self.tyreShare * echoGain * tyre * tyreEvidence(residual, row: row, ratio: tyreRatio)
        }
        return evidence
    }

    /// Residual correlation at a speed row's axle delay, less what repeats at
    /// its multiples.
    func echoEvidence(_ residual: [Double], row: Int) -> Double {
        let value = (1 - lagFraction[row]) * residual[lagIndex[row]] + lagFraction[row] * residual[lagIndex[row] + 1]
        guard echoSupported[row] else {
            return value
        }
        return value - Self.repeatPenalty * repeatedEvidence(residual, delay: echoLags[row])
    }

    /// Mean positive correlation at twice and three times a delay, where a
    /// repeating wheel vibration also correlates but a single echo does not.
    private func repeatedEvidence(_ residual: [Double], delay: Double) -> Double {
        var total = 0.0
        var count = 0
        for multiple in [2.0, 3.0] {
            let lag = delay * multiple
            guard lag < Double(residual.count - 2) else {
                continue
            }
            let index = Int(lag)
            let fraction = lag - Double(index)
            total += (1 - fraction) * residual[index] + fraction * residual[index + 1]
            count += 1
        }
        return count > 0 ? max(0, total / Double(count)) : 0
    }

    private static func meanSpeed(_ grid: [Double]) -> Double {
        let biasCount = biases.count
        var total = 0.0
        var mean = 0.0
        for row in 0..<speeds.count {
            for column in 0..<biasCount {
                total += grid[row * biasCount + column]
                mean += grid[row * biasCount + column] * speeds[row]
            }
        }
        return total > 0 ? mean / total : 0
    }

    /// Echo weight for the predicted mean speed.
    private func echoScale(_ speed: Double) -> Double {
        let highway = Self.highwayEchoSpeeds
        let fast = clamp((speed - highway.lowerBound) / (highway.upperBound - highway.lowerBound), 0, 1)
        let low = Self.lowSpeedEchoSpeeds
        let moving = clamp((speed - low.lowerBound) / (low.upperBound - low.lowerBound), 0, 1)
        return (1 - fast * (1 - Self.highwayEchoShare)) * (Self.lowSpeedEchoShare + (1 - Self.lowSpeedEchoShare) * moving)
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
    static let distanceMaximumSpread = 3.0
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
                                             rotation.x, rotation.y, rotation.z, simd_dot(totalAcceleration, up),
                                             integratedVelocity])
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

    /// A reused calibration keeps the baseline but restarts parked. The tyre
    /// ratio is learned again, as it is when a recording replays from its
    /// reused calibration row.
    func beginSession() {
        analyzer.reset()
        integratedVelocity = 0
        filter.resetTyreEvidence()
        completeCalibration(start: .infinity, end: .infinity)
    }

    private var lateralChange = 0.0
    private var yawChange = 0.0
    private var turnDuration = 0.0
    /// Forward acceleration less the estimated bias, integrated; only its
    /// changes within the four-second echo window are used.
    private var integratedVelocity = 0.0

    func accumulate(forwardAcceleration: Double, lateralAcceleration: Double = 0, yawRate: Double = 0, duration: Double) {
        integratedVelocity += (forwardAcceleration - accelerationBias) * duration
        guard nextUpdate != nil else {
            return
        }
        velocityChange += forwardAcceleration * duration
        lateralChange += lateralAcceleration * duration
        yawChange += yawRate * duration
        turnDuration += duration
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
            lateralChange = 0
            yawChange = 0
            turnDuration = 0
            return nil
        }
        guard time >= scheduled else {
            return nil
        }
        filter.shiftBias(by: pendingBiasShift)
        pendingBiasShift = 0
        let level = analyzer.rollingLevel()
        var turn: SpeedGridFilter.Turn?
        if turnDuration > 0 {
            turn = SpeedGridFilter.Turn(lateralAcceleration: lateralChange / turnDuration, yawRate: yawChange / turnDuration)
        }
        // The distance resampling needs a speed that is roughly right; a wide
        // posterior (two modes) would stretch the window by the wrong factor.
        let reference = uncertainty <= Self.distanceMaximumSpread ? speed : nil
        let posterior = filter.update(velocityChange: velocityChange, duration: time - lastUpdate,
                                      correlation: analyzer.correlation(currentSpeed: reference), rollingLevel: level,
                                      baseline: baseline, turn: turn)
        lateralChange = 0
        yawChange = 0
        turnDuration = 0
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
                                         movingProbability: posterior.movingProbability, wheelbase: wheelbase,
                                         tyreRatio: posterior.tyreRatio)
    }
}
