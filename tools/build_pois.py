"""Build the offline map's place and point-of-interest labels for a bundled region.

Named settlements, peaks, stations and everyday places (fuel, shops, food,
lodging, health, landmarks, ski lifts...) inside the region's graph bounds,
as GeoJSON points with a short category, a label priority and the zoom from
which each is shown. Points come from OSM nodes and the centres of mapped
buildings and areas; a place mapped both ways is kept once.

Usage: build_pois.py kyiv|lviv [output-directory]   (needs pyosmium)
"""
import json
import math
import pathlib
import sys

import osmium

from build_search import REGIONS, ROOT
from osm_graph import write_json

# Memorial plaques and stones name people on building walls; only standalone
# monuments are landmarks.
MONUMENTAL_MEMORIALS = {"statue", "war_memorial", "monument", "obelisk", "sculpture", "stele", "bust"}
PLACES = {"city": (0, 6), "town": (1, 9), "village": (2, 11), "suburb": (2, 12), "hamlet": (3, 13),
          "neighbourhood": (4, 14), "quarter": (4, 14)}


def category(tags):
    """(category, priority, minimum zoom) for a named OSM object, or None."""
    amenity = tags.get("amenity")
    shop = tags.get("shop")
    tourism = tags.get("tourism")
    historic = tags.get("historic")
    leisure = tags.get("leisure")
    if tags.get("natural") == "peak":
        return "peak", 3, 11
    if tags.get("railway") in ("station", "halt") or tags.get("public_transport") == "station" and tags.get("train") == "yes":
        return "rail", 3, 12
    if tags.get("aerialway") == "station" or tags.get("landuse") == "winter_sports":
        return "ski", 4, 13
    if amenity == "fuel":
        return "fuel", 4, 13
    if amenity == "bus_station":
        return "transit", 5, 14
    if amenity in ("hospital",):
        return "health", 4, 14
    if amenity in ("clinic", "doctors", "dentist"):
        return "health", 6, 16
    if amenity == "pharmacy":
        return "pharmacy", 5, 15
    if amenity in ("restaurant", "cafe", "fast_food", "bar", "pub", "food_court", "ice_cream"):
        return "food", 6, 16
    if shop in ("supermarket", "convenience", "greengrocer", "bakery", "butcher", "deli") or amenity == "marketplace":
        return "grocery", 5, 15
    if shop in ("mall", "department_store"):
        return "shop", 4, 14
    if shop:
        return "shop", 7, 17
    if tourism in ("hotel", "motel", "hostel", "guest_house", "chalet", "apartment", "alpine_hut"):
        return "lodging", 5, 15
    if tourism == "camp_site":
        return "camp", 5, 14
    if tourism in ("museum", "gallery") or amenity in ("theatre", "cinema", "arts_centre"):
        return "culture", 4, 14
    if historic in ("castle", "monument", "fort") or tags.get("memorial") in MONUMENTAL_MEMORIALS and historic == "memorial":
        return "landmark", 4, 14
    if tourism in ("attraction", "viewpoint") or historic in ("ruins", "archaeological_site"):
        return "landmark", 5, 15
    if amenity == "place_of_worship":
        return "worship", 5, 15
    if amenity in ("school", "university", "college", "kindergarten"):
        return "education", 6, 16
    if amenity in ("bank",):
        return "bank", 6, 16
    if amenity in ("post_office",):
        return "post", 6, 16
    if amenity in ("police", "fire_station"):
        return "emergency", 5, 15
    if amenity in ("townhall", "courthouse"):
        return "civic", 5, 15
    if leisure in ("stadium", "sports_centre", "water_park", "ice_rink"):
        return "sport", 5, 15
    if leisure in ("park", "garden") or tags.get("boundary") == "national_park":
        return "park", 5, 14
    return None


class Points(osmium.SimpleHandler):
    def __init__(self, bounds):
        super().__init__()
        self.bounds = bounds
        self.features = []

    def inside(self, lat, lon):
        south, west, north, east = self.bounds
        return south <= lat <= north and west <= lon <= east

    def add(self, tags, lat, lon):
        name = tags.get("name:uk") or tags.get("name")
        if not name or not self.inside(lat, lon):
            return
        place = tags.get("place")
        if place in PLACES:
            rank, zoom = PLACES[place]
            kind = "place"
            if place in ("suburb", "neighbourhood", "quarter"):
                kind = "district"
            self.features.append((name, kind, rank, zoom, lat, lon, place))
            return
        found = category(tags)
        if found is None:
            return
        kind, rank, zoom = found
        label = name
        if kind == "peak" and tags.get("ele"):
            try:
                label = f"{name} · {round(float(tags.get('ele').replace(',', '.')))} m"
            except ValueError:
                pass
        self.features.append((label, kind, rank, zoom, lat, lon, None))

    def node(self, node):
        if node.tags:
            self.add(node.tags, node.location.lat, node.location.lon)

    def way(self, way):
        if "name" not in way.tags and "name:uk" not in way.tags:
            return
        points = [(node.location.lat, node.location.lon) for node in way.nodes if node.location.valid()]
        if not points:
            return
        lat = sum(point[0] for point in points) / len(points)
        lon = sum(point[1] for point in points) / len(points)
        self.add(way.tags, lat, lon)


def build(region, output):
    graph = json.loads((output / f"{region}-graph.json").read_text())
    handler = Points(graph["bounds"])
    for path in REGIONS[region]:
        handler.apply_file(str(path), locations=True, idx="flex_mem")
    lat0 = math.radians((graph["bounds"][0] + graph["bounds"][2]) / 2)
    kept = []
    cells = {}
    # The same shop or hotel is often mapped as a point and as its building.
    for name, kind, rank, zoom, lat, lon, place in sorted(handler.features, key=lambda item: (item[2], item[0])):
        x, y = lon * 111_320 * math.cos(lat0), lat * 110_574
        key = (int(x // 100), int(y // 100))
        duplicate = any(other[0] == name and other[1] == kind and math.hypot(other[2] - x, other[3] - y) < 100
                        for dx in (-1, 0, 1) for dy in (-1, 0, 1) for other in cells.get((key[0] + dx, key[1] + dy), []))
        if duplicate:
            continue
        cells.setdefault(key, []).append((name, kind, x, y))
        properties = {"n": name, "c": kind, "r": rank, "z": zoom}
        if place:
            properties["p"] = place
        kept.append({"type": "Feature", "properties": properties,
                     "geometry": {"type": "Point", "coordinates": [round(lon, 5), round(lat, 5)]}})
    write_json(output / f"{region}-pois.geojson", {"type": "FeatureCollection", "features": kept})
    counts = {}
    for feature in kept:
        counts[feature["properties"]["c"]] = counts.get(feature["properties"]["c"], 0) + 1
    print(json.dumps({"region": region, "features": len(kept), "bytes": (output / f"{region}-pois.geojson").stat().st_size,
                      "categories": dict(sorted(counts.items(), key=lambda item: -item[1]))}, ensure_ascii=False))


if __name__ == "__main__":
    region = sys.argv[1]
    output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "GPSLess" / "OfflineData"
    build(region, output)
