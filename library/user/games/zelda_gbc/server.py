#!/usr/bin/env python3
"""GBC Emulator Web Server for WiFi Pineapple Pager

Serves the browser-based GBC emulator, lists/uploads ROMs, mirrors
game frames to the pager LCD, and exposes pager button state.
"""

import fcntl
import glob
import json
import os
import socketserver
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

PAYLOAD_DIR = os.path.dirname(os.path.abspath(__file__))
PORT = 8080

# Physical pager display (landscape 270-rotation)
PAGER_W = 480
PAGER_H = 222

# Frame size browser sends: GBC 160x144 scaled 1.5x to fill pager height
FRAME_W = 240   # 160 * 1.5
FRAME_H = 216   # 144 * 1.5
FRAME_BYTES = FRAME_W * FRAME_H * 2  # RGB565 = 103,680 bytes

# Center frame on pager
OFF_X = (PAGER_W - FRAME_W) // 2  # 120
OFF_Y = (PAGER_H - FRAME_H) // 2  # 3

# ----------------------------------------------------------------
# Globals
# ----------------------------------------------------------------
_buttons = 0
_buttons_lock = threading.Lock()

_fb_fd = None          # open file object for /dev/fb0
_fb_lock = threading.Lock()
FB_STRIDE = PAGER_W * 2
_pbuf = bytearray(FB_STRIDE * PAGER_H)

_log_file = None


def _log(*args):
    msg = ' '.join(str(a) for a in args)
    print(msg, flush=True)
    if _log_file:
        _log_file.write(msg + '\n')
        _log_file.flush()


def get_local_ip():
    import socket
    for target in ('10.255.255.255', '8.8.8.8'):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((target, 1))
            ip = s.getsockname()[0]
            s.close()
            if ip and not ip.startswith('127.'):
                return ip
        except Exception:
            pass
    try:
        import socket
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return '127.0.0.1'


def do_quit(pager=None):
    if pager:
        try:
            pager.clear(pager.BLACK)
            pager.draw_text_centered(100, 'Goodbye!', pager.GREEN, 2)
            pager.flip()
            time.sleep(0.5)
            pager.cleanup()
        except Exception:
            pass
    try:
        subprocess.Popen(['/etc/init.d/pineapplepager', 'start'])
    except Exception:
        pass
    os._exit(0)


def probe_fb_stride():
    try:
        buf = bytearray(80)
        with open('/dev/fb0', 'rb') as fd:
            fcntl.ioctl(fd, 0x4602, buf)   # FBIOGET_FSCREENINFO
        stride = struct.unpack_from('<I', buf, 44)[0]
        if stride >= PAGER_W * 2:
            return stride
    except Exception as e:
        _log(f'stride probe failed: {e}')
    return PAGER_W * 2


def write_frame(data):
    """Write a FRAME_W x FRAME_H RGB565 frame centered on the pager LCD."""
    if _fb_fd is None:
        return
    with _fb_lock:
        for row in range(FRAME_H):
            sr = row * FRAME_W * 2
            dr = (OFF_Y + row) * FB_STRIDE + OFF_X * 2
            _pbuf[dr:dr + FRAME_W * 2] = data[sr:sr + FRAME_W * 2]
        try:
            _fb_fd.seek(0)
            _fb_fd.write(_pbuf)
            _fb_fd.flush()
        except Exception as e:
            _log(f'fb0 write: {e}')


# ----------------------------------------------------------------
# Pager thread: show splash screen, poll buttons
# ----------------------------------------------------------------
def pager_thread():
    global _buttons, _fb_fd, FB_STRIDE, _pbuf
    try:
        sys.path.insert(0, PAYLOAD_DIR)
        from pagerctl import Pager
        pager = Pager()
        result = pager.init()
        _log(f'pager.init={result}')
        if result != 0:
            _log('pager init failed, display unavailable')
            return

        pager.set_rotation(270)

        ip = get_local_ip()
        url = f'http://{ip}:{PORT}'

        pager.clear(pager.BLACK)
        pager.draw_text_centered(65,  'GBC EMULATOR',  pager.GREEN, 2)
        pager.draw_text_centered(100, 'Open in browser:', pager.WHITE, 1)
        pager.draw_text_centered(118, url,             pager.CYAN, 2)
        pager.draw_text_centered(165, 'POWER = quit',  pager.GRAY, 1)
        pager.flip()
        _log(f'splash shown: {url}')

        # Open fb0 for direct frame writes (after pager owns display)
        FB_STRIDE = probe_fb_stride()
        _pbuf = bytearray(FB_STRIDE * PAGER_H)
        try:
            _fb_fd = open('/dev/fb0', 'wb')
            _log(f'fb0 opened stride={FB_STRIDE}')
        except Exception as e:
            _log(f'fb0 open: {e}')

        # Poll buttons continuously
        ab_held_since = None
        while True:
            time.sleep(0.05)
            current = pager.peek_buttons()
            with _buttons_lock:
                _buttons = current
            if current & 0x40:   # POWER
                _log('POWER pressed, exiting')
                do_quit(pager)
            if (current & 0x30) == 0x30:  # A+B held
                if ab_held_since is None:
                    ab_held_since = time.time()
                elif time.time() - ab_held_since >= 1.0:
                    _log('A+B held — exiting')
                    do_quit(pager)
            else:
                ab_held_since = None

    except Exception as e:
        _log(f'pager_thread: {e}')
    finally:
        if _fb_fd:
            try:
                _fb_fd.close()
            except Exception:
                pass


# ----------------------------------------------------------------
# HTTP request handler
# ----------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass   # silence access log

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, X-Filename')

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ('/', '/index.html'):
            self._serve_file('index.html', 'text/html; charset=utf-8')
        elif path == '/roms':
            self._serve_roms()
        elif path.startswith('/rom/'):
            self._serve_rom(path[5:])
        elif path == '/buttons':
            self._serve_buttons()
        else:
            fname = os.path.basename(path)
            fpath = os.path.join(PAYLOAD_DIR, fname)
            if os.path.isfile(fpath):
                ct = ('text/html' if fname.endswith('.html') else
                      'application/javascript' if fname.endswith('.js') else
                      'application/octet-stream')
                self._serve_file(fname, ct)
            else:
                self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == '/frame':
            self._handle_frame()
        elif path == '/upload':
            self._handle_upload()
        elif path == '/quit':
            self._handle_quit()
        else:
            self.send_error(404)

    def _serve_file(self, filename, content_type):
        try:
            with open(os.path.join(PAYLOAD_DIR, filename), 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self._cors()
            self.end_headers()
            self.wfile.write(data)
        except FileNotFoundError:
            self.send_error(404)

    def _serve_roms(self):
        roms = sorted(set(
            os.path.basename(p)
            for ext in ('*.gb', '*.gbc', '*.GB', '*.GBC')
            for p in glob.glob(os.path.join(PAYLOAD_DIR, ext))
        ))
        data = json.dumps(roms).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(data))
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _serve_rom(self, name):
        name = os.path.basename(name)
        if not name.lower().endswith(('.gb', '.gbc')):
            self.send_error(404)
            return
        fpath = os.path.join(PAYLOAD_DIR, name)
        if not os.path.isfile(fpath):
            self.send_error(404)
            return
        with open(fpath, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', len(data))
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _serve_buttons(self):
        with _buttons_lock:
            b = _buttons
        data = json.dumps({'buttons': b}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(data))
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _handle_frame(self):
        length = int(self.headers.get('Content-Length', 0))
        if length != FRAME_BYTES:
            self.send_error(400, f'Expected {FRAME_BYTES} bytes, got {length}')
            return
        data = self.rfile.read(length)
        write_frame(data)
        self.send_response(200)
        self._cors()
        self.end_headers()

    def _handle_quit(self):
        self.send_response(200)
        self._cors()
        self.end_headers()
        _log('quit from browser')
        do_quit()

    def _handle_upload(self):
        length = int(self.headers.get('Content-Length', 0))
        if length <= 0 or length > 16 * 1024 * 1024:
            self.send_error(400, 'Bad size')
            return
        name = os.path.basename(self.headers.get('X-Filename', 'rom.gbc'))
        if not name.lower().endswith(('.gb', '.gbc')):
            self.send_error(400, 'Only .gb/.gbc files accepted')
            return
        data = self.rfile.read(length)
        fpath = os.path.join(PAYLOAD_DIR, name)
        with open(fpath, 'wb') as f:
            f.write(data)
        _log(f'uploaded {name} ({len(data)}B)')
        resp = json.dumps({'ok': True, 'name': name}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(resp))
        self._cors()
        self.end_headers()
        self.wfile.write(resp)


class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
def main():
    global _log_file
    _log_file = open(os.path.join(PAYLOAD_DIR, 'server.log'), 'w', buffering=1)
    sys.stderr = _log_file
    _log('[server] starting')

    t = threading.Thread(target=pager_thread, daemon=True)
    t.start()

    ip = get_local_ip()
    _log(f'[server] http://{ip}:{PORT}')

    try:
        server = ThreadedHTTPServer(('', PORT), Handler)
        server.serve_forever()
    except KeyboardInterrupt:
        _log('[server] interrupted')
    finally:
        if _fb_fd:
            try:
                _fb_fd.close()
            except Exception:
                pass
        if _log_file:
            _log_file.close()


if __name__ == '__main__':
    main()
