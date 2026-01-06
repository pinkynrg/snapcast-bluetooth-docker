FROM python:3.11-slim

# Install bluetooth utilities
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bluez \
    alsa-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the script and entrypoint
COPY bluetooth-speaker-reconnector.py /app/
COPY entrypoint.sh /app/

# Make scripts executable
RUN chmod +x /app/bluetooth-speaker-reconnector.py /app/entrypoint.sh

# Set default environment variables
ENV PYTHONUNBUFFERED=1 \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket \
    BT_MAC="" \
    BT_CHECK_INTERVAL="30" \
    BT_TIMEOUT="15"

ENTRYPOINT ["/app/entrypoint.sh"]
