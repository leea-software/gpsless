import Foundation

public struct Vector2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public var length: Double {
        return hypot(x, y)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        return Self(lhs.x + rhs.x, lhs.y + rhs.y)
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        return Self(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    public static func * (lhs: Self, rhs: Double) -> Self {
        return Self(lhs.x * rhs, lhs.y * rhs)
    }

    public func dot(_ other: Self) -> Double {
        return x * other.x + y * other.y
    }
}

/// The local plane in which road geometry is measured. Kyiv and datasets
/// without a projection keep the original equirectangular plane around
/// 50.45° N, 30.52° E, so the Kyiv snapshot and its recordings are unchanged.
/// Larger regions use a conformal stereographic plane centred on the region:
/// its scale error stays below 0.01% within 100 km of the centre, where the
/// Kyiv plane would be about 3% wrong east-west in the Carpathians.
public struct MapProjection: Codable, Equatable, Sendable {
    public var kind: String
    public var latitude: Double
    public var longitude: Double

    public init(kind: String, latitude: Double, longitude: Double) {
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
    }

    public static let kyiv = MapProjection(kind: "equirectangular", latitude: 50.45, longitude: 30.52)
    static let radius = 111_320 * 180 / Double.pi

    /// Set when a road graph loads; one region is active at a time and it is
    /// never changed while tracking.
    public static var current = kyiv

    func metres(latitude: Double, longitude: Double) -> Vector2 {
        guard kind == "stereographic" else {
            return Vector2((longitude - self.longitude) * 111_320 * cos(self.latitude * .pi / 180), (latitude - self.latitude) * 111_320)
        }
        let phi = latitude * .pi / 180
        let origin = self.latitude * .pi / 180
        let lambda = (longitude - self.longitude) * .pi / 180
        let scale = 2 * Self.radius / (1 + sin(origin) * sin(phi) + cos(origin) * cos(phi) * cos(lambda))
        return Vector2(scale * cos(phi) * sin(lambda), scale * (cos(origin) * sin(phi) - sin(origin) * cos(phi) * cos(lambda)))
    }

    func coordinate(_ metres: Vector2) -> Coordinate {
        guard kind == "stereographic" else {
            return Coordinate(latitude: self.latitude + metres.y / 111_320,
                              longitude: self.longitude + metres.x / (111_320 * cos(self.latitude * .pi / 180)))
        }
        let origin = self.latitude * .pi / 180
        let rho = metres.length
        guard rho > 1e-9 else {
            return Coordinate(latitude: self.latitude, longitude: self.longitude)
        }
        let c = 2 * atan(rho / (2 * Self.radius))
        let phi = asin(cos(c) * sin(origin) + metres.y * sin(c) * cos(origin) / rho)
        let lambda = atan2(metres.x * sin(c), rho * cos(origin) * cos(c) - metres.y * sin(origin) * sin(c))
        return Coordinate(latitude: phi * 180 / .pi, longitude: self.longitude + lambda * 180 / .pi)
    }
}

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var metres: Vector2 {
        return MapProjection.current.metres(latitude: latitude, longitude: longitude)
    }

    public init(metres: Vector2) {
        self = MapProjection.current.coordinate(metres)
    }
}

public func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
    return atan2(sin(lhs - rhs), cos(lhs - rhs))
}

public func bearing(_ vector: Vector2) -> Double {
    return atan2(vector.x, vector.y)
}

public func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    return min(upper, max(lower, value))
}

public struct SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) {
        state = max(1, seed)
    }

    public mutating func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992
    }

    public mutating func normal() -> Double {
        return sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform())
    }
}
