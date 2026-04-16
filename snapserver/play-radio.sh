#!/bin/sh
# Wrapper for snapserver process:// sources.
# Decodes an internet radio stream to raw PCM with volume reduction.
# Usage: play-radio.sh <stream-url> [volume]
#   volume: 0.0-1.0 (default 0.1 = -20dB)
URL="$1"
VOL="${2:-0.1}"
LOGLEVEL=$([ "${RADIO_DEBUG}" = "true" ] && echo "warning" || echo "quiet")
exec ffmpeg -hide_banner -loglevel "$LOGLEVEL" -user_agent "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" -re -i "$URL" -af "volume=$VOL" -f s16le -ar 44100 -ac 2 -
