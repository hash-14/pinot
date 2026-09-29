#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Builds the demo dataset for the local cluster, entirely from this checkout:
#   1. DAYS daily CSV files (ROWS rows each) -> localtest/deepstore/demo/raw/
#   2. pinot-admin LaunchDataIngestionJob (SegmentCreation, in a container running the built
#      distribution) -> tarballs in localtest/deepstore/demo/segments/
#   3. each tarball untarred to localtest/deepstore/remote/streams_daily/<segment>/v3/ - the
#      layout the remote loader range-reads (compressed tarballs cannot be range-read)
# setup-table.sh then uploads the tarballs to the controller so Helix assigns them.
#
#   DAYS=5 ROWS=200000 ./make-demo-data.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TABLE=streams_daily
DAYS=${DAYS:-5}
ROWS=${ROWS:-200000}
START=${START:-2026-09-01}
IMG=eclipse-temurin:21-jre
case "${PLATFORM:-$(uname -m)}" in
  linux/*) PLATFORM="${PLATFORM}";;
  arm64|aarch64) PLATFORM=linux/arm64;;
  *) PLATFORM=linux/amd64;;
esac
host_path() {
  local p; p=$(cd "$1" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$p"; else echo "$p"; fi
}
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

DIST=$(ls -d "$DIR"/../pinot-distribution/target/apache-pinot-*-bin/apache-pinot-*-bin 2>/dev/null | head -1)
[ -n "$DIST" ] && [ -d "$DIST" ] || { echo "distribution not found — build with -Pbin-dist first"; exit 1; }

RAW="$DIR/deepstore/demo/raw"
SEGS="$DIR/deepstore/demo/segments"
REMOTE="$DIR/deepstore/remote/$TABLE"
mkdir -p "$RAW" "$SEGS" "$REMOTE"

# 1. CSV: skewed artist popularity, ~20k artists x 10 songs, 20 countries, deterministic per day
for ((d = 0; d < DAYS; d++)); do
  day=$(date -u -d "$START +$d day" +%F 2>/dev/null || date -u -j -v+${d}d -f %F "$START" +%F)
  out="$RAW/$day.csv"
  if [ -s "$out" ]; then echo "keep $out"; continue; fi
  awk -v rows="$ROWS" -v day="$day" -v seed="$((1000 + d))" 'BEGIN {
    srand(seed)
    split("LB AE SA EG US FR DE GB JO KW QA MA TN IQ TR BR IN ID NG MX", C, " ")
    split("ios android web tv desktop", D, " ")
    split("mobile web embedded", P, " ")
    print "day_dt,artist_id,song_id,song_name,country_code,device,platform,all_streams,full_streams,total_seconds_streamed"
    for (i = 0; i < rows; i++) {
      artist = int(40 * (rand() ^ (-1 / 1.2) - 1)) % 20000 + 1
      song = artist * 10 + int(rand() * 10)
      all = 1 + int(rand() * 499)
      full = int(rand() * 500); if (full > all) full = all
      secs = all * (30 + int(rand() * 210))
      printf "%s,%d,%d,Song %d,%s,%s,%s,%d,%d,%d\n", day, artist, song, song, C[1 + int(rand() * 20)], D[1 + int(rand() * 5)], P[1 + int(rand() * 3)], all, full, secs
    }
  }' | { IFS= read -r header; echo "$header"; sort -t, -k2,2n -s; } > "$out"
  # (sorted by artist_id: Pinot does not sort offline input, it only detects already-sorted columns)
  echo "wrote $out ($ROWS rows)"
done

# 2. segments (tarballs) from the CSVs, using the built distribution inside a Linux container
docker run --rm --platform $PLATFORM \
  -e JAVA_OPTS="-Xms512M -Xmx2G" \
  -v "$(host_path "$DIST"):/opt/pinot" -v "$(host_path "$DIR"):/conf" -v "$(host_path "$DIR/deepstore"):/deepstore" $IMG \
  /opt/pinot/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile /conf/ingestion-job.yaml 2>&1 \
  | grep -v -E "^\s+at " | grep -i -E "ERROR|Exception|Finished|Creating|segment" | head -40
ls "$SEGS"/*.tar.gz >/dev/null 2>&1 || { echo "segment creation produced no tarballs (see output above)"; exit 1; }

# 3. untarred v3 layout for the remote loader
for tar in "$SEGS"/*.tar.gz; do
  seg=$(basename "$tar" .tar.gz)
  rm -rf "${REMOTE:?}/${seg:?}"
  tar -xzf "$tar" -C "$REMOTE"
  [ -f "$REMOTE/$seg/v3/columns.psf" ] || { echo "unexpected layout in $tar"; ls -R "$REMOTE/$seg" | head; exit 1; }
  echo "published $seg -> deepstore/remote/$TABLE/$seg/v3 ($(du -sh "$REMOTE/$seg/v3/columns.psf" | cut -f1))"
done
echo "done: $(ls "$SEGS"/*.tar.gz | wc -l | tr -d ' ') segments"
