# Skotiq Constellation hub — self-hostable community fusion service.
#
# Build:  docker build -t skotiq-hub server/skotiq_hub
# Run:    docker run -d --name skotiq-hub -p 8088:8088 \
#           -e SKOTIQ_HUB_SECRET="$(openssl rand -hex 32)" \
#           -v skotiq-hub-state:/data skotiq-hub
#
# NOTE: the hub refuses to start on a weak/short secret. Pass a high-entropy
# value (the openssl one-liner above), or omit -e SKOTIQ_HUB_SECRET entirely
# and the hub will generate + persist a strong random secret beside the DB. The
# admin account's password IS this secret, so a guessable secret is a full hub
# compromise — never ship a literal placeholder like "change-me".

FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && \
    dart compile exe bin/server.dart -o /app/hub

# Runtime: the Dart AOT binary needs the SDK runtime libs (under /runtime) plus
# the system libsqlite3 (the hub talks to sqlite over FFI). A slim Debian base
# provides libsqlite3; copying just the runtime keeps the image small.
FROM debian:stable-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /runtime/ /
COPY --from=build /app/hub /app/hub

ENV SKOTIQ_HUB_PORT=8088
ENV SKOTIQ_HUB_BIND=0.0.0.0
ENV SKOTIQ_HUB_DB=/data/hub.db
ENV SKOTIQ_HUB_ATLAS_ROOT=/data/atlas

EXPOSE 8088
VOLUME ["/data"]
ENTRYPOINT ["/app/hub"]
