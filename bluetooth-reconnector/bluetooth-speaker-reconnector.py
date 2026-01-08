#!/usr/bin/env python3
"""
Bluetooth speaker connection script.
Connects to a Bluetooth device by MAC address and plays a system sound.
"""

import argparse
import subprocess
import time
import sys
import os
import pexpect

DEFAULT_CONNECTION_TIMEOUT = 15
DEFAULT_CHECK_INTERVAL = 30
DEFAULT_KEEPALIVE_VOLUME = 1000  # PulseAudio volume (0-65536, default 1000 = ~1.5%)

def run_command(command, timeout=10):
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"


def _get_devices(duration):
    print(f"[{time.strftime('%H:%M:%S')}] Unblocking bluetooth adapter")
    run_command("rfkill unblock bluetooth")
    time.sleep(1)

    print(f"[{time.strftime('%H:%M:%S')}] Powering off/on bluetooth adapter")
    run_command("bluetoothctl power off")
    time.sleep(1)
    run_command("bluetoothctl power on")
    time.sleep(2)

    print(f"[{time.strftime('%H:%M:%S')}] Cleaning all known devices")
    returncode, stdout, stderr = run_command("bluetoothctl devices")
    if stdout and stdout.strip():
        for line in stdout.strip().split('\n'):
            if line.strip() and line.startswith('Device'):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    mac = parts[1]
                    run_command(f"bluetoothctl remove {mac}")
    
    print(f"[{time.strftime('%H:%M:%S')}] Scanning for devices for {duration} seconds...")
    # Create a script that runs bluetoothctl interactively
    scan_script = f"(echo 'scan on'; sleep {duration}; echo 'scan off') | bluetoothctl > /dev/null 2>&1 &"
    subprocess.Popen(scan_script, shell=True)
    time.sleep(duration + 1)
    
    # Get list of devices
    returncode, stdout, stderr = run_command("bluetoothctl devices")

    devices = []
    if stdout and stdout.strip():
        for line in stdout.strip().split('\n'):
            if line.strip() and line.startswith('Device'):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    mac = parts[1]
                    name = parts[2] if len(parts) > 2 else "(Unknown)"
                    # Only include audio devices
                    if _is_audio_device(mac):
                        devices.append((mac, name))

    return devices

def _is_audio_device(mac_address):
    returncode, stdout, stderr = run_command(f"bluetoothctl info {mac_address}")
    if returncode != 0:
        return False
    
    if 'Icon: audio-card' in stdout or 'Icon: audio-headset' in stdout:
        return True
    
    return False

def list_bluetooth_devices(duration):
    print(f"[{time.strftime('%H:%M:%S')}] Scanning (this will take about {duration} seconds)...")
    devices = _get_devices(duration)
    if len(devices) == 0:
        print("\n✗ No devices found!")
    else: 
        print("\nAvailable Bluetooth devices:")
        print("=" * 70)
        for mac, name in devices:
            print(f"MAC: {mac:20} Name: {name}")
        print("=" * 70)
        print(f"\nFound {len(devices)} device(s)")

def connect_bluetooth(mac_address, duration):
    returncode, stdout, stderr = run_command(f"bluetoothctl info {mac_address}")
    if "Connected: yes" in stdout:
        print(f"[{time.strftime('%H:%M:%S')}] ✓ {mac_address} is connected")
        return True
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ {mac_address} is not connected")

    print(f"[{time.strftime('%H:%M:%S')}] Scanning for {mac_address} ({duration}s)...")
    
    macs = _get_devices(duration=duration)
    if not any(mac == mac_address for mac, name in macs):
        print(f"[{time.strftime('%H:%M:%S')}] ✗ {mac_address} not found")
        return False
    
    # Use pexpect with interactive bluetoothctl session to handle passkey confirmation
    print(f"[{time.strftime('%H:%M:%S')}] Pairing with {mac_address}...")
    try:
        # Start interactive bluetoothctl session
        child = pexpect.spawn('bluetoothctl', timeout=30, encoding='utf-8')
        child.expect([r'\[bluetooth\]>', r'\[bluetoothctl\]>'], timeout=5)
        
        # Send pair command
        child.sendline(f'pair {mac_address}')
        
        while True:
            index = child.expect([
                r'Request confirmation',  # Confirmation request
                r'Confirm passkey (\d+)',   # Passkey confirmation with number
                r'\(yes/no\):',           # The actual prompt
                r'Pairing successful',
                r'Failed to pair',
                r'not available',
                pexpect.TIMEOUT
            ], timeout=20)
            
            if index == 0:  # Confirmation request detected
                print(f"[{time.strftime('%H:%M:%S')}] Passkey confirmation requested")
                # Continue to wait for the yes/no prompt
                continue
            elif index == 1:  # Passkey confirmation with number
                passkey = child.match.group(1)
                print(f"[{time.strftime('%H:%M:%S')}] Passkey: {passkey}")
                # Continue to wait for the yes/no prompt
                continue
            elif index == 2:  # yes/no prompt
                print(f"[{time.strftime('%H:%M:%S')}] Auto-confirming passkey")
                child.sendline('yes')
            elif index == 3:  # Pairing successful
                print(f"[{time.strftime('%H:%M:%S')}] ✓ Pairing with {mac_address} successful")
                break
            elif index == 4 or index == 5:  # Failed to pair or not available
                print(f"[{time.strftime('%H:%M:%S')}] ✗ Pairing with {mac_address} failed")
                child.sendline('quit')
                child.close()
                return False
            elif index == 6:  # Timeout
                output = child.before if child.before else ""
                if 'Pairing successful' in output:
                    print(f"[{time.strftime('%H:%M:%S')}] ✓ Pairing with {mac_address} successful")
                    break
                else:
                    print(f"[{time.strftime('%H:%M:%S')}] ✗ Pairing with {mac_address} timed out")
                    child.sendline('quit')
                    child.close()
                    return False
        
        child.sendline('quit')
        child.close()
    except Exception as e:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ Pairing error: {e}")
        return False
    
    returncode, stdout, stderr = run_command(f"bluetoothctl connect {mac_address}", timeout=20)
    if returncode == 0:
        print(f"[{time.strftime('%H:%M:%S')}] ✓ Connection to {mac_address} successful")
        return True
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ Connection to {mac_address} failed: {stdout}")
        return False

def play_keepalive_sound():
    """Play a very brief sound through PulseAudio to keep Bluetooth alive"""
    try:
        # Get volume from environment variable or use default
        volume = int(os.getenv('BT_KEEPALIVE_VOLUME', DEFAULT_KEEPALIVE_VOLUME))
        
        # Play a system sound at configured volume
        cmd = f"paplay --volume={volume} /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null"
        returncode, stdout, stderr = run_command(cmd, timeout=5)
        
        if returncode == 0:
            print(f"[{time.strftime('%H:%M:%S')}] ♪ Keepalive sound played (volume: {volume})")
            return True
        else:
            print(f"[{time.strftime('%H:%M:%S')}] ⚠ Keepalive failed: {stderr}")
            return False
    except Exception as e:
        print(f"[{time.strftime('%H:%M:%S')}] ⚠ Keepalive error: {e}")
        return False

def monitor_connection(mac_address, duration, check_interval=30):
    print(f"[{time.strftime('%H:%M:%S')}] Monitoring {mac_address} (check every {check_interval}s)")
    
    try:
        while True:
            is_connected = connect_bluetooth(mac_address, duration)
            if is_connected:
                play_keepalive_sound()
            time.sleep(check_interval)
            
    except KeyboardInterrupt:
        print(f"\n[{time.strftime('%H:%M:%S')}] Monitoring stopped")
        sys.exit(0)

def main():
    parser = argparse.ArgumentParser(
        description="Connect to a Bluetooth speaker and play a system sound"
    )
    
    # Create mutually exclusive group for --mac and --list
    group = parser.add_mutually_exclusive_group(required=True)
    
    group.add_argument(
        "--mac",
        help="MAC address of the Bluetooth speaker (e.g., AA:BB:CC:DD:EE:FF)"
    )

    group.add_argument(
        "--list",
        action="store_true",
        help="List all available Bluetooth devices"
    )
    
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_CONNECTION_TIMEOUT,
        metavar="SECONDS",
        help=f"Scan timeout in seconds (default: {DEFAULT_CONNECTION_TIMEOUT})"
    )
    parser.add_argument(
        "--monitor",
        action="store_true",
        help="Keep monitoring and maintain the connection"
    )
    parser.add_argument(
        "--check-interval",
        type=int,
        default=DEFAULT_CHECK_INTERVAL,
        metavar="SECONDS",
        help=f"Connection check interval in seconds when monitoring (default: {DEFAULT_CHECK_INTERVAL})"
    )
    
    args = parser.parse_args()
    
    if args.list:
        list_bluetooth_devices(duration=args.timeout)
        return
    
    if args.monitor:
        monitor_connection(
            args.mac, 
            duration=args.timeout, 
            check_interval=args.check_interval
        )
    else:
        connect_bluetooth(args.mac, duration=args.timeout)

if __name__ == "__main__":
    main()
