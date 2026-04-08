#!/bin/bash
# Exit on any error. Every background process uses || true where failure is acceptable.
set -e

# ─── Config ──────────────────────────────────────────────────────────
DEVICE_NAME="${DEVICE_NAME:-Snapcast Receiver}"
VERBOSE="${VERBOSE:-false}"

# ─── Logging ─────────────────────────────────────────────────────────
# Consistent format: [bt-receiver] message
# In non-verbose mode, noisy subprocesses are silenced and we log key events ourselves.
log()  { echo "[bt-receiver] $*"; }
logv() { [ "$VERBOSE" = "true" ] && echo "[bt-receiver] $*" || true; }

# Redirect target: verbose → stdout, normal → /dev/null
if [ "$VERBOSE" = "true" ]; then
    VOUT="/dev/stdout"
else
    VOUT="/dev/null"
fi

log "========================================="
log "Bluetooth Receiver (bluez-alsa)"
log "Device: $DEVICE_NAME | Verbose: $VERBOSE"
log "========================================="

# ─── 1. D-Bus ────────────────────────────────────────────────────────
# BlueZ and bluez-alsa communicate over D-Bus. Without it, nothing starts.
log "Starting D-Bus..."
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --nofork --nopidfile &> "$VOUT" &
sleep 2

# ─── 2. ALSA loopback + config ──────────────────────────────────────
# snd-aloop creates a virtual sound card bridging bluealsa-aplay → arecord (TCP).
log "Loading ALSA loopback..."
lsmod | grep -q snd_aloop || modprobe snd-aloop pcm_substreams=1
for i in $(seq 1 10); do aplay -l 2>/dev/null | grep -q Loopback && break; sleep 1; done

# Docker snapshots /dev at start, before modprobe. Create any missing device nodes.
for dev in /sys/class/sound/*; do
    name=$(basename "$dev")
    if [ -f "$dev/dev" ] && [ ! -e "/dev/snd/$name" ]; then
        IFS=: read -r major minor < "$dev/dev"
        mknod "/dev/snd/$name" c "$major" "$minor" 2>/dev/null || true
    fi
done

# Verify loopback is accessible
if aplay -l 2>/dev/null | grep -q Loopback; then
    log "ALSA loopback ready"
else
    log "ERROR: ALSA loopback not found"
    exit 1
fi

# softvol "loopout": wraps hw:Loopback with a "Bluetooth" mixer for phone volume control
# dsnoop "loopin": lets drain + TCP server share the capture side simultaneously
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
# bluetoothd manages the HCI adapter, pairing, and profile connections.
log "Starting Bluetooth daemon..."
mkdir -p /var/lib/bluetooth
cat > /etc/bluetooth/main.conf << BTEOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
JustWorksRepairing = always
AutoEnable = true

[Policy]
AutoEnable = true
BTEOF

# -d (debug) only in verbose mode; normal mode runs quietly
if [ "$VERBOSE" = "true" ]; then
    /usr/libexec/bluetooth/bluetoothd -d &
else
    /usr/libexec/bluetooth/bluetoothd &> /dev/null &
fi
BLUETOOTHD_PID=$!
sleep 3

# ─── 4. Adapter + agent ─────────────────────────────────────────────
# expect script auto-responds to all pairing/authorization prompts.
# --agent NoInputNoOutput → Just Works pairing (no PIN display needed).
log "Initializing adapter + agent..."
hciconfig hci0 up
sleep 1

# log_user 0 suppresses expect output in non-verbose mode.
# In verbose mode, we sed it to log_user 1 so all bluetoothctl output is visible.
cat > /tmp/bt-agent.expect << 'EXPECTEOF'
#!/usr/bin/expect -f
set timeout -1
log_user 0
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

if [ "$VERBOSE" = "true" ]; then
    sed -i 's/^log_user 0$/log_user 1/' /tmp/bt-agent.expect
    /tmp/bt-agent.expect &
else
    /tmp/bt-agent.expect &> /dev/null &
fi
AGENT_PID=$!
sleep 5
log "Adapter up — discoverable + pairable"

# ─── 5. bluez-alsa ──────────────────────────────────────────────────
# bluealsad bridges BlueZ ↔ ALSA. Decodes A2DP audio into a virtual PCM device.
log "Starting bluez-alsa..."
bluealsad --profile=a2dp-sink &> "$VOUT" &
BLUEALSA_PID=$!
sleep 2
kill -0 $BLUEALSA_PID 2>/dev/null || { log "ERROR: bluealsad failed to start"; exit 1; }

# ── Single-device enforcer ──
# Only one BT device at a time. When a second connects, the old one is disconnected.
(
    PREV_MACS=""
    while true; do
        CURR_MACS=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' | sort)
        if [ "$CURR_MACS" != "$PREV_MACS" ] && [ -n "$CURR_MACS" ]; then
            COUNT=$(echo "$CURR_MACS" | wc -w)
            if [ "$COUNT" -gt 1 ]; then
                NEW_MAC=""
                for mac in $CURR_MACS; do
                    echo "$PREV_MACS" | grep -q "$mac" || NEW_MAC="$mac"
                done
                if [ -n "$NEW_MAC" ]; then
                    for mac in $CURR_MACS; do
                        if [ "$mac" != "$NEW_MAC" ]; then
                            log "Disconnecting old device $mac (replaced by $NEW_MAC)"
                            bluetoothctl disconnect "$mac" &> /dev/null || true
                        fi
                    done
                fi
            fi
            PREV_MACS="$CURR_MACS"
        fi
        sleep 2
    done
) &

# ── Connection event logger ──
# Watches D-Bus for connect/disconnect signals and logs them cleanly.
(
    dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace=/org/bluez" 2>/dev/null | \
    while read -r line; do
        if echo "$line" | grep -q "path=/org/bluez/hci0/dev_"; then
            DEV_PATH=$(echo "$line" | grep -o '/org/bluez/hci0/dev_[^ "]*')
            DEV_MAC=$(echo "$DEV_PATH" | sed 's|.*/dev_||; s/_/:/g')
        fi
        if echo "$line" | grep -q 'string "Connected"'; then
            read -r _type_line; read -r val_line
            if echo "$val_line" | grep -q "boolean true"; then
                DEV_NAME=$(bluetoothctl info "$DEV_MAC" 2>/dev/null | grep "Name:" | sed 's/.*Name: //')
                log "Device connected: ${DEV_NAME:-unknown} ($DEV_MAC)"
            elif echo "$val_line" | grep -q "boolean false"; then
                log "Device disconnected: $DEV_MAC"
            fi
        fi
    done
) &

# ─── 6. Audio routing + TCP ─────────────────────────────────────────
# Pipeline: bluealsa-aplay → loopout (softvol) → loopback → loopin (dsnoop) → TCP
log "Starting audio routing..."

# Initialize softvol mixer control with a dummy write (must happen before bluealsa-aplay)
aplay -D loopout -d 1 /dev/zero 2>/dev/null || true
sleep 1
amixer -c Loopback -q set 'Bluetooth' 100% 2>/dev/null || true

# Drain: continuously read loopback capture → /dev/null to prevent buffer stall
arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null &
DRAIN_PID=$!

# bluealsa-aplay: reads BT audio → writes to loopout (softvol → loopback)
if [ "$VERBOSE" = "true" ]; then
    bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio 2>&1 | sed 's/^/[bluealsa-aplay] /' &
else
    bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio &> /dev/null &
fi
APLAY_PID=$!

# TCP server: Snapserver connects to port 4953 and receives raw PCM
( while true; do
    socat TCP-LISTEN:4953,reuseaddr SYSTEM:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null" 2>/dev/null
    sleep 1
done ) &
TCP_PID=$!

# ─── 7. Ready ───────────────────────────────────────────────────────
log "========================================="
log "Ready! Device: ${DEVICE_NAME} | TCP: 4953"
log "========================================="

# ─── Watchdog ────────────────────────────────────────────────────────
# Every 10s: restart crashed processes, maintain discoverable, clean stale pairings.
while true; do
    kill -0 $BLUETOOTHD_PID 2>/dev/null || { log "Restarting bluetoothd";      /usr/libexec/bluetooth/bluetoothd &> "$VOUT" & BLUETOOTHD_PID=$!; }
    kill -0 $BLUEALSA_PID  2>/dev/null || { log "Restarting bluealsad";        bluealsad --profile=a2dp-sink &> "$VOUT" & BLUEALSA_PID=$!; }
    kill -0 $APLAY_PID     2>/dev/null || { log "Restarting bluealsa-aplay";   bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio &> "$VOUT" & APLAY_PID=$!; }
    kill -0 $DRAIN_PID     2>/dev/null || { logv "Restarting drain";           arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null & DRAIN_PID=$!; }
    kill -0 $TCP_PID       2>/dev/null || { log "Restarting TCP server";       ( while true; do socat TCP-LISTEN:4953,reuseaddr SYSTEM:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null" 2>/dev/null; sleep 1; done ) & TCP_PID=$!; }

    bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes" || { logv "Re-enabling discoverable"; bluetoothctl discoverable on &> /dev/null || true; }

    # Remove paired-but-disconnected devices (stale keys block re-pairing)
    CONNECTED=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}')
    for dev in $(bluetoothctl devices Paired 2>/dev/null | awk '{print $2}'); do
        if ! echo "$CONNECTED" | grep -q "$dev"; then
            logv "Removing stale pairing: $dev"
            bluetoothctl remove "$dev" &> /dev/null || true
        fi
    done

    sleep 10
done
