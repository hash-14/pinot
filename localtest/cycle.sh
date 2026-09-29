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
# Up -> wait for "Remote querying enabled" -> schema/table/segments -> wait ONLINE -> bench.
#   ./cycle.sh baseline                          # label for the bench output
#   SERVER_CONF=server-baseline.conf ./cycle.sh  # prefetch off (the A/B)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=${1:-run}
T=streams_daily
LOG="$DIR/logs/pinot-all.log"
EXPECTED=$(ls "${SEGMENTS_DIR:-$DIR/deepstore/demo/segments}"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
[ "$EXPECTED" -gt 0 ] || { echo "no segments — run ./make-demo-data.sh first"; exit 1; }

"$DIR/run-local-cluster.sh" up | tail -1
for i in $(seq 1 80); do
  curl -sf localhost:9001/health >/dev/null 2>&1 && grep -q "Remote querying enabled" "$LOG" 2>/dev/null && break
  if [ "$(docker inspect -f '{{.State.Running}}' lp-server 2>/dev/null)" != "true" ]; then
    echo "SERVER DIED:"; docker logs lp-server 2>&1 | grep -E "Exception|Error" | head -5; exit 1
  fi
  sleep 3
done
grep "Remote querying enabled" "$LOG" | tail -1 | sed 's/.*Remote querying enabled/server: remote querying enabled/' | cut -c1-200
"$DIR/setup-table.sh" 2>&1 | grep -E "not (ready|accepted)|failed|uploaded" || true
online() { curl -s "localhost:9001/tables/$T/externalview" | grep -o ONLINE | wc -l | tr -d ' '; }
for i in $(seq 1 80); do
  [ "$(online)" = "$EXPECTED" ] && break
  sleep 3
done
echo "segments online: $(online)/$EXPECTED"
sleep 3
"$DIR/bench.sh" "$LABEL"
