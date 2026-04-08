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

# ─── 7. CONFIGURE ALSA ───────────────────────────────────────────────
echo "[7/8] Configuring ALSA..."

# asound.conf with dsnoop: allows multiple readers on loopback capture side
# (drain process keeps buffer from stalling, TCP server streams to Snapserver)
cat > /etc/asound.conf << 'EOF'
# dsnoop: shared capture device on loopback capture side
pcm.loopin {
    type dsnoop
    ipc_key 12345
    slave {
        pcm "hw:Loopback,1,0"
        format S16_LE
        rate 44100
        channels 2
    }
}

pcm.!default {
    type hw
    card Loopback
    device 0
}
EOF

amixer -c Loopback -q set 'PCM' 100% unmute 2>/dev/null || true
echo "ALSA configured"

# ─── 8. START AUDIO ROUTING + TCP STREAM ──────────────────────────────
echo "[8/8] Starting audio routing..."

# Drain: always read loopback capture to prevent buffer stall.
# Without this, if no TCP client is connected, the capture buffer fills,
# bluealsa-aplay write-stalls, and BT disconnects.
arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null &
DRAIN_PID=$!
echo "Loopback drain started (PID: $DRAIN_PID)"

# bluealsa-aplay: routes BT audio to ALSA loopback playback side
bluealsa-aplay -D hw:Loopback,0,0 --single-audio 2>&1 | while read -r line; do
    echo "[bluealsa-aplay] $line"
done &
APLAY_PID=$!
echo "bluealsa-aplay started (PID: $APLAY_PID)"

# TCP audio server on port 4953 for Snapserver (mode=client connects here).
# socat spawns arecord on connection; loop handles reconnections.
(
    while true; do
        echo "[TCP] Waiting for Snapserver on port 4953..."
        socat TCP-LISTEN:4953,reuseaddr EXEC:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null"
        echo "[TCP] Connection closed, restarting..."
        sleep 1
    done
) &
TCP_PID=$!
echo "TCP audio server on port 4953 (PID: $TCP_PID)"

# ─── 9. READY ───────────────────────────────────────────────────────
echo "========================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "TCP stream: port 4953 (for Snapserver)"
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
    
    if ! kill -0 $DRAIN_PID 2>/dev/null; then
        echo "WATCHDOG: drain died, restarting..."
        arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null &
        DRAIN_PID=$!
    fi
    
    if ! kill -0 $TCP_PID 2>/dev/null; then
        echo "WATCHDOG: TCP server died, restarting..."
        (
            while true; do
                echo "[TCP] Waiting for Snapserver on port 4953..."
                socat TCP-LISTEN:4953,reuseaddr EXEC:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null"
                echo "[TCP] Connection closed, restarting..."
                sleep 1
            done
        ) &
        TCP_PID=$!
    fi
    
    # Re-enable discoverable if needed
    if ! bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes"; then
        bluetoothctl discoverable on 2>/dev/null || true
    fi
    
    sleep 10
done
