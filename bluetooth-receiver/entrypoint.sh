#!/bin/bash
set -e

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
bluetoothctl power on > /dev/null 2>&1
bluetoothctl discoverable on > /dev/null 2>&1
bluetoothctl pairable on > /dev/null 2>&1

# Create auto-accept agent script
cat > /usr/local/bin/bt-agent << 'AGENTEOF'
#!/usr/bin/expect -f

set timeout -1
log_user 0

proc agent_loop {} {
    spawn bluetoothctl
    expect {
        "*Agent registered*" { }
        "*#" { }
        timeout { after 2000; return }
    }
    sleep 1
    
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
                puts "Bluetooth: Pairing confirmed"
            }
            "Accept pairing*yes/no*" {
                send "yes\r"
                puts "Bluetooth: Pairing accepted"
            }
            "Authorize service*yes/no*" {
                send "yes\r"
                puts "Bluetooth: Service authorized"
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
/usr/local/bin/bt-agent &
AGENT_PID=$!

sleep 2

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
load-module module-bluetooth-policy
load-module module-bluetooth-discover
load-module module-switch-on-connect
set-default-sink tcp_out
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
        pulseaudio --system --disallow-exit --log-level=error --file=/etc/pulse/system.pa &
        PULSE_PID=$!
    fi
    
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "WARNING: Agent died, restarting..."
        /usr/local/bin/bt-agent > /dev/null 2>&1 &
        AGENT_PID=$!
    fi
    
    sleep 10
done
