#!/bin/sh
# Wrapper script to use environment variables with the Python script

# Build command arguments
ARGS="--monitor"

if [ -n "$BT_MAC" ]; then
    ARGS="$ARGS --mac $BT_MAC"
fi

if [ -n "$BT_TIMEOUT" ]; then
    ARGS="$ARGS --timeout $BT_TIMEOUT"
fi

if [ -n "$BT_CHECK_INTERVAL" ]; then
    ARGS="$ARGS --check-interval $BT_CHECK_INTERVAL"
fi

# Execute the Python script with constructed arguments
exec python3 /app/bluetooth-speaker-reconnector.py $ARGS "$@"
