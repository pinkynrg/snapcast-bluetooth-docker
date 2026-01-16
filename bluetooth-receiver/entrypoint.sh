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
killall -9 pulseaudio 2>/dev/null || true
sleep 1
rm -rf /var/run/pulse /root/.config/pulse /tmp/pulse-* ~/.pulse
mkdir -p /var/run/pulse

# Create minimal system config
mkdir -p /etc/pulse
cat > /etc/pulse/system.pa << 'EOF'
load-module module-device-restore
load-module module-stream-restore
load-module module-card-restore
load-module module-native-protocol-unix auth-anonymous=1
load-module module-bluetooth-policy
load-module module-bluetooth-discover
EOF

# Start PulseAudio in system mode
pulseaudio --system --disallow-exit --log-level=error -F /etc/pulse/system.pa &
PULSE_PID=$!
echo "PulseAudio started (PID: $PULSE_PID)"

sleep 5

# Create pipe sink for snapserver
pactl load-module module-pipe-sink file=/tmp/snapfifo format=s16le rate=44100 channels=2 sink_name=snapcast

# Set as default
pactl set-default-sink snapcast

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
