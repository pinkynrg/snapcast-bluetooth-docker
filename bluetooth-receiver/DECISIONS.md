# Bluetooth Receiver - Design Decisions & Troubleshooting Log

## Problem Statement
Raspberry Pi Zero 2W running Bluetooth audio receiver in Docker, streaming to Snapcast via TCP on port 4953.

## Issues Encountered

### Issue 1: Bluetooth Hardware Timeouts - THE ROOT CAUSE (Feb 9 + Apr 7, 2026)
**Symptoms:** 
- `hci0: command 0x0c52 tx timeout` in dmesg
- Device not visible to any phone/computer
- `hciconfig hci0 piscan` returns `Connection timed out (110)` ← KEY INDICATOR
- `hciconfig hci0` may still show `UP RUNNING PSCAN ISCAN` (misleading - software state, not hardware)
- Container reports "Bluetooth is discoverable" but nothing can see it
- Happened after ~1 month of uptime (Feb), then again in Apr after all the restarts

**Root Cause:** 
- Pi Zero Bluetooth (BCM43430A1) runs over UART and the hardware gets into an unrecoverable state
- The software (bluetoothd, bluetoothctl show) still reports everything OK - this is MISLEADING
- The actual radio stops responding to HCI commands
- This is a **hardware-level issue**, not a software/config issue
- **All the config changes, Python agents, dbus-monitor - none of that was the real problem**

**Confirmed Fix (the ONLY fix):**
```bash
docker stop bluetooth-receiver
sudo hciconfig hci0 down
sudo rmmod btbcm 2>/dev/null || true
sudo rmmod hci_uart 2>/dev/null || true
sleep 3
sudo modprobe hci_uart
sudo modprobe btbcm
sleep 2
sudo hciconfig hci0 up
docker start bluetooth-receiver
```

**How to detect it:**
- `sudo hciconfig hci0 piscan` returns `Connection timed out (110)` → hardware is stuck
- `sudo dmesg | grep -i bluetooth | tail -20` shows `tx timeout` errors

**Automatic Recovery (Docker-only)**
The container watchdog loop detects `tx timeout` in dmesg and performs the reset itself.
This works because the container runs --privileged, which grants `CAP_SYS_MODULE`.
No host-level service needed. The container kills its processes, runs `rmmod`/`modprobe`, restarts.

Also remove wireplumber/pipewire from the Pi host entirely - it has no purpose on this Pi and
interferes with the BT adapter. Run once on the host: `sudo apt-get remove --purge wireplumber pipewire pipewire-pulse -y && sudo apt-get autoremove -y`

**Key lesson:** When device is not visible despite bluetoothctl showing discoverable,
TEST THE HARDWARE FIRST with `sudo hciconfig hci0 piscan` before debugging software.

---

### Issue 2: Phone Disconnects After 10 Seconds
**Symptoms:**
- Phone connects successfully
- Disconnects exactly ~10 seconds later
- Happens even without playing audio

**Attempts:**
1. ❌ Added PulseAudio daemon.conf with buffering optimizations → No effect
2. ❌ Added Bluetooth main.conf settings (PageTimeout, etc.) → Config ignored (wrong syntax)
3. ❌ Created Python D-Bus agent for auto-pairing → No logging visibility
4. ❌ Added connection monitor → Agent crashed silently

**Current Investigation:**
- Simplified to pure bash approach
- Need better logging to see what's happening
- Auto-pair script is crashing immediately (Apr 7, 2026)

---

### Issue 3: Auto-Pair Script Immediately Dies (Apr 7, 2026)
**Symptoms:**
- `WARNING: Auto-pair script died, restarting...` loops continuously
- `[D0-56-FB-19-B7-16]# quit` visible in output
- No connection/disconnect events logged

**Root Cause:**
- `bluetoothctl` requires a TTY (interactive terminal)
- When piped (`bluetoothctl | while read`), it detects no TTY and exits immediately
- The `quit` in the output confirms bluetoothctl is terminating itself

**Solution:**
- Replaced `bluetoothctl` monitoring with `dbus-monitor --system`
- dbus-monitor doesn't need a TTY, runs forever, and gives reliable D-Bus events
- Parse PropertiesChanged signals for Connected/Disconnected/ServicesResolved

**Decision:** Never use `bluetoothctl` for background monitoring in Docker. Use `dbus-monitor` instead.

---

### Issue 5: bluetoothctl commands fail silently without TTY (Apr 7, 2026)
**Symptoms:**
- `bluetoothctl power on` / `discoverable on` etc. fail or behave unpredictably in Docker
- Device not visible to phones/computers
- Commands sometimes race with device events ([NEW] Device appearing mid-command)

**Root Cause:**
- `bluetoothctl` is designed for interactive use with a TTY
- Running `bluetoothctl <command>` without a TTY can fail silently
- Previously paired devices triggering events can break single commands

**Solution:**
- Pipe all commands at once via stdin: `echo -e "power on\ndiscoverable on\n..." | bluetoothctl`
- Also register agent (`NoInputNoOutput` + `default-agent`) in same session
- Verify result by checking `bluetoothctl show` for `Discoverable: yes`
- Retry loop (up to 5 attempts) with verification

**Decision:** Always pipe commands to bluetoothctl via stdin. Always verify the result with `bluetoothctl show`.

---

### Issue 4: Container Exits - `Failed to set discoverable on` (Apr 7, 2026)
**Symptoms:**
- `[NEW] Device D0:56:FB:19:B7:16` appears during startup (previously paired device)
- `Failed to set discoverable on: org.bluez.Error.Failed`
- Container exits immediately

**Root Cause:**
1. `set -e` in entrypoint.sh kills the script on ANY command failure
2. `bluetoothctl discoverable on` fails because a previously paired device triggers events mid-command, causing a race condition in bluetoothctl

**Solution:**
- Removed `set -e` from entrypoint.sh - only use explicit error handling where needed
- Added retry loop for bluetoothctl commands (power on, discoverable on, pairable on)
- Each command retries up to 3 times with 2 sec delay

**Decision:** Never use `set -e` in scripts that interact with bluetooth - commands fail transiently and that's OK

---

## Configuration Decisions

### Bluetooth Configuration
**File:** `/etc/bluetooth/main.conf`

```ini
[General]
Name = ${DEVICE_NAME}
Class = 0x200414              # Audio device class
DiscoverableTimeout = 0       # Stay discoverable forever
PairableTimeout = 0           # Stay pairable forever  
FastConnectable = true
ControllerMode = dual
JustWorksRepairing = always   # Auto-pair without prompts
Privacy = off                 # Disable privacy features

[BR]
PageTimeout = 8192            # Prevent premature disconnects

[Policy]
AutoEnable = true
ReconnectAttempts = 7
ReconnectIntervals = 1,2,4,8,16,32,64
```

**Why:** 
- Need device always discoverable for easy connection
- JustWorksRepairing prevents pairing prompts
- PageTimeout in [BR] section (not [General] - bluetoothd only looks there)

---

### PulseAudio Configuration
**File:** `/etc/pulse/custom.pa`

```
load-module module-native-protocol-unix auth-anonymous=1
load-module module-null-sink sink_name=tcp_out rate=44100 channels=2
load-module module-simple-protocol-tcp rate=44100 format=s16le channels=2 source=tcp_out.monitor port=4953 listen=0.0.0.0 record=true
load-module module-bluetooth-policy auto_switch=2
load-module module-bluetooth-discover headset=auto
load-module module-switch-on-connect
set-default-sink tcp_out
```

**Why:**
- `tcp_out` null sink captures all audio
- `module-simple-protocol-tcp` streams to snapserver on port 4953
- `module-switch-on-connect` auto-routes Bluetooth audio to default sink
- `auto_switch=2` enables automatic profile switching for better compatibility
- Use `--file` flag (not `-F`) to prevent loading default config that conflicts

**File:** `/etc/pulse/daemon.conf`

```
daemonize = no
high-priority = yes
nice-level = -11
realtime-scheduling = yes
realtime-priority = 5
exit-idle-time = -1
default-sample-format = s16le
default-sample-rate = 44100
default-fragments = 8
default-fragment-size-msec = 10
```

**Why:**
- Pi Zero is slow - need real-time priority and buffering for smooth audio
- Larger fragments prevent underruns

---

## Next Steps (Apr 7, 2026)

1. [x] Fix auto-pair script crash - use expect (TTY) for agent, dbus-monitor for logging
2. [x] Understand why bluetoothctl pipe is failing - no TTY in Docker
3. [x] Get connect/disconnect events visible in logs - dbus-monitor
4. [ ] Test if device actually stays connected once pairing works
5. [ ] Once working, clean up entire script based on this document

---

## Important Rules

### DO NOT edit early Dockerfile layers during debugging
The Pi Zero takes ~350 seconds to rebuild when the apt-get layer changes.
Only modify the Dockerfile when you're sure the change is needed.
During debugging, only change entrypoint.sh (which is a later COPY layer and rebuilds in seconds).

### Host services that may interfere
The Pi Zero likely runs PipeWire (default on Raspberry Pi OS Bookworm+).
PipeWire includes:
- `pipewire` - audio server
- `pipewire-pulse` - PulseAudio compatibility
- `wireplumber` - session manager that can grab Bluetooth devices

These host services may **compete** with the container's bluetoothd/PulseAudio for the Bluetooth adapter.
This could explain why the setup "worked for a month then stopped" - a host service update or restart
could have started interfering.

**To investigate on the Pi:**
```bash
# Check if PipeWire/PulseAudio is running on the host
systemctl --user status pipewire pipewire-pulse wireplumber

# Check if host bluetooth service is running (should be stopped/masked)
sudo systemctl status bluetooth.service

# Check what's using the BT adapter on the host
ps aux | grep -E "bluetooth|pulse|pipewire|wireplumber"

# Nuclear option: disable all host audio/BT services
sudo systemctl mask bluetooth.service
systemctl --user stop pipewire pipewire-pulse wireplumber
systemctl --user mask pipewire pipewire-pulse wireplumber
```

**NOTE:** The other Pi Zeros running snapclient use PipeWire for output.
Only the bluetooth-receiver Pi should have host BT services disabled.

---

## Clean Rewrite TODO

After resolving current issues, rewrite entrypoint.sh with:
- Clear sections with comments
- Only necessary components
- Comprehensive logging
- Error handling that actually works
- Remove all failed experiment code
