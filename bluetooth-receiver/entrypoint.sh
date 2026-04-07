#!/bin/bash
# NOTE: Do NOT use set -e here. bluetoothctl commands can fail transiently
# (e.g. when a previously paired device triggers events mid-command)
# and we don't want the whole container to die.

echo "Starting Bluetooth receiver..."

# Check if Bluetooth hardware is available
if ! ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    echo "ERROR: No Bluetooth adapter found!"
    echo "Make sure host Bluetooth service is stopped: sudo systemctl stop bluetooth.service"
    exit 1
fi

echo "Bluetooth adapter found: $(ls /sys/class/bluetooth/)"

# Configure Bluetooth for auto-pairing
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
PairableTimeout = 0
FastConnectable = true
ControllerMode = dual
JustWorksRepairing = always
Privacy = off

[BR]
PageTimeout = 8192

[Policy]
AutoEnable = true
ReconnectAttempts = 7
ReconnectIntervals = 1,2,4,8,16,32,64
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

# Wait for bluetooth controller to be ready
TIMEOUT=30
ELAPSED=0
while ! bluetoothctl show >/dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Bluetooth controller not available after ${TIMEOUT}s"
        echo "Make sure host Bluetooth service is stopped:"
        echo "  sudo systemctl stop bluetooth.service"
        echo "  sudo systemctl disable bluetooth.service"
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "Bluetooth controller ready"

# Configure Bluetooth to be discoverable and pairable
# Retry each command - can fail if a previously paired device triggers events
for cmd in "power on" "discoverable on" "pairable on"; do
    for attempt in 1 2 3; do
        if bluetoothctl $cmd 2>&1 | tee /dev/stderr | grep -q "succeeded\|already"; then
            break
        fi
        echo "Retrying bluetoothctl $cmd (attempt $attempt)..."
        sleep 2
    done
done

# Auto-trust and monitor connections
cat > /usr/local/bin/bt-autopair.sh << 'EOF'
#!/bin/bash
echo "Starting bt-autopair script..."

# Test if bluetoothctl works
if ! bluetoothctl show >/dev/null 2>&1; then
    echo "ERROR: bluetoothctl is not working"
    exit 1
fi

echo "bluetoothctl is responsive, starting monitor..."

# Monitor bluetoothctl output
bluetoothctl 2>&1 | while IFS= read -r line; do
    echo "[BT-MONITOR] $line"
    
    # Check for connection events
    if echo "$line" | grep -iq "CHG.*Connected: yes"; then
        mac=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
        if [ -n "$mac" ]; then
            echo "Bluetooth: Connected - $mac"
            bluetoothctl trust "$mac" >/dev/null 2>&1
        fi
    elif echo "$line" | grep -iq "CHG.*Connected: no"; then
        mac=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
        if [ -n "$mac" ]; then
            echo "Bluetooth: Disconnected - $mac"
        fi
    elif echo "$line" | grep -iq "NEW.*Device"; then
        mac=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
        if [ -n "$mac" ]; then
            echo "Bluetooth: Device discovered - $mac"
        fi
    fi
done

echo "ERROR: bt-autopair monitor loop exited unexpectedly"
exit 1
EOF

chmod +x /usr/local/bin/bt-autopair.sh  
/usr/local/bin/bt-autopair.sh &
AUTOPAIR_PID=$!

sleep 3

echo "Bluetooth is now discoverable and auto-accepting connections"

# Kill any existing PulseAudio instances
pulseaudio --kill 2>/dev/null || true
killall -9 pulseaudio 2>/dev/null || true
pkill -9 -f pulseaudio 2>/dev/null || true
rm -rf /var/run/pulse /tmp/pulse-* 2>/dev/null || true
sleep 2

# Disable default PulseAudio configs to prevent conflicts
mkdir -p /etc/pulse/default.pa.d
mv /etc/pulse/default.pa /etc/pulse/default.pa.disabled 2>/dev/null || true
mv /etc/pulse/system.pa /etc/pulse/system.pa.disabled 2>/dev/null || true

# Start PulseAudio with minimal config
mkdir -p /etc/pulse
cat > /etc/pulse/custom.pa << 'EOF'
load-module module-native-protocol-unix auth-anonymous=1
load-module module-null-sink sink_name=tcp_out rate=44100 channels=2
load-module module-simple-protocol-tcp rate=44100 format=s16le channels=2 source=tcp_out.monitor port=4953 listen=0.0.0.0 record=true
load-module module-bluetooth-policy auto_switch=2
load-module module-bluetooth-discover headset=auto
load-module module-switch-on-connect
set-default-sink tcp_out
EOF

# Configure daemon settings for better Bluetooth stability on Pi Zero
cat > /etc/pulse/daemon.conf << 'EOF'
daemonize = no
fail = yes
high-priority = yes
nice-level = -11
realtime-scheduling = yes
realtime-priority = 5
exit-idle-time = -1
resample-method = ffmpeg
avoid-resampling = yes
default-sample-format = s16le
default-sample-rate = 44100
alternate-sample-rate = 48000
default-sample-channels = 2
default-fragments = 8
default-fragment-size-msec = 10
EOF

pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
PULSE_PID=$!
echo "PulseAudio started (PID: $PULSE_PID)"

sleep 3

echo "Audio configuration complete"

echo "====================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "Streaming to TCP port 4953"
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
        pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
        PULSE_PID=$!
    fi
    
    if ! kill -0 $AUTOPAIR_PID 2>/dev/null; then
        echo "WARNING: Auto-pair script died, restarting..."
        /usr/local/bin/bt-autopair.sh &
        AUTOPAIR_PID=$!
    fi
    
    sleep 10
done
