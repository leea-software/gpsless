#!/usr/bin/env python3
"""Refuse to publish personal data. Run before every commit that will be pushed.

Checks every file Git would publish (tracked, plus untracked files that are
not ignored):

1. No recordings, exports, device data, signing material or private folders.
2. No absolute home paths, Apple team IDs outside the example, or email
   addresses other than the project's own.
3. None of the strings in Config/private-patterns.txt (ignored by Git; one
   case-insensitive regular expression per line: your name, personal emails,
   team ID, device identifiers, home district...).
4. If your own drive recordings are available locally (build/**/Drives), no
   coordinate literal lies within 300 m of where a recorded drive started or
   ended, and no road edge ID used in code lies on a road you actually drove.
   Recordings reveal home and work; a default start road can too.

Standard library only. Exit status 1 when anything is found.
Usage: python3 tools/privacy_check.py [--no-recordings]
"""
import gzip
import json
import math
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_EMAILS = {"leea.software@gmail.com", "noreply@anthropic.com"}
ALLOWED_EMAIL_DOMAINS = ("example.com", "users.noreply.github.com")
FORBIDDEN_PATHS = [
    r"\.jsonl(\.gz)?$", r"(^|/)Drives/", r"(^|/)FieldReferences/", r"\.xcresult(/|$)", r"\.xcappdata(/|$)",
    r"\.mobileprovision$", r"\.p12$", r"\.cer$", r"^Config/Local\.xcconfig$", r"^Config/private-patterns\.txt$",
    r"^build/", r"^\.build/", r"^data-source/", r"^artifacts/", r"(^|/)xcuserdata/",
]
# Generated OpenStreetMap data legitimately contains every district name.
PUBLIC_DATA = re.compile(r"^GPSLess/OfflineData/.*\.(json|geojson|pbf)$")
TEXT_SUFFIXES = {".swift", ".py", ".js", ".html", ".css", ".md", ".txt", ".yml", ".yaml", ".json", ".sh",
                 ".xcconfig", ".plist", ".pbxproj", ".xcscheme", ".resolved", ".geojson", ".example"}
EDGE_CONTEXT = re.compile(r"edge|start", re.IGNORECASE)


def publishable_files():
    output = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                            capture_output=True, text=True, check=True).stdout
    return [line for line in output.splitlines() if line and (ROOT / line).is_file()]


def read_text(path):
    if path.suffix not in TEXT_SUFFIXES and path.name not in {"LICENSE", "Package.resolved", ".gitignore"}:
        return None
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None


def private_patterns():
    path = ROOT / "Config" / "private-patterns.txt"
    if not path.exists():
        return []
    patterns = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            patterns.append(re.compile(line, re.IGNORECASE))
    return patterns


def recorded_places():
    """Start/end points and driven cells (~100 m) of local recordings, cached."""
    recordings = sorted(ROOT.glob("build/**/Drives/*.jsonl.gz"))
    if not recordings:
        return [], set()
    cache_path = ROOT / "build" / "privacy-cache.json"
    key = [[str(path), path.stat().st_mtime] for path in recordings]
    if cache_path.exists():
        cache = json.loads(cache_path.read_text())
        if cache.get("key") == key:
            return [tuple(point) for point in cache["ends"]], {tuple(cell) for cell in cache["cells"]}
    ends, cells = [], set()
    for path in recordings:
        first = last = None
        try:
            with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as handle:
                for line in handle:
                    if '"gps-reference"' not in line:
                        continue
                    reference = json.loads(line)["gpsReference"]
                    if not 0 < reference.get("horizontalAccuracy", 1e9) <= 30:
                        continue
                    point = (reference["coordinate"]["latitude"], reference["coordinate"]["longitude"])
                    first = first or point
                    last = point
                    cells.add((round(point[0], 3), round(point[1], 3)))
        except (OSError, EOFError, ValueError, KeyError):
            continue
        ends += [point for point in (first, last) if point]
    cache_path.write_text(json.dumps({"key": key, "ends": ends, "cells": sorted(cells)}))
    return ends, cells


def metres(a, b):
    return math.hypot((a[0] - b[0]) * 111_000, (a[1] - b[1]) * 111_000 * math.cos(math.radians(a[0])))


def main():
    use_recordings = "--no-recordings" not in sys.argv
    files = publishable_files()
    findings = []
    patterns = private_patterns()
    email = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
    team = re.compile(r"DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})|DevelopmentTeam = ([A-Z0-9]{10})")
    home = re.compile(r"/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+")
    coordinate = re.compile(r"(?<![\d.])(-?\d{1,2}\.\d{3,})\D{1,40}?(-?\d{1,3}\.\d{3,})(?![\d.])")
    number = re.compile(r"(?<![\w.])(\d{2,6})(?![\w.])")
    code_texts = {}
    for name in files:
        for pattern in FORBIDDEN_PATHS:
            if re.search(pattern, name):
                findings.append(f"{name}: personal or generated file must not be published")
        if PUBLIC_DATA.match(name):
            continue
        text = read_text(ROOT / name)
        if text is None:
            continue
        code_texts[name] = text
        for match in home.finditer(text):
            findings.append(f"{name}: absolute home path {match.group(0)}")
        for match in team.finditer(text):
            value = match.group(1) or match.group(2)
            if value != "ABCDE12345":
                findings.append(f"{name}: Apple team ID {value}; keep it in Config/Local.xcconfig")
        for match in email.finditer(text):
            address = match.group(0).lower()
            if address not in ALLOWED_EMAILS and not address.endswith(ALLOWED_EMAIL_DOMAINS):
                findings.append(f"{name}: email address {address}")
        for pattern in patterns:
            for match in pattern.finditer(text):
                findings.append(f"{name}: private pattern /{pattern.pattern}/ matched {match.group(0)!r}")
    # Commit identity of the next commit.
    identity = subprocess.run(["git", "config", "user.email"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if identity and identity.lower() not in ALLOWED_EMAILS:
        findings.append(f"git user.email is {identity}; set it with: git config user.email leea.software@gmail.com")

    if use_recordings:
        ends, cells = recorded_places()
        if ends:
            graphs = {}
            for graph in sorted((ROOT / "GPSLess" / "OfflineData").glob("*-graph.json")):
                roads = json.loads(graph.read_text())["roads"]
                graphs[graph.name] = {road["id"]: road["points"] for road in roads}
            for name, text in code_texts.items():
                for match in coordinate.finditer(text):
                    point = (float(match.group(1)), float(match.group(2)))
                    if not (-90 <= point[0] <= 90 and -180 <= point[1] <= 180):
                        continue
                    distance = min(metres(point, end) for end in ends)
                    if distance < 300:
                        findings.append(f"{name}: coordinate {point} is {distance:.0f} m from a recorded drive's start or end")
                for match in number.finditer(text):
                    context = text[max(0, match.start() - 60):match.end() + 10]
                    if not EDGE_CONTEXT.search(context):
                        continue
                    identifier = int(match.group(1))
                    for graph, roads in graphs.items():
                        points = roads.get(identifier)
                        if not points:
                            continue
                        if any((round(lat, 3), round(lon, 3)) in cells for lon, lat in points):
                            findings.append(f"{name}: road edge {identifier} ({graph}) lies on a road you recorded")
                        else:
                            middle = points[len(points) // 2]
                            distance = min(metres((middle[1], middle[0]), end) for end in ends)
                            if distance < 300:
                                findings.append(f"{name}: road edge {identifier} ({graph}) is {distance:.0f} m from a recorded drive's start or end")
        else:
            print("No local recordings found; location proximity not checked.")

    if findings:
        print(f"Privacy check FAILED: {len(findings)} finding(s)")
        for finding in sorted(set(findings)):
            print("  " + finding)
        return 1
    print(f"Privacy check passed: {len(files)} publishable files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
