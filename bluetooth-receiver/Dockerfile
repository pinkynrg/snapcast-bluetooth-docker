FROM debian:bookworm-slim

# Install build dependencies and runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Build tools
        git \
        build-essential \
        automake \
        autoconf \
        libtool \
        pkg-config \
        # Bluetooth and audio libraries
        bluez \
        libbluetooth-dev \
        libasound2-dev \
        libdbus-1-dev \
        libglib2.0-dev \
        libsbc-dev \
        # Runtime tools
        dbus \
        alsa-utils \
        expect \
        procps \
        iproute2 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build and install bluez-alsa from source
RUN git clone --depth=1 https://github.com/Arkq/bluez-alsa.git /tmp/bluez-alsa && \
    cd /tmp/bluez-alsa && \
    autoreconf --install --force && \
    mkdir build && cd build && \
    ../configure --enable-cli --disable-manpages && \
    make && make install && \
    ldconfig && \
    cd / && rm -rf /tmp/bluez-alsa

# Clean up build-only dependencies (keep runtime libs)
RUN apt-get remove -y \
        git \
        build-essential \
        automake \
        autoconf \
        libtool \
        pkg-config \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Load ALSA loopback kernel module support
RUN echo "snd-aloop" >> /etc/modules

# Install additional runtime tools (separate layer to preserve cache)
RUN apt-get update && apt-get install -y --no-install-recommends socat && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment variables
ENV DEVICE_NAME="Snapcast Receiver"

CMD ["/usr/local/bin/entrypoint.sh"]
