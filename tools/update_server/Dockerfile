# Skotiq Update Server Docker Image
#
# Build:
#   docker build -t skotiq-update-server .
#
# Run:
#   docker run -d -p 8090:8090 \
#     -v $(pwd)/releases:/app/releases \
#     -v $(pwd)/manifests:/app/manifests \
#     skotiq-update-server

FROM dart:stable AS build

WORKDIR /app

# Copy pubspec and get dependencies
COPY pubspec.yaml .
RUN dart pub get

# Copy source
COPY server.dart .

# Compile to native
RUN dart compile exe server.dart -o server

# Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled binary
COPY --from=build /app/server /app/server

# Create directories for releases and manifests
RUN mkdir -p /app/releases /app/manifests

# Expose port
EXPOSE 8090

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8090/health || exit 1

# Run server
CMD ["/app/server", "--port", "8090", "--releases", "/app/releases", "--manifests", "/app/manifests"]
