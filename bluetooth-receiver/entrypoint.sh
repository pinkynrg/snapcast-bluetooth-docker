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
# bluetoothctl needs commands piped via stdin in non-TTY environments
for attempt in 1 2 3 4 5; do
    echo "Setting up Bluetooth (attempt $attempt)..."
    
    result=$(echo -e "power on\ndiscoverable on\npairable on\nagent NoInputNoOutput\ndefault-agent\nquit" | bluetoothctl 2>&1)
    echo "$result" | grep -E "succeeded|failed|error|already" | while read -r line; do
        echo "  $line"
    done
    
    # Verify discoverable is actually on
    if bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        echo "Bluetooth setup complete - discoverable and pairable"
        break
    fi
    
    echo "Bluetooth not yet discoverable, retrying in 3s..."
    sleep 3
done

# Final verification
if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
    echo "WARNING: Bluetooth may not be discoverable! Continuing anyway..."
fi

# Auto-trust and monitor connections using dbus-monitor (reliable, no TTY needed)
cat > /usr/local/bin/bt-autopair.sh << 'EOF'
#!/bin/bash
echo "bt-autopair: starting..."

# Trust all previously paired devices
for dev in $(bluetoothctl devices Paired 2>/dev/null | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"); do
    bluetoothctl trust "$dev" >/dev/null 2>&1
    echo "bt-autopair: trusted known device $dev"
done

# Monitor D-Bus for Bluetooth events (no TTY needed, won't exit)
dbus-monitor --system "interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace=/org/bluez" 2>&1 | while IFS= read -r line; do
    # Track device path
    if echo "$line" | grep -q "path=/org/bluez/hci0/dev_"; then
        current_path=$(echo "$line" | grep -oP "path=/org/bluez/hci0/dev_\K[A-F0-9_]+")
        current_mac=$(echo "$current_path" | tr '_' ':')
    fi
    
    # Detect connection
    if echo "$line" | grep -q '"Connected"'; then
        read -r next_line
        if echo "$next_line" | grep -q "true"; then
            echo "Bluetooth: Connected - ${current_mac:-unknown}"
            if [ -n "$current_mac" ]; then
                bluetoothctl trust "$current_mac" >/dev/null 2>&1
                echo "Bluetooth: Trusted - $current_mac"
            fi
        elif echo "$next_line" | grep -q "false"; then
            echo "Bluetooth: Disconnected - ${current_mac:-unknown}"
        fi
    fi
    
    # Detect services resolved (device fully ready)
    if echo "$line" | grep -q '"ServicesResolved"'; then
        read -r next_line
        if echo "$next_line" | grep -q "true"; then
            echo "Bluetooth: Device ready - ${current_mac:-unknown}"
        fi
    fi
done

echo "ERROR: bt-autopair dbus-monitor exited unexpectedly"
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
