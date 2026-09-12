import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from collections import namedtuple
from types import SimpleNamespace
from unittest.mock import patch

import server


class FakeConnection:
    def __init__(self, label="fake"):
        self.label = label
        self.closed = False
        self.eq = [3, -2, 4]
        self.device_info = {"name": "Bose QuietComfort 45"}
        self.preset_modes = {0: "Quiet", 1: "Aware"}
        self._device = SimpleNamespace(FEATURES={}, EDITABLE_SLOTS=[2, 3])

    def close(self):
        self.closed = True

    def status(self):
        return {
            "battery": 90,
            "firmware": "4.0.4",
            "name": "Test QC45",
            "mode": "quiet",
            "mode_idx": 0,
            "eq": self.eq,
        }

    def profiles(self):
        return []

    def buttons(self):
        return []

    def source(self):
        return None

    def anr(self):
        return None

    def set_eq(self, bass, mid, treble):
        self.eq = [bass, mid, treble]
        return self.eq


class ImmediateDevice:
    def __init__(self, connection):
        self.connection = connection

    def run(self, operation, timeout=60):
        return operation(self.connection)

    def force_reconnect(self):
        return True


class DeviceTests(unittest.TestCase):
    def test_pump_runs_work_on_its_thread_and_closes_connection(self):
        connection = FakeConnection()
        device = server.Device()

        with patch.object(server.pybmap, "connect", return_value=connection):
            pump = threading.Thread(target=device.pump)
            pump.start()
            self.assertEqual(device.run(lambda conn: conn.label, timeout=1), "fake")
            device.shutdown()
            pump.join(timeout=1)

        self.assertFalse(pump.is_alive())
        self.assertTrue(connection.closed)

    def test_stale_connection_is_closed_and_reopened_once(self):
        stale = FakeConnection("stale")
        fresh = FakeConnection("fresh")
        device = server.Device()

        def operation(connection):
            if connection is stale:
                raise server.StaleConnection("out of sync")
            return connection.label

        with patch.object(server.pybmap, "connect", side_effect=[stale, fresh]) as connect:
            self.assertEqual(device._execute(operation), "fresh")

        self.assertEqual(connect.call_count, 2)
        self.assertTrue(stale.closed)
        self.assertIs(device._conn, fresh)


class LockTests(unittest.TestCase):
    def test_only_one_backend_can_hold_the_shared_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "backend.lock")
            first = server.acquire_backend_lock(path)
            self.addCleanup(first.close)

            with self.assertRaisesRegex(server.BackendAlreadyRunning, "already running"):
                server.acquire_backend_lock(path)

            first.close()
            second = server.acquire_backend_lock(path)
            second.close()


class DataTests(unittest.TestCase):
    def test_plausibility_rejects_invalid_battery_and_control_characters(self):
        with self.assertRaisesRegex(server.StaleConnection, "battery"):
            server.check_plausible({"status": {"battery": 101, "firmware": "1"}})

        with self.assertRaisesRegex(server.StaleConnection, "control characters"):
            server.check_plausible({
                "status": {"battery": 50, "firmware": "1", "name": "bad\x00name"}
            })

    def test_jsonable_converts_protocol_values(self):
        Response = namedtuple("Response", "payload count")
        value = {"response": Response(b"\x01\xff", 2), "items": (b"\x03",)}
        self.assertEqual(
            server.jsonable(value),
            {"response": {"payload": "01ff", "count": 2}, "items": ["03"]},
        )

    def test_profile_writes_only_editable_slots(self):
        Profile = namedtuple(
            "Profile", "mode_idx name editable cnc_level spatial wind_block anc_toggle"
        )

        class ProfileConnection:
            def __init__(self):
                self.writes = []
                self.items = [
                    Profile(0, "Quiet", False, 0, 0, 0, 1),
                    Profile(2, "Custom", True, 4, 0, 0, 1),
                ]

            def profiles(self):
                return self.items

            def _write_mode(self, *args, **kwargs):
                self.writes.append((args, kwargs))

        connection = ProfileConnection()
        with self.assertRaisesRegex(server.BmapError, "preset"):
            server._set_profile(connection, "Quiet", slot=0)

        result = server._set_profile(
            connection, "Travel", slot=2, cnc_level=7, wind_block=True, anc_toggle=False
        )
        self.assertEqual(result, {"slot": 2})
        self.assertEqual(
            connection.writes,
            [((2, "Travel"), {"cnc_level": 7, "spatial": 0, "wind_block": 1, "anc_toggle": 0})],
        )


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.connection = FakeConnection()
        cls.original_device = server.device
        server.device = ImmediateDevice(cls.connection)
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = "http://127.0.0.1:%d" % cls.httpd.server_port

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=1)
        server.device = cls.original_device

    def request_json(self, path, payload=None, headers=None):
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request_headers = {"Content-Type": "application/json"}
        request_headers.update(headers or {})
        request = urllib.request.Request(
            self.base_url + path,
            data=body,
            headers=request_headers,
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.load(response)

    def test_state_endpoint_reads_fake_headphones(self):
        status, payload = self.request_json("/api/state")
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["state"]["status"]["battery"], 90)
        self.assertEqual(payload["state"]["device"]["name"], "Bose QuietComfort 45")

    def test_write_action_returns_verified_state(self):
        status, payload = self.request_json(
            "/api/action",
            {"action": "set_eq", "args": {"bass": -1, "mid": 2, "treble": 5}},
            headers={"Origin": self.base_url},
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["result"], [-1, 2, 5])
        self.assertEqual(payload["state"]["status"]["eq"], [-1, 2, 5])

    def test_unknown_action_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request_json("/api/action", {"action": "format_computer"})
        error = raised.exception
        self.addCleanup(error.close)
        self.assertEqual(error.code, 400)
        payload = json.load(error)
        self.assertIn("unknown action", payload["error"])

    def test_cross_origin_action_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.request_json(
                "/api/action",
                {"action": "power_off"},
                headers={"Origin": "https://example.com"},
            )
        error = raised.exception
        self.addCleanup(error.close)
        self.assertEqual(error.code, 403)
        self.assertIn("cross-origin", json.load(error)["error"])

    def test_non_json_action_is_rejected(self):
        request = urllib.request.Request(
            self.base_url + "/api/action",
            data=b'{"action":"power_off"}',
            headers={"Content-Type": "text/plain"},
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=2)
        error = raised.exception
        self.addCleanup(error.close)
        self.assertEqual(error.code, 415)

    def test_page_has_security_headers_and_no_remote_assets(self):
        with urllib.request.urlopen(self.base_url + "/", timeout=2) as response:
            page = response.read().decode("utf-8")
            self.assertIn("default-src 'self'", response.headers["Content-Security-Policy"])
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        self.assertNotIn("https://", page)


if __name__ == "__main__":
    unittest.main()
