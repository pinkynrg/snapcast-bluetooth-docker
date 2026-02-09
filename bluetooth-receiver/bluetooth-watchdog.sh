#!/bin/bash
# Bluetooth hardware watchdog for Raspberry Pi Zero
# This script monitors for Bluetooth hardware timeouts and automatically resets the adapter

CONTAINER_NAME="bluetooth-receiver"
CHECK_INTERVAL=30  # Check every 30 seconds
ERROR_THRESHOLD=3  # Reset after 3 consecutive errors

error_count=0

echo "Bluetooth watchdog started for container: $CONTAINER_NAME"

while true; do
    # Check for Bluetooth command timeouts in kernel log
    if dmesg | tail -50 | grep -q "Bluetooth: hci0: command.*tx timeout"; then
        error_count=$((error_count + 1))
        echo "$(date): Bluetooth hardware timeout detected ($error_count/$ERROR_THRESHOLD)"
        
        if [ $error_count -ge $ERROR_THRESHOLD ]; then
            echo "$(date): ERROR THRESHOLD REACHED - Resetting Bluetooth hardware"
            
            # Stop container
            docker stop $CONTAINER_NAME
            
            # Reset Bluetooth hardware
            hciconfig hci0 down
            rmmod btbcm 2>/dev/null || true
            rmmod hci_uart 2>/dev/null || true
            sleep 3
            modprobe hci_uart
            modprobe btbcm
            sleep 2
            hciconfig hci0 up
            
            # Start container
            docker start $CONTAINER_NAME
            
            echo "$(date): Bluetooth hardware reset complete"
            error_count=0
            
            # Wait longer after reset
            sleep 60
        fi
    else
        # No errors, reset counter
        if [ $error_count -gt 0 ]; then
            echo "$(date): No recent errors, resetting counter"
        fi
        error_count=0
    fi
    
    sleep $CHECK_INTERVAL
done
