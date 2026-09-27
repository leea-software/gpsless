"""Build a local corridor map for a long drive across several oblasts.

The app loads one map at a time, and full oblasts are too large to combine.
A corridor keeps full road detail only near the drive:

1. A rough route is planned on the main roads (tertiary and above) of all
   sources, through the waypoints in order.
2. Every road within `--buffer` km of that route is kept, plus circles around
   waypoints that give a radius (city bypasses, stops) and whole `--box`
   areas (a destination city). Unpaved tracks are kept only inside `--tracks`
   boxes.
3. The usual graph, display, search and label files are written with the
   region id, plus `<id>-region.json`, which makes the app offer the map.

Corridor ids must start with `local-`: such files describe someone's journey,
so Git ignores them and tools/privacy_check.py refuses to publish them.

Usage (run from tools/, needs pyosmium):
  build_corridor.py local-trip "Name" --source ../data-source/a.osm.pbf ... \\
      --via LAT,LON[,RADIUS_KM] --via ... [--buffer 3] [--box S,W,N,E] [--tracks S,W,N,E]
"""
import argparse
import hashlib
import heapq
import json
import math
import pathlib

import osmium

import build_pois
import build_search
from osm_graph import ROAD_KINDS, build, drivable, write_json

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAIN_ROADS = {"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link", "primary_link",
              "secondary_link", "tertiary_link"}
AREA_TAGS = {("natural", "water"), ("waterway", "riverbank"), ("landuse", "forest"), ("landuse", "grass"),
             ("landuse", "recreation_ground"), ("leisure", "park")}


class Plane:
    """Local metres for distance tests across the corridor (0.5% is plenty)."""

    def __init__(self, latitude):
        self.east = 111_320 * math.cos(math.radians(latitude))

    def xy(self, lat, lon):
        return lon * self.east, lat * 110_574


class MainRoads(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.coordinates = {}
        self.neighbours = {}

    def way(self, way):
        tags = way.tags
        if not drivable(tags, MAIN_ROADS):
            return
        try:
            nodes = [(node.ref, node.location.lat, node.location.lon) for node in way.nodes]
        except osmium.InvalidLocationError:
            return
        for ref, lat, lon in nodes:
            self.coordinates[ref] = (lat, lon)
        # Direction does not matter for choosing a corridor.
        for (first, _, _), (second, _, _) in zip(nodes, nodes[1:]):
            self.neighbours.setdefault(first, set()).add(second)
            self.neighbours.setdefault(second, set()).add(first)


def rough_route(roads, waypoints, plane):
    def nearest(lat, lon):
        x, y = plane.xy(lat, lon)
        return min(roads.coordinates, key=lambda ref: (plane.xy(*roads.coordinates[ref])[0] - x) ** 2
                   + (plane.xy(*roads.coordinates[ref])[1] - y) ** 2)

    def length(first, second):
        a = plane.xy(*roads.coordinates[first])
        b = plane.xy(*roads.coordinates[second])
        return math.hypot(a[0] - b[0], a[1] - b[1])

    anchors = [nearest(lat, lon) for lat, lon, _ in waypoints]
    path = [anchors[0]]
    for start, goal in zip(anchors, anchors[1:]):
        costs = {start: 0.0}
        parents = {}
        heap = [(0.0, start)]
        while heap:
            cost, node = heapq.heappop(heap)
            if node == goal:
                break
            if cost > costs[node]:
                continue
            for neighbour in roads.neighbours.get(node, ()):
                candidate = cost + length(node, neighbour)
                if candidate < costs.get(neighbour, math.inf):
                    costs[neighbour] = candidate
                    parents[neighbour] = node
                    heapq.heappush(heap, (candidate, neighbour))
        if goal not in costs:
            raise SystemExit(f"No main-road connection between waypoints near {roads.coordinates[start]} and {roads.coordinates[goal]}")
        leg = [goal]
        while leg[-1] != start:
            leg.append(parents[leg[-1]])
        path += list(reversed(leg))[1:]
        print(json.dumps({"leg_km": round(costs[goal] / 1000, 1)}))
    return [roads.coordinates[ref] for ref in path]


class Corridor:
    def __init__(self, route, buffer_km, waypoints, boxes, plane):
        self.plane = plane
        self.buffer = buffer_km * 1000
        self.cell = self.buffer
        self.cells = {}
        points = []
        for (lat, lon), (next_lat, next_lon) in zip(route, route[1:]):
            a = plane.xy(lat, lon)
            b = plane.xy(next_lat, next_lon)
            steps = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) // 200))
            for step in range(steps):
                t = step / steps
                points.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        points.append(plane.xy(*route[-1]))
        for x, y in points:
            self.cells.setdefault((int(x // self.cell), int(y // self.cell)), []).append((x, y))
        self.circles = [(plane.xy(lat, lon), radius * 1000) for lat, lon, radius in waypoints if radius]
        self.boxes = boxes

    def __call__(self, lat, lon):
        if any(box[0] <= lat <= box[2] and box[1] <= lon <= box[3] for box in self.boxes):
            return True
        x, y = self.plane.xy(lat, lon)
        if any(math.hypot(cx - x, cy - y) <= radius for (cx, cy), radius in self.circles):
            return True
        cell = (int(x // self.cell), int(y // self.cell))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for px, py in self.cells.get((cell[0] + dx, cell[1] + dy), ()):
                    if math.hypot(px - x, py - y) <= self.buffer:
                        return True
        return False


class Collector(osmium.SimpleHandler):
    def __init__(self, inside, tracks):
        super().__init__()
        self.inside = inside
        self.tracks = tracks
        self.nodes = {}
        self.ways = {}
        self.relations = {}

    def way(self, way):
        if way.id in self.ways:
            return
        tags = dict(way.tags)
        highway = tags.get("highway")
        area = any(tags.get(key) == value for key, value in AREA_TAGS)
        if highway not in ROAD_KINDS and highway != "track" and not area:
            return
        try:
            points = [(node.ref, node.location.lon, node.location.lat) for node in way.nodes]
        except osmium.InvalidLocationError:
            return
        in_tracks = any(box[0] <= lat <= box[2] and box[1] <= lon <= box[3] for box in self.tracks for _, lon, lat in points)
        if highway == "track" and (not in_tracks or tags.get("tracktype") == "grade5"):
            return
        if not any(self.inside(lat, lon) for _, lon, lat in points[::max(1, len(points) // 20)] + points[-1:]):
            return
        for ref, lon, lat in points:
            self.nodes[ref] = [round(lon, 7), round(lat, 7)]
        self.ways[way.id] = {"id": way.id, "nodes": [ref for ref, _, _ in points], "tags": tags, "focus": in_tracks}

    def relation(self, relation):
        tags = dict(relation.tags)
        if tags.get("type") != "restriction":
            return
        kinds = {"w": "way", "n": "node", "r": "relation"}
        members = [{"type": kinds[member.type], "ref": member.ref, "role": member.role} for member in relation.members]
        self.relations[relation.id] = {"id": relation.id, "tags": tags, "members": members}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("region")
    parser.add_argument("name")
    parser.add_argument("--source", action="append", required=True, type=pathlib.Path)
    parser.add_argument("--via", action="append", required=True, help="LAT,LON[,RADIUS_KM] in driving order")
    parser.add_argument("--buffer", type=float, default=3)
    parser.add_argument("--box", action="append", default=[], help="S,W,N,E kept in full")
    parser.add_argument("--tracks", action="append", default=[], help="S,W,N,E where unpaved tracks are kept")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "GPSLess" / "OfflineData")
    options = parser.parse_args()
    if not options.region.startswith("local-"):
        raise SystemExit("Corridor ids must start with 'local-' so they stay out of Git")
    waypoints = []
    for value in options.via:
        parts = [float(part) for part in value.split(",")]
        waypoints.append((parts[0], parts[1], parts[2] if len(parts) > 2 else 0))
    boxes = [tuple(float(part) for part in value.split(",")) for value in options.box]
    tracks = [tuple(float(part) for part in value.split(",")) for value in options.tracks]
    plane = Plane(sum(point[0] for point in waypoints) / len(waypoints))

    roads = MainRoads()
    for source in options.source:
        roads.apply_file(str(source), locations=True, idx="flex_mem")
    route = rough_route(roads, waypoints, plane)
    del roads
    corridor = Corridor(route, options.buffer, waypoints, boxes + tracks, plane)

    collector = Collector(corridor, tracks)
    for source in options.source:
        collector.apply_file(str(source), locations=True, idx="flex_mem")
    result = build(collector.nodes, list(collector.ways.values()), list(collector.relations.values()),
                   include_road=lambda way: way["focus"] and way["tags"].get("highway") == "track")
    edges = result["edges"]
    latitudes = [point[1] for edge in edges for point in edge["points"]]
    longitudes = [point[0] for edge in edges for point in edge["points"]]
    bounds = [round(min(latitudes) - 0.005, 3), round(min(longitudes) - 0.005, 3),
              round(max(latitudes) + 0.005, 3), round(max(longitudes) + 0.005, 3)]
    projection = {"kind": "stereographic", "latitude": round((bounds[0] + bounds[2]) / 2, 4),
                  "longitude": round((bounds[1] + bounds[3]) / 2, 4)}
    header = osmium.io.Reader(str(options.source[0]), osmium.osm.osm_entity_bits.NOTHING).header()
    generated = header.get("osmosis_replication_timestamp") or header.get("timestamp") or ""
    output = options.output
    region = options.region
    write_json(output / f"{region}-graph.json", {"generated": generated, "bounds": bounds, "region": region,
                                                 "projection": projection, "roads": edges,
                                                 "restrictions": result["restrictions"]})
    write_json(output / f"{region}-roads.geojson", {"type": "FeatureCollection", "features": result["features"]})
    write_json(output / f"{region}-areas.geojson", {"type": "FeatureCollection", "features": result["areas"]})
    route_km = sum(math.hypot(*(a - b for a, b in zip(plane.xy(*p), plane.xy(*q)))) for p, q in zip(route, route[1:])) / 1000
    manifest = {"region": region, "source": "OpenStreetMap contributors via openstreetmap.fr oblast extracts",
                "snapshot": generated, "inputs": {source.name: sha256(source) for source in options.source},
                "roughRouteKm": round(route_km, 1), "bufferKm": options.buffer, "directedEdges": len(edges),
                "roadWays": len(result["roads"]), "areas": len(result["areas"]),
                "nodeRestrictions": len(result["restrictions"]),
                "unsupportedConditionalOrViaWayRestrictions": result["unsupported"], "bounds": bounds,
                "projection": projection}
    write_json(output / f"{region}-manifest.json", manifest)
    first = waypoints[0]
    write_json(output / f"{region}-region.json", {"id": region, "name": options.name,
                                                  "summary": f"Corridor of about {round(route_km)} km",
                                                  "center": [first[0], first[1]], "zoom": 13,
                                                  "testingStart": [first[0], first[1]]})
    print(json.dumps({key: manifest[key] for key in ("roughRouteKm", "directedEdges", "roadWays", "areas", "nodeRestrictions", "bounds")}))
    build_search.build(region, output, sources=options.source, inside=corridor)
    build_pois.build(region, output, sources=options.source, inside=corridor)


if __name__ == "__main__":
    main()
