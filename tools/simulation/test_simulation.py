"""Discriminating checks for sensor physics, reproducibility and truth isolation."""
import gzip
import json
from pathlib import Path
import tempfile
import unittest
import subprocess

import numpy as np

from sensors import G, sensor_profile, simulate, spectrum_vibration
from world import KyivGraph, Route, autonomous_motion, EAST_SCALE
from sim import build_engine, engine_replay, frame_rows, source_hash, ROOT, HERE
from recordings import read_drive


def coordinate(x, y):
    return [30.52 + x / EAST_SCALE, 50.45 + y / 111320]


class SimulationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        roads = []
        for index in range(8):
            roads.append({"id": index, "way": 100, "from": index, "to": index + 1,
                          "name": "Straight", "kind": "residential",
                          "points": [coordinate(0, index * 100), coordinate(0, (index + 1) * 100)]})
        self.graph_path = self.directory / "graph.json"
        self.graph_path.write_text(json.dumps({"generated": "test", "bounds": [50.21, 30.23, 50.64, 30.83], "roads": roads, "restrictions": []}))
        self.graph = KyivGraph(self.graph_path)
        self.route = Route(self.graph, list(range(8)), 20)

    def tearDown(self):
        self.temporary.cleanup()

    def test_aceinna_noise_is_seeded_and_has_expected_scale(self):
        clock = np.arange(-4.01, 15, 0.01)
        progress = np.zeros_like(clock)
        profile = sensor_profile("nominal")
        profile["vibration"] = 0
        profile["gravityTiltDegrees"] = 0
        profile["accelDrift"] = 0
        profile["gyroDrift"] = 0
        first = simulate(self.route, clock, progress, profile, 56, self.directory / "a.gz")
        second = simulate(self.route, clock, progress, profile, 56, self.directory / "b.gz")
        np.testing.assert_array_equal(first["specificForce"], second["specificForce"])
        np.testing.assert_allclose(np.std(first["specificForce"], axis=0), profile["accelSigma"], rtol=0.12)
        np.testing.assert_allclose(np.std(first["deviceGyro"], axis=0), profile["gyroSigma"], rtol=0.12)

    def test_vibration_spectrum_has_correct_energy_without_repeated_blocks(self):
        frequency = np.linspace(0, 50, 501)
        density = np.zeros((501, 3))
        density[(frequency >= 5) & (frequency <= 15)] = 0.02
        spectrum = {"frequencyHz": frequency, "density": density}
        data = spectrum_vibration(spectrum, 40000, np.random.default_rng(8))
        np.testing.assert_allclose(np.var(data, axis=0), 0.2, rtol=0.12)
        self.assertFalse(np.array_equal(data[:10000], data[16384:26384]))

    def test_stationary_gravity_and_forward_acceleration_convention(self):
        clock = np.arange(-4.01, 15, 0.01)
        progress = np.maximum(clock, 0) ** 2 / 2
        result = simulate(self.route, clock, progress, sensor_profile("ideal"), 8, self.directory / "raw.gz")
        np.testing.assert_allclose(np.linalg.norm(result["gravity"], axis=1), 1, atol=1e-10)
        stationary = clock < -0.1
        self.assertLess(float(np.max(abs(result["deviceAcceleration"][stationary]))), 1e-7)
        # Project with the same gravity/mount definition as the Swift converter.
        up = -result["gravity"]
        screen = np.tile([0, 0, -1], (len(clock), 1))
        forward = screen - up * np.sum(screen * up, axis=1)[:, None]
        forward /= np.linalg.norm(forward, axis=1)[:, None]
        projected = np.sum(-G * result["deviceAcceleration"] * forward, axis=1)
        self.assertAlmostEqual(float(np.median(projected[(clock > 4) & (clock < 10)])), 1, places=3)

    def test_autonomous_motion_starts_stopped_and_respects_acceleration(self):
        clock, distance = autonomous_motion(self.route, 40, 9)
        self.assertTrue(np.all(np.diff(distance) >= -1e-8))
        self.assertTrue(np.all(distance[clock < 2.9] == 0))
        speed = np.gradient(distance, 0.01)
        acceleration = np.gradient(speed, 0.01)
        self.assertLess(float(np.max(speed)), 40 / 3.6 + 0.2)
        self.assertLess(float(np.max(abs(acceleration))), 2)
        self.assertLess(float(speed[-1]), 0.01)

    def test_legal_route_excludes_mandatory_conflict(self):
        self.graph.restrictions[1] = [{"via": 1, "from": 100, "to": 500, "only": True}]
        self.assertEqual(self.graph.successors(0), [])
        with self.assertRaises(ValueError):
            self.graph.random_route(0, 500, 9)

    def test_frozen_estimate_error_keeps_growing(self):
        sample = {"time": 0, "forwardAcceleration": 0, "yawRate": 0}
        estimate = {"coordinate": {"latitude": 50.45, "longitude": 30.52}, "speed": 0,
                    "heading": 0, "uncertainty": 8, "roadProbability": 1,
                    "position": {"edge": 0}, "status": "lost", "anchorCount": 0,
                    "failure": {"reason": "sensor_gap"}}
        rows = [{"time": 0, "sample": sample, "estimate": estimate, "signals": []},
                {"time": 1, "sample": {**sample, "time": 1}, "signals": []}]
        truth = {"time": [0, 1], "xy": np.array([[0, 0], [0, 10]]),
                 "speed": [10, 10], "heading": [0, 0], "height": [0, 0], "pitch": [0, 0], "roll": [0, 0], "progress": [0, 10]}
        frames, _ = frame_rows(rows, truth)
        self.assertEqual(frames[-1]["error"], 10)
        self.assertIsNotNone(frames[-1]["failure"])

    def test_recording_parser_excludes_calibration_payload_from_motion(self):
        path = self.directory / "recording.jsonl"
        entries = [{"kind": "header", "header": {}},
                   {"kind": "calibration-restarted", "sample": {"time": 5}},
                   {"kind": "sample", "sample": {"time": 6}}]
        path.write_text("\n".join(json.dumps(row) for row in entries))
        self.assertEqual(read_drive(path)["samples"], [{"time": 6}])

    def test_swift_bridge_projects_sensors_reproducibly_and_rejects_map_mismatch(self):
        binary, _ = build_engine()
        clock = np.arange(-4.01, 12, 0.01)
        progress = 0.25 * np.maximum(clock, 0) ** 2
        raw = self.directory / "raw.jsonl.gz"
        simulate(self.route, clock, progress, sensor_profile("ideal"), 9, raw)
        config = {"mode": "raw", "mapSnapshot": "test", "initialPosition": {"edge": 0, "distance": 20},
                  "initialUncertainty": 8, "seed": 7829, "route": list(range(8))}
        config_path = self.directory / "config.json"
        config_path.write_text(json.dumps(config))
        outputs = []
        for index in range(2):
            output = self.directory / f"output-{index}.jsonl"
            subprocess.run([str(binary), str(self.graph_path), str(config_path), str(raw), str(output)], check=True, capture_output=True, timeout=30)
            outputs.append(output.read_text())
        self.assertEqual(outputs[0], outputs[1])
        rows = [json.loads(line) for line in outputs[0].splitlines()]
        estimates = [row["estimate"] for row in rows if row.get("estimate")]
        self.assertFalse(estimates[-1]["needsReset"])
        self.assertAlmostEqual(estimates[-1]["speed"], 6, delta=0.4)
        self.assertAlmostEqual(estimates[-1]["position"]["distance"], 56, delta=3)
        config["mapSnapshot"] = "wrong-map"
        config_path.write_text(json.dumps(config))
        result = subprocess.run([str(binary), str(self.graph_path), str(config_path), str(raw), str(self.directory / "bad.jsonl")], capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
