#!/usr/bin/env python3
"""Shows a QR code on the Pager screen (the radio's channel share link, for the
Meshtastic phone app's QR scanner). Any button closes it, or after --timeout s.

QR matrix: qrcodegen (Project Nayuki, MIT, in this folder). Drawing: pagerfb.
The text is read from a file and that file is deleted, so the link (it carries the
channel keys) does not stay on the Pager.
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import qrcodegen  # noqa: E402
import pagerfb  # noqa: E402

W, H = 480, 222


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True, help="file with the text; deleted after reading")
    ap.add_argument("--title", default="Scan with the Meshtastic app")
    ap.add_argument("--timeout", type=int, default=120)
    a = ap.parse_args(argv)
    try:
        with open(a.file, encoding="utf-8") as fh:
            text = fh.readline().strip()
    finally:
        try:
            os.remove(a.file)
        except OSError:
            pass
    if not text:
        return 2
    q = qrcodegen.QrCode.encode_text(text, qrcodegen.QrCode.Ecc.LOW)
    n = q.get_size()
    with pagerfb.Pager() as p:
        p.set_rotation(270)
        p.clear_input_events()
        white, black, grey = p.rgb(255, 255, 255), p.rgb(0, 0, 0), p.rgb(150, 150, 150)
        p.clear(black)
        scale = max(1, (H - 8) // (n + 2))
        size = (n + 2) * scale
        x0, y0 = 4, (H - size) // 2
        p.fill_rect(x0, y0, size, size, white)
        for y in range(n):
            for x in range(n):
                if q.get_module(x, y):
                    p.fill_rect(x0 + (x + 1) * scale, y0 + (y + 1) * scale, scale, scale, black)
        tx = x0 + size + 12
        p.draw_text(tx, 20, "CHANNELS", white, 2)
        y = 52
        for line in (a.title, "", "This code holds your", "channel keys: show it", "only to people who", "should join the mesh.",
                     "", "Any button: close"):
            p.draw_text(tx, y, line, grey if not line.startswith("Scan") else white, 1)
            y += 14
        p.flip()
        end = time.time() + a.timeout
        while time.time() < end:
            if p.poll_input()[1]:
                break
            time.sleep(0.05)
    return 0


if __name__ == "__main__":
    sys.exit(main())
