#!/usr/bin/env python3
"""External DevTools-protocol control of a running CefQml app.

Usage: tests/cdp_remote.py <builddir> [main.qml]

Starts the reference browser offscreen with CEF_QML_REMOTE_DEBUGGING_PORT,
drives its page target over the remote-debugging WebSocket (navigate to a
data: URL, Runtime.evaluate), checks the app saw the change (window title,
logged through the opt-in "cefqml.browser" category) and that SIGTERM shuts it
down cleanly. Exits 77 (skip) when the qml runtime or the build is missing.

Stdlib only; the WebSocket client below implements just what CDP needs.
"""

import base64
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

SKIP = 77
TITLE = "CDP remote OK"


def log(*args):
    print("cdp-remote:", *args, flush=True)


def find_qml():
    env = os.environ.get("QML_RUNTIME")
    if env:
        return shutil.which(env)
    for c in ("qml6", "qml-qt6", "/usr/lib/qt6/bin/qml",
              "/usr/lib64/qt6/bin/qml", "qml"):
        path = shutil.which(c)
        if path:
            return path
    return None


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def until(pred, timeout, what, proc=None, step=0.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc is not None and proc.poll() is not None:
            raise AssertionError(f"app exited ({proc.returncode}) while waiting for {what}")
        value = pred()
        if value:
            return value
        time.sleep(step)
    raise AssertionError(f"timed out waiting for {what}")


def http_json(port, path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as r:
            return json.load(r)
    except OSError:
        return None


class WebSocket:
    """Minimal RFC 6455 client: text frames, masking, ping/pong, close."""

    def __init__(self, url, timeout=30):
        u = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET {u.path} HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("handshake: connection closed")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError(f"handshake refused: {head.decode(errors='replace')}")

    def _send_frame(self, opcode, payload):
        n = len(payload)
        if n < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
        elif n < 1 << 16:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n:]
        return data

    def send(self, text):
        self._send_frame(0x1, text.encode())

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("closed by peer")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode in (0x0, 0x1, 0x2):
                message += payload
                if b0 & 0x80:
                    return message.decode()

    def close(self):
        try:
            self._send_frame(0x8, struct.pack("!H", 1000))
        except OSError:
            pass
        self.sock.close()


class Cdp:
    def __init__(self, url):
        self.ws = WebSocket(url)
        self.next_id = 0
        self.events = []

    def call(self, method, **params):
        self.next_id += 1
        mid = self.next_id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise AssertionError(f"{method} failed: {msg['error']}")
                return msg.get("result", {})
            if "method" in msg:
                self.events.append(msg)

    def wait_event(self, method, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            for i, ev in enumerate(self.events):
                if ev["method"] == method:
                    return self.events.pop(i)
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {method}")
            msg = json.loads(self.ws.recv())
            if "method" in msg:
                self.events.append(msg)

    def evaluate(self, expression):
        r = self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        if "exceptionDetails" in r:
            raise AssertionError(f"evaluate {expression!r}: {r['exceptionDetails']}")
        return r["result"].get("value")


def descendants(pid):
    children = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open(f"/proc/{entry}/stat") as f:
                    ppid = int(f.read().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            children.setdefault(ppid, []).append(int(entry))
    out, todo = [], [pid]
    while todo:
        for c in children.get(todo.pop(), []):
            out.append(c)
            todo.append(c)
    return out


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def run(builddir, main_qml, tmp):
    qml = find_qml()
    if not qml:
        log("qml runtime not found (set QML_RUNTIME)")
        return SKIP
    if not os.path.exists(os.path.join(builddir, "CefQml", "qmldir")):
        log(f"no CefQml module in {builddir}")
        return SKIP

    port = free_port()
    env = dict(os.environ)
    env.update({
        "QT_QPA_PLATFORM": "offscreen",
        "QML_IMPORT_PATH": builddir + (":" + env["QML_IMPORT_PATH"] if env.get("QML_IMPORT_PATH") else ""),
        "CEF_QML_CACHE_DIR": os.path.join(tmp, "profile"),
        "CEF_QML_REMOTE_DEBUGGING_PORT": str(port),
        "QT_LOGGING_RULES": "cefqml.info=true;cefqml.browser.info=true",
    })
    logpath = os.path.join(tmp, "app.log")
    logfile = open(logpath, "w")
    log(f"starting {qml} {main_qml} (port {port})")
    proc = subprocess.Popen([qml, main_qml], env=env, stdout=logfile,
                            stderr=subprocess.STDOUT, start_new_session=True)

    def app_log():
        with open(logpath, errors="replace") as f:
            return f.read()

    try:
        version = until(lambda: http_json(port, "/json/version"), 60, "/json/version", proc)
        log("browser:", version.get("Browser"))

        pages = until(lambda: [t for t in http_json(port, "/json/list") or []
                               if t.get("type") == "page" and t.get("webSocketDebuggerUrl")],
                      30, "a page target", proc)
        target = pages[0]
        log(f"{len(pages)} page target(s); using {target['id']}")

        cdp = Cdp(target["webSocketDebuggerUrl"])
        # The view starts on an about:blank bootstrap page and then loads its
        # first URL; a navigation sent before that would be superseded.
        until(lambda: cdp.evaluate("location.href != 'about:blank' && "
                                   "document.readyState == 'complete'"),
              30, "the app's first page", proc)
        cdp.call("Page.enable")
        url = "data:text/html," + urllib.parse.quote(
            f"<title>{TITLE}</title><p id=msg>driven over CDP</p>")
        nav = cdp.call("Page.navigate", url=url)
        assert not nav.get("errorText"), nav
        cdp.wait_event("Page.loadEventFired")

        assert cdp.evaluate("6 * 7") == 42
        got = cdp.evaluate("document.title + '|' + document.getElementById('msg').textContent")
        assert got == f"{TITLE}|driven over CDP", got
        cdp.evaluate(f"document.title = {json.dumps(TITLE + ' 2')}")
        cdp.ws.close()
        log("navigated and evaluated over CDP")

        until(lambda: any(t.get("id") == target["id"] and t.get("title") == TITLE + " 2"
                          for t in http_json(port, "/json/list") or []),
              15, "target title in /json/list", proc)
        expected = f"window title: {TITLE} 2 — CefQml Browser"
        until(lambda: expected in app_log(), 15, f"app log line {expected!r}", proc)
        log("app window title follows the remotely driven page")

        helpers = descendants(proc.pid)
        proc.send_signal(signal.SIGTERM)
        try:
            status = proc.wait(30)
        except subprocess.TimeoutExpired:
            raise AssertionError("app did not exit within 30 s of SIGTERM")
        assert status == 0, f"app exit status {status} after SIGTERM"
        out = app_log()
        assert "received signal 15" in out, "SIGTERM did not take the Qt quit path"
        for bad in ("incorrectly held", "did not close before shutdown"):
            assert bad not in out, f"unclean shutdown: {bad!r}"
        until(lambda: not any(alive(p) for p in helpers), 15, "helper processes to exit")
        log(f"clean exit after SIGTERM ({len(helpers)} helper process(es) gone)")
        return 0
    except AssertionError as e:
        log("FAIL:", e)
        print("---- app log ----\n" + app_log(), flush=True)
        return 1
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        logfile.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    builddir = os.path.abspath(sys.argv[1])
    main_qml = os.path.abspath(sys.argv[2] if len(sys.argv) > 2
                               else os.path.join(here, "..", "examples", "browser", "main.qml"))
    tmp = tempfile.mkdtemp(prefix="cefqml-cdp-")
    try:
        return run(builddir, main_qml, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
