# Dockerized Snapcast with Bluetooth Speaker Auto-Reconnect

Multi-room audio streaming solution with Snapcast server/client, Spotify integration via librespot, and automatic Bluetooth speaker connection management, fully containerized for Raspberry Pi and x86 systems.

## Overview

This project provides a complete Dockerized Snapcast setup with automatic Bluetooth reconnection:

- **Snapcast Server**: Streams audio from Spotify (via librespot) to multiple clients
- **Snapcast Client**: Receives audio and plays through Bluetooth speakers
- **Bluetooth Reconnector**: Automatically maintains connection to Bluetooth audio devices
- Multi-architecture support (AMD64, ARM64)
- Fully containerized with Docker

## Features

- **Automatic Bluetooth Reconnection**: Monitors and maintains connection to Bluetooth audio devices
- **Multi-Room Audio**: Synchronized audio streaming across multiple Snapcast clients
- **Spotify Integration**: Built-in librespot support for Spotify Connect
- **Easy Deployment**: Docker Compose for simple service management
- **Audio Device Filtering**: Only shows and connects to audio-capable Bluetooth devices

## Prerequisites

### Network Configuration (Static IP)

Configure a static IP address for reliable network access:

```bash
# List available connections
nmcli connection show

# Configure static IP with router-provided DNS (replace values with your network settings)
sudo nmcli connection modify "the-interface" \
  ipv4.addresses 192.168.1.123/24 \
  ipv4.gateway 192.168.1.254 \
  ipv4.dns "192.168.1.100 1.1.1.1" \
  ipv4.method manual

sudo nmcli connection up "the-interface"
```

**Disable a connection (e.g., WiFi):**
```bash
# List all connections
nmcli connection show

# Disable/bring down a connection
sudo nmcli connection down "the-interface"
```

### PipeWire (Audio System)

Raspberry Pi OS (Bookworm or newer) comes with **PipeWire** pre-installed with Bluetooth support. No additional installation needed.

You can verify PipeWire is running:
```bash
systemctl --user status pipewire pipewire-pulse
```

### Docker

Install Docker on Raspberry Pi:
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add your user to the docker group
sudo usermod -aG docker $USER

# Refresh group membership without logging out
newgrp docker

# Verify
docker --version

# Start Portainer Agent (optional, for remote management)
docker run -d \
  -p 9001:9001 \
  --name portainer_agent \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  portainer/agent:latest
```

## Usage

### Find Your Bluetooth Speaker MAC Address

Before configuring services, identify your Bluetooth speaker's MAC address:

```bash
cd bluetooth-reconnector
docker-compose run --rm bluetooth-reconnector python3 /app/bluetooth-speaker-reconnector.py --list --timeout 15
```

This will scan and display all available Bluetooth audio devices with their MAC addresses.

### Adjust Volume

If your audio is too quiet or too loud, you can adjust the PulseAudio volume on the host machine.

**Install pactl (if not already installed):**
```bash
sudo apt-get update
sudo apt-get install pulseaudio-utils
```

**1. List available audio sinks:**
```bash
pactl list sinks short
```

Output example:
```
57   alsa_output.platform-fe00b840.mailbox.stereo-fallback  PipeWire  s16le 2ch 48000Hz  SUSPENDED
100  bluez_output.60_AB_D2_08_0C_32.1                       PipeWire  s16le 2ch 48000Hz  RUNNING
```

**2. Check current volume:**
```bash
pactl list sinks | grep -i 'volume:'
```

**3. Increase or decrease volume:**
```bash
# Increase by 20%
pactl set-sink-volume bluez_output.60_AB_D2_08_0C_32.1 +20%

# Decrease by 10%
pactl set-sink-volume bluez_output.60_AB_D2_08_0C_32.1 -10%

# Set to specific percentage
pactl set-sink-volume bluez_output.60_AB_D2_08_0C_32.1 80%
```

Replace `bluez_output.60_AB_D2_08_0C_32.1` with your Bluetooth device name from step 1.

**Note:** Volume changes persist until the device disconnects or the system reboots.

### Snapcast Server

The Snapcast server streams audio from Spotify (via librespot) to connected clients.

**Setup:**
1. Navigate to the snapserver directory: `cd snapserver`
2. Configure environment variables in `docker-compose.yml`:
   ```yaml
   environment:
     - DEVICE_NAME=Snapcast        # Spotify device name
     - CACHE=/data                 # Cache directory
   ```
3. Start the server: `docker-compose up -d`

The server will be accessible on ports 1704 (client connections) and 1705 (control).

### Snapcast Client

The Snapcast client receives audio from the server and plays through the connected Bluetooth speaker.

**Setup:**
1. Navigate to the snapclient directory: `cd snapclient`
2. Configure the server and host ID in `docker-compose.yml`:
   ```yaml
   command: ["snapclient", "-h", "your-snapserver.com", "-s", "pulse", "--hostID", "your-client-id"]
   ```
3. Start the client: `docker-compose up -d`

### Bluetooth Reconnector

The Bluetooth reconnector monitors and maintains connection to your Bluetooth speaker.

**Setup:**
1. Navigate to the bluetooth-reconnector directory: `cd bluetooth-reconnector`
2. Configure the MAC address in `docker-compose.yml`:
   ```yaml
   environment:
     - BT_MAC=60:AB:D2:08:0C:32  # Replace with your speaker's MAC address
     - BT_CHECK_INTERVAL=30      # Connection check interval (seconds)
     - BT_TIMEOUT=15             # Bluetooth scan timeout (seconds)
   ```
3. Start the reconnector: `docker-compose up -d`

## Architecture

The system consists of three main components:

1. **Snapcast Server**
   - Runs librespot for Spotify Connect integration
   - Streams audio to connected Snapcast clients
   - Built from Debian with custom librespot compilation

2. **Snapcast Client**
   - Receives audio stream from Snapcast server
   - Outputs audio through PipeWire/PulseAudio to Bluetooth speaker
   - Uses host network mode to access PipeWire audio system

3. **Bluetooth Reconnector**
   - Monitors Bluetooth connection status
   - Automatically reconnects if connection is lost
   - Uses `bluetoothctl` for device management

**Audio Flow:**
```
Spotify → Librespot → Snapserver → Network → Snapclient → PipeWire → Bluetooth Speaker
                                                              ↑
                                                    Bluetooth Reconnector
                                                    (maintains connection)
```

## Environment Variables

### Snapcast Server

- `DEVICE_NAME`: Spotify Connect device name (default: "Snapcast")
- `CACHE`: Directory for librespot cache (default: "/data")

### Snapcast Client

Configured via command-line arguments in docker-compose.yml:
- `-h`: Snapcast server hostname or IP
- `-s`: Audio backend (pulse, alsa, etc.)
- `--hostID`: Unique identifier for this client
- `--buffer`: Buffer size in milliseconds (optional, e.g., 2000 for higher stability)

### Bluetooth Reconnector

- `BT_MAC`: MAC address of the Bluetooth speaker (required)
- `BT_CHECK_INTERVAL`: Connection check interval in seconds (default: 30)
- `BT_TIMEOUT`: Bluetooth scan timeout in seconds (default: 15)

## Building Images

The project includes a GitHub Actions workflow that automatically builds and pushes multi-platform Docker images (AMD64 and ARM64) on every push to the main branch.

Images are published to Docker Hub:
- `pinkynrg/snapserver:latest`
- `pinkynrg/snapclient:latest`
- `pinkynrg/bluetooth-speaker-reconnector:latest`


## Troubleshooting

### Audio Crackling or Dropouts

If you experience audio glitches on all speakers simultaneously:
1. Increase Snapclient buffer: Add `--buffer 2000` to the command in docker-compose.yml
2. Check network quality between server and clients
3. Monitor CPU usage on the Snapserver host

### Bluetooth Connection Issues

If Bluetooth frequently disconnects:
1. Verify the MAC address is correct using `--list`
2. Reduce `BT_CHECK_INTERVAL` for more frequent monitoring
3. Check Bluetooth signal strength (move speaker closer)
4. Ensure PipeWire is running: `systemctl --user status pipewire`

### Container Not Starting

Check logs for specific errors:
```bash
docker-compose logs
```

Ensure required permissions for Bluetooth access (containers use host network mode).

## License

MIT
