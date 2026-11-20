"""Line editor and verified, backed-up writes to allocated O.MG source slots."""
import re
import os
import json
import time
from pathlib import Path
from controller import ControllerError


class PayloadEditor:
    def __init__(self, session):
        self.session = session
        self.slot = None

    def read_all(self, address, size, emit):
        data = bytearray()
        for offset in range(0, size, 1024):
            if offset % 4096 == 0:
                emit('LOG', 'Reading slot: %d/%d bytes' % (offset, size))
            data.extend(self.session.read_chunk(address + offset, min(1024, size - offset)))
        return bytes(data)

    def load(self, value, emit, recovery=False):
        self.slot = None
        s = self.session
        s.ready()
        s.catalog(refresh=True)
        slot = s.slot(value)
        address, size = s.files[slot]
        raw = self.read_all(address, size, emit)
        end = min((raw.find(marker) for marker in (b'\0', b'\xff') if marker in raw), default=len(raw))
        source = '' if recovery else raw[:end].decode('utf-8')
        if any(ord(ch) < 32 and ch not in '\t\r\n' for ch in source):
            raise ControllerError('Slot is not plain-text source')
        self.slot, self.address, self.size, self.original = slot, address, size, raw
        self.lines = source.splitlines(keepends=True)
        self.newline = '\r\n' if '\r\n' in source else '\n'
        s.prepared = None

    def source(self):
        return ''.join(self.lines).encode('utf-8')

    @staticmethod
    def backup_slot(name):
        match = re.fullmatch(r'([0-9]{3})-[A-Za-z0-9 _-]{1,10}-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(?:-[0-9]+)?\.txt', name)
        return int(match[1]) if match and 1 <= int(match[1]) <= 200 else None

    def store_backup(self, slot, data, emit):
        end = min((data.find(marker) for marker in (b'\0', b'\xff') if marker in data), default=len(data))
        data = data[:end]
        if not data:
            emit('LOG', 'Slot %03d is empty; backup skipped.' % slot)
            return None
        source = data.decode('utf-8')
        if any(ord(ch) < 32 and ch not in '\t\r\n' for ch in source):
            raise ControllerError('Slot is not plain-text source; cannot create a .txt backup')
        folder = Path(__file__).resolve().parent / 'backups'
        folder.mkdir(exist_ok=True)
        preview = next((line.strip() for line in source.splitlines() if line.strip()), 'Empty')
        preview = re.sub(r'^REM(?:[ \t]+|$)', '', preview, count=1, flags=re.IGNORECASE)
        preview = re.sub(r'[^A-Za-z0-9 _-]', '_', preview)
        preview = re.sub(r'\s+', ' ', preview)[:10].strip(' _-') or 'Empty'
        stamp = time.strftime('%Y-%m-%d_%H-%M-%S')
        base = '%03d-%s-%s' % (slot, preview, stamp)
        counter = 1
        while True:
            backup = folder / (base + ('' if counter == 1 else '-%d' % counter) + '.txt')
            try:
                output = backup.open('xb')
                break
            except FileExistsError:
                counter += 1
        with output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        emit('LOG', 'Original slot backup: backups/' + backup.name)
        return backup

    def write(self, verb, number, suffix=''):
        s = self.session
        s.serial += 1
        tag = '[ed%d]' % s.serial
        command = (tag + verb + str(number)).encode() + suffix if isinstance(suffix, bytes) else tag + verb + str(number) + suffix
        reply = s.request(command, expected=verb, tag=tag, write=True)
        header = reply.split(b'\t', 1)[0].decode('ascii', 'replace').replace(tag, '', 1)
        # Bare acknowledgements can end in CR/LF. These are framing, not part
        # of the echoed sector/address; never strip bytes from flash contents.
        normalized = header.strip(' \r\n')
        match = re.fullmatch(verb + r'([0-9]+)?', normalized)
        if normalized and (not match or (match[1] and int(match[1]) != number)):
            raise ControllerError('Unexpected write acknowledgement; expected %s%d, received %r; outcome unknown'
                                  % (verb, number, header[:80]))

    def save(self, emit):
        s = self.session
        data = self.source()
        if len(data) >= self.size:
            raise ControllerError('Payload exceeds slot capacity (one byte reserved for terminator)')
        desired = data + b'\0'
        desired += b'\0' * (-len(desired) % 4)
        s.ready()
        s.catalog(refresh=True)
        if s.files.get(self.slot) != (self.address, self.size):
            raise ControllerError('Slot allocation changed; reopen the editor')
        # The web frontend separately recompiles bootscript when bootpair matches.
        # Do not silently leave an active boot payload out of sync.
        # CTGet raises CTError when an optional key is absent. Like the official
        # frontend, inspect CTList instead; absence in a valid list means unpaired.
        try:
            fields = s.request('CTList').decode('utf-8').split('\t')
            settings = json.loads(fields[1]) if len(fields) >= 2 else None
            if not isinstance(settings, dict):
                raise ValueError('Expected a settings object')
            pair = settings.get('bootpair', '')
            if not isinstance(pair, (str, int)) or isinstance(pair, bool):
                raise ValueError('Invalid bootpair value')
            pair = str(pair)
            match = re.fullmatch(r'(?:payload)?([0-9]{1,3})', pair)
            if pair and (not match or not 0 <= int(match[1]) <= 200):
                raise ValueError('Invalid bootpair value')
        except (ControllerError, ValueError) as exc:
            raise ControllerError('Could not check boot payload pairing via CTList; no changes made. ' + str(exc)) from exc
        if match and int(match[1]) == self.slot:
            raise ControllerError('This slot is paired with bootscript. Edit it in the O.MG web UI to update both.')
        current = self.read_all(self.address, self.size, emit)
        if current != self.original:
            raise ControllerError('Slot changed since editing began; reopen it before saving')
        backup = self.store_backup(self.slot, current, emit)
        try:
            for offset in range(0, self.size, 4096):
                emit('LOG', 'Erasing slot sector %d/%d' % (offset // 4096 + 1, self.size // 4096))
                self.write('FE', (self.address + offset) // 4096)
            for offset in range(0, len(desired), 1024):
                chunk = desired[offset:offset + 1024]
                emit('LOG', 'Writing payload: %d/%d bytes' % (offset, len(desired)))
                self.write('FW', self.address + offset, b'\t' + str(len(chunk)).encode() + b'\t' + chunk)
            actual = self.read_all(self.address, self.size, emit)
            expected = desired.ljust(self.size, b'\xff')
            if actual != expected:
                raise ControllerError('Flash readback did not match')
        except Exception as exc:
            recovery = 'Backup: ' + backup.name if backup else 'Destination was empty; no backup created'
            raise ControllerError('Save incomplete or uncertain; not retried. ' + recovery + '. ' + str(exc)) from exc
        self.original = actual
        s.prepared = None
        s.view = None
        emit('LOG', 'Payload %d saved and verified.' % self.slot)

    def do(self, action, arg, emit):
        if action == 'edit-clear':
            self.load(arg, emit, recovery=True)
            self.save(emit)  # Empty source, with backup and full readback verification.
            emit('LOG', 'Payload %03d cleared.' % self.slot)
            self.slot = None
            return
        if action == 'edit-backup':
            s = self.session
            s.ready()
            s.catalog(refresh=True)
            slot = s.slot(arg)
            address, size = s.files[slot]
            data = self.read_all(address, size, emit)
            if self.store_backup(slot, data, emit) is not None:
                emit('LOG', 'Payload %03d source backed up as .txt.' % slot)
            return
        if action == 'edit-import-files':
            folder = Path(__file__).resolve().parent / 'payloads'
            if folder.is_dir():
                for path in sorted(folder.iterdir(), key=lambda p: p.name.lower()):
                    if (path.is_file() and not path.is_symlink() and path.suffix.lower() == '.txt'
                            and len(path.name) <= 200 and all(ch.isprintable() for ch in path.name)):
                        emit('ITEM', path.name)
            return
        if action == 'edit-import-load':
            self.slot = None
            slot, separator, name = arg.partition('\t')
            folder = Path(__file__).resolve().parent / 'payloads'
            if (not separator or not name or '/' in name or '\\' in name
                    or Path(name).suffix.lower() != '.txt' or not all(ch.isprintable() for ch in name)):
                raise ControllerError('Choose a .txt file from the payloads folder')
            path = folder / name
            if (not path.is_file() or path.is_symlink() or path.resolve().parent != folder.resolve()
                    or not 0 < path.stat().st_size <= 524288):
                raise ControllerError('Import file missing, empty, or too large')
            source = path.read_bytes().decode('utf-8-sig')
            if not source or any(ord(ch) < 32 and ch not in '\t\r\n' for ch in source):
                raise ControllerError('Import requires UTF-8 plain text without binary data')
            self.load(slot, emit)
            if self.source():
                self.slot = None
                raise ControllerError('Slot is no longer empty; import cancelled')
            if len(source.encode('utf-8')) >= self.size:
                self.slot = None
                raise ControllerError('Imported payload exceeds slot capacity')
            self.lines = source.splitlines(keepends=True)
            self.newline = '\r\n' if '\r\n' in source else '\n'
            emit('LOG', 'Loaded ' + name + ' for import.')
            return
        if action == 'edit-backups':
            folder = Path(__file__).resolve().parent / 'backups'
            for path in sorted(folder.glob('*.txt'), reverse=True):
                if self.backup_slot(path.name) is not None and path.is_file() and not path.is_symlink():
                    emit('ITEM', path.name)
            return
        if action == 'edit-restore-load':
            self.slot = None
            original_slot = self.backup_slot(arg)
            if original_slot is None:
                raise ControllerError('Invalid backup filename')
            path = Path(__file__).resolve().parent / 'backups' / arg
            if path.is_symlink() or not path.is_file() or not 0 <= path.stat().st_size <= 524288:
                raise ControllerError('Invalid backup file')
            raw = path.read_bytes()
            source = raw.decode('utf-8-sig')
            if any(ord(ch) < 32 and ch not in '\t\r\n' for ch in source):
                raise ControllerError('Backup must contain UTF-8 plain text')
            self.load(str(original_slot), emit, recovery=True)
            if len(source.encode('utf-8')) >= self.size:
                self.slot = None
                raise ControllerError('Backup size does not match current slot capacity')
            self.lines = source.splitlines(keepends=True)
            self.newline = '\r\n' if '\r\n' in source else '\n'
            emit('LOG', 'Restore payload %03d from %s' % (self.slot, arg))
            emit('LOG', '%d bytes of source; preview:' % len(source.encode('utf-8')))
            for line in self.lines[:5]:
                emit('LOG', line.rstrip('\r\n'))
            return
        if action == 'edit-load':
            self.load(arg, emit)
            return
        if action == 'edit-discard':
            self.slot = None
            return
        if self.slot is None:
            raise ControllerError('Open a payload in the editor first')
        if action == 'edit-restore-target':
            source = self.source()
            slot, _, mode = arg.partition('\t')
            self.load(slot, emit, recovery=True)
            if mode == 'new' and self.original[:1] not in (b'\0', b'\xff'):
                self.slot = None
                raise ControllerError('New Slot is no longer empty; choose a destination again')
            if len(source) >= self.size:
                self.slot = None
                raise ControllerError('Backup source exceeds destination slot capacity')
            text = source.decode('utf-8')
            self.lines = text.splitlines(keepends=True)
            self.newline = '\r\n' if '\r\n' in text else '\n'
            emit('LOG', 'Restore destination: payload %03d (%d source bytes)' % (self.slot, len(source)))
            return
        if action == 'edit-list':
            for i, line in enumerate(self.lines):
                emit('ITEM', '%d | %s' % (i + 1, line.rstrip('\r\n')[:60]))
            emit('LOG', '%d bytes of %d available' % (len(self.source()), self.size - 1))
        elif action == 'edit-save':
            self.save(emit)
        else:
            number, separator, value = arg.partition('=')
            if not number.isdigit():
                raise ControllerError('Invalid line number')
            index = int(number) - 1
            if not 0 <= index <= len(self.lines):
                raise ControllerError('Invalid line number')
            if action in ('edit-get', 'edit-delete', 'edit-replace') and index == len(self.lines):
                raise ControllerError('Line no longer exists')
            if action == 'edit-get':
                # Sentinels preserve leading/trailing tabs/spaces through Bash read.
                print('TEXT\t=' + self.lines[index].rstrip('\r\n') + '=', flush=True)
            elif action == 'edit-delete':
                del self.lines[index]
            elif action in ('edit-replace', 'edit-insert'):
                if not separator or any((ord(ch) < 32 and ch != '\t') or ch == '\x7f' for ch in value):
                    raise ControllerError('Enter a single line without control characters')
                previous = self.lines[:]
                if action == 'edit-replace':
                    old = self.lines[index]
                    ending = old[len(old.rstrip('\r\n')):]
                    self.lines[index] = value + ending
                else:
                    if index == len(self.lines) and self.lines and not self.lines[-1].endswith(('\n', '\r')):
                        self.lines[-1] += self.newline
                    self.lines.insert(index, value + self.newline)
                if len(self.source()) >= self.size:
                    self.lines = previous
                    raise ControllerError('Payload exceeds slot capacity')
            else:
                raise ControllerError('Unknown editor action')
