# Bluetooth Receiver - bluez-alsa Implementation

## Architecture

**Simple, reliable audio stack:**
```
Phone (A2DP Source)
  ↓
BlueZ (Bluetooth stack)
  ↓
bluez-alsa (Bluetooth audio daemon)
  ↓
bluealsa-aplay (audio router)
  ↓
ALSA Loopback (hw:Loopback)
  ↓
Snapcast Client (reads from hw:Loopback,0,0)
```

## Why bluez-alsa?

- ✅ **No PulseAudio complexity** - Direct ALSA integration
- ✅ **No race conditions** - Designed for Bluetooth audio receivers
- ✅ **Proven technology** - Used in production Bluetooth speaker projects
- ✅ **Low latency** - Direct audio path without intermediate servers
- ✅ **Reliable** - Simple architecture = fewer failure points

## How It Works

1. **bluealsa daemon** registers with BlueZ as A2DP sink
2. **Auto-router script** monitors for Bluetooth connections
3. When phone connects and plays audio:
   - Auto-router detects the connection
   - Starts `bluealsa-aplay` to route audio
   - Audio flows: Bluetooth → bluealsa → ALSA loopback
4. **Snapcast reads** from `hw:Loopback,0,0` (capture side)

## Deployment

```bash
cd bluetooth-receiver
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

## Logs

```bash
# Watch logs
docker logs -f bluetooth-receiver

# Check bluealsa status
docker exec bluetooth-receiver bluealsa-cli status

# List connected PCM devices
docker exec bluetooth-receiver bluealsa-cli list-pcms

# Check ALSA devices
docker exec bluetooth-receiver aplay -l
```

## Testing

1. **Pair phone:**
   - Open Bluetooth settings on phone
   - Look for "Snapcast Receiver"
   - Connect (auto-pairs, no PIN needed)

2. **Play audio:**
   - Open music app on phone
   - Play any track
   - Audio should stream continuously

3. **Verify routing:**
   ```bash
   docker logs bluetooth-receiver | grep "AutoRouter"
   # Should see: "A2DP source detected, starting playback..."
   ```

4. **Check ALSA loopback:**
   ```bash
   docker exec bluetooth-receiver cat /proc/asound/Loopback/pcm0c/sub0/status
   # Should show: state: RUNNING (when audio playing)
   ```

## Troubleshooting

### No audio
```bash
# Check if bluealsa-aplay is running
docker exec bluetooth-receiver ps aux | grep bluealsa-aplay

# Check ALSA loopback module
docker exec bluetooth-receiver lsmod | grep snd_aloop

# Verify bluealsa sees the device
docker exec bluetooth-receiver bluealsa-cli list-pcms
```

### Connection drops
```bash
# Check bluetoothd logs
docker exec bluetooth-receiver journalctl -u bluetooth -f

# Test Bluetooth signal strength
docker exec bluetooth-receiver hcitool rssi <MAC_ADDRESS>
```

### Module load fails
If `snd-aloop` fails to load, ensure:
- Container runs with `--privileged` (already set in docker-compose.yml)
- Host kernel has ALSA loopback support: `modprobe snd-aloop` on host

## Configuration

### Change device name
Edit `docker-compose.yml`:
```yaml
environment:
  - DEVICE_NAME=My Custom Name
```

### Adjust audio buffer
Edit `entrypoint.sh`, modify bluealsa-aplay line:
```bash
--pcm-buffer-time=500000 --pcm-period-time=100000
```
Larger values = more latency but fewer dropouts

## Migration from PulseAudio

Old PulseAudio implementation backed up as `entrypoint-pulseaudio-old.sh`.

**Key differences:**
- ❌ No PulseAudio daemons
- ❌ No module-loopback timing issues  
- ❌ No complex audio server configuration
- ✅ Direct ALSA path
- ✅ Simpler, more reliable

## References

- [bluez-alsa documentation](https://github.com/Arkq/bluez-alsa)
- [ALSA loopback](https://www.alsa-project.org/wiki/Matrix:Module-aloop)
