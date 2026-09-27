"""Build the Lviv region offline map from openstreetmap.fr oblast extracts.

Lviv Oblast is included completely. Around Slavske the map also keeps unpaved
tracks (many village access roads are tagged that way) and a strip of
Zakarpattia, so routes over the Beskyd pass do not stop at the oblast line.

Download the inputs into data-source/ first:
  https://download.openstreetmap.fr/extracts/europe/ukraine/lviv_oblast-latest.osm.pbf
  https://download.openstreetmap.fr/extracts/europe/ukraine/zakarpattia_oblast-latest.osm.pbf

Usage: build_lviv.py [output-directory]   (needs pyosmium: pip install osmium)
"""
import hashlib
import json
import pathlib
import sys

import osmium

from osm_graph import ROAD_KINDS, build, write_json

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "GPSLess" / "OfflineData"
SOURCES = ROOT / "data-source"
LVIV = SOURCES / "lviv_oblast-latest.osm.pbf"
ZAKARPATTIA = SOURCES / "zakarpattia_oblast-latest.osm.pbf"
# south, west, north, east
FOCUS = (48.60, 23.00, 49.05, 23.80)         # Slavske and nearby villages: tracks included
ZAKARPATTIA_STRIP = (48.55, 22.95, 49.10, 23.85)  # all Zakarpattia land near Slavske, both passes
AREA_TAGS = {("natural", "water"), ("waterway", "riverbank"), ("landuse", "forest"), ("landuse", "grass"),
             ("landuse", "recreation_ground"), ("leisure", "park")}


def inside(box, lat, lon):
    return box[0] <= lat <= box[2] and box[1] <= lon <= box[3]


class Collector(osmium.SimpleHandler):
    def __init__(self, clip=None):
        super().__init__()
        self.clip = clip
        self.nodes = {}
        self.ways = []
        self.relations = []

    def way(self, way):
        tags = dict(way.tags)
        highway = tags.get("highway")
        area = any(tags.get(key) == value for key, value in AREA_TAGS)
        if highway not in ROAD_KINDS and highway != "track" and not area:
            return
        try:
            points = [(node.ref, node.location.lon, node.location.lat) for node in way.nodes]
        except osmium.InvalidLocationError:
            return
        in_focus = any(inside(FOCUS, lat, lon) for _, lon, lat in points)
        if highway == "track" and (not in_focus or tags.get("tracktype") == "grade5"):
            return
        if self.clip and not any(inside(self.clip, lat, lon) for _, lon, lat in points):
            return
        for ref, lon, lat in points:
            self.nodes[ref] = [round(lon, 7), round(lat, 7)]
        self.ways.append({"id": way.id, "nodes": [ref for ref, _, _ in points], "tags": tags, "focus": in_focus})

    def relation(self, relation):
        tags = dict(relation.tags)
        if tags.get("type") != "restriction":
            return
        kinds = {"w": "way", "n": "node", "r": "relation"}
        members = [{"type": kinds[member.type], "ref": member.ref, "role": member.role} for member in relation.members]
        self.relations.append({"id": relation.id, "tags": tags, "members": members})


def snapshot(path):
    header = osmium.io.Reader(str(path), osmium.osm.osm_entity_bits.NOTHING).header()
    return header.get("osmosis_replication_timestamp") or header.get("timestamp") or ""


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


lviv = Collector()
lviv.apply_file(str(LVIV), locations=True)
strip = Collector(clip=ZAKARPATTIA_STRIP)
strip.apply_file(str(ZAKARPATTIA), locations=True)

nodes = dict(strip.nodes)
nodes.update(lviv.nodes)
seen = set()
ways = []
for way in lviv.ways + strip.ways:
    if way["id"] not in seen:
        seen.add(way["id"])
        ways.append(way)
relations = {relation["id"]: relation for relation in strip.relations + lviv.relations}.values()

result = build(nodes, ways, list(relations), include_road=lambda way: way["focus"] and way["tags"].get("highway") == "track")
edges = result["edges"]
latitudes = [point[1] for edge in edges for point in edge["points"]]
longitudes = [point[0] for edge in edges for point in edge["points"]]
bounds = [round(min(latitudes) - 0.005, 3), round(min(longitudes) - 0.005, 3), round(max(latitudes) + 0.005, 3), round(max(longitudes) + 0.005, 3)]
# A conformal plane centred on the region: its scale error stays below 0.01%
# across the oblast, where the Kyiv equirectangular plane would reach 3%.
projection = {"kind": "stereographic", "latitude": round((bounds[0] + bounds[2]) / 2, 4), "longitude": round((bounds[1] + bounds[3]) / 2, 4)}
generated = snapshot(LVIV)
OUTPUT.mkdir(parents=True, exist_ok=True)
write_json(OUTPUT / "lviv-graph.json", {"generated": generated, "bounds": bounds, "region": "lviv", "projection": projection,
                                        "roads": edges, "restrictions": result["restrictions"]})
write_json(OUTPUT / "lviv-roads.geojson", {"type": "FeatureCollection", "features": result["features"]})
write_json(OUTPUT / "lviv-areas.geojson", {"type": "FeatureCollection", "features": result["areas"]})
manifest = {
    "region": "lviv",
    "source": "OpenStreetMap contributors via openstreetmap.fr oblast extracts",
    "snapshot": generated,
    "zakarpattiaSnapshot": snapshot(ZAKARPATTIA),
    "inputs": {LVIV.name: sha256(LVIV), ZAKARPATTIA.name: sha256(ZAKARPATTIA)},
    "focusWithTracks": FOCUS,
    "zakarpattiaStrip": ZAKARPATTIA_STRIP,
    "directedEdges": len(edges),
    "roadWays": len(result["roads"]),
    "trackWays": sum(1 for way in result["roads"] if way["tags"].get("highway") == "track"),
    "areas": len(result["areas"]),
    "nodeRestrictions": len(result["restrictions"]),
    "unsupportedConditionalOrViaWayRestrictions": result["unsupported"],
    "bounds": bounds,
    "projection": projection,
}
write_json(OUTPUT / "lviv-manifest.json", manifest)
print(json.dumps({key: manifest[key] for key in ("snapshot", "directedEdges", "roadWays", "trackWays", "areas", "nodeRestrictions", "bounds", "projection")}))
