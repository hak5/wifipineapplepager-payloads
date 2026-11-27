"""The Pager's D-pad and its green and red buttons, read from evdev and turned into Quartermaster keys.

Green is OK. Red is back. Holding green opens the action menu. Holding red for two seconds leaves
Quartermaster and gives the screen back to the Pager.
"""

import os
import select
import struct
import time

from quartermaster.ui.keys import Key

EVENT = struct.Struct("llHHi")
EV_KEY = 1
CODES = {103: "UP", 108: "DOWN", 105: "LEFT", 106: "RIGHT", 305: "A", 304: "B", 116: "POWER"}
HOLD_ACTIONS, HOLD_QUIT = 0.6, 2.0
REPEAT_DELAY, REPEAT_EVERY = 0.45, 0.12
DEVICES = ("/dev/input/event0", "/dev/input/event1")


class PagerInput:
    def __init__(self, paths=DEVICES, clock=time.monotonic):
        self.clock = clock
        self.fd = None
        for path in paths:
            try:
                self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                break
            except OSError:
                continue
        if self.fd is None:
            raise OSError("Cannot open the Pager buttons")
        self.devices = [self.fd]
        self.down = {}
        self.fired = set()
        self.quit = False
        self.on_quit = None
        self.on_input = None

    def read_events(self):
        events = []
        while True:
            try:
                data = os.read(self.fd, EVENT.size * 32)
            except BlockingIOError:
                break
            except OSError:
                break
            if not data:
                break
            for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _, _, kind, code, value = EVENT.unpack_from(data, i)
                if kind == EV_KEY and code in CODES:
                    events.append((CODES[code], value))
            if len(data) < EVENT.size * 32:
                break
        return events

    def feed(self, events, now):
        keys = []
        for name, value in events:
            if value == 1:
                self.down[name] = now
                self.fired.discard(name)
                if name in ("UP", "DOWN", "LEFT", "RIGHT"):
                    keys.append(Key(name))
            elif value == 0:
                started = self.down.pop(name, None)
                if started is None or name in self.fired:
                    self.fired.discard(name)
                    continue
                if name == "A":
                    keys.append(Key("ENTER"))
                elif name == "B":
                    keys.append(Key("ESC"))
        keys.extend(self.held(now))
        return keys

    def held(self, now):
        keys = []
        for name, started in list(self.down.items()):
            age = now - started
            if name == "A" and age >= HOLD_ACTIONS and name not in self.fired:
                self.fired.add(name)
                keys.append(Key("TAB"))
            elif name == "B" and age >= HOLD_QUIT and name not in self.fired:
                self.fired.add(name)
                self.quit = True
                if self.on_quit:
                    self.on_quit()
            elif name in ("UP", "DOWN", "LEFT", "RIGHT") and age >= REPEAT_DELAY and name not in self.fired:
                count = int((age - REPEAT_DELAY) / REPEAT_EVERY) + 1
                last = getattr(self, "_repeats", {}).get(name, 0)
                if count > last:
                    self._repeats = {**getattr(self, "_repeats", {}), name: count}
                    keys.append(Key(name, repeat=True))
        for name in list(getattr(self, "_repeats", {})):
            if name not in self.down:
                del self._repeats[name]
        return keys

    def poll(self, timeout):
        if self.down:
            timeout = min(timeout, 0.05) if timeout is not None else 0.05
        ready, _, _ = select.select([self.fd], [], [], timeout)
        events = self.read_events() if ready else []
        if events and self.on_input and self.on_input():
            now = self.clock()
            for name, value in events:
                if value == 1:
                    self.down[name] = now
                    self.fired.add(name)
            return []
        return self.feed(events, self.clock())

    def flush(self):
        self.read_events()
        self.down.clear()
        self.fired.clear()

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
