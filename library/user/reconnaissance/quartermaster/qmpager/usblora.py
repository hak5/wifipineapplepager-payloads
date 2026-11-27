"""Any LoRa radio on the Pager's USB, found by itself and looked for again while none is there.

In order: a CH341 stick (MeshToad, MeshStick, Glytch Mesh Mod) that is free is driven directly, so it hops between
Meshtastic, MeshCore and LoRaWAN like the Cap. A stick that meshtasticd holds, or any radio meshtasticd runs, is read
through meshtasticd. Last, a Meshtastic board on USB serial is read through its own firmware. Serial ports the GPS
layer already checked and heard no GPS on are the only ones asked, and a port that answers is kept from the GPS.
"""

import socket
import threading
import time

from quartermaster import hardware, lora

from . import ch341, meshapi

DIRECT, SERVICE, BOARD = "direct", "meshtasticd", "board"
LOOK_EVERY = 5.0


def service_up(host="127.0.0.1", port=meshapi.TCP_PORT):
    try:
        socket.create_connection((host, port), 0.3).close()
        return True
    except OSError:
        return False


class UsbLora:
    """Stands where lora.Cap stands."""

    def __init__(self, sticks=ch341.sticks, radio=ch341.Ch341Radio, service=service_up,
                 ports=lambda: hardware.gps_candidates(cardputer=False), answers=None, every=LOOK_EVERY):
        self.sticks, self.radio_class, self.service, self.ports = sticks, radio, service, ports
        self.answers = answers or self._answers
        self.every = every
        self.state = lora.CHECKING
        self.kind, self.where, self.label = "", "", ""
        self.cardputer = False
        self.in_use = 0
        self.asked = set()
        self._wanted = True
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()

    @property
    def found(self):
        return self.state == lora.FOUND

    @property
    def meshtastic_only(self):
        return self.kind in (SERVICE, BOARD)

    def title(self):
        return {DIRECT: "%s for mesh nodes" % (self.label or "USB LoRa stick"),
                SERVICE: "Meshtastic radio through meshtasticd",
                BOARD: "Meshtastic board %s" % (self.label or self.where)}.get(self.kind, "USB LoRa radio for mesh nodes")

    def start(self, wanted=True):
        self._wanted = wanted
        if not wanted:
            self.state = lora.OFF
            return
        if self.state == lora.OFF:
            self.state = lora.CHECKING
        if self._thread is None:
            self._thread = threading.Thread(target=self._watch, daemon=True, name="usb-lora")
            self._thread.start()

    def stop(self):
        self._stop.set()

    def _watch(self):
        while not self._stop.is_set():
            if self._wanted:
                try:
                    self.look()
                except Exception:
                    if self.state == lora.CHECKING:
                        self.state = lora.ABSENT
            self._stop.wait(self.every)

    def look(self):
        with self._lock:
            if self.in_use:
                return
            if self.found and self._still_there():
                return
            self._release()
            self.state = self._find()

    def _still_there(self):
        if self.kind == DIRECT:
            return any(s["node"] == self.where for s in self.sticks())
        if self.kind == SERVICE:
            return self.service()
        if self.kind == BOARD:
            return any(p["path"] == self.where for p in self.ports())
        return False

    def _release(self):
        if self.kind == BOARD and self.where:
            hardware.let_go_port(self.where, "meshtastic")
            hardware.mark_port(self.where, None)
        self.kind = self.where = self.label = ""

    def _find(self):
        result = lora.ABSENT
        for stick in self.sticks():
            radio = self.radio_class(stick["node"])
            try:
                radio.open()
                self.kind, self.where, self.label = DIRECT, stick["node"], stick["label"] or "CH341 LoRa stick"
                return lora.FOUND
            except lora.RadioError as exc:
                result = str(exc) if str(exc) in lora.WORDS else result
            except Exception:
                pass
            finally:
                try:
                    radio.close()
                except Exception:
                    pass
        if self.service():
            self.kind, self.where, self.label = SERVICE, "127.0.0.1:%d" % meshapi.TCP_PORT, "meshtasticd"
            return lora.FOUND
        current = {p["path"] for p in self.ports()}
        self.asked &= current
        for port in self.ports():
            path = port["path"]
            if path in self.asked or hardware.port_mark(path) != "checked" or hardware.port_holder(path):
                continue
            if not hardware.hold_port(path, "meshtastic"):
                continue
            self.asked.add(path)
            if self.answers(path):
                hardware.mark_port(path, "meshtastic")
                self.kind, self.where, self.label = BOARD, path, port.get("label") or ""
                return lora.FOUND
            hardware.let_go_port(path, "meshtastic")
        return result

    @staticmethod
    def _answers(path):
        try:
            link = meshapi.Serial(path)
        except OSError:
            return False
        try:
            return meshapi.answers(link)
        except OSError:
            return False
        finally:
            link.close()

    def wait(self, seconds):
        deadline = time.monotonic() + seconds
        while self.state == lora.CHECKING and time.monotonic() < deadline:
            time.sleep(0.05)

    def radio(self):
        if not self.found:
            raise lora.RadioError(lora.ABSENT)
        kind, where = self.kind, self.where
        if kind == DIRECT:
            inner = self.radio_class(where)
        elif kind == SERVICE:
            host, port = where.rsplit(":", 1)
            inner = meshapi.StreamRadio(lambda: meshapi.Tcp(host, int(port)))
        else:
            inner = meshapi.StreamRadio(lambda: meshapi.Serial(where))
        return _Held(self, inner)


class _Held:
    """A radio the listener has open, so the watcher leaves the device alone until it is closed."""

    def __init__(self, owner, inner):
        self.owner, self.inner, self.open_now = owner, inner, False

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def open(self, profile=None):
        with self.owner._lock:
            self.owner.in_use += 1
        self.open_now = True
        try:
            self.inner.open(profile)
        except BaseException:
            self.close()
            raise
        return self

    def close(self):
        try:
            self.inner.close()
        finally:
            if self.open_now:
                self.open_now = False
                with self.owner._lock:
                    self.owner.in_use -= 1
