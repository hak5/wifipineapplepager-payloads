/*
 * Loot Browser - walk /root/loot on the Pager screen, read the text files, and show an info card for
 * anything that can't be shown on the device (pcap, handshakes, images...), with where to grab it.
 *
 * Read-only: it opens files only to read them, and never writes, moves or deletes anything. Browsing
 * is locked to /root/loot (you can't go above it).
 *
 * Controls (normal landscape grip):
 *   BROWSE  Up/Down select   Green/Right open (folder or file)   Left up a folder   Red exit
 *   VIEW    Up/Down line      Left/Right page   Green page down   Red back to the list
 *   INFO    Green/Red back to the list
 *   Power is left to the Pager (display sleep).
 *
 * Freestanding (no libc, raw MIPS o32 syscalls, integer-only - the MT7628 has no FPU). The directory
 * listing uses getdents64 (4219) and file sizes use lseek SEEK_END, both verified on the device. Draws
 * upright 480x222, rotated into the 222x480 framebuffer. The pixel font is uppercase-only, so file
 * names and text are shown in capitals. -DHOST_PREVIEW builds a desktop version over a local folder.
 */
#include <stdint.h>
#include "font5x7.h"

#define W 480
#define H 222
#define FB_W 222
#define NPIX (W * H)
#define FRAME_BYTES (NPIX * 2)

#define ROOT "/root/loot"
#define MAXENT 400
#define NAMEMAX 63
#define PATHMAX 1024
#define FBUF (128 * 1024)
#define MAXLINES 4000
#define WRAP 78

static uint16_t fb[NPIX];

/* ------------------------------------------------------------------ drawing */
static inline uint16_t rgb(int r, int g, int b) {
    if (r < 0) r = 0; if (r > 255) r = 255; if (g < 0) g = 0; if (g > 255) g = 255; if (b < 0) b = 0; if (b > 255) b = 255;
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
static inline void px(int x, int y, uint16_t c) { if ((unsigned)x < W && (unsigned)y < H) fb[x * FB_W + (H - 1 - y)] = c; }
static void fill(int x, int y, int w, int h, uint16_t c) { for (int i = 0; i < w; i++) for (int j = 0; j < h; j++) px(x + i, y + j, c); }
static void frame_rect(int x, int y, int w, int h, uint16_t c) { fill(x, y, w, 1, c); fill(x, y + h - 1, w, 1, c); fill(x, y, 1, h, c); fill(x + w - 1, y, 1, h, c); }
/* draw at most `maxc` characters of s; returns chars drawn */
static int draw_textn(int x, int y, const char *s, int maxc, uint16_t c, int sc) {
    int n = 0;
    for (; *s && n < maxc; s++, n++) { char ch = *s; if (ch >= 'a' && ch <= 'z') ch -= 32;
        if (ch >= FONT_FIRST && ch < FONT_FIRST + FONT_COUNT) { const unsigned char *g = FONT5X7[ch - FONT_FIRST];
            for (int row = 0; row < 7; row++) { unsigned bits = g[row];
                for (int col = 0; col < 5; col++) if (bits & (1u << (4 - col))) fill(x + col * sc, y + row * sc, sc, sc, c); } }
        x += 6 * sc; }
    return n;
}
static void draw_text(int x, int y, const char *s, uint16_t c, int sc) { draw_textn(x, y, s, 100000, c, sc); }
static int slen_(const char *s) { int n = 0; while (s[n]) n++; return n; }
static int text_w(const char *s, int sc) { int n = slen_(s); return n ? n * 6 * sc - sc : 0; }
static void text_at_c(int cx, int y, const char *s, uint16_t c, int sc) { draw_text(cx - text_w(s, sc) / 2, y, s, c, sc); }

/* tiny string builder */
static char sb[128]; static int sbn;
static void sb_reset(void) { sbn = 0; sb[0] = 0; }
static void sb_c(char c) { if (sbn < 126) { sb[sbn++] = c; sb[sbn] = 0; } }
static void sb_s(const char *s) { while (*s && sbn < 126) sb[sbn++] = *s++; sb[sbn] = 0; }
static void sb_i(long v) { char t[16]; int j = 0, i = 0; if (v < 0) { sb_c('-'); v = -v; } if (!v) t[j++] = '0'; while (v) { t[j++] = (char)('0' + v % 10); v /= 10; } char o[16]; while (j) o[i++] = t[--j]; o[i] = 0; sb_s(o); }
static void human(long n) { if (n < 1024) { sb_i(n); sb_c('B'); } else if (n < 1024 * 1024) { sb_i(n / 1024); sb_c('K'); } else { sb_i(n / (1024 * 1024)); sb_c('M'); } }

/* ------------------------------------------------------------------ platform I/O (device vs host) */
typedef struct { char name[NAMEMAX + 1]; int is_dir; long size; } Entry;
static Entry ent[MAXENT];
static int nent;
static int list_dir(const char *path);              /* fills ent[]/nent, sorted; -1 on error */
static long read_file(const char *path, char *buf, long max);   /* bytes read, or -1 */

static int ci(char a) { return a >= 'a' && a <= 'z' ? a - 32 : a; }
static int name_cmp(const char *a, const char *b) { for (; *a || *b; a++, b++) { int d = ci(*a) - ci(*b); if (d) return d; } return 0; }
static void sort_entries(void) {                     /* dirs first, then files; each alphabetical */
    for (int i = 1; i < nent; i++) { Entry t = ent[i]; int j = i - 1;
        while (j >= 0 && ((ent[j].is_dir < t.is_dir) || (ent[j].is_dir == t.is_dir && name_cmp(ent[j].name, t.name) > 0))) { ent[j + 1] = ent[j]; j--; }
        ent[j + 1] = t; }
}

/* ------------------------------------------------------------------ paths */
static char path[PATHMAX];
static int rootlen;
static void path_down(const char *name) { int k = slen_(path); if (k < PATHMAX - 2) { path[k++] = '/'; } int j = 0; while (name[j] && k < PATHMAX - 1) path[k++] = name[j++]; path[k] = 0; }
static void path_up(void) { int k = slen_(path); while (k > rootlen && path[k - 1] != '/') k--; if (k > rootlen) k--; if (k < rootlen) k = rootlen; path[k] = 0; }
static int at_root(void) { return slen_(path) <= rootlen; }
static const char *leaf(const char *p) { const char *last = p; for (const char *s = p; *s; s++) if (*s == '/') last = s + 1; return last; }

/* ------------------------------------------------------------------ file kind */
static int ext_is_binary(const char *name) {
    static const char *BIN[] = {"pcap", "cap", "pcapng", "gz", "zip", "tar", "7z", "jpg", "jpeg", "png", "gif", "bmp",
        "bin", "pdf", "db", "sqlite", "hccapx", "22000", "pmkid", "ico", "mp3", "wav", "o", "so", 0};
    const char *dot = 0; for (const char *s = name; *s; s++) if (*s == '.') dot = s + 1;
    if (!dot) return 0;
    for (int i = 0; BIN[i]; i++) { const char *a = dot, *b = BIN[i]; while (*a && *b && ci(*a) == ci(*b)) { a++; b++; } if (!*a && !*b) return 1; }
    return 0;
}
/* 0 text, 1 binary (NUL byte or too many non-printing in the first chunk) */
static int looks_binary(const char *buf, long n) {
    long cap = n < 2048 ? n : 2048, bad = 0;
    for (long i = 0; i < cap; i++) { unsigned char c = buf[i];
        if (c == 0) return 1;
        if (c < 9 || (c > 13 && c < 32) || c > 126) bad++; }
    return cap > 0 && bad * 100 / cap > 8;
}

/* ------------------------------------------------------------------ text viewer model */
static char fbuf[FBUF + 1];
static long fsize; static int ftrunc;
static int line_off[MAXLINES], line_len[MAXLINES], nlines;
static void build_lines(long n) {
    nlines = 0; long i = 0;
    while (i < n && nlines < MAXLINES) {
        long start = i, col = 0, lastsp = -1;
        while (i < n && fbuf[i] != '\n') {
            if (fbuf[i] == '\t') { /* expand tabs to the next multiple of 4 */ col = (col + 4) & ~3L; }
            else col++;
            if (fbuf[i] == ' ') lastsp = i;
            if (col >= WRAP) break;
            i++;
        }
        if (i < n && fbuf[i] != '\n' && col >= WRAP && lastsp > start) { i = lastsp + 1; line_off[nlines] = start; line_len[nlines] = lastsp - start; }
        else { line_off[nlines] = start; line_len[nlines] = i - start; }
        nlines++;
        if (i < n && fbuf[i] == '\n') i++;
        else if (i < n && line_len[nlines - 1] == 0 && col < WRAP) i++;   /* safety */
    }
    if (nlines == 0) { line_off[0] = 0; line_len[0] = 0; nlines = 1; }
}

/* ------------------------------------------------------------------ state */
enum { S_BROWSE, S_VIEW, S_INFO };
enum { A_UP, A_DOWN, A_LEFT, A_RIGHT, A_GREEN, A_RED, NACT };
static unsigned char press[NACT];
static int state, quit_req, tick;
static int sel, top;                 /* browse selection + scroll */
static int vtop;                     /* viewer top line */
static char open_name[NAMEMAX + 1];  /* file being viewed / info'd */
static long open_size;

/* layout; init_skin() adjusts these for the Finder skins */
static int ROWS_BROWSE = 11, ROWH = 16, LIST_Y = 36, LIST_X = 0, VIEW_ROWS = 19, VIEW_Y = 34, VIEW_LH = 9;

static void enter_dir(void) { list_dir(path); sel = 0; top = 0; }

static void open_selected(void) {
    int has_up = !at_root();
    if (has_up && sel == 0) { path_up(); enter_dir(); return; }
    int ei = sel - (has_up ? 1 : 0);
    if (ei < 0 || ei >= nent) return;
    Entry *e = &ent[ei];
    if (e->is_dir) { path_down(e->name); enter_dir(); return; }
    /* a file */
    int k = 0; while (e->name[k] && k < NAMEMAX) { open_name[k] = e->name[k]; k++; } open_name[k] = 0;
    open_size = e->size;
    char full[PATHMAX]; int p = 0; while (path[p]) { full[p] = path[p]; p++; } full[p++] = '/'; int j = 0; while (e->name[j]) full[p++] = e->name[j++]; full[p] = 0;
    if (ext_is_binary(e->name)) { state = S_INFO; return; }
    fsize = read_file(full, fbuf, FBUF); ftrunc = 0;
    if (fsize < 0) { state = S_INFO; return; }
    if (fsize >= FBUF) { fsize = FBUF; ftrunc = 1; }
    if (looks_binary(fbuf, fsize)) { state = S_INFO; return; }
    build_lines(fsize); vtop = 0; state = S_VIEW;
}

static void game_tick(void) {
    tick++;
    if (state == S_BROWSE) {
        int has_up = !at_root();
        int total = nent + (has_up ? 1 : 0);
        if (total < 1) total = 1;
        if (press[A_UP] && sel > 0) sel--;
        if (press[A_DOWN] && sel < total - 1) sel++;
        if (sel < top) top = sel;
        if (sel >= top + ROWS_BROWSE) top = sel - ROWS_BROWSE + 1;
        if (press[A_LEFT] && has_up) { path_up(); enter_dir(); }
        if (press[A_GREEN] || press[A_RIGHT]) open_selected();
        if (press[A_RED]) { if (has_up) { path_up(); enter_dir(); } else quit_req = 1; }
    } else if (state == S_VIEW) {
        if (press[A_UP] && vtop > 0) vtop--;
        if (press[A_DOWN] && vtop < nlines - 1) vtop++;
        if ((press[A_RIGHT] || press[A_GREEN])) { vtop += VIEW_ROWS - 1; if (vtop > nlines - 1) vtop = nlines - 1; if (vtop < 0) vtop = 0; }
        if (press[A_LEFT]) { vtop -= VIEW_ROWS - 1; if (vtop < 0) vtop = 0; }
        if (press[A_RED]) state = S_BROWSE;
    } else {  /* S_INFO */
        if (press[A_RED] || press[A_GREEN] || press[A_LEFT]) state = S_BROWSE;
    }
}

/* ------------------------------------------------------------------ rendering */
/* ---- skins: 0 default (tech), 1 Dockside (Finder light), 2 Dockside Dark (Finder dark) ---- */
typedef struct {
    int finder;
    uint16_t bg, bar, tb1, tb2, title, sidebar, line, line2, header, stripe, pathbar,
             text, dim, accent, selbar, seltext, diricon, fileicon, warn, lred, lyel, lgrn;
} Skin;
static Skin sk;
static int theme_id;
static void init_skin(int id) {
    theme_id = id;
    if (id == 1) {                                   /* Dockside - Finder light */
        sk.finder = 1;
        sk.bg = rgb(255, 255, 255); sk.tb1 = rgb(246, 246, 247); sk.tb2 = rgb(229, 229, 232); sk.title = rgb(29, 29, 31);
        sk.sidebar = rgb(236, 236, 240); sk.line = rgb(209, 209, 214); sk.line2 = rgb(199, 199, 204);
        sk.header = rgb(250, 250, 250); sk.stripe = rgb(244, 245, 248); sk.pathbar = rgb(246, 246, 247);
        sk.text = rgb(29, 29, 31); sk.dim = rgb(110, 110, 115); sk.accent = rgb(10, 100, 216);
        sk.selbar = rgb(10, 100, 216); sk.seltext = rgb(255, 255, 255); sk.diricon = rgb(10, 100, 216);
        sk.fileicon = rgb(142, 142, 147); sk.warn = rgb(215, 0, 21); sk.bar = rgb(246, 246, 247);
        sk.lred = rgb(255, 95, 87); sk.lyel = rgb(254, 188, 46); sk.lgrn = rgb(40, 200, 64);
    } else if (id == 2) {                            /* Dockside Dark - Finder dark */
        sk.finder = 1;
        sk.bg = rgb(30, 30, 30); sk.tb1 = rgb(56, 56, 58); sk.tb2 = rgb(44, 44, 46); sk.title = rgb(245, 245, 247);
        sk.sidebar = rgb(38, 38, 40); sk.line = rgb(58, 58, 60); sk.line2 = rgb(72, 72, 74);
        sk.header = rgb(34, 34, 36); sk.stripe = rgb(36, 36, 38); sk.pathbar = rgb(38, 38, 40);
        sk.text = rgb(245, 245, 247); sk.dim = rgb(152, 152, 157); sk.accent = rgb(10, 132, 255);
        sk.selbar = rgb(10, 132, 255); sk.seltext = rgb(255, 255, 255); sk.diricon = rgb(10, 132, 255);
        sk.fileicon = rgb(152, 152, 157); sk.warn = rgb(255, 120, 90); sk.bar = rgb(44, 44, 46);
        sk.lred = rgb(255, 95, 87); sk.lyel = rgb(254, 188, 46); sk.lgrn = rgb(40, 200, 64);
    } else {                                         /* default tech look */
        sk.finder = 0;
        sk.bg = rgb(10, 12, 20); sk.bar = rgb(22, 26, 44); sk.tb1 = sk.tb2 = rgb(22, 26, 44); sk.title = rgb(120, 180, 255);
        sk.sidebar = rgb(22, 26, 44); sk.line = rgb(60, 70, 110); sk.line2 = rgb(60, 70, 110);
        sk.header = rgb(22, 26, 44); sk.stripe = rgb(16, 20, 34); sk.pathbar = rgb(22, 26, 44);
        sk.text = rgb(220, 228, 240); sk.dim = rgb(110, 120, 150); sk.accent = rgb(255, 196, 70);
        sk.selbar = rgb(40, 90, 170); sk.seltext = rgb(255, 255, 255); sk.diricon = rgb(120, 200, 255);
        sk.fileicon = rgb(210, 220, 235); sk.warn = rgb(255, 150, 90);
    }
    if (sk.finder) { LIST_X = 111; LIST_Y = 48; ROWH = 18; ROWS_BROWSE = 8; VIEW_Y = 32; VIEW_LH = 9; VIEW_ROWS = 18; }
    else           { LIST_X = 0;   LIST_Y = 36; ROWH = 16; ROWS_BROWSE = 11; VIEW_Y = 34; VIEW_LH = 9; VIEW_ROWS = 19; }
}

static void background(void) { for (int i = 0; i < NPIX; i++) fb[i] = sk.bg; }
static void folder_icon(int x, int y, uint16_t c) { fill(x, y + 2, 11, 7, c); fill(x, y + 1, 5, 2, c); fill(x + 1, y + 3, 9, 4, sk.finder ? sk.bg : rgb(30, 50, 90)); }
static void file_icon(int x, int y, uint16_t c) { fill(x + 1, y, 8, 10, c); fill(x + 6, y, 3, 3, sk.bg); for (int r = 0; r < 3; r++) fill(x + 2, y + 3 + r * 2, 6, 1, sk.bg); }
static void disc(int cx, int cy, int r, uint16_t c) { for (int dy = -r; dy <= r; dy++) for (int dx = -r; dx <= r; dx++) if (dx * dx + dy * dy <= r * r) px(cx + dx, cy + dy, c); }
static void grad_v(int x, int y, int w, int h, uint16_t c0, uint16_t c1) {
    int r0 = (c0 >> 11) & 31, g0 = (c0 >> 5) & 63, b0 = c0 & 31, r1 = (c1 >> 11) & 31, g1 = (c1 >> 5) & 63, b1 = c1 & 31;
    for (int j = 0; j < h; j++) { int r = r0 + (r1 - r0) * j / h, g = g0 + (g1 - g0) * j / h, b = b0 + (b1 - b0) * j / h; fill(x, y + j, w, 1, (uint16_t)((r << 11) | (g << 5) | b)); }
}
static void disk_glyph(int x, int y) { fill(x, y + 2, 15, 9, sk.line); fill(x + 1, y + 3, 13, 7, rgb(190, 190, 195)); disc(x + 11, y + 6, 1, rgb(48, 209, 88)); }
/* breadcrumbs: "PAGER HD > loot > ..." from the live path (strips the /root/ prefix) */
static void crumbs(void) {
    sb_reset(); sb_s("PAGER HD"); const char *q = path;
    if (q[0] == '/' && q[1] == 'r' && q[2] == 'o' && q[3] == 'o' && q[4] == 't' && q[5] == '/') q += 6;
    while (*q) { sb_s(" > "); while (*q && *q != '/') sb_c(*q++); if (*q == '/') q++; }
}
static const char *cur_folder(void) { return at_root() ? "LOOT" : leaf(path); }

/* a Dockside-style Finder title bar: gradient + traffic lights + a left-aligned title */
static void finder_titlebar(const char *title) {
    grad_v(0, 0, W, 28, sk.tb1, sk.tb2);
    fill(0, 28, W, 1, sk.line2);
    disc(14, 14, 5, sk.lred); disc(32, 14, 5, sk.lyel); disc(50, 14, 5, sk.lgrn);
    draw_textn(66, 10, title, 44, sk.title, 1);
}
static void finder_sidebar(void) {                   /* decorative, matches the theme (Loot highlighted) */
    fill(0, 28, 110, H - 28, sk.sidebar); fill(110, 28, 1, H - 28, sk.line);
    draw_text(10, 40, "FAVORITES", sk.dim, 1);
    static const char *FAV[4] = {"PAYLOADS", "RECON", "ALERTS", "LOOT"};
    for (int i = 0; i < 4; i++) { int y = 54 + i * 19;
        if (i == 3) fill(5, y - 3, 100, 17, sk.selbar);        /* Loot = where we are */
        folder_icon(12, y, i == 3 ? sk.seltext : sk.diricon); draw_text(32, y, FAV[i], i == 3 ? sk.seltext : sk.text, 1); }
    draw_text(10, 150, "LOCATIONS", sk.dim, 1);
    disk_glyph(12, 164); draw_text(32, 166, "PAGER HD", sk.text, 1);
}

static void render_browse_finder(void) {
    background();
    finder_titlebar(cur_folder());
    finder_sidebar();
    int has_up = !at_root();
    int total = nent + (has_up ? 1 : 0);
    fill(111, 29, 369, 18, sk.header); fill(111, 47, 369, 1, sk.line);
    draw_text(120, 33, "NAME", sk.dim, 1); draw_text(392, 33, "SIZE", sk.dim, 1); fill(384, 31, 1, 14, sk.line);
    for (int r = 0; r < ROWS_BROWSE; r++) {
        int idx = top + r; if (idx >= total) break;
        int y = LIST_Y + r * ROWH;
        if ((r & 1) == 0) fill(111, y - 2, 369, ROWH, sk.stripe);
        int selline = (idx == sel);
        if (selline) fill(111, y - 2, 365, ROWH, sk.selbar);
        uint16_t tc = selline ? sk.seltext : sk.text;
        if (has_up && idx == 0) { folder_icon(118, y, selline ? sk.seltext : sk.diricon); draw_text(136, y, ".. UP A FOLDER", selline ? sk.seltext : sk.dim, 1); continue; }
        Entry *e = &ent[idx - (has_up ? 1 : 0)];
        if (e->is_dir) { folder_icon(118, y, selline ? sk.seltext : sk.diricon); sb_reset(); sb_s(e->name); sb_c('/'); draw_textn(136, y, sb, 40, tc, 1);
            draw_text(392, y, "FOLDER", selline ? sk.seltext : sk.dim, 1); }
        else { file_icon(119, y, selline ? sk.seltext : sk.fileicon); draw_textn(136, y, e->name, 40, tc, 1);
            sb_reset(); human(e->size); draw_text(474 - text_w(sb, 1), y, sb, selline ? sk.seltext : sk.dim, 1); }
    }
    if (total == (has_up ? 1 : 0)) draw_text(130, 70, "EMPTY FOLDER", sk.dim, 1);
    /* path bar */
    fill(0, 194, W, 28, sk.pathbar); fill(0, 194, W, 1, sk.line2);
    disk_glyph(8, 201); crumbs(); draw_textn(28, 203, sb, 74, sk.text, 1);
    /* scrollbar */
    if (total > ROWS_BROWSE) { int trh = ROWS_BROWSE * ROWH; int th = trh * ROWS_BROWSE / total; if (th < 8) th = 8;
        int ty = LIST_Y - 2 + (trh - th) * top / (total - ROWS_BROWSE);
        fill(476, LIST_Y - 2, 2, trh, sk.line); fill(476, ty, 2, th, sk.dim); }
}

static void render_browse(void) {
    if (sk.finder) { render_browse_finder(); return; }
    background();
    fill(0, 0, W, 30, sk.bar); draw_text(8, 6, "LOOT", sk.accent, 2);
    { int maxc = 60; const char *p = path; int len = slen_(p);
      if (len > maxc) { p += len - maxc + 1; draw_text(64, 8, "...", sk.dim, 1); draw_textn(82, 8, p, maxc - 3, sk.text, 1); } else draw_text(64, 8, p, sk.text, 1); }
    fill(0, 30, W, 1, sk.line2);
    int has_up = !at_root();
    int total = nent + (has_up ? 1 : 0);
    for (int r = 0; r < ROWS_BROWSE; r++) {
        int idx = top + r; if (idx >= total) break;
        int y = LIST_Y + r * ROWH;
        if (idx == sel) fill(4, y - 2, W - 8, ROWH, sk.selbar);
        if (has_up && idx == 0) { folder_icon(10, y, sk.diricon); draw_text(28, y, "..  (UP A FOLDER)", idx == sel ? sk.text : sk.dim, 1); continue; }
        Entry *e = &ent[idx - (has_up ? 1 : 0)];
        if (e->is_dir) { folder_icon(10, y, sk.diricon); sb_reset(); sb_s(e->name); sb_c('/'); draw_textn(28, y, sb, 54, sk.diricon, 1); }
        else { file_icon(11, y, sk.fileicon); draw_textn(28, y, e->name, 48, sk.fileicon, 1);
            sb_reset(); human(e->size); draw_text(W - 12 - text_w(sb, 1), y, sb, idx == sel ? sk.text : sk.dim, 1); }
    }
    fill(0, H - 14, W, 14, sk.bar);
    if (total == (has_up ? 1 : 0)) text_at_c(240, H - 12, "EMPTY FOLDER", sk.dim, 1);
    else { sb_reset(); sb_i(sel + 1); sb_c('/'); sb_i(total); draw_text(8, H - 12, sb, sk.dim, 1); }
    draw_text(150, H - 12, "GREEN OPEN  LEFT UP", sk.dim, 1);
    draw_text(W - 8 - text_w(has_up ? "RED UP" : "RED EXIT", 1), H - 12, has_up ? "RED UP" : "RED EXIT", sk.dim, 1);
    if (total > ROWS_BROWSE) { int trh = ROWS_BROWSE * ROWH; int th = trh * ROWS_BROWSE / total; if (th < 8) th = 8;
        int ty = LIST_Y - 2 + (trh - th) * top / (total - ROWS_BROWSE);
        fill(W - 4, LIST_Y - 2, 2, trh, rgb(40, 46, 70)); fill(W - 4, ty, 2, th, sk.dim); }
}

static void render_view(void) {
    background();
    if (sk.finder) { finder_titlebar(open_name); }
    else { fill(0, 0, W, 24, sk.bar); draw_textn(8, 6, open_name, 60, sk.title, 1); fill(0, 24, W, 1, sk.line2); }
    { sb_reset(); human(open_size); if (ftrunc) sb_s(" (FIRST 128K)");
      draw_text(W - 10 - text_w(sb, 1), sk.finder ? 10 : 6, sb, sk.dim, 1); }
    static char line[WRAP + 2];
    int vx = sk.finder ? 10 : 6;
    for (int r = 0; r < VIEW_ROWS; r++) {
        int li = vtop + r; if (li >= nlines) break;
        int n = line_len[li]; if (n > WRAP) n = WRAP;
        int off = line_off[li], col = 0;
        for (int k = 0; k < n && col < WRAP; k++) { char ch = fbuf[off + k]; if (ch == '\t') { int nx = (col + 4) & ~3; while (col < nx && col < WRAP) line[col++] = ' '; } else line[col++] = ch; }
        line[col] = 0;
        draw_text(vx, VIEW_Y + r * VIEW_LH, line, sk.text, 1);
    }
    fill(0, H - 16, W, 16, sk.finder ? sk.pathbar : sk.bar); if (sk.finder) fill(0, H - 16, W, 1, sk.line2);
    sb_reset(); sb_s("LINE "); sb_i(vtop + 1); sb_c('/'); sb_i(nlines);
    if (nlines > VIEW_ROWS) { sb_s("  "); sb_i((vtop + VIEW_ROWS >= nlines ? 100 : (vtop * 100 / (nlines - 1)))); sb_c('%'); }
    draw_text(8, H - 13, sb, sk.dim, 1);
    draw_text(190, H - 13, "UP/DN LINE  L/R PAGE", sk.dim, 1);
    draw_text(W - 8 - text_w("RED BACK", 1), H - 13, "RED BACK", sk.dim, 1);
    int ytop = sk.finder ? 30 : 26;
    if (nlines > VIEW_ROWS) { int trh = H - ytop - 18; int th = trh * VIEW_ROWS / nlines; if (th < 8) th = 8;
        int ty = ytop + (trh - th) * vtop / (nlines - 1); fill(W - 4, ytop, 2, trh, sk.line); fill(W - 4, ty, 2, th, sk.dim); }
}

static const char *kind_of(const char *name) {
    const char *dot = 0; for (const char *s = name; *s; s++) if (*s == '.') dot = s + 1;
    if (!dot) return "FILE";
    struct { const char *e, *d; } K[] = {{"pcap", "PACKET CAPTURE"}, {"pcapng", "PACKET CAPTURE"}, {"cap", "PACKET CAPTURE"},
        {"hccapx", "WPA HANDSHAKE"}, {"22000", "WPA HANDSHAKE"}, {"pmkid", "WPA PMKID"},
        {"jpg", "IMAGE"}, {"jpeg", "IMAGE"}, {"png", "IMAGE"}, {"gif", "IMAGE"}, {"bmp", "IMAGE"},
        {"gz", "COMPRESSED"}, {"zip", "COMPRESSED"}, {"tar", "ARCHIVE"}, {"pdf", "PDF DOCUMENT"},
        {"db", "DATABASE"}, {"sqlite", "DATABASE"}, {"bin", "BINARY"}, {0, 0}};
    for (int i = 0; K[i].e; i++) { const char *a = dot, *b = K[i].e; while (*a && *b && ci(*a) == ci(*b)) { a++; b++; } if (!*a && !*b) return K[i].d; }
    return "BINARY FILE";
}
static void render_info(void) {
    background();
    if (sk.finder) finder_titlebar(open_name);
    else { fill(0, 0, W, 24, sk.bar); draw_textn(8, 6, open_name, 60, sk.title, 1); fill(0, 24, W, 1, sk.line2); }
    frame_rect(30, 50, W - 60, 130, sk.warn);
    text_at_c(240, 66, "CAN'T BE SHOWN HERE", sk.warn, 2);
    sb_reset(); sb_s("TYPE: "); sb_s(kind_of(open_name)); sb_s("    SIZE: "); human(open_size); text_at_c(240, 94, sb, sk.text, 1);
    text_at_c(240, 118, "THIS ISN'T A TEXT FILE, SO COPY IT OFF TO OPEN IT:", sk.dim, 1);
    sb_reset(); sb_s("SCP ROOT@172.16.52.1:"); sb_s(path); sb_c('/'); sb_s(open_name);
    { int tw = text_w(sb, 1); if (tw > W - 40) draw_textn(20, 138, sb, (W - 40) / 6, sk.accent, 1); else text_at_c(240, 138, sb, sk.accent, 1); }
    text_at_c(240, 156, "OR THE WEB UI AT HTTP://172.16.52.1", sk.dim, 1);
    fill(0, H - 14, W, 14, sk.finder ? sk.pathbar : sk.bar); text_at_c(240, H - 12, "RED / GREEN  BACK TO THE LIST", sk.dim, 1);
}
static void render(void) { if (state == S_BROWSE) render_browse(); else if (state == S_VIEW) render_view(); else render_info(); }

/* ================================================================== device */
#ifndef HOST_PREVIEW
#define SYS_read 4003
#define SYS_write 4004
#define SYS_open 4005
#define SYS_close 4006
#define SYS_lseek 4019
#define SYS_nanosleep 4166
#define SYS_getdents64 4219
#define O_RDONLY 0
#define O_NONBLOCK 0x80
#define O_RDWR 2
#define O_DIRECTORY 0x10000
static long sys3(long n, long a, long b, long c) {
    register long r2 asm("$2") = n, r4 asm("$4") = a, r5 asm("$5") = b, r6 asm("$6") = c, r7 asm("$7") = 0;
    asm volatile("syscall" : "+r"(r2), "+r"(r7) : "r"(r4), "r"(r5), "r"(r6)
                 : "$1", "$3", "$8", "$9", "$10", "$11", "$12", "$13", "$14", "$15", "$24", "$25", "memory");
    return r7 ? -r2 : r2;
}
asm(".text\n.globl _start\n.ent _start\n_start:\n jal main\n nop\n move $4,$2\n li $2,4246\n syscall\n nop\n.end _start\n");
void *memset(void *d, int c, unsigned n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, unsigned n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
struct ts { long sec, nsec; };
static void sleep_ms(long ms) { struct ts t; t.sec = ms / 1000; t.nsec = (ms % 1000) * 1000000; sys3(SYS_nanosleep, (long)&t, 0, 0); }

static unsigned char dbuf[16384];
static long file_size(const char *full) { int fd = (int)sys3(SYS_open, (long)full, O_RDONLY, 0); if (fd < 0) return 0; long s = sys3(SYS_lseek, fd, 0, 2); sys3(SYS_close, fd, 0, 0); return s < 0 ? 0 : s; }
static int list_dir(const char *p) {
    nent = 0;
    int fd = (int)sys3(SYS_open, (long)p, O_RDONLY | O_DIRECTORY, 0); if (fd < 0) return -1;
    long n;
    while ((n = sys3(SYS_getdents64, fd, (long)dbuf, sizeof dbuf)) > 0) {
        long off = 0;
        while (off < n) {
            unsigned char *d = dbuf + off; int reclen = d[16] | (d[17] << 8); int type = d[18]; char *nm = (char *)d + 19;
            if (reclen <= 0) break; off += reclen;
            if (nm[0] == '.' && (nm[1] == 0 || (nm[1] == '.' && nm[2] == 0))) continue;
            if (nent >= MAXENT) continue;
            Entry *e = &ent[nent];
            int k = 0; while (nm[k] && k < NAMEMAX) { e->name[k] = nm[k]; k++; } e->name[k] = 0;
            e->is_dir = (type == 4); e->size = 0;
            if (!e->is_dir) { char full[PATHMAX]; int q = 0; while (p[q]) { full[q] = p[q]; q++; } full[q++] = '/'; int j = 0; while (nm[j] && q < PATHMAX - 1) full[q++] = nm[j++]; full[q] = 0; e->size = file_size(full); }
            nent++;
        }
    }
    sys3(SYS_close, fd, 0, 0);
    sort_entries();
    return nent;
}
static long read_file(const char *full, char *buf, long max) {
    int fd = (int)sys3(SYS_open, (long)full, O_RDONLY, 0); if (fd < 0) return -1;
    long total = 0, r;
    while (total < max && (r = sys3(SYS_read, fd, (long)(buf + total), max - total)) > 0) total += r;
    sys3(SYS_close, fd, 0, 0); buf[total < max ? total : max] = 0; return total;
}
static void poll_input(int fd) {
    for (int i = 0; i < NACT; i++) press[i] = 0;
    if (fd < 0) return;
    unsigned char e[16];
    while (sys3(SYS_read, fd, (long)e, 16) == 16) {
        int type = e[8] | (e[9] << 8), code = e[10] | (e[11] << 8), val = e[12] | (e[13] << 8);
        if (type != 1 || val != 1) continue;
        if (code == 103) press[A_UP] = 1; else if (code == 108) press[A_DOWN] = 1;
        else if (code == 105) press[A_LEFT] = 1; else if (code == 106) press[A_RIGHT] = 1;
        else if (code == 305) press[A_GREEN] = 1; else if (code == 304) press[A_RED] = 1;
    }
}
static void path_set_root(void) { int k = 0; const char *r = ROOT; while (r[k]) { path[k] = r[k]; k++; } path[k] = 0; rootlen = k; }
/* payload.sh writes the active theme name to /tmp/loot.theme; map it to a skin */
static int streqs(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void load_theme(void) {
    char b[64]; int id = 0;
    int fd = (int)sys3(SYS_open, (long)"/tmp/loot.theme", O_RDONLY, 0);
    if (fd >= 0) { long n = sys3(SYS_read, fd, (long)b, 63); sys3(SYS_close, fd, 0, 0);
        if (n > 0) { while (n > 0 && (b[n - 1] == '\n' || b[n - 1] == '\r' || b[n - 1] == ' ')) n--; b[n] = 0;
            if (streqs(b, "dockside-dark")) id = 2; else if (streqs(b, "dockside")) id = 1; } }
    init_skin(id);
}
int main(void) {
    int fb_fd = (int)sys3(SYS_open, (long)"/dev/fb0", O_RDWR, 0); if (fb_fd < 0) return 1;
    int ev = (int)sys3(SYS_open, (long)"/dev/input/event0", O_RDONLY | O_NONBLOCK, 0);
    load_theme(); path_set_root(); enter_dir(); state = S_BROWSE;
    while (!quit_req) {
        poll_input(ev);
        game_tick();
        render();
        sys3(SYS_lseek, fb_fd, 0, 0); sys3(SYS_write, fb_fd, (long)fb, FRAME_BYTES);
        sleep_ms(50);
    }
    if (ev >= 0) sys3(SYS_close, ev, 0, 0);
    sys3(SYS_close, fb_fd, 0, 0);
    return 0;
}

/* ================================================================== desktop preview */
#else
#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
static int list_dir(const char *p) {
    nent = 0; DIR *d = opendir(p); if (!d) return -1; struct dirent *de;
    while ((de = readdir(d)) && nent < MAXENT) {
        if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0))) continue;
        Entry *e = &ent[nent]; int k = 0; while (de->d_name[k] && k < NAMEMAX) { e->name[k] = de->d_name[k]; k++; } e->name[k] = 0;
        char full[PATHMAX]; snprintf(full, sizeof full, "%s/%s", p, de->d_name); struct stat st; e->is_dir = 0; e->size = 0;
        if (!stat(full, &st)) { e->is_dir = S_ISDIR(st.st_mode); e->size = st.st_size; }
        nent++;
    }
    closedir(d); sort_entries(); return nent;
}
static long read_file(const char *full, char *buf, long max) { FILE *f = fopen(full, "rb"); if (!f) return -1; long n = fread(buf, 1, max, f); fclose(f); buf[n < max ? n : max] = 0; return n; }
static const char *outdir;
static void snap(const char *name) { char p[512]; snprintf(p, sizeof p, "%s/%s.raw", outdir, name); FILE *f = fopen(p, "wb"); if (f) { fwrite(fb, 2, NPIX, f); fclose(f); } }
static void key(int a) { for (int i = 0; i < NACT; i++) press[i] = 0; press[a] = 1; game_tick(); for (int i = 0; i < NACT; i++) press[i] = 0; }
int main(int argc, char **argv) {
    if (argc < 4 || strcmp(argv[1], "--preview")) { fprintf(stderr, "usage: %s --preview ROOTDIR OUTDIR [theme:default|dockside|dockside-dark]\n", argv[0]); return 2; }
    int id = 0; if (argc >= 5) { if (!strcmp(argv[4], "dockside")) id = 1; else if (!strcmp(argv[4], "dockside-dark")) id = 2; }
    init_skin(id);
    int rl = 0; while (argv[2][rl]) { path[rl] = argv[2][rl]; rl++; } path[rl] = 0; rootlen = rl;
    outdir = argv[3];
    enter_dir(); state = S_BROWSE; render(); snap("browse");
    /* find a named entry in the current listing and select it */
    int (*find)(const char *) ;
    (void)find;
    /* helper: select entry by name, return 1 if found */
    #define SELECT(NM) do { int has_up = !at_root(); sel = 0; for (int i = 0; i < nent; i++) if (!name_cmp(ent[i].name, NM)) { sel = i + (has_up ? 1 : 0); break; } } while (0)
    /* 1) open a binary file -> info card. descend to pcap/ */
    SELECT("pcap"); key(A_GREEN); render(); snap("browse_pcap");
    { int has_up = !at_root(); for (int i = 0; i < nent; i++) if (!ent[i].is_dir && ext_is_binary(ent[i].name)) { sel = i + (has_up ? 1 : 0); break; } }
    key(A_GREEN); render(); snap("info");
    key(A_RED);            /* back to list */
    key(A_LEFT);           /* up to root */
    /* 2) open a text file -> viewer. descend to readiness/ */
    SELECT("readiness"); key(A_GREEN); render(); snap("browse_sub");
    { int has_up = !at_root(); for (int i = 0; i < nent; i++) if (!ent[i].is_dir) { sel = i + (has_up ? 1 : 0); break; } }
    key(A_GREEN); render(); snap("view");
    if (state == S_VIEW) { for (int i = 0; i < 5; i++) key(A_DOWN); render(); snap("view2"); key(A_GREEN); render(); snap("view_page"); }
    printf("opened: state=%d (2=info path works, then 1=view) name=%s lines=%d\n", state, open_name, nlines);
    return 0;
}
#endif
