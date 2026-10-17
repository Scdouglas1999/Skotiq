# Skotiq relay — self-hostable remote-access relay.
#
# Build:  docker build -t skotiq-relay tools/skotiq_relay
# Run:    docker run -d --name skotiq-relay -p 9777:9777 \
#           -v skotiq-relay-state:/data skotiq-relay

FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && \
    dart compile exe bin/relay.dart -o /app/relay

# Minimal runtime: the Dart AOT runtime libs live under /runtime in the SDK
# image and are the only thing the compiled binary needs besides libc.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/relay /app/relay

ENV SKOTIQ_RELAY_PORT=9777
ENV SKOTIQ_RELAY_STATE_FILE=/data/relay_state.json

EXPOSE 9777
VOLUME ["/data"]
ENTRYPOINT ["/app/relay"]
