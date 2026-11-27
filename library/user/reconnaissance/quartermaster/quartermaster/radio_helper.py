"""The app's side of the radio helper: one connection, its replies and the frames it relays.

The helper does the privileged steps. Whatever this connection changed is put back by the helper when the
connection closes, so a crash of the app leaves no adapter in monitor mode.
"""

import errno
import json
import queue
import socket
import struct
import threading
import time

SOCKET = "/run/quartermaster/radio.sock"
HEADER = struct.Struct("<IIId")
TIMEOUT = 25.0
MAX_ID = 2 ** 31 - 1
WORDS = {
    "missing": "Radio helper not installed. Update Quartermaster from the AppStore.",
    "no_group": "Restart the Cardputer once so the new permission applies.",
    "off": "Deep scan is off in Settings.",
    "ready": "Radio helper ready",
}
SETTINGS = ("deep_scan", "direct_scan", "radio_tuning")


class HelperError(RuntimeError):
    pass


def wanted(cfg):
    return any(cfg.get(key) is True for key in SETTINGS)


def words(state, detail=""):
    if state == "error":
        return ("Radio helper failed: %s" % detail)[:100]
    return WORDS.get(state, state)


class Client:
    """Requests may come from several threads at once: each carries an id and waits only for its own reply, so a
    long scan of one adapter never holds up another adapter or Deep scan."""

    def __init__(self, path=SOCKET, connect=None):
        self.path = path
        self._connect = connect or self._unix
        self.sock = None
        self.frames = None
        self.lock = threading.Lock()
        self.reader = None
        self.closed = threading.Event()
        self.cpu = 0.0
        self._waiting = {}
        self._next_id = 0
        self._chunked = None

    @staticmethod
    def _unix(path):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        try:
            sock.connect(path)
        except BaseException:
            sock.close()
            raise
        return sock

    def open(self):
        self.sock = self._connect(self.path)
        self.reader = threading.Thread(target=self._read, daemon=True, name="radio-helper")
        self.reader.start()
        return self

    def peer_pid(self):
        """The helper's process id, for its share of the CPU, or None."""
        try:
            pid = struct.unpack("3i", self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                                           struct.calcsize("3i")))[0]
        except (OSError, AttributeError, struct.error):
            return None
        return pid if pid > 0 else None

    def _read(self):
        try:
            while not self.closed.is_set():
                data = self.sock.recv(1 << 17)
                if not data:
                    break
                kind, body = data[:1], data[1:]
                if kind == b"F":
                    sink = self.frames
                    if sink is not None:
                        sink(body)
                elif kind == b"J":
                    self._reply(body)
                elif kind == b"C":
                    self._chunk(body)
                self.cpu = time.thread_time()
        except OSError:
            pass
        finally:
            self.closed.set()
            with self.lock:
                boxes, self._waiting = list(self._waiting.values()), {}
            for box in boxes:
                box.put(None)

    def _reply(self, body):
        try:
            reply = json.loads(body.decode("utf-8"))
        except ValueError:
            reply = {"ok": False, "error": "unreadable reply"}
        if not isinstance(reply, dict):
            reply = {"ok": False, "error": "refused"}
        rid = reply.pop("id", None)
        chunks = reply.pop("chunks", 0)
        if isinstance(chunks, int) and chunks > 0:
            self._chunked = [rid, reply, chunks, []]
            return
        self._deliver(rid, reply)

    def _chunk(self, body):
        held = self._chunked
        if held is None:
            return
        held[3].append(body)
        if len(held[3]) >= held[2]:
            self._chunked = None
            held[1]["text"] = b"".join(held[3]).decode("utf-8", "replace")
            self._deliver(held[0], held[1])

    def _deliver(self, rid, reply):
        with self.lock:
            if rid is None:
                rid = min(self._waiting, default=None)
            box = self._waiting.pop(rid, None)
        if box is not None:
            box.put(reply)

    def request(self, cmd, timeout=TIMEOUT, **args):
        box = queue.Queue(maxsize=1)
        with self.lock:
            if self.sock is None or self.closed.is_set():
                raise HelperError("the radio helper is not connected")
            self._next_id = self._next_id % MAX_ID + 1
            rid = self._next_id
            message = json.dumps(dict(args, cmd=cmd, id=rid), separators=(",", ":")).encode()
            self._waiting[rid] = box
            try:
                self.sock.send(message)
            except OSError as exc:
                self._waiting.pop(rid, None)
                raise HelperError(str(exc))
        try:
            reply = box.get(timeout=timeout)
        except queue.Empty:
            raise HelperError("the radio helper did not answer")
        finally:
            with self.lock:
                self._waiting.pop(rid, None)
        if reply is None:
            raise HelperError("the radio helper went away")
        if not reply.get("ok"):
            raise HelperError(reply.get("error", "refused"))
        return reply

    def close(self):
        self.closed.set()
        sock, self.sock = self.sock, None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        if self.reader is not None and self.reader is not threading.current_thread():
            self.reader.join(timeout=2)


def connect(path=SOCKET, client=Client):
    """(client or None, state, detail)."""
    try:
        opened = client(path).open()
    except FileNotFoundError:
        return None, "missing", ""
    except PermissionError:
        return None, "no_group", ""
    except ConnectionRefusedError:
        return None, "missing", ""
    except OSError as exc:
        if exc.errno == errno.EACCES:
            return None, "no_group", ""
        return None, "error", str(exc)[:80]
    try:
        opened.request("hello", timeout=5)
    except HelperError as exc:
        opened.close()
        text = str(exc)
        return None, ("no_group" if "group" in text else "error"), text[:80]
    return opened, "ready", ""


def state(cfg, path=SOCKET, client=Client):
    """(state, words) for Settings and the Hardware screen."""
    if not wanted(cfg):
        return "off", words("off")
    opened, found, detail = connect(path, client)
    if opened is not None:
        opened.close()
    return found, words(found, detail)


def split_batch(body):
    """(received, dropped, freq, switched_at, [frame bytes]) of one relayed batch, or None when it is cut short."""
    if len(body) < HEADER.size:
        return None
    received, dropped, freq, switched = HEADER.unpack_from(body)
    frames, at, view = [], HEADER.size, memoryview(body)
    while at + 2 <= len(body):
        size = body[at] | body[at + 1] << 8
        at += 2
        if at + size > len(body):
            break
        frames.append(view[at:at + size])
        at += size
    return received, dropped, freq, switched, frames
