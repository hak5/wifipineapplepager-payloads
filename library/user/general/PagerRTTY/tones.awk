# tones.awk - tone sequence -> raw unsigned 8-bit PCM at 16 kHz on stdout.
# Runs in BusyBox awk. Play with:  aplay -q -t raw -f U8 -r 16000 -c 1
# vars: seq="F1[+F2]:MS,..."  (0:MS = silence)   amp=100
# Square waves on purpose: the buzzer can't play pure tones below ~1.5 kHz,
# but a square wave's harmonics make low tones audible. Output is built from
# runs of constant samples between waveform edges, so it stays fast.
function rep(v, n,   k, s, c) {
    k = v SUBSEP n
    if (k in R) return R[k]
    c = C[v]; s = ""
    while (n > 0) { if (n % 2) s = s c; c = c c; n = int(n / 2) }
    R[k] = s; return s
}
function seg(f1, f2, ms,   n, h1, h2, nx1, nx2, s1, s2, pos, nxt, len, v, a) {
    n = ms * RATE / 1000
    if (f1 <= 0) { len = int(n + 0.5); if (len > 0) printf "%s", rep(128, len); return }
    h1 = RATE / (2 * f1); nx1 = h1; s1 = 1
    if (f2 > 0) { h2 = RATE / (2 * f2); nx2 = h2; s2 = 1; a = amp / 2 } else { nx2 = n + 1; s2 = 0; a = amp }
    pos = 0
    while (pos < n) {
        nxt = nx1 < nx2 ? nx1 : nx2; if (nxt > n) nxt = n
        len = int(nxt + 0.5) - int(pos + 0.5)
        v = int(128 + a * (s1 + s2) + 0.5)
        if (len > 0) printf "%s", rep(v, len)
        pos = nxt
        if (nx1 <= nxt) { s1 = -s1; nx1 += h1 }
        if (f2 > 0 && nx2 <= nxt) { s2 = -s2; nx2 += h2 }
    }
}
BEGIN {
    RATE = 16000; if (amp == "") amp = 100; if (amp > 120) amp = 120
    for (i = 1; i < 256; i++) C[i] = sprintf("%c", i)
    m = split(seq, parts, ",")
    for (j = 1; j <= m; j++) {
        split(parts[j], tm, ":"); split(tm[1], ff, "+")
        seg(ff[1] + 0, ff[2] + 0, tm[2] + 0)
    }
}
