#!/bin/bash

# Configuration
URL=${STREAM_URL:-"https://datamk-trading-pulse.hf.space"}
AUDIO_FILE=${AUDIO_FILE:-"Cool Revenge.mp3"}
RESOLUTION=${RESOLUTION:-"3840x2160"}
BITRATE=${BITRATE:-"15000k"}
FPS=${FPS:-"30"}
ZOOM=${ZOOM:-"1.0"}
DEPTH="24"
DISPLAY_NUM=":99"
RTMP_URL=${RTMP_URL:-""}

# Cleanup on exit
cleanup() {
    echo "Cleaning up..."
    kill $(jobs -p) 2>/dev/null
    rm -f /tmp/.X99-lock
}
trap cleanup EXIT

# 1. Start D-Bus and PulseAudio 
echo "Ensuring D-Bus and PulseAudio..."
export $(dbus-launch) 2>/dev/null || true
pulseaudio -D --exit-idle-time=-1 --disallow-exit 2>/dev/null || true
pactl load-module module-null-sink sink_name=dummy_sink 2>/dev/null || true
pactl set-default-sink dummy_sink 2>/dev/null || true

# 2. Start Xvfb
echo "Starting Xvfb on $DISPLAY_NUM with $RESOLUTION..."
Xvfb $DISPLAY_NUM -screen 0 ${RESOLUTION}x${DEPTH} > /dev/null 2>&1 &
sleep 2

export DISPLAY=$DISPLAY_NUM


# 3. Start Chromium in Kiosk Mode (suppress all logs)
echo "Starting Chromium in kiosk mode..."
# Extract width and height from RESOLUTION (e.g., 3840x2160 -> 3840, 2160)
W=$(echo $RESOLUTION | cut -d'x' -f1)
H=$(echo $RESOLUTION | cut -d'x' -f2)

chromium \
    --no-sandbox \
    --disable-setuid-sandbox \
    --kiosk \
    --user-data-dir=/tmp/chrome-data \
    --force-device-scale-factor=$ZOOM \
    --window-size=$W,$H \
    --window-position=0,0 \
    --disable-notifications \
    --disable-infobars \
    --disable-dev-shm-usage \
    --no-first-run \
    --hide-scrollbars \
    --autoplay-policy=no-user-gesture-required \
    --no-zygote \
    --disable-gpu \
    --disable-features=VizDisplayCompositor \
    --remote-debugging-port=9222 \
    --log-level=3 \
    --silent-debugger-extension-api \
    "$URL" > /dev/null 2>&1 &
sleep 30

# 3. Start FFmpeg
if [ -z "$RTMP_URL" ]; then
    echo "ERROR: RTMP_URL is not set. Streaming cannot start."
    exit 1
fi

# Extract hostname for DNS check
HOSTNAME=$(echo "$RTMP_URL" | sed -e 's|rtmp://||' -e 's|/.*||')
echo "Checking DNS for $HOSTNAME..."

RESOLVED_IP=$(getent hosts "$HOSTNAME" | awk '{print $1}')

if [ -z "$RESOLVED_IP" ]; then
    echo "WARNING: System resolver failed for $HOSTNAME. Trying DNS-over-HTTPS (Cloudflare)..."
    RESOLVED_IP=$(curl -s -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$HOSTNAME&type=A" | jq -r '.Answer[0].data // empty')
    
    if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "null" ]; then
        echo "SUCCESS: Resolved $HOSTNAME to $RESOLVED_IP via DoH."
        # Update RTMP_URL to use IP
        RTMP_URL=$(echo "$RTMP_URL" | sed "s|$HOSTNAME|$RESOLVED_IP|")
        echo "New RTMP URL: $RTMP_URL"
    else
        echo "ERROR: DoH resolution also failed for $HOSTNAME."
        exit 1
    fi
fi

echo "Starting FFmpeg 4K stream with looped audio to $RTMP_URL..."

# Audio: use dummy by default or mp3 if available and requested  
AUDIO_FILE=${AUDIO_FILE:-"Cool Revenge.mp3"}
if [ "${USE_DUMMY_AUDIO:-0}" = "1" ] || [ ! -f "$AUDIO_FILE" ]; then
    AUDIO_INPUT="-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100"
    AUDIO_CODEC="-c:a aac -b:a 128k -ar 44100"
else
    AUDIO_INPUT="-stream_loop -1 -i \"$AUDIO_FILE\""
    AUDIO_CODEC="-c:a aac -b:a 192k -ar 44100"
fi

eval ffmpeg -f x11grab -draw_mouse 0 -video_size $RESOLUTION -framerate $FPS -i $DISPLAY_NUM.0+0,0 \
    $AUDIO_INPUT \
    -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
    -b:v $BITRATE -maxrate $BITRATE -bufsize 30000k \
    -g 60 -keyint_min 60 -sc_threshold 0 \
    $AUDIO_CODEC \
    -f flv "$RTMP_URL"
