"""Build the offline place and street search index for a bundled region.

Places (cities, towns, villages, hamlets, suburbs, neighbourhoods) come from
OSM extracts; streets come from the region's road graph, clustered so a street
name repeated in many villages yields one entry per village. Every entry also
carries Latin forms (name:en and the Ukrainian national transliteration) so
"Slavske" and "Славсько" both match.

Fuel stations are included too, findable by name or brand.

Usage: build_search.py kyiv|lviv [output-directory]   (needs pyosmium)
"""
import json
import math
import pathlib
import sys

import osmium

from osm_graph import write_json

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "data-source"
REGIONS = {
    "kyiv": [SOURCES / "kiev-latest.osm.pbf"],
    "lviv": [SOURCES / "lviv_oblast-latest.osm.pbf", SOURCES / "zakarpattia_oblast-latest.osm.pbf"],
}
PLACE_KINDS = {"city": 0, "town": 1, "village": 2, "suburb": 3, "hamlet": 4, "neighbourhood": 5, "quarter": 5}
SETTLEMENTS = {"city", "town", "village", "hamlet"}
STREET_RANK = 6
FUEL_RANK = 5
CLUSTER_METRES = 1500

LATIN = {"а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e", "є": "ie", "ж": "zh", "з": "z", "и": "y",
         "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
         "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ь": "", "ю": "iu",
         "я": "ia", "ы": "y", "э": "e", "ё": "io", "ъ": ""}
WORD_INITIAL = {"є": "ye", "ї": "yi", "й": "y", "ю": "yu", "я": "ya"}
APOSTROPHES = "'’ʼ`"


def transliterate(text):
    """Ukrainian national transliteration (Cabinet of Ministers resolution 55, 2010)."""
    result = []
    previous = " "
    lowered = text.lower()
    for index, character in enumerate(lowered):
        if character in APOSTROPHES:
            continue
        initial = not previous.isalpha()
        if character == "г" and previous == "з":
            latin = "gh"
        elif initial and character in WORD_INITIAL:
            latin = WORD_INITIAL[character]
        else:
            latin = LATIN.get(character, character)
        if text[index].isupper() and latin:
            latin = latin[0].upper() + latin[1:]
        result.append(latin)
        previous = character
    return "".join(result)


def metres(lat, lon, lat0):
    return lon * 111_320 * math.cos(math.radians(lat0)), lat * 110_574


class Places(osmium.SimpleHandler):
    def __init__(self, bounds, inside=None):
        super().__init__()
        self.bounds = bounds
        self.inside = inside
        self.places = {}
        self.fuel = {}

    def within(self, lat, lon):
        south, west, north, east = self.bounds
        return south <= lat <= north and west <= lon <= east and (self.inside is None or self.inside(lat, lon))

    def fuel_station(self, identifier, tags, lat, lon):
        # Drivers look fuel stations up by brand ("OKKO", "WOG") as often as by name.
        name = tags.get("name:uk") or tags.get("name") or tags.get("brand")
        if not name or not self.within(lat, lon):
            return
        latin = [value for value in (tags.get("brand:en"), tags.get("name:en"), tags.get("brand"), transliterate(name)) if value]
        self.fuel[identifier] = {"n": name, "l": list(dict.fromkeys(latin)), "k": "fuel", "c": "", "y": round(lat, 5),
                                 "x": round(lon, 5), "r": FUEL_RANK}

    def way(self, way):
        if way.tags.get("amenity") != "fuel":
            return
        points = [(node.location.lat, node.location.lon) for node in way.nodes if node.location.valid()]
        if points:
            self.fuel_station(("w", way.id), way.tags, sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))

    def node(self, node):
        if node.tags.get("amenity") == "fuel":
            self.fuel_station(("n", node.id), node.tags, node.location.lat, node.location.lon)
        kind = node.tags.get("place")
        name = node.tags.get("name:uk") or node.tags.get("name")
        if kind not in PLACE_KINDS or not name:
            return
        lat, lon = node.location.lat, node.location.lon
        if not self.within(lat, lon):
            return
        latin = [value for value in (node.tags.get("name:en"), transliterate(name)) if value]
        self.places[node.id] = {"n": name, "l": list(dict.fromkeys(latin)), "k": kind, "c": "", "y": round(lat, 5),
                                "x": round(lon, 5), "r": PLACE_KINDS[kind]}


def build(region, output, sources=None, inside=None):
    """`sources` defaults to the region's extracts; `inside(lat, lon)` limits
    entries to a corridor."""
    graph = json.loads((output / f"{region}-graph.json").read_text())
    bounds = graph["bounds"]
    places = Places(bounds, inside)
    for path in sources or REGIONS[region]:
        places.apply_file(str(path), locations=True, idx="flex_mem")
    place_list = list(places.places.values())
    lat0 = (bounds[0] + bounds[2]) / 2
    settlements = [place for place in place_list if place["k"] in SETTLEMENTS]
    cell = 5000
    grid = {}
    for place in settlements:
        x, y = metres(place["y"], place["x"], lat0)
        grid.setdefault((int(x // cell), int(y // cell)), []).append((x, y, place))

    suburbs = [(metres(place["y"], place["x"], lat0), place) for place in place_list if place["k"] in ("suburb", "neighbourhood", "quarter")]

    def nearest_settlement(lat, lon):
        x, y = metres(lat, lon, lat0)

        def score(px, py, place):
            # Larger settlements claim streets a little further out.
            return math.hypot(px - x, py - y) - (1500 if place["k"] == "city" else 500 if place["k"] == "town" else 0)
        nearby = [(px, py, place) for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                  for px, py, place in grid.get((int(x // cell) + dx, int(y // cell) + dy), [])]
        if not nearby:
            nearby = [(*metres(place["y"], place["x"], lat0), place) for place in settlements]
        if not nearby:
            return ""
        best = min(nearby, key=lambda item: score(*item))[2]
        if best["k"] != "city" or not suburbs:
            return best["n"]
        # Within a city the district tells repeated street names apart.
        (sx, sy), suburb = min(suburbs, key=lambda item: math.hypot(item[0][0] - x, item[0][1] - y))
        if math.hypot(sx - x, sy - y) <= 4000:
            return f"{best['n']} · {suburb['n']}"
        return best["n"]

    # One representative point per street way (the longest directed edge).
    ways = {}
    for edge in graph["roads"]:
        name = edge["name"].strip()
        if not name:
            continue
        points = edge["points"]
        length = sum(math.hypot(*(a - b for a, b in zip(metres(p[1], p[0], lat0), metres(q[1], q[0], lat0))))
                     for p, q in zip(points, points[1:]))
        if edge["way"] not in ways or length > ways[edge["way"]][2]:
            middle = points[len(points) // 2]
            ways[edge["way"]] = (name, middle, length)
    by_name = {}
    for name, middle, length in ways.values():
        by_name.setdefault(name, []).append((middle, length))

    streets = []
    for name, members in by_name.items():
        coordinates = [metres(point[1], point[0], lat0) for point, _ in members]
        parent = list(range(len(members)))

        def find(index):
            while parent[index] != index:
                parent[index] = parent[parent[index]]
                index = parent[index]
            return index
        cells = {}
        for index, (x, y) in enumerate(coordinates):
            cells.setdefault((int(x // CLUSTER_METRES), int(y // CLUSTER_METRES)), []).append(index)
        for (cx, cy), indices in cells.items():
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for other in cells.get((cx + dx, cy + dy), []):
                        for index in indices:
                            if index < other and math.dist(coordinates[index], coordinates[other]) <= CLUSTER_METRES:
                                parent[find(index)] = find(other)
        clusters = {}
        for index in range(len(members)):
            clusters.setdefault(find(index), []).append(index)
        latin = transliterate(name)
        for indices in clusters.values():
            # The longest way's midpoint represents the street.
            point = max((members[index] for index in indices), key=lambda member: member[1])[0]
            streets.append({"n": name, "l": [latin], "k": "street", "c": nearest_settlement(point[1], point[0]),
                            "y": round(point[1], 5), "x": round(point[0], 5), "r": STREET_RANK})
    for place in place_list:
        if place["k"] not in SETTLEMENTS:
            place["c"] = nearest_settlement(place["y"], place["x"])
    fuel = list(places.fuel.values())
    for station in fuel:
        station["c"] = nearest_settlement(station["y"], station["x"])
    entries = (sorted(place_list, key=lambda entry: (entry["r"], entry["n"])) + sorted(fuel, key=lambda entry: (entry["n"], entry["c"]))
               + sorted(streets, key=lambda entry: (entry["n"], entry["c"])))
    write_json(output / f"{region}-search.json", {"region": region, "snapshot": graph["generated"], "entries": entries})
    print(json.dumps({"region": region, "places": len(place_list), "fuel": len(fuel), "streets": len(streets),
                      "settlements": len(settlements), "bytes": (output / f"{region}-search.json").stat().st_size}))


if __name__ == "__main__":
    region = sys.argv[1]
    output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "GPSLess" / "OfflineData"
    build(region, output)
