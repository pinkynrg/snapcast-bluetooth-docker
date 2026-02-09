#!/bin/bash
set -e

echo "Starting Bluetooth receiver..."

# Check if Bluetooth hardware is available
if ! ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    echo "ERROR: No Bluetooth adapter found!"
    echo "Make sure host Bluetooth service is stopped: sudo systemctl stop bluetooth.service"
    exit 1
fi

echo "Bluetooth adapter found: $(ls /sys/class/bluetooth/)"

# Configure Bluetooth for auto-pairing
cat > /etc/bluetooth/main.conf << EOF
[General]
Name = ${DEVICE_NAME}
Class = 0x200414
DiscoverableTimeout = 0
PairableTimeout = 0
FastConnectable = true
ControllerMode = dual
JustWorksRepairing = always
Privacy = off

[BR]
PageTimeout = 8192

[Policy]
AutoEnable = true
ReconnectAttempts = 7
ReconnectIntervals = 1,2,4,8,16,32,64
EOF

echo "Bluetooth configured for auto-pairing"

# Start D-Bus
mkdir -p /var/run/dbus
rm -f /var/run/dbus/pid
dbus-daemon --system --fork
echo "D-Bus started"

sleep 1

# Start Bluetooth service
/usr/libexec/bluetooth/bluetoothd &
BLUETOOTHD_PID=$!
echo "Bluetooth daemon started (PID: $BLUETOOTHD_PID)"

sleep 3

# Wait for bluetooth controller to be ready
TIMEOUT=30
ELAPSED=0
while ! bluetoothctl show >/dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: Bluetooth controller not available after ${TIMEOUT}s"
        echo "Make sure host Bluetooth service is stopped:"
        echo "  sudo systemctl stop bluetooth.service"
        echo "  sudo systemctl disable bluetooth.service"
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "Bluetooth controller ready"

# Configure Bluetooth to be discoverable and pairable
bluetoothctl power on > /dev/null 2>&1
bluetoothctl discoverable on > /dev/null 2>&1
bluetoothctl pairable on > /dev/null 2>&1

# Create auto-accept agent script using Python D-Bus
cat > /usr/local/bin/bt-agent << 'AGENTEOF'
#!/usr/bin/env python3
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

BUS_NAME = 'org.bluez'
AGENT_INTERFACE = 'org.bluez.Agent1'
AGENT_PATH = "/org/bluez/AutoPairAgent"

class AutoPairAgent(dbus.service.Object):
    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print(f"Bluetooth: Service authorized for {device}")
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print(f"Bluetooth: Authorization granted for {device}")
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        print(f"Bluetooth: Auto-confirmed pairing for {device}")
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print(f"Bluetooth: Using passkey 0 for {device}")
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        print(f"Bluetooth: Using PIN 0000 for {device}")
        return "0000"

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Cancel(self):
        pass

if __name__ == '__main__':
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    agent = AutoPairAgent(bus, AGENT_PATH)
    
    obj = bus.get_object(BUS_NAME, "/org/bluez")
    manager = dbus.Interface(obj, "org.bluez.AgentManager1")
    manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    manager.RequestDefaultAgent(AGENT_PATH)
    
    print("Bluetooth agent registered - auto-pairing enabled")
    
    mainloop = GLib.MainLoop()
    mainloop.run()
AGENTEOF

chmod +x /usr/local/bin/bt-agent
/usr/local/bin/bt-agent &
AGENT_PID=$!

# Create Bluetooth connection monitor
cat > /usr/local/bin/bt-monitor << 'MONITOREOF'
#!/usr/bin/env python3
import dbus
import dbus.mainloop.glib
from gi.repository import GLib
import sys

def device_property_changed(interface, changed, invalidated, path):
    if interface != "org.bluez.Device1":
        return
    
    device_path = str(path)
    mac = device_path.split('/')[-1].replace('_', ':')
    
    if 'Connected' in changed:
        if changed['Connected']:
            print(f"Bluetooth: Connected - {mac}", flush=True)
        else:
            print(f"Bluetooth: Disconnected - {mac}", flush=True)
    
    if 'ServicesResolved' in changed:
        if changed['ServicesResolved']:
            print(f"Bluetooth: Device ready - {mac}", flush=True)

if __name__ == '__main__':
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    
    bus.add_signal_receiver(
        device_property_changed,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        path_keyword="path"
    )
    
    print("Bluetooth monitor started", flush=True)
    mainloop = GLib.MainLoop()
    mainloop.run()
MONITOREOF

chmod +x /usr/local/bin/bt-monitor
/usr/local/bin/bt-monitor &
MONITOR_PID=$!

sleep 2

echo "Bluetooth is now discoverable and auto-accepting connections"

# Kill any existing PulseAudio instances
pulseaudio --kill 2>/dev/null || true
killall -9 pulseaudio 2>/dev/null || true
pkill -9 -f pulseaudio 2>/dev/null || true
rm -rf /var/run/pulse /tmp/pulse-* 2>/dev/null || true
sleep 2

# Disable default PulseAudio configs to prevent conflicts
mkdir -p /etc/pulse/default.pa.d
mv /etc/pulse/default.pa /etc/pulse/default.pa.disabled 2>/dev/null || true
mv /etc/pulse/system.pa /etc/pulse/system.pa.disabled 2>/dev/null || true

# Start PulseAudio with minimal config
mkdir -p /etc/pulse
cat > /etc/pulse/custom.pa << 'EOF'
load-module module-native-protocol-unix auth-anonymous=1
load-module module-null-sink sink_name=tcp_out rate=44100 channels=2
load-module module-simple-protocol-tcp rate=44100 format=s16le channels=2 source=tcp_out.monitor port=4953 listen=0.0.0.0 record=true
load-module module-bluetooth-policy auto_switch=2
load-module module-bluetooth-discover headset=auto
load-module module-switch-on-connect
set-default-sink tcp_out
EOF

# Configure daemon settings for better Bluetooth stability on Pi Zero
cat > /etc/pulse/daemon.conf << 'EOF'
daemonize = no
fail = yes
high-priority = yes
nice-level = -11
realtime-scheduling = yes
realtime-priority = 5
exit-idle-time = -1
resample-method = ffmpeg
avoid-resampling = yes
default-sample-format = s16le
default-sample-rate = 44100
alternate-sample-rate = 48000
default-sample-channels = 2
default-fragments = 8
default-fragment-size-msec = 10
EOF

pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
PULSE_PID=$!
echo "PulseAudio started (PID: $PULSE_PID)"

sleep 3

echo "Audio configuration complete"

echo "====================================="
echo "Bluetooth receiver ready!"
echo "Device name: ${DEVICE_NAME}"
echo "Streaming to TCP port 4953"
echo "Connect your phone/device via Bluetooth"
echo "Audio will stream to snapserver"
echo "====================================="

# Monitor and keep container running
ERROR_COUNT=0
while true; do
    if ! kill -0 $BLUETOOTHD_PID 2>/dev/null; then
        echo "ERROR: Bluetooth daemon died, restarting..."
        /usr/libexec/bluetooth/bluetoothd &
        BLUETOOTHD_PID=$!
    fi
    
    if ! kill -0 $PULSE_PID 2>/dev/null; then
        echo "ERROR: PulseAudio died, restarting..."
        pulseaudio --system --disallow-exit --log-level=error -n --file=/etc/pulse/custom.pa &
        PULSE_PID=$!
    fi
    
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "WARNING: Agent died, restarting..."
        /usr/local/bin/bt-agent > /dev/null 2>&1 &
        AGENT_PID=$!
    fi
    
    if ! kill -0 $MONITOR_PID 2>/dev/null; then
        echo "WARNING: Monitor died, restarting..."
        /usr/local/bin/bt-monitor &
        MONITOR_PID=$!
    fi
    
    # Check for Bluetooth hardware errors
    if dmesg | tail -20 | grep -q "hci0: command.*tx timeout"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "WARNING: Bluetooth hardware timeout detected ($ERROR_COUNT/3)"
        
        if [ $ERROR_COUNT -ge 3 ]; then
            echo "ERROR: Bluetooth hardware is stuck. Container needs restart."
            echo "Please run: docker restart bluetooth-receiver"
            echo "Or on host: sudo hciconfig hci0 down && sudo hciconfig hci0 up && docker restart bluetooth-receiver"
            ERROR_COUNT=0
        fi
    else
        ERROR_COUNT=0
    fi
    
    sleep 10
done
