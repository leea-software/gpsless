# Map data licence

The map-derived files in this folder are databases derived from OpenStreetMap:

| Files | Source extract | Snapshot |
| --- | --- | --- |
| `kyiv-graph.json`, `kyiv-roads.geojson`, `kyiv-areas.geojson`, `map-manifest.json` | Overpass API, Kyiv rectangle | 2026-09-09 |
| `kyiv-search.json`, `kyiv-pois.geojson` | openstreetmap.fr `kiev` extract | 2026-09-26 |
| `lviv-graph.json`, `lviv-roads.geojson`, `lviv-areas.geojson`, `lviv-manifest.json`, `lviv-search.json`, `lviv-pois.geojson` | openstreetmap.fr `lviv_oblast` and `zakarpattia_oblast` extracts | 2026-09-25 |

Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

These derived databases are made available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/) (ODbL).
Any rights in individual contents of the database are licensed under the
[Database Contents License 1.0](https://opendatacommons.org/licenses/dbcl/1-0/).
If you publicly use, adapt or redistribute them, you must attribute OpenStreetMap
contributors, keep this licence, and offer any adapted database under the ODbL.

The programs that produce them (`tools/build_kyiv.py`, `tools/build_lviv.py`,
`tools/build_search.py`, `tools/build_pois.py`, `tools/osm_graph.py`) are code
under the project's PolyForm Noncommercial licence; the ODbL does not cover them.

`fonts/` holds Open Sans glyphs (SIL Open Font License 1.1, see
`OPEN-SANS-LICENSE.txt`); `MAPLIBRE-LICENSE.md` is MapLibre Native's licence.
