"""Directed Kyiv routes and a continuous, explicitly synthetic vehicle model."""
import heapq
import json
import math
from collections import defaultdict

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.interpolate import PchipInterpolator, CubicHermiteSpline, CubicSpline

EAST_SCALE = 111320 * math.cos(math.radians(50.45))


def metres(points):
    points = np.asarray(points, dtype=float)
    return (points - [30.52, 50.45]) * [EAST_SCALE, 111320]


class KyivGraph:
    def __init__(self, path):
        self.path = path
        self.data = json.loads(path.read_text())
        self.roads = self.data["roads"]
        self.outgoing = defaultdict(list)
        self.restrictions = defaultdict(list)
        self.lengths = []
        for road in self.roads:
            self.outgoing[road["from"]].append(road["id"])
            points = metres(road["points"])
            self.lengths.append(float(np.linalg.norm(np.diff(points, axis=0), axis=1).sum()))
        for restriction in self.data["restrictions"]:
            self.restrictions[restriction["via"]].append(restriction)

    def successors(self, edge):
        road = self.roads[edge]
        result = []
        for candidate in self.outgoing[road["to"]]:
            other = self.roads[candidate]
            if other["to"] == road["from"] and other["way"] == road["way"]:
                continue
            allowed = True
            for rule in self.restrictions[road["to"]]:
                if rule["from"] != road["way"]:
                    continue
                if rule["only"] and rule["to"] != other["way"]:
                    allowed = False
                if not rule["only"] and rule["to"] == other["way"]:
                    allowed = False
            if allowed:
                result.append(candidate)
        return result

    def connect(self, start, end, maximum=1000):
        queue = [(0.0, start, [])]
        seen = set()
        while queue:
            distance, edge, route = heapq.heappop(queue)
            if edge == end:
                return route
            if edge in seen or distance > maximum:
                continue
            seen.add(edge)
            for candidate in self.successors(edge):
                heapq.heappush(queue, (distance + self.lengths[candidate], candidate, route + [candidate]))
        raise ValueError(f"No legal connection from edge {start} to {end} within {maximum} m")

    def random_route(self, start, length, seed):
        rng = np.random.default_rng(seed)
        for attempt in range(20):
            route = [start]
            distance = self.lengths[start]
            while distance < length and len(route) < 500:
                candidates = self.successors(route[-1])
                candidates = [edge for edge in candidates if edge not in route[-15:]]
                if not candidates:
                    break
                weights = []
                previous = metres(self.roads[route[-1]]["points"])
                direction = previous[-1] - previous[-2]
                for edge in candidates:
                    points = metres(self.roads[edge]["points"])
                    vector = points[1] - points[0]
                    cosine = np.dot(direction, vector) / max(0.001, np.linalg.norm(direction) * np.linalg.norm(vector))
                    weight = 0.4 + (float(cosine) + 1) / 2
                    if self.roads[edge]["kind"] in ("service", "living_street", "track"):
                        weight *= 0.12
                    weights.append(weight)
                edge = int(rng.choice(candidates, p=np.array(weights) / sum(weights)))
                route.append(edge)
                distance += self.lengths[edge]
            if distance >= length:
                return route
        raise ValueError("Could not generate a long enough legal route from this start; choose another seed or start")

    def nearby(self, xy, margin=180):
        low = np.min(xy, axis=0) - margin
        high = np.max(xy, axis=0) + margin
        roads = []
        seen = set()
        for road in self.roads:
            key = (road["way"], min(road["from"], road["to"]), max(road["from"], road["to"]))
            if key in seen:
                continue
            points = metres(road["points"])
            if np.any(points.max(axis=0) < low) or np.any(points.min(axis=0) > high):
                continue
            seen.add(key)
            roads.append({"id": road["id"], "name": road["name"], "kind": road["kind"], "points": points.round(3).tolist()})
        return roads


class Route:
    def __init__(self, graph, edges, start_distance=0):
        self.edges = edges
        self.starts = {}
        points = []
        distance = -start_distance
        for edge in edges:
            self.starts[edge] = distance
            road_points = metres(graph.roads[edge]["points"])
            if points:
                road_points = road_points[1:]
            points.extend(road_points)
            distance += graph.lengths[edge]
        points = np.asarray(points)
        cumulative = np.r_[0, np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))]
        keep = np.r_[True, np.diff(cumulative) > 0.001]
        points = points[keep]
        cumulative = cumulative[keep]
        # Round sharp centre-line vertices spatially. This is a plausible lane
        # trajectory, not surveyed lane geometry or measured road elevation.
        grid = np.arange(0, cumulative[-1], 0.5)
        xy = np.column_stack([np.interp(grid, cumulative, points[:, axis]) for axis in range(2)])
        xy = gaussian_filter1d(xy, 5, axis=0, mode="nearest")
        self.s = grid - start_distance
        self.xy = xy
        self.curve = CubicSpline(self.s, xy)
        self.length = float(self.s[-1])
        derivative = np.gradient(xy, 0.5, axis=0)
        self.heading = np.unwrap(np.arctan2(derivative[:, 0], derivative[:, 1]))
        self.curvature = np.gradient(self.heading, 0.5)

    def point(self, distance):
        return self.curve(distance)

    def position_distance(self, position):
        return self.starts[position["edge"]] + position["distance"]


def autonomous_motion(route, speed_kmh, seed):
    rng = np.random.default_rng(seed)
    distance = np.arange(0, route.length - 8, 0.5)
    curvature = np.interp(distance, route.s, route.curvature)
    cruise = speed_kmh / 3.6
    limit = np.minimum(cruise, np.sqrt(1.8 / np.maximum(0.0001, np.abs(curvature))))
    limit *= 0.93 + 0.07 * np.sin(distance / 90 + rng.uniform(0, 6))
    stop = int(len(limit) * 0.55)
    limit[0] = 0
    limit[-1] = 0
    limit[stop] = 0
    for index in range(1, len(limit)):
        limit[index] = min(limit[index], math.sqrt(limit[index - 1] ** 2 + 2 * 0.8 * 0.5))
    for index in range(len(limit) - 2, -1, -1):
        limit[index] = min(limit[index], math.sqrt(limit[index + 1] ** 2 + 2 * 1.2 * 0.5))
    elapsed = np.r_[3, 3 + np.cumsum(1 / np.maximum(0.01, limit[:-1] + limit[1:]))]
    elapsed[stop + 1:] += 4
    elapsed = np.insert(elapsed, stop + 1, elapsed[stop] + 4)
    distance = np.insert(distance, stop + 1, distance[stop])
    limit = np.insert(limit, stop + 1, 0)
    elapsed = np.r_[-5, 0, elapsed, elapsed[-1] + 3]
    distance = np.r_[0, 0, distance, distance[-1]]
    limit = np.r_[0, 0, limit, 0]
    clock = np.arange(-4.01, elapsed[-1], 0.01)
    progress = CubicHermiteSpline(elapsed, distance, limit)(clock)
    return clock, progress


def reconstructed_motion(route, samples, estimates, signals, end_seconds=160):
    """Fit an illustrative timeline to recorded estimates and observed turns.

    No resulting coordinate or speed is independent field ground truth.
    """
    origin = samples[0]["time"]
    anchors = [(0.0, 0.0)]
    # Recorded estimates can lag and jump: use sparse route-distance anchors,
    # never copy their displayed speed into the simulator as measured truth.
    for row in estimates:
        t = row["time"] - origin
        position = row["position"]
        if t > end_seconds or position["edge"] not in route.starts:
            continue
        distance = route.position_distance(position)
        if t - anchors[-1][0] >= 12 and distance > anchors[-1][1] + 2:
            anchors.append((t, min(distance, route.length - 8)))
    end = min(end_seconds, samples[-1]["time"] - origin)
    if anchors[-1][0] < end:
        anchors.append((end, anchors[-1][1]))
    # Avoid an inferred moving start during the calibration interval.
    anchors = [(-5, 0)] + anchors
    times, distances = np.asarray(anchors).T
    field_clock = np.arange(0, end, 0.01)
    field_progress = PchipInterpolator(times, distances)(field_clock)
    distance_grid = np.arange(0, distances[-1], 0.5)
    field_time = np.interp(distance_grid, field_progress, field_clock)
    inferred_speed = 0.5 / np.maximum(0.01, np.gradient(field_time))
    curvature = np.interp(distance_grid, route.s, route.curvature)
    speed = np.minimum(inferred_speed, np.sqrt(2.2 / np.maximum(0.0001, np.abs(curvature))))
    speed = np.minimum(speed, 20)
    speed[0] = 0
    speed[-1] = 0
    for index in range(1, len(speed)):
        speed[index] = min(speed[index], math.sqrt(speed[index - 1] ** 2 + 2 * 1.2 * 0.5))
    for index in range(len(speed) - 2, -1, -1):
        speed[index] = min(speed[index], math.sqrt(speed[index + 1] ** 2 + 2 * 1.8 * 0.5))
    elapsed = np.r_[0, np.cumsum(1 / np.maximum(0.01, speed[:-1] + speed[1:]))]
    # Corrections in the original estimate can imply impossible speeds through
    # a corner. Retime the reconstructed drive instead of inventing violent IMU
    # impulses. Keep the time mapping for an explicitly labelled comparison.
    clock = np.arange(-4.01, elapsed[-1] + 3, 0.01)
    progress = CubicHermiteSpline(np.r_[-5, elapsed, elapsed[-1] + 3],
                                  np.r_[0, distance_grid, distance_grid[-1]],
                                  np.r_[0, speed, 0])(clock)
    alignment = np.column_stack([elapsed, field_time])[::10].tolist()
    alignment.append([float(elapsed[-1]), float(end)])
    return clock, progress, {"anchors": [list(item) for item in anchors],
                             "method": "Sparse recorded road estimates define an inferred distance timeline. It is retimed to limit cornering to 2.2 m/s², acceleration to 1.2 m/s² and braking to 1.8 m/s². Neither field speed nor position is measured truth.",
                             "alignmentColumns": ["simulatedSeconds", "recordedSeconds"],
                             "timeAlignment": alignment, "excludedAfterSeconds": end}
