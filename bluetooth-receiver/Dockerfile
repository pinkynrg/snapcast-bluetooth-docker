FROM debian:bookworm-slim

# Install Bluetooth and audio dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bluez \
        pulseaudio \
        pulseaudio-module-bluetooth \
        dbus \
        alsa-utils \
        expect \
    && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment variables
ENV DEVICE_NAME="Snapcast Receiver"

CMD ["/usr/local/bin/entrypoint.sh"]
