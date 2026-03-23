#!/usr/bin/env python3
"""
Neon Bikes - Light cycle arena game for the Hak5 WiFi Pineapple Pager
Display: 480x222 RGB565 via libpagerctl.so
Author: wickedNull
Controls:
  D-pad      - steer your bike
  A (GREEN)  - start / restart / confirm
  B (RED)    - pause menu (in-game) / quit (menus)
"""

import sys
import os
import random
import traceback

# -- lib path ------------------------------------------------------------------
SEARCH_DIRS = []
if len(sys.argv) >= 2:
    SEARCH_DIRS.append(sys.argv[1])
SEARCH_DIRS += [
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"),
    "/root/payloads/user/utilities/PAGERCTL",
    "/mmc/root/payloads/user/utilities/PAGERCTL",
]

LIB_DIR = None
for d in SEARCH_DIRS:
    if (os.path.isfile(os.path.join(d, "pagerctl.py")) and
            os.path.isfile(os.path.join(d, "libpagerctl.so"))):
        LIB_DIR = d
        break

if LIB_DIR is None:
    print("ERROR: pagerctl.py / libpagerctl.so not found")
    print("Searched:", SEARCH_DIRS)
    sys.exit(1)

os.environ["LD_LIBRARY_PATH"] = (
    LIB_DIR + ":/mmc/usr/lib:/mmc/lib:" +
    os.environ.get("LD_LIBRARY_PATH", "")
)
sys.path.insert(0, LIB_DIR)

try:
    from pagerctl import Pager
except ImportError as e:
    print("ERROR: Failed to import pagerctl: %s" % e)
    traceback.print_exc()
    sys.exit(1)

# -- Display constants ---------------------------------------------------------
SCREEN_W = 480
SCREEN_H = 222
CELL     = 4        # px per grid cell -> 120 x 55 grid

GRID_W = SCREEN_W // CELL   # 120
GRID_H = SCREEN_H // CELL   #  55

UP    = ( 0, -1)
DOWN  = ( 0,  1)
LEFT  = (-1,  0)
RIGHT = ( 1,  0)
OPPOSITE = {UP: DOWN, DOWN: UP, LEFT: RIGHT, RIGHT: LEFT}

SCOREBAR_H = 10
PLAY_Y0    = (SCOREBAR_H // CELL) + 1
PLAY_Y1    = GRID_H - 1
PLAY_X0    = 1
PLAY_X1    = GRID_W - 1

FRAME_MS = 50   # ms per game tick -- lower = faster

# -- Colours -------------------------------------------------------------------
def rgb(r, g, b):
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)

C_BG       = rgb(  0,   0,  10)
C_WALL     = rgb( 30,  30,  30)
C_SCORE_BG = rgb( 10,  10,  10)
C_P1_HEAD  = rgb(  0, 255, 255)
C_P1_TRAIL = rgb(  0,  90, 130)
C_P2_HEAD  = rgb(255,  80,   0)
C_P2_TRAIL = rgb(120,  40,   0)
C_WHITE    = rgb(255, 255, 255)
C_GREEN    = rgb(  0, 255,  80)
C_RED      = rgb(255,  50,  50)
C_YELLOW   = rgb(255, 220,   0)
C_TITLE    = rgb(  0, 210, 255)
C_SUBTITLE = rgb(  0, 160, 200)
C_DIM      = rgb(160, 160, 160)
C_MENU_BG  = rgb( 10,  10,  20)
C_MENU_SEL = rgb(  0, 140, 180)


# -- AI ------------------------------------------------------------------------
def _open_neighbors(grid, x, y):
    count = 0
    for dx, dy in (UP, DOWN, LEFT, RIGHT):
        nx, ny = x + dx, y + dy
        if (PLAY_X0 <= nx < PLAY_X1 and PLAY_Y0 <= ny < PLAY_Y1
                and grid[ny][nx] == 0):
            count += 1
    return count

def ai_dir(grid, ax, ay, cur_dir):
    best_score = -1
    best_dirs  = []
    for d in (UP, DOWN, LEFT, RIGHT):
        if d == OPPOSITE[cur_dir]:
            continue
        nx, ny = ax + d[0], ay + d[1]
        if not (PLAY_X0 <= nx < PLAY_X1 and PLAY_Y0 <= ny < PLAY_Y1
                and grid[ny][nx] == 0):
            continue
        score = _open_neighbors(grid, nx, ny)
        for d2 in (UP, DOWN, LEFT, RIGHT):
            nx2, ny2 = nx + d2[0], ny + d2[1]
            if (PLAY_X0 <= nx2 < PLAY_X1 and PLAY_Y0 <= ny2 < PLAY_Y1
                    and grid[ny2][nx2] == 0):
                score += _open_neighbors(grid, nx2, ny2)
        if score > best_score:
            best_score = score
            best_dirs  = [d]
        elif score == best_score:
            best_dirs.append(d)
    if best_dirs:
        return random.choice(best_dirs)
    return cur_dir


# -- Game state ----------------------------------------------------------------
class Game:
    def __init__(self):
        self.p1_score = 0
        self.p2_score = 0
        self.reset()

    def reset(self):
        self.grid = [[0] * GRID_W for _ in range(GRID_H)]
        mid_y = (PLAY_Y0 + PLAY_Y1) // 2
        q1x   = PLAY_X0 + (PLAY_X1 - PLAY_X0) // 4
        q3x   = PLAY_X1 - (PLAY_X1 - PLAY_X0) // 4
        self.p1x, self.p1y, self.p1d = q1x, mid_y, RIGHT
        self.p2x, self.p2y, self.p2d = q3x, mid_y, LEFT
        self.p1_alive = True
        self.p2_alive = True
        self.grid[self.p1y][self.p1x] = 1
        self.grid[self.p2y][self.p2x] = 2
        self.over   = False
        self.result = None

    def step(self):
        if self.over:
            return
        if self.p1_alive:
            nx = self.p1x + self.p1d[0]
            ny = self.p1y + self.p1d[1]
            if (nx < PLAY_X0 or nx >= PLAY_X1 or
                    ny < PLAY_Y0 or ny >= PLAY_Y1 or
                    self.grid[ny][nx] != 0):
                self.p1_alive = False
            else:
                self.p1x, self.p1y = nx, ny
                self.grid[ny][nx] = 1
        if self.p2_alive:
            self.p2d = ai_dir(self.grid, self.p2x, self.p2y, self.p2d)
            nx = self.p2x + self.p2d[0]
            ny = self.p2y + self.p2d[1]
            if (nx < PLAY_X0 or nx >= PLAY_X1 or
                    ny < PLAY_Y0 or ny >= PLAY_Y1 or
                    self.grid[ny][nx] != 0):
                self.p2_alive = False
            else:
                self.p2x, self.p2y = nx, ny
                self.grid[ny][nx] = 2
        if not self.p1_alive and not self.p2_alive:
            self.over = True
            self.result = 'draw'
        elif not self.p1_alive:
            self.over = True
            self.result = 'p2'
            self.p2_score += 1
        elif not self.p2_alive:
            self.over = True
            self.result = 'p1'
            self.p1_score += 1


# -- Renderer ------------------------------------------------------------------
class Renderer:
    def __init__(self, p):
        self.p = p

    def _cell(self, gx, gy, color):
        # clamp pixel coords so the C library never receives negative values
        px = max(0, min(SCREEN_W - CELL, gx * CELL))
        py = max(0, min(SCREEN_H - CELL, gy * CELL))
        self.p.fill_rect(px, py, CELL, CELL, color)

    def _head(self, gx, gy, color):
        px = max(0, min(SCREEN_W - CELL - 2, gx * CELL - 1))
        py = max(0, min(SCREEN_H - CELL - 2, gy * CELL - 1))
        self.p.fill_rect(px, py, CELL + 2, CELL + 2, color)

    def walls(self):
        for x in range(GRID_W):
            self._cell(x, PLAY_Y0 - 1, C_WALL)
            self._cell(x, PLAY_Y1,     C_WALL)
        for y in range(PLAY_Y0, PLAY_Y1):
            self._cell(PLAY_X0 - 1, y, C_WALL)
            self._cell(PLAY_X1,     y, C_WALL)

    def scorebar(self, g):
        p = self.p
        p.fill_rect(0, 0, SCREEN_W, SCOREBAR_H, C_SCORE_BG)
        p.draw_text(4, 1, "YOU %d" % g.p1_score, C_P1_HEAD, 1)
        p.draw_text_centered(1, "NEON BIKES", C_TITLE, 1)
        lbl = "CPU %d" % g.p2_score
        p.draw_text(SCREEN_W - p.text_width(lbl, 1) - 4, 1, lbl, C_P2_HEAD, 1)

    def heads(self, g):
        if g.p1_alive:
            self._head(g.p1x, g.p1y, C_P1_HEAD)
        if g.p2_alive:
            self._head(g.p2x, g.p2y, C_P2_HEAD)

    def full_draw(self, g):
        self.p.clear(C_BG)
        self.walls()
        for gy in range(PLAY_Y0, PLAY_Y1):
            for gx in range(PLAY_X0, PLAY_X1):
                v = g.grid[gy][gx]
                if v == 1:
                    self._cell(gx, gy, C_P1_TRAIL)
                elif v == 2:
                    self._cell(gx, gy, C_P2_TRAIL)
        self.heads(g)
        self.scorebar(g)

    def delta_draw(self, g, op1, op2):
        if op1 is not None and g.p1_alive:
            self._cell(op1[0], op1[1], C_P1_TRAIL)
        if op2 is not None and g.p2_alive:
            self._cell(op2[0], op2[1], C_P2_TRAIL)
        self.heads(g)
        self.scorebar(g)

    def game_over_overlay(self, g):
        if g.result == 'p1':
            msg, col = "YOU WIN!", C_GREEN
        elif g.result == 'p2':
            msg, col = "CPU WINS", C_RED
        else:
            msg, col = "  DRAW  ", C_YELLOW
        bx = SCREEN_W // 2 - 80
        by = SCREEN_H // 2 - 22
        w, h = 160, 46
        # fill background
        self.p.fill_rect(bx, by, w, h, rgb(8, 8, 20))
        # draw border with 1px fill_rect strips (draw_rect doesn't exist)
        self.p.fill_rect(bx,         by,         w, 1, col)  # top
        self.p.fill_rect(bx,         by + h - 1, w, 1, col)  # bottom
        self.p.fill_rect(bx,         by,         1, h, col)  # left
        self.p.fill_rect(bx + w - 1, by,         1, h, col)  # right
        self.p.draw_text_centered(by + 6,  msg,                col,    2)
        self.p.draw_text_centered(by + 28, "A=Restart  B=Menu", C_DIM, 1)

    def title_screen(self, p1s, p2s):
        p = self.p
        p.clear(C_BG)
        p.draw_text_centered(10,  "NEON BIKES",        C_TITLE,    4)
        p.draw_text_centered(52,  "LIGHT CYCLE ARENA", C_SUBTITLE, 2)
        p.draw_text_centered(78,  "by wickedNull",     C_SUBTITLE, 1)
        p.draw_text_centered(96,  "YOU  vs  CPU",      C_WHITE,    1)
        p.draw_text_centered(110, "D-PAD = STEER",     C_DIM,      1)
        p.draw_text_centered(122, "A=START   B=QUIT",  C_DIM,      1)
        if p1s or p2s:
            p.draw_text_centered(142,
                "SCORE   YOU %d : %d CPU" % (p1s, p2s), C_WHITE, 1)
        p.draw_text_centered(160, "PRESS A TO PLAY",   C_GREEN,    1)

    def pause_menu(self, sel):
        # sel: 0=Resume, 1=Exit
        items  = ["RESUME", "EXIT GAME"]
        colors = [C_GREEN, C_RED]
        bx = SCREEN_W // 2 - 90
        by = SCREEN_H // 2 - 36
        w, h = 180, 74
        self.p.fill_rect(bx, by, w, h, C_MENU_BG)
        # border
        self.p.fill_rect(bx,         by,         w, 1, C_SUBTITLE)
        self.p.fill_rect(bx,         by + h - 1, w, 1, C_SUBTITLE)
        self.p.fill_rect(bx,         by,         1, h, C_SUBTITLE)
        self.p.fill_rect(bx + w - 1, by,         1, h, C_SUBTITLE)
        self.p.draw_text_centered(by + 6, "- PAUSED -", C_TITLE, 2)
        for i in range(len(items)):
            row_y = by + 34 + i * 20
            if i == sel:
                self.p.fill_rect(bx + 4, row_y - 2, 172, 18, C_MENU_SEL)
            c = C_WHITE if i == sel else colors[i]
            self.p.draw_text_centered(row_y, items[i], c, 1)


# -- Pause menu handler --------------------------------------------------------
def show_pause_menu(p, r, BTN_UP, BTN_DOWN, BTN_A, BTN_B):
    """Returns True if user chose Exit, False if Resume."""
    sel = 0
    try:
        r.pause_menu(sel)
        p.flip()
    except Exception as e:
        print("pause draw error: %s" % e)
        return False

    while True:
        try:
            _, pressed, _ = p.poll_input()
        except Exception:
            pressed = 0

        changed = False
        if pressed & BTN_UP:
            sel = (sel - 1) % 2
            changed = True
        if pressed & BTN_DOWN:
            sel = (sel + 1) % 2
            changed = True

        if changed:
            try:
                r.pause_menu(sel)
                p.flip()
            except Exception:
                pass

        if pressed & BTN_A:
            return sel == 1   # True=Exit, False=Resume

        if pressed & BTN_B:
            return False      # B = resume

        p.delay(80)


# -- Main ----------------------------------------------------------------------
def run():
    with Pager() as p:
        p.set_rotation(270)

        # BTN constants are on the CLASS, not the instance
        BTN_UP    = Pager.BTN_UP
        BTN_DOWN  = Pager.BTN_DOWN
        BTN_LEFT  = Pager.BTN_LEFT
        BTN_RIGHT = Pager.BTN_RIGHT
        BTN_A     = Pager.BTN_A
        BTN_B     = Pager.BTN_B

        r = Renderer(p)
        g = Game()

        # ---- TITLE LOOP ------------------------------------------------------
        while True:
            # Draw title (wrap every draw call so a crash here doesn't exit)
            try:
                r.title_screen(g.p1_score, g.p2_score)
                p.flip()
            except Exception as e:
                print("title draw error: %s" % e)

            # Wait for A or B on title
            while True:
                try:
                    _, pressed, _ = p.poll_input()
                except Exception:
                    pressed = 0
                if pressed & BTN_B:
                    return          # B on title = exit payload cleanly
                if pressed & BTN_A:
                    break
                p.delay(30)

            # ---- ROUND LOOP --------------------------------------------------
            try:
                g.reset()
                r.full_draw(g)
                p.flip()
            except Exception as e:
                print("round start draw error: %s" % e)
                continue    # back to title

            to_title = False

            while not g.over:
                p.delay(FRAME_MS)

                try:
                    _, pressed, _ = p.poll_input()
                except Exception:
                    pressed = 0

                # Steer
                if (pressed & BTN_UP)    and g.p1d != DOWN:  g.p1d = UP
                if (pressed & BTN_DOWN)  and g.p1d != UP:    g.p1d = DOWN
                if (pressed & BTN_LEFT)  and g.p1d != RIGHT: g.p1d = LEFT
                if (pressed & BTN_RIGHT) and g.p1d != LEFT:  g.p1d = RIGHT

                # B = pause
                if pressed & BTN_B:
                    to_title = show_pause_menu(p, r, BTN_UP, BTN_DOWN,
                                               BTN_A, BTN_B)
                    if to_title:
                        break
                    # Resuming - redraw board
                    try:
                        r.full_draw(g)
                        p.flip()
                    except Exception as e:
                        print("resume draw error: %s" % e)
                    continue

                # Advance game state
                op1 = (g.p1x, g.p1y) if g.p1_alive else None
                op2 = (g.p2x, g.p2y) if g.p2_alive else None

                try:
                    g.step()
                except Exception as e:
                    print("g.step() error: %s" % e)
                    traceback.print_exc()
                    break

                # Only render if the round is still live
                if not g.over:
                    try:
                        r.delta_draw(g, op1, op2)
                        p.flip()
                    except Exception as e:
                        print("delta_draw error: %s" % e)

            if to_title:
                continue    # back to title loop

            # ---- GAME OVER ---------------------------------------------------
            try:
                r.game_over_overlay(g)
                p.flip()
            except Exception as e:
                print("game over draw error: %s" % e)

            # Wait for A (restart) or B (back to title)
            # NOTE: no p.beep() / p.vibrate() here - those crash if the audio
            # service was stopped by payload.sh service management
            while True:
                try:
                    _, pressed, _ = p.poll_input()
                except Exception:
                    pressed = 0
                if pressed & BTN_A:
                    break           # restart round
                if pressed & BTN_B:
                    to_title = True
                    break
                p.delay(30)

            if to_title:
                continue    # back to title loop
            # else A pressed -> fall through -> new round starts


# -- Entry ---------------------------------------------------------------------
if __name__ == "__main__":
    try:
        run()
    except Exception as e:
        tb = traceback.format_exc()
        print("FATAL CRASH: %s" % e)
        print(tb)
        try:
            with open("/tmp/neon_bikes_crash.log", "w") as f:
                f.write(tb)
        except Exception:
            pass
        sys.exit(1)
