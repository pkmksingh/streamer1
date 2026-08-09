#!/bin/bash

# Configuration
URL=${STREAM_URL:-"https://datamk-trading-pulse.hf.space"}
AUDIO_FILE=${AUDIO_FILE:-"Cool Revenge.mp3"}
RESOLUTION=${RESOLUTION:-"1920x1080"}
BITRATE=${BITRATE:-"2500k"}
FPS=${FPS:-"20"}
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

# Configure Google Public DNS for system resolver if permission allows
echo "[stream.sh] Setting Google Public DNS (8.8.8.8 / 8.8.4.4)..."
(echo "nameserver 8.8.8.8" > /etc/resolv.conf && echo "nameserver 8.8.4.4" >> /etc/resolv.conf) 2>/dev/null || true

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

# Helper: Google DNS & Google DoH Resolver
resolve_google_dns() {
    local target_host="$1"
    local ip=""
    
    # 1. Query Google Primary DNS (8.8.8.8) via dig
    ip=$(dig @8.8.8.8 +short +time=2 +tries=2 "$target_host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    
    # 2. Query Google Secondary DNS (8.8.4.4) via dig
    if [ -z "$ip" ]; then
        ip=$(dig @8.8.4.4 +short +time=2 +tries=2 "$target_host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    fi
    
    # 3. Query Google DNS-over-HTTPS (DoH) API via curl
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 4 "https://dns.google/resolve?name=$target_host&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1)
    fi

    # 4. Fallback Google DoH via 8.8.8.8 IP direct
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        ip=$(curl -s --max-time 4 -H "Host: dns.google" "https://8.8.8.8/resolve?name=$target_host&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n 1)
    fi

    echo "$ip"
}

# 3. Chromium launcher & watchdog
W=$(echo $RESOLUTION | cut -d'x' -f1)
H=$(echo $RESOLUTION | cut -d'x' -f2)

launch_chromium() {
    echo "[stream.sh] Starting Chromium with Google DNS ($URL)..."
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
        --disable-software-rasterizer \
        --renderer-process-limit=1 \
        --js-flags="--max-old-space-size=256" \
        --memory-pressure-off \
        --disable-extensions \
        --enable-async-dns \
        --dns-server="8.8.8.8,8.8.4.4" \
        --dns-over-https-mode=automatic \
        --dns-over-https-templates="https://dns.google/dns-query{?dns}" \
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
        echo "[stream.sh] Resolving DNS for $HOSTNAME using Google DNS (8.8.8.8 / 8.8.4.4 / dns.google)..."
        
        RESOLVED_IP=$(resolve_google_dns "$HOSTNAME")
        
        if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "null" ]; then
            echo "[stream.sh] SUCCESS: Google DNS resolved $HOSTNAME -> $RESOLVED_IP"
            URL=$(echo "$URL" | sed "s|$HOSTNAME|$RESOLVED_IP|")
        else
            echo "[stream.sh] WARNING: Google DNS failed for $HOSTNAME. Trying system resolver fallback..."
            RESOLVED_IP=$(getent hosts "$HOSTNAME" | awk '{print $1}')
            if [ -n "$RESOLVED_IP" ]; then
                URL=$(echo "$URL" | sed "s|$HOSTNAME|$RESOLVED_IP|")
            else
                echo "[stream.sh] ERROR: Could not resolve $HOSTNAME. Skipping destination."
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

    KEYINT=$((FPS * 2))

    if [ ${#RESOLVED_URLS[@]} -eq 1 ]; then
        SINGLE_URL="${RESOLVED_URLS[0]}"
        echo "[stream.sh] Connecting FFmpeg stream to destination: $SINGLE_URL"
        ffmpeg -f x11grab -draw_mouse 0 -video_size $RESOLUTION -framerate $FPS -i $DISPLAY_NUM.0+0,0 \
            "${AUDIO_INPUT_ARGS[@]}" \
            -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
            -b:v $BITRATE -maxrate $BITRATE -bufsize 5000k \
            -g $KEYINT -keyint_min $KEYINT -sc_threshold 0 \
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
            -b:v $BITRATE -maxrate $BITRATE -bufsize 5000k \
            -g $KEYINT -keyint_min $KEYINT -sc_threshold 0 \
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
