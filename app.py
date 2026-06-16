import os
import subprocess
import signal
import time
import json
import threading
import streamlit as st
from streamlit_autorefresh import st_autorefresh

# Global state
CONFIG_FILE = "stream_config.json"
DASHBOARD_URL = "https://datamk-trading-pulse.hf.space"

def load_config():
    """Load config from file, falling back to environment variables."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r") as f:
            try:
                return json.load(f)
            except Exception:
                pass
    # Default config
    return {
        "enabled": True,
        "rtmp_url": os.environ.get("RTMP_URL", "rtmp://x.rtmp.youtube.com/live2/xfy3-p65p-p1hq-041p-buxw, rtmp://live.twitch.tv/app/live_1352303410_mZ5822JKsRM1U8Uw7B1xM5QK9OK8JX"),
        "resolution": os.environ.get("RESOLUTION", "1920x1080"),
        "bitrate": os.environ.get("BITRATE", "5000k"),
        "fps": os.environ.get("FPS", "30"),
        "zoom": os.environ.get("ZOOM", "1.5"),
        "overlay_url": os.environ.get("OVERLAY_URL",
            "https://streamelements.com/overlay/68ae13eaceb05ce7a084a618/JX6ewgq8Pmqkp6EvngSMZZEKAk5dSAGWDGsd1pH7ooSjaPsY")
    }

def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f)

def generate_wrapper_html(overlay_url):
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.5">
    <title>Stream Wrapper</title>
    <style>
        body, html {{ margin: 0; padding: 0; width: 100vw; height: 100vh; overflow: hidden; background: black; }}
        .container {{ position: relative; width: 100%; height: 100%; }}
        iframe {{ position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: none; }}
        #dashboard {{ z-index: 1; }}
        #overlay {{ z-index: 10; pointer-events: none; background: transparent; }}
        #ist-clock {{
            position: fixed;
            top: 40%;
            right: 20%;
            transform: translateY(-50%);
            z-index: 999999;
            font-family: 'SF Pro Display', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            font-size: 26px;
            font-weight: 600;
            color: #ffffff;
            background: rgba(15, 23, 42, 0.65);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            padding: 12px 20px;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.15);
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
            letter-spacing: 0.5px;
            pointer-events: none;
            display: flex;
            align-items: center;
            gap: 8px;
            text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
        }}
    </style>
</head>
<body>
    <div class="container">
        <iframe src="{DASHBOARD_URL}" id="dashboard" allow="autoplay; encrypted-media"></iframe>
        <iframe src="{overlay_url}" id="overlay"></iframe>
    </div>
    <div id="ist-clock">--:-- -- ist</div>
    <script>
        function updateTime() {{
            const options = {{
                timeZone: 'Asia/Kolkata',
                hour: '2-digit',
                minute: '2-digit',
                hour12: true
            }};
            try {{
                const formatter = new Intl.DateTimeFormat('en-US', options);
                let timeStr = formatter.format(new Date());
                timeStr = timeStr.toLowerCase();
                document.getElementById('ist-clock').textContent = timeStr + ' ist';
            }} catch (e) {{
                console.error(e);
            }}
        }}
        setInterval(updateTime, 1000);
        updateTime();
    </script>
</body>
</html>"""
    with open("wrapper.html", "w") as f:
        f.write(html)

@st.cache_resource
def init_monitor():
    class StreamManager:
        def __init__(self):
            self.stream_process = None
            self.thread = threading.Thread(target=self.monitor_stream, daemon=True)
            self.thread.start()
            
            self.keep_alive_thread = threading.Thread(target=self.keep_alive, daemon=True)
            self.keep_alive_thread.start()
            
        def keep_alive(self):
            import urllib.request
            print("[monitor] Keep-alive thread started.", flush=True)
            while True:
                time.sleep(300)  # Ping every 5 minutes
                try:
                    space_host = os.environ.get("SPACE_HOST")
                    if space_host:
                        url = f"https://{space_host}"
                        urllib.request.urlopen(url, timeout=10).read()
                        print(f"[monitor] Keep-alive ping sent to {url}", flush=True)
                    else:
                        url = "http://localhost:8501/_stcore/health"
                        urllib.request.urlopen(url, timeout=10).read()
                        print("[monitor] Keep-alive ping sent to localhost", flush=True)
                except Exception as e:
                    print(f"[monitor] Keep-alive ping failed: {e}", flush=True)
                    
        def start_stream_logic(self, config):
            env = os.environ.copy()
            generate_wrapper_html(config['overlay_url'])
            # Point Chrome to the locally generated wrapper.html
            env["STREAM_URL"] = f"file://{os.path.abspath('wrapper.html')}"
            env["RTMP_URL"] = config["rtmp_url"]
            env["RESOLUTION"] = config["resolution"]
            env["BITRATE"] = config["bitrate"]
            env["FPS"] = str(config["fps"])
            env["ZOOM"] = str(config["zoom"])
            env["USE_DUMMY_AUDIO"] = "0"  # use mp3 if available, else fallback

            try:
                # Redirect output to /dev/null to avoid disk usage
                devnull = open(os.devnull, "w")
                self.stream_process = subprocess.Popen(
                    ["bash", "./stream.sh"],
                    stdout=devnull,
                    stderr=devnull,
                    env=env,
                    preexec_fn=os.setsid
                )
                print(f"[monitor] Stream started PID={self.stream_process.pid}", flush=True)
            except Exception as e:
                print(f"[monitor] Failed to start stream: {e}", flush=True)

        def monitor_stream(self):
            print("[monitor] Thread started. Waiting 15s for server to be ready...", flush=True)
            time.sleep(15)
            while True:
                try:
                    config = load_config()
                    if config.get("enabled") and config.get("rtmp_url"):
                        if self.stream_process is None or self.stream_process.poll() is not None:
                            print("[monitor] Auto-starting stream...", flush=True)
                            self.start_stream_logic(config)
                except Exception as e:
                    print(f"[monitor] Error: {e}", flush=True)
                time.sleep(8)
                
        def stop_stream(self):
            if self.stream_process and self.stream_process.pid:
                try:
                    os.killpg(os.getpgid(self.stream_process.pid), signal.SIGTERM)
                except:
                    pass
                self.stream_process = None
                
        def is_running(self):
            return self.stream_process is not None and self.stream_process.poll() is None
            
        def get_pid(self):
            return self.stream_process.pid if self.is_running() else None

    return StreamManager()

manager = init_monitor()

# -------------------------------------------------------------------
# Streamlit UI
# -------------------------------------------------------------------

st.set_page_config(page_title="Trading Pulse Streamer", layout="wide")

# Auto refresh every 6000ms (6 seconds)
st_autorefresh(interval=6000, key="status_refresh")

st.markdown("<h1 style='text-align: center; background: linear-gradient(90deg, #3b82f6, #10b981); -webkit-background-clip: text; -webkit-text-fill-color: transparent;'>Trading Pulse Streamer</h1>", unsafe_allow_html=True)
st.markdown("<p style='text-align: center;'>Capturing the pulse of the market at high resolution.</p>", unsafe_allow_html=True)

config = load_config()
is_running = manager.is_running()

# Status Banner
if is_running:
    st.success(f"🔴 Live — FFmpeg running (PID {manager.get_pid()}) — Auto-restart: ON")
else:
    if config.get("enabled"):
        st.warning("⏳ Starting... Enabled — monitor will start stream shortly...")
    else:
        st.error("⚫ Stopped — Stream disabled. Click Start to enable auto-restart mode.")

with st.expander("Stream Configuration", expanded=True):
    # Setup safe masking for display similar to the original JS function
    def mask_rtmp_url(url_string):
        if not url_string:
            return ""
        # Split by comma or space
        urls = [u.strip() for u in url_string.replace(",", " ").split() if u.strip()]
        masked_urls = []
        for url in urls:
            parts = url.split('/')
            if len(parts) > 4:
                key = parts[-1]
                masked_key = key[:4] + "••••-••••-••••-••••"
                masked_urls.append("/".join(parts[:-1]) + "/" + masked_key)
            else:
                masked_urls.append((url[:20] + "...") if url else "")
        return ", ".join(masked_urls)

    col_url1, col_url2 = st.columns(2)
    with col_url1:
        st.text_input("RTMP Destinations (Masked) 🔒", value=mask_rtmp_url(config.get("rtmp_url")), disabled=True, help="Protected — edit via Space Secrets (supports multiple comma-separated URLs)")
    with col_url2:
        overlay_val = config.get("overlay_url", "")
        # truncate overlay for display as original did
        overlay_display = (overlay_val[:50] + "...") if len(overlay_val) > 50 else overlay_val
        st.text_input("Overlay URL 🔒", value=overlay_display, disabled=True, help="Protected — edit via Space Secrets")

    col1, col2, col3 = st.columns(3)
    with col1:
        res_options = ["3840x2160", "1920x1080", "1280x720"]
        res_current = config.get("resolution", "3840x2160")
        res_index = res_options.index(res_current) if res_current in res_options else 0
        resolution = st.selectbox("Resolution", res_options, index=res_index)
        
    with col2:
        bitrate = st.text_input("Bitrate", value=config.get("bitrate", "15000k"))
        
    with col3:
        fps = st.number_input("FPS", min_value=10, max_value=60, value=int(config.get("fps", 30)))

    col_zoom, col_scale = st.columns(2)
    with col_zoom:
        zoom = st.slider("Stream Zoom (Readable Content)", min_value=1.0, max_value=3.0, step=0.1, value=float(config.get("zoom", 1.0)))
    with col_scale:
        preview_scale = st.slider("Preview Scale (Admin UI)", min_value=0.2, max_value=1.0, step=0.1, value=0.5)

    col_btn1, col_btn2 = st.columns(2)
    with col_btn1:
        if st.button("▶ Start Stream", use_container_width=True, disabled=config.get("enabled", False)):
            config["enabled"] = True
            config["resolution"] = resolution
            config["bitrate"] = str(bitrate)
            config["fps"] = int(fps)
            config["zoom"] = str(zoom)
            save_config(config)
            st.rerun()
            
    with col_btn2:
        if st.button("⏹ Stop Stream", use_container_width=True, disabled=not config.get("enabled", False)):
            config["enabled"] = False
            manager.stop_stream()
            save_config(config)
            st.rerun()

st.header("Dashboard Preview")

# Display the dashboard utilizing the preview scale parameter
scaled_html = f'''
<div style="overflow: hidden; border-radius: 0.5rem; background: #000; width: 100%;">
    <iframe src="{DASHBOARD_URL}" 
        style="
            transform: scale({preview_scale}); 
            transform-origin: top left; 
            width: {100/preview_scale}%; 
            height: {600/preview_scale}px; 
            border: none;
        ">
    </iframe>
</div>
'''

st.components.v1.html(scaled_html, height=600)
