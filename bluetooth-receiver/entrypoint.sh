#!/bin/bash
# Exit on any error. Every background process uses || true where failure is acceptable.
set -e

# Bluetooth device name visible to phones/computers scanning for devices.
# Can be overridden via DEVICE_NAME env var in docker-compose.yml.
DEVICE_NAME="${DEVICE_NAME:-Snapcast Receiver}"

echo "========================================="
echo "Bluetooth Receiver (bluez-alsa)"
echo "Device: $DEVICE_NAME"
echo "========================================="

# ─── 1. D-Bus ────────────────────────────────────────────────────────
# BlueZ (bluetoothd) and bluez-alsa (bluealsad) communicate over D-Bus.
# Without a running system bus, neither can start.
echo "[1/7] Starting D-Bus..."
mkdir -p /var/run/dbus          # Socket directory (may not exist in minimal container)
rm -f /var/run/dbus/pid         # Stale PID file from a previous run would prevent startup
dbus-daemon --system --nofork --nopidfile &
sleep 2                         # Wait for the bus socket to be ready

# ─── 2. ALSA loopback + config ──────────────────────────────────────
# The ALSA loopback kernel module (snd-aloop) creates a virtual sound card with two
# sides: what you write to side 0 appears as audio on side 1, and vice versa.
# This is how we bridge bluealsa-aplay (writes BT audio) to arecord (reads it for TCP).
#   pcm_substreams=1 — we only need one substream pair, not the default 8.
echo "[2/7] Loading ALSA loopback..."
lsmod | grep -q snd_aloop || modprobe snd-aloop pcm_substreams=1
# Wait up to 10 seconds for the Loopback card to appear in ALSA's device list.
for i in $(seq 1 10); do aplay -l 2>/dev/null | grep -q Loopback && break; sleep 1; done

# Docker snapshots /dev at container start. If modprobe loaded snd-aloop AFTER start,
# the Loopback device nodes (pcmC2D0p, pcmC2D0c, etc.) won't exist in /dev/snd/.
# Fix: read /sys/class/sound/ (always up-to-date) and create any missing char devices.
for dev in /sys/class/sound/*; do
    name=$(basename "$dev")
    if [ -f "$dev/dev" ] && [ ! -e "/dev/snd/$name" ]; then
        IFS=: read -r major minor < "$dev/dev"
        mknod "/dev/snd/$name" c "$major" "$minor" 2>/dev/null || true
    fi
done

# ALSA configuration — defines two virtual PCM devices used throughout the script:
#
# "loopout" (softvol plugin):
#   Wraps hw:Loopback,0,0 (playback side 0) with a software volume control named
#   "Bluetooth" on the Loopback card. This is what bluealsa-aplay writes to.
#   When the phone changes volume, bluealsa-aplay adjusts this mixer, and the
#   actual PCM amplitude changes before it hits the loopback.
#   Range: -51dB (silent) to 0dB (full volume).
#
# "loopin" (dsnoop plugin):
#   Wraps hw:Loopback,1,0 (capture side 1 — receives whatever was written to side 0).
#   dsnoop allows multiple processes to read from the same capture device simultaneously.
#   We need this because TWO things read from the loopback capture:
#     1. The drain process (arecord > /dev/null) — prevents buffer stall when no TCP client
#     2. The TCP server (socat > arecord) — sends audio to Snapserver
#   Without dsnoop, only one could open the device at a time.
#   ipc_key 12345 — shared memory key so both readers coordinate.
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
# bluetoothd is the BlueZ daemon — manages the HCI adapter, handles pairing,
# service discovery, and profile connections. Everything BT goes through it.
echo "[3/7] Starting Bluetooth..."
mkdir -p /var/lib/bluetooth     # Persistent storage for pairing keys (mapped to Docker volume)
# Write BlueZ main config:
#   Name — what shows up when phones scan
#   Class 0x200414 — "Audio" major class + "Loudspeaker" minor (so phones show a speaker icon)
#   DiscoverableTimeout 0 — stay discoverable forever (never hide)
#   JustWorksRepairing always — re-pair without user confirmation if keys are lost
#   AutoEnable true — power on the adapter automatically at startup
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

# Start bluetoothd in debug mode (-d) so errors show in container logs.
# Runs in background; PID saved for watchdog monitoring.
/usr/libexec/bluetooth/bluetoothd -d &
BLUETOOTHD_PID=$!
sleep 3                         # Wait for bluetoothd to register on D-Bus

# ─── 4. Adapter + agent ─────────────────────────────────────────────
# The BT adapter (hci0) needs to be UP, and we need a "pairing agent" that
# automatically responds to pairing/authorization prompts from bluetoothctl.
echo "[4/7] Initializing adapter..."
hciconfig hci0 up               # Bring up the HCI adapter (may already be up from AutoEnable)
sleep 1

# The expect script solves a critical problem: bluetoothctl is interactive and prompts
# for confirmation on pairing ("Confirm passkey?"), service authorization ("Authorize
# service?"), etc. Without an agent responding, connections hang and eventually fail.
#
# Why expect and not a FIFO or bt-agent?
#   - FIFO: bluetoothctl reads stdin but "Authorize service" needs a "yes" response
#     that can't be pre-piped (it arrives asynchronously).
#   - bt-agent (bluez-tools): daemon mode is broken per upstream README.
#   - expect: pattern-matches output lines and sends responses. Works perfectly.
#
# --agent NoInputNoOutput: tells BlueZ this device has no display/keyboard, so it
# uses "Just Works" pairing (no PIN display). Without this, BlueZ might ask the
# user to confirm a 6-digit passkey on a screen that doesn't exist.
#
# The while loop runs forever, matching any prompt bluetoothctl produces:
#   "Authorize service" — a device wants to use A2DP sink. Must say yes or audio won't work.
#   "Request confirmation" — pairing confirmation. Must say yes.
#   "Confirm passkey" — SSP passkey confirmation. Must say yes.
#   "Enter passkey" / "Request PIN" — legacy pairing. Send 0000.
#   "Accept" — any other acceptance prompt. Say yes.
#   eof — bluetoothctl died. Break out (watchdog will notice).
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
sleep 5                         # Wait for power/discoverable/pairable to complete

# ─── 5. bluez-alsa ──────────────────────────────────────────────────
# bluealsad is the bluez-alsa daemon. It bridges BlueZ (Bluetooth) and ALSA (audio).
# When a phone streams A2DP audio, bluealsad decodes the SBC/AAC stream and makes
# it available as a virtual ALSA PCM device that bluealsa-aplay can read from.
#   --profile=a2dp-sink — we are an A2DP sink (receive audio), not a source.
echo "[5/7] Starting bluez-alsa..."
bluealsad --profile=a2dp-sink &
BLUEALSA_PID=$!
sleep 2
# Verify bluealsad is still running. If it crashed (missing libs, D-Bus errors),
# there's no point continuing — nothing else will work without it.
kill -0 $BLUEALSA_PID 2>/dev/null || { echo "ERROR: bluealsad failed"; exit 1; }

# ── Single-device enforcer ──
# Only allow one Bluetooth device connected at a time. When a second phone connects,
# the older one gets disconnected. This prevents audio conflicts (two phones trying
# to stream simultaneously) and keeps things simple for a single-speaker setup.
#
# How it works:
#   - Every 2 seconds, poll bluetoothctl for the list of connected MAC addresses.
#   - If the list changed AND there are now >1 devices connected:
#     - Figure out which MAC is new (wasn't in the previous list).
#     - Disconnect everything except the new one.
#   - PREV_MACS tracks the last known state so we can diff.
#
# Edge case: if both devices connected simultaneously (both new), NEW_MAC will be
# the last one iterated (sorted order). Acceptable — one gets kept either way.
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
# This section wires up the complete audio pipeline:
#   Phone → BlueZ → bluealsad → bluealsa-aplay → loopout (softvol) →
#   hw:Loopback,0,0 → hw:Loopback,1,0 → loopin (dsnoop) →
#   arecord → socat TCP:4953 → Snapserver
echo "[6/7] Starting audio routing..."

# The softvol plugin ("loopout") creates a mixer control named "Bluetooth" on the
# Loopback card, but ONLY after something first writes to it. Without this dummy
# write, bluealsa-aplay would fail with "Mixer element not found" because the
# control doesn't exist yet. We play 1 second of silence to force its creation.
aplay -D loopout -d 1 /dev/zero 2>/dev/null || true
sleep 1
# Set initial volume to 100%. The phone will adjust it from there.
amixer -c Loopback -q set 'Bluetooth' 100% 2>/dev/null || true

# DRAIN PROCESS — critical for preventing disconnections.
# The ALSA loopback has a fixed-size ring buffer. If bluealsa-aplay is writing BT
# audio to side 0, but NOTHING is reading from side 1, the buffer fills up in ~30
# seconds. Once full, bluealsa-aplay's write() blocks, it can't consume BT data
# fast enough, bluealsad detects the stall, and the phone gets disconnected.
# This arecord reads continuously from loopin and throws it away (/dev/null),
# keeping the buffer drained so writes never block.
# The TCP server (socat) also reads from loopin via dsnoop, but only when a Snapserver
# client is connected. The drain ensures stability even with no TCP client.
arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null &
DRAIN_PID=$!

# BLUEALSA-APLAY — the bridge between Bluetooth audio and ALSA.
# Reads decoded PCM from bluealsad and writes it to "loopout" (softvol → loopback).
#   -D loopout — output to our softvol device (which wraps hw:Loopback,0,0)
#   --mixer-device=hw:Loopback — the ALSA card where the "Bluetooth" mixer control lives
#   --mixer-control=Bluetooth — name of the softvol control to adjust for BT volume
#   --single-audio — only play audio from one BT device at a time (matches single-device enforcer)
# Without --mixer-device and --mixer-control, phone volume changes would be ignored.
bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio 2>&1 | sed 's/^/[bluealsa-aplay] /' &
APLAY_PID=$!

# TCP SERVER — Snapserver connects here to receive the audio stream.
# socat listens on port 4953. When Snapserver connects (mode=client in its config),
# socat spawns arecord which reads from loopin (loopback capture side via dsnoop)
# and sends raw PCM (S16_LE, 44100Hz, stereo) over the TCP connection.
# The while/sleep loop restarts socat after each client disconnects (Snapserver
# reconnect). Without this loop, a single disconnect would kill the TCP server.
# SYSTEM: (not EXEC:) is required because 2>/dev/null needs shell interpretation.
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
# Every 10 seconds, check that all critical background processes are still alive.
# If any died (crash, OOM, ALSA error), restart it with the same arguments.
# Also re-enable discoverable mode if bluetoothd lost it (can happen after adapter reset).
restart() { echo "WATCHDOG: $1 died, restarting..."; }
while true; do
    kill -0 $BLUETOOTHD_PID 2>/dev/null || { restart bluetoothd; /usr/libexec/bluetooth/bluetoothd -d & BLUETOOTHD_PID=$!; }
    kill -0 $BLUEALSA_PID  2>/dev/null || { restart bluealsad; bluealsad --profile=a2dp-sink & BLUEALSA_PID=$!; }
    kill -0 $APLAY_PID     2>/dev/null || { restart bluealsa-aplay; bluealsa-aplay -D loopout --mixer-device=hw:Loopback --mixer-control=Bluetooth --single-audio 2>&1 | sed 's/^/[bluealsa-aplay] /' & APLAY_PID=$!; }
    kill -0 $DRAIN_PID     2>/dev/null || { restart drain; arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw /dev/null 2>/dev/null & DRAIN_PID=$!; }
    kill -0 $TCP_PID       2>/dev/null || { restart tcp; ( while true; do socat TCP-LISTEN:4953,reuseaddr SYSTEM:"arecord -D loopin -f S16_LE -r 44100 -c 2 -t raw 2>/dev/null"; sleep 1; done ) & TCP_PID=$!; }

    # BlueZ can lose discoverable state after certain events (adapter reset, D-Bus
    # reconnect). This ensures phones can always find the device.
    bluetoothctl show 2>/dev/null | grep -q "Discoverable: yes" || bluetoothctl discoverable on 2>/dev/null || true

    # Clean up stale pairing keys. When a phone "forgets" this device, the Pi still
    # has the old keys. On next scan, BlueZ tries to authenticate with the dead keys
    # which silently fails, making the device invisible to that phone.
    # Fix: every 10s, remove any paired device that isn't currently connected.
    # Re-pairing is seamless because the expect agent auto-accepts everything.
    CONNECTED=$(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}')
    for dev in $(bluetoothctl devices Paired 2>/dev/null | awk '{print $2}'); do
        echo "$CONNECTED" | grep -q "$dev" || bluetoothctl remove "$dev" 2>/dev/null || true
    done

    sleep 10
done
