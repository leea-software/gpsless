import Foundation
import simd

/// Converts Core Motion device axes into physical vehicle acceleration and yaw.
/// The supported mount has its top edge up and its screen facing rearward.
enum VehicleMotionProjection {
    static let convention = "coremotion-negated-g-v1"
    static let standardGravity = 9.80665

    static func sample(time: Double, userAcceleration: SIMD3<Double>, gravity: SIMD3<Double>, rotationRate: SIMD3<Double>, magneticMagnitude: Double? = nil, relativeAltitude: Double? = nil) -> MotionSample? {
        let gravityLength = simd_length(gravity)
        guard gravityLength > 0 else {
            return nil
        }
        let up = -gravity / gravityLength
        let screenForward = SIMD3<Double>(0, 0, -1)
        let projected = screenForward - up * simd_dot(screenForward, up)
        guard simd_length(projected) > 0.45 else {
            return nil
        }
        let forward = simd_normalize(projected)
        let right = simd_normalize(simd_cross(forward, up))

        // Core Motion reports gravity downward and acceleration with the opposite
        // sign to physical translation. Negate userAcceleration after gravity
        // removal; gyroscope rotation keeps its right-hand-rule convention.
        let acceleration = -userAcceleration * standardGravity
        return MotionSample(time: time,
                            forwardAcceleration: simd_dot(acceleration, forward),
                            lateralAcceleration: simd_dot(acceleration, right),
                            verticalAcceleration: simd_dot(acceleration, up),
                            yawRate: -simd_dot(rotationRate, up),
                            pitch: asin(clamp(up.z, -1, 1)),
                            roll: atan2(up.x, up.y),
                            gravityError: abs(gravityLength - 1),
                            magneticMagnitude: magneticMagnitude,
                            relativeAltitude: relativeAltitude)
    }
}
