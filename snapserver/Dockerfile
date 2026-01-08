FROM debian:bookworm-slim

ARG SNAPSERVER_VERSION=0.34.0-1
ARG DEBIAN_CODENAME=bookworm
ARG SNAPSERVER_AMD64_URL=https://github.com/snapcast/snapcast/releases/download/v0.34.0/snapserver_0.34.0-1_amd64_bookworm.deb
ARG SNAPSERVER_ARM64_URL= https://github.com/snapcast/snapcast/releases/download/v0.34.0/snapserver_0.34.0-1_arm64_bookworm.deb

# Install build dependencies for librespot and runtime dependencies for snapserver
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        git \
        build-essential \
        pkg-config \
        libasound2-dev \
        libssl-dev \
        ca-certificates \
        bash \
        sed && \
    rm -rf /var/lib/apt/lists/*

# Install Rust (for librespot build)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

# Build librespot from source
RUN git clone https://github.com/librespot-org/librespot.git /librespot && \
    cd /librespot && \
    cargo build --release && \
    cp target/release/librespot /usr/local/bin/librespot && \
    chmod +x /usr/local/bin/librespot && \
    rm -rf /librespot

# Remove build dependencies to reduce image size
RUN apt-get purge -y \
        git \
        build-essential \
        pkg-config \
        libasound2-dev \
        libssl-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Download and install the correct snapserver .deb for the architecture
RUN arch=$(dpkg --print-architecture) && \
    if [ "$arch" = "amd64" ]; then \
        url="${SNAPSERVER_AMD64_URL}"; \
    elif [ "$arch" = "arm64" ]; then \
        url="${SNAPSERVER_ARM64_URL}"; \
    else \
        echo "Unsupported architecture: $arch" && exit 1; \
    fi && \
    curl -L -o /tmp/snapserver.deb "$url" && \
    apt-get update && \
    apt-get install -y --no-install-recommends /tmp/snapserver.deb && \
    rm -rf /tmp/snapserver.deb /var/lib/apt/lists/*

# Environment variables
ENV DEVICE_NAME=Snapcast
ENV CACHE=/data

# Expose snapserver ports
EXPOSE 1704/tcp 1705/tcp

# Start snapserver with librespot source
CMD ["/bin/bash", "-c", "\
    cp /etc/snapserver.conf /tmp/snapserver.conf && \
    sed -i \"s,^source = .*,source = librespot:///librespot?name=Spotify\\&devicename=$DEVICE_NAME\\&bitrate=320\\&volume=100\\&cache=$CACHE,\" /tmp/snapserver.conf && \
    exec snapserver -c /tmp/snapserver.conf\
"]