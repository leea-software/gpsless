import Foundation
import simd

public struct CameraMotionPose: Codable, Sendable {
    public let time: Double
    public let quaternion: [Double]
    public let angularRate: Double
    public let rotationRate: [Double]
    public let gravity: [Double]
    public let attitudeDisagreementRadians: Double?

    public init(time: Double, quaternion: [Double], angularRate: Double,
                rotationRate: [Double] = [0, 0, 0], gravity: [Double] = [0, -1, 0],
                attitudeDisagreementRadians: Double? = nil) {
        self.time = time
        self.quaternion = quaternion
        self.angularRate = angularRate
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.attitudeDisagreementRadians = attitudeDisagreementRadians
    }

    init(raw: RawMotion, processing: MotionProcessingDiagnostic?) {
        var disagreement: Double?
        if let processing, abs(processing.time - raw.time) < 0.000_001 {
            disagreement = processing.gravityDisagreementDegrees * .pi / 180
        }
        let angularRate = sqrt(raw.rotation.reduce(0.0) { total, value in
            return total + value * value
        })
        self.init(time: raw.time, quaternion: raw.quaternion, angularRate: angularRate,
                  rotationRate: raw.rotation, gravity: raw.gravity,
                  attitudeDisagreementRadians: disagreement)
    }

    var rotation: simd_quatd? {
        guard quaternion.count == 4, quaternion.allSatisfy({ value in
            return value.isFinite
        }) else {
            return nil
        }
        let result = simd_quatd(ix: quaternion[0], iy: quaternion[1], iz: quaternion[2], r: quaternion[3])
        guard result.length > 0.9, result.length < 1.1 else {
            return nil
        }
        let normalized = result.normalized
        guard gravity.count == 3 else {
            return normalized
        }
        let gravityVector = SIMD3<Double>(gravity[0], gravity[1], gravity[2])
        guard gravityVector.x.isFinite, gravityVector.y.isFinite, gravityVector.z.isFinite,
              simd_length(gravityVector) > 0.8 else {
            return nil
        }
        let up = -simd_normalize(gravityVector)
        let directScore = normalized.act(up).z
        let inverseScore = normalized.inverse.act(up).z
        var selected = normalized
        if inverseScore > directScore {
            selected = normalized.inverse
        }
        guard max(directScore, inverseScore) >= 0.85 else {
            return nil
        }
        return selected
    }

}


public struct CameraFrameGeometry: Codable, Sendable {
    public let time: Double
    public let width: Int
    public let height: Int
    public let focalX: Double
    public let focalY: Double
    public let principalX: Double
    public let principalY: Double
    public let pose: CameraMotionPose

    public init(time: Double, width: Int, height: Int, focalX: Double, focalY: Double,
                principalX: Double, principalY: Double, pose: CameraMotionPose) {
        self.time = time
        self.width = width
        self.height = height
        self.focalX = focalX
        self.focalY = focalY
        self.principalX = principalX
        self.principalY = principalY
        self.pose = pose
    }
}

public struct TrackedImageMotion: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let deltaX: Double
    public let deltaY: Double
    public let texture: Double
    public let luminance: Double

    public init(x: Double, y: Double, deltaX: Double, deltaY: Double,
                texture: Double = 1, luminance: Double = 0.5) {
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.texture = texture
        self.luminance = luminance
    }
}

public struct VisualSpeedObservation: Codable, Sendable {
    public let time: Double
    public let speed: Double
    public let uncertainty: Double
    public let quality: Double

    public init(time: Double, speed: Double, uncertainty: Double, quality: Double) {
        self.time = time
        self.speed = speed
        self.uncertainty = uncertainty
        self.quality = quality
    }
}

public struct VisualSpeedDiagnostic: Codable, Sendable {
    public let time: Double
    public let previousTime: Double?
    public let region: [Double]
    public let cameraHeightMetres: Double
    public let focalPixels: [Double]
    public let candidateCount: Int
    public let inlierCount: Int
    public let medianTexture: Double
    public let attitudeDisagreementDegrees: Double?
    public let visualSpeed: Double?
    public let uncertainty: Double?
    public let quality: Double
    public var accepted: Bool
    public var reason: String
    public var fusedSpeedBefore: Double?
    public var fusedSpeedAfter: Double?
    public var fusedPositionChangeMetres: Double?

    public init(time: Double, previousTime: Double?, region: [Double], cameraHeightMetres: Double,
                focalPixels: [Double], candidateCount: Int, inlierCount: Int, medianTexture: Double,
                visualSpeed: Double?, uncertainty: Double?, quality: Double, accepted: Bool,
                reason: String, fusedSpeedBefore: Double? = nil, fusedSpeedAfter: Double? = nil,
                fusedPositionChangeMetres: Double? = nil,
                attitudeDisagreementDegrees: Double? = nil) {
        self.time = time
        self.previousTime = previousTime
        self.region = region
        self.cameraHeightMetres = cameraHeightMetres
        self.focalPixels = focalPixels
        self.candidateCount = candidateCount
        self.inlierCount = inlierCount
        self.medianTexture = medianTexture
        self.attitudeDisagreementDegrees = attitudeDisagreementDegrees
        self.visualSpeed = visualSpeed
        self.uncertainty = uncertainty
        self.quality = quality
        self.accepted = accepted
        self.reason = reason
        self.fusedSpeedBefore = fusedSpeedBefore
        self.fusedSpeedAfter = fusedSpeedAfter
        self.fusedPositionChangeMetres = fusedPositionChangeMetres
    }

    public var observation: VisualSpeedObservation? {
        guard accepted, let visualSpeed, let uncertainty else {
            return nil
        }
        return VisualSpeedObservation(time: time, speed: visualSpeed, uncertainty: uncertainty, quality: quality)
    }
}

public enum RoadPlaneVisualSpeedEstimator {
    public static func estimate(previous: CameraFrameGeometry, current: CameraFrameGeometry,
                                tracks: [TrackedImageMotion], cameraHeightMetres: Double,
                                region: [Double]) -> VisualSpeedDiagnostic {
        let time = current.time
        let dt = current.time - previous.time
        guard cameraHeightMetres.isFinite, cameraHeightMetres >= 0.6, cameraHeightMetres <= 2.5 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "invalid_camera_height")
        }
        guard previous.width == current.width, previous.height == current.height,
              previous.width > 0, previous.height > 0 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "frame_geometry_changed")
        }
        guard dt >= 0.08, dt <= 0.5 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "invalid_frame_interval")
        }
        guard let previousRotation = previous.pose.rotation, let currentRotation = current.pose.rotation else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "missing_attitude")
        }
        guard let previousAttitudeDisagreement = previous.pose.attitudeDisagreementRadians,
              let currentAttitudeDisagreement = current.pose.attitudeDisagreementRadians else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "attitude_trust_unavailable")
        }
        let attitudeDisagreement = max(previousAttitudeDisagreement, currentAttitudeDisagreement)
        guard attitudeDisagreement.isFinite, attitudeDisagreement <= 2 * .pi / 180 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count,
                            reason: "attitude_reference_disagreement")
        }
        guard previous.pose.angularRate < 1.2, current.pose.angularRate < 1.2 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "excessive_rotation")
        }
        let cameraForward = previousRotation.act(SIMD3<Double>(0, 0, -1))
        let horizontalForward = SIMD3<Double>(cameraForward.x, cameraForward.y, 0)
        guard simd_length(horizontalForward) > 0.45 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "camera_not_facing_horizon")
        }
        let forward = simd_normalize(horizontalForward)
        let lateral = SIMD3<Double>(forward.y, -forward.x, 0)
        var translations: [(forward: Double, lateral: Double, texture: Double)] = []
        for track in tracks {
            guard track.texture >= 0.08, track.luminance >= 0.04, track.luminance <= 0.96 else {
                continue
            }
            guard let first = groundOffset(x: track.x, y: track.y, frame: previous,
                                           rotation: previousRotation, cameraHeight: cameraHeightMetres),
                  let second = groundOffset(x: track.x + track.deltaX, y: track.y + track.deltaY,
                                            frame: current, rotation: currentRotation,
                                            cameraHeight: cameraHeightMetres) else {
                continue
            }
            let translation = first - second
            translations.append((simd_dot(translation, forward), simd_dot(translation, lateral), track.texture))
        }
        let texture = median(translations.map { item in
            return item.texture
        }) ?? 0
        guard translations.count >= 12 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, valid: translations.count,
                            texture: texture, reason: "insufficient_road_features")
        }
        guard let centre = median(translations.map({ item in
            return item.forward
        })) else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, reason: "insufficient_geometry")
        }
        let deviations = translations.map { item in
            return abs(item.forward - centre)
        }
        let mad = median(deviations) ?? .infinity
        let threshold = max(0.06, 3.5 * 1.4826 * mad)
        let inliers = translations.filter { item in
            return abs(item.forward - centre) <= threshold
        }
        let inlierRatio = Double(inliers.count) / Double(translations.count)
        guard inliers.count >= 10, inlierRatio >= 0.55 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, valid: inliers.count,
                            texture: texture, reason: "inconsistent_or_moving_features")
        }
        let distance = median(inliers.map { item in
            return item.forward
        }) ?? 0
        let lateralDistance = abs(median(inliers.map { item in
            return item.lateral
        }) ?? 0)
        guard lateralDistance <= max(0.18, abs(distance) * 0.35) else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, valid: inliers.count,
                            texture: texture, reason: "lateral_or_nonroad_motion")
        }
        let speed = distance / dt
        guard speed >= -0.5, speed <= 55 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, valid: inliers.count,
                            texture: texture, reason: "implausible_visual_speed")
        }
        let dispersion = 1.4826 * (median(inliers.map { item in
            return abs(item.forward - distance)
        }) ?? 0) / dt
        var attitudeScaleUncertainty = 0.0
        if attitudeDisagreement >= 0.25 * .pi / 180 {
            let negativeSpeed = speedWithTiltOffset(-attitudeDisagreement, previous: previous,
                                                    current: current, tracks: tracks,
                                                    cameraHeight: cameraHeightMetres,
                                                    lateralAxis: lateral)
            let positiveSpeed = speedWithTiltOffset(attitudeDisagreement, previous: previous,
                                                    current: current, tracks: tracks,
                                                    cameraHeight: cameraHeightMetres,
                                                    lateralAxis: lateral)
            guard let negativeSpeed, let positiveSpeed else {
                return rejected(time: time, previous: previous.time, region: region,
                                height: cameraHeightMetres, current: current,
                                candidates: tracks.count, valid: inliers.count,
                                texture: texture, speed: max(0, speed),
                                reason: "attitude_scale_unbounded")
            }
            attitudeScaleUncertainty = max(abs(negativeSpeed - speed), abs(positiveSpeed - speed))
        }
        let uncertainty = max(1.2, dispersion + 0.08 * max(0, speed), attitudeScaleUncertainty)
        let countQuality = min(1, Double(inliers.count) / 36)
        let textureQuality = min(1, texture / 0.22)
        let dispersionQuality = 1 / (1 + uncertainty / 5)
        let quality = min(0.9, countQuality * textureQuality * dispersionQuality * inlierRatio)
        guard quality >= 0.2 else {
            return rejected(time: time, previous: previous.time, region: region, height: cameraHeightMetres,
                            current: current, candidates: tracks.count, valid: inliers.count,
                            texture: texture, speed: max(0, speed), uncertainty: uncertainty,
                            quality: quality, reason: "poor_tracking_quality")
        }
        return VisualSpeedDiagnostic(time: time, previousTime: previous.time, region: region,
                                     cameraHeightMetres: cameraHeightMetres,
                                     focalPixels: [current.focalX, current.focalY],
                                     candidateCount: tracks.count, inlierCount: inliers.count,
                                     medianTexture: texture, visualSpeed: max(0, speed),
                                     uncertainty: uncertainty, quality: quality, accepted: true,
                                     reason: "accepted_road_plane_motion",
                                     attitudeDisagreementDegrees: attitudeDisagreement * 180 / .pi)
    }

    private static func speedWithTiltOffset(_ angle: Double, previous: CameraFrameGeometry,
                                            current: CameraFrameGeometry,
                                            tracks: [TrackedImageMotion], cameraHeight: Double,
                                            lateralAxis: SIMD3<Double>) -> Double? {
        guard let previousRotation = previous.pose.rotation,
              let currentRotation = current.pose.rotation else {
            return nil
        }
        let tilt = simd_quatd(angle: angle, axis: lateralAxis)
        let adjustedPrevious = tilt * previousRotation
        let adjustedCurrent = tilt * currentRotation
        let adjustedForward3D = adjustedPrevious.act(SIMD3<Double>(0, 0, -1))
        let adjustedHorizontal = SIMD3<Double>(adjustedForward3D.x, adjustedForward3D.y, 0)
        guard simd_length(adjustedHorizontal) > 0.45 else {
            return nil
        }
        let adjustedForward = simd_normalize(adjustedHorizontal)
        var distances: [Double] = []
        for track in tracks {
            guard track.texture >= 0.08, track.luminance >= 0.04, track.luminance <= 0.96 else {
                continue
            }
            guard let first = groundOffset(x: track.x, y: track.y, frame: previous,
                                           rotation: adjustedPrevious, cameraHeight: cameraHeight),
                  let second = groundOffset(x: track.x + track.deltaX, y: track.y + track.deltaY,
                                            frame: current, rotation: adjustedCurrent,
                                            cameraHeight: cameraHeight) else {
                continue
            }
            distances.append(simd_dot(first - second, adjustedForward))
        }
        guard distances.count >= 10, let distance = median(distances) else {
            return nil
        }
        return distance / (current.time - previous.time)
    }

    private static func groundOffset(x: Double, y: Double, frame: CameraFrameGeometry,
                                     rotation: simd_quatd, cameraHeight: Double) -> SIMD3<Double>? {
        guard frame.focalX.isFinite, frame.focalY.isFinite, frame.focalX > 0, frame.focalY > 0 else {
            return nil
        }
        let rayDevice = simd_normalize(SIMD3<Double>((x - frame.principalX) / frame.focalX,
                                                     -(y - frame.principalY) / frame.focalY,
                                                     -1))
        let rayReference = rotation.act(rayDevice)
        guard rayReference.z < -0.06 else {
            return nil
        }
        let scale = -cameraHeight / rayReference.z
        guard scale >= 1.5, scale <= 60 else {
            return nil
        }
        return rayReference * scale
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func rejected(time: Double, previous: Double?, region: [Double], height: Double,
                                 current: CameraFrameGeometry, candidates: Int, valid: Int = 0,
                                 texture: Double = 0, speed: Double? = nil, uncertainty: Double? = nil,
                                 quality: Double = 0, reason: String) -> VisualSpeedDiagnostic {
        return VisualSpeedDiagnostic(time: time, previousTime: previous, region: region,
                                     cameraHeightMetres: height,
                                     focalPixels: [current.focalX, current.focalY],
                                     candidateCount: candidates, inlierCount: valid,
                                     medianTexture: texture, visualSpeed: speed,
                                     uncertainty: uncertainty, quality: quality,
                                     accepted: false, reason: reason,
                                     attitudeDisagreementDegrees: current.pose.attitudeDisagreementRadians.map { value in
                                         return value * 180 / .pi
                                     })
    }
}
