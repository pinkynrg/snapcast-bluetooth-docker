# Bluetooth Receiver - Design Decisions

## Setup
Raspberry Pi Zero 2W (BCM43430A1 BT chip, UART-based), Docker container with `--privileged` and `network_mode: host`, streaming BT audio to Snapcast via TCP port 4953.

**Host requirements:**
- `sudo systemctl stop bluetooth.service && sudo systemctl mask bluetooth.service`
- `sudo apt-get remove --purge wireplumber pipewire pipewire-pulse -y && sudo apt-get autoremove -y`
- PipeWire/wireplumber compete for the BT adapter. Only affects this Pi, not the snapclient Pis.

---

## Architecture

```
Phone --[A2DP]--> bluetoothd --[D-Bus]--> PulseAudio --> module-null-sink (tcp_out)
                                                              |
                                                        tcp_out.monitor
                                                              |
                                                     module-simple-protocol-tcp :4953
                                                              |
                                                         snapserver
```

`module-bluetooth-policy` auto-creates a `module-loopback` from `bluez_source.MAC.a2dp_source` to the default sink (`tcp_out`) on connection. `module-switch-on-connect` sets the new BT source as default. `module-simple-protocol-tcp` streams `tcp_out.monitor` to snapserver.

---

## Key Decisions

### 1. No `set -e`
bluetoothctl commands fail transiently (race with paired device events). Let them fail silently.

### 2. `expect` for bt-agent, `dbus-monitor` for monitoring
`bluetoothctl` requires a TTY to stay running as an interactive agent. `expect` provides that. For background monitoring (connect/disconnect events), `dbus-monitor` works without a TTY.

### 3. bluetoothd `--noplugin=hfp_hf,hfp_ag`
This is a music receiver, not a phone. Disabling HFP prevents the phone from connecting handsfree profile, which causes PA to tear down the A2DP card to rebuild profiles.

### 4. D-Bus policy for `pulse` user
PulseAudio runs as user `pulse` in system mode. Without an explicit D-Bus allow rule, `pulse` can't call `TryAcquire`/`Acquire` on `org.bluez.MediaTransport1`. D-Bus masks the denial as "method doesn't exist". Fix: custom policy file + `usermod -aG bluetooth pulse`.

### 5. `set-default-source tcp_out.monitor` in custom.pa
Without this, PA auto-selects any new source (including `bluez_source`) as default. This causes the TCP client (snapserver) to move off `tcp_out.monitor` onto the BT source directly. When PA later re-evaluates, everything cascades: loopback freed → transport released → disconnect.

### 6. `module-switch-on-connect` is NOT loaded
Despite being in the original working config, this module changes the default source when a BT device connects, causing the snapserver TCP client to move off `tcp_out.monitor`. Removed.

### 7. `auto_switch=false` in `module-bluetooth-policy`
Prevents PA from trying to switch between A2DP and HSP/HFP profiles mid-connection.

### 8. `headset=ofono` in `module-bluetooth-discover`
Points HFP to oFono (not installed) → effectively disables HFP handling in PA as well.

### 9. Hardware watchdog in container
The BCM43430A1 BT chip locks up after prolonged uptime. `dmesg` shows `tx timeout`, `hciconfig hci0 piscan` returns `Connection timed out (110)`. `bluetoothctl show` still reports `Discoverable: yes` (misleading — software state, not hardware). The container runs `rmmod`/`modprobe` to reset (requires `--privileged` + `/lib/modules:/lib/modules:ro` volume). Only checks dmesg lines written AFTER container start to avoid triggering on stale errors.

### 10. Re-enable discoverable after disconnect
BlueZ sometimes silently turns off discoverable after a device disconnects. The watchdog re-enables it every 10s if needed.

### 11. Stale link keys after hardware reset
After a BT hardware reset (`rmmod`/`modprobe`), previously paired devices may have stale link keys. The connection establishes but drops after ~20-25 seconds (BT supervision timeout). Fix: `bluetoothctl remove <MAC>` + forget on the phone, then re-pair.

### 12. Do NOT edit early Dockerfile layers during debugging
Pi Zero takes ~350s to rebuild the apt-get layer. Only modify `entrypoint.sh` (later COPY layer, rebuilds in seconds).

---

## Diagnostic Commands

```bash
# Is the hardware stuck?
sudo hciconfig hci0 piscan     # timeout = stuck, need rmmod/modprobe

# Check dmesg for BT errors
sudo dmesg | grep -i bluetooth | tail -20

# PA state inside container
docker exec bluetooth-receiver pactl list sources short
docker exec bluetooth-receiver pactl list source-outputs short
docker exec bluetooth-receiver pactl list sink-inputs short

# Remove stale pairing
docker exec bluetooth-receiver bluetoothctl remove D0:56:FB:19:B7:16
```

---

## Current Status (Apr 8, 2026)

**OPEN: Phone disconnects after ~20-25 seconds**

Timeline from logs:
```
+0s   ServicesResolved, card created, loopback created, codec=SBC
+2s   BT Connected
+5s   Transport acquired (fd), transport pending → active, audio flowing
+25s  source-output freed, loopback freed, transport auto-released by BlueZ, disconnect
```

The `Transport auto-released by BlueZ` at +25s indicates BlueZ is initiating the disconnect — not PulseAudio. This is consistent with stale link keys (BT supervision timeout). Mac stays connected (different key negotiation behavior).

**Next step:** Forget device on both sides and re-pair fresh. If that doesn't fix it, the problem is at the BlueZ/radio level, not PulseAudio.
