#!/usr/bin/python3
"""Network setup fallback for a headless Mac (root LaunchDaemon local.netsetup).

Checked every 10 s:
  1. Online over Wi-Fi or Ethernet (saved networks join by themselves)  -> do nothing
  2. Offline for GRACE seconds and a phone is tethered over USB          -> serve the setup page
     on the tether; the Wi-Fi radio is free, so it scans live and joins while the phone stays put
The setup page lists nearby networks (via WifiScan.app in the user's session), takes a password
and joins. Logs: /var/log/ai-netsetup.log.  Force tether mode for testing: ai-netsetup-mode tether

There is no Wi-Fi hotspot fallback: on macOS 27 Internet Sharing only starts through Apple's own
apps (private entitlement), and even System Settings won't start it without a connection to share.
"""
import http.server, json, os, subprocess, threading, time, urllib.parse

GRACE = int(os.environ.get("NETSETUP_GRACE", "180"))
PORT = int(os.environ.get("NETSETUP_PORT", "80"))
HERE = os.path.dirname(os.path.abspath(__file__))
SCANNER = "/Applications/WifiScan.app/Contents/MacOS/WifiScan"
FORCE_FILE = "/var/run/ai-netsetup-force"     # contains "tether" (testing)
# After a successful join the page stays up this long on every network, as a confirmation with the
# Mac's new address: the cable link often drops the moment Wi-Fi comes up, so the phone may only see
# the result once it is on the same Wi-Fi itself.
CONFIRM_SECS = int(os.environ.get("NETSETUP_CONFIRM", "3600"))
TETHER_NET = "172.20.10."   # iPhone Personal Hotspot range; the only place a join may come from after setup


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def sh(*cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception as e:
        log("command failed:", cmd[0], e)
        return ""


# ---------------------------------------------------------------- interfaces
def hardware_ports():
    """{device: port name} from networksetup, e.g. {'en0': 'Ethernet', 'en1': 'Wi-Fi'}"""
    out, ports, name = sh("networksetup", "-listallhardwareports"), {}, None
    for line in out.splitlines():
        if line.startswith("Hardware Port:"): name = line.split(":", 1)[1].strip()
        elif line.startswith("Device:") and name: ports[line.split(":", 1)[1].strip()] = name
    return ports


def ipv4(dev):
    ip = sh("ipconfig", "getifaddr", dev).strip()
    return ip if ip and not ip.startswith("169.254.") else ""


def wifi_dev(ports):
    return next((d for d, n in ports.items() if n == "Wi-Fi"), "en1")


def online(ports):
    """Connected over Wi-Fi or wired Ethernet (not a phone tether)."""
    for dev, name in ports.items():
        if name == "Wi-Fi" or (("Ethernet" in name or "LAN" in name) and "Adapter" not in name):
            if ipv4(dev): return dev
    return ""


def wake_tether(ports):
    """macOS doesn't always bring an iPhone's USB link up, and the iPhone may not answer DHCP
    (seen on macOS 27 / iOS 26): bring the link up, try DHCP, else use the hotspot's fixed range."""
    for dev, name in ports.items():
        if "iPhone" not in name and "iPad" not in name: continue
        if "status: active" not in sh("ifconfig", dev):
            sh("ifconfig", dev, "up"); time.sleep(3)
        if "status: active" not in sh("ifconfig", dev) or ipv4(dev): continue
        sh("ipconfig", "set", dev, "DHCP")
        for _ in range(10):
            if ipv4(dev): break
            time.sleep(1)
        if not ipv4(dev):
            log("no DHCP from", name, "- using 172.20.10.2")
            sh("networksetup", "-setmanual", name, "172.20.10.2", "255.255.255.240", "172.20.10.1")
            time.sleep(2)


def option(dev, name):
    return sh("ipconfig", "getoption", dev, name).strip()


def network_info():
    """What the confirmation shows: the Mac's address on its new network and how to reach it."""
    ports = hardware_ports()
    dev = wifi_dev(ports)
    ip = ipv4(dev)
    if not ip: return None
    ether = ""
    for line in sh("ifconfig", dev).splitlines():
        if line.strip().startswith("ether "): ether = line.split()[1]
    info = {"ip": ip, "subnet": option(dev, "subnet_mask"), "router": option(dev, "router"),
            "dns": option(dev, "domain_name_server"), "mac": ether, "device": dev,
            "host": sh("scutil", "--get", "LocalHostName").strip()}
    try:   # Tailscale, if it's set up and connected (reachable from anywhere)
        ts = json.loads(sh("/opt/homebrew/bin/tailscale", "status", "--json", timeout=10) or "{}").get("Self") or {}
        if ts.get("Online"):
            info["tailscale_name"] = (ts.get("DNSName") or "").rstrip(".")
            info["tailscale_ip"] = next((a for a in ts.get("TailscaleIPs") or [] if "." in a), "")
    except (ValueError, AttributeError):
        pass
    return info


def from_tether(addr):
    return addr.startswith(TETHER_NET)


def tether(ports):
    """A phone sharing its connection over USB: iPhone USB, or any unknown en* with an address."""
    known = {d for d, n in ports.items() if n == "Wi-Fi" or "Ethernet" in n or "LAN" in n or "Thunderbolt" in n}
    for dev in sh("ifconfig", "-l").split():
        if dev.startswith("en") and dev not in known and ipv4(dev):
            return dev
    return ""


# ---------------------------------------------------------------- Wi-Fi via the user's session
def console_uid():
    try: return os.stat("/dev/console").st_uid
    except OSError: return 0


def scanner(*args, timeout=100):
    """Run WifiScan.app as the logged-in user (it holds the Location permission); returns JSON."""
    uid = console_uid()
    if uid == 0 or not os.path.exists(SCANNER): return None
    out = f"/var/tmp/ai-netsetup-{os.getpid()}-{time.time_ns()}.json"
    user = sh("id", "-un", str(uid)).strip()
    sh("launchctl", "asuser", str(uid), "sudo", "-u", user, "open", "-W", "-n", "-g",
       "-a", "/Applications/WifiScan.app", "--args", *args, "--out", out, timeout=timeout)
    try:
        with open(out) as f: return json.load(f)
    except Exception: return None
    finally:
        try: os.remove(out)
        except OSError: pass


class State:
    mode = "idle"          # idle | tether
    networks = []          # last scan
    scanned_at = 0
    joining = ""           # ssid being joined
    result = None          # {"ok":..., "error":..., "ssid":...}
    result_at = 0          # when the last join finished
    idle_since = 0         # when the current idle period began
    lock = threading.Lock()
    post_lock = threading.Lock()


def refresh_scan(force=False):
    if not force and time.time() - State.scanned_at < 20: return
    nets = scanner()
    if isinstance(nets, list):
        State.networks, State.scanned_at = nets, time.time()


def join(ssid, password):
    with State.lock:
        State.result = None
        pw_file = f"/var/tmp/ai-netsetup-pw-{time.time_ns()}"
        res = {}
        try:
            if console_uid() == 0:   # login window (auto-login failed or not finished): no user session
                res = {"ok": False, "error": "Nobody is logged in on the Mac yet, so it can't join Wi-Fi from here. "
                                             "Wait a minute after it starts, or use a monitor and keyboard"}
            else:
                fd = os.open(pw_file, os.O_WRONLY | os.O_CREAT, 0o600)
                os.write(fd, password.encode()); os.close(fd)
                os.chown(pw_file, console_uid(), -1)
                res = scanner("--join", ssid, pw_file) or {"ok": False, "error": "Wi-Fi helper didn't answer"}
                ports = hardware_ports()
                if res.get("ok"):
                    for _ in range(20):        # wait for an address
                        if ipv4(wifi_dev(ports)): break
                        time.sleep(1)
                    res = res if ipv4(wifi_dev(ports)) else {"ok": False, "error": "Joined, but got no address from the router"}
        except Exception as e:
            log("join error:", e)
            res = {"ok": False, "error": "Something went wrong on the Mac. Try again"}
        finally:
            try: os.remove(pw_file)
            except OSError: pass
        res["ssid"] = ssid
        log("join", ssid, "->", res)
        State.result, State.result_at = res, time.time()
        try:
            if res.get("ok"):
                if os.path.exists(FORCE_FILE): os.remove(FORCE_FILE)   # a successful join ends a forced test
                set_mode("idle")
        finally:
            State.joining = ""   # last, so the main loop never acts on a half-finished join


# ---------------------------------------------------------------- setup page
PAGE = open(os.path.join(HERE, "portal.html")).read()   # __MODEL__ is replaced by the model name
MODEL = None


def model_name():
    """The Mac's model name ("Mac mini", "Mac Studio", "MacBook Pro"), or "Mac". Read once."""
    global MODEL
    if MODEL is None:
        name = ""
        for line in sh("system_profiler", "SPHardwareDataType").splitlines():
            if line.strip().startswith("Model Name:"):
                name = line.split(":", 1)[1].strip()
                break
        # Safe in HTML text and inside the page's JavaScript strings
        name = "".join(c for c in name if c.isalnum() and c.isascii() or c in " ().,-").strip()
        MODEL = name or "Mac"
    return MODEL


def page():
    return PAGE.replace("__MODEL__", model_name())


class Portal(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def may_change(self):
        """Scanning and joining: from anyone while the Mac is offline (only the phone can reach it
        then), but once it's on a network only from the phone's cable, never from the network."""
        return State.mode == "tether" or from_tether(self.client_address[0])

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if State.mode == "idle" and not State.result:
            return self.send(200, "<p>This Mac is online. Nothing to set up.</p>")
        if path == "/api/networks":
            if not self.may_change(): return self.send(200, "[]", "application/json")
            refresh_scan(force="refresh" in self.path)
            return self.send(200, json.dumps(State.networks), "application/json")
        if path == "/api/status":
            host = sh("scutil", "--get", "LocalHostName").strip()
            user = sh("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser").strip()
            ok = bool(State.result and State.result.get("ok"))
            return self.send(200, json.dumps({"mode": State.mode, "joining": State.joining, "result": State.result,
                                              "host": host, "user": user, "net": network_info() if ok else None,
                                              "confirm_until": int(State.result_at + CONFIRM_SECS) if ok else 0}),
                             "application/json")
        self.send(200, page())

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/api/join": return self.send(404, "")
        if not self.may_change():
            return self.send(403, json.dumps({"error": "The Mac is already online. Change its Wi-Fi from the phone cable or System Settings"}), "application/json")
        n = int(self.headers.get("Content-Length", "0"))
        form = json.loads(self.rfile.read(min(n, 4096)) or b"{}")
        ssid, pw = str(form.get("ssid", ""))[:64], str(form.get("password", ""))[:128]
        if not ssid: return self.send(400, json.dumps({"error": "Pick a network"}), "application/json")
        with State.post_lock:   # test and set together, so a double tap can't start two joins
            if State.joining: return self.send(409, json.dumps({"error": "Already joining"}), "application/json")
            State.joining = ssid
        try:
            threading.Thread(target=join, args=(ssid, pw), daemon=True).start()
        except Exception:
            State.joining = ""; raise
        self.send(202, json.dumps({"ok": True}), "application/json")


# ---------------------------------------------------------------- main loop
servers = {}


def serve():
    if "web" not in servers:
        srv = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Portal)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers["web"] = srv


def unserve():
    for k in list(servers):
        srv = servers.pop(k); srv.shutdown(); srv.server_close()


def unserve_if_still_idle(since):
    # only if nothing changed since this idle period began (a later tether/idle cycle has its own timer)
    if State.mode != "idle" or State.idle_since != since: return
    if State.joining: threading.Timer(30, unserve_if_still_idle, args=(since,)).start()   # after the join
    else:
        unserve()
        State.result = None   # the confirmation is over; a later setup starts fresh


def set_mode(mode):
    if mode == "tether": serve()   # first, and on every check: if port 80 was busy, the next check retries
    if mode == State.mode: return
    log("mode", State.mode, "->", mode)
    State.mode = mode
    if mode == "idle":
        State.idle_since = since = time.time()
        # Right after a successful join: the confirmation page, for CONFIRM_SECS. Otherwise 2 minutes.
        ok = State.result and State.result.get("ok") and time.time() - State.result_at < 60
        threading.Timer(CONFIRM_SECS if ok else 120, unserve_if_still_idle, args=(since,)).start()
    else:
        if time.time() - State.result_at > 120: State.result = None   # keep a fresh result for the page
        threading.Thread(target=refresh_scan, args=(True,), daemon=True).start()


def main():
    log("started, grace", GRACE, "s")
    offline_since = None
    while True:
        try:
            ports = hardware_ports()
            if State.joining:
                time.sleep(10); continue
            forced = os.path.exists(FORCE_FILE) and open(FORCE_FILE).read().strip() == "tether"
            if forced:
                set_mode("tether")
            elif online(ports):
                offline_since = None
                set_mode("idle")
            else:
                offline_since = offline_since or time.time()
                if time.time() - offline_since >= GRACE:
                    wake_tether(ports)   # also revives a tether link that dropped
                    set_mode("tether" if tether(ports) else "idle")
        except Exception as e:
            log("error:", e)
        time.sleep(10)


if __name__ == "__main__":
    main()
