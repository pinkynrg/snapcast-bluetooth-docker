# Changes Tracking - Bluetooth Receiver Debugging

## Problem
Container gets stuck - bluetoothd starts but `bluetoothctl show` times out after 30s

## Root Cause FOUND
**D-Bus setup failed: Name already in use**
- Another bluetoothd is already registered on D-Bus as `org.bluez`
- The bluetoothd we start can't register, so bluetoothctl can't connect to it
- Either host has bluetoothd running OR container has duplicate bluetoothd process

## Solution
1. Kill any existing bluetoothd before starting ours in the container:
```bash
killall -9 bluetoothd 2>/dev/null || true
```

2. **Host bluetooth service MUST be stopped and masked:**
```bash
sudo systemctl mask bluetooth
sudo systemctl stop bluetooth
```

## Current Status
✅ WORKING after reboot!
- Device "Snapcast Receiver" visible on phone
- Container running successfully
- bluetoothd registered on D-Bus correctly

## What Fixed It
Reboot cleared hardware/driver state that was preventing discoverable mode from working properly

## Next Steps
- Test connecting phone and playing audio
- Verify audio streams to snapserver
- Once confirmed working, clean up debug code

## Changes to KEEP:

### Added (may need removal):
1. Verbose logging with `sed 's/^/  /'` for bluetoothctl commands
2. D-Bus connection checks
3. Adapter state logging (before/after hciconfig up)
4. Periodic discoverable status checks every 30s
5. Initial device cleanup on startup
6. Auto-remove pairing on disconnect
7. Show which devices are "connected" at startup

### Changes to Keep:
- `hciconfig $ADAPTER up` before starting bluetoothd (needed)

## Next Steps
1. Check if bluetoothd is actually connecting to D-Bus
2. Add temporary debug: run bluetoothd in foreground with verbose logging
3. Check D-Bus permissions/policies

## Solution (once found)
[To be filled in - then remove all unnecessary debug code]
