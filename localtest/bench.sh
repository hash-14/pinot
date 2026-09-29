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
# Runs the benchmark query set against the local broker and, after each query, prints the
# "Remote fetch stats" line the server logged for it (GETs, bytes, time inside GETs).
# Needs jq (JQ=/path/to/jq to override).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
B=http://localhost:8098
T=streams_daily
LABEL=${1:-run}
JQ=${JQ:-jq}
LOG="$DIR/logs/pinot-all.log"

q() {
  local sql="$1"
  local res; res=$(curl -s -X POST $B/query/sql -H 'Content-Type: application/json' \
    -d "$($JQ -cn --arg s "$sql" '{sql:$s}')")
  echo "--- $sql"
  echo "$res" | $JQ -c '{timeUsedMs, numDocsScanned, numSegmentsQueried, numSegmentsProcessed, numEntriesScannedInFilter, numEntriesScannedPostFilter, rows: (.resultTable.rows|length), exceptions: (.exceptions|map(.message)|.[0]|.[0:120])}'
  sleep 1
  local after; after=$(grep -c "Remote fetch stats" "$LOG" 2>/dev/null || echo 0)
  if [ "$after" -gt "$STATS_SEEN" ]; then
    grep "Remote fetch stats" "$LOG" | tail -n +$((STATS_SEEN + 1)) | sed 's/.*Remote fetch stats for table: [^,]*,/    fetch stats:/'
  else
    echo "    fetch stats: no remote GETs"
  fi
  STATS_SEEN=$after
}

STATS_SEEN=$(grep -c "Remote fetch stats" "$LOG" 2>/dev/null || echo 0)
echo "=== $LABEL"
q "SELECT COUNT(*) FROM $T"
q "SELECT * FROM $T LIMIT 10"
q "SELECT artist_id, SUM(all_streams) FROM $T WHERE day_dt = '2026-09-01' GROUP BY artist_id ORDER BY SUM(all_streams) DESC LIMIT 10"
q "SELECT SUM(all_streams), SUM(full_streams) FROM $T WHERE artist_id = 126"
q "SELECT country_code, SUM(all_streams) FROM $T WHERE artist_id = 126 GROUP BY country_code ORDER BY SUM(all_streams) DESC LIMIT 20"
q "SELECT song_name, SUM(all_streams) FROM $T WHERE artist_id = 126 GROUP BY song_name ORDER BY SUM(all_streams) DESC LIMIT 20"
q "SELECT COUNT(*) FROM $T WHERE song_id = 1263"
q "SELECT device, COUNT(*) FROM $T WHERE country_code = 'LB' AND all_streams > 400 GROUP BY device ORDER BY COUNT(*) DESC"
