#!/usr/bin/env python3
"""Local web UI for Bose BMAP headphones.

Holds one RFCOMM connection and serves a JSON API plus a static page.
Every write is followed by a read of the device, so the UI shows what the
firmware actually stored rather than what was requested.
"""

import json
import os
import queue
import sys
import threading
import traceback
import webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "vendor"))

import pybmap  # noqa: E402
from pybmap.errors import BmapError, BmapDesyncError  # noqa: E402

HOST = os.environ.get("BOSE_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("BOSE_UI_PORT", "8765"))
MAC = os.environ.get("BOSE_MAC") or None
DEVICE_TYPE = os.environ.get("BOSE_DEVICE") or None


class Device:
    """One shared BMAP connection, driven only from the main thread.

    macOS IOBluetooth will not open an RFCOMM channel from a worker thread:
    the attempt fails with "Failed to establish baseband connection". So HTTP
    handler threads hand work to a queue and the main thread performs it.
    """

    def __init__(self):
        self._jobs = queue.Queue()
        self._conn = None
        self._stop = threading.Event()

    # ── main thread ──────────────────────────────────────────────────

    def _open(self):
        self._conn = pybmap.connect(mac=MAC, device_type=DEVICE_TYPE)
        return self._conn

    def _drop(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    def _execute(self, fn):
        """Run fn against the shared connection, reopening it once on failure.

        A desync is reported by pybmap as a BmapError subclass, so it has to be
        caught before the BmapError clause or the broken channel is kept.
        """
        for attempt in (1, 2):
            try:
                conn = self._conn or self._open()
                return fn(conn)
            except (BmapDesyncError, StaleConnection):
                self._drop()
                if attempt == 2:
                    raise
            except BmapError:
                raise
            except Exception:
                self._drop()
                if attempt == 2:
                    raise
        raise RuntimeError("unreachable")

    def pump(self):
        """Block on the main thread, serving queued jobs until stopped."""
        while not self._stop.is_set():
            try:
                job = self._jobs.get(timeout=0.25)
            except queue.Empty:
                continue
            fn, done, box = job
            try:
                box["value"] = self._execute(fn)
            except BaseException as exc:
                box["error"] = exc
            finally:
                done.set()
        self._drop()

    def shutdown(self):
        self._stop.set()

    def force_reconnect(self):
        """Close the channel and open a fresh one, from the main thread."""
        def job(_conn):
            self._drop()
            self._open()
            return True

        # _execute would hand us the existing connection, so bypass it.
        done = threading.Event()
        box = {}
        self._jobs.put((job, done, box))
        if not done.wait(60):
            raise TimeoutError("reconnect timed out")
        if "error" in box:
            raise box["error"]
        return box["value"]

    # ── any thread ───────────────────────────────────────────────────

    def run(self, fn, timeout=60):
        """Queue fn(conn) for the main thread and wait for its result."""
        done = threading.Event()
        box = {}
        self._jobs.put((fn, done, box))
        if not done.wait(timeout):
            raise TimeoutError("device did not respond within %ss" % timeout)
        if "error" in box:
            raise box["error"]
        return box["value"]


device = Device()


class StaleConnection(Exception):
    """The RFCOMM stream is out of step with our requests.

    After the headphones drop and reconnect, responses queued before the drop
    are still in the socket, so each read returns the previous request's
    answer. pybmap does not check that a response came from the address it
    asked for, so this surfaces as garbled values rather than an error.
    Reopening the channel clears it.
    """


def check_plausible(snapshot):
    """Raise StaleConnection if a snapshot shows desynced reads."""
    status = snapshot.get("status") or {}

    battery = status.get("battery")
    if not isinstance(battery, int) or not 0 <= battery <= 100:
        raise StaleConnection("battery read back as %r" % (battery,))

    if not status.get("firmware"):
        raise StaleConnection("firmware read back empty")

    name = status.get("name") or ""
    if any(ord(c) < 32 for c in name):
        raise StaleConnection("device name contains control characters")

    return snapshot


def jsonable(value):
    """Convert pybmap namedtuples and bytes into JSON-safe values."""
    if isinstance(value, bytes):
        return value.hex()
    if hasattr(value, "_asdict"):
        return {k: jsonable(v) for k, v in value._asdict().items()}
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    return value


def read_light(conn):
    """Cheap snapshot for background polling.

    A full read is about 3 seconds of Bluetooth round trips, too much to
    repeat on a timer. These two are enough to notice that something changed
    on the headphones themselves; the page then asks for the full state.
    """
    return {
        "mode_idx": conn.mode_idx(),
        "battery": conn.battery(),
    }


def read_all(conn):
    """Full device snapshot: status, profiles, buttons and capabilities."""
    snapshot = {
        "device": jsonable(conn.device_info),
        "status": jsonable(conn.status()),
        "features": sorted(getattr(conn._device, "FEATURES", {}).keys()),
        "preset_modes": jsonable(conn.preset_modes),
        "editable_slots": list(getattr(conn._device, "EDITABLE_SLOTS", [])),
    }

    try:
        snapshot["profiles"] = [jsonable(m) for m in conn.profiles()]
    except BmapDesyncError:
        raise
    except BmapError as exc:
        snapshot["profiles"] = []
        snapshot["profiles_error"] = str(exc)

    try:
        buttons = conn.buttons()
        # Devices with one remappable button return a single ButtonMapping.
        # It is a namedtuple, so test for _fields rather than for tuple-ness.
        if hasattr(buttons, "_fields") or not isinstance(buttons, (list, tuple)):
            buttons = [buttons]
        snapshot["buttons"] = [jsonable(b) for b in buttons]
    except BmapDesyncError:
        raise
    except Exception as exc:
        snapshot["buttons"] = []
        snapshot["buttons_error"] = str(exc)

    # source, anr and audio_settings are not supported on every device and
    # nothing in the page uses them. Each one costs a round trip, so they are
    # only read when the device config actually declares them.
    features = getattr(conn._device, "FEATURES", {})
    for key, fn in (("source", conn.source), ("anr", conn.anr)):
        if key not in features:
            continue
        try:
            snapshot[key] = jsonable(fn())
        except BmapDesyncError:
            raise
        except Exception as exc:
            snapshot[key] = None
            snapshot[key + "_error"] = str(exc)

    return check_plausible(snapshot)


# Whitelisted write actions. Anything not listed here is rejected.
def _set_profile(conn, name, slot=None, **kw):
    """Write a profile to an explicit slot.

    create_profile() only takes slots whose 'configured' bit is clear, and
    that bit is never cleared again once a slot has been written, so a slot
    with a blank name still looks occupied. Addressing the slot directly
    avoids that.
    """
    profiles = {p.mode_idx: p for p in conn.profiles()}

    if slot is None:
        match = next((p for p in profiles.values()
                      if p.name and p.name.lower() == name.lower()), None)
        if match is None:
            match = next((p for p in profiles.values()
                          if p.editable and not p.name.strip()), None)
        if match is None:
            raise BmapError("No writable profile slot available")
        slot = match.mode_idx

    slot = int(slot)
    target = profiles.get(slot)
    if target is None:
        raise BmapError("No slot %d on this device" % slot)
    if not target.editable:
        raise BmapError("Slot %d is a preset and cannot be changed" % slot)

    conn._write_mode(
        slot, name,
        cnc_level=int(kw.get("cnc_level", target.cnc_level)),
        spatial=int(kw.get("spatial", target.spatial)),
        wind_block=1 if kw.get("wind_block", target.wind_block) else 0,
        anc_toggle=1 if kw.get("anc_toggle", target.anc_toggle) else 0,
    )
    return {"slot": slot}


def _delete_profile(conn, name=None, slot=None):
    """Clear a slot by index, or by name when no index is given."""
    if slot is None:
        return conn.delete_profile(name)
    slot = int(slot)
    target = next((p for p in conn.profiles() if p.mode_idx == int(slot)), None)
    if target is None:
        raise BmapError("No slot %d on this device" % slot)
    if not target.editable:
        raise BmapError("Slot %d is a preset and cannot be cleared" % slot)
    conn._write_mode(slot, "", cnc_level=0, spatial=0,
                     wind_block=0, anc_toggle=0)
    return {"slot": slot}


ACTIONS = {
    "set_mode": lambda c, name, announce=False: c.set_mode(name, announce=announce),
    "set_cnc": lambda c, level: c.set_cnc(int(level)),
    "set_anc": lambda c, enabled: c.set_anc(bool(enabled)),
    "set_wind": lambda c, enabled: c.set_wind(bool(enabled)),
    "set_eq": lambda c, bass, mid, treble: c.set_eq(int(bass), int(mid), int(treble)),
    "set_spatial": lambda c, mode: c.set_spatial(mode),
    "set_name": lambda c, new_name: c.set_name(new_name),
    "set_sidetone": lambda c, level: c.set_sidetone(level),
    "set_multipoint": lambda c, enabled: c.set_multipoint(bool(enabled)),
    "set_auto_pause": lambda c, enabled: c.set_auto_pause(bool(enabled)),
    "set_auto_answer": lambda c, enabled: c.set_auto_answer(bool(enabled)),
    "set_prompts": lambda c, enabled: c.set_prompts(bool(enabled)),
    "set_anr": lambda c, level: c.set_anr(level),
    "set_buttons": lambda c, button_id, event, action: c.set_buttons(button_id, event, action),
    "set_profile": _set_profile,
    "delete_profile": _delete_profile,
    "pair": lambda c: c.pair(),
    "power_off": lambda c: c.power_off(),
    "route": lambda c, mac: c.route(mac),
    "send_raw": lambda c, hex_str: [jsonable(r) for r in c.send_raw(hex_str)],
}

# Actions after which re-reading the device is pointless or disruptive.
NO_REFRESH = {"power_off", "pair"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    def _send(self, code, body, content_type="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, relpath, content_type):
        path = os.path.join(HERE, "static", relpath)
        if not os.path.isfile(path):
            self._send(404, {"error": "not found"})
            return
        with open(path, "rb") as fh:
            self._send(200, fh.read(), content_type)

    def do_GET(self):
        route = urlparse(self.path).path
        if route in ("/", "/index.html"):
            self._send_file("index.html", "text/html; charset=utf-8")
        elif route == "/app.js":
            self._send_file("app.js", "text/javascript; charset=utf-8")
        elif route == "/app.css":
            self._send_file("app.css", "text/css; charset=utf-8")
        elif route == "/api/poll":
            self._api(lambda: {"ok": True, "poll": device.run(read_light)})
        elif route == "/api/state":
            self._api(lambda: {"ok": True, "state": device.run(read_all)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path != "/api/action":
            self._send(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"ok": False, "error": "invalid JSON"})
            return

        name = body.get("action")
        args = body.get("args") or {}

        if name == "reconnect":
            def redo():
                device.force_reconnect()
                return {"ok": True, "action": name, "result": None,
                        "state": device.run(read_all)}

            self._api(redo)
            return

        if name not in ACTIONS:
            self._send(400, {"ok": False, "error": "unknown action: %s" % name})
            return

        def work():
            def call(conn):
                result = ACTIONS[name](conn, **args)
                # Read the device back so the UI reflects stored values, not
                # requested ones. The QC45 silently drops some writes.
                state = None if name in NO_REFRESH else read_all(conn)
                return {"ok": True, "action": name,
                        "result": jsonable(result), "state": state}

            return device.run(call)

        self._api(work)

    def _api(self, work):
        try:
            self._send(200, work())
        except BmapError as exc:
            self._send(200, {"ok": False, "error": str(exc)})
        except StaleConnection as exc:
            self._send(200, {"ok": False, "stale": True, "error":
                             "Lost sync with the headphones (%s). "
                             "Reconnect them, then press Reconnect." % exc})
        except Exception as exc:
            traceback.print_exc()
            self._send(200, {"ok": False,
                             "error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    url = "http://%s:%d/" % (HOST, PORT)
    server = ThreadingHTTPServer((HOST, PORT), Handler)

    # HTTP runs on a daemon thread; Bluetooth stays on the main thread.
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("Bose web UI on %s" % url)
    print("Headphones must be powered on and connected to this machine.")
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()

    try:
        device.pump()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        device.shutdown()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
