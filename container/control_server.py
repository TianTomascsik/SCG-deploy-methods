#!/usr/bin/env python3
"""
SCG Gateway Control Server — Toggle HTTP/HTTPS mode.

Serves a web UI on port 9090 that allows toggling between:
- HTTP mode: socat forwards port 8080 directly to NGINX (plain HTTP)
- HTTPS mode: SCG gateway listens on port 8080 with TLS, forwards to NGINX

No external dependencies — uses only Python stdlib.
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import threading
import time

NGINX_HOST = os.environ.get("NGINX_HOST", "172.29.0.10")
NGINX_PORT = os.environ.get("NGINX_PORT", "80")
LISTEN_PORT = os.environ.get("LISTEN_PORT", "8080")
CONTROL_PORT = int(os.environ.get("CONTROL_PORT", "9090"))
GATEWAY_CONFIG = "/etc/gateway/config.json"

# Global state
state = {
    "mode": "http",  # "http" or "https"
    "switching": False,
}
socat_proc = None
gateway_proc = None
lock = threading.Lock()


def generate_gateway_config():
    """Generate the SCG gateway JSON config for TLS termination."""
    config = {
        "log_level": "info",
        "sock_buf_size": 16777216,
        "policy": {
            "default_action": "allow",
            "whitelist": []
        },
        "rules": [
            {
                "name": "https-termination",
                "direction": "decrypt",
                "listen_addr": f"0.0.0.0:{LISTEN_PORT}",
                "listen_proto": "tcp",
                "upstream_addr": f"{NGINX_HOST}:{NGINX_PORT}",
                "security_provider": "tls",
                "transparent": False,
                "protocol_version": "tls1.3",
                "priority": 0,
            }
        ],
    }
    os.makedirs(os.path.dirname(GATEWAY_CONFIG), exist_ok=True)
    with open(GATEWAY_CONFIG, "w") as f:
        json.dump(config, f, indent=2)


def start_socat():
    """Start socat to forward port 8080 → NGINX (HTTP passthrough)."""
    global socat_proc
    cmd = [
        "socat",
        f"TCP-LISTEN:{LISTEN_PORT},fork,reuseaddr",
        f"TCP:{NGINX_HOST}:{NGINX_PORT}",
    ]
    socat_proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
    print(f"[CONTROL] Started socat (HTTP mode) PID={socat_proc.pid}")


def stop_socat():
    """Stop socat and all its forked children."""
    global socat_proc
    if socat_proc and socat_proc.poll() is None:
        # Kill the process group to catch all forked children
        pid = socat_proc.pid
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            socat_proc.terminate()
        socat_proc.wait(timeout=5)
        print("[CONTROL] Stopped socat")
    # Also kill any remaining socat processes
    subprocess.run(["pkill", "-f", "socat.*TCP-LISTEN"], capture_output=True)
    socat_proc = None


def start_gateway():
    """Start the SCG gateway (HTTPS mode)."""
    global gateway_proc
    generate_gateway_config()
    cmd = ["gateway", "--config", GATEWAY_CONFIG]
    gateway_proc = subprocess.Popen(cmd)
    print(f"[CONTROL] Started gateway (HTTPS mode) PID={gateway_proc.pid}")


def stop_gateway():
    """Stop the SCG gateway."""
    global gateway_proc
    if gateway_proc and gateway_proc.poll() is None:
        gateway_proc.terminate()
        gateway_proc.wait(timeout=5)
        print("[CONTROL] Stopped gateway")
    gateway_proc = None


def switch_to_https():
    """Switch from HTTP to HTTPS mode."""
    with lock:
        if state["mode"] == "https" or state["switching"]:
            return
        state["switching"] = True

    try:
        stop_socat()
        time.sleep(0.5)  # Allow port to be released
        start_gateway()
        time.sleep(1.0)  # Allow gateway to bind
        with lock:
            state["mode"] = "https"
    finally:
        with lock:
            state["switching"] = False


def switch_to_http():
    """Switch from HTTPS to HTTP mode."""
    with lock:
        if state["mode"] == "http" or state["switching"]:
            return
        state["switching"] = True

    try:
        stop_gateway()
        time.sleep(0.5)  # Allow port to be released
        start_socat()
        with lock:
            state["mode"] = "http"
    finally:
        with lock:
            state["switching"] = False


HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SCG Gateway Control Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            background: #16213e;
            border-radius: 16px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
            max-width: 500px;
            width: 90%;
        }
        h1 {
            font-size: 1.5rem;
            margin-bottom: 8px;
            color: #fff;
        }
        .subtitle {
            color: #888;
            font-size: 0.9rem;
            margin-bottom: 30px;
        }
        .status-box {
            background: #0f3460;
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 24px;
        }
        .status-label {
            font-size: 0.85rem;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 8px;
        }
        .status-value {
            font-size: 2rem;
            font-weight: bold;
        }
        .status-http { color: #ff6b6b; }
        .status-https { color: #51cf66; }
        .status-switching { color: #ffd43b; }
        .toggle-btn {
            display: inline-block;
            padding: 14px 36px;
            font-size: 1rem;
            font-weight: 600;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.2s;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .toggle-btn:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
        .toggle-btn:active { transform: translateY(0); }
        .toggle-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
        .btn-enable { background: #51cf66; color: #1a1a2e; }
        .btn-disable { background: #ff6b6b; color: #fff; }
        .link-box {
            margin-top: 24px;
            padding: 16px;
            background: #0f3460;
            border-radius: 8px;
        }
        .link-box a {
            color: #74c0fc;
            text-decoration: none;
            font-size: 1.1rem;
            font-weight: 500;
        }
        .link-box a:hover { text-decoration: underline; }
        .link-box .hint {
            color: #666;
            font-size: 0.8rem;
            margin-top: 6px;
        }
        .info {
            margin-top: 20px;
            font-size: 0.8rem;
            color: #555;
            line-height: 1.6;
        }
        .lock-icon { font-size: 2.5rem; margin-bottom: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>SCG Gateway Control Panel</h1>
        <p class="subtitle">Secure Communication Gateway — TLS Proxy Demo</p>

        <div class="status-box">
            <div class="status-label">Current Mode</div>
            <div class="lock-icon" id="lock-icon">🔓</div>
            <div class="status-value" id="status">Loading...</div>
        </div>

        <button class="toggle-btn btn-enable" id="toggle-btn" onclick="toggle()">
            Loading...
        </button>

        <div class="link-box">
            <a id="access-link" href="http://localhost:8080" target="_blank">
                Open NGINX →
            </a>
            <div class="hint" id="access-hint">Access the web server on port 8080</div>
        </div>

        <div class="info">
            <strong>How it works:</strong><br>
            When HTTPS is enabled, the SCG gateway intercepts port 8080 via TPROXY.<br>
            Plain HTTP is <strong>blocked</strong> — only HTTPS connections are accepted.<br>
            When disabled, NGINX is accessible directly over plain HTTP.
        </div>
    </div>

    <script>
        let currentMode = 'unknown';
        let polling = null;

        async function fetchStatus() {
            try {
                const res = await fetch('/api/status');
                const data = await res.json();
                updateUI(data);
            } catch (e) {
                document.getElementById('status').textContent = 'Error';
            }
        }

        function updateUI(data) {
            const status = document.getElementById('status');
            const btn = document.getElementById('toggle-btn');
            const icon = document.getElementById('lock-icon');
            const link = document.getElementById('access-link');
            const hint = document.getElementById('access-hint');
            currentMode = data.mode;

            if (data.switching) {
                status.textContent = 'Switching...';
                status.className = 'status-value status-switching';
                icon.textContent = '⏳';
                btn.disabled = true;
                btn.textContent = 'Please wait...';
            } else if (data.mode === 'https') {
                status.textContent = 'HTTPS (TLS 1.3)';
                status.className = 'status-value status-https';
                icon.textContent = '🔒';
                btn.className = 'toggle-btn btn-disable';
                btn.textContent = 'Disable HTTPS';
                btn.disabled = false;
                link.href = 'https://localhost:8080';
                link.textContent = 'Open NGINX (HTTPS only) →';
                hint.textContent = '⚠️ HTTP is blocked — only HTTPS works on port 8080';
            } else {
                status.textContent = 'HTTP (Plain)';
                status.className = 'status-value status-http';
                icon.textContent = '🔓';
                btn.className = 'toggle-btn btn-enable';
                btn.textContent = 'Enable HTTPS';
                btn.disabled = false;
                link.href = 'http://localhost:8080';
                link.textContent = 'Open NGINX (HTTP) →';
                hint.textContent = 'Plain unencrypted — no TLS protection';
            }
        }

        async function toggle() {
            const btn = document.getElementById('toggle-btn');
            btn.disabled = true;

            const action = currentMode === 'https' ? 'http' : 'https';
            try {
                await fetch('/api/toggle', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ mode: action })
                });
            } catch (e) {}

            // Poll faster during switch
            setTimeout(fetchStatus, 500);
            setTimeout(fetchStatus, 1500);
            setTimeout(fetchStatus, 3000);
        }

        // Initial fetch and polling
        fetchStatus();
        polling = setInterval(fetchStatus, 3000);
    </script>
</body>
</html>"""


class ControlHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for the control panel."""

    def log_message(self, format, *args):
        # Suppress access logs for cleaner output
        pass

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        elif self.path == "/api/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            with lock:
                resp = json.dumps(state)
            self.wfile.write(resp.encode())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/toggle":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {}

            target_mode = data.get("mode", "")

            if target_mode == "https":
                threading.Thread(target=switch_to_https, daemon=True).start()
            elif target_mode == "http":
                threading.Thread(target=switch_to_http, daemon=True).start()

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True}).encode())
        else:
            self.send_error(404)


def main():
    print(f"[CONTROL] SCG Gateway Control Server")
    print(f"[CONTROL] NGINX upstream: {NGINX_HOST}:{NGINX_PORT}")
    print(f"[CONTROL] Traffic port:   {LISTEN_PORT}")
    print(f"[CONTROL] Control UI:     http://0.0.0.0:{CONTROL_PORT}")
    print()

    # Start in HTTP mode (socat passthrough)
    start_socat()
    print(f"[CONTROL] Initial mode: HTTP (socat → nginx)")
    print()

    # Start control server
    server = http.server.HTTPServer(("0.0.0.0", CONTROL_PORT), ControlHandler)
    print(f"[CONTROL] Control panel ready at http://localhost:{CONTROL_PORT}")
    print(f"[CONTROL] NGINX accessible at http://localhost:{LISTEN_PORT}")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[CONTROL] Shutting down...")
        stop_socat()
        stop_gateway()
        server.shutdown()


if __name__ == "__main__":
    main()
