# Instructions for coding agents

These instructions are for AI coding agents (Claude Code, Codex, Cursor, Copilot and similar) working in a clone or fork of GPSLess. Read them before changing anything. Humans may find them a useful map too.

## What this is

An iPhone app that tracks a car along a chosen route without GPS. Speed comes from the road-bump echo between the front and rear axles (`VehicleSpeedObserver`); position comes from a road-constrained particle filter (`TrackingEngine`) corrected by matching measured turns against the route (`RouteEvidenceMatcher`). Maps, routing and search are offline. See docs/TECHNICAL.md for the full design and its measured limits.

## Layout

| Path | Contents |
| --- | --- |
| `Core/` | Swift package `GPSLessCore`: engine, road graph, routing (`SelectedRoute`, `RouteAlternatives`), search (`PlaceSearch`), sensor processing, recording format and replay. No UIKit/SwiftUI. |
| `GPSLess/` | iOS app (SwiftUI, MapLibre for the offline map, MapKit for satellite and Apple Maps search). `Shared/NavigationStore.swift` owns app state; `Shared/MotionTrackingService.swift` runs sensors and the engine on a background queue. |
| `GPSLess/OfflineData/` | Generated OpenStreetMap-derived data (ODbL). Never hand-edit; regenerate with `tools/`. |
| `Tests/`, `AppTests/`, `UITests/` | Core tests (`swift test`), app service tests and UI tests (Xcode). |
| `tools/` | Map builders (Python + pyosmium), `replay_raw` (replays a recording through the current engine), `inspect_drive.py`, the Mac simulation lab, `privacy_check.py`. |
| `Config/` | Signing: `Signing.xcconfig` (shared), `Local.xcconfig` (personal, ignored). |

## Commands

- Core tests: `swift test` (about 4 minutes; everything must pass).
- After adding or removing files: `xcodegen generate` (`project.yml` is the source of truth) and commit the regenerated `GPSLess.xcodeproj`.
- Simulator build: `xcodebuild -project GPSLess.xcodeproj -scheme GPSLess -destination 'generic/platform=iOS Simulator' build`.
- App and UI tests: `xcodebuild -project GPSLess.xcodeproj -scheme GPSLess -destination 'platform=iOS Simulator,name=<an available iPhone>' test`.
- Replay a recording with the current engine: `swiftc -O Core/*.swift tools/replay_raw/main.swift -o build/replay-raw`, then `build/replay-raw GPSLess/OfflineData/<region>-graph.json <drive.jsonl.gz> build/out.jsonl 3000`.
- Rebuild map data (needs OSM extracts in `data-source/`): run `tools/build_kyiv.py` or `tools/build_lviv.py`, then `build_search.py <region>` and `build_pois.py <region>` from `tools/`.
- Corridor map for a long journey: `tools/build_corridor.py local-<name> "<Name>" --source … --via LAT,LON[,RADIUS_KM] …` (see docs/TECHNICAL.md). Its `local-*` files are personal and never committed.
- Privacy check before any commit you might publish: `python3 tools/privacy_check.py`.

Device builds need the user's own `Config/Local.xcconfig`; never write a team ID or personal bundle identifier anywhere else.

## Invariants — do not break

- **No GPS in positioning.** GPS reference rows and the background location session are never inputs to `TrackingEngine`, replay, calibration or wheelbase learning.
- **Recordings stay readable.** Recording formats 2–4 must still replay. Add fields as optional; bump `TrackingEngine.version` when estimator behaviour changes, and document the change in docs/TECHNICAL.md and CHANGELOG.md.
- **Deterministic Core.** The engine uses seeded randomness and sensor time only. Tests are deterministic; no wall-clock time, network or UIKit in `Core/`.
- **Offline first.** Everything except satellite imagery and Apple Maps search works without a network.
- **Map identity.** Regenerating map data changes its hash, and recordings only replay against the map they were made with. Do not regenerate data as a side effect of another change.
- **Evidence for engine changes.** Justify estimator changes with replays of real drives or synthetic tests, and state what they do and do not show.

## Privacy rules

This project handles location-derived data. Follow these without exception:

- Never commit drive recordings (`*.jsonl`, `*.jsonl.gz`), exports, device containers, GPS traces, `.xcresult` bundles or screenshots of real locations. They are ignored; keep it that way.
- Never put coordinates, road edge IDs, place names, dates or times taken from someone's own drives into code, tests, defaults, docs or commit messages. They reveal where people live, work and park. Use public landmarks (city centres, main streets, stations) or synthetic graphs.
- Describe field results without places, dates or times ("a 13.5 km mountain-road drive").
- Personal signing stays in `Config/Local.xcconfig`; personal strings for the privacy check go in `Config/private-patterns.txt`. Both are ignored.
- Corridor maps (`GPSLess/OfflineData/local-*`) and the waypoints used to build them reveal someone's journey; never commit them or put the waypoints in code, docs or commit messages.

## Licensing

- Code and docs: PolyForm Noncommercial 1.0.0 (`LICENSE.md`). Forks must stay noncommercial and keep the `Required Notice` line.
- Map data: ODbL (`GPSLess/OfflineData/DATA-LICENSE.md`); keep OpenStreetMap attribution, including in the app's Tracking details screen.
- New third-party code, fonts or data: add them to `THIRD_PARTY_NOTICES.md`, and bundle their licence if distributed.

## Upstream

The upstream repository does not accept pull requests. Keep changes in the fork. Report upstream bugs as issues, without recordings or personal locations.

## Style

Match the surrounding code: explicit `return` in closures and functions, descriptive names, and comments that explain why, with the measured evidence where a constant was tuned. Keep user-visible text short and plain.
