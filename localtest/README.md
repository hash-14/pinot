<!--
    Licensed to the Apache Software Foundation (ASF) under one
    or more contributor license agreements.  See the NOTICE file
    distributed with this work for additional information
    regarding copyright ownership.  The ASF licenses this file
    to you under the Apache License, Version 2.0 (the
    "License"); you may not use this file except in compliance
    with the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing,
    software distributed under the License is distributed on an
    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
    KIND, either express or implied.  See the License for the
    specific language governing permissions and limitations
    under the License.
-->
# Local cluster for direct deep-store (S3) querying

Four Docker containers (ZooKeeper, controller, broker, server) running the distribution built
from this checkout. The server uses the remote segment-directory loader; `deepstore/` on your
machine stands in for S3 through `file://` URIs, and `remote.fetch.debug.latency.ms=30` fakes
S3 first-byte latency per GET. Point `remote.query.base.uri` in `table.json` at a real `s3://`
URI and the same harness reads the real bucket (your AWS CLI credentials are exported into the
containers).

Prerequisites: JDK 21, Docker, `curl`, `jq` (or `JQ=/path/to/jq`). Works on Linux, macOS
(Intel or Apple Silicon) and Git Bash on Windows.

```sh
# 1. build the distribution (once; add -Dnpm.script=build on Windows)
./mvnw install -DskipTests -Pbin-dist -Dcheckstyle.skip -Dspotless.check.skip -Dlicense.skip -Denforcer.skip

# 2. generate the demo table: CSV -> segments -> untarred v3 layout under deepstore/remote/
cd localtest
DAYS=5 ROWS=200000 ./make-demo-data.sh

# 3. cluster up + schema + table + segments + benchmark
./cycle.sh prefetch                              # server.conf: plan prefetch + pipelined hints
SERVER_CONF=server-baseline.conf ./cycle.sh baseline   # the A/B: both off
./run-local-cluster.sh down
```

`bench.sh` prints, for every query, Pinot's own counters (`timeUsedMs`, `numDocsScanned`,
`numEntriesScannedInFilter`, ...) followed by the `Remote fetch stats` line the server logged
for it: how many ranged GETs the query caused, how many bytes, and how long was spent inside
them. `logs/pinot-all.log` is the full server log.

Files:

| File | Purpose |
|---|---|
| `run-local-cluster.sh` | `up` / `down` / `status`; mounts the dist, `localtest/` (as `/conf`), `deepstore/`, `logs/` |
| `make-demo-data.sh` | writes `deepstore/demo/raw/*.csv`, runs `LaunchDataIngestionJob` (`ingestion-job.yaml`), untars every tarball to `deepstore/remote/streams_daily/<segment>/v3/` |
| `setup-table.sh` | `POST /schemas`, `POST /tables` (retried until Helix tenants exist), uploads the tarballs from `deepstore/demo/segments/` |
| `cycle.sh` | the whole loop, waits for every segment to be ONLINE, then `bench.sh` |
| `server.conf` / `server-baseline.conf` | remote loader on; plan prefetch + pipelined hints on / off |
| `schema.json` / `table.json` | the `streams_daily` demo table: sorted `artist_id`, inverted `country_code`/`song_id`/`device`, bloom `song_id`/`song_name`, range `all_streams`, a star-tree, and the `metadata.customConfigs` remote opt-in |

The trap to remember: `customConfigs` lives under the `metadata` key of the table config. At
the top level it is accepted silently and the table is served the stock way.
