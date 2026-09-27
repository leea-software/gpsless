"""Shared OSM → offline map conversion for every bundled region. Build tooling only."""
import collections
import json

ROAD_KINDS = {"motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street", "service", "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"}
BLOCKED_ACCESS = {"no", "private", "agricultural", "forestry"}


def drivable(tags, road_kinds):
    if tags.get("highway") not in road_kinds:
        return False
    access = tags.get("motorcar", tags.get("motor_vehicle", tags.get("vehicle", tags.get("access", "yes"))))
    return access not in BLOCKED_ACCESS


def build(nodes, ways, relations, road_kinds=ROAD_KINDS, include_road=None):
    """nodes: id -> [lon, lat]; ways/relations: Overpass-style dicts.

    Returns directed graph edges, display road features, display areas,
    supported node restrictions and the count of unsupported restrictions.
    `include_road(way)` may admit extra road ways (for example tracks in a
    focus area); they must still pass the access rules.
    """
    roads = []
    counts = collections.Counter()
    for way in ways:
        tags = way.get("tags", {})
        kinds = road_kinds
        if include_road is not None and include_road(way):
            kinds = road_kinds | {tags.get("highway")}
        if not drivable(tags, kinds):
            continue
        if any(node not in nodes for node in way["nodes"]):
            continue
        roads.append(way)
        counts.update(set(way["nodes"]))

    edges = []
    features = []
    for way in roads:
        tags = way["tags"]
        name = tags.get("name:uk", tags.get("name", ""))
        points = [nodes[node] for node in way["nodes"]]
        features.append({"type": "Feature", "properties": {"name": name, "kind": tags["highway"]}, "geometry": {"type": "LineString", "coordinates": points}})
        one_way = tags.get("oneway", "")
        if one_way == "" and (tags.get("junction") == "roundabout" or tags["highway"] == "motorway"):
            one_way = "yes"
        beginning = 0
        for end in range(1, len(way["nodes"])):
            if counts[way["nodes"][end]] <= 1 and end != len(way["nodes"]) - 1:
                continue
            segment = points[beginning:end + 1]
            first = way["nodes"][beginning]
            last = way["nodes"][end]
            beginning = end
            if len(set(tuple(point) for point in segment)) < 2:
                continue
            directions = []
            if one_way != "-1":
                directions.append((first, last, segment))
            if one_way not in {"yes", "1", "true"}:
                directions.append((last, first, list(reversed(segment))))
            for start_node, end_node, coordinates in directions:
                edges.append({"id": len(edges), "way": way["id"], "from": start_node, "to": end_node, "name": name, "kind": tags["highway"], "points": coordinates})

    road_ids = {way["id"] for way in roads}
    areas = []
    for way in ways:
        tags = way.get("tags", {})
        if tags.get("highway") in road_kinds or way["id"] in road_ids:
            continue
        ids = way["nodes"]
        if len(ids) < 4 or ids[0] != ids[-1] or any(node not in nodes for node in ids):
            continue
        kind = "green"
        if tags.get("natural") == "water" or tags.get("waterway") == "riverbank":
            kind = "water"
        areas.append({"type": "Feature", "properties": {"kind": kind}, "geometry": {"type": "Polygon", "coordinates": [[nodes[node] for node in ids]]}})

    restrictions = []
    unsupported = 0
    for relation in relations:
        tags = relation.get("tags", {})
        restriction = tags.get("restriction:motorcar", tags.get("restriction", ""))
        if not restriction.startswith(("no_", "only_")):
            continue
        if "motorcar" in tags.get("except", "") or "motor_vehicle" in tags.get("except", ""):
            continue
        members = relation.get("members", [])
        from_ways = [member["ref"] for member in members if member["role"] == "from" and member["type"] == "way"]
        to_ways = [member["ref"] for member in members if member["role"] == "to" and member["type"] == "way"]
        via_nodes = [member["ref"] for member in members if member["role"] == "via" and member["type"] == "node"]
        if not any(way in road_ids for way in from_ways):
            continue
        if len(via_nodes) != 1 or any("conditional" in key for key in tags):
            unsupported += 1
            continue
        # Same-way no_u_turn requires direction-specific handling; the runtime already
        # excludes immediate reversal. Do not accidentally prohibit straight travel.
        for first in from_ways:
            for last in to_ways:
                if first == last:
                    continue
                restrictions.append({"via": via_nodes[0], "from": first, "to": last, "only": restriction.startswith("only_")})
    return {"roads": roads, "edges": edges, "features": features, "areas": areas,
            "restrictions": restrictions, "unsupported": unsupported}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
