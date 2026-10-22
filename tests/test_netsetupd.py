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
        self.assertEqual(body, netsetupd.PAGE)


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


if __name__ == "__main__":
    unittest.main()
