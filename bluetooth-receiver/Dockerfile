FROM debian:bookworm-slim

# Install Bluetooth, bluez-alsa, and audio dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bluez \
        bluez-alsa \
        dbus \
        alsa-utils \
        expect \
        procps \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Load ALSA loopback kernel module support
RUN echo "snd-aloop" >> /etc/modules

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment variables
ENV DEVICE_NAME="Snapcast Receiver"

CMD ["/usr/local/bin/entrypoint.sh"]
