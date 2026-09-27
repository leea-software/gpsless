"""Fetch a bounded OSM extract. This is build tooling, never app runtime code."""
import json
import pathlib
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "data-source"
DESTINATION.mkdir(exist_ok=True)
QUERY = """
[out:json][timeout:240][bbox:50.21,30.23,50.64,30.83];
(
  way[highway~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"];
  way[natural=water];
  way[waterway=riverbank];
  way[landuse~"^(forest|grass|recreation_ground)$"];
  way[leisure=park];
  relation[type=restriction];
);
(._;>;);
out body;
"""
request = urllib.request.Request(
    "https://overpass-api.de/api/interpreter",
    data=urllib.parse.urlencode({"data": QUERY}).encode(),
    headers={"User-Agent": "GPSLess-Kyiv-Prototype/0.1 (offline extract build)"},
)
with urllib.request.urlopen(request, timeout=300) as response:
    payload = response.read()
parsed = json.loads(payload)
if "remark" in parsed:
    raise RuntimeError(parsed["remark"])
if len(parsed.get("elements", [])) < 1000:
    raise RuntimeError("Incomplete Kyiv extract")
(DESTINATION / "kyiv-osm.json").write_bytes(payload)
print(json.dumps({"bytes": len(payload), "elements": len(parsed["elements"])}))
