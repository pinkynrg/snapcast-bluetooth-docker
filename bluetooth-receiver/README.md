# Bluetooth A2DP Receiver (Docker)

Receives Bluetooth audio from phones/computers and serves it as a TCP PCM stream
for Snapserver. Runs on Raspberry Pi Zero 2W (BCM43430A1) in a privileged Docker container.

## Architecture

```
Phone ──BT A2DP──► BlueZ ──► bluealsad ──► bluealsa-aplay ──► loopout (softvol)
    ──► hw:Loopback,0,0 ──► hw:Loopback,1,0 ──► loopin (dsnoop) ──┬──► drain (/dev/null)
                                                                    └──► socat TCP:4953 ──► Snapserver
```

**Key components:**
- **BlueZ 5.66** — Bluetooth stack, handles pairing/connections
- **bluez-alsa** (compiled from source) — bridges BlueZ ↔ ALSA (`bluealsad` + `bluealsa-aplay`)
- **ALSA loopback** (`snd-aloop`) — virtual sound card connecting playback to capture
- **softvol** — ALSA plugin giving bluealsa-aplay a mixer control for phone volume
- **dsnoop** — ALSA plugin allowing drain + TCP server to share loopback capture
- **expect** — auto-responds to bluetoothctl pairing/authorization prompts
- **socat** — TCP server sending raw PCM to Snapserver

## What Failed and Why

### PulseAudio (months of debugging)
**Root cause:** `module-loopback` race condition. It attaches to the BT source before the
A2DP transport is acquired. This causes "Could not peek into queue" errors, which triggers
a teardown cascade. Audio plays for 10-24 seconds then disconnects. Unfixable in PulseAudio
architecture — the loopback module has no way to wait for transport acquisition.

### Bluetooth agent approaches
1. **FIFO pipe to bluetoothctl** — Works for simple commands but hangs on "Authorize service"
   because you can't pre-pipe async responses. The prompt arrives after the FIFO is already
   written.
2. **bt-agent (bluez-tools)** — Daemon mode (`-d`) is broken per upstream README. Crashes or
   hangs depending on version.
3. **expect script** ✅ — Pattern-matches bluetoothctl output and responds to any prompt.
   Combined with `--agent NoInputNoOutput` flag for Just Works pairing. This is the solution.

### Audio routing issues
1. **bluealsa-aplay with specific MAC** — Grepped for `a2dp-sink` but actual PCM path was
   `a2dpsnk`. Fixed by using bluealsa-aplay without MAC (handles all devices internally).
2. **Loopback buffer stall** — With no reader on `hw:Loopback,1,0`, the ring buffer fills in
   ~30 seconds, bluealsa-aplay's write blocks, bluealsad detects the stall, phone disconnects.
   Fixed with permanent `arecord` drain to `/dev/null`.
3. **socat EXEC: vs SYSTEM:** — `EXEC:` doesn't invoke a shell, so `2>/dev/null` gets treated
   as a literal filename argument. Must use `SYSTEM:` for shell redirection.

### Volume control
`hw:Loopback,0,0` has no mixer — bluealsa-aplay logs "Couldn't open ALSA mixer". Fix: wrap
loopback in softvol plugin creating a "Bluetooth" mixer control, then pass
`--mixer-device=hw:Loopback --mixer-control=Bluetooth` to bluealsa-aplay. Requires a dummy
`aplay -D loopout -d 1 /dev/zero` first to initialize the control.

### Docker /dev/snd after modprobe
Docker snapshots `/dev/` at container start. If `snd-aloop` is loaded by `modprobe` inside
the container AFTER start, the Loopback device nodes don't appear in `/dev/snd/`. Fix: read
`/sys/class/sound/` (always current) and `mknod` any missing device nodes.

### Stale pairing keys
When a phone "forgets" the Pi, BlueZ still has the old keys. On next scan, BlueZ tries to
authenticate with dead keys, silently fails, and the device becomes invisible to that phone.
Fix: watchdog removes any paired-but-disconnected device every 10 seconds. Re-pairing is
seamless because the expect agent auto-accepts.

## What Works and Why

### The expect agent
`bluetoothctl --agent NoInputNoOutput` sets the IO capability at the BlueZ level (no display,
no keyboard = Just Works pairing). The expect script wraps bluetoothctl and pattern-matches
every possible prompt: "Authorize service", "Request confirmation", "Confirm passkey", etc.
It responds "yes" or "0000" as appropriate. This runs as a long-lived background process.

### bluez-alsa over PulseAudio
PulseAudio's module-loopback has an unfixable race condition with BT transports. bluez-alsa
(`bluealsad`) operates at the ALSA level — it creates a virtual PCM device for each connected
BT device. `bluealsa-aplay` reads from it and writes to our loopback. No race, no stalls,
no 10-second disconnects.

### The drain process
`arecord -D loopin ... /dev/null` runs permanently. It keeps the loopback capture buffer
drained so `bluealsa-aplay`'s writes to the playback side never block. Without it, the buffer
fills in ~30 seconds and the BT connection dies.

### softvol + mixer flags
The softvol ALSA plugin wraps `hw:Loopback,0,0` and creates a "Bluetooth" mixer control.
`bluealsa-aplay --mixer-device=hw:Loopback --mixer-control=Bluetooth` maps A2DP AVRCP volume
changes to this control. Phone volume slider now controls actual output amplitude.

### Single-device enforcer
Polls `bluetoothctl devices Connected` every 2 seconds. If >1 device connected, identifies
which is new (wasn't in previous poll) and disconnects the rest. Prevents audio conflicts.

### mknod after modprobe
After `modprobe snd-aloop`, iterates `/sys/class/sound/*`, reads major:minor from each
device's `dev` file, and creates any missing `/dev/snd/` char device. Makes the container
fully self-contained — no host config needed.

## Snapserver Config

```
source = tcp://192.168.1.104:4953?name=Bluetooth&mode=client&sampleformat=44100:16:2
```

Snapserver connects as a TCP **client** to the receiver's port 4953.

## Deploy

```bash
cd ~/snapcast-bluetooth-docker/bluetooth-receiver
git pull && docker build -t pinkynrg/bluetooth-receiver:latest . \
  && docker compose down && docker compose up -d \
  && docker compose logs -f
```

## Docker Requirements

- `privileged: true` (BT adapter + kernel modules)
- `network_mode: host` (BT + TCP server)
- Volume: `bluetooth-data:/var/lib/bluetooth` (pairing keys persist across restarts)

## Hardware

- Raspberry Pi Zero 2W
- BCM43430A1 Bluetooth (UART-attached)
- Tested with: Samsung Galaxy S25, MacBook Pro (macOS)
