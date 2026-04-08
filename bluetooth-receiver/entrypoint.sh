#!/bin/bash
set -e

DEVICE_NAME="${DEVICE_NAME:-Snapcast Receiver}"

echo "========================================="
echo "Bluetooth Receiver (bluez-alsa)"
echo "Device: $DEVICE_NAME"
echo "========================================="

# ─── 1. D-Bus ────────────────────────────────────────────────────────
echo "[1/7] Starting D-Bus..."
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --nofork --nopidfile &
sleep 2

# ─── 2. ALSA loopback + config ──────────────────────────────────────
echo "[2/7] Loading ALSA loopback..."
lsmod | grep -q snd_aloop || modprobe snd-aloop pcm_substreams=1
for i in $(seq 1 10); do aplay -l 2>/dev/null | grep -q Loopback && break; sleep 1; done

# softvol: wraps loopback playback so bluealsa-aplay has a mixer for BT volume
# dsnoop: allows drain + TCP server to share the capture side
cat > /etc/asound.conf << 'EOF'
pcm.loopout {
    type softvol
    slave.pcm "hw:Loopback,0,0"
    control {
        name "Bluetooth"
        card Loopback
    }
    min_dB -51.0
    max_dB 0.0
}

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
EOF

# ─── 3. Bluetooth daemon ────────────────────────────────────────────
echo "[3/7] Starting Bluetooth..."
mkdir -p /var/lib/bluetooth
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
JustWorksRepairing = always
AutoEnable = true

[Policy]
AutoEnable = true
EOF

/usr/libexec/bluetooth/bluetoothd -d &
BLUETOOTHD_PID=$!
sleep 3

# ─── 4. Adapter + agent ─────────────────────────────────────────────
echo "[4/7] Initializing adapter..."
hciconfig hci0 up
sleep 1

for dev in $(bluetoothctl devices Paired 2>/dev/null | awk '{print $2}'); do
    bluetoothctl trust "$dev" 2>/dev/null || true
done

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

# ─── 5. bluez-alsa ──────────────────────────────────────────────────
echo "[5/7] Starting bluez-alsa..."
bluealsad --profile=a2dp-sink &
BLUEALSA_PID=$!
sleep 2
kill -0 $BLUEALSA_PID 2>/dev/null || { echo "ERROR: bluealsad failed"; exit 1; }

# Single-device enforcer: poll for multiple connections, keep only the newest
(
    PREV_MACS=""
    while true; do
        CURR_MACS=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' | sort)
        if [ "$CURR_MACS" != "$PREV_MACS" ] && [ -n "$CURR_MACS" ]; then
            COUNT=$(echo "$CURR_MACS" | wc -w)
            if [ "$COUNT" -gt 1 ]; then
                # Find the new MAC (present now but not before)
                NEW_MAC=""
                for mac in $CURR_MACS; do
                    echo "$PREV_MACS" | grep -q "$mac" || NEW_MAC="$mac"
                done
                # Disconnect everything except the new device
                if [ -n "$NEW_MAC" ]; then
                    for mac in $CURR_MACS; do
                        if [ "$mac" != "$NEW_MAC" ]; then
                            echo "[SingleDevice] Disconnecting old device: $mac"
                            bluetoothctl disconnect "$mac" 2>/dev/null || true
                        fi
                    done
                fi
            fi
            PREV_MACS="$CURR_MACS"
        fi
        sleep 2
    done
) &

# ─── 6. Audio routing + TCP ─────────────────────────────────────────
echo "[6/7] Starting audio routing..."

# Initialize softvol mixer control with a dummy write
aplay -D loopout -d 1 /dev/zero 2>/dev/null || true
sleep 1
amixer -c Loopback -q set 'Bluetooth' 100% 2>/dev/null || true

arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null &
DRAIN_PID=$!

bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio 2>&1 | sed 's/^/[bluealsa-aplay] /' &
APLAY_PID=$!

( while true; do
    socat TCP-LISTEN:4953,reuseaddr SYSTEM:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null"
    sleep 1
done ) &
TCP_PID=$!

# ─── 7. Ready ───────────────────────────────────────────────────────
echo "========================================="
echo "Bluetooth receiver ready!"
echo "Device: ${DEVICE_NAME} | TCP: port 4953"
echo "========================================="

# ─── Watchdog ────────────────────────────────────────────────────────
restart() { echo "WATCHDOG: $1 died, restarting..."; }
while true; do
    kill -0 $BLUETOOTHD_PID 2>/dev/null || { restart bluetoothd; /usr/libexec/bluetooth/bluetoothd -d & BLUETOOTHD_PID=$!; }
    kill -0 $BLUEALSA_PID  2>/dev/null || { restart bluealsad; bluealsad --profile=a2dp-sink & BLUEALSA_PID=$!; }
    kill -0 $APLAY_PID     2>/dev/null || { restart bluealsa-aplay; bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio 2>&1 | sed 's/^/[bluealsa-aplay] /' & APLAY_PID=$!; }
    kill -0 $DRAIN_PID     2>/dev/null || { restart drain; arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null & DRAIN_PID=$!; }
    kill -0 $TCP_PID       2>/dev/null || { restart tcp; ( while true; do socat TCP-LISTEN:4953,reuseaddr SYSTEM:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null"; sleep 1; done ) & TCP_PID=$!; }

    bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes" || bluetoothctl discoverable on 2>/dev/null || true
    sleep 10
done
