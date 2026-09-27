"""Build the bundled display geometry and directed graph from one OSM snapshot.

Usage: build_kyiv.py [output-directory] [--skip-fonts]
"""
import datetime
import json
import pathlib
import subprocess
import sys

from osm_graph import build, write_json

ROOT = pathlib.Path(__file__).resolve().parents[1]
arguments = [argument for argument in sys.argv[1:] if not argument.startswith("--")]
OUTPUT = pathlib.Path(arguments[0]) if arguments else ROOT / "GPSLess" / "OfflineData"
OUTPUT.mkdir(parents=True, exist_ok=True)
source = json.loads((ROOT / "data-source" / "kyiv-osm.json").read_text())
nodes = {}
ways = []
relations = []
for element in source["elements"]:
    if element["type"] == "node":
        nodes[element["id"]] = [element["lon"], element["lat"]]
    elif element["type"] == "way":
        ways.append(element)
    elif element["type"] == "relation":
        relations.append(element)

result = build(nodes, ways, relations)
edges = result["edges"]
timestamp = source.get("osm3s", {}).get("timestamp_osm_base", datetime.datetime.now(datetime.timezone.utc).isoformat())
write_json(OUTPUT / "kyiv-graph.json", {"generated": timestamp, "bounds": [50.21, 30.23, 50.64, 30.83], "roads": edges, "restrictions": result["restrictions"]})
write_json(OUTPUT / "kyiv-roads.geojson", {"type": "FeatureCollection", "features": result["features"]})
write_json(OUTPUT / "kyiv-areas.geojson", {"type": "FeatureCollection", "features": result["areas"]})
write_json(OUTPUT / "map-manifest.json", {"source": "OpenStreetMap contributors via Overpass", "snapshot": timestamp, "directedEdges": len(edges), "roadWays": len(result["roads"]), "areas": len(result["areas"]), "nodeRestrictions": len(result["restrictions"]), "unsupportedConditionalOrViaWayRestrictions": result["unsupported"], "bounds": [50.21, 30.23, 50.64, 30.83]})
if "--skip-fonts" not in sys.argv:
    font_dir = OUTPUT / "fonts" / "Open Sans Semibold"
    font_dir.mkdir(parents=True, exist_ok=True)
    for lower in [0, 256, 512, 768, 1024, 8192]:
        filename = f"{lower}-{lower + 255}.pbf"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "30", f"https://demotiles.maplibre.org/font/Open%20Sans%20Semibold/{filename}", "-o", str(font_dir / filename)], check=True)
print(json.dumps({"edges": len(edges), "roads": len(result["roads"]), "areas": len(result["areas"]), "restrictions": len(result["restrictions"]), "unsupportedRestrictions": result["unsupported"], "snapshot": timestamp}))
