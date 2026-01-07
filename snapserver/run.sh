#!/bin/bash
set -euo pipefail

sed -i "s,^source = .*,source = librespot:///librespot?name=Spotify\&devicename=$DEVICE_NAME\&bitrate=320\&volume=100\&cache=$CACHE," /etc/snapserver.conf

exec snapserver -c /etc/snapserver.conf
