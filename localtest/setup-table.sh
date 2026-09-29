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
# Creates the schema + table and uploads the demo segment tarballs (from make-demo-data.sh,
# or SEGMENTS_DIR=<dir with *.tar.gz>). The untarred copies must already be under
# deepstore/remote/<table>/ - that is what the server reads; the tarball upload only
# registers the segment with the controller/Helix.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
C=http://localhost:9001
T=streams_daily
SEGMENTS_DIR=${SEGMENTS_DIR:-$DIR/deepstore/demo/segments}

until curl -sf $C/health >/dev/null; do echo "waiting for controller"; sleep 3; done
# The controller passes /health before tenants register in Helix; writes fail until they do
for i in $(seq 1 30); do
  curl -sf -X POST $C/schemas -H 'Content-Type: application/json' -d @"$DIR/schema.json" && echo && break
  echo "controller not ready for writes yet ($i)"; sleep 3
done
for i in $(seq 1 30); do
  curl -sf -X POST $C/tables -H 'Content-Type: application/json' -d @"$DIR/table.json" && echo && break
  echo "table not accepted yet ($i)"; sleep 3
done
curl -sf $C/tables/$T >/dev/null || { echo "table creation failed"; exit 1; }

n=0
for tar in "$SEGMENTS_DIR"/*.tar.gz; do
  [ -f "$tar" ] || { echo "no tarballs in $SEGMENTS_DIR — run make-demo-data.sh first"; exit 1; }
  echo "uploading $(basename "$tar")"
  curl -sf -F segment=@"$tar" "$C/v2/segments?tableName=$T&tableType=OFFLINE" && echo
  n=$((n + 1))
done
sleep 5
curl -s "$C/segments/$T/servers" | head -c 600; echo
echo "uploaded $n segments"
