"""Physical phone motion + pinned ACEINNA errors + approximate fused output."""
import gzip
import json
import math

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.spatial.transform import Rotation
from scipy.signal import lfilter
from gnss_ins_sim.pathgen import pathgen

G = 9.80665
ACEINNA_COMMIT = "966ff271bf21d08fbd0e31d1eb47fa5f3acef8d3"


def sensor_profile(name, fitted=None):
    if name == "field-inspired" and not fitted:
        raise ValueError("Import a recording with 'prepare' before selecting the field-inspired profile")
    profile = {"name": name, "accelSigma": [0.035] * 3, "gyroSigma": [0.003] * 3,
               "accelDrift": 0.012, "gyroDrift": 0.0004, "correlationSeconds": 80,
               "vibration": 0.06, "gravityTiltDegrees": 0.06, "scaleError": 0.0003,
               "mountPitchDegrees": 34, "mountRollDegrees": 0, "mountYawDegrees": 0, "roadHeightMetres": 0.004,
               "timestampJitterSeconds": 0.0005, "dropProbability": 0,
               "basis": "Assumed phone-like parameters; not a measured iPhone calibration"}
    if name == "ideal":
        for key in ("accelDrift", "gyroDrift", "vibration", "gravityTiltDegrees", "scaleError", "roadHeightMetres", "timestampJitterSeconds"):
            profile[key] = 0
        profile["accelSigma"] = [0] * 3
        profile["gyroSigma"] = [0] * 3
        profile["basis"] = "Ideal sensor diagnostic control; synthetic vehicle dynamics retained"
    elif name == "field-inspired" and fitted:
        profile.update(fitted)
        profile["name"] = name
    elif name == "stress":
        profile.update({"accelDrift": 0.04, "gyroDrift": 0.0015,
                        "vibration": 0.16, "gravityTiltDegrees": 0.25,
                        "mountYawDegrees": 4, "roadHeightMetres": 0.012,
                        "dropProbability": 0.015, "timestampJitterSeconds": 0.0015})
    elif name not in ("nominal", "field-inspired"):
        raise ValueError("Unknown sensor profile")
    return profile


def spectrum_vibration(spectrum, count, rng):
    """Gaussian spectral synthesis without the upstream PSD helper's 16384-
    sample repetition limit. Input is a one-sided density in physical units.
    """
    frequencies = np.fft.rfftfreq(count, 0.01)
    density = np.asarray(spectrum["density"])
    interpolated = np.column_stack([np.interp(frequencies, spectrum["frequencyHz"], density[:, axis]) for axis in range(3)])
    white = np.fft.rfft(rng.normal(size=(count, 3)), axis=0)
    return np.fft.irfft(white * np.sqrt(interpolated * 50), n=count, axis=0)


def simulate(route, clock, progress, profile, seed, output):
    dt = 0.01
    n = len(clock)
    xy = route.point(progress)
    velocity = np.gradient(xy, dt, axis=0)
    speed = np.linalg.norm(velocity, axis=1)
    heading = np.interp(progress, route.s, route.heading)
    # A low-order sprung-body approximation. Height profiles are deliberately
    # synthetic; Kyiv's centre-line graph has no surveyed surface measurements.
    height = profile["roadHeightMetres"] * (np.sin(progress / 2.7) + 0.25 * np.sin(progress / 0.83))
    height = gaussian_filter1d(height, 8, mode="nearest")
    center = np.column_stack([xy, height])
    acceleration = np.gradient(np.gradient(center, dt, axis=0), dt, axis=0)
    forward = np.column_stack([np.sin(heading), np.cos(heading), np.zeros(n)])
    right = np.column_stack([np.cos(heading), -np.sin(heading), np.zeros(n)])
    down = np.tile([0, 0, -1], (n, 1))
    longitudinal = np.einsum("ij,ij->i", acceleration, forward)
    lateral = np.einsum("ij,ij->i", acceleration, right)
    response = 1 - math.exp(-dt / 0.35)
    pitch = lfilter([response], [1, -(1 - response)], -0.008 * longitudinal)
    roll = lfilter([response], [1, -(1 - response)], 0.012 * lateral)
    body = np.stack([forward, right, down], axis=2)
    suspension = Rotation.from_euler("xyz", np.column_stack([roll, pitch, np.zeros(n)])).as_matrix()
    body = body @ suspension
    tilt = math.radians(profile["mountPitchDegrees"])
    mount = np.array([[0, math.sin(tilt), -math.cos(tilt)],
                      [1, 0, 0], [0, -math.cos(tilt), -math.sin(tilt)]])
    mount = Rotation.from_euler("z", profile["mountYawDegrees"], degrees=True).as_matrix() @ mount
    mount = mount @ Rotation.from_euler("z", profile["mountRollDegrees"], degrees=True).as_matrix()
    device = body @ mount
    # Dashboard position relative to car's rotation centre. Its rotational
    # acceleration is obtained by differentiating this actual mounted position.
    phone = center + np.einsum("nij,j->ni", body, [0.8, 0.25, -0.45])
    phone_acceleration = np.gradient(np.gradient(phone, dt, axis=0), dt, axis=0)
    gravity_world = np.array([0, 0, -G])
    specific_force = np.einsum("nji,nj->ni", device, phone_acceleration - gravity_world)
    increments = Rotation.from_matrix(np.transpose(device[:-1], (0, 2, 1)) @ device[1:]).as_rotvec() / dt
    gyro_truth = np.vstack([increments[0], (increments[:-1] + increments[1:]) / 2, increments[-1]])

    # ACEINNA uses NumPy's legacy RNG. Isolate and restore it, and seed every run.
    saved_rng = np.random.get_state()
    np.random.seed(seed)
    try:
        accel_error = {"b": np.array([0.012, -0.008, 0.015]),
                       "b_drift": np.full(3, profile["accelDrift"]),
                       "b_corr": np.full(3, profile["correlationSeconds"]),
                       "vrw": np.asarray(profile["accelSigma"]) / 10}
        gyro_error = {"b": np.array([0.0002, -0.0001, 0.00015]),
                      "b_drift": np.full(3, profile["gyroDrift"]),
                      "b_corr": np.full(3, profile["correlationSeconds"]),
                      "arw": np.asarray(profile["gyroSigma"]) / 10}
        if profile["name"] == "ideal":
            accel_error["b"] *= 0
            gyro_error["b"] *= 0
        measured_accel = pathgen.acc_gen(100, specific_force, accel_error)
        measured_gyro = pathgen.gyro_gen(100, gyro_truth, gyro_error)
    finally:
        np.random.set_state(saved_rng)
    rng = np.random.default_rng(seed + 23)
    measured_accel *= 1 + profile["scaleError"]
    vibration = profile["vibration"] * (0.3 + np.minimum(speed / 8, 1))
    measured_accel += vibration[:, None] * np.sin(clock[:, None] * [2 * np.pi * 13, 2 * np.pi * 19, 2 * np.pi * 27] + rng.uniform(0, 6, 3))
    if profile.get("vibrationPSD"):
        coloured_vibration = spectrum_vibration(profile["vibrationPSD"], n, rng)
        moving_gain = np.clip(speed / 3, 0, 1)
        measured_accel += coloured_vibration * moving_gain[:, None]
    # Explicit surrogate of Core Motion gravity separation: exact pose + slowly
    # varying tilt error. This must not be mistaken for Apple's private fusion.
    tilt_noise = gaussian_filter1d(rng.normal(size=(n, 3)), 60, axis=0, mode="nearest")
    tilt_noise /= np.maximum(1e-9, tilt_noise.std(axis=0))
    tilt_noise *= math.radians(profile["gravityTiltDegrees"])
    fused_device = device @ Rotation.from_rotvec(tilt_noise).as_matrix()
    gravity = np.einsum("nji,j->ni", fused_device, gravity_world) / G
    # Follow the app's empirically established negative-g acceleration convention.
    user_acceleration = -measured_accel / G - gravity
    quaternion = Rotation.from_matrix(fused_device).as_quat()
    jitter = rng.normal(0, profile["timestampJitterSeconds"], n)
    timestamps = np.maximum.accumulate(clock + np.clip(jitter, -0.003, 0.003))
    keep = rng.uniform(size=n) >= profile["dropProbability"]
    keep[clock <= 0] = True
    with gzip.open(output, "wt", compresslevel=6) as stream:
        for i in range(n):
            if not keep[i]:
                continue
            raw = {"time": float(timestamps[i]), "acceleration": user_acceleration[i].tolist(),
                   "gravity": gravity[i].tolist(), "rotation": measured_gyro[i].tolist(),
                   "quaternion": quaternion[i].tolist()}
            stream.write(json.dumps({"kind": "raw", "raw": raw}, separators=(",", ":")) + "\n")
    return {"time": clock, "xy": xy, "height": height, "heading": heading,
            "speed": speed, "roll": roll, "pitch": pitch, "progress": progress,
            "deviceAcceleration": user_acceleration, "deviceGyro": measured_gyro,
            "specificForce": measured_accel, "gravity": gravity,
            "truthAcceleration": longitudinal, "truthYaw": np.gradient(heading, dt),
            "sampleCount": int(keep.sum())}
