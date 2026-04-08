#!/bin/bash
# Exit on any error. Every background process uses || true where failure is acceptable.
set -e

# ─── Config ──────────────────────────────────────────────────────────
DEVICE_NAME="${DEVICE_NAME:-Snapcast Receiver}"
VERBOSE="${VERBOSE:-false}"
INIT_VOLUME="${INIT_VOLUME:-50}"

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
# plug "loopout_plug": resamples any input rate (e.g. 48kHz from Mac) to 44100 for the loopback
# dsnoop "loopin": lets drain + TCP server share the capture side simultaneously
cat > /etc/asound.conf << 'EOF'
pcm.loopout {
    type softvol
    slave.pcm "loopout_plug"
    control {
        name "Bluetooth"
        card Loopback
    }
    min_dB -51.0
    max_dB 0.0
}

pcm.loopout_plug {
    type plug
    slave {
        pcm "hw:Loopback,0,0"
        format S16_LE
        rate 44100
        channels 2
    }
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
# Also logs every connection change.
get_dev_name() { bluetoothctl info "$1" 2>/dev/null | grep "Name:" | sed 's/.*Name: //' ; }
(
    set +e
    PREV_MACS=""
    while true; do
        CURR_MACS=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' | grep -E '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' | sort)
        if [ "$CURR_MACS" != "$PREV_MACS" ]; then
            # Log new connections
            for mac in $CURR_MACS; do
                if [ -z "$PREV_MACS" ] || ! echo "$PREV_MACS" | grep -q "$mac"; then
                    NAME=$(get_dev_name "$mac")
                    log "Device connected: ${NAME:-$mac}"
                fi
            done
            # Log disconnections
            for mac in $PREV_MACS; do
                if [ -z "$CURR_MACS" ] || ! echo "$CURR_MACS" | grep -q "$mac"; then
                    NAME=$(get_dev_name "$mac")
                    log "Device disconnected: ${NAME:-$mac}"
                fi
            done
            # Evict old device if two are connected
            COUNT=$(echo "$CURR_MACS" | grep -c . 2>/dev/null || true)
            if [ "$COUNT" -gt 1 ]; then
                NEW_MAC=""
                for mac in $CURR_MACS; do
                    echo "$PREV_MACS" | grep -q "$mac" || NEW_MAC="$mac"
                done
                if [ -n "$NEW_MAC" ]; then
                    NEW_NAME=$(get_dev_name "$NEW_MAC")
                    for mac in $CURR_MACS; do
                        if [ "$mac" != "$NEW_MAC" ]; then
                            OLD_NAME=$(get_dev_name "$mac")
                            log "Evicting ${OLD_NAME:-$mac} (replaced by ${NEW_NAME:-$NEW_MAC})"
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

# ── Now-playing + volume + playback status monitor ──
# Polls mixer for volume changes, and AVRCP MediaPlayer1 for track + status.
get_player_props() {
    local mac="$1"
    local dev_path="/org/bluez/hci0/dev_${mac//:/_}"
    # Player path can be player0, player1, etc. — discover dynamically.
    local player_path
    player_path=$(dbus-send --system --dest=org.bluez --print-reply / \
        org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null \
        | grep -o "${dev_path}/player[0-9]*" | head -1) || true
    [ -z "$player_path" ] && return 1
    dbus-send --system --dest=org.bluez --print-reply "$player_path" \
        org.freedesktop.DBus.Properties.GetAll string:org.bluez.MediaPlayer1 2>/dev/null || true
}
get_now_playing() {
    local props="$1"
    local artist title
    artist=$(echo "$props" | grep -A2 '"Artist"' | grep 'variant' | sed 's/.*string "//;s/"$//')
    title=$(echo "$props" | grep -A2 '"Title"' | grep 'variant' | sed 's/.*string "//;s/"$//')
    if [ -n "$title" ]; then
        [ -n "$artist" ] && echo "$artist — $title" || echo "$title"
    fi
}
get_player_status() {
    local props="$1"
    echo "$props" | grep -A1 '"Status"' | grep 'variant' | sed 's/.*string "//;s/"$//'
}
(
    set +e
    PREV_VOL=""
    PREV_TRACK=""
    PREV_STATUS=""
    while true; do
        # Get connected device for context
        CON_MAC=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' | grep -E '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' | head -1)
        CON_NAME=""
        if [ -n "$CON_MAC" ]; then
            CON_NAME=$(get_dev_name "$CON_MAC")
        fi
        DEV_LABEL="${CON_NAME:-unknown}"

        # Volume
        CURR_VOL=$(amixer -c Loopback sget 'Bluetooth' 2>/dev/null | grep -o '[0-9]*%' | head -1)
        if [ -n "$CURR_VOL" ] && [ "$CURR_VOL" != "$PREV_VOL" ]; then
            [ -n "$PREV_VOL" ] && log "Volume: $CURR_VOL ($DEV_LABEL)"
            PREV_VOL="$CURR_VOL"
        fi

        # Track + status from AVRCP
        if [ -n "$CON_MAC" ]; then
            PROPS=$(get_player_props "$CON_MAC" 2>/dev/null)
            if [ -n "$PROPS" ]; then
                CURR_TRACK=$(get_now_playing "$PROPS")
                CURR_STATUS=$(get_player_status "$PROPS")

                if [ -n "$CURR_TRACK" ] && [ "$CURR_TRACK" != "$PREV_TRACK" ]; then
                    log "Now playing: $CURR_TRACK ($DEV_LABEL)"
                    PREV_TRACK="$CURR_TRACK"
                fi

                if [ -n "$CURR_STATUS" ] && [ "$CURR_STATUS" != "$PREV_STATUS" ]; then
                    case "$CURR_STATUS" in
                        playing)       log "Playback resumed ($DEV_LABEL)" ;;
                        paused)        log "Playback paused ($DEV_LABEL)" ;;
                        stopped)       log "Playback stopped ($DEV_LABEL)" ;;
                        forward-seek)  log "Seeking forward ($DEV_LABEL)" ;;
                        reverse-seek)  log "Seeking backward ($DEV_LABEL)" ;;
                        *)             log "Playback status: $CURR_STATUS ($DEV_LABEL)" ;;
                    esac
                    PREV_STATUS="$CURR_STATUS"
                fi
            fi
        else
            PREV_TRACK=""
            PREV_STATUS=""
        fi
        sleep 2
    done
) &

# ─── 6. Audio routing + TCP ─────────────────────────────────────────
# Pipeline: bluealsa-aplay → loopout (softvol) → loopback → loopin (dsnoop) → TCP
log "Starting audio routing..."

# Initialize softvol mixer control with a dummy write (must happen before bluealsa-aplay)
aplay -D loopout -d 1 /dev/zero 2>/dev/null || true
sleep 1
amixer -c Loopback -q set 'Bluetooth' "${INIT_VOLUME}%" 2>/dev/null || true
log "Initial volume: ${INIT_VOLUME}%"

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
