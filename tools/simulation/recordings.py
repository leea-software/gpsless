"""Read-only field-data import and comparisons that never claim field truth."""
import gzip
import hashlib
import json

import numpy as np
from scipy.signal import welch


def read_drive(path):
    opener = open
    if path.suffix == ".gz":
        opener = gzip.open
    result = {"samples": [], "raw": [], "estimates": [], "signals": [], "calibration": None}
    with opener(path, "rt") as stream:
        for line in stream:
            row = json.loads(line)
            kind = row["kind"]
            if kind == "header":
                result["header"] = row["header"]
            elif kind == "sample":
                result["samples"].append(row["sample"])
            elif kind == "raw":
                result["raw"].append(row["raw"])
            elif kind == "estimate":
                result["estimates"].append(row["estimate"])
            elif kind == "road-signal":
                result["signals"].append(row["roadSignal"])
            elif kind == "calibration":
                result["calibration"] = row["calibration"]
    if not result["samples"] or "header" not in result:
        raise ValueError("The recording has no header or driving samples")
    result["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    result["filename"] = path.name
    return result


def fit_short_term_noise(drive):
    calibration = drive["calibration"]
    if not calibration:
        raise ValueError("A calibration interval is required to fit short-term noise")
    raw = [row for row in drive["raw"] if calibration["start"] <= row["time"] <= calibration["end"]]
    if len(raw) < 100:
        raise ValueError("Too few stationary raw samples to fit short-term noise")
    accel = np.asarray([row["acceleration"] for row in raw]) * 9.80665
    gyro = np.asarray([row["rotation"] for row in raw])
    accel_sigma = np.std(np.diff(accel, axis=0), axis=0) / np.sqrt(2)
    gyro_sigma = np.std(np.diff(gyro, axis=0), axis=0) / np.sqrt(2)
    fitted = {"accelSigma": accel_sigma.tolist(), "gyroSigma": gyro_sigma.tolist(),
              "mountPitchDegrees": float(np.degrees(calibration["pitch"])),
              "mountRollDegrees": float(np.degrees(calibration["roll"])),
              "fitRecordingSHA256": drive["sha256"], "fitSamples": len(raw),
              "fitDurationSeconds": calibration["end"] - calibration["start"],
              "basis": "Short-term noise and mounting angles from stationary Core Motion data. There is insufficient driving data to fit vibration; vibration, long-term drift and gravity errors remain assumptions."}
    origin = drive["samples"][0]["time"]
    driving = [row for row in drive["raw"] if origin + 5 <= row["time"] <= origin + 160]
    if len(driving) < 200:
        return fitted
    times = np.array([row["time"] for row in driving])
    values = np.array([row["acceleration"] for row in driving]) * 9.80665
    uniform_time = np.arange(times[0], times[-1], 0.01)
    uniform = np.column_stack([np.interp(uniform_time, times, values[:, axis]) for axis in range(3)])
    frequency, density = welch(uniform, fs=100, nperseg=min(1024, len(uniform)), axis=0)
    # Estimate vibration separately from manoeuvres. Remove the fitted white
    # noise floor and frequencies below 2 Hz; this is an effective output model
    # of the car + phone + Core Motion chain, not a raw chip specification.
    density = np.maximum(0, density - 2 * accel_sigma ** 2 / 100)
    density *= np.clip((frequency - 2) / 1.5, 0, 1)[:, None]
    density[frequency > 45] = 0
    fitted.update({
            "vibration": 0,
            "vibrationPSD": {"frequencyHz": frequency.tolist(), "density": density.tolist(),
                             "units": "(m/s²)²/Hz, device axes", "bandHz": [2, 45]},
            "basis": "Short-term noise and mounting angles from stationary Core Motion data; 2–45 Hz effective vibration spectrum from the first 160 driving seconds, with the fitted white-noise floor removed. Includes car and fusion effects. Long-term drift and gravity errors remain assumptions."})
    return fitted


def reconstruct_route(graph, drive, until=160):
    route = [drive["header"]["initialPosition"]["edge"]]
    origin = drive["samples"][0]["time"]
    notes = []
    for estimate in drive["estimates"]:
        if estimate["time"] - origin > until:
            break
        edge = estimate["position"]["edge"]
        if edge in route:
            continue
        try:
            route.extend(graph.connect(route[-1], edge, maximum=600))
        except ValueError:
            notes.append(f"Skipped disconnected/transient recorded edge {edge}")
    if len(route) < 2:
        raise ValueError("Could not reconstruct a connected route from the recording")
    # Keep geometry beyond the final observation to avoid endpoint derivatives.
    for _ in range(3):
        successors = graph.successors(route[-1])
        if not successors:
            break
        route.append(max(successors, key=lambda edge: graph.lengths[edge]))
    return route, sorted(set(notes))


CHANNELS = [("forwardAcceleration", "Forward acceleration", "m/s²"),
            ("lateralAcceleration", "Lateral acceleration", "m/s²"),
            ("verticalAcceleration", "Vertical acceleration", "m/s²"),
            ("yawRate", "Yaw rate", "rad/s"), ("pitch", "Mount pitch", "rad"),
            ("roll", "Mount roll", "rad")]


def compare_signals(real_samples, simulated_rows, reconstruction, end=160):
    origin = real_samples[0]["time"]
    real = [row for row in real_samples if row["time"] - origin <= end]
    sim = [row["sample"] for row in simulated_rows]
    metrics = []
    for key, label, units in CHANNELS:
        a = np.array([row[key] for row in real])
        b = np.array([row[key] for row in sim])
        metrics.append({"channel": key, "label": label, "units": units,
                        "recordedRMS": float(np.sqrt(np.mean(a ** 2))),
                        "simulatedRMS": float(np.sqrt(np.mean(b ** 2))),
                        "recordedStd": float(a.std()), "simulatedStd": float(b.std()),
                        "recordedP95Absolute": float(np.percentile(np.abs(a), 95)),
                        "simulatedP95Absolute": float(np.percentile(np.abs(b), 95))})
    series = []
    alignment = np.asarray(reconstruction["timeAlignment"])
    for row in real:
        aligned_time = float(np.interp(row["time"] - origin, alignment[:, 1], alignment[:, 0]))
        series.append([aligned_time] + [row[key] for key, _, _ in CHANNELS])
    return {"metrics": metrics, "recordedSeries": series,
            "columns": ["time"] + [key for key, _, _ in CHANNELS],
            "endSeconds": end,
            "interpretation": "Recorded signals are time-aligned by reconstructed distance; the simulated drive is retimed for plausible cornering and acceleration. This is a shape/statistics comparison, not exact field timing or positioning accuracy. The fit and comparison use the same drive."}
