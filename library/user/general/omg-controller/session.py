"""Persistent local helper for Pager UI and O.MG v3 payload browsing."""
import json
import re
import socket
import sys
import time
from pathlib import Path

from controller import ACTIONS, ControllerError, HOST, URL, TIMEOUT, clean, describe, websocket
from ducky import CompileError, compile_source
from editor import PayloadEditor

USB_SETTING_KEYS = ('usbvid', 'usbpid', 'usbman', 'usbpro', 'usbser')


def event(kind, text):
    print(kind + "\t" + clean(str(text)), flush=True)


class Session:
    def __init__(self):
        self.ws = None
        self.serial = 0
        self.files = None
        self.view = None
        self.prepared = None
        self.descriptor_draft = None
        self.editor = PayloadEditor(self)

    def close(self):
        if self.ws is not None:
            try:
                self.ws.close(timeout=0.05)
            except (OSError, websocket.WebSocketException):
                pass
        self.ws = None

    def connect(self):
        self.close()
        sock = socket.create_connection((HOST, 80), timeout=TIMEOUT)
        try:
            self.ws = websocket.create_connection(URL, socket=sock, timeout=TIMEOUT,
                origin="http://192.168.4.1", skip_utf8_validation=True)
        except Exception:
            sock.close()
            raise

    def ready(self):
        if self.ws is not None:
            try:
                self.request("E")  # A read-only barrier discards queued notifications.
                return
            except (ControllerError, OSError, websocket.WebSocketException):
                self.close()
        self.connect()  # Reconnect before an action, never replay an action.

    def request(self, command, expected=None, write=False, tag=None):
        expected = expected or command.split("\t", 1)[0]
        end = time.monotonic() + TIMEOUT
        last_header = "(no reply)"
        try:
            self.ws.settimeout(TIMEOUT)
            self.ws.send(command)
            while time.monotonic() < end:
                self.ws.settimeout(max(0.01, end - time.monotonic()))
                opcode, data = self.ws.recv_data()
                if opcode == 8 or not data:
                    raise ConnectionError("Device disconnected")
                if isinstance(data, str):
                    data = data.encode("utf-8")
                token = re.split(rb"[\t\r\n ]", data, maxsplit=1)[0].decode("ascii", "replace")
                last_header = clean(token[:80])
                reply_tags = re.findall(r"\[[^\[\]]*\]", token)
                if tag is not None and reply_tags and reply_tags != [tag]:
                    continue
                # Inspect only reply headers, never user script contents.
                if token.endswith("Error") or data.lower().startswith(b"unrecognized command"):
                    raise ControllerError("Device error: " + clean(data[:300].decode('utf-8', 'replace')))
                # The official frontend correlates flash replies by bracketed ID,
                # not by an exact echo of FR plus its address.
                expected_tokens = (expected,) if isinstance(expected, str) else expected
                if (tag is not None and reply_tags == [tag]) or (tag is None and token in expected_tokens):
                    return data
            raise TimeoutError("No matching response")
        except (OSError, websocket.WebSocketException) as exc:
            if write:
                raise ControllerError("No acknowledgement; action may have taken effect. Not retried.") from exc
            raise ControllerError("Timed out/disconnected waiting for " + (tag or str(expected))
                                  + "; last reply header: " + last_header) from exc

    def catalog(self, refresh=False):
        if self.files is not None and not refresh:
            return self.files
        entries, cursor, seen = {}, None, set()
        for _ in range(256):
            command = "CFList" + ("\t" + cursor if cursor is not None else "")
            parts = self.request(command, "CFList").decode("utf-8").split("\t")
            if len(parts) < 2:
                raise ControllerError("Invalid CFList response")
            page = json.loads(parts[1])
            if not isinstance(page, dict):
                raise ControllerError("Invalid filesystem listing")
            entries.update(page)
            if len(parts) < 4 or parts[3].strip() == "0":
                break
            cursor = parts[3].strip()
            if not cursor.isdigit() or cursor in seen:
                raise ControllerError("Invalid/repeated CFList cursor")
            seen.add(cursor)
        else:
            raise ControllerError("Filesystem listing did not finish")
        # v3 frontend parses CFList sector numbers in decimal. Older hex maps
        # must not be guessed: this module targets the user's 3.0.16 backend.
        files = {}
        for name, values in entries.items():
            match = re.fullmatch(r"payload([1-9][0-9]{0,2})", name)
            if not match or not 1 <= int(match[1]) <= 200:
                continue
            if not isinstance(values, list) or len(values) < 2:
                raise ControllerError("Invalid slot geometry")
            if any(not re.fullmatch(r"[0-9]+", str(v)) for v in values[:2]):
                raise ControllerError("Unsupported non-decimal slot map; use the O.MG web UI")
            sector, count = map(int, values[:2])
            if count == 0:
                continue
            if sector < 1 or count > 128 or sector + count > 4096:
                raise ControllerError("Slot geometry outside supported bounds")
            files[int(match[1])] = (sector * 4096, count * 4096)
        self.files = files
        return files

    def slot(self, value):
        if not re.fullmatch(r"[0-9]{1,3}", str(value)) or not 1 <= int(value) <= 200:
            raise ControllerError("Choose a slot from 1 through 200")
        slot = int(value)
        if slot not in self.catalog():
            raise ControllerError("Slot %d is not allocated on this device" % slot)
        return slot

    def read_chunk(self, address, length):
        self.serial += 1
        tag = "[pg%d]" % self.serial
        command = "%sFR%d\t%d" % (tag, address, length)
        raw = self.request(command, tag=tag)
        parts = raw.split(b"\t", 2)
        header = parts[0].decode("ascii", "replace")
        response = header.replace(tag, "", 1)
        address_match = re.fullmatch(r"FR([0-9]+)", response)
        # Firmware may echo decimal addresses padded to eight digits.
        valid_header = response in ("", "FR") or (
            address_match is not None and int(address_match[1], 10) == address)
        if len(parts) != 3 or not parts[1].isdigit() or not valid_header:
            raise ControllerError("Unexpected flash-read response header: " + clean(header[:80]))
        metadata, content = int(parts[1]), parts[2]
        # Current frontend consumes data after two tab-separated fields. Accept
        # address or length metadata, checking the actual byte count in either case.
        # Also support the API reference's FR\taddress\tlength\tdata layout.
        if metadata == address and len(content) != length:
            size_field, separator, body = content.partition(b"\t")
            if separator and size_field.isdigit() and int(size_field) == length:
                content = body
        if metadata not in (address, length):
            raise ControllerError("Unexpected flash-read response layout")
        if len(content) != length:
            raise ControllerError("Incomplete flash read: expected %d bytes, received %d; header: %s"
                                  % (length, len(content), clean(header[:80])))
        return content

    def read_slot(self, value, preview=False):
        slot = self.slot(value)
        address, size = self.files[slot]
        data = bytearray()
        limit = min(size, 256) if preview else size
        for offset in range(0, limit, 1024):
            chunk = self.read_chunk(address + offset, min(1024, limit - offset))
            end = min((chunk.find(marker) for marker in (b"\0", b"\xff") if marker in chunk), default=len(chunk))
            data.extend(chunk[:end])
            if end < len(chunk):
                break
        # Never silently replace malformed text and then compile it.
        try:
            text = bytes(data).decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            if preview:
                text = bytes(data).decode("utf-8", errors="replace")
            else:
                raise ControllerError("Slot contains binary/non-UTF8 data; source execution is unavailable") from exc
        if any(ord(ch) < 32 and ch not in "\r\n\t" for ch in text):
            raise ControllerError("Slot is not plain-text source")
        return text

    @staticmethod
    def descriptor_value(index, value):
        if index < 2:
            if not re.fullmatch(r"(?:0[xX])?[0-9a-fA-F]{1,4}", value):
                raise ControllerError("VID and PID must contain 1-4 hexadecimal digits")
            return "%04x" % int(value, 16)
        if len(value) > 63 or any(not 32 <= ord(ch) <= 126 for ch in value):
            raise ControllerError("Descriptor text: up to 63 printable ASCII characters, no tabs/newlines")
        return value

    def get_descriptors(self):
        parts = self.request("CNGet").decode("utf-8").split("\t")
        if len(parts) != 6:
            raise ControllerError("Unexpected USB descriptor response")
        stored = self.usb_settings()
        return [self.descriptor_value(i, stored.get(key, value))
                for i, (key, value) in enumerate(zip(USB_SETTING_KEYS, parts[1:]))]

    def usb_settings(self):
        parts = self.request('CTList').decode('utf-8').split('\t')
        try:
            settings = json.loads(parts[1]) if len(parts) > 1 else None
        except ValueError as exc:
            raise ControllerError('Invalid USB settings response') from exc
        if not isinstance(settings, dict):
            raise ControllerError('Invalid USB settings response')
        selected = {key: value for key, value in settings.items() if key in USB_SETTING_KEYS}
        if any(not isinstance(value, str) for value in selected.values()):
            raise ControllerError('Invalid USB setting value')
        return selected

    def do(self, action, arg="", emit=event):
        if action.startswith('edit-'):
            return self.editor.do(action, arg, emit)
        if action in ("descriptor-edit", "descriptor-review"):
            if self.descriptor_draft is None:
                raise ControllerError("Load descriptors before editing")
            if action == "descriptor-edit":
                index, separator, value = arg.partition("=")
                if not separator or index not in ("0", "1", "2", "3", "4"):
                    raise ControllerError("Invalid descriptor field")
                index = int(index)
                self.descriptor_draft[index] = self.descriptor_value(index, value)
                emit("FIELD", "%d=%s" % (index, self.descriptor_draft[index]))
            else:
                for name, value in zip(("VID", "PID", "Manufacturer", "Product", "Serial"), self.descriptor_draft):
                    emit("LOG", name + ": " + value)
            return
        if action == "descriptor-load":
            self.descriptor_draft = None
            self.ready()
            self.descriptor_draft = self.get_descriptors()
            for i, value in enumerate(self.descriptor_draft):
                emit("FIELD", "%d=%s" % (i, value))
            return
        if action == "descriptor-save":
            if self.descriptor_draft is None:
                raise ControllerError("Load descriptors before saving")
            values = self.descriptor_draft[:]
            self.descriptor_draft = None
            self.ready()
            try:
                for index, (key, value) in enumerate(zip(USB_SETTING_KEYS, values)):
                    self.request('CTSet\t' + key + '\t' + value, expected='CTSet', write=True)
                    # Firmware acknowledgement fields vary. Verify the persisted
                    # setting itself instead of assuming field 1 echoes its key.
                    saved = self.usb_settings()
                    if key not in saved or self.descriptor_value(index, saved[key]) != value:
                        raise ControllerError('Descriptor readback differs for ' + key)
                stored = self.usb_settings()
                if any(key not in stored for key in USB_SETTING_KEYS):
                    raise ControllerError('USB settings missing from readback')
                actual = [self.descriptor_value(i, stored[key]) for i, key in enumerate(USB_SETTING_KEYS)]
                if actual != values:
                    raise ControllerError('Descriptor readback differs from requested values')
            except (ControllerError, OSError, ValueError, websocket.WebSocketException) as exc:
                raise ControllerError('Descriptor save incomplete; some settings may have changed. Not retried. ' + str(exc)) from exc
            emit("LOG", "USB descriptors saved and verified.")
            emit("LOG", "Reboot O.MG from the main menu to apply the saved defaults.")
            return
        if action == 'descriptors':
            self.ready()
            values = self.get_descriptors()
            for name, value in zip(('VID', 'PID', 'Manufacturer', 'Product', 'Serial'), values):
                emit('LOG', name + ': ' + value)
            emit('LOG', 'Saved defaults; reboot O.MG after changing these.')
            return
        if action == "view-page":
            if self.view is None:
                raise ControllerError("Choose View first")
            page = int(arg)
            pages = self.view
            if not 0 <= page < len(pages):
                raise ControllerError("Invalid page")
            emit("LOG", "Page %d of %d" % (page + 1, len(pages)))
            for line in pages[page]:
                emit("LOG", line)
            return
        if action == "reboot":
            # Reboot often disconnects before acknowledging. Send once without
            # an echo/status preflight or a response/reconnection check.
            try:
                if self.ws is None:
                    self.connect()
                self.ws.settimeout(TIMEOUT)
                self.ws.send("CR1")
            finally:
                self.close()
                self.files = None
            return
        self.ready()
        if action in ACTIONS:
            for command, label in ACTIONS[action]:
                raw = self.request(command, write=action in ("jiggler-on", "jiggler-off", "usb-on", "usb-off", "reboot"))
                for line in describe(command, label, raw.decode("utf-8", "replace")):
                    emit("LOG", line)
            return
        if action in ("slots", "populated", "payloads", "restore-slots"):
            files = self.catalog(refresh=True)
            emit("LOG", "%d allocated slots" % len(files))
            empty_slots, last_populated = [], 0
            payload_titles = {}
            for index, slot in enumerate(sorted(files), 1):
                if action != "slots":
                    if index == 1 or index % 10 == 0:
                        emit("LOG", "Checking %d/%d slots" % (index, len(files)))
                    text = self.read_slot(slot, preview=True)
                    if not text:
                        empty_slots.append(slot)
                        continue
                    last_populated = slot
                    title = next((line.strip() for line in text.splitlines() if line.strip()), "(whitespace)")
                    title = re.sub(r'^REM(?:[ \t]+|$)', '', title, count=1, flags=re.IGNORECASE) or '(empty comment)'
                    if action == 'payloads':
                        payload_titles[slot] = clean(title)[:60]
                    else:
                        emit("ITEM", "%03d | %s" % (slot, clean(title)[:60]))
                else:
                    emit("ITEM", "%03d | %d KB capacity" % (slot, files[slot][1] // 1024))
            if action == 'payloads':
                for slot in empty_slots:
                    if slot < last_populated:
                        payload_titles[slot] = 'Create New'
                next_empty = next((slot for slot in empty_slots if slot > last_populated), None)
                if next_empty is not None:
                    payload_titles[next_empty] = 'Create New'
                    emit('NEW_SLOT', next_empty)
                for slot in sorted(payload_titles):
                    if slot in empty_slots:
                        emit('EMPTY_SLOT', slot)
                    emit('ITEM', '%03d | %s' % (slot, payload_titles[slot]))
            if action == "restore-slots":
                if empty_slots:
                    new_slot = next((slot for slot in empty_slots if slot > last_populated), empty_slots[0])
                    emit("NEW_SLOT", new_slot)
                    emit("ITEM", "%03d | %s" % (new_slot, 'New Slot (empty)' if action == 'restore-slots' else 'Create New'))
                else:
                    emit("LOG", "No unused allocated payload slots available.")
            return
        if action == "view":
            text = self.read_slot(arg)
            if not text:
                raise ControllerError("Slot is empty")
            rows = []
            for n, line in enumerate(text.splitlines(), 1):
                expanded = line.expandtabs(4)
                for start in range(0, max(1, len(expanded)), 60):
                    rows.append(("%d: " % n if start == 0 else "   ") + expanded[start:start + 60])
            self.view = [rows[i:i + 10] for i in range(0, len(rows), 10)] or [["(empty)"]]
            emit("PAGES", len(self.view))
            emit("LOG", "Slot %s: %d bytes; %d pages" % (arg, len(text.encode()), len(self.view)))
            return
        if action == "prepare":
            self.prepared = None
            text = self.read_slot(arg)
            frames = compile_source(text)
            self.prepared = (int(arg), frames)
            emit("LOG", "Slot %s validated: %d segments, US keyboard layout" % (arg, len(frames)))
            return
        if action == "execute":
            if self.prepared is None or str(self.prepared[0]) != str(int(arg)):
                raise ControllerError("Validate this slot before executing")
            slot, frames = self.prepared
            self.prepared = None  # Single-use, including failures.
            status = self.request("CEStatus").decode("ascii", "replace").split()
            if len(status) < 2 or status[1].lower() != "idle":
                raise ControllerError("Device is not idle; payload was not sent")
            try:
                for frame in frames:
                    self.ws.settimeout(TIMEOUT)
                    self.ws.send(frame)
                    # Status query is also a barrier; surface CEError from any segment.
                    state = self.request("CEStatus").decode("ascii", "replace")
                emit("LOG", "Slot %d submitted. %s" % (slot, state))
                emit("LOG", "Submission does not confirm host-side completion.")
            except (ControllerError, OSError, websocket.WebSocketException) as exc:
                raise ControllerError("Payload send interrupted: outcome unknown; not retried. " + str(exc)) from exc
            return
        if action == "timing":
            for i in range(3):
                start = time.monotonic()
                self.request("E")
                emit("LOG", "Echo %d: %.0f ms" % (i + 1, (time.monotonic() - start) * 1000))
            return
        raise ControllerError("Unknown action")


def worker():
    session = Session()
    event("READY", "O.MG helper ready")
    try:
        for line in sys.stdin:
            fields = line.rstrip("\n").split("\t", 1)
            action, arg = fields[0], fields[1] if len(fields) == 2 else ""
            if action == "quit":
                break
            start = time.monotonic()
            try:
                session.do(action, arg)
                event("TIME", "%.2f s" % (time.monotonic() - start))
                event("DONE", "0")
            except (ControllerError, CompileError, OSError, ValueError, websocket.WebSocketException) as exc:
                session.prepared = None
                session.close()
                session.files = None
                event("ERROR", str(exc))
                event("DONE", "1")
    finally:
        session.close()


if __name__ == "__main__":
    worker()
