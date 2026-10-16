#!/bin/sh
#
# Title:        Starchorus -- on-device Overview (passive)
# Description:  Reads the starchorus.json the collector already wrote and shows it on the
#               device's 480x222 screen, one screen at a time: a summary (counts, band split,
#               freshness, crowding), the strongest networks, bands & security, logical devices /
#               merged SSIDs, probe requests, stations, and air quality (channel crowding). Each
#               screen ends with the time of the scan it shows. It NEVER transmits: it only reads
#               a local JSON file. No deauth, no rogue AP, no scan, no association. It starts and
#               stops nothing.
# Author:       Starchorus
# Version:      0.1.1
# Contract:     2
# Category:     reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs on the device (uses the device's display commands LOG / LIST_PICKER / ERROR_DIALOG / WAIT_FOR_INPUT,
# which exist only inside the payload runtime) AND on a dev machine
# (every device command has a plain-text fallback, so `sh starchorus-display.sh --once summary` prints
# the same screen to stdout for testing). Needs `jq` -- confirmed present on the device, but built
# WITHOUT the Oniguruma regex library, so no filter here may use test/match/sub/gsub/capture/scan/
# splits/split-2 (see the JQLIB block below and docs/device-notes.md), the --selftest included. A jq that
# lacks or breaks one of the builtins the filters use would leave the counters blank without a word, so
# the summary / top / bands screens print one red line when a cheap probe of that path fails, and
# --selftest names the builtin that does.
#
#   payload usage:  starchorus-display.sh              # the Overview: the summary, drawn once; A draws a screen again, B goes up
#   test usage:     starchorus-display.sh --once summary tests/fixtures/field-probes.json
#   device check:   sh starchorus-display.sh --selftest   # one PASS/FAIL line per jq builtin + the JQLIB helpers +
#                                                  # one end-to-end summary; exit 0 = all pass, 1 = any FAIL
#                                                  # (read-only, sends nothing, works even without jq)
#
# Reads $STARCHORUS_DIR/starchorus.json by default; pass a file as the last argument to override.
# The payload runs it as a child process and hands it three variables: STARCHORUS_SINCE (the epoch of the last Start: a
# capture generated before it counts as no data, so the screen never shows an earlier run's file), STARCHORUS_PAGE_URL
# (ADDR:PORT of the page, for the last line of the summary; empty = no page) and STARCHORUS_PARENT_PID (the payload: asked
# once per pass, after every answer and so before the next arm, and again when the list returns, so an Overview whose payload has
# gone ends at its next key press, not before: it waits for a key with no time limit; the payload gives it no stdout for that reason,
# so it holds none of the payload's pipes while it waits). Without them it behaves as it always did.
#
# KEYS. Nothing on the screen moves by itself: there is no timer and no live summary. The Overview ARMS one WAIT_FOR_INPUT in the
# background BEFORE it draws, the shell draws while it waits, and then takes the answer. Measured on the device (16 October 2026,
# docs/device-notes.md section 7): a press made while no wait is open is LOST, not queued (M1), and B pressed then is taken by the
# Pager UI itself and leaves the payload view (M2); a wait started in the background does get its key while the foreground writes
# LOG lines (M3). So a press during "Reading..." is kept: it ends the draw (a wait takes one key, and a draw that went on would run
# with none open: nothing more is printed and the jq that is running is ended) and is acted on at once, with the next wait armed
# straight after, so a second press has a wait to find. Not every moment is covered: a press that falls before the first arm, or
# between a key being answered and the next wait being registered with the UI (while a jq runs, the 0.2 s its watcher takes to see the
# key, then a few forks and the UI's own time: a fraction of a second), is lost and, for B, may still leave the payload view (M1, M2);
# docs/display-paths.md lists them. A wait is never put under `timeout`
# (killing a UI command can leave a waiter in the UI daemon that swallows the next press) and none is left behind: every way out
# of the Overview ends a pending waiter (ov_cleanup).
# Every press acts at once and means the same on every screen:
#   A  the same screen again          B  one level up: screen -> the list "Overview" -> exit 0, back to the payload's menu
#   LEFT / RIGHT  the previous / next screen, wrapping (summary, top, bands, devices, probes, clients, air)
#   UP / DOWN  ignored (the console's own scrolling), the wait is armed again at once and nothing is drawn (the screen is drawn
#              again only when the draw they came in was cut, so no half screen stays)
#   anything else, or no answer, that comes back within 1 s of its arm: a strike, three in a row end it (a slower one is only waited out)
# The words other payloads of the library test for count as the two buttons, so they are no strikes: BACK and Escape as B, a
# lower-case a or b as the capital (take). A draw that has to run jq prints "Reading..." first; jq runs under `timeout 20` when the
# device has that applet; a capture that takes longer gets the two lines of nodata() instead of numbers, and the verdict is cached
# per capture like a result (a run that a key has ended is no result and is not kept). STARCHORUS_PROC (a stand-in for /proc: the
# uptime and the stat file of this shell) and STARCHORUS_JQ_CAP are for the tests only.
#
# The only output is LOG lines: append-only (a payload cannot register screens of its own), nothing
# is sent, no LED or buzzer is driven. Red marks an alarm and nothing else: an open/WEP network, the
# one "jq incomplete" line (counts may be blank, see jq_warn), or the "No new scan" line that ends a screen
# whose capture is more than three of the collector's intervals old; nothing is green.

# shellcheck disable=SC2016  # every jq filter below is a literal program; no shell expansion intended
# shellcheck disable=SC2154  # R_<key> / N_<key> and the fx_ / rl_ names are set by load() and fetch() through eval
STARCHORUS_DIR=${STARCHORUS_DIR:-/root/loot/starchorus}
JSON=${STARCHORUS_JSON:-$STARCHORUS_DIR/starchorus.json}
GEN=0; LASTG=

# ------------------------------------------------------------------ device command shims
# On the device these are real commands; elsewhere (or with STARCHORUS_DISPLAY_PLAIN=1) everything falls back
# to stdout, colour words dropped, so the same script is testable. Detected via LIST_PICKER: device-only,
# unlike LOG, which clashes with macOS /usr/bin/log on a dev machine.
if [ "${STARCHORUS_DISPLAY_PLAIN:-0}" != 1 ] && command -v LIST_PICKER >/dev/null 2>&1; then ONDEV=1; else ONDEV=0; fi

# OV_GATE names the key file while a draw runs (draw sets it and clears it again), else it is empty; see draw.
OV_GATE=
log() {  # log [red|blue] "text..."  -- red = an alarm, blue = a heading (that is the whole palette)
    [ -s "$OV_GATE" ] && return 0   # a key has come during the draw: the draw is over and nothing more of it is printed
    case "$1" in red|blue) color=$1; shift ;; *) color= ;; esac
    if [ "$ONDEV" = 1 ]; then LOG ${color:+"$color"} "$*"; else printf '%s\n' "$*"; fi
}
logeach() { while IFS= read -r l; do log "$l"; done; }   # one LOG line per stdin line
err_dialog() { if [ "$ONDEV" = 1 ]; then ERROR_DIALOG "$1"; else printf 'ERROR: %s\n' "$1" >&2; fi }

# pick "Title" opt1 opt2 ... default -> the chosen option; the dev fallback echoes the default (last
# arg), so the menu flows run non-interactively
pick() { if [ "$ONDEV" = 1 ]; then LIST_PICKER "$@"; else for last; do :; done; printf '%s\n' "$last"; fi; }

# uptime_cs -> UT, the time since boot in hundredths of a second, read from /proc/uptime with the shell's own read (no
# process); UT stays empty and the status is 1 where there is no such file. STARCHORUS_PROC (TESTS ONLY) names another directory.
UT=
uptime_cs() {
    UT=; ut_p=${STARCHORUS_PROC:-/proc}/uptime
    [ -r "$ut_p" ] || return 1
    read -r ut_a _ 2>/dev/null < "$ut_p" || return 1
    case $ut_a in *.*) ut_f=${ut_a#*.} ;; *) ut_f=0 ;; esac
    ut_f=${ut_f}00; ut_f=${ut_f%"${ut_f#??}"}; ut_a=${ut_a%%.*}   # two decimals, whatever the file has
    case $ut_a$ut_f in ''|*[!0-9]*) return 1 ;; esac
    UT=$((ut_a * 100 + ${ut_f#0}))
}

# The key wait: arm, draw, take. The Overview keeps a WAIT_FOR_INPUT open while a screen or "Reading..." is on the console: arm()
# starts it in the background BEFORE the draw, the shell draws while it waits, take() then collects the answer. Why this order, as
# measured on the device on 16 October 2026 (docs/device-notes.md section 7): a press made while no wait is open is LOST, not
# queued (M1), and B pressed then is taken by the Pager UI itself and leaves the payload view (M2); a wait started in the background
# does receive its key while the foreground writes LOG lines (M3). Nothing is buffered, so a key that came back during a draw was
# pressed on purpose, at "Reading...", and is acted on as soon as that draw has ended.
# A wait takes ONE key. A draw that went on after it would run with no wait open for the rest of its time (up to the 20 s of jq,
# then every LOG line), and a second press in that time, B again because nothing seems to happen, would be lost or leave the payload
# view (M1, M2). So the draw does not go on: log() prints nothing once the key file holds an answer, a jq that is still running is
# ended (ov_jq), and take and the next arm follow at once. What stays unarmed is short: the start up to the first arm, and the stretch
# from a key being answered to the next wait being registered with the UI (the watcher's 0.2 s while a jq runs, two forks for the
# waiter, the UI's own time to take the request); a press that falls there is lost. docs/display-paths.md lists them.
# A wait is never put under `timeout`, and none is left behind: ov_cleanup ends a pending one.
#
# The waiter is a subshell that starts WAIT_FOR_INPUT as a background child of its own (answer to OV_RAW) and, when that has ended,
# leaves one line in OV_KEYF: "UPTIME KEY". UPTIME is /proc/uptime in hundredths of a second at that moment ("-" without a clock),
# KEY is what WAIT_FOR_INPUT printed (empty for no answer). Why a child inside the subshell and not `k=$(WAIT_FOR_INPUT)` there:
# a TERM to the subshell must reach WAIT_FOR_INPUT itself. A shell runs its traps only between commands, so a subshell that sits
# in a command substitution cannot pass the signal on; it would die and leave the real waiter behind, still registered with the
# UI daemon, where it takes the next press. Waiting in `wait` it can, at once. The subshell's trap only notes the signal (`sig`)
# and the code after the fork and after the wait acts on it, so a TERM that lands between the fork and the child's pid being known
# is not lost either. The subshell has no stdin, stdout or stderr of its own, so it holds none of the payload's pipes (the payload
# gives the display no stdout for the same reason), and it clears the EXIT trap it inherits (ov_cleanup would otherwise delete the
# temp dir as soon as the first answer came in).
# KEY_CS, the time from the arm to the end of the wait, is what the strike rule judges: it comes from the waiter's own clock, so a
# long draw between the arm and the take cannot make an answer that came at once look slow. STRIKE_CS is one second.
KEY=; KEY_CS=; KEY_ERR=; STRIKE_CS=100
OV_TMP=; OV_KEYF=; OV_RAW=; OV_JQO=; OV_WPID=; OV_ARM=; OV_ARMING=; OV_JPID=; OV_WTCH=
CR=$(printf '\r'); TAB=$(printf '\t')
arm() {
    : > "$OV_KEYF"
    uptime_cs; OV_ARM=$UT
    OV_ARMING=1   # ov_cleanup: a TERM that lands before OV_WPID is set finds the waiter in $!
    (
        trap - EXIT; ow=; sig=
        trap 'sig=1' TERM INT HUP
        WAIT_FOR_INPUT > "$OV_RAW" 2>/dev/null & ow=$!
        [ -z "$sig" ] || { kill "$ow" 2>/dev/null; exit 143; }
        wait "$ow"
        [ -z "$sig" ] || { kill "$ow" 2>/dev/null; wait "$ow" 2>/dev/null; exit 143; }
        ok=; read -r ok < "$OV_RAW"
        uptime_cs; printf '%s %s\n' "${UT:--}" "$ok" > "$OV_KEYF"
    ) > /dev/null 2>&1 < /dev/null &
    OV_WPID=$!; OV_ARMING=
}
# take -> KEY: A, B, UP, DOWN, LEFT or RIGHT as WAIT_FOR_INPUT printed it (BACK and Escape count as B, as in other payloads of the
# library; a lower-case a or b as the capital), else empty; KEY_CS as above (empty without a clock). Waits for the waiter armed last
# (at once when it has answered during the draw), clears OV_WPID, and strips spaces, tabs and CR from the answer with the shell's own
# expansions (no process per key). KEY_ERR=1: the waiter has ended and left nothing in the key file (the file system is full, or the
# waiter was killed from outside): that is no answer, and the Overview says so instead of counting it as a strike.
take() {
    [ -z "$OV_WPID" ] || wait "$OV_WPID" 2>/dev/null
    OV_WPID=
    KEY=; KEY_CS=; KEY_ERR=; tk_t=; tk_k=
    if [ -s "$OV_KEYF" ]; then read -r tk_t tk_k < "$OV_KEYF" || :; else KEY_ERR=1; fi
    while :; do
        case $tk_k in
            *" "*) tk_k=${tk_k%%" "*}${tk_k#*" "} ;;
            *"$TAB"*) tk_k=${tk_k%%"$TAB"*}${tk_k#*"$TAB"} ;;
            *"$CR"*) tk_k=${tk_k%%"$CR"*}${tk_k#*"$CR"} ;;
            *) break ;;
        esac
    done
    case $tk_t in
        ''|*[!0-9]*) ;;
        *) case $OV_ARM in ''|*[!0-9]*) ;; *) KEY_CS=$((tk_t - OV_ARM)) ;; esac ;;
    esac
    case $tk_k in
        A|a) KEY=A ;;
        B|b|BACK|Escape) KEY=B ;;
        UP|DOWN|LEFT|RIGHT) KEY=$tk_k ;;
    esac
}
# ov_kids PID -> the pids of PID's children, one per line: /proc/*/stat field 4 is the parent, read after the LAST ")" (the command
# in field 2 may hold one); `ps` where there is no /proc (a dev machine).
ov_kids() {
    if [ -r /proc/self/stat ]; then
        # shellcheck disable=SC2016   # awk program
        cat /proc/[0-9]*/stat 2>/dev/null | awk -v p="$1" '{
            l = $0; c = 0; t = l
            while ((k = index(t, ")")) > 0) { c += k; t = substr(t, k + 1) }
            if (c == 0) next
            split(substr(l, c + 1), f, " ")
            if (f[2] == p) print $1 }'
    else
        ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'
    fi
}
# ov_kill PID: ends PID and what it started. The children go first: jq runs under `timeout`, and a `timeout` that is ended does not
# necessarily end its command (which implementation the device has was not measured), so a jq that nobody wants any more must not be
# left running behind it; once `timeout` is gone, its jq would be found with a parent of 1.
ov_kill() {
    ok_k=$(ov_kids "$1")
    # shellcheck disable=SC2086   # a list of pids, split on purpose
    [ -z "$ok_k" ] || kill $ok_k 2>/dev/null
    kill "$1" 2>/dev/null
}
# ov_cleanup: the EXIT trap of the Overview (set where it starts). Ends a waiter that is still pending (the subshell hands the TERM on
# to WAIT_FOR_INPUT), the jq of a draw that is running and its watcher, and removes the temp dir. Normal exits come after take and find
# nothing pending; this is for TERM, INT and HUP, which reach the trap through `exit`, and for any exit the loop did not plan. A signal
# that lands after the waiter was forked and before its pid was stored (OV_ARMING) finds it in $!.
ov_cleanup() {
    ov_last=$!
    [ -n "$OV_WPID" ] || [ "$OV_ARMING" != 1 ] || OV_WPID=$ov_last
    [ -z "$OV_WPID" ] || kill "$OV_WPID" 2>/dev/null
    [ -z "$OV_WTCH" ] || kill "$OV_WTCH" 2>/dev/null
    [ -z "$OV_JPID" ] || ov_kill "$OV_JPID"
    [ -z "$OV_TMP" ] || rm -rf "$OV_TMP"
}

# parent_gone -> 0 when STARCHORUS_PARENT_PID names the payload that started us and it has ended (or we were handed over
# to another parent): the Overview then ends too, instead of drawing over whatever the device shows next. No process is started
# for it: it runs between a key being taken and the next wait being armed, which must not take long. The parent of this shell is
# field 4 of /proc/self/stat (the file is read by the shell's own `read`, so "self" is this shell), taken after the last ") ".
# STARCHORUS_PROC (TESTS ONLY) names another directory for /proc.
parent_gone() {
    case ${STARCHORUS_PARENT_PID:-} in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$STARCHORUS_PARENT_PID" 2>/dev/null || return 0
    pg_f=${STARCHORUS_PROC:-/proc}/self/stat
    [ -r "$pg_f" ] || return 1
    read -r pg_s < "$pg_f" || return 1
    pg_s=${pg_s##*") "}; pg_s=${pg_s#* }; pg_s=${pg_s%% *}   # "STATE PPID ..." -> PPID
    case $pg_s in ''|*[!0-9]*) return 1 ;; esac
    [ "$pg_s" != "$STARCHORUS_PARENT_PID" ]
}

# ------------------------------------------------------------------ data access (jq, read-only)
# The "jq not found" gate sits right before the dispatch at the bottom of this file, not here: --selftest
# has to run (and report "FAIL: jq present") on a box without jq, and it needs every function below.
#
# ONE jq PROCESS PER SCREEN. The device is a single ~580 MHz MIPS core: every jq start re-parses the whole
# capture (15-50 KB) and compiles JQLIB again, which is what made a redraw cost seconds of CPU. So each
# screen has ONE jq program (JQ_SUMMARY, JQ_TOP, ... below) that computes every value the screen needs and
# prints them as records, and fetch() runs it once per render:
#     ok 0                      <- the document parsed (always the first record)
#     <key> <N>                 <- a header: the key and the number of text lines that follow
#     <N lines>
# A record is framed by its line COUNT, never by looking at the text, so no value (an SSID, a probe name) can
# forge a record: a newline inside a value is split into lines by jq (_R) and arrives as lines, exactly as the
# separate q calls of the earlier versions delivered it. load() turns the records into R_<key> (the lines, joined
# by newlines) and N_<key> (their count). A value that failed to compute (see _R) keeps the lines it had produced
# before the error, usually none: R_<key> is blank, as the output of a failed filter was before. A document that does not parse, is empty or is just null /
# false is "no data" (that is json_ok, folded into the same call), and so, with STARCHORUS_SINCE (digits, the epoch of the
# last Start), is a capture whose `generated` is older or missing: SINCE_JQ puts that gate in front of the program, it
# costs no process of its own. No data prints WAITING.
# fetch() also keeps the verdict of the last run per screen with a fingerprint of the file: the records, "no data" or
# "too slow". When the collector has not written a new capture (it replaces starchorus.json atomically once a cycle, 5 to 30 s)
# the verdict is reused whatever it was, so a screen drawn again (key A) runs no jq at all and a screen that waits for the
# first scan does not read the old file again and again; only the time of the scan and its age, both shell arithmetic, move.
NL='
'
RKEYS=
# load OUTPUT: records -> R_<key> / N_<key> (the keys are written by the jq programs below, never taken from the capture)
load() {
    for k in $RKEYS; do unset "R_$k" "N_$k"; done
    RKEYS=
    while IFS= read -r l; do
        n=${l##* }; k=${l%" $n"}
        case $k in ""|*[!a-z0-9_]*) break ;; esac
        case $n in ""|*[!0-9]*) break ;; esac
        v=; i=0
        while [ "$i" -lt "$n" ] && IFS= read -r x; do
            if [ "$i" = 0 ]; then v=$x; else v=$v$NL$x; fi
            i=$((i + 1))
        done
        eval "R_$k=\$v N_$k=\$i"
        RKEYS="$RKEYS $k"
    done <<EOF
$1
EOF
}
# rec_lines KEY: the lines of one record on stdout, nothing for an empty or missing one
rec_lines() {
    eval "rl_n=\${N_$1:-0} rl_v=\${R_$1-}"
    if [ "$rl_n" -gt 0 ]; then printf '%s\n' "$rl_v"; fi
    return 0
}

# Fingerprint of the capture file: changes whenever the collector's atomic mv puts a new file in place. Both forms
# follow a symlink (-L): STARCHORUS_JSON may point at a link whose target the collector replaces, and the link itself
# never changes.
# stat -L -c '%Y %s %i' (mtime, size, inode) where the stat applet takes it; else the long listing with inode and
# numeric owners (ls -linL), whose time has minute resolution, which the inode and the size make up for.
# fp_init decides between the two once, in the main shell (an assignment inside the $(...) of fetch() would be lost
# with the subshell, and the probe would run again on every render).
FP_MODE=
fp_init() {
    fp_probe=$(stat -L -c '%Y %s %i' / 2>/dev/null)
    case $fp_probe in ""|*[!0-9\ ]*) FP_MODE=long ;; *) FP_MODE=stat ;; esac
}
fingerprint() {
    if [ "$FP_MODE" = stat ]; then stat -L -c '%Y %s %i' "$JSON" 2>/dev/null; else ls -linL "$JSON" 2>/dev/null; fi
}

# ov_jq PROGRAM -> fx_out (what jq printed) and, as the status, the one of `timeout` or of jq. The Overview runs jq in the background
# with its output in a file, and the shell waits for it in `wait` (a TERM is therefore handled at once). A watcher looks at the key
# file every 0.2 s (a whole second where the sleep applet has no fractions); once the waiter armed for this draw has its answer, it
# ends the jq and what `timeout` started for it (ov_kill): a draw that went on would run with no wait open for the rest of its time,
# and jq is the long part of it (up to the 20 s of the cap). FX_CUT=1 says the run ended for that reason: fetch then keeps nothing, so
# the next draw of the screen reads the capture again. A run that failed while a key had come counts as cut too, whatever its status
# (143 or 137 for a jq that was ended; a `timeout` that fired at that moment is not worth a verdict). The watcher leaves by itself
# when the jq is gone (its pid does not exist once `wait` has reaped it) and is ended here as well.
ov_jq() {
    FX_CUT=0
    if [ -n "$JQ_TMO" ]; then timeout "$JQ_TMO" jq -r "$JQLIB$SINCE_JQ$1" "$JSON" > "$OV_JQO" 2>/dev/null &
    else jq -r "$JQLIB$SINCE_JQ$1" "$JSON" > "$OV_JQO" 2>/dev/null &
    fi
    OV_JPID=$!; oj_p=$!
    (
        trap - EXIT
        while kill -0 "$oj_p" 2>/dev/null && [ ! -s "$OV_KEYF" ]; do sleep 0.2 2>/dev/null || sleep 1; done
        [ ! -s "$OV_KEYF" ] || ov_kill "$oj_p"
    ) > /dev/null 2>&1 < /dev/null &
    OV_WTCH=$!
    wait "$OV_JPID" 2>/dev/null; oj_rc=$?
    kill "$OV_WTCH" 2>/dev/null; wait "$OV_WTCH" 2>/dev/null
    OV_JPID=; OV_WTCH=
    if [ "$oj_rc" != 0 ] && [ -s "$OV_KEYF" ]; then FX_CUT=1; return "$oj_rc"; fi
    fx_out=$(cat "$OV_JQO" 2>/dev/null)
    return "$oj_rc"
}
# fetch SCREEN 'PROGRAM': run (or reuse) the screen's one jq program and load() its records; 1 = nothing to show, and
# FX_SLOW says whether that is because jq ran out of time (see nodata). A key that has ended the draw (see ov_jq) also gives 1, with
# FX_SLOW 0 and nothing kept; what the screen then prints is not printed (see log).
# The fingerprint is taken BEFORE jq reads the file: a capture that lands in between is simply read again at the
# next draw. stderr goes to /dev/null on purpose (a screen must never print jq noise), which is exactly how
# a missing builtin used to turn into silently blank counters: see jq_warn.
# In the Overview (OV_LIVE=1) a run that is not served from the cache says "Reading..." first (busy) and runs (ov_jq) under
# `timeout` where the device has one, so a capture too big for the device cannot hold the screen for ever: status 124, 137
# or 143 from that `timeout` is "too slow". Only from it: a jq that ran without the limit (no applet, --once, --selftest) and
# was killed from outside (the out-of-memory killer, a TERM) never had 20 s to overrun, so that is no data, as it always was.
# The no-data and the slow verdict are cached per fingerprint exactly like the records (CV_<screen>:
# ok, nodata or slow), so a draw of the same file again, A on the waiting or on the slow screen, starts no jq.
# --once and --selftest never set OV_LIVE: one plain jq call, as before.
fetch() {
    FX_SLOW=0
    [ -s "$JSON" ] || return 1
    [ -n "$FP_MODE" ] || fp_init
    fx_key="$JSON|$(fingerprint)"
    eval "fx_ck=\${CK_$1-} fx_out=\${CO_$1-} fx_vd=\${CV_$1-}"
    if [ "$fx_key" = "$JSON|" ] || [ "$fx_ck" != "$fx_key" ]; then
        [ ! -s "$OV_GATE" ] || return 1   # a key has come: the draw is over, nothing is read for it
        busy
        fx_lim=0
        if [ "$OV_LIVE" = 1 ]; then
            [ -z "$JQ_TMO" ] || fx_lim=1
            ov_jq "$2"; fx_rc=$?
            [ "$FX_CUT" != 1 ] || return 1   # ended by a key: that is no verdict on the capture and nothing of it is kept
        else
            fx_out=$(jq -r "$JQLIB$SINCE_JQ$2" "$JSON" 2>/dev/null); fx_rc=$?
        fi
        case $fx_rc in
            0) if [ -n "$fx_out" ]; then fx_vd=ok; else fx_vd=nodata; fi ;;
            124|137|143) if [ "$fx_lim" = 1 ]; then fx_vd=slow; else fx_vd=nodata; fi; fx_out= ;;
            *) fx_vd=nodata; fx_out= ;;
        esac
        [ "$fx_key" = "$JSON|" ] || eval "CK_$1=\$fx_key CO_$1=\$fx_out CV_$1=\$fx_vd"
    fi
    case $fx_vd in
        ok) load "$fx_out" ;;
        slow) FX_SLOW=1; return 1 ;;
        *) return 1 ;;
    esac
}
# The SINCE gate (see above): an older capture reaches the screen's program as null, which _D turns into no data.
case ${STARCHORUS_SINCE:-} in
    ''|*[!0-9]*) SINCE_JQ= ;;
    *) SINCE_JQ="(if (.generated | type) == \"number\" and .generated >= $STARCHORUS_SINCE then . else null end) | " ;;
esac
WAITING="Waiting for the first scan."
SLOW1="This scan took over 20 s to read."   # the cap is 20 s; STARCHORUS_JQ_CAP shortens it for the tests, the words stay
SLOW2="Try Settings > Show Last: 1 h."
# nodata: what a screen prints when fetch() has nothing to show: the two lines for a capture jq could not read in time, else
# the waiting line (no capture yet, or only an earlier run's)
nodata() { if [ "$FX_SLOW" = 1 ]; then log "$SLOW1"; log "$SLOW2"; else log "$WAITING"; fi; }
# "Reading..." (BUSY) is the first line of a draw that has to run jq, printed once however many jq runs the draw needs
# (the probe of jq_healthy, then the screen's program). Only the Overview sets OV_LIVE; --once prints no such line.
BUSY="Reading..."
OV_LIVE=0; OV_BUSY=0; FX_SLOW=0; OV_INT=
busy() { [ "$OV_LIVE" = 1 ] && [ "$OV_BUSY" = 0 ] || return 0; OV_BUSY=1; log "$BUSY"; }
# jq under `timeout` where the applet exists (BusyBox has it); the cap in seconds, 20 unless the tests shorten it
JQ_TMO=
if command -v timeout >/dev/null 2>&1; then
    JQ_TMO=${STARCHORUS_JQ_CAP:-20}; case $JQ_TMO in ''|0|*[!0-9]*) JQ_TMO=20 ;; esac
fi

# NO REGEX IN ANY jq FILTER. The device's jq is built without Oniguruma (device-verified,
# docs/device-notes.md §2a): test/match/sub/gsub/capture/scan/splits/split-2 abort the whole program
# at call time (exit 5), and fetch() discards stderr, so a regex filter would silently print nothing
# (the band counts and the open/WEP line would come out EMPTY on the device).
# JQLIB holds string-builtin replacements and the record helpers; every screen program runs with it in front.
# A builtin not used here yet needs a device check first (§2a). tools/regress.d/jq-noregex.sh fails on a regex call and pins
# the meaning of bandnorm/sectag/isopenwep/secupper and the _WS membership (R3); display-selftest.sh (S8) repeats the
# regex scan after joining shell '' pairs, the --selftest included (it calls no regex builtin either).
#
# bandnorm ("2.4GHz"/" 5 GHz"/"6g" -> "2.4"/"5"/"6") follows the page's bandOf step for step
# (starchorus.html: .trim(), then /\s*ghz$/i): _trimws first, then each suffix cut followed by
# another _rtrimws; losing any of the three _rtrimws silently un-counts a band.
# _WS is the UNION (26) of the two measured references, so no band value either one normalises can
# drop out of the counts: Oniguruma "[[:space:]]" = the 25 Unicode White_Space codepoints (U+0009-
# U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000);
# the page's .trim() = the same minus U+0085 plus U+FEFF. Deliberate divergences from the page, both
# in the counting direction: U+0085 is trimmed here, and a bare trailing "g" is stripped here
# (iwinfo writes "6g").
# _rtrimws/_ltrimws are O(n^2) in the whitespace run (every slice copies); explode/implode would be
# linear but are not verified on the device's jq, and band strings are a handful of characters.
# rssit = the page's rssiT on an RSSI (a null would count as 1, as rssiT(null) does in JS; only apprep, i.e. the
# freshness line, still carries a null: pgaps below turns a missing RSSI into -75 dBm first, as normalizeDoc does).
# chloads / busiest (crowding and the busiest channel) follow the page's own pipeline, not apprep:
# pgaps = normalizeDoc for the fields the channel model reads (BSSID key via normMac or "ap<i>", duplicate
# BSSIDs merged with the strongest RSSI and the first non-empty channel/freq/width, a missing RSSI = -75 dBm,
# band via bandOf with its freq/channel fallback, a width outside 20/40/80/160/320 = none), sorted like
# S.apOrder (RSSI desc, then BSSID); chloads lists the channels per band in the order they first appear there
# and sums each load in that order (float addition is not associative: a tie can hinge on it); busiest is the
# FIRST channel with the highest load, as crowdingOf keeps it. chloads_of / _busiest take the pgaps result and the
# chloads list, so a screen that needs both (crowding, busiest channel, the Air block) runs pgaps once.
# _trimjs trims the page's .trim() set (_WS without U+0085). Not modelled (the collector writes neither): numeric
# STRINGS (the page's numOrNull reads "6" as 6, here only JSON numbers count), non-ASCII capitals in a BSSID
# (toLowerCase vs ascii_downcase).
# ld2 = channelLoad's Math.round(sum * 100) / 100 (the Air screen ranks on it, like airQuality); beaconpct = the page's
# beaconPct(band, n) for the n APs of ONE channel (rounded per channel, then summed and rounded again per band).
# oneline joins the lines of a text with a space: a newline in an SSID must not start a LOG line of its own (screen_top
# marks its alarm lines with a leading "!" that only the filter may write).
# Record helpers (see the data-access notes above): _D(body) is the whole program of a screen: nothing for a document
# that is null or false (no data), else the "ok 0" record and then body. _R(key; f) is one record: every output of f as
# text (a string as it is, anything else as JSON; _r), split into lines, behind a "key N" header; if f fails (a builtin
# that is missing on the device, a field of the wrong type) the record keeps what f had printed before the error and the
# other records still arrive, which is what separate filters per value gave: one blank figure, not a blank screen. The
# program uses try for that (and, with catch, to turn a failed intermediate result into null). _chomp drops trailing
# newlines (what $(...) did to a one-line value before).
# bandcnt counts the APs of one band in the list of normalised band strings the program computed once.
# clouds = the page's random clouds (docs/architecture.md §8.8a) on one capture: rndfree lists the randomised free stations
# the way normalizeDoc reads them (the first entry of a MAC wins, an associated MAC is not free, a randomized flag or the U/L
# bit without a vendor) with D1 dating; this device's own transmitters (center.own_bssids) are left out. cl_bands is the flat-window
# mean shift (±3 dB, the largest stack of one value first, at most 8 shifts, down to 8 addresses), cl_bursts the bursts (a gap
# > 2 s starts the next; the newest 1500 of a band are examined). cl_streams finds the periods a band's burst starts show far more
# often than unrelated bursts would. First pairs: candidates are the commonest gaps (15 to 300 s, one per tolerance) to the next three
# bursts; a period counts when its pair hits (±max(2 s, 10 %)) exceed the chance level, the larger of the band's own count in the bands
# beside that window (cl_hits: what this band shows by chance, other devices and crowding included) and the Poisson count (cl_chance,
# worked out from the band's density without exp() or pow(): cl_expm is ten squarings), by 6 standard deviations plus 2, with twice the
# own count, at least 5 pairs and 6 bursts; the clearest period (its fundamental, when that stands on its own) takes its bursts out, up
# to 5 times. Then, for a band too dense for pairs, chains (cl_chain): bursts one to three periods after one another that keep their
# phase, against the longest chain bursts of the band's density make by chance (cl_need), the first at a chance of 0.5 links per
# burst, later ones at 0.8. A stream's own addresses (8 or more) are a cloud; a stream whose bursts coincide (>= 0.6) with an accepted
# cloud within 12 dB is the same device seen in another signal band, and one with the same period (or a whole number of them: a band that holds every other burst) whose bursts together keep the
# rhythm (>= 0.8 of the gaps) is the same device that moved from one band to the next: both join it; a loose address inside one of a
# cloud's bursts within 6 dB of the centre of any band it holds joins too. cl_in tests a time against a cloud's bursts by bisection (cl_cov: their starts and the running latest end). The literals are the
# page's CLOUD values; tools/regress.d/clouds.sh compares page and Overview on documents at each threshold.
# Deliberate divergences from the page: numeric STRINGS in rssi or last_seen do not count here; the vendor test does not strip
# control characters; and the Overview reads each capture on its own, so it has no keep rule (the page holds a live cloud down
# to two addresses; a first load of the page and the Overview agree).
JQLIB='def _WS: ["\u0009","\u000A","\u000B","\u000C","\u000D","\u0020","\u0085","\u00A0","\u1680",
          "\u2000","\u2001","\u2002","\u2003","\u2004","\u2005","\u2006","\u2007","\u2008",
          "\u2009","\u200A","\u2028","\u2029","\u202F","\u205F","\u3000","\uFEFF"];
def _rtrimws: _WS as $ws | until(length == 0 or ((.[-1:]) as $c | $ws | index($c)) == null; .[:-1]);
def _ltrimws: _WS as $ws | until(length == 0 or ((.[0:1]) as $c | $ws | index($c)) == null; .[1:]);
def _trimws: _ltrimws | _rtrimws;
def bandnorm: (. // "") | tostring | ascii_downcase | _trimws
         | (if endswith("ghz") then rtrimstr("ghz") | _rtrimws else . end)
         | (if endswith("g")   then rtrimstr("g")   | _rtrimws else . end);
def rssit: (if . == null then 1 else ((. + 90) / 60 | if . < 0 then 0 elif . > 1 then 1 else . end) end);
def fctr($b; $ch): if $ch == null then null elif $b == "2.4" then (if $ch == 14 then 2484 else 2407 + 5 * $ch end) elif $b == "5" then 5000 + 5 * $ch elif $b == "6" then (if $ch == 2 then 5935 else 5950 + 5 * $ch end) else null end;
def apprep: {b: (.band | bandnorm), ch: (.channel | if type == "number" then . else null end), fq: (.freq | if type == "number" then . else null end),
             w: (.width | if type == "number" and (. as $w | [20,40,80,160,320] | index($w)) != null then . else 20 end),
             r: (.rssi | if type == "number" then (if . < -120 then -120 elif . > 0 then 0 else . end) else null end),
             ls: (.last_seen | if type == "number" then . else null end)};
def apspan: (.fq // fctr(.b; .ch)) as $f | if $f == null then null else [$f - .w / 2, $f + .w / 2] end;
def tierof($g): if $g == null or .ls == null or .ls <= 0 then null else ($g - .ls) as $age | if $age < -300 then null else (if $age < 0 then 0 else $age end) as $a | (if $a < 60 then 0 elif $a < 300 then 1 elif $a < 900 then 2 else 3 end) end end;
def chload($A; $b; $ch): (fctr($b; $ch)) as $f | if $f == null then {load: 0, co: 0, adj: 0}
  else ([$A[] | select(.b == $b and .ch != null) | . as $x | ($x | apspan) as $sp | select($sp != null)
        | select(((if $sp[1] < $f + 10 then $sp[1] else $f + 10 end) - (if $sp[0] > $f - 10 then $sp[0] else $f - 10 end)) > 0) | {r: ($x.r | rssit), same: ($x.ch == $ch)}]) as $O
    | {load: ([$O[].r] | add // 0), co: ([$O[] | select(.same)] | length), adj: ([$O[] | select(.same | not)] | length)} end;
def _WSP: _WS | map(select(. != "\u0085"));
def _trimjs: _WSP as $ws | until(length == 0 or ((.[0:1]) as $c | $ws | index($c)) == null; .[1:])
                         | until(length == 0 or ((.[-1:]) as $c | $ws | index($c)) == null; .[:-1]);
def pgband($f; $ch): (if . == null then "" else tostring end) | _trimjs
  | (if ascii_downcase | endswith("ghz") then .[:-3] | _trimjs else . end)
  | if . == "2.4" or . == "5" or . == "6" then .
    elif $f != null and $f >= 5925 then "6" elif $f != null and $f >= 5000 then "5" elif $f != null and $f >= 2400 then "2.4"
    elif $ch != null and $ch > 177 then "6" elif $ch != null and $ch >= 32 and $ch <= 177 then "5"
    elif $ch != null and $ch >= 1 and $ch <= 14 then "2.4" else "unknown" end;
def pgmac: tostring | _trimjs | ascii_downcase | ([split("-")[] | ":" + .] | add | .[1:])
  | if length == 12 and ([range(0; 12) as $i | .[$i:$i+1] | . as $c
        | select((["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"] | index($c)) != null)] | length) == 12
    then . as $s | [range(0; 6) as $i | ":" + $s[$i * 2:$i * 2 + 2]] | add | .[1:] else . end;
def pgaps: .aps as $R | [range(0; $R | length) as $i | $R[$i] | select(type == "object")
    | (.channel | if type == "number" then . else null end) as $ch | (.freq | if type == "number" then . else null end) as $fq
    | {id: (if .bssid == null or (.bssid | tostring | _trimjs) == "" then "ap\($i)" else (.bssid | pgmac) end),
       r: (.rssi | if type == "number" then (if . < -120 then -120 elif . > 0 then 0 else . end) else null end),
       ch: $ch, fq: $fq, w: (.width | if type == "number" and (. as $w | [20,40,80,160,320] | index($w)) != null then . else null end),
       b: (.band | pgband($fq; $ch))}]
  | group_by(.id)
  | map({id: .[0].id, r: ([.[].r | select(. != null)] | max // -75), ch: ([.[].ch | select(. != null)] | .[0]),
         fq: ([.[].fq | select(. != null)] | .[0]), w: ([.[].w | select(. != null)] | .[0] // 20),
         b: ([.[].b | select(. != "unknown")] | .[0] // "unknown")})
  | sort_by(-.r, .id);
def chloads_of($A): [("2.4", "5", "6") as $b | [$A[] | select(.b == $b and .ch != null) | .ch] as $L
     | [range(0; $L | length) as $i | $L[$i] as $x | select(($L[:$i] | index($x)) == null) | $x][] | {b: $b, ch: .}]
  | map(. + {load: chload($A; .b; .ch).load});
def chloads: pgaps as $A | chloads_of($A);
def _busiest: if length == 0 then null else (map(.load) | max) as $m | map(select(.load == $m)) | .[0] end;
def busiest: chloads | _busiest;
def ld2: (. * 100 | round) / 100;
def beaconpct($b; $n): ($n * ((if $b == "2.4" then 192 else 20 end) + 200 * 8 / (if $b == "2.4" then 1 else 6 end)) / (102.4 * 10) * 10 | round) / 10;
def oneline: tostring | split("\n") | .[0:1] + (.[1:] | map(" " + .)) | add // "";
def probers: .unassociated[] | select(.probes and (.probes|length>0));
def secupper: (. // "") | tostring | ascii_upcase;
def isopenwep: secupper | (. == "" or . == "OPEN" or contains("WEP"));
def sectag: secupper
         | if . == "" or . == "OPEN" or . == "NONE" then "Open"
           elif contains("WEP") then "WEP"
           elif contains("WPA3") or contains("SAE") then "WPA3"
           elif contains("OWE") then "OWE"
           elif contains("WPA2") or contains("RSN") then "WPA2"
           elif contains("WPA") then "WPA"
           else "other" end;
def _r: tostring;
def _chomp: if type == "string" then until(endswith("\n") | not; .[:-1]) else . end;
def _R($k; f): [try f] | map(_r | split("\n")) | add // [] | "\($k) \(length)", .[];
def _D(body): if . == null or . == false then empty else "ok 0", body end;
def bandcnt($B; $b): $B | map(select(. == $b)) | length;
def _abs: if . < 0 then -. else . end;
def _win($c): select(.r >= $c - 3 and .r <= $c + 3);
# the randomised free stations, normalised like normalizeDoc (first entry of a MAC wins, associated wins), with D1 dating
def rndfree: (.generated | if type == "number" then . else null end) as $g
  | ([.aps[]? | select(type == "object") | (.clients // [])[]? | select(type == "object") | .mac
      | select(. != null) | select((tostring | _trimjs) != "") | pgmac]) as $A
  | (.unassociated // []) as $U
  | [range(0; $U | length) as $j | $U[$j] | select(type == "object")
     | {id: (if .mac == null or (.mac | tostring | _trimjs) == "" then "free\($j)" else (.mac | pgmac) end),
        v: (.vendor | if type == "string" then (_trimjs | length) > 0 else false end),
        rf: (.randomized == true),
        r: (.rssi | if type == "number" then (if . < -120 then -120 elif . > 0 then 0 else . end) else null end),
        t: (.last_seen | if type == "number" then . else null end)}]
  | group_by(.id) | map(.[0]) | map(select(.id as $i | $A | index($i) == null))
  | map(select(.rf or ((.v | not) and ((.id[1:2]) as $c | ["2","6","a","e"] | index($c)) != null)))
  | map(. + {d: ($g != null and .r != null and .t != null and .t > 0 and .t - $g <= 300)});
def cl_bands: {E: sort_by(-.r, .id), B: []}
  | until((.E | length) < 8;
      .E as $E | .B as $B0
      | ($E | group_by(.r) | map({r: .[0].r, n: length}) | sort_by(-.n, -.r) | .[0].r) as $s
      | ({c: $s, k: 0, done: false} | until(.done or .k >= 8;
            .c as $c | .k as $k | ([$E[] | _win($c) | .r] | add / length) as $m
            | if (($m - $c) | _abs) < 0.01 then {c: $c, k: $k, done: true} else {c: $m, k: ($k + 1), done: false} end) | .c) as $c
      | {E: [$E[] | select(.r < $c - 3 or .r > $c + 3)], B: ($B0 + [{c: $c, W: [$E[] | _win($c)]}])})
  | .B;
def cl_bursts: . as $t | [range(0; $t | length) | select(. == 0 or $t[.] - $t[. - 1] > 2)] as $S
  | [range(0; $S | length) as $k | [$t[$S[$k]], $t[(if $k + 1 < ($S | length) then $S[$k + 1] else ($t | length) end) - 1]]];
def cl_tol: (. * 0.1) as $t | if $t > 2 then $t else 2 end;
def cl_expm: (1 - . / 1024) as $y | if $y < 0 then 0 else reduce range(0; 10) as $i ($y; . * .) end;
def cl_chance($n; $T; $c): ($n / $T) as $lam
  | (reduce range(1; 4) as $l ({f: 0, p: $lam, q: 1}; .f += .p * .q | .p *= $lam | .q *= $c / $l)) as $s
  | $n * $s.f * (($lam * $c) | cl_expm) * 2 * ($c | cl_tol);
def cl_hits($S; $c): ($c | cl_tol) as $tol | ($S | length) as $n
  | reduce (range(0; $n) as $i | range($i + 1; (if $n < $i + 4 then $n else $i + 4 end)) as $j | [$i, $j, ($S[$j] - $S[$i])]) as $q
      ({p: [], ab: 0};
       ($q[2] - $c) as $d
       | if ($d | _abs) <= $tol then .p += [{i: $q[0], j: $q[1], x: $q[2]}]
         elif ($d >= -3 * $tol and $d < -$tol) or ($d > $tol and $d <= 3 * $tol) then .ab += 1 else . end)
  | {p: .p, sup: ([.p[] | .i, .j] | unique), side: (.ab / 2)};
def cl_cands: . as $S | ($S | length) as $n
  | ([range(1; 4) as $l | range(0; $n - $l) as $i | ($S[$i + $l] - $S[$i] | round) | select(. >= 15 and . <= 300)]
     | group_by(.) | map({d: .[0], n: length}) | sort_by(-.n, .d)) as $A
  | reduce $A[] as $a ([]; if length >= 6 then . elif any(.[]; . as $c | (($a.d - $c) | _abs) <= ($c | cl_tol)) then . else . + [$a.d] end);
def cl_chain($S; $c; $km): ($S | length) as $n | ($c | cl_tol) as $tol | ($km * $c + $tol) as $reach
  | (reduce (range(0; $n) as $i | $S[$i] as $si | label $out | range($i + 1; $n) as $j
             | (($S[$j] - $si) as $x | if $x > $reach then break $out else [$i, $j, $x] end)) as $q
      ({f: [range(0; $n) | 1], pv: [range(0; $n) | -1], dv: [range(0; $n) | 0], kk: [range(0; $n) | 0]};
       ($q[2]) as $x | ($x / $c | round) as $k
       | if $k < 1 or $k > $km then .
         else (($x - $k * $c) | _abs) as $dev
           | if $dev > $tol then .
             else (.f[$q[0]] + 1) as $L
               | if $L > .f[$q[1]] or ($L == .f[$q[1]] and $dev < .dv[$q[1]])
                 then .f[$q[1]] = $L | .pv[$q[1]] = $q[0] | .dv[$q[1]] = $dev | .kk[$q[1]] = $k else . end
             end
         end)) as $D
  | (reduce range(1; $n) as $i (0; if $D.f[$i] > $D.f[.] then $i else . end)) as $b
  | ({i: $b, idx: [], ks: []} | until(.i < 0; .idx += [.i] | .ks += [$D.kk[.i]] | .i = $D.pv[.i]))
  | {idx: (.idx | reverse), k: (.ks | reverse)};
def cl_need($n; $mu): {x: $n, l: 1} | until(.x <= 0.001 or .l > 400; .x *= $mu | .l += 1) | .l;
def cl_median: sort | .[((length - 1) / 2) | round];
def cl_drop($R; $q): ($q | map({key: tostring, value: 1}) | from_entries) as $m | [range(0; $R | length) | select($m[tostring] | not) | $R[.]];
def cl_streams: . as $S | ($S | length) as $N
  | (reduce range(0; 5) as $pass ({R: [range(0; $N)], out: [], go: true};
      if (.go | not) or (.R | length) < 6 then .go = false else
        .R as $R | [$R[] | $S[.]] as $Sr | ($Sr | length) as $nn | ($Sr[$nn - 1] - $Sr[0]) as $TT
        | [$Sr | cl_cands[] as $c | cl_hits($Sr; $c) as $h
           | ([1, $h.side, (if $TT > 0 then cl_chance($nn; $TT; $c) else 0 end)] | max) as $E
           | (($h.p | length) - $E - 2) as $x | (if $x > 0 then $x * $x / $E else 0 end) as $z2
           | {z2: $z2, c: $c, h: $h, ok: ((($h.p | length) >= 5) and (($h.sup | length) >= 6) and (($h.p | length) >= 2 * ([1, $h.side] | max)) and $z2 >= 36)}] as $all
        | ([$all[] | select(.ok)]) as $ok
        | if ($ok | length) == 0 then .go = false else
            ($ok | sort_by(-.z2, .c) | .[0]) as $b0
            | ([$all | sort_by(.c)[] | select(.c != $b0.c and (.h.p | length) >= 0.8 * ($b0.h.p | length) and (.h.sup | length) >= 6
                 and ((((2 * .c - $b0.c) | _abs) <= ($b0.c | cl_tol)) or (((3 * .c - $b0.c) | _abs) <= ($b0.c | cl_tol))))] | .[0] // $b0) as $best
            | (reduce ($best.h.p[] | .i, .j) as $q ({}; .[$q | tostring] += 1)) as $deg
            | ([$best.h.p[] | (select($deg[.i | tostring] == 1 and $deg[.j | tostring] >= 3) | .i), (select($deg[.j | tostring] == 1 and $deg[.i | tostring] >= 3) | .j)]) as $drop
            | ($drop | map({key: tostring, value: 1}) | from_entries) as $dm
            | ([$best.h.sup[] | select($dm[tostring] | not)]) as $sup
            | if ($sup | length) < 6 then .go = false else
                .out += [{idx: [$sup[] | $R[.]], per: ([$best.h.p[].x] | cl_median | round)}]
                | .R = cl_drop($R; $sup)
              end
          end
      end)) as $T1
  | (reduce range(0; 5) as $pass ($T1 | .go = true;
      if (.go | not) or (.R | length) < 6 then .go = false else
        .R as $R | [$R[] | $S[.]] as $Sr | ($Sr | length) as $n | ($Sr[$n - 1] - $Sr[0]) as $T
        | if ($T > 0 | not) then .go = false else
            (if $pass > 0 then 0.8 else 0.5 end) as $mm
            | ([$Sr | cl_cands[] as $c | ($c | cl_tol) as $tol
                | (reduce range(1; 4) as $km ({prev: 0, stop: false, cands: []};
                    if .stop then .
                    elif ($km * 2 * $tol * $n / $T) > $mm then .stop = true
                    else cl_chain($Sr; $c; $km) as $ch | ($ch.idx | length) as $L
                      | if $L <= .prev then .stop = true
                        else .prev = $L
                          | if $L < 6 then .
                            else ($Sr[$ch.idx[0]]) as $a | ($Sr[$ch.idx[$L - 1]]) as $z | ($z - $a) as $span
                              | if ($span > 0 | not) then .
                                else ([$Sr[] | select(. >= $a and . <= $z)] | length) as $ns
                                  | ($km * 2 * $tol * $ns / $span) as $mu
                                  | if $mu > $mm or $L < (cl_need($ns; $mu) + 3) then . else .cands += [{c: $c, ch: $ch, L: $L}] end
                                end
                          end
                      end
                    end)) | .cands[]]) as $K
            | if ($K | length) == 0 then .go = false else
                ($K | sort_by(-.L, .c) | .[0]) as $best
                | ([range(1; $best.L) | ($Sr[$best.ch.idx[.]] - $Sr[$best.ch.idx[. - 1]]) / $best.ch.k[.]]) as $sp
                | .out += [{idx: [$best.ch.idx[] | $R[.]], per: ($sp | cl_median | round)}]
                | .R = cl_drop($R; $best.ch.idx)
              end
          end
      end)) | .out;
def cl_ongap($cad): (. / $cad | round) as $m
  | $m >= 1 and $m <= 3 and (((. - $m * $cad) | _abs) <= (if 0.1 * $m * $cad > 2 then 0.1 * $m * $cad else 2 end));
def cl_share($cad): [.[][0]] as $st | ($st | length) as $n
  | if $n < 2 then 0 else ([range(1; $n) | select(($st[.] - $st[. - 1]) | cl_ongap($cad))] | length) / ($n - 1) end;
def cl_union($a; $b): ($a + $b | sort_by(.[0])) as $u
  | reduce $u[] as $x ([]; if length > 0 and ($x[0] - .[-1][0]) <= 2 then (if $x[1] > .[-1][1] then .[-1][1] = $x[1] else . end) else . + [[$x[0], $x[1]]] end);
# -> {rnd, clouds: [{c, n, core, cad, nb, share, mean, ids}]}
def cl_kin($p; $q): ([$p, $q] | min) as $lo | ([$p, $q] | max) as $hi | any(range(1; 4); (($hi - . * $lo) | _abs) <= ($hi | cl_tol));
def cl_cov: {st: map(.[0]), mx: (reduce .[] as $y ([]; . + [(if length > 0 and .[-1] > $y[1] then .[-1] else $y[1] end)]))};
def cl_in($c; $t; $pad): ($c.st | bsearch($t + $pad)) as $r | (if $r >= 0 then $r else -2 - $r end) as $i | $i >= 0 and $c.mx[$i] + $pad >= $t;
def clouds: rndfree as $R
  | ([.center.own_bssids[]? | select(type == "string") | pgmac] | .[0:16]) as $own
  | ([$R[] | select(.d) | select(.id as $i | $own | index($i) == null)] | sort_by(-.r, .id)) as $E
  | ($E | cl_bands | map(. as $b | ($b.W | map(.t) | sort_by(.) | cl_bursts | .[-1500:]) as $B | $b + {B: $B, st: ($B | map(.[0]) | cl_streams)})) as $bands
  | ([range(0; $bands | length) as $bi | $bands[$bi] as $b | range(0; $b.st | length) as $si | {bi: $bi, si: $si, b: $b, s: $b.st[$si]}]
     | sort_by(-(.s.idx | length), .bi, .si)) as $cand
  | (reduce $cand[] as $x ([]; . as $acc
      | ($x.s.idx | map($x.b.B[.])) as $cb | ($cb | cl_cov) as $cc
      | ([$x.b.W[] | select(cl_in($cc; .t; 0))]) as $core
      | ([range(0; $acc | length) | select(. as $ai | $acc[$ai] as $A | ($A.cb | cl_cov) as $ac
           | ((($A.c - $x.b.c) | _abs) <= 12)
             and (([$cb[] | select(cl_in($ac; .[0]; 2))] | length) >= 0.6 * ($cb | length)
                  or (cl_kin($A.per; $x.s.per) and (cl_union($A.cb; $cb) | cl_share([$A.per, $x.s.per] | min)) >= 0.8)))] | .[0]) as $d
      | if $d != null then ([.[$d].per, $x.s.per] | min) as $pp | .[$d].per = $pp | .[$d].cad = $pp | .[$d].cs += [$x.b.c] | .[$d].merged += $core | .[$d].cb = cl_union(.[$d].cb; $cb) | .[$d].share = (.[$d].cb | cl_share($pp))
        elif ($core | length) >= 8 then . + [{c: $x.b.c, cs: [$x.b.c], core: $core, merged: [], cb: $cb, cad: $x.s.per, per: $x.s.per, share: ($cb | cl_share($x.s.per))}]
        else . end)) as $acc
  | (reduce ($acc[] | .core[], .merged[] | .id) as $u ({}; .[$u] = 1)) as $used
  | ($acc | map(. + {cv: (.cb | cl_cov)})) as $accs
  | ($E | map(select(. as $e | $used[$e.id] == null)
     | . as $e | . + {k: ([range(0; $accs | length) as $ki | $accs[$ki] as $K
         | select(any($K.cs[]; (($e.r - .) | _abs) <= 6) and cl_in($K.cv; $e.t; 2)) | $ki] | .[0])})) as $L
  | {rnd: ($R | length),
     clouds: [range(0; $acc | length) as $ki | ($acc[$ki].core + $acc[$ki].merged + [$L[] | select(.k == $ki)]) as $M
       | ($M | sort_by(-.r, .id)) as $Ms
       | {c: $acc[$ki].c, n: ($M | length), core: (($acc[$ki].core + $acc[$ki].merged) | length), cad: $acc[$ki].cad, nb: ($acc[$ki].cb | length), share: $acc[$ki].share,
          mean: (($Ms | map(.r) | add) / ($Ms | length)), ids: [$Ms[].id]}]};
'

# Visible failure marker. fetch() sends jq's stderr to /dev/null on purpose (a screen must never print jq
# noise), which is exactly how a missing builtin turned into silently blank counters. jq_healthy makes
# ONE jq call through the same JQLIB path the screens use, on known values, and compares the whole answer
# with the expected array: any jq error (a builtin that is absent or fails when it is called) leaves the
# output empty, so the comparison fails. The probe covers the JQLIB helpers plus add / group_by / sort_by
# (called outside JQLIB by the summary, top and bands filters); --selftest probes each builtin on its own.
# The probe runs once per process (on first use: the first summary, top or bands screen) and the answer is kept
# in JQ_OK, so a draw of the same screen again costs no extra process. In the Overview that first draw says "Reading..."
# before the probe (busy), the probe being the first jq of the draw.
# jq_warn is the one place that turns a failed probe into a red line, called first thing in those three
# screens. When the probe passes it prints nothing, so the healthy output is unchanged.
JQ_PROBE='[(" 5 GHz" | bandnorm), ("6g" | bandnorm), ("WPA2/WPA3" | sectag), ("" | sectag), (null | isopenwep),
          ([[1, 2], [3]] | map(length) | add),
          (["b", "a", "b"] | group_by(.) | map({k: .[0], n: length}) | sort_by(-.n) | .[0].k)]'
JQ_PROBE_WANT='["5","6","WPA3","Open",true,3,"b"]'
JQ_OK=
jq_healthy() {
    if [ -z "$JQ_OK" ]; then
        [ ! -s "$OV_GATE" ] || return 0   # the draw is over (a key came): no probe now, the next draw makes it
        busy
        if [ "$(jq -n -c "$JQLIB$JQ_PROBE" 2>/dev/null)" = "$JQ_PROBE_WANT" ]; then JQ_OK=1; else JQ_OK=0; fi
    fi
    [ "$JQ_OK" = 1 ]
}
jq_warn() { jq_healthy || log red "jq incomplete on this device -- counts may be blank. Run: sh starchorus-display.sh --selftest"; }

# D4 (same wording as the web page): the passivity claim, replaced by the ACTIVE line when the capture
# came from the collector's opt-in active scan (source contains "active" in any case, e.g. iw-scan-ACTIVE).
# ACTIVE holds the "claim" record of the screen just loaded ("true" or empty).
RX_SHORT="rx only"
ACTIVE=
claim() {  # claim [short]
    if [ "$ACTIVE" = true ]; then
        printf '%s\n' "ACTIVE SCAN · the collector sent probe requests"
    elif [ "${1:-}" = short ]; then printf '%s\n' "$RX_SHORT"
    else printf '%s\n' "rx only, nothing sent"; fi
}

age_str() {  # age_str GENERATED -> "42s ago" / "5m ago" / "3h ago" since .generated (unix seconds), or nothing
    g=$1; [ -n "$g" ] || return
    now=$(date +%s 2>/dev/null) || return
    d=$((now - g)); [ "$d" -lt 0 ] && d=0
    if [ "$d" -lt 90 ]; then echo "${d}s ago"; elif [ "$d" -lt 5400 ]; then echo "$((d/60))m ago"; else echo "$((d/3600))h ago"; fi
}

# GEN, the generation counter: moves only when the collector wrote a NEW capture (a different
# `generated`), so a stalled collector shows a stalled GEN. Called with the "gen" record of the screen just loaded.
gen_tick() { if [ -n "$1" ] && [ "$1" != "$LASTG" ]; then GEN=$((GEN + 1)); LASTG=$1; fi; }
crowd_word() { case "$1" in 1) echo quiet ;; 2) echo light ;; 3) echo moderate ;; 4) echo busy ;; *) echo "very busy" ;; esac; }

# ------------------------------------------------------------------ screens
# Every screen appends a fresh LOG block stamped with GEN: the device log cannot redraw in place.
# Each one names its jq program (JQ_<SCREEN>), which returns the "gen" record plus whatever the screen shows.
ready() { fetch "$1" "$2" || { nodata; return 1; }; gen_tick "$R_gen"; }

# summary: D1 freshness (the page's four stages and words, ENCODING.fresh.words; undated = no capture time,
# last_seen <= 0, or later than generated + 300 s, counted and named) and D11 crowding 1-5 (the busiest channel's
# overlap, the sum of rssiT over the APs whose span overlaps its own 20 MHz, against [1.5, 3, 5, 8]; the same words
# as the page's Air drawer) as records, next to the plain counts. "bz" is "2.4 GHz ch 6": the FIRST channel of
# chloads with the highest load, i.e. the page's crowdingOf (strict ">" over bands 2.4, 5, 6 and, per band, the
# channels in the order they first appear in S.apOrder). Not max_by: it keeps the LAST maximum, which would name a
# different channel than the page on every tie. "interval" (center.interval) is for stale_line below.
JQ_SUMMARY='_D(
  (try chloads catch null) as $cl | (try [.aps[] | (.band | bandnorm)] catch null) as $B | (try clouds catch null) as $CL
  | _R("gen"; .generated // empty),
    _R("interval"; .center.interval // empty),
    _R("aps"; .aps | length),
    _R("open"; [.aps[] | select(.security | isopenwep)] | length),
    _R("free"; .unassociated | length),
    _R("rnd"; $CL.rnd // empty), _R("ncl"; ($CL.clouds // empty) | length),
    _R("assoc"; [.aps[].clients // [] | length] | add // 0),
    _R("b24"; bandcnt($B; "2.4")), _R("b5"; bandcnt($B; "5")), _R("b6"; bandcnt($B; "6")),
    _R("probing"; [probers] | length),
    _R("center"; .center.label // "This device" | _chomp),
    _R("claim"; (.source // "") | tostring | ascii_downcase | contains("active")),
    _R("fresh"; (.generated | if type == "number" then . else null end) as $g | [.aps[] | apprep | tierof($g)] as $t
       | [range(0;4) as $i | ($t | map(select(. == $i)) | length)] as $c | ($t | map(select(. == null)) | length) as $u
       | "heard < 1 min \($c[0]) · heard < 5 min \($c[1]) · heard < 15 min \($c[2]) · on record \($c[3])" + (if $u > 0 then " · undated \($u)" else "" end)),
    _R("lvl"; [$cl[].load] | (max // 0) as $m | 1 + ([1.5, 3, 5, 8] | map(select($m >= .)) | length)),
    _R("bz"; $cl | _busiest | if . == null then "" else .b + " GHz ch " + (.ch + 0 | tostring) end))'
# rnd_note: RN = " (N random, K clouds)" from the rnd / ncl records of the screen just loaded; empty without a randomised free station
rnd_note() {
    RN=
    case ${R_rnd:-} in ''|0|*[!0-9]*) return 0 ;; esac
    case ${R_ncl:-0} in 0|''|*[!0-9]*) RN=" ($R_rnd random)" ;; 1) RN=" ($R_rnd random, 1 cloud)" ;; *) RN=" ($R_rnd random, $R_ncl clouds)" ;; esac
}
screen_summary() {   # 1 = no data yet (the waiting line, or the two slow lines, were printed instead)
    jq_warn
    if ! fetch summary "$JQ_SUMMARY"; then nodata; return 1; fi
    gen_tick "$R_gen"
    aps=$R_aps; open=$R_open; free=$R_free; assoc=$R_assoc
    b24=$R_b24; b5=$R_b5; b6=$R_b6; probing=$R_probing
    center=$R_center; ACTIVE=$R_claim; lvl=$R_lvl; bz=$R_bz
    a=$(age_str "$R_gen")
    log blue  "Starchorus  ~  $center"
    log       "GEN $GEN ${a:+· $a}  ($(claim))"
    log       "APs $aps   ·   2.4:$b24  5:$b5  6:$b6"
    rnd_note
    log       "Clients  $free free$RN · $assoc associated"
    log       "$R_fresh"
    log       "Crowding ${lvl:-1}/5 ($(crowd_word "${lvl:-1}"))${bz:+ · busiest $bz}"
    [ "${probing:-0}" -gt 0 ] && log "Probe requests: $probing client(s) naming a network"
    if [ "${open:-0}" -gt 0 ]; then log red "Open/WEP networks: $open"; else log "No open/WEP networks"; fi
    tpl_line "$aps" "$b24" "$b5" "$b6" "${open:-0}" "${lvl:-1}"
}

JQ_TOP='_D(
  _R("gen"; .generated // empty),
  _R("top"; [.aps[] | {s:((.ssid // "") | oneline), b:(.band | bandnorm), r:(.rssi // -99), sec:((.security // "") | oneline), a:(.security | isopenwep)}]
      | sort_by(.r) | reverse | .[0:8][]
      | (if .a then "!" else " " end) + (.r|tostring) + " dBm  " + (if .s=="" then "<hidden>" else .s end) + "  " + .b + "G  " + .sec))'
screen_top() {   # strongest networks by RSSI
    jq_warn; ready top "$JQ_TOP" || return
    log blue "Strongest networks (GEN $GEN)"
    # the alarm is decided HERE, from the security field (isopenwep, the rule of the summary's Open/WEP count), and carried
    # as a leading "!" / " ", never by searching the rendered line: with the SSID included a WPA2 "OpenWrt" would come out
    # red and an AP with security "" (open, as the summary and the page count it) would not
    rec_lines top \
      | while IFS= read -r line; do
            case "$line" in '!'*) log red "${line#?}" ;; *) log "${line#?}" ;; esac
        done
}

JQ_BANDS='_D(
  (try [.aps[] | (.band | bandnorm)] catch null) as $B
  | _R("gen"; .generated // empty),
    _R("b24"; bandcnt($B; "2.4")), _R("b5"; bandcnt($B; "5")), _R("b6"; bandcnt($B; "6")),
    _R("sec"; [.aps[] | (.security | sectag)]
        | group_by(.) | map({k:.[0], n:length}) | sort_by(-.n) | .[]
        | "  " + .k + ": " + (.n|tostring)))'
screen_bands() {   # band split + security tally
    jq_warn; ready bands "$JQ_BANDS" || return
    log blue "Bands & security (GEN $GEN)"
    log "  2.4 GHz: ${R_b24:-0} AP(s)"
    log "  5 GHz: ${R_b5:-0} AP(s)"
    log "  6 GHz: ${R_b6:-0} AP(s)"
    rec_lines sec \
      | while IFS= read -r line; do
            case "$line" in *"Open:"*|*"WEP:"*) log red "$line" ;; *) log "$line" ;; esac
        done
}

# G1/G2 (device bundling + ESS), a simplified on-glass count of the visualiser's heuristic (the full
# union-find lives in the HTML). Device = >= 2 BSSIDs sharing bytes 0-4, locally administered ones
# excluded; ESS = one SSID seen under >= 2 distinct bytes-0-4 prefixes.
JQ_DEVICES='_D(
  (try ([ .aps[] | select(.bssid) | {bssid:(.bssid|ascii_downcase), ssid:(.ssid // "")} ]
        | map(. + { oui:(.bssid[0:8]), pfx:(.bssid[0:11]),
                    ul:( (.bssid[1:2]) as $c | ($c=="2" or $c=="6" or $c=="a" or $c=="e") ) })
        | map(select(.ul|not))
        | group_by(.pfx) | map(select(length>=2))) catch null) as $dl
  | _R("gen"; .generated // empty),
    _R("ndev"; $dl | length),
    _R("ess"; [ .aps[] | select((.ssid // "")!="") | {ssid:.ssid, dev:((.bssid // "")|ascii_downcase|.[0:11])} ]
        | group_by(.ssid) | map({ssid:.[0].ssid, devs:( [.[].dev] | unique | length)})
        | map(select(.devs>=2)) | length),
    _R("devl"; $dl | .[0:4][] | "  dev " + .[0].oui + "xx  (" + (length|tostring) + " radios)  " + (.[0].ssid|if .=="" then "<hidden>" else . end)))'
screen_devices() {
    ready devices "$JQ_DEVICES" || return
    log blue "Logical grouping (GEN $GEN)"
    log "Devices (multi-BSSID / multi-radio): ${R_ndev:-0}"
    log "Merged SSIDs (one name, >=2 devices): ${R_ess:-0}"
    [ "${R_ndev:-0}" -gt 0 ] && rec_lines devl | logeach
}

JQ_PROBES='_D(
  _R("gen"; .generated // empty),
  _R("claim"; (.source // "") | tostring | ascii_downcase | contains("active")),
  _R("n"; [probers] | length),
  _R("plist"; [probers | .probes[]]
      | group_by(.) | map({k:.[0], n:length}) | sort_by(-.n) | .[0:8][]
      | "  " + .k + "  (x" + (.n|tostring) + ")"))'
screen_probes() {   # who is looking for which network (probe requests, rx only)
    ready probes "$JQ_PROBES" || return
    ACTIVE=$R_claim
    log blue "Probe requests (GEN $GEN)  $(claim short)"
    if [ "${R_n:-0}" -eq 0 ]; then log "No probe requests naming a network."; return; fi
    log "$R_n client(s) probing:"
    rec_lines plist | logeach
}

# Stations: the strongest client MACs, rx only (a MAC is display, never transmission). Every
# optional field is coalesced; the total tie-break (-.r, .mac) makes the order deterministic. The addresses of a random cloud
# (see clouds above) are one line at the cloud's mean signal, sorted before a station of the same signal (its key is "").
JQ_CLIENTS='_D(
  (try clouds catch null) as $CL
  | _R("gen"; .generated // empty),
    _R("claim"; (.source // "") | tostring | ascii_downcase | contains("active")),
    _R("free"; .unassociated | length),
    _R("rnd"; $CL.rnd // empty), _R("ncl"; ($CL.clouds // empty) | length),
    _R("assoc"; [.aps[].clients // [] | length] | add // 0),
    _R("clist"; ([$CL.clouds[]?.ids[]]) as $IN
      | [ (.aps[] | .bssid as $b | (.clients // [])[] | {mac:(.mac // "?"), r:(.rssi // -99), a:$b, np:0}),
          (.unassociated[] | select(.mac == null or ((.mac | pgmac) as $p | $IN | index($p)) == null)
           | {mac:(.mac // "?"), r:(.rssi // -99), a:null, np:((.probes // []) | length)}),
          ($CL.clouds[]? | {mac: "", r: (.mean | round), a: null, np: 0, k: .n}) ]
      | sort_by(-.r, .mac) | .[0:8][]
      | if .k != null then (.r|tostring) + " dBm  cloud of \(.k) random addresses"
        else (.r|tostring) + " dBm  " + .mac + "  " + (if .a then "assoc " + .a else (if .np>0 then "probing" else "free" end) end) end))'
screen_clients() {
    ready clients "$JQ_CLIENTS" || return
    ACTIVE=$R_claim
    log blue "Stations (GEN $GEN)  $(claim short)"
    rnd_note
    log "  ${R_free:-0} free$RN · ${R_assoc:-0} associated"
    rec_lines clist | logeach
}

# Air quality: the page's Air drawer as a LOG block. Per band the busiest channels (overlap load) with
# co-/adjacent-channel counts, the least occupied of the usual set, and the beacon airtime as an
# ESTIMATED lower bound (one beacon per AP every 102.4 ms, 200 bytes at 1 Mbit/s on 2.4 GHz or
# 6 Mbit/s on 5/6 GHz).
# On the page's model, like the summary's crowding line: pgaps (duplicates merged, a missing RSSI = -75 dBm,
# band from freq/channel when the band field says nothing), channels ranked on the ROUNDED load (ld2) then the channel
# number, and the beacon estimate rounded per channel before the band sum (airQuality's beaconPctSum).
# pgaps runs once for the crowding level and the three band blocks.
JQ_AIR='def _air($A; $b):
    [$A[] | select(.b == $b and .ch != null)] as $P | ($P | length) as $n
    | if $n == 0 then "  \($b) GHz: no APs"
      else ([$P[].ch] | unique) as $C
        | ($C | map({ch: ., l: (chload($A; $b; .) | . + {load: (.load | ld2)})}) | sort_by(-.l.load, .ch) | .[0:3]) as $top
        | (if $b == "2.4" then [1,6,11] elif $b == "5" then [36,40,44,48,149,153,157,161,165] else [] end | map({ch: ., l: (chload($A; $b; .) | . + {load: (.load | ld2)})}) | sort_by(.l.load, .ch) | .[0]) as $q
        | ($C | map(. as $c | beaconpct($b; [$P[] | select(.ch == $c)] | length)) | add | . * 10 | round / 10) as $bp
        | "  \($b) GHz: \($n) APs · beacons >= \($bp)% (est.)",
          ($top[] | "    ch \(.ch): \(.l.co) co · \(.l.adj) adjacent"),
          (if $q == null then empty else "    least occupied: ch \($q.ch)" end)
      end;
  _D(
  (try pgaps catch null) as $A
  | _R("gen"; .generated // empty),
    _R("lvl"; chloads_of($A) | [.[].load] | (max // 0) as $m | 1 + ([1.5, 3, 5, 8] | map(select($m >= .)) | length)),
    _R("a24"; _air($A; "2.4")), _R("a5"; _air($A; "5")), _R("a6"; _air($A; "6")))'
screen_air() {
    ready air "$JQ_AIR" || return
    lvl=$R_lvl
    log blue "Air quality (GEN $GEN)"
    log "The air is $(crowd_word "${lvl:-1}") · crowding ${lvl:-1}/5"
    for band in a24 a5 a6; do rec_lines "$band" | logeach; done
    log "estimate: 1 beacon per AP / 102.4 ms, 200 B, 1 Mbit/s (2.4) or 6 Mbit/s (5, 6)"
}

# Optional one-line template (operator-editable plain text; STARCHORUS_DISPLAY_TEMPLATE, else the first line of
# $STARCHORUS_DIR/display.tpl): {aps} {b24} {b5} {b6} {open} {crowding} {gen}. Only numbers are substituted;
# nothing else is read from the capture.
tpl_line() {   # tpl_line aps b24 b5 b6 open crowding
    t=${STARCHORUS_DISPLAY_TEMPLATE:-$(head -n 1 "$STARCHORUS_DIR/display.tpl" 2>/dev/null)}
    [ -n "$t" ] || return 0
    printf '%s\n' "$t" | sed -e "s/{aps}/$1/g" -e "s/{b24}/$2/g" -e "s/{b5}/$3/g" -e "s/{b6}/$4/g" -e "s/{open}/$5/g" -e "s/{crowding}/$6/g" -e "s/{gen}/$GEN/g" | cut -c1-80 | logeach
}

# ------------------------------------------------------------------ the frame that ends every draw
# Nothing on the screen refreshes by itself, so every screen says how old its numbers are.
# scan_age -> SA_G (the capture's `generated`), SA_D (its age in seconds, 0 at the least) and SA_LIM (three of the collector's
# intervals: center.interval of the capture, which only the summary's program reads, so the last value it gave is kept in
# OV_INT for the other screens; else STARCHORUS_INTERVAL, else 30 s). Status 1: this screen has no usable capture time (no
# capture, a waiting screen) or the box has no clock. It reads the "gen" and "interval" records the screen has just loaded
# and takes one `date`: no jq of its own, so a draw of an unchanged capture runs none.
scan_age() {
    sg=${R_gen-}; case $sg in ''|*[!0-9]*) return 1 ;; esac
    [ "${#sg}" -le 11 ] || return 1
    si=${R_interval-}; case $si in ''|0|*[!0-9]*) si=${OV_INT:-${STARCHORUS_INTERVAL:-30}} ;; esac
    case $si in ''|0|*[!0-9]*) si=30 ;; esac
    now=$(date +%s 2>/dev/null) || return 1
    case $now in ''|*[!0-9]*) return 1 ;; esac
    SA_G=$sg; SA_D=$((now - sg)); [ "$SA_D" -ge 0 ] || SA_D=0; SA_LIM=$((3 * si))
}
# age_words SECONDS -> AW: "42 s", "5 min" or "3 h"
age_words() {
    if [ "$1" -lt 120 ]; then AW="$1 s"; elif [ "$1" -lt 7200 ]; then AW="$(($1 / 60)) min"; else AW="$(($1 / 3600)) h"; fi
}
# stale_line -> the red line, and status 0, when the collector has not written a capture for more than three of its
# intervals (see scan_age); status 1 and nothing printed otherwise
stale_line() {
    [ "$SA_D" -gt "$SA_LIM" ] || return 1
    age_words "$SA_D"; st=$AW
    log red "No new scan for $st."
}
# stamp -> the line that dates the screen: "Last scan 12:04:31 (42 s ago)", the time of `generated` in UTC as the page shows
# it (shell arithmetic on the epoch, no process) and the age by the rule of stale_line; the red line replaces it when the
# scan is too old; no capture, no line
stamp() {
    scan_age || return 0
    stale_line && return 0
    ls_t=$((SA_G % 86400)); ls_h=$((ls_t / 3600)); ls_m=$((ls_t % 3600 / 60)); ls_s=$((ls_t % 60))
    case $ls_h in ?) ls_h=0$ls_h ;; esac; case $ls_m in ?) ls_m=0$ls_m ;; esac; case $ls_s in ?) ls_s=0$ls_s ;; esac
    age_words "$SA_D"
    log "Last scan $ls_h:$ls_m:$ls_s ($AW ago)"
}
# frame VIEW -> the last lines of every draw: when the scan was made, the keys, and on the summary the page's address
# when the payload serves one
frame() {
    case ${R_interval-} in ''|0|*[!0-9]*) ;; *) OV_INT=$R_interval ;; esac
    stamp
    log "A: Refresh   B: Back"
    if [ "$1" = summary ]; then
        fu=${STARCHORUS_PAGE_URL:-}; fu=${fu#http://}; fu=${fu%/}
        [ -z "$fu" ] || log "Web page: $fu"
    fi
}

# ------------------------------------------------------------------ --selftest (read-only device check)
# sh starchorus-display.sh --selftest       (over ssh or from a shell on the device; sends nothing, reads no capture)
# One "[display-selftest]   PASS: name" or "[display-selftest]   FAIL: name" line per check, then a last line
# "[display-selftest] SELFTEST: ALL PASS (N checks)" or "[display-selftest] SELFTEST: FAILED (k of N)"; exit 0
# only when every check passed. Written with printf straight to stdout, not through log(): it is meant to
# be read in a terminal. It runs the REAL JQLIB text above (never a copy) through the jq on PATH, in three
# layers so a failing jq shows WHICH piece is wrong: (1) one probe per jq builtin / syntax form the
# filters use, each on its own line; (2) a small table of bandnorm / secupper / isopenwep / sectag inputs
# (modelled on the oracle in tools/regress.d/jq-noregex.sh, far smaller); (3) the jq_healthy probe and
# screen_summary over a tiny embedded fixture. INFO lines are informational and never change the verdict.
# The one file it writes is that fixture (mktemp); a trap removes it again, also on INT/TERM.
ST_N=0; ST_FAIL=0; ST_TMP=
st_pass() { ST_N=$((ST_N + 1)); printf '[display-selftest]   PASS: %s\n' "$1"; }
st_fail() { ST_N=$((ST_N + 1)); ST_FAIL=$((ST_FAIL + 1)); printf '[display-selftest]   FAIL: %s\n' "$1"; }
st_info() { printf '[display-selftest]   INFO: %s\n' "$1"; }
# st_ck NAME WANT GOT RC: PASS iff jq exited 0 AND its compact output is exactly WANT (a jq that failed
# cannot pass by printing nothing); on FAIL the first line of what jq said is kept, it names the culprit.
st_ck() {
    if [ "$4" -eq 0 ] && [ "$3" = "$2" ]; then st_pass "$1"
    else st_fail "$1  (want $2, got: $(printf '%s\n' "$3" | sed -n 1p | cut -c1-90))"; fi
}
st_probe() {  # st_probe NAME 'FILTER' 'WANT-JSON': one builtin on its own, nothing else in the way
    st_got=$(jq -n -c "$2" 2>&1); st_rc=$?
    st_ck "jq $1" "$3" "$st_got" "$st_rc"
}
st_lib() {  # st_lib FN 'INPUT-JSON' 'WANT-JSON': FN of the real JQLIB applied to INPUT
    st_got=$(printf '%s\n' "$2" | jq -c "$JQLIB$1" 2>&1); st_rc=$?
    st_ck "$1 $2 -> $3" "$3" "$st_got" "$st_rc"
}
st_has() {  # st_has NAME TEXT grep-args...: PASS iff grep finds its pattern in TEXT (else show the counter lines)
    st_name=$1; st_text=$2; shift 2
    if printf '%s\n' "$st_text" | grep "$@" >/dev/null 2>&1; then st_pass "$st_name"
    else st_fail "$st_name  (got: $(printf '%s\n' "$st_text" | grep -E '^(APs |Open/WEP|No open/WEP|jq incomplete)' | tr '\n' '|'))"; fi
}
st_verdict() {
    if [ "$ST_FAIL" -eq 0 ]; then printf '[display-selftest] SELFTEST: ALL PASS (%s checks)\n' "$ST_N"; return 0; fi
    printf '[display-selftest] SELFTEST: FAILED (%s of %s)\n' "$ST_FAIL" "$ST_N"; return 1
}

display_selftest() {
    ONDEV=0   # plain-text path: log() prints to stdout, which is what the screen_summary check captures
    SINCE_JQ=   # the fixture carries no capture time: a STARCHORUS_SINCE in the environment must not turn it into no data
    trap '[ -z "$ST_TMP" ] || rm -f "$ST_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if command -v jq >/dev/null 2>&1; then st_pass "jq present"; else
        st_fail "jq present"; st_info "no jq on PATH: every other check needs it, so they are skipped"
        st_verdict; return
    fi
    st_info "jq version: $(jq --version 2>&1 | sed -n 1p)"
    # No regex builtin is called anywhere in this file, the selftest included (see the no-regex rule above).

    # (1) every builtin / syntax form the JQLIB helpers and the screen filters rely on, one line each
    st_probe "builtin endswith" '[("5ghz" | endswith("ghz")), ("5ghz" | endswith("g5")), ("" | endswith("g"))]' '[true,false,false]'
    st_probe "builtin until" '[0 | until(. >= 3; . + 1)]' '[3]'
    st_probe "builtin index" '[([" ", "a"] | index(" ")), ([" ", "a"] | index("z"))]' '[0,null]'
    st_probe "builtin string slice .[a:b]" '["abcd" | .[:-1], .[0:1], .[-1:], .[1:3]]' '["abc","a","d","bc"]'
    st_probe "builtin array slice .[a:b]" '[[1, 2, 3, 4] | .[0:2], .[-1:]]' '[[1,2],[4]]'
    st_probe "builtin tostring" '[(5 | tostring), ("a" | tostring), (null | tostring), (true | tostring)]' '["5","a","null","true"]'
    st_probe "builtin ascii_downcase" '"AbC 5" | ascii_downcase' '"abc 5"'
    st_probe "builtin ascii_upcase" '"AbC 5" | ascii_upcase' '"ABC 5"'
    st_probe "builtin rtrimstr" '[("abcghz" | rtrimstr("ghz")), ("abc" | rtrimstr("x"))]' '["abc","abc"]'
    st_probe "builtin ltrimstr" '[("xxabc" | ltrimstr("xx")), ("abc" | ltrimstr("x"))]' '["abc","abc"]'
    st_probe "builtin contains" '[("WPA2" | contains("PA")), ("WPA2" | contains("X"))]' '[true,false]'
    st_probe "builtin startswith" '[("WPA2" | startswith("WP")), ("WPA2" | startswith("PA"))]' '[true,false]'
    st_probe "builtin split/1" '"a,b,c" | split(",")' '["a","b","c"]'
    st_probe "builtin group_by" '[1, 2, 1] | group_by(.)' '[[1,1],[2]]'
    st_probe "builtin sort_by" '[([{"r": 2}, {"r": 1}] | sort_by(.r) | map(.r)), ([{"n": 1}, {"n": 3}] | sort_by(-.n) | map(.n))]' '[[1,2],[3,1]]'
    st_probe "builtin reverse" '[1, 2, 3] | reverse' '[3,2,1]'
    st_probe "builtin unique" '[3, 1, 3] | unique' '[1,3]'
    st_probe "builtin add" '[([1, 2] | add), ([] | add // 0)]' '[3,0]'
    st_probe "builtin select" '[1, 2, 3] | map(select(. > 1))' '[2,3]'
    st_probe "syntax // (alternative operator)" '[(null // "x"), (false // "y"), ("z" // "w")]' '["x","y","z"]'
    st_probe "syntax \uXXXX escapes in string literals" '["\u0041", ("\u00A0\u3000\uFEFF" | length)]' '["A",3]'
    # the same for what the freshness, crowding, stations and air-quality screens use
    st_probe "builtin map" '[1, 2, 3] | map(. * 2)' '[2,4,6]'
    st_probe "builtin max" '[([3, 1, 2] | max), ([] | max)]' '[3,null]'
    # the random clouds' rule (§8.8a): bisection for the bursts' cover, a lookup object, an early end of a scan, a reduce over pairs
    st_probe "builtin bsearch" '[([1, 3, 5] | bsearch(3)), ([1, 3, 5] | bsearch(4)), ([] | bsearch(1))]' '[1,-3,-1]'
    st_probe "builtin from_entries" '[{"key": "1", "value": 1}] | from_entries' '{"1":1}'
    st_probe "builtin any/2" '[([1, 2] | any(.[]; . > 1)), ([1, 2] | any(.[]; . > 2))]' '[true,false]'
    st_probe "syntax label / break" '[label $out | range(0; 5) | if . > 2 then break $out else . end]' '[0,1,2]'
    st_probe "syntax reduce over a generator" '[reduce (range(0; 3) as $i | range(0; 2) as $j | $i * $j) as $q (0; . + $q)]' '[3]'
    st_probe "builtin range" '[range(0; 3)]' '[0,1,2]'
    st_probe "builtin round" '[(2.5 | round), (1.24 | round)]' '[3,1]'
    st_probe "builtin type" '[(1 | type), ("a" | type), (null | type)]' '["number","string","null"]'
    st_probe "builtin not / empty" '[(true | not), (false | not), ([1, empty, 2] | length)]' '[false,true,2]'
    st_probe "builtin sort_by with several keys" '[([{"r": 1, "m": "b"}, {"r": 1, "m": "a"}, {"r": 2, "m": "c"}] | sort_by(-.r, .m) | map(.m)), ([{"l": 1, "c": 6}, {"l": 1, "c": 1}, {"l": 0, "c": 11}] | sort_by([.l, .c]) | map(.c))]' '[["c","a","b"],[11,1,6]]'
    st_probe "syntax string interpolation" '"a\(1 + 1)b"' '"a2b"'
    st_probe "syntax def with \$parameters" 'def f($a; $b): $a + $b; f(1; 2)' '3'
    # the page-order channel model (chloads) merges duplicate BSSIDs with group_by and takes the FIRST non-empty value
    # the record helpers of JQLIB (_R) keep what a value printed before it failed
    st_probe "syntax try (keeps the outputs before an error)" '[try (1, error("x"), 3)]' '[1]'
    # the SINCE gate goes in front of a screen's program, and the Air program begins with a def of its own
    st_probe "syntax def after a pipe (the SINCE gate in front of a program)" '[1 | def f: . + 1; f]' '[2]'
    st_probe "builtin group_by keeps the input order inside a group" '[{"k": 2, "v": "a"}, {"k": 1, "v": "b"}, {"k": 2, "v": "c"}] | group_by(.k) | map(map(.v))' '[["b"],["a","c"]]'

    # (2) what the JQLIB helpers MEAN, on a small fixed table (input and expected value are JSON)
    st_lib bandnorm '"2.4GHz"' '"2.4"'
    st_lib bandnorm '" 5 GHz"' '"5"'
    st_lib bandnorm '"5GHZ"' '"5"'
    st_lib bandnorm '"6g"' '"6"'
    st_lib bandnorm '"5"' '"5"'
    st_lib bandnorm '"5\u00A0GHz"' '"5"'
    st_lib bandnorm '""' '""'
    st_lib bandnorm 'null' '""'
    st_lib secupper '"wpa2"' '"WPA2"'
    st_lib isopenwep '""' 'true'
    st_lib isopenwep '"OPEN"' 'true'
    st_lib isopenwep '"WEP"' 'true'
    st_lib isopenwep '"WPA2"' 'false'
    st_lib sectag '"WPA2/WPA3"' '"WPA3"'
    st_lib sectag '"SAE"' '"WPA3"'
    st_lib sectag '"OWE"' '"OWE"'
    st_lib sectag '"RSN"' '"WPA2"'
    st_lib sectag '"WEP"' '"WEP"'
    st_lib sectag '""' '"Open"'
    st_lib sectag '"CCMP"' '"other"'
    # busiest = the page's crowdingOf on a tie: ch 1 and ch 11 carry the same load, ch 1 holds the lower BSSID, so the page
    # meets it first and keeps it (jq max_by would keep the LAST maximum, ch 11)
    # clouds = the page's random clouds (§8.8a): twenty bursts of two addresses at -40 dBm, one every 50 s, are one cloud of 40 (the two at -70 stay single); at irregular times there is none
    ST_CL='{generated: 1000, aps: [], unassociated: ([range(0; 20) as $k | range(0; 2) as $j | {mac: "02:00:00:00:\(("0" + ($k|tostring))[-2:]):\(("0" + ($j|tostring))[-2:])", rssi: (-40 - $j), last_seen: LS}] + [{mac: "02:00:00:00:d0:01", rssi: -70, last_seen: 990}, {mac: "02:00:00:00:d0:02", rssi: -71, last_seen: 990}])} | clouds | [.rnd, (.clouds | length), (.clouds[0].n // 0)]'
    st_lib "$(printf '%s' "$ST_CL" | sed 's/LS/(50 + 50 * $k)/')" '{}' '[42,1,40]'
    st_lib "$(printf '%s' "$ST_CL" | sed 's/LS/(50 + [4,611,97,402,333,508,89,720,251,19,660,145,380,570,60,830,205,455,700,120][$k])/')" '{}' '[42,0,0]'
    st_lib 'busiest | [.b, .ch]' '{"aps":[{"bssid":"02:00:00:00:00:02","rssi":-60,"channel":11,"band":"2.4"},{"bssid":"02:00:00:00:00:01","rssi":-60,"channel":1,"band":"2.4"}]}' '["2.4",1]'

    # (3) the marker's own probe, then the whole screen: a jq without a needed builtin would break exactly this output
    if jq_healthy; then st_pass "jq_healthy probe (the failure marker's own test)"
    else st_fail "jq_healthy probe (the failure marker's own test)"; fi
    ST_TMP=$(mktemp "${TMPDIR:-/tmp}/starchorus-display-st.XXXXXX" 2>/dev/null) || ST_TMP=
    if [ -n "$ST_TMP" ]; then
        # synthetic fixture: locally administered dummy BSSIDs, no real network data
        cat > "$ST_TMP" <<'ST_JSON'
{"source":"selftest","center":{"label":"selftest"},"unassociated":[],
 "aps":[{"bssid":"02:00:00:00:00:01","ssid":"Test-A","rssi":-40,"band":"2.4GHz","security":"WPA2/WPA3"},
        {"bssid":"02:00:00:00:00:02","ssid":"Test-B","rssi":-50,"band":" 5 GHz","security":"Open"},
        {"bssid":"02:00:00:00:00:03","ssid":"Test-C","rssi":-60,"band":"5","security":"WEP"},
        {"bssid":"02:00:00:00:00:04","ssid":"Test-D","rssi":-70,"band":"6g","security":"WPA3"}]}
ST_JSON
        JSON=$ST_TMP
        st_out=$(screen_summary 2>&1)
        rm -f "$ST_TMP"; ST_TMP=
        st_has "screen_summary: band counters are digits" "$st_out" -Eq '2\.4:[0-9]+ +5:[0-9]+ +6:[0-9]+'
        st_has "screen_summary: band counts match the fixture (2.4:1 5:2 6:1)" "$st_out" -qF '2.4:1  5:2  6:1'
        st_has "screen_summary: open/WEP line matches the fixture (2)" "$st_out" -qxF 'Open/WEP networks: 2'
    else
        st_fail "screen_summary end-to-end (no temp file for the fixture)"
    fi
    st_verdict
}

# ------------------------------------------------------------------ main loop
render() {
    case "$1" in
        top|bands|devices|probes|clients|air) "screen_$1" ;;
        *) screen_summary ;;
    esac
}

# --selftest is dispatched BEFORE the jq gate on purpose: without jq it still has to print "FAIL: jq present"
# and the FAILED line (exit 1) instead of taking the err_dialog + exit 1 path of a normal run.
if [ "${1:-}" = "--selftest" ]; then display_selftest; exit $?; fi

if [ "$1" = "--once" ]; then
    command -v jq >/dev/null 2>&1 || { err_dialog "Overview needs jq."; exit 1; }
    [ -n "$3" ] && JSON=$3
    render "$2"
    exit 0
fi

# draw VIEW: one screen as its block of LOG lines and, last, its frame. A draw that has to run jq says "Reading..." first (busy(),
# once per draw). It runs with a key wait already open (arm). The wait takes one key, so the draw ends with it: while a draw runs,
# OV_GATE names the key file, and log(), fetch() and jq_healthy() do nothing once that file holds an answer (a jq that is running
# is ended by ov_jq); frame is not started. The status is 1 for a draw that was ended that way, 0 for a whole one: the loop draws
# a screen again after a key that asked for nothing (Up, Down, a strike) only when its draw was cut, so no half screen is left as the
# last thing on the console. R_gen and R_interval are cleared first: a screen that has nothing to show (waiting, slow) must not borrow
# the time of the screen before.
draw() {
    OV_BUSY=0; FX_SLOW=0; unset R_gen R_interval
    OV_GATE=$OV_KEYF
    render "$1"
    [ -s "$OV_KEYF" ] || frame "$1"
    OV_GATE=
    [ ! -s "$OV_KEYF" ]
}

# The screens in the order of the list and of Left / Right, wrapping round at both ends. step sets view to the neighbour,
# row_of names the list row of the current view, view_of turns a list answer back into a view (status 1: not one of ours).
step() {
    case $1$view in
        RIGHTsummary) view=top ;; RIGHTtop) view=bands ;; RIGHTbands) view=devices ;; RIGHTdevices) view=probes ;;
        RIGHTprobes) view=clients ;; RIGHTclients) view=air ;; RIGHTair) view=summary ;;
        LEFTsummary) view=air ;; LEFTtop) view=summary ;; LEFTbands) view=top ;; LEFTdevices) view=bands ;;
        LEFTprobes) view=devices ;; LEFTclients) view=probes ;; LEFTair) view=clients ;;
    esac
}
row_of() {
    case $view in
        top) ROW="Strongest Networks" ;; bands) ROW="Bands & Security" ;; devices) ROW="Devices & Merges" ;;
        probes) ROW="Probe Requests" ;; clients) ROW=Stations ;; air) ROW="Air Quality" ;; *) ROW=Summary ;;
    esac
}
view_of() {
    case $1 in
        Summary) view=summary ;; "Strongest Networks") view=top ;; "Bands & Security") view=bands ;;
        "Devices & Merges") view=devices ;; "Probe Requests") view=probes ;; Stations) view=clients ;;
        "Air Quality") view=air ;; *) return 1 ;;
    esac
}

# The Overview. On the device the first things that happen are the traps, the private temp dir and the first arm, and only then the
# first line (before any jq call, so the screen still answers at once): the wait is registered while the heading goes out, not after
# it, which is the one stretch the start can keep unarmed. Then every pass of the loop is arm, draw, take, with parent_gone asked once
# per pass (after take, which is also before the next arm; a second time after the list, which can take as long as a person likes): a
# key wait is opened in the background, the screen is drawn while it waits (a draw ends as soon as a key has come), and take collects
# the answer. The first pass draws the summary; after that nothing is drawn unless a key asks for it. A draws the same screen
# again, B goes up one level (a screen -> the list "Overview" with its cursor on that screen -> exit 0, back to the payload's menu),
# LEFT and RIGHT step through the screens, UP and DOWN are ignored (the wait is armed again, nothing is drawn, unless the draw they
# came in was cut: then the screen is drawn again), anything else is a strike when it came back within 1 s of its arm (STRIKE_CS)
# or when there is no clock to tell, and the third in a row ends the Overview: an empty answer at once means the key path is broken,
# and this must not become a busy loop. The same answer after a real wait (a second or more) is a UI that took its time: the wait is
# simply opened again and the count starts over. The list "Overview" is a wait of its own, so no waiter is armed while it is up; when
# it returns, the next pass arms, then draws. Every exit is after a take (nothing pending) or through ov_cleanup, which ends a
# pending waiter and removes the temp dir. No menu of its own: starting and stopping belong to the payload.
command -v jq >/dev/null 2>&1 || { log blue "Overview"; err_dialog "Overview needs jq."; exit 1; }
view=summary
[ "$ONDEV" = 1 ] || { log blue "Overview"; draw summary; exit 0; }   # dev fallback: one screen, no keys, nothing armed
# The key file lives in a private temp dir (umask 077 makes it 0700 with no process of its own) that the EXIT trap removes. The traps
# come first, so no signal can find a dir they would not clean up; TERM, INT and HUP end the Overview through `exit`, which runs
# ov_cleanup. Both files are written once, here, so that a file system with no room left is an error at the start and not three
# empty answers later (take names the same failure later on).
trap ov_cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
OV_TMP=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/starchorus-ov.XXXXXX" 2>/dev/null) || { OV_TMP=; log blue "Overview"; err_dialog "Overview could not start."; exit 1; }
OV_KEYF=$OV_TMP/key; OV_RAW=$OV_TMP/raw; OV_JQO=$OV_TMP/jq
{ printf x > "$OV_KEYF" && printf x > "$OV_RAW" && printf x > "$OV_JQO"; } 2>/dev/null || { log blue "Overview"; err_dialog "Overview could not start."; exit 1; }
OV_LIVE=1; bad=0; again=1; first=1
parent_gone && exit 0
while :; do
    arm
    [ -z "$first" ] || { log blue "Overview"; first=; }
    ov_cut=0
    [ "$again" = 0 ] || draw "$view" || ov_cut=1
    take
    parent_gone && exit 0
    [ -z "$KEY_ERR" ] || { err_dialog "Overview could not read a key."; exit 1; }
    again=1
    case $KEY in
        A) bad=0 ;;
        LEFT|RIGHT) bad=0; step "$KEY" ;;
        UP|DOWN) bad=0; again=$ov_cut ;;
        B) bad=0; row_of
           sel=$(pick "Overview" "Summary" "Strongest Networks" "Bands & Security" "Devices & Merges" "Probe Requests" "Stations" "Air Quality" "$ROW") || exit 0
           parent_gone && exit 0
           view_of "$sel" || exit 0 ;;
        *) again=$ov_cut
           if [ -z "$KEY_CS" ] || [ "$KEY_CS" -lt "$STRIKE_CS" ]; then bad=$((bad + 1)); [ "$bad" -lt 3 ] || exit 0; else bad=0; fi ;;
    esac
done
