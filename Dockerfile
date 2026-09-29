# Builds the pinot-s3 fork (direct deep-store / S3 querying, branch feature/remote-segment-reads)
# into a runnable image. The official Pinot Dockerfile builds from a git URL; this one builds
# from the repo context so the fork's working tree is what ships.

FROM eclipse-temurin:21-jdk AS builder
# buildnumber-maven-plugin shells out to git for the revision stamped into manifests
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
ENV MAVEN_OPTS="-Xmx4g -XX:+UseG1GC"
RUN ./mvnw install -DskipTests -Pbin-dist -T 1C \
      -Dcheckstyle.skip=true -Dlicense.skip=true -Dspotless.skip=true -Denforcer.skip=true -Drat.skip=true \
      -Djacoco.skip=true \
    && mv pinot-distribution/target/apache-pinot-*-bin/apache-pinot-*-bin /opt/pinot \
    && rm -rf /root/.m2 /build

FROM eclipse-temurin:21-jre
LABEL org.opencontainers.image.source="https://github.com/codeaeondev/pinot-s3"
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/pinot /opt/pinot
WORKDIR /opt/pinot
ENV JAVA_OPTS="-Xms512M -Xmx1G -XX:+UseG1GC"
# Component + config are supplied by the deployment, e.g.:
#   bin/pinot-admin.sh StartServer -configFileName /config/server.conf
CMD ["bin/pinot-admin.sh"]
