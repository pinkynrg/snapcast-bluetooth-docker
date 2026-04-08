#!/bin/bash
# Bluetooth Receiver Entrypoint
# See DECISIONS.md for why things are done this way.
# Do NOT use set -e: bluetoothctl commands fail transiently and that's OK.

# Timestamp all output
exec > >(while IFS= read -r line; do echo "[$(date "+%H:%M:%S")] $line"; done) 2>&1

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
# Run in debug mode (-d) to see exactly why BlueZ releases the transport.
# Write to a log file and tail it — piping directly eats output.
mkdir -p /var/log
/usr/libexec/bluetooth/bluetoothd -d --noplugin=hfp_hf,hfp_ag >/var/log/bluetoothd.log 2>&1 &
BLUETOOTHD_PID=$!
echo "bluetoothd started in DEBUG mode (PID: $BLUETOOTHD_PID)"
tail -f /var/log/bluetoothd.log 2>/dev/null | while IFS= read -r line; do echo "[bluetoothd] $line"; done &
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
# Watch key BlueZ property changes (Connected, State, ServicesResolved, profiles)
cat > /usr/local/bin/bt-monitor.sh << 'MONEOF'
#!/bin/bash
ts() { date "+%H:%M:%S.%3N"; }

dbus-monitor --system "interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace=/org/bluez" 2>&1 | while IFS= read -r line; do
    # Track the object path for context
    if echo "$line" | grep -q "path=/org/bluez/"; then
        current_path=$(echo "$line" | grep -oP 'path=/org/bluez/\K[^ ;]+')
    fi
    # Log the interface being changed
    if echo "$line" | grep -q 'string "org.bluez.'; then
        iface=$(echo "$line" | grep -oP 'string "\K[^"]*')
        echo "[$(ts)] [dbus] === $current_path: $iface ==="
    fi
    # Log every property name and value
    if echo "$line" | grep -q 'string "'; then
        prop=$(echo "$line" | grep -oP 'string "\K[^"]*')
        # Skip interface names (already printed)
        if ! echo "$prop" | grep -q 'org.bluez'; then
            echo "[$(ts)] [dbus]   property: $prop"
        fi
    fi
    if echo "$line" | grep -qE 'variant|boolean|uint|int32|string "[a-z]'; then
        val=$(echo "$line" | sed 's/^[[:space:]]*//')
        echo "[$(ts)] [dbus]   value: $val"
    fi
done
MONEOF
chmod +x /usr/local/bin/bt-monitor.sh
/usr/local/bin/bt-monitor.sh &
MONITOR_PID=$!
echo "Connection monitor started"

# ─── 8b. BTMON (HCI-level protocol trace) ────────────────────────────
# btmon shows HCI packets. Filter OUT audio data (PSM 25 / ACL Data flood)
# to only see control events: connections, disconnections, errors, AVDTP signaling.
if command -v btmon >/dev/null 2>&1; then
    btmon 2>&1 > /var/log/btmon.log &
    BTMON_PID=$!
    echo "btmon started (full trace in /var/log/btmon.log, PID: $BTMON_PID)"
    # Filtered tail: exclude audio data, show only control/signaling events
    tail -f /var/log/btmon.log 2>/dev/null | grep --line-buffered -v -E 'ACL Data (RX|TX):|Channel: [0-9]+ len [0-9]+ \[PSM 25|^\s+Channel:' | while IFS= read -r line; do echo "[btmon] $line"; done &
else
    echo "WARNING: btmon not found, no HCI-level tracing"
    BTMON_PID=0
fi

sleep 2

# ─── 9. PULSEAUDIO ──────────────────────────────────────────────────
pulseaudio --kill 2>/dev/null || true
killall -9 pulseaudio 2>/dev/null || true
rm -rf /var/run/pulse /tmp/pulse-* 2>/dev/null || true
sleep 1
# Grant PA (pulse user) access to BlueZ D-Bus methods.
# Without this, TryAcquire/Acquire on MediaTransport1 fails silently
# (D-Bus returns "method doesn't exist" to mask the permission denial).
usermod -aG bluetooth pulse 2>/dev/null || true
mkdir -p /etc/dbus-1/system.d
cat > /etc/dbus-1/system.d/pulseaudio-bluetooth.conf << 'DBUSEOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="pulse">
    <allow send_destination="org.bluez"/>
  </policy>
</busconfig>
DBUSEOF
# Reload D-Bus to pick up the new policy
dbus-send --system --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig 2>/dev/null || true
echo "D-Bus policy updated: pulse user can access org.bluez"
# Disable default PulseAudio configs (we use custom.pa exclusively via -n flag)
mv /etc/pulse/default.pa /etc/pulse/default.pa.disabled 2>/dev/null || true
mv /etc/pulse/system.pa /etc/pulse/system.pa.disabled 2>/dev/null || true

mkdir -p /etc/pulse
cat > /etc/pulse/custom.pa << 'EOF'
load-module module-native-protocol-unix auth-anonymous=1
load-module module-null-sink sink_name=tcp_out rate=44100 channels=2
load-module module-simple-protocol-tcp rate=44100 format=s16le channels=2 source=tcp_out.monitor port=4953 listen=0.0.0.0 record=true
load-module module-bluetooth-policy auto_switch=false
load-module module-bluetooth-discover headset=ofono
set-default-sink tcp_out
set-default-source tcp_out.monitor
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

pulseaudio --system --disallow-exit --log-level=info -n --file=/etc/pulse/custom.pa &
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
# Record current dmesg line count so we only check NEW errors, not stale ones from before startup.
DMESG_START=$(dmesg | wc -l)

while true; do
    if ! kill -0 $BLUETOOTHD_PID 2>/dev/null; then
        echo "WATCHDOG: bluetoothd died, restarting..."
        /usr/libexec/bluetooth/bluetoothd -d --noplugin=hfp_hf,hfp_ag >/var/log/bluetoothd.log 2>&1 &
        BLUETOOTHD_PID=$!
        tail -f /var/log/bluetoothd.log 2>/dev/null | while IFS= read -r line; do echo "[bluetoothd] $line"; done &
    fi

    if ! kill -0 $PULSE_PID 2>/dev/null; then
        echo "WATCHDOG: PulseAudio died, restarting..."
        pulseaudio --system --disallow-exit --log-level=info -n --file=/etc/pulse/custom.pa &
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

    # Re-enable discoverable if it turned off (BlueZ can silently disable it after disconnect)
    if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        echo "WATCHDOG: Not discoverable, re-enabling..."
        bluetoothctl discoverable on 2>/dev/null || true
    fi

    # Check for BT hardware lock-up (tx timeout in dmesg = BCM43430A1 is stuck)
    # Only check lines written AFTER container startup to avoid stale errors triggering on boot.
    if dmesg | tail -n "+${DMESG_START}" | grep -q "hci0: command.*tx timeout"; then
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
        /usr/libexec/bluetooth/bluetoothd -d --noplugin=hfp_hf,hfp_ag >/var/log/bluetoothd.log 2>&1 &
        BLUETOOTHD_PID=$!
        tail -f /var/log/bluetoothd.log 2>/dev/null | while IFS= read -r line; do echo "[bluetoothd] $line"; done &
        sleep 3
        
        bluetoothctl power on 2>/dev/null || true
        sleep 1
        bluetoothctl discoverable on 2>/dev/null || true
        sleep 1
        bluetoothctl pairable on 2>/dev/null || true
        
        pulseaudio --system --disallow-exit --log-level=info -n --file=/etc/pulse/custom.pa &
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
