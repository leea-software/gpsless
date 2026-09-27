#!/bin/bash
set -euo pipefail
cd "$SRCROOT"

# Native macOS tools only. Hash the actual estimator, sensor/recording code,
# app state and map used for this build so exported drives identify their inputs.
source_digest=$(/usr/bin/shasum -a 256 Core/*.swift GPSLess/Shared/*.swift | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1)
map_digest=$(/usr/bin/shasum -a 256 GPSLess/OfflineData/kyiv-graph.json | /usr/bin/cut -d ' ' -f 1)
# One digest per bundled region graph; the app records the active region's.
region_digests=""
for graph in GPSLess/OfflineData/*-graph.json; do
    region=$(/usr/bin/basename "$graph" -graph.json)
    digest=$(/usr/bin/shasum -a 256 "$graph" | /usr/bin/cut -d ' ' -f 1)
    region_digests="$region_digests,\"mapSHA256_$region\":\"$digest\""
done
identity_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BuildIdentity.json"
/bin/mkdir -p "$(/usr/bin/dirname "$identity_destination")"
/bin/cat > "$identity_destination" <<EOF
{"sourceSHA256":"$source_digest","mapSHA256":"$map_digest"$region_digests,"buildConfiguration":"$CONFIGURATION"}
EOF
