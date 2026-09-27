# Maintaining the upstream repository

How changes reach the public repository without leaking personal data and without the documentation falling behind the code. Agents working upstream follow this together with [AGENTS.md](AGENTS.md).

## One-time setup on a maintainer's Mac

```bash
git config user.name "Leea Software"
git config user.email leea.software@gmail.com
git config core.hooksPath .githooks
gh auth switch --user leea-software
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set the real team and bundle ID
```

Create `Config/private-patterns.txt` with one regular expression per line for everything that must never appear publicly: personal names and emails, other GitHub accounts, the Apple team ID, device identifiers, home and work districts or streets. It is ignored by Git and read by `tools/privacy_check.py`.

The hooks run the privacy check automatically: quickly on every commit, and fully (including locations) before every push. Keep your own recordings under `build/`, which is ignored; the full check reads them to spot coordinates or road IDs near where you actually drive.

## README style

Keep README.md short: what it is, the main features in a line each, limitations, quick start, links. Explanations of how things work and measured results belong in docs/TECHNICAL.md; control-by-control usage in docs/USER_GUIDE.md.

## Every change

1. Make the change; keep `project.yml` and the generated Xcode project in sync (`xcodegen generate`).
2. Update the documentation the change affects (table below) in the same commit.
3. Run `swift test`, a simulator build, and for UI changes the app and UI tests.
4. Commit. The pre-commit hook must pass; never bypass it with `--no-verify`.
5. Before pushing, read `git log -p origin/main..HEAD` for anything personal: places, dates or times of your drives, screenshots, pasted logs. The pre-push hook runs the full check.

| When you change | Also update |
| --- | --- |
| Estimator behaviour (`Core/`) | `TrackingEngine.version`; docs/TECHNICAL.md "Positioning engine" with replay evidence, worded without places, dates or times; README features or limitations if they change; CHANGELOG |
| App features or controls | README "Features" and "Quick start" (brief), docs/USER_GUIDE.md (detail); CHANGELOG; AGENTS.md if commands or layout change |
| Recording format | docs/TECHNICAL.md "Recordings and replay" table; keep older formats readable; CHANGELOG |
| Map data rebuild | `DATA-LICENSE.md` snapshot table, docs/TECHNICAL.md "Offline data" counts, README features if coverage changes, manifests; keep every file under GitHub's 100 MB limit (`lviv-graph.json` is about 95 MB, so a larger area needs splitting or release downloads) |
| Dependencies, fonts, bundled assets | `THIRD_PARTY_NOTICES.md`, bundled licence files |
| Build settings, tool versions, signing | `project.yml`, `Config/Signing.xcconfig`, README "Prerequisites" |
| Privacy-relevant behaviour (what is recorded, exported or sent) | README "Privacy", docs/USER_GUIDE.md, issue template, CONTRIBUTING |
| Commands, invariants, repository layout | AGENTS.md |

## Releases

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, run `xcodegen generate`.
2. Add the release to CHANGELOG.md.
3. Commit, tag `vX.Y.Z` and push the tag.
4. Optionally create a GitHub release from the tag with the changelog entry. Do not attach recordings or signed builds.

## Issues and pull requests

- Issues: answer and label them. If one contains a recording, a GPS trace or a screenshot showing a personal place, hide or edit it and ask the reporter to remove the file.
- Pull requests are not accepted. Close them with a short thank-you pointing to CONTRIBUTING.md, for example `gh pr close <number> --comment "Thanks — this repository doesn't accept pull requests; please keep the change in your fork. See CONTRIBUTING.md."`

## Never publish

Recordings, exports, GPS traces, device containers, `build/`, `data-source/`, `artifacts/`, `Config/Local.xcconfig`, `Config/private-patterns.txt`, personal emails or names, the Apple team ID, device identifiers, and coordinates, road edge IDs or place names derived from your own drives.
