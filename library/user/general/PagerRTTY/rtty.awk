# rtty.awk - text -> ITA2/Baudot RTTY (45.45 baud, ~170 Hz shift) as raw
# unsigned 8-bit PCM at 16 kHz on stdout. Runs in BusyBox awk (no math lib).
# Play with:  aplay -q -t raw -f U8 -r 16000 -c 1
# vars: msg  lead=1000 (ms)  amp=100
#
# Speed trick: mark 3909.09 Hz / space 4090.91 Hz fit a whole number of
# cycles in one bit (352 samples = 22 ms) and in half a bit (176 samples), so
# each bit starts and ends at phase 0. The waveforms are built once and
# repeated, instead of computing every sample.
function wave(cyc, n,   s, i, ph) {
    s = ""
    for (i = 0; i < n; i++) { ph = int(i * cyc * 256 / n) % 256; s = s T[ph] }
    return s
}
function sym(c,   k) {
    printf "%s", SP                                   # start bit
    for (k = 0; k < 5; k++) { printf "%s", (c % 2 ? MK : SP); c = int(c / 2) }
    printf "%s%s", MK, MKH                            # 1.5 stop bits
}
BEGIN {
    if (lead == "") lead = 1000; if (amp == "") amp = 100
    cs = 0.99969881869620425; sn = 0.024541228522912288; x = 1; y = 0
    for (i = 0; i < 256; i++) {
        v = int(128 + amp * y + 0.5); if (v < 1) v = 1
        T[i] = sprintf("%c", v); nx = x * cs - y * sn; y = x * sn + y * cs; x = nx
    }
    MK = wave(86, 352); SP = wave(90, 352); MKH = wave(43, 176)
    L = "\001E\nA SIU\rDRJNFCKTZLWHYPQOBG\001MXV"     # index-1 = ITA2 code
    F = "\0013\n- '87\r$4',!:(5\")2#6019?&\001./;"
    for (t = 0; t < lead; t += 22) printf "%s", MK     # lead-in (mark idle)
    sym(31); sym(31); figs = 0
    n = length(msg)
    for (p = 1; p <= n; p++) {
        ch = toupper(substr(msg, p, 1))
        if (ch == " " || ch == "\r" || ch == "\n") { sym(index(L, ch) - 1); figs = 0; continue }
        li = index(L, ch); fi = index(F, ch)
        if (li > 1) { if (figs) { sym(31); figs = 0 } sym(li - 1) }
        else if (fi > 1) { if (!figs) { sym(27); figs = 1 } sym(fi - 1) }
    }
    sym(31); for (k = 0; k < 4; k++) printf "%s", MK
}
