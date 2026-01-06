#!/usr/bin/env python3
"""
Bluetooth speaker connection script.
Connects to a Bluetooth device by MAC address and plays a system sound.
"""

import argparse
import subprocess
import time
import sys

DEFAULT_CONNECTION_TIMEOUT = 15

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

    print(f"[{time.strftime('%H:%M:%S')}] Removing trusted devices")
    returncode, stdout, stderr = run_command("bluetoothctl devices")
    if stdout and stdout.strip():
        for line in stdout.strip().split('\n'):
            if line.strip() and line.startswith('Device'):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    mac = parts[1]
                    run_command(f"bluetoothctl remove {mac}")
    
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
                    devices.append((mac, name))

    return devices

def _play_sound():
    print(f"[{time.strftime('%H:%M:%S')}] Playing connection sound...")
    run_command("timeout 1s speaker-test --test sine --frequency 440", timeout=1)
    print(f"[{time.strftime('%H:%M:%S')}] ✓ Sound played")

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
        print(f"[{time.strftime('%H:%M:%S')}] ✓ {mac_address} is connection")
        return True
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ {mac_address} is not connected")

    print(f"[{time.strftime('%H:%M:%S')}] Scanning for {mac_address} ({duration}s)...")
    
    macs = _get_devices(duration=duration)
    if not any(mac == mac_address for mac, name in macs):
        print(f"[{time.strftime('%H:%M:%S')}] ✗ {mac_address} not found")
        return False
    
    returncode, stdout, stderr = run_command(f"bluetoothctl pair {mac_address}", timeout=20)
    if returncode == 0:
        print(f"[{time.strftime('%H:%M:%S')}] ✓ Pairing with {mac_address} successful")
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ Pairing with {mac_address} failed: {stdout}")
        return False
    
    returncode, stdout, stderr = run_command(f"bluetoothctl connect {mac_address}", timeout=20)
    if returncode == 0:
        print(f"[{time.strftime('%H:%M:%S')}] ✓ Connection to {mac_address} successful")
        _play_sound()
        return True
    else:
        print(f"[{time.strftime('%H:%M:%S')}] ✗ Connection to {mac_address} failed: {stdout}")
        return False

def monitor_connection(mac_address, duration, check_interval=30):
    print(f"[{time.strftime('%H:%M:%S')}] Monitoring {mac_address} (check every {check_interval}s)")
    
    try:
        while True:
            connect_bluetooth(mac_address, duration)
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
        default=30,
        metavar="SECONDS",
        help="Connection check interval in seconds when monitoring (default: 30)"
    )
    
    args = parser.parse_args()
    
    if args.list:
        list_bluetooth_devices(duration=args.timeout)
        return
    
    if args.monitor:
        monitor_connection(args.mac, duration=args.timeout, check_interval=args.check_interval)
    else:
        connect_bluetooth(args.mac, duration=args.timeout)

if __name__ == "__main__":
    main()
