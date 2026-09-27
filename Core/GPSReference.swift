import Foundation

/// Reference observations are recording data only. They have no conversion to
/// MotionSample or any other TrackingEngine input.
struct GPSReferenceSample: Codable {
    let timestamp: Double?
    let time: Double?
    let receivedTimestamp: Double
    let receivedUptime: Double
    let ageSeconds: Double?
    let coordinate: Coordinate?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let speed: Double?
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let reducedAccuracy: Bool
    let simulatedBySoftware: Bool
    let producedByAccessory: Bool
    let batchSize: Int
    var qualityFlags: [String]

    init(timestamp: Double, receivedTimestamp: Double, receivedUptime: Double,
         coordinate: Coordinate, altitude: Double, horizontalAccuracy: Double,
         verticalAccuracy: Double, speed: Double, speedAccuracy: Double,
         course: Double, courseAccuracy: Double, reducedAccuracy: Bool,
         simulatedBySoftware: Bool, producedByAccessory: Bool, batchSize: Int = 1) {
        self.timestamp = Self.finite(timestamp)
        self.receivedTimestamp = receivedTimestamp
        self.receivedUptime = receivedUptime
        var age: Double?
        var uptime: Double?
        if timestamp.isFinite, receivedTimestamp.isFinite, receivedUptime.isFinite {
            age = Self.finite(receivedTimestamp - timestamp)
            uptime = Self.finite(receivedUptime - (receivedTimestamp - timestamp))
        }
        ageSeconds = age
        time = uptime
        var flags: [String] = []
        if coordinate.latitude.isFinite, coordinate.longitude.isFinite,
           abs(coordinate.latitude) <= 90, abs(coordinate.longitude) <= 180 {
            self.coordinate = coordinate
        } else {
            self.coordinate = nil
            flags.append("invalid_coordinate")
        }
        self.altitude = Self.finite(altitude)
        self.horizontalAccuracy = Self.finite(horizontalAccuracy)
        self.verticalAccuracy = Self.finite(verticalAccuracy)
        self.speed = Self.finite(speed)
        self.speedAccuracy = Self.finite(speedAccuracy)
        self.course = Self.finite(course)
        self.courseAccuracy = Self.finite(courseAccuracy)
        self.reducedAccuracy = reducedAccuracy
        self.simulatedBySoftware = simulatedBySoftware
        self.producedByAccessory = producedByAccessory
        self.batchSize = batchSize
        if !timestamp.isFinite {
            flags.append("invalid_timestamp")
        }
        if let age {
            if age > 3 {
                flags.append("stale_fix")
            }
            if age < -1 {
                flags.append("future_fix")
            }
        }
        if !horizontalAccuracy.isFinite || horizontalAccuracy < 0 {
            flags.append("invalid_horizontal_accuracy")
        } else if horizontalAccuracy > 25 {
            flags.append("poor_horizontal_accuracy")
        }
        if !verticalAccuracy.isFinite || verticalAccuracy < 0 || !altitude.isFinite {
            flags.append("invalid_altitude")
        }
        if !speed.isFinite || speed < 0 || !speedAccuracy.isFinite || speedAccuracy < 0 {
            flags.append("invalid_speed")
        } else if speedAccuracy > 3 {
            flags.append("poor_speed_accuracy")
        }
        if !course.isFinite || course < 0 || course >= 360 || !courseAccuracy.isFinite || courseAccuracy < 0 {
            flags.append("invalid_course")
        }
        if reducedAccuracy {
            flags.append("reduced_accuracy")
        }
        if simulatedBySoftware {
            flags.append("software_simulation")
        }
        if producedByAccessory {
            flags.append("accessory_source")
        }
        qualityFlags = flags
    }

    private static func finite(_ value: Double) -> Double? {
        guard value.isFinite else {
            return nil
        }
        return value
    }
}

/// Bounds reference logging and preserves timing anomalies for later analysis.
/// The capture ends by discarding this value; no motion state is owned here.
struct GPSReferenceCapture {
    let id = UUID()
    let startTimestamp: Double
    let startUptime: Double
    private(set) var recordedCount = 0
    private(set) var throttledCount = 0
    private var lastReceiptUptime: Double?
    private var lastFixTimestamp: Double?

    init(startTimestamp: Double, startUptime: Double) {
        self.startTimestamp = startTimestamp
        self.startUptime = startUptime
    }

    mutating func record(_ input: GPSReferenceSample) -> GPSReferenceSample? {
        guard input.receivedTimestamp.isFinite, input.receivedUptime.isFinite else {
            return nil
        }
        if let lastReceiptUptime, input.receivedUptime - lastReceiptUptime < 1 {
            throttledCount += 1
            return nil
        }
        var sample = input
        if let timestamp = input.timestamp {
            if timestamp < startTimestamp {
                sample.qualityFlags.append("predates_trace")
            }
            if let lastFixTimestamp, timestamp <= lastFixTimestamp {
                sample.qualityFlags.append("non_increasing_fix_timestamp")
            }
            lastFixTimestamp = timestamp
        }
        let wallElapsed = input.receivedTimestamp - startTimestamp
        let uptimeElapsed = input.receivedUptime - startUptime
        if abs(wallElapsed - uptimeElapsed) > 1 {
            sample.qualityFlags.append("wall_clock_changed")
        }
        lastReceiptUptime = input.receivedUptime
        recordedCount += 1
        return sample
    }
}
