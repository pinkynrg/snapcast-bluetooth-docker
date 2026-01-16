# Bluetooth Receiver for Snapcast

This setup turns your device into a Bluetooth audio receiver that streams to Snapcast clients.

## Features

- **Auto-accepts all Bluetooth connections** - no pairing confirmation needed
- **Last device wins** - connection can be "stolen" by any new device
- **Pipes audio to snapserver** - distributes to all snapclients in sync
- **Always discoverable** - appears as "Snapcast Receiver" in Bluetooth devices

## Setup

1. **Build the image:**
   ```bash
   docker build -t pinkynrg/bluetooth-receiver:latest .
   ```

2. **Configure snapserver:**
   
   Create `/mnt/data/snapserver/snapserver-bt.conf` with:
   ```ini
   [stream]
   source = pipe:///tmp/snapfifo?name=Bluetooth&sampleformat=48000:16:2&mode=read
   ```

3. **Start the services:**
   ```bash
   docker-compose up -d
   ```

4. **Connect your device:**
   - Open Bluetooth settings on your phone/tablet
   - Look for "Snapcast Receiver"
   - Connect (no PIN needed)
   - Play music - it will stream to all snapclients!

## Customization

Change the Bluetooth device name by editing `docker-compose.yml`:
```yaml
environment:
  - DEVICE_NAME=My Custom Name
```

## Troubleshooting

Check logs:
```bash
docker-compose logs -f bluetooth-receiver
```

Check Bluetooth status inside container:
```bash
docker exec -it bluetooth-receiver bluetoothctl
```

## Requirements

- Host Bluetooth adapter
- `privileged: true` and `network_mode: host` for Bluetooth access
- D-Bus socket access
