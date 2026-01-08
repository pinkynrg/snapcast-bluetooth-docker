FROM debian:bookworm-slim

ARG SNAPCLIENT_VERSION=0.34.0-1
ARG DEBIAN_CODENAME=bookworm
ARG SNAPCLIENT_AMD64_URL=https://github.com/snapcast/snapcast/releases/download/v0.34.0/snapclient_0.34.0-1_amd64_bookworm.deb
ARG SNAPCLIENT_ARM64_URL=https://github.com/snapcast/snapcast/releases/download/v0.34.0/snapclient_0.34.0-1_arm64_bookworm.deb

# Install runtime dependencies and download snapclient
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        libasound2-plugins \
        alsa-utils && \
    arch=$(dpkg --print-architecture) && \
    if [ "$arch" = "amd64" ]; then \
        url="${SNAPCLIENT_AMD64_URL}"; \
    elif [ "$arch" = "arm64" ]; then \
        url="${SNAPCLIENT_ARM64_URL}"; \
    else \
        echo "Unsupported architecture: $arch" && exit 1; \
    fi && \
    curl -L -o /tmp/snapclient.deb "$url" && \
    apt-get install -y --no-install-recommends /tmp/snapclient.deb && \
    apt-get purge -y curl ca-certificates && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /tmp/snapclient.deb /var/lib/apt/lists/*

ENTRYPOINT []
CMD ["snapclient"]
