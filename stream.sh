#!/bin/bash

# Configuration
URL=${STREAM_URL:-"https://datamk-trading-pulse.hf.space"}
AUDIO_FILE=${AUDIO_FILE:-"Cool Revenge.mp3"}
RESOLUTION=${RESOLUTION:-"3840x2160"}
BITRATE=${BITRATE:-"15000k"}
FPS=${FPS:-"30"}
ZOOM=${ZOOM:-"1.5"}
DEPTH="24"
DISPLAY_NUM=":99"
RTMP_URL=${RTMP_URL:-""}

# Cleanup on exit
cleanup() {
    echo "[stream.sh] Cleaning up..."
    kill $(jobs -p) 2>/dev/null || true
    pkill -9 -f "chromium.*chrome-data" 2>/dev/null || true
    pkill -9 -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
    rm -rf /tmp/chrome-data/Singleton* 2>/dev/null || true
}
trap cleanup EXIT

# 0. Pre-start cleanup of old instances
echo "[stream.sh] Performing pre-start cleanup of stale processes and locks..."
pkill -9 -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
pkill -9 -f "chromium.*chrome-data" 2>/dev/null || true
pkill -9 -f "ffmpeg.*$DISPLAY_NUM" 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
rm -rf /tmp/chrome-data/Singleton* 2>/dev/null || true
sleep 1

# 1. Start D-Bus and PulseAudio 
echo "[stream.sh] Ensuring D-Bus and PulseAudio..."
export $(dbus-launch) 2>/dev/null || true
pulseaudio -D --exit-idle-time=-1 --disallow-exit 2>/dev/null || true
pactl load-module module-null-sink sink_name=dummy_sink 2>/dev/null || true
pactl set-default-sink dummy_sink 2>/dev/null || true

# 2. Start Xvfb
echo "[stream.sh] Starting Xvfb on $DISPLAY_NUM with $RESOLUTION..."
Xvfb $DISPLAY_NUM -screen 0 ${RESOLUTION}x${DEPTH} > /dev/null 2>&1 &
sleep 2

export DISPLAY=$DISPLAY_NUM

# Disable DPMS and screensaver on Xvfb display to prevent black screen
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

# 3. Chromium launcher & watchdog
W=$(echo $RESOLUTION | cut -d'x' -f1)
H=$(echo $RESOLUTION | cut -d'x' -f2)

launch_chromium() {
    echo "[stream.sh] Starting Chromium in kiosk mode ($URL)..."
    rm -rf /tmp/chrome-data/Singleton* 2>/dev/null || true
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
        --disable-web-security \
        --allow-running-insecure-content \
        --disable-site-isolation-trials \
        --disk-cache-size=1 \
        --no-zygote \
        --disable-gpu \
        --remote-debugging-port=9222 \
        --log-level=3 \
        "$URL" > /dev/null 2>&1 &
}

launch_chromium

# Chromium Watchdog running in background
(
    while true; do
        sleep 15
        if ! pgrep -f "chromium.*chrome-data" > /dev/null 2>&1; then
            echo "[watchdog] WARNING: Chromium process died. Restarting Chromium..."
            launch_chromium
        fi
    done
) &

echo "[stream.sh] Waiting 15s for browser to render initial page..."
sleep 15

# 4. Start FFmpeg
if [ -z "$RTMP_URL" ]; then
    echo "[stream.sh] ERROR: RTMP_URL is not set. Streaming cannot start."
    exit 1
fi

IFS=', ' read -r -a URL_ARRAY <<< "$RTMP_URL"

AUDIO_FILE=${AUDIO_FILE:-"Cool Revenge.mp3"}
if [ "${USE_DUMMY_AUDIO:-0}" = "1" ] || [ ! -f "$AUDIO_FILE" ]; then
    AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100")
    AUDIO_CODEC_ARGS=(-c:a aac -b:a 128k -ar 44100)
else
    AUDIO_INPUT_ARGS=(-stream_loop -1 -i "$AUDIO_FILE")
    AUDIO_CODEC_ARGS=(-c:a aac -b:a 192k -ar 44100)
fi

echo "[stream.sh] Starting persistent stream auto-reconnect loop..."

RETRY_COUNT=0

while true; do
    TEE_OUTPUTS=()
    RESOLVED_URLS=()
    for URL in "${URL_ARRAY[@]}"; do
        URL=$(echo "$URL" | xargs)
        if [ -z "$URL" ]; then
            continue
        fi
        
        HOSTNAME=$(echo "$URL" | sed -e 's|rtmp://||' -e 's|/.*||')
        echo "[stream.sh] Checking DNS for $HOSTNAME..."
        
        RESOLVED_IP=$(getent hosts "$HOSTNAME" | awk '{print $1}')
        
        if [ -z "$RESOLVED_IP" ]; then
            echo "[stream.sh] WARNING: System resolver failed for $HOSTNAME. Trying DNS-over-HTTPS (Cloudflare)..."
            RESOLVED_IP=$(curl -s -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=$HOSTNAME&type=A" | jq -r '.Answer[0].data // empty')
            
            if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "null" ]; then
                echo "[stream.sh] SUCCESS: Resolved $HOSTNAME to $RESOLVED_IP via DoH."
                URL=$(echo "$URL" | sed "s|$HOSTNAME|$RESOLVED_IP|")
            else
                echo "[stream.sh] ERROR: DoH resolution also failed for $HOSTNAME. Skipping destination for this attempt."
                continue
            fi
        fi
        RESOLVED_URLS+=("$URL")
        TEE_OUTPUTS+=("[f=flv:onfail=ignore]${URL}")
    done

    if [ ${#RESOLVED_URLS[@]} -eq 0 ]; then
        echo "[stream.sh] WARNING: No valid RTMP destinations resolved. Internet or DNS down. Retrying in 10s..."
        sleep 10
        continue
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "[stream.sh] Connection attempt #$RETRY_COUNT starting..."

    if [ ${#RESOLVED_URLS[@]} -eq 1 ]; then
        SINGLE_URL="${RESOLVED_URLS[0]}"
        echo "[stream.sh] Connecting FFmpeg stream to destination: $SINGLE_URL"
        ffmpeg -f x11grab -draw_mouse 0 -video_size $RESOLUTION -framerate $FPS -i $DISPLAY_NUM.0+0,0 \
            "${AUDIO_INPUT_ARGS[@]}" \
            -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
            -b:v $BITRATE -minrate $BITRATE -maxrate $BITRATE -bufsize $BITRATE -nal-hrd cbr \
            -g 60 -keyint_min 60 -sc_threshold 0 \
            "${AUDIO_CODEC_ARGS[@]}" \
            -rw_timeout 10000000 \
            -f flv "$SINGLE_URL"
    else
        printf -v JOINED_OUTPUTS "%s|" "${TEE_OUTPUTS[@]}"
        JOINED_OUTPUTS="${JOINED_OUTPUTS%|}"
        echo "[stream.sh] Connecting FFmpeg stream to multiple destinations: $JOINED_OUTPUTS"
        ffmpeg -f x11grab -draw_mouse 0 -video_size $RESOLUTION -framerate $FPS -i $DISPLAY_NUM.0+0,0 \
            "${AUDIO_INPUT_ARGS[@]}" \
            -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
            -b:v $BITRATE -minrate $BITRATE -maxrate $BITRATE -bufsize $BITRATE -nal-hrd cbr \
            -g 60 -keyint_min 60 -sc_threshold 0 \
            "${AUDIO_CODEC_ARGS[@]}" \
            -rw_timeout 10000000 \
            -f tee -map 0:v -map 1:a "$JOINED_OUTPUTS"
    fi

    FFMPEG_EXIT_CODE=$?
    echo "[stream.sh] FFmpeg exited with status code $FFMPEG_EXIT_CODE."

    # Only exit loop if explicitly killed by SIGINT (130) or SIGTERM (143)
    if [ $FFMPEG_EXIT_CODE -eq 130 ] || [ $FFMPEG_EXIT_CODE -eq 143 ]; then
        echo "[stream.sh] FFmpeg stopped by user/system signal ($FFMPEG_EXIT_CODE). Exiting."
        break
    fi

    echo "[stream.sh] Connection interrupted or dropped. Auto-reconnecting in 5 seconds..."
    sleep 5
done
