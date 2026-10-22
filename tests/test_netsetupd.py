"""Pins the behaviour of netsetup/netsetupd.py. Run: /usr/bin/python3 -m unittest tests/test_netsetupd.py

Never binds port 80 and never runs networksetup: PORT is a free high port, sh/scanner are faked."""
import json, os, socket, sys, threading, unittest, urllib.error, urllib.request
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "netsetup"))


def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


PORT = _free_port()
os.environ["NETSETUP_PORT"] = str(PORT)
os.environ["NETSETUP_GRACE"] = "0"
import netsetupd  # noqa: E402

assert netsetupd.PORT == PORT and netsetupd.PORT != 80


class StopLoop(BaseException):
    pass


def fake_sh(*cmd, timeout=60):
    return {"scutil": "ai-mini\n", "defaults": "admin\n"}.get(cmd[0], "")


class Base(unittest.TestCase):
    def setUp(self):
        S = netsetupd.State
        S.mode, S.networks, S.scanned_at, S.joining, S.result = "idle", [], 0, "", None
        S.result_at = S.idle_since = 0
        netsetupd.MODEL = None
        self.patches = [
            mock.patch.object(netsetupd, "sh", fake_sh),
            mock.patch.object(netsetupd, "scanner", lambda *a, **k: None),
            mock.patch.object(netsetupd, "FORCE_FILE", "/nonexistent/ai-netsetup-force"),
            mock.patch.object(netsetupd.threading, "Timer", mock.MagicMock()),  # no 120 s timers
        ]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in self.patches: p.stop()
        netsetupd.unserve()

    def url(self, path): return f"http://127.0.0.1:{PORT}{path}"

    def get(self, path):
        with urllib.request.urlopen(self.url(path), timeout=5) as r:
            return r.status, r.read().decode()

    def post(self, path, obj):
        req = urllib.request.Request(self.url(path), json.dumps(obj).encode(), {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r: return r.status
        except urllib.error.HTTPError as e:
            return e.code


class MainLoop(Base):
    def one_pass(self, online):
        def stop(_): raise StopLoop
        with mock.patch.object(netsetupd, "hardware_ports", lambda: {"en1": "Wi-Fi"}), \
             mock.patch.object(netsetupd, "online", lambda ports: "en1" if online else ""), \
             mock.patch.object(netsetupd, "tether", lambda ports: "en5"), \
             mock.patch.object(netsetupd, "wake_tether", lambda ports: None), \
             mock.patch.object(netsetupd.time, "sleep", stop):
            with self.assertRaises(StopLoop): netsetupd.main()

    def test_online_with_tether_is_idle(self):
        self.one_pass(online=True)
        self.assertEqual(netsetupd.State.mode, "idle")
        self.assertNotIn("web", netsetupd.servers)

    def test_offline_past_grace_with_tether_serves_page(self):
        self.one_pass(online=False)
        self.assertEqual(netsetupd.State.mode, "tether")
        status, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(body, netsetupd.page())


class ModelName(Base):
    """The page names the actual model (system_profiler's Model Name), or just "Mac"."""
    def page_for(self, profiler_out):
        out = {"system_profiler": profiler_out}
        with mock.patch.object(netsetupd, "sh", lambda *c, **k: out.get(c[0], fake_sh(*c))):
            netsetupd.MODEL = None
            return netsetupd.page()

    def test_mac_studio(self):
        p = self.page_for("Hardware:\n\n    Hardware Overview:\n\n      Model Name: Mac Studio\n      Chip: Apple M5 Max\n")
        self.assertIn("Connect this Mac Studio to your Wi-Fi", p)
        self.assertNotIn("Mac mini", p)
        self.assertNotIn("__MODEL__", p)

    def test_macbook_pro(self):
        self.assertIn("The MacBook Pro has no Wi-Fi yet", self.page_for("      Model Name: MacBook Pro\n"))

    def test_fallback_is_mac(self):
        p = self.page_for("")
        self.assertIn("Connect this Mac to your Wi-Fi", p)
        self.assertNotIn("Mac mini", p)

    def test_name_is_sanitized(self):
        p = self.page_for('      Model Name: Mac<script>"x"</script>\n')
        self.assertNotIn("<script>\"x", p)


class Joining(Base):
    def test_failed_helper_clears_joining_and_password_file(self):
        seen = {}
        def scanner(*args, **kw):
            seen["pw"] = args[2]
            seen["existed"] = os.path.exists(args[2])
            return None
        with mock.patch.object(netsetupd, "console_uid", lambda: 501), \
             mock.patch.object(netsetupd.os, "chown", lambda *a: None), \
             mock.patch.object(netsetupd, "scanner", scanner):
            netsetupd.State.joining = "MyWiFi"
            netsetupd.join("MyWiFi", "secret")
        self.assertTrue(seen["existed"], "password file is present while the helper runs")
        self.assertFalse(os.path.exists(seen["pw"]), "password file deleted afterwards")
        self.assertEqual(netsetupd.State.joining, "")
        self.assertFalse(netsetupd.State.result["ok"])
        self.assertEqual(netsetupd.State.result["ssid"], "MyWiFi")

    def test_double_post_is_202_then_409(self):
        release, started = threading.Event(), threading.Event()
        def scanner(*args, **kw):
            started.set(); release.wait(10); return None
        netsetupd.State.mode = "tether"
        netsetupd.serve()
        with mock.patch.object(netsetupd, "console_uid", lambda: 501), \
             mock.patch.object(netsetupd.os, "chown", lambda *a: None), \
             mock.patch.object(netsetupd, "scanner", scanner):
            self.assertEqual(self.post("/api/join", {"ssid": "MyWiFi", "password": "x"}), 202)
            self.assertTrue(started.wait(5))
            self.assertEqual(self.post("/api/join", {"ssid": "MyWiFi", "password": "x"}), 409)
            release.set()
            for _ in range(50):
                if not netsetupd.State.joining: break
                threading.Event().wait(0.1)
        self.assertEqual(netsetupd.State.joining, "")

    def test_join_without_ssid_is_400(self):
        netsetupd.State.mode = "tether"; netsetupd.serve()
        self.assertEqual(self.post("/api/join", {"password": "x"}), 400)


class Status(Base):
    def test_status_has_user_and_host(self):
        netsetupd.State.mode = "tether"; netsetupd.serve()
        status, body = self.get("/api/status")
        d = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual(d["host"], "ai-mini")
        self.assertEqual(d["user"], "admin")
        self.assertEqual(d["mode"], "tether")
        self.assertIn("joining", d)
        self.assertIn("result", d)


class Confirmation(Base):
    """After a successful join the page stays up for an hour, with the Mac's new address."""
    def ok_result(self):
        netsetupd.State.result, netsetupd.State.result_at = {"ok": True, "error": "", "ssid": "MyWiFi"}, netsetupd.time.time()

    def test_success_keeps_the_page_for_an_hour(self):
        netsetupd.State.mode = "tether"
        self.ok_result()
        netsetupd.set_mode("idle")
        delay = netsetupd.threading.Timer.call_args[0][0]
        self.assertEqual(delay, netsetupd.CONFIRM_SECS)
        self.assertEqual(netsetupd.CONFIRM_SECS, 3600)

    def test_no_success_two_minutes(self):
        netsetupd.State.mode = "tether"
        netsetupd.set_mode("idle")
        self.assertEqual(netsetupd.threading.Timer.call_args[0][0], 120)

    def test_end_of_confirmation_clears_the_result(self):
        self.ok_result(); netsetupd.State.idle_since = 5
        netsetupd.unserve_if_still_idle(5)
        self.assertIsNone(netsetupd.State.result)

    def test_status_has_the_new_address(self):
        self.ok_result(); netsetupd.serve()
        net = {"ip": "192.0.2.20", "router": "192.0.2.1", "host": "ai-mini"}
        with mock.patch.object(netsetupd, "network_info", lambda: net):
            d = json.loads(self.get("/api/status")[1])
        self.assertEqual(d["net"], net)
        self.assertGreater(d["confirm_until"], netsetupd.time.time() + 3000)

    def test_no_address_before_a_join(self):
        netsetupd.State.mode = "tether"; netsetupd.serve()
        d = json.loads(self.get("/api/status")[1])
        self.assertIsNone(d["net"])
        self.assertEqual(d["confirm_until"], 0)

    def test_network_info(self):
        out = {
            "networksetup": "Hardware Port: Wi-Fi\nDevice: en1\n",
            "ifconfig": "en1: flags=8863\n\tether 02:00:00:aa:bb:cc\n\tinet 192.0.2.20 netmask 0xffffff00\n",
            "scutil": "ai-mini\n",
            "/opt/homebrew/bin/tailscale": json.dumps({"Self": {"Online": True, "DNSName": "ai-mini.example.ts.net.",
                                                                "TailscaleIPs": ["ts-ip.test", "fd7a::5"]}}),
        }
        def sh(*c, **k):
            if c[0] == "ipconfig":
                return {"getifaddr": "192.0.2.20\n", "router": "192.0.2.1\n", "subnet_mask": "255.255.255.0\n",
                        "domain_name_server": "192.0.2.1\n"}.get(c[-1] if c[1] == "getoption" else c[1], "")
            return out.get(c[0], "")
        with mock.patch.object(netsetupd, "sh", sh):
            n = netsetupd.network_info()
        self.assertEqual(n["ip"], "192.0.2.20"); self.assertEqual(n["router"], "192.0.2.1")
        self.assertEqual(n["subnet"], "255.255.255.0"); self.assertEqual(n["mac"], "02:00:00:aa:bb:cc")
        self.assertEqual(n["tailscale_name"], "ai-mini.example.ts.net"); self.assertEqual(n["tailscale_ip"], "ts-ip.test")

    def test_network_info_without_wifi_address(self):
        with mock.patch.object(netsetupd, "sh", lambda *c, **k: "Hardware Port: Wi-Fi\nDevice: en1\n" if c[0] == "networksetup" else ""):
            self.assertIsNone(netsetupd.network_info())


class OnlyFromThePhone(Base):
    """Once the Mac is online, the page on the home network may only show the result."""
    def test_join_refused_from_the_network_after_setup(self):
        netsetupd.State.result, netsetupd.State.result_at = {"ok": True, "ssid": "MyWiFi"}, netsetupd.time.time()
        netsetupd.serve()   # idle, confirmation showing; the test client is 127.0.0.1, not the cable
        self.assertEqual(self.post("/api/join", {"ssid": "Other", "password": "x"}), 403)
        self.assertEqual(netsetupd.State.joining, "")
        self.assertEqual(json.loads(self.get("/api/networks")[1]), [])

    def test_join_allowed_while_offline(self):
        netsetupd.State.mode = "tether"; netsetupd.serve()
        with mock.patch.object(netsetupd, "join", lambda *a: None):
            self.assertEqual(self.post("/api/join", {"ssid": "MyWiFi", "password": "x"}), 202)
        netsetupd.State.joining = ""

    def test_the_phone_cable_range(self):
        self.assertTrue(netsetupd.from_tether("172.20.10.3"))
        self.assertFalse(netsetupd.from_tether("192.168.1.20"))
        self.assertFalse(netsetupd.from_tether("127.0.0.1"))


if __name__ == "__main__":
    unittest.main()
