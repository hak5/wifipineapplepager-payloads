#!/usr/bin/env python3
"""
pager_display.py — PWRLVL9000 Pager hardware display

Draws the status screen using libpagerctl.so directly.
Stops pineapplepager before init so we own the screen,
restarts it in the finally block regardless of how we exit.

Exit codes:
  0 — user pressed B (normal stop)
  1 — pagerctl unavailable / hardware error
"""

import os, sys, signal, json, time, subprocess

# ── Path setup ────────────────────────────────────────────────────────────
_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB  = os.path.join(_HERE, 'lib')
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)

try:
    from pagerctl import Pager
except Exception as e:
    print(f'pagerctl unavailable: {e}', file=sys.stderr)
    sys.exit(1)

# ── Config from environment ───────────────────────────────────────────────
WEBUI_PORT = os.environ.get('WEBUI_PORT', '9000')
LOOT_DIR   = os.environ.get('LOOT_DIR', '/root/loot/pwrlvl9000')
XP_FILE    = os.path.join(LOOT_DIR, 'xp.json')

# ── XP / level system ─────────────────────────────────────────────────────
LEVELS = [
    (0,     1,    'APPRENTICE'),
    (100,   2,    'ACOLYTE'),
    (300,   3,    'CONJURER'),
    (700,   4,    'WARLOCK'),
    (1500,  5,    'NECROMANCER'),
    (3000,  6,    'LICH'),
    (6000,  7,    'DREADLORD'),
    (12000, 8,    'ARCHLICH'),
    (25000, 9000, 'PWRLVL9000'),
]
XP_THRESHOLDS = [t for t, _, _ in LEVELS]


def _calc_level(xp):
    level, title, xp_next = 1, 'APPRENTICE', 100
    for thresh, lvl, ttl in LEVELS:
        if xp >= thresh:
            level, title = lvl, ttl
        else:
            xp_next = thresh
            break
    else:
        xp_next = 0
    return level, title, xp_next


def load_xp():
    try:
        with open(XP_FILE) as f:
            d = json.load(f)
        xp = d.get('xp', 0)
        level, title, xp_next = _calc_level(xp)
        return xp, level, title, xp_next
    except Exception:
        return 0, 1, 'APPRENTICE', 100


# ── Sprite frames ─────────────────────────────────────────────────────────
_ASSETS   = os.path.join(_HERE, 'web', 'assets')
_N_FRAMES = 8
_SPRITE_W = 120   # display size on Pager screen
_SPRITE_H = 120
_SPRITE_X = 4
_SPRITE_Y = 22


def _load_frames(p):
    """Pre-load all idle animation frames; returns list of handles (None on failure)."""
    handles = []
    for i in range(_N_FRAMES):
        path = os.path.join(_ASSETS, f'necro_idle_{i}.png')
        h = p.load_image(path)
        handles.append(h)
    return handles


def _free_frames(p, handles):
    for h in handles:
        if h is not None:
            p.free_image(h)


# ── ASCII fallback art ────────────────────────────────────────────────────
_NECRO_ASCII = [
    ('    *    ', 0xF800),
    ('   /|\\   ', 0x07FF),
    ('  (x x)  ', 0x07FF),
    ('   )|(   ', 0xF800),
    ('  / | \\  ', 0x07FF),
    (' |  |  | ', 0x07FF),
    ('  \\_|_/  ', 0x07FF),
]

# ── Colors ────────────────────────────────────────────────────────────────
_PURPLE      = 0x8010
_BAR_PURPLE  = Pager.rgb(160, 0, 220)
_INFO_X      = 128   # right column x (sprite ends at 4+120=124, leave 4px gap)


# ── Screen draw ───────────────────────────────────────────────────────────
def draw_screen(p, xp, level, title, xp_next, frame_handles, frame_idx):
    W = p.width    # 480
    H = p.height   # 222

    p.clear(p.BLACK)

    # ── Title bar ────────────────────────────────────────────────────────
    p.fill_rect(0, 0, W, 20, _PURPLE)
    p.draw_text_centered(3, 'PWRLVL9000', p.BLACK, 2)
    p.hline(0, 20, W, p.GRAY)

    # ── Sprite (or ASCII fallback) ───────────────────────────────────────
    if frame_handles and frame_handles[frame_idx] is not None:
        p.draw_image_scaled(_SPRITE_X, _SPRITE_Y,
                            _SPRITE_W, _SPRITE_H,
                            frame_handles[frame_idx])
    else:
        # ASCII fallback
        for i, (line, color) in enumerate(_NECRO_ASCII):
            p.draw_text(4, _SPRITE_Y + i * 10, line, color, 1)

    # ── Info panel ───────────────────────────────────────────────────────
    # At size=2: each char is 10×14px. Right column from x=_INFO_X to W-4.
    RX = _INFO_X

    p.draw_text(RX, 27, f'LVL {level}', p.YELLOW, 2)   # y=27, h=14 → ends 41
    p.draw_text(RX, 45, title,          p.CYAN,   2)   # y=45, h=14 → ends 59
    p.draw_text(RX, 63, f'172.16.42.1:{WEBUI_PORT}', p.CYAN, 2)  # ends 77

    # XP text (size=2)
    p.draw_text(RX, 83, f'XP: {xp}', p.WHITE, 2)
    if xp_next:
        p.draw_text(RX + 100, 83, f'/ {xp_next}', p.GRAY, 2)
    else:
        p.draw_text(RX + 100, 83, 'MAX!', p.YELLOW, 2)

    # XP bar — thicker at 14px
    bx = RX
    by = 101
    bw = W - RX - 4
    bh = 14
    p.rect(bx, by, bw, bh, p.GRAY)
    if xp_next:
        prev_t = XP_THRESHOLDS[level - 1] if level - 1 < len(XP_THRESHOLDS) else 0
        denom  = xp_next - prev_t
        pct    = min(1.0, (xp - prev_t) / denom) if denom > 0 else 1.0
        fill_w = max(0, int((bw - 2) * pct))
        if fill_w:
            p.fill_rect(bx + 1, by + 1, fill_w, bh - 2, _BAR_PURPLE)
    else:
        p.fill_rect(bx + 1, by + 1, bw - 2, bh - 2, p.YELLOW)

    # ── Bottom bar ────────────────────────────────────────────────────────
    sep_y = H - 22
    p.hline(0, sep_y, W, p.GRAY)

    # Red stop-button block on the right
    p.fill_rect(W - 100, sep_y + 1, 100, H - sep_y - 1, p.rgb(40, 0, 0))
    p.rect(W - 98, sep_y + 2, 96, H - sep_y - 3, p.RED)
    p.draw_text(W - 94, sep_y + 7, '[ B ] STOP', p.RED, 1)

    # Status text on the left
    p.draw_text(4, sep_y + 7, 'PENTEST CONSOLE  ONLINE', p.rgb(0, 200, 0), 1)

    p.flip()


# ── Main ──────────────────────────────────────────────────────────────────
_running = True


def main():
    global _running

    def _sig_handler(sig, frame):
        global _running
        _running = False

    signal.signal(signal.SIGTERM, _sig_handler)
    signal.signal(signal.SIGINT,  _sig_handler)

    # Stop pineapplepager so we can own the screen
    subprocess.run(
        ['/etc/init.d/pineapplepager', 'stop'],
        capture_output=True, timeout=5,
    )
    time.sleep(0.5)

    try:
        with Pager() as p:
            p.set_rotation(270)
            p.clear_input_events()   # drain any stale button events

            # Pre-load sprite frames (load_image returns None on failure)
            frame_handles = _load_frames(p)
            frames_ok = any(h is not None for h in frame_handles)
            if not frames_ok:
                print('Warning: sprite frames not loaded, using ASCII fallback',
                      file=sys.stderr)

            xp, level, title, xp_next = load_xp()
            anim_frame     = 0
            last_xp_check  = time.time()

            draw_screen(p, xp, level, title, xp_next, frame_handles, anim_frame)

            try:
                while _running:
                    # Poll for B button press
                    event = p.get_input_event()
                    if event:
                        button, etype, _ = event
                        if button == Pager.BTN_B and etype == Pager.EVENT_PRESS:
                            break

                    # Refresh XP every 5 seconds
                    now = time.time()
                    if now - last_xp_check >= 5:
                        xp, level, title, xp_next = load_xp()
                        last_xp_check = now

                    # Advance animation frame at ~5fps
                    anim_frame = (anim_frame + 1) % _N_FRAMES
                    draw_screen(p, xp, level, title, xp_next, frame_handles, anim_frame)
                    p.delay(200)
            finally:
                # Free pre-loaded images while pager is still initialised
                _free_frames(p, frame_handles)
                # p.cleanup() called automatically by 'with' block __exit__

    finally:
        # Always restart pineapplepager whether we exited cleanly or not
        subprocess.run(
            ['/etc/init.d/pineapplepager', 'start'],
            capture_output=True, timeout=5,
        )


if __name__ == '__main__':
    main()
