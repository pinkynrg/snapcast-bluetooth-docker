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

# Create an expect script that runs bluetoothctl as our Bluetooth agent.
# It pattern-matches all interactive prompts and auto-responds "yes".
# (No FIFO, no interact, no TTY needed — just expect's core match loop.)
cat > /tmp/bt-agent.expect << 'EXPECTEOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl --agent NoInputNoOutput
expect "Agent registered"
send "power on\r"
expect "succeeded"
send "discoverable on\r"
expect "succeeded"
send "pairable on\r"
expect "succeeded"
# Sit forever, auto-accepting any prompt BlueZ throws at us
while {1} {
    expect {
        "Authorize service*"       { send "yes\r" }
        "Request confirmation*"    { send "yes\r" }
        "Confirm passkey*"         { send "yes\r" }
        "Enter passkey*"           { send "0000\r" }
        "Request PIN*"             { send "0000\r" }
        "Accept*"                  { send "yes\r" }
        eof                        { break }
    }
}
EXPECTEOF
chmod +x /tmp/bt-agent.expect

/tmp/bt-agent.expect &
AGENT_PID=$!
sleep 5
echo "Bluetooth adapter + agent ready (PID: $AGENT_PID)"

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

# ─── 7. START AUDIO PLAYBACK ──────────────────────────────────────────
echo "[7/8] Starting audio routing..."

# bluealsa-aplay without a MAC address automatically handles ALL connecting
# devices. --single-audio plays one device at a time. No custom router needed.
bluealsa-aplay -D hw:Loopback,0,0 --single-audio 2>&1 | while read -r line; do
    echo "[bluealsa-aplay] $line"
done &
APLAY_PID=$!
echo "bluealsa-aplay started (PID: $APLAY_PID)"

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
    
    if ! kill -0 $APLAY_PID 2>/dev/null; then
        echo "WATCHDOG: bluealsa-aplay died, restarting..."
        bluealsa-aplay -D hw:Loopback,0,0 --single-audio 2>&1 | while read -r line; do
            echo "[bluealsa-aplay] $line"
        done &
        APLAY_PID=$!
    fi
    
    # Re-enable discoverable if needed
    if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        bluetoothctl discoverable on 2>/dev/null || true
    fi
    
    sleep 10
done
