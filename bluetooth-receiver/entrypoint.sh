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

# Create auto-accept agent script
cat > /usr/local/bin/bt-agent << 'AGENTEOF'
#!/usr/bin/expect -f

set timeout -1
log_user 0

proc agent_loop {} {
    spawn bluetoothctl
    expect "*#"
    
    send "agent NoInputNoOutput\r"
    expect {
        "Agent registered" {
            send "default-agent\r"
            expect "Default agent request successful"
        }
        "Failed to register" {
            after 5000
            return
        }
    }
    
    # Keep agent running and auto-accept all requests
    while {1} {
        expect {
            "Confirm passkey*yes/no*" {
                send "yes\r"
            }
            "Accept pairing*yes/no*" {
                send "yes\r"
            }
            "Authorize service*yes/no*" {
                send "yes\r"
            }
            eof {
                break
            }
            timeout {
                continue
            }
        }
    }
}

while {1} {
    agent_loop
    after 2000
}
AGENTEOF

chmod +x /usr/local/bin/bt-agent

# Run agent in background
/usr/local/bin/bt-agent > /dev/null 2>&1 &
AGENT_PID=$!

sleep 2

echo "Bluetooth is now discoverable and auto-accepting connections"

# Kill any existing PulseAudio instances and clean up
pkill -9 pulseaudio 2>/dev/null || true
rm -rf /var/run/pulse /root/.config/pulse
mkdir -p /var/run/pulse

# Create PulseAudio system configuration
mkdir -p /etc/pulse

cat > /etc/pulse/system.pa << 'EOF'
#!/usr/bin/pulseaudio -nF

# Load protocol
load-module module-native-protocol-unix auth-anonymous=1

# Bluetooth support
load-module module-bluetooth-policy
load-module module-bluetooth-discover

# Pipe sink for snapserver - match Bluetooth's 44100Hz rate
load-module module-pipe-sink file=/tmp/snapfifo format=s16le rate=44100 channels=2 sink_name=snapcast
echo "PulseAudio started (PID: $PULSE_PID)"

sleep 5

# Auto-route any Bluetooth sources to snapcast sink via script
cat > /usr/local/bin/bt-audio-router << 'ROUTEREOF'
#!/bin/bash
while true; do
    # Find all Bluetooth A2DP sources
    for source in $(pactl list sources short | grep bluez | grep a2dp_source | awk '{print $2}'); do
        # Check if loopback already exists for this source
        if ! pactl list modules | grep -q "source=$source.*sink=snapcast"; then
            echo "Routing Bluetooth source $source to snapcast sink"
            pactl load-module module-loopback source="$source" sink=snapcast latency_msec=1 || true
        fi
    done
    sleep 2
done
ROUTEREOF

chmod +x /usr/local/bin/bt-audio-router
/usr/local/bin/bt-audio-router > /dev/null 2>&1 &

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
        pulseaudio --system --disallow-exit -F /etc/pulse/system.pa &
        PULSE_PID=$!
    fi
    
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "WARNING: Agent died, restarting..."
        /usr/local/bin/bt-agent > /dev/null 2>&1 &
        AGENT_PID=$!
    fi
    
    sleep 10
done
