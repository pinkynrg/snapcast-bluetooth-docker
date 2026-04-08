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

# Use bluetoothctl in non-blocking mode by piping commands
(
echo "power on"
sleep 1
echo "discoverable on"
sleep 1
echo "pairable on"
sleep 1
echo "agent NoInputNoOutput"
sleep 1
echo "default-agent"
sleep 1
echo "quit"
) | bluetoothctl

echo "Bluetooth adapter ready"

# ─── 6. START BLUEZ-ALSA ─────────────────────────────────────────────
echo "[6/8] Starting bluez-alsa..."

# bluealsa daemon: handles Bluetooth audio
# --profile=a2dp-source: We're receiving audio FROM phones (A2DP source)
bluealsa --profile=a2dp-source &
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
# This script monitors D-Bus for new connections and starts bluealsa-aplay

echo "[AutoRouter] Started, monitoring for Bluetooth connections..."

# Monitor bluetoothctl for device connections
bluetoothctl | while read -r line; do
    # Look for device connection events
    if echo "$line" | grep -iq "Device.*Connected: yes"; then
        MAC=$(echo "$line" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1)
        if [ -n "$MAC" ]; then
            echo "[AutoRouter] Device connected: $MAC"
            sleep 2  # Wait for A2DP profile to negotiate
            
            # Check if this device supports A2DP source profile
            if bluealsa-cli list-pcms | grep -q "$MAC"; then
                echo "[AutoRouter] A2DP source detected, starting playback..."
                
                # Kill any existing bluealsa-aplay for this device
                pkill -f "bluealsa-aplay.*$MAC" 2>/dev/null || true
                sleep 1
                
                # Start bluealsa-aplay to route audio from Bluetooth to ALSA loopback (hw:Loopback,1,0)
                # hw:Loopback,1,0 = Loopback card, device 1, subdevice 0 (playback side)
                bluealsa-aplay -v --pcm-buffer-time=500000 --pcm-period-time=100000 --single-audio "$MAC" | while read -r aplay_line; do
                    echo "[bluealsa-aplay] $aplay_line"
                done &
                
                echo "[AutoRouter] Audio routing active for $MAC"
            fi
        fi
    elif echo "$line" | grep -iq "Device.*Connected: no"; then
        MAC=$(echo "$line" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -1)
        if [ -n "$MAC" ]; then
            echo "[AutoRouter] Device disconnected: $MAC, stopping playback..."
            pkill -f "bluealsa-aplay.*$MAC" 2>/dev/null || true
        fi
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
# bluealsa-aplay writes to hw:Loopback,1,0 (playback)
# Snapcast reads from hw:Loopback,0,0 (capture)

pcm.snapcast {
    type hw
    card Loopback
    device 0
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
echo "ALSA device: hw:Loopback,0,0"
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
        echo "WATCHDOG: bluealsa died, restarting..."
        bluealsa --profile=a2dp-source &
        BLUEALSA_PID=$!
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
