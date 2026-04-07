#!/bin/bash
# Bluetooth Receiver Entrypoint
# See DECISIONS.md for why things are done this way.
# Do NOT use set -e: bluetoothctl commands fail transiently and that's OK.

echo "Starting Bluetooth receiver..."

# ─── 1. CHECK HARDWARE ────────────────────────────────────────────────
if ! ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    echo "ERROR: No Bluetooth adapter found!"
    echo "Make sure host Bluetooth service is stopped: sudo systemctl stop bluetooth.service"
    exit 1
fi
echo "Bluetooth adapter found: $(ls /sys/class/bluetooth/)"

# ─── 2. CONFIGURE BLUETOOTH ──────────────────────────────────────────
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
PairableTimeout = 0
FastConnectable = true
ControllerMode = dual
JustWorksRepairing = always

[BR]
PageTimeout = 8192

[Policy]
AutoEnable = true
ReconnectAttempts = 7
ReconnectIntervals = 1,2,4,8,16,32,64
EOF
echo "Bluetooth configured"

# ─── 3. START DBUS ───────────────────────────────────────────────────
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --fork
echo "D-Bus started"
sleep 1

# ─── 4. START BLUETOOTHD ─────────────────────────────────────────────
/usr/libexec/bluetooth/bluetoothd &
BLUETOOTHD_PID=$!
echo "bluetoothd started (PID: $BLUETOOTHD_PID)"
sleep 3

# ─── 5. WAIT FOR CONTROLLER ─────────────────────────────────────────
TIMEOUT=30
ELAPSED=0
while ! bluetoothctl show >/dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Bluetooth controller not available after ${TIMEOUT}s"
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo "Bluetooth controller ready"

# ─── 6. MAKE DISCOVERABLE (with retries) ────────────────────────────
# bluetoothctl can fail if a previously paired device triggers events.
# Retry until bluetoothctl show confirms Discoverable: yes.
for attempt in 1 2 3 4 5; do
    bluetoothctl power on 2>/dev/null || true
    sleep 1
    bluetoothctl discoverable on 2>/dev/null || true
    sleep 1
    bluetoothctl pairable on 2>/dev/null || true
    sleep 1

    if bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        echo "Bluetooth is discoverable and pairable"
        break
    fi
    echo "Bluetooth setup attempt $attempt failed, retrying..."
    sleep 2
done

if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
    echo "WARNING: Bluetooth may not be discoverable"
fi

# ─── 7. AUTO-PAIR AGENT (expect) ────────────────────────────────────
# expect gives us a real TTY for bluetoothctl, which is required for the
# agent to stay running. This worked reliably for a month.
cat > /usr/local/bin/bt-agent << 'AGENTEOF'
#!/usr/bin/expect -f
set timeout -1
log_user 0

proc agent_loop {} {
    spawn bluetoothctl
    expect {
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
        "Agent is already registered" {
            send "default-agent\r"
            expect -re ".*#"
        }
        "Failed to register" {
            after 5000
            return
        }
    }

    # Auto-accept everything forever
    while {1} {
        expect {
            "*Confirm passkey*yes/no*"   { send "yes\r" }
            "*Accept pairing*yes/no*"    { send "yes\r" }
            "*Authorize service*yes/no*" { send "yes\r" }
            "*yes/no*"                   { send "yes\r" }
            eof                          { break }
            timeout                      { continue }
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
echo "Auto-pair agent started"

# ─── 8. CONNECTION MONITOR (dbus-monitor) ────────────────────────────
# dbus-monitor doesn't need a TTY, runs forever, and reliably catches events.
cat > /usr/local/bin/bt-monitor.sh << 'MONEOF'
#!/bin/bash
dbus-monitor --system "interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace=/org/bluez" 2>&1 | while IFS= read -r line; do
    if echo "$line" | grep -q "path=/org/bluez/hci0/dev_"; then
        current_mac=$(echo "$line" | grep -oP "dev_\K[A-F0-9_]+" | tr '_' ':')
    fi
    if echo "$line" | grep -q '"Connected"'; then
        read -r val
        if echo "$val" | grep -q "true"; then
            echo "Bluetooth: Connected - ${current_mac:-unknown}"
        elif echo "$val" | grep -q "false"; then
            echo "Bluetooth: Disconnected - ${current_mac:-unknown}"
        fi
    fi
done
MONEOF
chmod +x /usr/local/bin/bt-monitor.sh
/usr/local/bin/bt-monitor.sh &
MONITOR_PID=$!
echo "Connection monitor started"

sleep 2

# ─── 9. PULSEAUDIO ──────────────────────────────────────────────────
pulseaudio --kill 2>/dev/null || true
killall -9 pulseaudio 2>/dev/null || true
rm -rf /var/run/pulse /tmp/pulse-* 2>/dev/null || true
sleep 1

# Disable default PulseAudio configs (we use custom.pa exclusively via -n flag)
mv /etc/pulse/default.pa /etc/pulse/default.pa.disabled 2>/dev/null || true
mv /etc/pulse/system.pa /etc/pulse/system.pa.disabled 2>/dev/null || true

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

cat > /etc/pulse/daemon.conf << 'EOF'
daemonize = no
high-priority = yes
nice-level = -11
realtime-scheduling = yes
realtime-priority = 5
exit-idle-time = -1
default-sample-format = s16le
default-sample-rate = 44100
default-sample-channels = 2
default-fragments = 8
default-fragment-size-msec = 10
EOF

pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
PULSE_PID=$!
echo "PulseAudio started (PID: $PULSE_PID)"
sleep 3

# ─── 10. READY ──────────────────────────────────────────────────────
echo "====================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "TCP port: 4953"
echo "====================================="

# ─── 11. WATCHDOG LOOP ──────────────────────────────────────────────
while true; do
    if ! kill -0 $BLUETOOTHD_PID 2>/dev/null; then
        echo "WATCHDOG: bluetoothd died, restarting..."
        /usr/libexec/bluetooth/bluetoothd &
        BLUETOOTHD_PID=$!
    fi

    if ! kill -0 $PULSE_PID 2>/dev/null; then
        echo "WATCHDOG: PulseAudio died, restarting..."
        pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
        PULSE_PID=$!
    fi

    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "WATCHDOG: Agent died, restarting..."
        /usr/local/bin/bt-agent &
        AGENT_PID=$!
    fi

    if ! kill -0 $MONITOR_PID 2>/dev/null; then
        echo "WATCHDOG: Monitor died, restarting..."
        /usr/local/bin/bt-monitor.sh &
        MONITOR_PID=$!
    fi

    # Check for BT hardware lock-up (tx timeout in dmesg = BCM43430A1 is stuck)
    # The container runs --privileged so it can reset kernel modules
    if dmesg | tail -30 | grep -q "hci0: command.*tx timeout"; then
        echo "WATCHDOG: BT hardware stuck (tx timeout detected), resetting..."
        
        kill $BLUETOOTHD_PID 2>/dev/null || true
        kill $PULSE_PID 2>/dev/null || true
        kill $AGENT_PID 2>/dev/null || true
        kill $MONITOR_PID 2>/dev/null || true
        
        hciconfig hci0 down 2>/dev/null || true
        rmmod btbcm 2>/dev/null || true
        rmmod hci_uart 2>/dev/null || true
        sleep 3
        modprobe hci_uart
        modprobe btbcm
        sleep 2
        hciconfig hci0 up
        sleep 2
        
        echo "WATCHDOG: Hardware reset done, restarting services..."
        /usr/libexec/bluetooth/bluetoothd &
        BLUETOOTHD_PID=$!
        sleep 3
        
        bluetoothctl power on 2>/dev/null || true
        sleep 1
        bluetoothctl discoverable on 2>/dev/null || true
        sleep 1
        bluetoothctl pairable on 2>/dev/null || true
        
        pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
        PULSE_PID=$!
        /usr/local/bin/bt-agent &
        AGENT_PID=$!
        /usr/local/bin/bt-monitor.sh &
        MONITOR_PID=$!
        
        echo "WATCHDOG: Recovery complete"
        sleep 60
        continue
    fi

    sleep 10
done
