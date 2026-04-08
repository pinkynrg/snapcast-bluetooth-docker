#!/bin/sh
# Wrapper for snapserver process:// sources.
# Decodes an internet radio stream to raw PCM with volume reduction.
# Usage: play-radio.sh <stream-url> [volume]
#   volume: 0.0-1.0 (default 0.1 = -20dB)
URL="$1"
VOL="${2:-0.1}"
exec ffmpeg -hide_banner -loglevel quiet -re -i "$URL" -af "volume=$VOL" -f s16le -ar 44100 -ac 2 -
