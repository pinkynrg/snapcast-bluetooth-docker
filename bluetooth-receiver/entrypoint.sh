#!/bin/bash
set -e

echo "Starting Bluetooth receiver..."

# Check if Bluetooth hardware is available
if ! ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    echo "ERROR: No Bluetooth adapter found!"
    echo "Make sure:"
    echo "  1. Bluetooth hardware is present"
    echo "  2. Host Bluetooth service is stopped: sudo systemctl stop bluetooth.service"
    echo "  3. Container is running with privileged: true"
    exit 1
fi

echo "Bluetooth adapter found: $(ls /sys/class/bluetooth/)"

# Create FIFO if it doesn't exist
if [ ! -p /tmp/snapfifo ]; then
    mkfifo -m 666 /tmp/snapfifo
    echo "Created FIFO at /tmp/snapfifo"
fi

# Configure Bluetooth for auto-pairing
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
PairableTimeout = 0
FastConnectable = true

[Policy]
AutoEnable=true
EOF

echo "Bluetooth configured for auto-pairing"

# Start D-Bus
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --fork
echo "D-Bus started"

sleep 1

# Start Bluetooth service
/usr/libexec/bluetooth/bluetoothd &
BLUETOOTHD_PID=$!
echo "Bluetooth daemon started (PID: $BLUETOOTHD_PID)"

sleep 2

# Configure Bluetooth to be discoverable and auto-accept
bluetoothctl <<EOF
power on
discoverable on
pairable on
agent NoInputNoOutput
default-agent
EOF

echo "Bluetooth is now discoverable and accepting connections"

# Create PulseAudio system configuration
mkdir -p /etc/pulse

cat > /etc/pulse/system.pa << 'EOF'
#!/usr/bin/pulseaudio -nF

# Load audio drivers
load-module module-alsa-sink device=default
load-module module-alsa-source device=default
load-module module-native-protocol-unix auth-anonymous=1

# Bluetooth support
load-module module-bluetooth-policy
load-module module-bluetooth-discover

# Pipe sink for snapserver
load-module module-pipe-sink file=/tmp/snapfifo format=s16le rate=48000 channels=2 sink_name=snapcast

# Set default
set-default-sink snapcast
EOF

cat > /etc/pulse/client.conf << 'EOF'
autospawn = no
daemon-binary = /bin/true
enable-shm = false
EOF

# Start PulseAudio in system mode
pulseaudio --system --disallow-exit -F /etc/pulse/system.pa &
PULSE_PID=$!
echo "PulseAudio started (PID: $PULSE_PID)"

sleep 3

echo "Audio configuration complete"

echo "====================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "Connect your phone/device via Bluetooth"
echo "Audio will stream to snapserver"
echo "====================================="

# Monitor and keep container running
while true; do
    if ! kill -0 $BLUETOOTHD_PID 2>/dev/null; then
        echo "ERROR: Bluetooth daemon died, restarting..."
        /usr/libexec/bluetooth/bluetoothd &
        BLUETOOTHD_PID=$!
    fi
    
    if ! kill -0 $PULSE_PID 2>/dev/null; then
        echo "ERROR: PulseAudio died, restarting..."
        pulseaudio --system --disallow-exit --disallow-module-loading=false &
        PULSE_PID=$!
    fi
    
    sleep 10
done
