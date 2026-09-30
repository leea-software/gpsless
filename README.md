# GPSLess

An iPhone app that follows your car along a route **without GPS** — for places where GPS is jammed or unreliable. It measures speed from road bumps and keeps its position on the road by recognising the turns and bends you drive through on an offline map.

> **Experimental prototype.** Tested on a small number of drives with one car, one phone and one mount. Don't rely on it where a wrong position matters, and don't handle the phone while driving.

**Free for personal, noncommercial use** ([licence](LICENSE.md)). Issues are welcome; pull requests are not accepted — fork it instead ([contributing](CONTRIBUTING.md)).

## Features

- **No-GPS tracking** along a chosen route: speed from the road-bump echo between the front and rear axles and, once learned, the tyres' once-per-revolution shake; position corrected at every turn and bend.
- **Offline maps** of Kyiv and the Lviv region, including unpaved Carpathian tracks, with places, peaks, stations, fuel, shops, food, landmarks and speed cameras labelled.
- **Corridor maps** for long journeys across oblasts, built on your Mac from OpenStreetMap along your route and kept private.
- **Offline search** for villages, towns, districts, streets and fuel stations, in Ukrainian or Latin letters; Apple Maps search when viewing satellite imagery.
- **Google Maps hand-off:** find a place in Google Maps and share it to GPSLess, or paste its link or coordinates, to set point A or B exactly.
- **Offline routing** with up to three alternatives (fastest, shortest and a distinct one) and route changes while paused.
- **Satellite view** to find your exact starting point.
- **Keeps running** in the background and with the screen locked.
- **Self-calibrating:** learns your car's wheelbase from the turns you drive.
- **Private by design:** no account, no server, nothing uploaded. Drives are recorded on the phone for export and replay; an optional GPS trace can be recorded alongside for accuracy testing only.

**Limitations:** you set the starting point by hand; accuracy drifts on long stretches without turns and when creeping below about 4 km/h; evenly spaced road joints can fool the speed measurement; a rigid mount is required.

## Quick start

### Prerequisites

- A Mac with **Xcode 26** or later (tested with Xcode 26.3) and about 1 GB of free space. The clone is about 230 MB, mostly offline maps; no Git LFS is needed.
- An **iPhone with iOS 17** or later. Tracking needs the real motion sensors, so the simulator only runs the interface.
- An **Apple ID** added in Xcode → Settings → Accounts. A free personal team works, but its installs expire after 7 days; a paid developer membership lasts a year.
- A **rigid phone mount** that holds the phone upright with the screen facing straight back along the car.
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) when adding or removing source files; Python 3 with `pyosmium` to rebuild map data; Python 3 with NumPy/SciPy and Node 20 for the Mac simulation lab.

### Install

1. `git clone https://github.com/leea-software/gpsless.git` and open `GPSLess.xcodeproj`. The first build downloads the pinned MapLibre 6.29.0 Swift package; map data and fonts are already in the repository.
2. **Simulator:** choose the **GPSLess** scheme and a simulator, then Run. No signing is needed.
3. **iPhone:** copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (ignored by Git). Set `DEVELOPMENT_TEAM` to your team ID (Xcode → Settings → Accounts → your team, or Signing & Capabilities) and `GPSLESS_BUNDLE_IDENTIFIER` to an identifier of your own, such as `com.yourname.gpsless`. Connect the iPhone, choose it as the run destination and Run.
4. On the first install, enable **Developer Mode** on the iPhone (Settings → Privacy & Security) and, with a free team, trust your developer profile (Settings → General → VPN & Device Management).

`project.yml` is the XcodeGen source. After adding or removing source files, run `xcodegen generate` and commit the regenerated project with it.

### Use

1. Choose the map on the first card (**Map**: Kyiv, Lviv region or a corridor map you built).
2. While parked, tap your road on the map, or search for it; the globe button switches to satellite imagery, which helps to spot exactly where you are. Drag the marker to your position, use **Flip** until the arrow points the way the car faces, and press **Set as start**.
3. Tap or search destination B and choose one of the offered routes.
4. Once, set the **Wheelbase** from your car's specifications (in the start sheet or **Settings → Car**); the app refines it from turns afterwards.
5. Mount the phone upright with the screen facing back, press **Start drive**, check the three points and press **Start drive** again, keep still for four seconds and drive. Allow Location when asked so tracking continues in other apps and with the screen locked (the location itself is discarded).
6. Follow the chosen route. Press **Pause** before taking the phone out of the mount. Recordings stay on the phone; **Settings → Recorded drives** exports them.

The [user guide](docs/USER_GUIDE.md) explains each control in detail.

## Documentation

- [User guide](docs/USER_GUIDE.md) — every control, pausing and resuming, the optional GPS reference trace.
- [Technical notes](docs/TECHNICAL.md) — how the engine works and how well, map data, recording format, replay and the simulation lab.
- [AGENTS.md](AGENTS.md) — for coding agents working on a fork. [MAINTAINING.md](MAINTAINING.md) — how this repository is maintained. [CHANGELOG.md](CHANGELOG.md).

## Privacy

Nothing leaves the phone unless you export it, search Apple Maps over the satellite view (the typed text), or hand over a short Google Maps link (the link is opened once to find its place). Location permission only keeps a drive running in the background (the location itself is discarded) and, if you turn it on, records the GPS reference trace. Recordings contain your routes and times, so **never attach recordings or screenshots of personal places to a public issue**; the issue template asks for what is needed instead.

## Licence

Code and documentation: [PolyForm Noncommercial 1.0.0](LICENSE.md) — free for personal use, study, changes and noncommercial sharing; commercial use is not permitted (so the project is source-available rather than OSI open source). Map data: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), [ODbL 1.0](GPSLess/OfflineData/DATA-LICENSE.md). Third-party components: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
