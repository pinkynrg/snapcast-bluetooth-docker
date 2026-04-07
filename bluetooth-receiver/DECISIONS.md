# Bluetooth Receiver - Design Decisions & Troubleshooting Log

## Problem Statement
Raspberry Pi Zero 2W running Bluetooth audio receiver in Docker, streaming to Snapcast via TCP on port 4953.

## Issues Encountered

### Issue 1: Bluetooth Hardware Timeouts (Feb 9, 2026)
**Symptoms:** 
- `hci0: command 0x0c52 tx timeout` in dmesg
- Device couldn't connect at all
- Hardware appeared stuck after ~1 month of uptime

**Root Cause:** 
- Pi Zero Bluetooth runs over UART and can get into unrecoverable states
- Not a software issue - hardware timeout

**Solution:**
- Manual reset: `sudo hciconfig hci0 down && sudo hciconfig hci0 up`
- Container restart after reset
- Created optional watchdog script (bluetooth-watchdog.sh) for automatic recovery

**Decision:** Don't try to fix this in container - it requires host-level commands

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

1. [ ] Fix auto-pair script crash - add better error handling and logging
2. [ ] Understand why bluetoothctl pipe is failing
3. [ ] Get connect/disconnect events visible in logs
4. [ ] Test if device actually stays connected once pairing works
5. [ ] Once working, clean up entire script based on this document

---

## Clean Rewrite TODO

After resolving current issues, rewrite entrypoint.sh with:
- Clear sections with comments
- Only necessary components
- Comprehensive logging
- Error handling that actually works
- Remove all failed experiment code
