#!/bin/bash
set -e

# ============================================================================
# Bluetooth A2DP Receiver with bluez-alsa
# Simple, reliable stack: BlueZ → bluez-alsa → ALSA loopback → Snapcast
# ============================================================================

DEVICE_NAME="${DEVICE_NAME:-Snapcast Receiver}"

echo "========================================="
echo "Bluetooth Receiver (bluez-alsa)"
echo "Device: $DEVICE_NAME"
echo "========================================="

# ─── 1. DBUS ────────────────────────────────────────────────────────
echo "[1/8] Starting D-Bus..."
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --nofork --nopidfile &
DBUS_PID=$!
sleep 2

# ─── 2. LOAD ALSA LOOPBACK KERNEL MODULE ────────────────────────────
echo "[2/8] Loading ALSA loopback module..."
if ! lsmod | grep -q snd_aloop; then
    modprobe snd-aloop pcm_substreams=1 || {
        echo "ERROR: Failed to load snd-aloop module"
        echo "Make sure container runs with --privileged or --cap-add=SYS_MODULE"
        exit 1
    }
fi

# Wait for loopback device to appear
for i in {1..10}; do
    if aplay -l | grep -q "Loopback"; then
        echo "ALSA loopback device ready"
        break
    fi
    sleep 1
done

# ─── 3. BLUETOOTH CONFIGURATION ──────────────────────────────────────
echo "[3/8] Configuring Bluetooth..."
mkdir -p /var/lib/bluetooth
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
FastConnectable = true
ControllerMode = dual
JustWorksRepairing = always
PageTimeout = 8192
AutoEnable = true
ReconnectAttempts = 7

[Policy]
AutoEnable = true
EOF

# ─── 4. START BLUETOOTHD ─────────────────────────────────────────────
echo "[4/8] Starting bluetoothd..."
/usr/libexec/bluetooth/bluetoothd -d &
BLUETOOTHD_PID=$!
sleep 3

# ─── 5. INITIALIZE BLUETOOTH ADAPTER ─────────────────────────────────
echo "[5/8] Initializing Bluetooth adapter..."
hciconfig hci0 up
sleep 1

# Configure adapter via bluetoothctl (non-blocking, just settings)
(
echo "power on"
sleep 1
echo "discoverable on"
sleep 1
echo "pairable on"
sleep 1
echo "quit"
) | bluetoothctl

echo "Bluetooth adapter configured"

# Start a persistent agent that stays running to handle pairing requests
# Without this, all pairing attempts are rejected
cat > /usr/local/bin/bt-agent << 'AGENTEOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl
expect "#"
send "agent NoInputNoOutput\r"
expect "#"
send "default-agent\r"
expect "#"
# Keep running forever to handle pairing requests
interact
AGENTEOF
chmod +x /usr/local/bin/bt-agent

/usr/local/bin/bt-agent &
AGENT_PID=$!
sleep 2
echo "Bluetooth agent running (PID: $AGENT_PID)"

# ─── 6. START BLUEZ-ALSA ─────────────────────────────────────────────
echo "[6/8] Starting bluez-alsa..."

# bluealsad daemon: handles Bluetooth audio
# --profile=a2dp-sink: We act as A2DP sink (receiving audio FROM phones)
bluealsad --profile=a2dp-sink &
BLUEALSA_PID=$!
sleep 2

# Check if bluealsa started successfully
if ! kill -0 $BLUEALSA_PID 2>/dev/null; then
    echo "ERROR: bluealsa failed to start"
    exit 1
fi

echo "bluealsa daemon running (PID: $BLUEALSA_PID)"

# ─── 7. CREATE AUTO-ROUTER FOR BLUETOOTH CONNECTIONS ─────────────────
echo "[7/8] Setting up automatic audio routing..."

cat > /usr/local/bin/bluealsa-autoroute.sh << 'ROUTEREOF'
#!/bin/bash
# Automatically route new Bluetooth A2DP connections to ALSA loopback
# Uses bluealsactl monitor to detect new PCMs (more reliable than bluetoothctl)

echo "[AutoRouter] Started, monitoring for Bluetooth PCMs..."

# Use bluealsactl monitor to watch for new PCM events
bluealsactl monitor 2>/dev/null | while read -r line; do
    if echo "$line" | grep -q "PCMAdded"; then
        echo "[AutoRouter] New PCM detected: $line"
        sleep 2  # Wait for transport to fully initialize
        
        # List all available PCMs and start playback for A2DP sink PCMs
        bluealsactl list-pcms 2>/dev/null | while read -r pcm; do
            if echo "$pcm" | grep -q "a2dp-sink"; then
                MAC=$(echo "$pcm" | grep -oE '([0-9A-F]{2}_){5}[0-9A-F]{2}' | tr '_' ':' | head -1)
                if [ -n "$MAC" ] && ! pgrep -f "bluealsa-aplay.*$MAC" >/dev/null 2>&1; then
                    echo "[AutoRouter] Starting playback for $MAC -> hw:Loopback,0,0"
                    bluealsa-aplay -D hw:Loopback,0,0 --single-audio "$MAC" 2>&1 | while read -r aplay_line; do
                        echo "[bluealsa-aplay] $aplay_line"
                    done &
                    echo "[AutoRouter] Audio routing active for $MAC"
                fi
            fi
        done
    elif echo "$line" | grep -q "PCMRemoved"; then
        echo "[AutoRouter] PCM removed: $line"
    fi
done
ROUTEREOF
chmod +x /usr/local/bin/bluealsa-autoroute.sh

/usr/local/bin/bluealsa-autoroute.sh &
ROUTER_PID=$!
echo "Auto-router started (PID: $ROUTER_PID)"

# ─── 8. CONFIGURE ALSA LOOPBACK ──────────────────────────────────────
echo "[8/8] Configuring ALSA loopback..."

# Create asound.conf to define a PCM device for Snapcast to capture from
cat > /etc/asound.conf << 'EOF'
# Loopback device configuration
# bluealsa-aplay writes to hw:Loopback,0,0 (playback side)
# Snapcast reads from hw:Loopback,1,0 (capture side)

pcm.snapcast {
    type hw
    card Loopback
    device 1
    subdevice 0
}

pcm.!default {
    type hw
    card Loopback
    device 0
}
EOF

# Set loopback volume to 100%
amixer -c Loopback -q set 'PCM' 100% unmute 2>/dev/null || true

echo "ALSA loopback configured for Snapcast"

# ─── 9. READY ───────────────────────────────────────────────────────
echo "========================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "ALSA device: hw:Loopback,1,0 (capture for Snapcast)"
echo ""
echo "Pair your phone and play audio"
echo "========================================="

# ─── 10. WATCHDOG LOOP ───────────────────────────────────────────────
while true; do
    if ! kill -0 $BLUETOOTHD_PID 2>/dev/null; then
        echo "WATCHDOG: bluetoothd died, restarting..."
        /usr/libexec/bluetooth/bluetoothd -d &
        BLUETOOTHD_PID=$!
    fi
    
    if ! kill -0 $BLUEALSA_PID 2>/dev/null; then
        echo "WATCHDOG: bluealsad died, restarting..."
        bluealsad --profile=a2dp-sink &
        BLUEALSA_PID=$!
    fi
    
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "WATCHDOG: BT agent died, restarting..."
        /usr/local/bin/bt-agent &
        AGENT_PID=$!
    fi
    
    if ! kill -0 $ROUTER_PID 2>/dev/null; then
        echo "WATCHDOG: Auto-router died, restarting..."
        /usr/local/bin/bluealsa-autoroute.sh &
        ROUTER_PID=$!
    fi
    
    # Re-enable discoverable if needed
    if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        bluetoothctl discoverable on 2>/dev/null || true
    fi
    
    sleep 10
done
