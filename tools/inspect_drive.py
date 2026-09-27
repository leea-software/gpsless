#!/usr/bin/env python3
"""Inspect exported GPSLess recordings without loading sensor data into memory."""

import argparse
import collections
import gzip
import json
from pathlib import Path


def inspect(path, limit):
    counts = collections.Counter()
    decisions = collections.Counter()
    signals = collections.deque(maxlen=limit)
    route_constraints = collections.deque(maxlen=limit)
    route_constraint_stages = collections.Counter()
    route_evidence = collections.deque(maxlen=limit)
    route_evidence_stages = collections.Counter()
    stop_corrections = collections.deque(maxlen=limit)
    stop_decisions = collections.Counter()
    visual_decisions = collections.Counter()
    visual_observations = collections.deque(maxlen=limit)
    gps_flags = collections.Counter()
    gps_observations = collections.deque(maxlen=limit)
    gps_events = collections.Counter()
    header = None
    footer = None
    first_time = None
    last_time = None
    warning = None
    if path.name.endswith(".gz"):
        opener = gzip.open
    else:
        opener = open
    try:
        with opener(path, "rt", encoding="utf-8") as recording:
            for number, line in enumerate(recording, start=1):
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as error:
                    if not line.endswith("\n"):
                        warning = "Incomplete final row; complete preceding records retained."
                        break
                    raise ValueError(f"Damaged JSON at line {number}: {error}") from error
                kind = row.get("kind", "unknown")
                counts[kind] += 1
                if kind == "header":
                    header = row.get("header")
                if kind == "footer":
                    footer = row
                sample = row.get("sample")
                if kind == "sample" and sample is not None:
                    if first_time is None:
                        first_time = sample["time"]
                    last_time = sample["time"]
                signal = row.get("roadSignal")
                if signal is not None:
                    decisions[signal["stage"]] += 1
                    signals.append(signal)
                route_constraint = row.get("routeConstraint")
                if route_constraint is not None:
                    route_constraint_stages[route_constraint["stage"]] += 1
                    route_constraints.append(route_constraint)
                evidence = row.get("routeEvidence")
                if evidence is not None:
                    route_evidence_stages[evidence["stage"]] += 1
                    route_evidence.append(evidence)
                stop_correction = row.get("stopCorrection")
                if stop_correction is not None:
                    stop_decisions[stop_correction["decision"]] += 1
                    stop_corrections.append(stop_correction)
                visual = row.get("visualSpeed")
                if visual is not None:
                    visual_decisions[visual["reason"]] += 1
                    visual_observations.append(visual)
                gps = row.get("gpsReference")
                if kind == "gps-reference" and gps is not None:
                    gps_flags.update(gps.get("qualityFlags", []))
                    gps_observations.append(gps)
                if kind == "gps-trace-event":
                    gps_events[row.get("event", "unknown")] += 1
                reference = row.get("reference")
                if kind == "field-reference" and reference is not None:
                    print(f"Reference: {reference['observedAt']} · {reference['note']}")
                    print(f"  Position: {reference['coordinate']} · segment: {reference.get('previousRecording', 'unlinked')}")
                    if reference.get("odometerKilometres") is not None:
                        print(f"  Odometer: {reference['odometerKilometres']:.3f} km")
    except (EOFError, gzip.BadGzipFile) as error:
        warning = f"Incomplete or damaged gzip stream; results cover readable rows only: {error}"

    size = path.stat().st_size
    print(f"\n{path.name} · {size / 1_000_000:.2f} MB on disk")
    if header is not None:
        metadata = header.get("metadata", {})
        print(f"  Started: {header['created']} · engine: {metadata.get('engineVersion', 'legacy')} · map: {header['mapSnapshot']}")
        if metadata.get("reprocessedWithEngine") is not None:
            print(f"  Raw reprocessing: engine {metadata['reprocessedWithEngine']} · {metadata.get('reprocessedWithMotion', 'unknown method')}")
        print(f"  Source SHA-256: {metadata.get('sourceSHA256', 'not recorded')}")
    if first_time is not None and last_time is not None:
        duration = last_time - first_time
        print(f"  Processed motion: {duration:.1f} seconds")
        if duration > 0:
            print(f"  Measured file rate: {size / 1_000_000 * 60 / duration:.2f} MB/min (includes calibration and metadata)")
    print(f"  Rows: {dict(counts)}")
    print(f"  Road signals: {dict(decisions)}")
    print(f"  Route constraints: {dict(route_constraint_stages)}")
    print(f"  Route-wide evidence: {dict(route_evidence_stages)}")
    print(f"  Automatic stop corrections: {dict(stop_decisions)}")
    print(f"  Camera decisions: {dict(visual_decisions)}")
    print(f"  GPS reference rows: {counts['gps-reference']} · flags: {dict(gps_flags)} · events: {dict(gps_events)}")
    if footer is not None:
        print(f"  Finished: {footer.get('event', 'unknown')}")
    elif header is not None:
        print("  No footer: recording may have ended unexpectedly.")
    if warning is not None:
        print(f"  Recovery note: {warning}")

    if gps_observations:
        print(f"\nLast {len(gps_observations)} GPS reference observations (never used by the estimator):")
    for gps in gps_observations:
        print(f"  Unix time {gps.get('timestamp')} · inferred uptime {gps.get('time')} · fix age {gps.get('ageSeconds')} s")
        print(f"    Position: {gps.get('coordinate')} · horizontal accuracy: {gps.get('horizontalAccuracy')} m")
        speed = gps.get("speed")
        if speed is not None and speed >= 0:
            print(f"    Reference speed: {speed * 3.6:.2f} km/h · reported speed accuracy: {gps.get('speedAccuracy')} m/s")
        else:
            print("    Reference speed unavailable")
        print(f"    Quality flags: {gps.get('qualityFlags', [])}")

    if stop_corrections:
        print(f"\nLast {len(stop_corrections)} automatic stop corrections:")
    for correction in stop_corrections:
        print(f"  t={correction['time']:.3f}s {correction['decision']} · rewind {correction['rewindMetres']:.2f} m")
        print(f"    Stop evidence source: {correction.get('source', 'inertial')}")
        if correction.get("onsetTime") is not None:
            delay = correction["time"] - correction["onsetTime"]
            print(f"    Supported low-speed interval: {delay:.2f}s · onset {correction['onsetTime']:.3f}s")
        print(f"    Before: {correction['before']} · after: {correction['after']}")

    if visual_observations:
        print(f"\nLast {len(visual_observations)} camera observations:")
    for visual in visual_observations:
        print(f"  t={visual['time']:.3f}s {visual['reason']} · accepted {visual['accepted']}")
        if visual.get("visualSpeed") is not None:
            print(f"    Visual speed: {visual['visualSpeed'] * 3.6:.2f} km/h · quality {visual['quality']:.2f}")
        if visual.get("fusedSpeedBefore") is not None and visual.get("fusedSpeedAfter") is not None:
            print(f"    Velocity effect: {visual['fusedSpeedBefore'] * 3.6:.2f} → {visual['fusedSpeedAfter'] * 3.6:.2f} km/h")

    if route_constraints:
        print(f"\nLast {len(route_constraints)} route constraints:")
    for constraint in route_constraints:
        print(f"  t={constraint['time']:.3f}s {constraint['stage'].upper()} · landmark {constraint['landmarkIndex']} · wait {constraint['waitingSeconds']:.1f}s")
        print(f"    Limit {constraint['allowedRouteOffsetMetres']:.1f} m · affected {constraint['affectedProbability']:.1%} · yaw {constraint['observedTurnDegrees']:.1f}°/{constraint['expectedTurnDegrees']:.1f}°")
        print(f"    Constrained speed {constraint['speedBeforeMetresPerSecond'] * 3.6:.1f} → {constraint['speedAfterMetresPerSecond'] * 3.6:.1f} km/h")

    if route_evidence:
        print(f"\nLast {len(route_evidence)} route-wide evidence events:")
    for evidence in route_evidence:
        print(f"  t={evidence['time']:.3f}s {evidence['stage'].upper()} · observed {evidence['observedTurnDegrees']:.1f}° · confidence {evidence['confidence']:.1%}")
        if evidence.get("matchedFeatureIndex") is not None:
            print(f"    Feature {evidence['matchedFeatureIndex']} at {evidence['matchedRouteOffsetMetres']:.1f} m · route angle {evidence['matchedTurnDegrees']:.1f}° · residual {evidence['angleResidualDegrees']:.1f}°")
            print(f"    Route position {evidence['routeOffsetBeforeMetres']:.1f} → {evidence['routeOffsetAfterMetres']:.1f} m")
            if evidence.get("routeAverageSpeedMetresPerSecond") is not None:
                average = evidence["routeAverageSpeedMetresPerSecond"] * 3.6
                before = evidence["speedBeforeMetresPerSecond"] * 3.6
                after = evidence["speedAfterMetresPerSecond"] * 3.6
                print(f"    Route interval average {average:.1f} km/h · speed {before:.1f} → {after:.1f} km/h")
        print(f"    {evidence['reason']}")

    if signals:
        print(f"\nLast {len(signals)} road-signal events:")
    for signal in signals:
        match = signal.get("roadMatch")
        print(f"  #{signal['signalID']} t={signal['time']:.3f}s {signal['stage'].upper()} · observed {signal['observedTurnDegrees']:.1f}° · road {signal['mappedTurnDegrees']:.1f}° · residual {signal['angleResidualDegrees']:.1f}°")
        print(f"    {signal['reason']}")
        if match is not None:
            result = match["result"]
            before = match.get("previousEstimate")
            print(f"    Road edge {result['position']['edge']} · road-evidence adjustment {match['positionAdjustmentMetres']:.2f} m · confidence mass {result['roadProbability']:.3f}")
            if before is not None:
                print(f"    Uncertainty {before['uncertainty']:.1f} → {result['uncertainty']:.1f} m · anchor count {before['anchorCount']} → {result['anchorCount']}")
            print(f"    Before evidence: {match['predictionBeforeRoadEvidence']} · after: {result['coordinate']}")
            correction = match.get("landmarkCorrection")
            if correction is not None:
                print(f"    Timed junction: {correction['incomingEdge']} → {correction['outgoingEdge']} at {correction['observationTime']:.3f}s")
                print(f"    Applied: position {correction['positionChangeMetres']:+.2f} m · speed {correction['speedChangeMetresPerSecond']:+.3f} m/s · bias {correction['biasChangeMetresPerSecondSquared']:+.5f} m/s²")
                print(f"    Observation innovation {correction['innovationMetres']:+.2f} m · sigma {correction['observationSigmaMetres']:.2f} m")
                if correction.get("calibrationDistanceMetres") is not None:
                    print(f"    Calibration interval: {correction['calibrationDistanceMetres']:.1f} m in {correction['calibrationDurationSeconds']:.2f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", type=Path, nargs="+", help="Exported .jsonl.gz / .jsonl files, or a folder containing them")
    parser.add_argument("--last", type=int, default=20, help="Maximum events of each type displayed per file (default: 20)")
    arguments = parser.parse_args()
    if arguments.last < 1 or arguments.last > 2000:
        parser.error("--last must be between 1 and 2000")
    for path in arguments.paths:
        if path.is_dir():
            files = sorted(set(path.rglob("*.jsonl")) | set(path.rglob("*.jsonl.gz")))
        else:
            files = [path]
        for recording in files:
            inspect(recording, arguments.last)


if __name__ == "__main__":
    main()
