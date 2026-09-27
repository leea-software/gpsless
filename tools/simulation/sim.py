#!/usr/bin/env python3
"""GPSLess Simulation Lab. All runs and private recordings remain local."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np

from world import KyivGraph, Route, autonomous_motion, reconstructed_motion, metres
from sensors import ACEINNA_COMMIT, sensor_profile, simulate
from recordings import read_drive, fit_short_term_noise, reconstruct_route, compare_signals

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DATA = ROOT / "build/simulation"
GRAPH_PATH = ROOT / "GPSLess/OfflineData/kyiv-graph.json"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":"), allow_nan=False))
    temporary.replace(path)


def source_hash(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


SIMULATION_SOURCE_HASH = source_hash([path for path in HERE.glob("*.py") if path.name != "test_simulation.py"])


def build_engine():
    sources = list((ROOT / "Core").glob("*.swift")) + [HERE / "engine/main.swift"]
    identity = source_hash(sources)
    binary = DATA / "bin" / f"engine-{identity[:16]}"
    if not binary.exists():
        binary.parent.mkdir(parents=True, exist_ok=True)
        print("Compiling current Swift tracking core…", flush=True)
        subprocess.run(["swiftc", "-O"] + [str(path) for path in sources] + ["-o", str(binary)], check=True, timeout=180)
    return binary, identity


def engine_replay(config, stream, directory):
    binary, identity = build_engine()
    config_path = directory / "engine-input.json"
    write_json(config_path, config)
    output = directory / "engine.jsonl"
    result = subprocess.run([str(binary), str(GRAPH_PATH), str(config_path), str(stream), str(output)],
                            capture_output=True, text=True, timeout=240)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    rows = [json.loads(line) for line in output.read_text().splitlines()]
    with gzip.open(directory / "engine.jsonl.gz", "wt") as compressed:
        compressed.write(output.read_text())
    output.unlink()
    return rows, json.loads(result.stdout), identity


def frame_rows(rows, truth=None):
    frames = []
    events = []
    estimate = None
    diagnostic = None
    last_frame = -1.0
    for row in rows:
        if row.get("estimate"):
            estimate = row["estimate"]
        if row.get("diagnostic"):
            diagnostic = row["diagnostic"]
        for signal in row["signals"]:
            event = dict(signal)
            event["time"] = row["time"]
            events.append(event)
        if not estimate or row["time"] - last_frame < 0.099:
            continue
        last_frame = row["time"]
        xy = metres([[estimate["coordinate"]["longitude"], estimate["coordinate"]["latitude"]]])[0]
        frame = {"time": row["time"], "estimate": [float(xy[0]), float(xy[1])],
                 "speed": estimate["speed"], "heading": estimate["heading"],
                 "uncertainty": estimate["uncertainty"], "probability": estimate["roadProbability"],
                 "edge": estimate["position"]["edge"], "status": estimate["status"],
                 "anchors": estimate["anchorCount"], "failure": estimate.get("failure"),
                 "sample": row["sample"], "adjustment": 0,
                 "hypotheses": [], "error": None, "truth": None}
        if row.get("roadMatch"):
            frame["adjustment"] = row["roadMatch"]["positionAdjustmentMetres"]
        if diagnostic:
            frame["hypotheses"] = diagnostic["roadHypotheses"][:8]
        if truth:
            t = row["sample"]["time"]
            actual = np.array([np.interp(t, truth["time"], truth["xy"][:, axis]) for axis in range(2)])
            frame["truth"] = actual.tolist()
            frame["error"] = float(np.linalg.norm(xy - actual))
            for key in ("speed", "heading", "height", "pitch", "roll", "progress"):
                frame["truth" + key.capitalize()] = float(np.interp(t, truth["time"], truth[key]))
        frames.append(frame)
    return frames, events


def summarize(frames, events):
    errors = [frame["error"] for frame in frames if frame["error"] is not None]
    failure = next((frame for frame in frames if frame["failure"]), None)
    metrics = {"duration": frames[-1]["time"], "frames": len(frames),
               "acceptedTurns": sum(event["stage"] == "accepted" for event in events),
               "detectedTurns": sum(event["stage"] == "detected" for event in events),
               "failure": None, "p95Error": None, "maximumError": None, "finalError": None,
               "withinUncertaintyFraction": None}
    if failure:
        metrics["failure"] = {"time": failure["time"], **failure["failure"]}
    if errors:
        metrics.update({"p95Error": float(np.percentile(errors, 95)),
                        "maximumError": float(max(errors)), "finalError": float(errors[-1]),
                        "withinUncertaintyFraction": float(np.mean([frame["error"] <= frame["uncertainty"] for frame in frames]))})
    return metrics


def publish(directory, run, graph):
    points = [frame["estimate"] for frame in run["frames"]]
    points.extend([frame["truth"] for frame in run["frames"] if frame["truth"] is not None])
    run["roads"] = graph.nearby(np.asarray(points))
    run["schema"] = 1
    run["id"] = directory.name
    run["created"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    run["metrics"] = summarize(run["frames"], run["events"])
    run["provenance"]["mapSnapshot"] = graph.data["generated"]
    run["provenance"]["mapSHA256"] = hashlib.sha256(GRAPH_PATH.read_bytes()).hexdigest()
    run["provenance"]["simulationSourceSHA256"] = SIMULATION_SOURCE_HASH
    write_json(directory / "replay.json", run)
    summary = {key: run[key] for key in ("id", "name", "kind", "created", "metrics", "provenance")}
    write_json(directory / "summary.json", summary)
    return summary


def create_simulation(graph, options, drive=None, fit=None):
    current_hash = source_hash([path for path in HERE.glob("*.py") if path.name != "test_simulation.py"])
    if current_hash != SIMULATION_SOURCE_HASH:
        raise ValueError("Simulator sources changed during this process. Restart the local server before generating new runs.")
    seed = int(options.get("seed", 42))
    start = int(options.get("startEdge", 217386))
    offset = float(options.get("startOffset", 0))
    kind = "synthetic"
    reconstruction = None
    length = float(options.get("length", 1200))
    speed = float(options.get("speedKmh", 40))
    if not 0 <= seed <= 2**31 - 100 or not 0 <= start < len(graph.roads):
        raise ValueError("Invalid seed or starting edge")
    if not 300 <= length <= 5000 or not 10 <= speed <= 90 or not -30 <= offset <= 30:
        raise ValueError("Use 300–5000 m, 10–90 km/h and a starting offset within ±30 m")
    initial_distance = min(graph.lengths[start] * 0.3, 20)
    if drive:
        kind = "reconstruction"
        initial = drive["header"]["initialPosition"]
        start = initial["edge"]
        initial_distance = initial["distance"]
        edges, notes = reconstruct_route(graph, drive)
        route = Route(graph, edges, initial_distance)
        clock, progress, reconstruction = reconstructed_motion(route, drive["samples"], drive["estimates"], drive["signals"])
        reconstruction["notes"] = notes
    else:
        edges = graph.random_route(start, length, seed)
        route = Route(graph, edges, initial_distance)
        clock, progress = autonomous_motion(route, speed, seed)
    if len(clock) > 120000:
        raise ValueError("Drive exceeds the 20-minute simulation limit; shorten the route")
    shifted = initial_distance + offset
    if shifted < 0 or shifted > graph.lengths[start]:
        raise ValueError("Starting offset leaves the initial road edge")
    profile = sensor_profile(options.get("profile", "nominal"), fit)
    directory = DATA / "runs" / (time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    raw_path = directory / "sensors.jsonl.gz"
    print(f"Simulating {len(edges)} Kyiv edges, {len(clock) / 100:.0f} seconds, profile {profile['name']}…", flush=True)
    truth = simulate(route, clock, progress, profile, seed, raw_path)
    config = {"mode": "raw", "mapSnapshot": graph.data["generated"],
              "initialPosition": {"edge": start, "distance": shifted}, "initialUncertainty": 8,
              "seed": 7829, "route": edges}
    rows, engine, identity = engine_replay(config, raw_path, directory)
    frames, events = frame_rows(rows, truth)
    name = f"Kyiv · seed {seed} · {profile['name']}"
    if drive:
        name = "Field route · reconstructed motion"
        if profile.get("vibrationPSD"):
            name = "Field route · vibration fitted"
    run = {"name": name, "kind": kind, "frames": frames, "events": events,
           "route": edges, "reconstruction": reconstruction,
           "comparison": None,
           "provenance": {"engine": engine["engine"], "engineSourceSHA256": identity,
                          "sensorLibrary": "ACEINNA gnss-ins-sim", "sensorCommit": ACEINNA_COMMIT,
                          "seed": seed, "engineSeed": 7829, "profile": profile,
                          "initialPosition": config["initialPosition"], "startOffset": offset,
                          "groundTruth": "Known synthetic trajectory. Vehicle response, road surface and Core Motion fusion are approximations.",
                          "rawSamples": truth["sampleCount"]}}
    if drive:
        run["comparison"] = compare_signals(drive["samples"], rows, reconstruction)
        run["provenance"]["recordingSHA256"] = drive["sha256"]
        run["provenance"]["groundTruth"] = "Synthetic truth only. The route is reconstructed from the first 160 seconds of recorded estimates and retimed for plausible driving; this is not measured field accuracy."
    np.savez_compressed(directory / "truth.npz", **truth)
    write_json(directory / "scenario.json", {"options": options, "profile": profile, "route": edges,
                                            "initialDistance": initial_distance, "reconstruction": reconstruction})
    return publish(directory, run, graph)


def import_recording(graph, path):
    drive = read_drive(path)
    if drive["header"]["mapSnapshot"] != graph.data["generated"]:
        raise ValueError("Recording belongs to another map snapshot")
    recorded_map_hash = drive["header"].get("metadata", {}).get("mapSHA256")
    if recorded_map_hash and recorded_map_hash != hashlib.sha256(GRAPH_PATH.read_bytes()).hexdigest():
        raise ValueError("Recording map hash differs from bundled Kyiv graph")
    directory = DATA / "runs" / ("field-" + drive["sha256"][:12])
    directory.mkdir(parents=True, exist_ok=True)
    config = {"mode": "recorded", "mapSnapshot": graph.data["generated"],
              "initialPosition": drive["header"]["initialPosition"],
              "initialUncertainty": drive["header"]["initialUncertainty"], "seed": drive["header"]["seed"]}
    rows, engine, identity = engine_replay(config, path, directory)
    frames, events = frame_rows(rows)
    # Preserve original live positions/events beside replay of the current core.
    origin = drive["samples"][0]["time"]
    original = []
    for estimate in drive["estimates"]:
        point = metres([[estimate["coordinate"]["longitude"], estimate["coordinate"]["latitude"]]])[0]
        original.append({"time": estimate["time"] - origin, "position": point.tolist(),
                         "speed": estimate["speed"], "heading": estimate["heading"], "anchors": estimate["anchorCount"]})
    recorded_events = []
    for event in drive["signals"]:
        event = dict(event)
        event["time"] -= origin
        recorded_events.append(event)
    created = datetime.fromisoformat(drive["header"]["created"])
    local_date = created.astimezone(ZoneInfo(drive["header"].get("metadata", {}).get("timeZone", "Europe/Kyiv")))
    name = local_date.strftime("Recorded drive · %d %b, %H:%M")
    run = {"name": name, "kind": "recorded", "frames": frames,
           "events": events, "recordedEvents": recorded_events, "original": original,
           "comparison": None, "provenance": {"engine": engine["engine"], "engineSourceSHA256": identity,
           "recordedEngine": drive["header"].get("metadata", {}).get("engineVersion", "unknown"),
           "recordingSHA256": drive["sha256"], "recordingFile": path.name,
           "groundTruth": "No independent field ground truth. Both paths are estimates. Original live engine and current engine replay are separate.",
           "seed": drive["header"]["seed"]}}
    summary = publish(directory, run, graph)
    fit = fit_short_term_noise(drive)
    write_json(DATA / "field-profile.json", fit)
    write_json(DATA / "recording.json", {"path": str(path.resolve()), "sha256": drive["sha256"]})
    return drive, fit, summary


def catalog():
    summaries = []
    for path in sorted((DATA / "runs").glob("*/summary.json"), reverse=True):
        summaries.append(json.loads(path.read_text()))
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--recording", type=Path, required=True, help="an exported drive (.jsonl.gz) to fit the field-inspired profile from")
    run = sub.add_parser("run")
    run.add_argument("--seed", type=int, default=42)
    run.add_argument("--profile", choices=["ideal", "nominal", "field-inspired", "stress"], default="nominal")
    run.add_argument("--length", type=float, default=1200)
    run.add_argument("--speed", type=float, default=40)
    run.add_argument("--start-edge", type=int, default=217386)
    run.add_argument("--start-offset", type=float, default=0)
    batch = sub.add_parser("batch")
    batch.add_argument("--count", type=int, default=6)
    batch.add_argument("--seed", type=int, default=100)
    batch.add_argument("--length", type=float, default=1000)
    serve = sub.add_parser("serve")
    serve.add_argument("--port", type=int, default=8940)
    args = parser.parse_args()
    if args.command == "build":
        print(build_engine()[0])
        return
    if args.command == "serve":
        from server import serve as start_server
        start_server(args.port)
        return
    graph = KyivGraph(GRAPH_PATH)
    fit = None
    if (DATA / "field-profile.json").exists():
        fit = json.loads((DATA / "field-profile.json").read_text())
    if args.command == "prepare":
        drive, fit, field = import_recording(graph, args.recording)
        print(json.dumps(field["metrics"]), flush=True)
        paired = create_simulation(graph, {"seed": 42, "profile": "field-inspired"}, drive, fit)
        print(json.dumps(paired["metrics"]), flush=True)
        for profile in ("ideal", "nominal", "stress"):
            result = create_simulation(graph, {"seed": 42, "profile": profile}, fit=fit)
            print(json.dumps(result["metrics"]), flush=True)
    elif args.command == "run":
        options = {"seed": args.seed, "profile": args.profile, "length": args.length,
                   "speedKmh": args.speed, "startEdge": args.start_edge, "startOffset": args.start_offset}
        print(json.dumps(create_simulation(graph, options, fit=fit)["metrics"]))
    elif args.command == "batch":
        if not 1 <= args.count <= 50:
            raise ValueError("Batch count must be 1–50")
        summaries = []
        for index in range(args.count):
            profile = ["ideal", "nominal", "stress"][index % 3]
            starts = [217386, 244659, 105914, 14702]
            options = {"seed": args.seed + index // 3, "profile": profile, "length": args.length,
                       "startEdge": starts[(index // 3) % len(starts)]}
            try:
                summaries.append(create_simulation(graph, options, fit=fit))
            except Exception as error:
                summaries.append({"options": options, "error": str(error)})
            print(f"Completed {index + 1}/{args.count}", flush=True)
        output = DATA / "batches" / (time.strftime("%Y%m%d-%H%M%S") + ".json")
        write_json(output, summaries)
        print(output)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Simulation failed: {error}", file=sys.stderr)
        sys.exit(1)
