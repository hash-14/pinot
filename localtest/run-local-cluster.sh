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
# Four-container local cluster (zk, controller, broker, server) running the distribution
# built from this checkout (mvn install -DskipTests -Pbin-dist). The server runs with the
# remote segment-directory loader; localtest/deepstore/ stands in for S3 via file:// URIs.
#
#   ./run-local-cluster.sh up      # start (default)
#   ./run-local-cluster.sh down    # remove containers + network
#   ./run-local-cluster.sh status
#
# Env: SERVER_CONF=server.conf|server-baseline.conf, SERVER_JAVA_OPTS, PLATFORM=linux/amd64|linux/arm64
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NET=pinot-local
IMG=eclipse-temurin:21-jre

# Container platform follows the host unless overridden (Apple Silicon -> arm64, else amd64)
case "${PLATFORM:-$(uname -m)}" in
  linux/*) PLATFORM="${PLATFORM}";;
  arm64|aarch64) PLATFORM=linux/arm64;;
  *) PLATFORM=linux/amd64;;
esac

# Docker bind mounts need canonical host paths; on Git Bash (Windows) that means C:/... not /c/...
host_path() {
  local p; p=$(cd "$1" && pwd -P)
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$p"; else echo "$p"; fi
}
# Stop MSYS from rewriting container paths like /opt/pinot in the argument list
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

case "${1:-up}" in
  down)
    docker rm -f lp-zk lp-controller lp-broker lp-server 2>/dev/null || true
    docker network rm $NET 2>/dev/null || true
    echo "local cluster removed"; exit 0;;
  status)
    docker ps --filter name=lp- --format '{{.Names}} {{.Status}}'; exit 0;;
esac

DIST=$(ls -d "$DIR"/../pinot-distribution/target/apache-pinot-*-bin/apache-pinot-*-bin 2>/dev/null | head -1)
[ -n "$DIST" ] && [ -d "$DIST" ] || { echo "distribution not found — build with -Pbin-dist first"; exit 1; }
DIST=$(host_path "$DIST")
CONF=$(host_path "$DIR")
mkdir -p "$DIR/deepstore" "$DIR/logs"
DEEPSTORE=$(host_path "$DIR/deepstore")
LOGS=$(host_path "$DIR/logs")
echo "using dist: $DIST (platform $PLATFORM)"

# Real AWS credentials, if any, so a table can point remote.query.base.uri at a real s3:// URI
aws configure export-credentials --format env-no-export > "$DIR/aws-env.list" 2>/dev/null || : > "$DIR/aws-env.list"

docker network create $NET 2>/dev/null || true
docker rm -f lp-zk lp-controller lp-broker lp-server 2>/dev/null || true

docker run -d --name lp-zk --network $NET --platform $PLATFORM \
  zookeeper:3.9.3 > /dev/null
sleep 5

docker run -d --name lp-controller --network $NET --platform $PLATFORM \
  --env-file "$CONF/aws-env.list" -e AWS_REGION="${AWS_REGION:-eu-west-1}" \
  -e JAVA_OPTS="-Xms256M -Xmx1G" \
  -v "$DIST:/opt/pinot" -v "$CONF:/conf" -v "$DEEPSTORE:/deepstore" -p 9001:9000 $IMG \
  /opt/pinot/bin/pinot-admin.sh StartController -zkAddress lp-zk:2181 -clusterName pinot-local \
    -configFileName /conf/controller.conf > /dev/null

docker run -d --name lp-broker --network $NET --platform $PLATFORM \
  -e JAVA_OPTS="-Xms256M -Xmx1G" \
  -v "$DIST:/opt/pinot" -p 8098:8099 $IMG \
  /opt/pinot/bin/pinot-admin.sh StartBroker -zkAddress lp-zk:2181 -clusterName pinot-local > /dev/null

docker run -d --name lp-server --network $NET --platform $PLATFORM \
  --env-file "$CONF/aws-env.list" -e AWS_REGION="${AWS_REGION:-eu-west-1}" \
  -e LOG_ROOT=/logs -e PINOT_COMPONENT=all \
  -e JAVA_OPTS="${SERVER_JAVA_OPTS:--Xms512M -Xmx2G} -Dlog4j2.configurationFile=/conf/log4j2-local.xml" \
  -v "$DIST:/opt/pinot" -v "$CONF:/conf" -v "$DEEPSTORE:/deepstore" -v "$LOGS:/logs" $IMG \
  /opt/pinot/bin/pinot-admin.sh StartServer -zkAddress lp-zk:2181 -clusterName pinot-local \
    -configFileName /conf/${SERVER_CONF:-server.conf} > /dev/null

echo "cluster starting — controller: http://localhost:9001  broker: http://localhost:8098"
