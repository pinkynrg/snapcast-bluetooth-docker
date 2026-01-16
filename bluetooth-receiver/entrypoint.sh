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

sleep 3

# Configure Bluetooth to be discoverable and pairable
bluetoothctl power on
bluetoothctl discoverable on
bluetoothctl pairable on

# Use a simple pairing agent script
cat > /tmp/bt-agent << 'BTEOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl
send "agent NoInputNoOutput\r"
expect "Agent registered"
send "default-agent\r"
expect eof
BTEOF

# Install expect if needed and run agent
if ! command -v expect &> /dev/null; then
    apt-get update && apt-get install -y expect
fi
chmod +x /tmp/bt-agent
/tmp/bt-agent || echo "Agent setup attempted"

echo "Bluetooth is now discoverable and accepting connections"

# Kill any existing PulseAudio instances
killall pulseaudio 2>/dev/null || true
rm -f /var/run/pulse/native /var/run/pulse/pid

# Create PulseAudio system configuration
mkdir -p /etc/pulse

cat > /etc/pulse/system.pa << 'EOF'
#!/usr/bin/pulseaudio -nF

# Load protocol
load-module module-native-protocol-unix auth-anonymous=1

# Bluetooth support
load-module module-bluetooth-policy
load-module module-bluetooth-discover

# Pipe sink for snapserver
load-module module-pipe-sink file=/tmp/snapfifo format=s16le rate=48000 channels=2 sink_name=snapcast

# Set default
set-default-sink snapcast
EOF

sleep 1

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
