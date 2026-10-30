#!/bin/sh
#
# Title:        Starchorus -- on-device Overview (passive)
# Description:  Reads the starchorus.json the collector already wrote and shows it on the
#               device's 480x222 screen, one screen at a time: a summary (counts, band split,
#               freshness, crowding), the strongest networks, bands & security, logical devices /
#               merged SSIDs, probe requests, stations, Bluetooth (addresses heard, by company), and
#               air quality (channel crowding). Each screen ends with the time of the scan it shows.
#               It NEVER transmits: it only reads a local JSON file. No deauth, no rogue AP, no scan,
#               no association. It starts and stops nothing.
# Author:       Starchorus
# Version:      0.2.6.2
# Contract:     3
# Category:     reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs on the device (uses the device's display commands LOG / LIST_PICKER / ERROR_DIALOG / WAIT_FOR_INPUT,
# which exist only inside the payload runtime) AND on a dev machine
# (every device command has a plain-text fallback, so `sh starchorus-display.sh --once summary` prints
# the same screen to stdout for testing). Needs `jq` -- confirmed present on the device, but built
# WITHOUT the Oniguruma regex library: no regex builtin anywhere, see the NO REGEX block below. A jq that
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
# after every key the Overview takes and again when the list returns, so an Overview whose payload has gone ends at its next key
# press, not before: it waits for keys with no time limit; the payload gives it no stdout for that reason, so it holds none of
# the payload's pipes while it waits). Without them it behaves as it always did.
#
# KEYS. Nothing on the screen moves by itself: there is no timer and no live summary. A KEY READER runs WAIT_FOR_INPUT in the
# background, again and again, from the first screen until the Overview ends (the list excepted, see The key reader below), and
# appends every answer to a queue; the shell draws while the reader waits and takes the keys from the queue in the order they were
# pressed (docs/display-paths.md). A press during "Reading..." is therefore kept, whatever the key, and means the same on every screen:
#   A  the same screen again. An A pressed during a draw is answered by that draw once it is finished: no second draw, no second jq
#   B  one level up: screen -> the list "Overview" -> exit 0, back to the payload's menu. It ends a draw that is running, at once
#   LEFT / RIGHT  the previous / next screen, wrapping (summary, top, bands, devices, probes, clients, bluetooth, air). They end a
#              draw that is running, at once
#   UP / DOWN  ignored (whether the console scrolls for them was not measured), also during a draw, which they leave running; nothing is drawn for them
#   anything else, or no answer, that comes back within 1 s of its wait being opened: a strike, three in a row end it (a slower one
#              is only waited out)
# A draw that has to run jq prints "Reading..." first (see BUSY); jq runs under a `timeout` (see JQ_TMO); a capture that takes
# longer gets the two lines of nodata() instead of numbers, and the verdict is cached per capture like a result (a run that a key
# has ended is no result and is not kept). STARCHORUS_PROC (a stand-in for /proc: the uptime and the stat file of this shell) and
# STARCHORUS_JQ_CAP are test hooks.
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

# OV_GATE is 1 while a draw of the Overview runs (draw sets it and clears it again), else empty; ov_cut then says whether the draw
# has been ended by a key (see draw).
OV_GATE=
log() {  # log [red|blue] "text..."  -- red = an alarm, blue = a heading (that is the whole palette)
    ov_cut && return 0   # the draw is over (see draw)
    case "$1" in red|blue) color=$1; shift ;; *) color= ;; esac
    if [ "$ONDEV" = 1 ]; then LOG ${color:+"$color"} "$*"; else printf '%s\n' "$*"; fi
}
logeach() { while IFS= read -r l; do log "$l"; done; }   # one LOG line per stdin line
err_dialog() { if [ "$ONDEV" = 1 ]; then ERROR_DIALOG "$1"; else printf 'ERROR: %s\n' "$1" >&2; fi }

# pick "Title" opt1 opt2 ... default -> the chosen option; the dev fallback echoes the default (last
# arg), so the menu flows run non-interactively
pick() { if [ "$ONDEV" = 1 ]; then LIST_PICKER "$@"; else for last; do :; done; printf '%s\n' "$last"; fi; }

# uptime_cs -> UT, the time since boot in hundredths of a second, read from /proc/uptime with the shell's own read (no
# process); UT stays empty and the status is 1 where there is no such file. STARCHORUS_PROC (test hook) names another /proc directory.
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

# The key reader. A reader (ov_reader, a background subshell) keeps a WAIT_FOR_INPUT open from the first screen on: it starts one, takes its
# answer, appends the answer to the queue and starts the next at once, so a press made while a screen or "Reading..." is being drawn is
# kept, in order, whatever the key is. Why the waits must be open, as measured on the device (docs/device-notes.md section 7): a press made
# while no wait is open is LOST, not buffered (M1), and B pressed then is taken by the Pager UI itself and leaves the payload view (M2); a
# wait started in the background does receive its key while the foreground writes LOG lines (M3). A wait takes ONE key. 0.1.1 opened one wait
# per draw and so had to end the draw on any key, to get the next wait open before a second press; the reader needs no such rule, and what
# ends a draw now is only a key that asks for another screen (below). What stays unopened is short: the start up to the first wait, the
# stretch from an answer to the next wait being registered with the UI (a fork and an exec for the `mv` that renames the new counts onto their
# file, then a fork and an exec for the new wait, then the UI's own time), and the list. The list is a wait of its own, and nothing measured
# says how the UI shares a key between a picker and a wait, so the reader ends itself on a B and the shell starts another when the list returns.
#
# The queue is an append-only file in the private temp dir (OV_QUE), a line per answer, "CS RAW": CS is how long that wait was open in
# hundredths of a second, by the reader's own clock ("-" where there is none), RAW what WAIT_FOR_INPUT printed. The shell reads it by line
# number (OV_QN lines are taken). A file and not a FIFO for three reasons: the shell has to look into the queue without taking from it (a draw
# must know whether a B, Left or Right is waiting, and every read from a FIFO takes); a writer to a FIFO blocks until somebody has the other
# end open, which would tie the reader's life to the shell's reads, where a file can be appended to whether or not anyone is reading; and a
# file needs no mkfifo applet, which was not looked for on the device. The device's /tmp is RAM: a line is about ten bytes and exists only for
# a key that was pressed; the queue starts again from nothing each time the reader is started (after a B, when everything in it has been
# taken and nothing is writing), and the directory goes with the Overview. A reader whose waits come back with nothing known three times in
# a row, each within STRIKE_CS, ends itself, as the shell would (the strike rule in the main loop), so a broken key path leaves three lines
# and not a busy loop's worth.
#
# Two numbers tell the shell what the reader has done, in one small file (OV_CNT) that the reader replaces after each append: "LINES
# ENDERS", the lines appended so far and how many of them are a B, Left or Right (the keys that end a draw). The shell holds the counts of
# what it has taken (OV_QN, OV_NC), so a key is waiting when LINES is more than OV_QN, and a draw is cut when ENDERS is more than OV_NC
# (ov_cut). Counting what was appended against what was taken leaves no flag for the one side to set and the other to clear, and so no
# order in which the two can step on each other. The file is never rewritten in place: the reader writes the new numbers to a file beside it
# and renames that onto OV_CNT (`mv -f`: one rename within one directory), so a look finds the numbers from before or the numbers from after,
# and never the empty file that a truncating `>` leaves between its open and its write. That matters where the shell looks once and acts on
# what it finds (a jq to end, a verdict to keep, the count of a finished block): a look that found nothing there would be a wrong decision,
# not a miss that the next look makes good. The file with the pid of the reader's open wait (OV_WPF), which the cleanup reads in one shot,
# is written the same way when a wait is opened; it is emptied in place when the wait has ended, and empty is then what it holds.
#
# A key taken with OV_QN at or below OV_QC (the lines there were when the draw finished its block, see draw) was pressed during that
# draw. An A among those is answered by the draw, whole or cut, and asks for nothing more; Up and Down are ignored where they come. A key
# taken above OV_QC was pressed after the screen was complete: an A then draws it again.
#
# The reader is a subshell that starts WAIT_FOR_INPUT as a background child of its own (answer to OV_RAW) and waits for it. Why a child
# and not `k=$(WAIT_FOR_INPUT)` there: a TERM to the reader must reach WAIT_FOR_INPUT itself. A shell runs its traps only between commands,
# so a subshell that sits in a command substitution cannot pass the signal on; it would die and leave the real waiter behind, still
# registered with the UI daemon, where it takes the next press (the payload's menu would lose its key). Waiting in `wait` it can act at
# once. Its trap notes the signal (`rd_sig`) and ends the wait it has open, and the code before the fork, after it and after the wait acts
# on the note, so a TERM that lands between the check and the `wait` (where the trap would run before `wait` blocks, and nothing would
# wake it) or between the fork and the child's pid being known is not lost either. A TERM that lands just after the reader was forked, while
# it still has the traps of the shell and not yet its own, can be lost all the same; ov_cleanup therefore also leaves a mark that the reader
# looks for (ov_orphan). The reader writes the child's pid to OV_WPF while the wait is open, so that
# ov_cleanup can end the waiter even if the reader itself was killed from outside. The reader has no stdin, stdout or stderr of its own, so it
# holds none of the payload's pipes, and it replaces the EXIT trap it inherits (ov_cleanup would otherwise delete the temp dir as soon as
# the reader ended); its own EXIT trap leaves a mark in OV_RDONE (where the temp dir is still there), which tells the shell that nothing more
# will come: with the queue empty that is a failure, named as such, and not an answer. A reader killed with KILL runs no trap and one on a
# file system with no room left cannot write the mark, so ov_await asks for the reader's pid as well: a pid that is gone is the same failure.
# A wait is never put under `timeout`: killing a UI command can leave a waiter in the UI daemon that swallows the next press.
KEY=; KEY_CS=; KEY_ERR=; STRIKE_CS=100
OV_TMP=; OV_QUE=; OV_CNT=; OV_RAW=; OV_JQO=; OV_RDONE=; OV_WPF=; OV_QUIT=; OV_RPID=; OV_JPID=; OV_WTCH=
OV_QN=0; OV_NC=0; OV_QC=0; CN_L=0; CN_E=0; NK=; QL=; ov_sig=
CR=$(printf '\r'); TAB=$(printf '\t')
# ov_nap: the nap of the wait for a key (ov_await), and it widens the longer nobody presses anything. OV_NAPS counts the naps since the last key
# was taken or the last screen was drawn (both set it back to 0, see ov_await and draw): the first 15 naps (about 3 s, when another press is
# likely) are 0.2 s, the next 54 (up to about 30 s) 0.5 s, every one after that 1 s. The count is the clock: no process is started to read
# one, and the shell still looks at the queue between naps. Where the sleep applet has no fractions each stage is a whole second (the
# stages then run longer in time, not in naps). A press after a long idle is seen up to 1 s late; the UI's own handling of it is not slowed.
# ov_nap_short: the fixed short nap, 0.2 s (a whole second where the sleep applet has no fractions), for the two waits that are over soon and
# must not lag: the watcher of a running jq (ov_jq; the jq is under `timeout` for 20 s at most, and a cut key has to end it) and the removal
# of the reader's end (ov_cleanup, ten naps at most).
OV_NAPS=0
ov_nap() {
    if [ "$OV_NAPS" -lt 15 ]; then ov_ns=0.2
    elif [ "$OV_NAPS" -lt 69 ]; then ov_ns=0.5
    else ov_ns=1; fi
    OV_NAPS=$((OV_NAPS + 1))
    sleep "$ov_ns" 2>/dev/null || sleep 1
}
ov_nap_short() { sleep 0.2 2>/dev/null || sleep 1; }
# ov_counts -> CN_L, CN_E: the numbers in OV_CNT as the reader last wrote them. The reader replaces the file by a rename (see The key
# reader), so a read finds a whole file, the old numbers or the new; status 1 is for a file that is not there or holds something else, and
# the caller takes it as no news. The shell's own read: no process.
ov_counts() {
    oc_l=; oc_e=
    read -r oc_l oc_e 2>/dev/null < "$OV_CNT" || return 1
    case $oc_l in ''|*[!0-9]*) return 1 ;; esac
    case $oc_e in ''|*[!0-9]*) return 1 ;; esac
    CN_L=$oc_l; CN_E=$oc_e
}
# ov_cut: status 0 while a draw runs and a B, Left or Right that the shell has not taken yet is in the queue. Those three end a draw, as
# they leave the screen; A, Up and Down do not.
ov_cut() { [ "$OV_GATE" = 1 ] && ov_counts && [ "$CN_E" -gt "$OV_NC" ]; }
# keyname RAW -> NK: A, B, UP, DOWN, LEFT or RIGHT as WAIT_FOR_INPUT printed it (BACK and Escape count as B, as in other payloads of the
# library; a lower-case a or b as the capital), else empty. Spaces, tabs and CR are stripped with the shell's own expansions (no process per
# key). The reader and the shell both use it, so they cannot disagree on what a B is.
keyname() {
    kn_s=$1
    while :; do
        case $kn_s in
            *" "*) kn_s=${kn_s%%" "*}${kn_s#*" "} ;;
            *"$TAB"*) kn_s=${kn_s%%"$TAB"*}${kn_s#*"$TAB"} ;;
            *"$CR"*) kn_s=${kn_s%%"$CR"*}${kn_s#*"$CR"} ;;
            *) break ;;
        esac
    done
    case $kn_s in
        A|a) NK=A ;;
        B|b|BACK|Escape) NK=B ;;
        UP|DOWN|LEFT|RIGHT) NK=$kn_s ;;
        *) NK= ;;
    esac
}
# ov_orphan: status 0 when the reader has nothing left to serve (it runs in the reader, where rd_main is the pid of the shell that
# started it): ov_cleanup has left its mark (OV_QUIT), or the temp dir is gone, or the shell has died (killed with KILL, where no
# cleanup runs). Why not the signal alone: a subshell resets its traps just after the fork, and a TERM that lands in that gap runs
# the handler it inherited and is then forgotten, so a reader forked an instant before the shell's TERM went on to open a wait nobody
# would end (seen under dash, TERM about 4 ms after the start). The mark is written before the TERM is sent, so a reader that missed
# the signal finds the mark at its next look, before it opens a wait and again before it blocks in `wait`. A reader whose shell was
# killed without a cleanup ends at its next answer instead of opening another wait, so it can take one more key, as a one-shot waiter
# did, and not every key until the device restarts.
ov_orphan() { [ -e "$OV_QUIT" ] || [ ! -e "$OV_CNT" ] || ! kill -0 "$rd_main" 2>/dev/null; }
# ov_reader: the body of the reader (started by ov_rstart as a background job). One round: a wait, its answer, a line in the queue, the
# counts, and the next wait. It ends after a B (the list follows), after the third answer in a row that was nothing known and came back
# within STRIKE_CS (or with no clock to tell), when a line cannot be appended or its count cannot be stored, and on TERM, INT or HUP. Its
# EXIT trap leaves the `done` mark only where the temp dir is still there: the cleanup waits for the reader before it removes the dir, but
# not for ever, and a mark written into a dir that is being removed must not make a new one.
ov_reader() {
    rd_sig=; rd_w=; rd_main=$$; rd_n=0; rd_e=0; rd_junk=0
    trap 'rd_sig=1; [ -z "$rd_w" ] || kill "$rd_w" 2>/dev/null' TERM INT HUP
    trap '[ ! -d "$OV_TMP" ] || printf x 2>/dev/null > "$OV_RDONE"' EXIT
    [ -z "$ov_sig" ] || exit 143   # a signal that came before the traps above was noted in the copy of ov_sig this subshell was born with
    ov_counts && { rd_n=$CN_L; rd_e=$CN_E; }
    while :; do
        if [ -n "$rd_sig" ] || ov_orphan; then exit 143; fi
        uptime_cs; rd_t=$UT
        WAIT_FOR_INPUT > "$OV_RAW" 2>/dev/null & rd_w=$!
        printf '%s\n' "$rd_w" > "$OV_WPF.new" && mv -f "$OV_WPF.new" "$OV_WPF"
        if [ -n "$rd_sig" ] || ov_orphan; then kill "$rd_w" 2>/dev/null; exit 143; fi
        wait "$rd_w"
        rd_x=$rd_w; rd_w=
        if [ -n "$rd_sig" ]; then kill "$rd_x" 2>/dev/null; wait "$rd_x" 2>/dev/null; exit 143; fi
        : > "$OV_WPF"
        rd_k=; read -r rd_k < "$OV_RAW"
        uptime_cs; rd_c=-
        case $rd_t in ''|*[!0-9]*) ;; *) case $UT in ''|*[!0-9]*) ;; *) rd_c=$((UT - rd_t)) ;; esac ;; esac
        printf '%s %s\n' "$rd_c" "$rd_k" >> "$OV_QUE" || exit 1
        keyname "$rd_k"
        rd_n=$((rd_n + 1))
        case $NK in B|LEFT|RIGHT) rd_e=$((rd_e + 1)) ;; esac
        { printf '%s %s\n' "$rd_n" "$rd_e" > "$OV_CNT.new" && mv -f "$OV_CNT.new" "$OV_CNT"; } || exit 1
        case $NK in
            B) exit 0 ;;
            '') case $rd_c in
                    -) rd_junk=$((rd_junk + 1)) ;;
                    *) if [ "$rd_c" -lt "$STRIKE_CS" ]; then rd_junk=$((rd_junk + 1)); else rd_junk=0; fi ;;
                esac
                [ "$rd_junk" -lt 3 ] || exit 0 ;;
            *) rd_junk=0 ;;
        esac
    done
}
# ov_trap_exit: TERM, INT and HUP end the Overview through `exit`, which runs ov_cleanup (that ignores them from its first line on). The trap
# that takes the first of them ignores the others from that moment: the stretch between its `exit` and the cleanup's first line is a few
# microseconds unloaded but, with the machine busy, long enough for a second signal to run `exit` again from inside the cleanup, before the
# reader is ended and the temp dir removed (seen once in the regression, a TERM every 0.05 s).
ov_trap_exit() { trap 'trap "" TERM INT HUP; exit 143' TERM; trap 'trap "" TERM INT HUP; exit 130' INT; trap 'trap "" TERM INT HUP; exit 129' HUP; }
# ov_rstart: start the key reader. Everything in the queue has been taken by now and nothing is writing to it (the reader of the round
# before ended on a B, and the first round has none), so the queue and its counts begin again from nothing. TERM, INT and HUP are only
# noted while the reader is forked and its pid stored (ov_sig), and acted on once OV_RPID is known: ov_cleanup then ends the reader by
# its pid and not by a guess from `$!`, which before the fork is the pid of some earlier job.
ov_rstart() {
    rs_l=; rs_e=; ov_counts && { rs_l=$CN_L; rs_e=$CN_E; }
    if [ "$rs_l" = "$OV_QN" ] && [ "$rs_e" = "$OV_NC" ]; then
        : > "$OV_QUE"; printf '0 0\n' > "$OV_CNT"; OV_QN=0; OV_NC=0; OV_QC=0
    fi
    : > "$OV_RDONE"; : > "$OV_WPF"
    ov_sig=
    trap 'ov_sig=143' TERM; trap 'ov_sig=130' INT; trap 'ov_sig=129' HUP
    ov_reader > /dev/null 2>&1 < /dev/null &
    OV_RPID=$!
    ov_trap_exit
    [ -z "$ov_sig" ] || { trap '' TERM INT HUP; exit "$ov_sig"; }   # the same, for a signal noted while the reader was forked
}
# ov_rstop: the reader that ended itself on a B is gone before the list opens (so no wait is open while it shows); `wait` reaps it
ov_rstop() { [ -z "$OV_RPID" ] || { wait "$OV_RPID" 2>/dev/null; OV_RPID=; }; }
# ov_qnext -> QL: the first line of the queue that the shell has not taken (OV_QN counts the lines it has), and OV_QN moves on past it;
# status 1 if there is none. A last line without its newline, which the reader has not finished, is not read.
ov_qnext() {
    qn_i=0; QL=
    while IFS= read -r qn_l; do
        qn_i=$((qn_i + 1))
        [ "$qn_i" -gt "$OV_QN" ] || continue
        QL=$qn_l; OV_QN=$qn_i
        return 0
    done < "$OV_QUE"
    return 1
}
# ov_await -> KEY: waits for the next key of the queue, napping (ov_nap, which widens with the idle time) while there is none, and takes it. KEY is A, B, UP, DOWN, LEFT or
# RIGHT as keyname makes it, else empty (a strike); KEY_CS is the time that wait was open (empty without a clock). KEY_ERR=1: the reader has
# ended and left nothing: no answer and no key, a failure, and the Overview says so instead of counting it as a strike. The reader has ended
# when it has left its mark (OV_RDONE) or when its pid is gone (`kill -0`, no process): a reader killed with KILL runs no trap, and one on a
# full file system cannot write the mark, so the mark alone would leave the loop below napping for ever with no wait open. A child that has
# died stays a zombie, and `kill -0` still finds it, until the shell collects it; dash, bash and the Pager's BusyBox ash do that while the
# nap's sleep is waited for (measured on a dev machine and, on 20 October 2026, on the device: docs/device-notes.md section 7). The counts are
# looked at again once the reader's end is seen, because it writes them before it ends. A B, Left or Right taken is counted in OV_NC, which
# ends the cut of the draw it came in (ov_cut).
ov_await() {
    KEY=; KEY_CS=; KEY_ERR=; aw_ok=
    while :; do
        if ov_counts && [ "$CN_L" -gt "$OV_QN" ] && ov_qnext; then aw_ok=1; break; fi
        if [ -s "$OV_RDONE" ] || ! kill -0 "$OV_RPID" 2>/dev/null; then
            if ov_counts && [ "$CN_L" -gt "$OV_QN" ] && ov_qnext; then aw_ok=1; else KEY_ERR=1; ov_rstop; fi
            break
        fi
        ov_nap
    done
    [ -n "$aw_ok" ] || return 0
    OV_NAPS=0   # a key was taken: the next wait starts with the short nap again
    aw_t=${QL%% *}; aw_k=${QL#* }
    case $aw_t in ''|*[!0-9]*) ;; *) KEY_CS=$aw_t ;; esac
    keyname "$aw_k"; KEY=$NK
    case $KEY in B|LEFT|RIGHT) OV_NC=$((OV_NC + 1)) ;; esac
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
# ov_cleanup: the EXIT trap of the Overview (set where it starts). It ignores TERM, INT and HUP from its first line on, for the time it takes
# (about 2 s at most, see below): a further one of them would run `exit` from inside this EXIT trap, and the shell would leave before the temp
# dir is removed, with the queue, the counts and the screen lines left in the device's RAM. It leaves its mark for the reader, then ends the key
# reader and the wait it has open (the reader hands the TERM on to WAIT_FOR_INPUT), the jq of a draw that is running and its watcher, waits for
# the reader to be gone, and removes the temp dir. A normal exit after a B finds no reader (it ended itself on that B); an exit after a key that
# found the payload gone, three strikes in the queue's order, or a TERM, INT or HUP, finds one with a wait open. The reader is known by the pid
# ov_rstart stored (it defers a signal until then), and its wait by the pid the reader wrote to OV_WPF, so nothing here guesses from `$!`:
# should the reader itself have been killed from outside, its wait is still ended. The reader ends in its own time after the TERM (its wait
# has to leave first), and its last act writes into the temp dir; removing the dir meanwhile could leave it with that one file in it, so
# the removal waits for the reader's end, in ten naps at most (ov_nap_short: about 2 s, and about 10 s where the sleep applet has no fractions), never
# for ever (the reader's own trap writes nothing into a dir that is gone). The nap also lets the shell collect a reader that has ended (see
# ov_await), so that its pid is then gone. The Overview stays endable: KILL cannot be ignored, and the signals are ignored for that wait only.
# ov_wkill: end the wait the reader left open, by the pid it wrote to OV_WPF (nothing is guessed from `$!`). The KEY_ERR path uses it before
# its dialog, so that a dead reader's orphan wait is not the one that takes the press meant to dismiss the dialog. ov_cleanup keeps its own
# two lines for the same step, so that the cleanup itself names the pids it ends (the reader's from OV_RPID, its wait's from OV_WPF).
ov_wkill() { cl_w=; [ ! -s "$OV_WPF" ] || read -r cl_w < "$OV_WPF"; case $cl_w in ''|*[!0-9]*) ;; *) kill "$cl_w" 2>/dev/null ;; esac; }
ov_cleanup() {
    trap '' TERM INT HUP
    [ -z "$OV_QUIT" ] || printf x 2>/dev/null > "$OV_QUIT"   # the mark the reader looks for (see ov_orphan), before the signals
    [ -z "$OV_RPID" ] || kill "$OV_RPID" 2>/dev/null
    cl_w=; [ ! -s "$OV_WPF" ] || read -r cl_w < "$OV_WPF"
    case $cl_w in ''|*[!0-9]*) ;; *) kill "$cl_w" 2>/dev/null ;; esac
    [ -z "$OV_WTCH" ] || kill "$OV_WTCH" 2>/dev/null
    [ -z "$OV_JPID" ] || ov_kill "$OV_JPID"
    cl_n=0
    while [ -n "$OV_RPID" ] && [ "$cl_n" -lt 10 ] && kill -0 "$OV_RPID" 2>/dev/null; do ov_nap_short; cl_n=$((cl_n + 1)); done
    [ -z "$OV_TMP" ] || rm -rf "$OV_TMP"
}

# parent_gone -> 0 when STARCHORUS_PARENT_PID names the payload that started us and it has ended (or we were handed over
# to another parent): the Overview then ends too, instead of drawing over whatever the device shows next. It is asked after every
# key the shell takes from the queue, and once more when the list returns, which can take as long as a person likes; an Overview whose
# payload has gone therefore ends at its next key press (the reader has opened another wait by then, which ov_cleanup ends). No process
# is started for it: it runs between a key being taken and the next draw or nap, which must not take long. The parent of this shell is
# field 4 of /proc/self/stat (the file is read by the shell's own `read`, so "self" is this shell), taken after the last ") ".
# STARCHORUS_PROC (test hook) names another /proc directory.
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
# The "jq not found" gate is at the dispatch at the bottom of this file, not here: see there.
#
# ONE jq PROCESS PER SCREEN. The device is a single ~580 MHz MIPS core: every jq start re-parses the whole
# capture (15-50 KB) and compiles JQLIB again, which is what made a redraw cost seconds of CPU. So each
# screen has ONE jq program (JQ_SUMMARY, JQ_TOP, ... below) that computes every value the screen needs and
# prints them as records, and fetch() runs it once per render:
#     ok 0                      <- the document parsed (always the first record)
#     <key> <N>                 <- a header: the key and the number of text lines that follow
#     <N lines>
# A record is framed by its line COUNT, never by looking at the text, so no value (an SSID, a probe name) can
# forge a record: a newline inside a value is split into lines by jq (_R) and arrives as lines. load() turns the records into
# R_<key> (the lines, joined by newlines) and N_<key> (their count); a value that failed to compute: see _R.
# A document that does not parse, is empty or is just null / false is "no data" (_D), as is a capture older than
# STARCHORUS_SINCE (see SINCE_JQ). No data prints WAITING.
# fetch() reuses the last verdict per capture fingerprint; see fetch.
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

# ov_jq LIMIT JQ-ARGS... -> fx_out (what jq printed) and, as the status, the one of `timeout` or of jq. Runs jq with those arguments under
# `timeout LIMIT` (without it where LIMIT is empty): the screens' programs run under the cap, the health probe without one. The Overview
# runs jq in the background with its output in a file, and the shell waits for it in `wait` (a TERM is therefore handled at once). A
# watcher looks at the queue's counts every 0.2 s (ov_nap_short, not the widening nap: a running jq is not an idle wait); once a B, Left or Right is waiting (ov_cut), it ends the jq and what `timeout`
# started for it (ov_kill; see draw). FX_CUT=1 says the run ended for that reason: fetch then keeps nothing, so the next draw of the screen
# reads the capture again. A run that failed while such a key had come counts as cut too, whatever its status (143 or 137 for a jq that
# was ended; a `timeout` that fired at that moment is not worth a verdict). The watcher leaves by itself when the jq is gone (its pid does
# not exist once `wait` has reaped it) and is ended here as well.
ov_jq() {
    FX_CUT=0; oj_t=$1; shift
    if [ -n "$oj_t" ]; then timeout "$oj_t" jq "$@" > "$OV_JQO" 2>/dev/null &
    else jq "$@" > "$OV_JQO" 2>/dev/null &
    fi
    OV_JPID=$!; oj_p=$!
    (
        trap - EXIT
        while kill -0 "$oj_p" 2>/dev/null && ! ov_cut; do ov_nap_short; done
        if ov_cut; then ov_kill "$oj_p"; fi
    ) > /dev/null 2>&1 < /dev/null &
    OV_WTCH=$!
    wait "$OV_JPID" 2>/dev/null; oj_rc=$?
    kill "$OV_WTCH" 2>/dev/null; wait "$OV_WTCH" 2>/dev/null
    OV_JPID=; OV_WTCH=
    if [ "$oj_rc" != 0 ] && ov_cut; then FX_CUT=1; return "$oj_rc"; fi
    fx_out=$(cat "$OV_JQO" 2>/dev/null)
    return "$oj_rc"
}
# fetch SCREEN 'PROGRAM': run (or reuse) the screen's one jq program and load() its records; 1 = nothing to show, and
# FX_SLOW says whether that is because jq ran out of time and FX_BAD whether it is because the capture is no document (see nodata); 1 also when
# a key ended the draw (see draw), both 0.
# The fingerprint is taken BEFORE jq reads the file: a capture that lands in between is simply read again at the
# next draw. stderr goes to /dev/null on purpose (see jq_warn).
# In the Overview (OV_LIVE=1) a run that is not served from the cache says "Reading..." first (busy: see BUSY) and runs (ov_jq)
# under `timeout` (see JQ_TMO), so a capture too big for the device cannot hold the screen for ever: status 124, 137
# or 143 from that `timeout` is "too slow". Only from it: a jq that ran without the limit (no applet, --once, --selftest) and
# was killed from outside (the out-of-memory killer, a TERM) never had the cap to overrun, so that is no data.
# A capture that exists and is not empty but that jq cannot read (status 2 or 5: cut off, not JSON) or that is the one word null is
# "bad": it prints "Capture unreadable." and not the waiting line, which would look like a slow start for ever. An empty file and a missing one
# stay "Waiting". The no-data, the bad and the slow verdict are cached per fingerprint exactly like the records (CV_<screen>: ok, nodata, bad or slow), so a
# draw of the same file again, A on the waiting or on the slow screen, starts no jq. The collector replaces starchorus.json
# atomically once a cycle (5 to 30 s); until it does, only the time of the scan and its age (shell arithmetic) move.
# Only the Overview sets OV_LIVE; --once and --selftest make one plain jq call (no cap, no "Reading...").
fetch() {
    FX_SLOW=0; FX_BAD=0
    [ -s "$JSON" ] || return 1
    [ -n "$FP_MODE" ] || fp_init
    fx_key="$JSON|$(fingerprint)"
    eval "fx_ck=\${CK_$1-} fx_out=\${CO_$1-} fx_vd=\${CV_$1-}"
    if [ "$fx_key" = "$JSON|" ] || [ "$fx_ck" != "$fx_key" ]; then
        ov_cut && return 1   # the draw is over (see draw)
        busy
        fx_lim=0
        if [ "$OV_LIVE" = 1 ]; then
            [ -z "$JQ_TMO" ] || fx_lim=1
            ov_jq "$JQ_TMO" -r "$JQLIB$SINCE_JQ$2" "$JSON"; fx_rc=$?
            [ "$FX_CUT" != 1 ] || return 1   # a cut run is no verdict (see draw)
        else
            fx_out=$(jq -r "$JQLIB$SINCE_JQ$2" "$JSON" 2>/dev/null); fx_rc=$?
        fi
        case $fx_rc in
            0) if [ -n "$fx_out" ]; then fx_vd=ok
               elif [ "$(head -c 32 "$JSON" 2>/dev/null | tr -d ' \t\r\n')" = null ]; then fx_vd=bad
               else fx_vd=nodata; fi ;;
            124|137|143) if [ "$fx_lim" = 1 ]; then fx_vd=slow; else fx_vd=nodata; fi; fx_out= ;;
            2|5) fx_vd=bad; fx_out= ;;
            *) fx_vd=nodata; fx_out= ;;
        esac
        [ "$fx_key" = "$JSON|" ] || eval "CK_$1=\$fx_key CO_$1=\$fx_out CV_$1=\$fx_vd"
    fi
    case $fx_vd in
        ok) load "$fx_out" ;;
        slow) FX_SLOW=1; return 1 ;;
        bad) FX_BAD=1; return 1 ;;
        *) return 1 ;;
    esac
}
# The SINCE gate. STARCHORUS_SINCE (digits, the epoch of the last Start): a capture whose `generated` is older or missing reaches
# the screen's program as null, which _D turns into no data (WAITING is printed); the gate costs no process of its own.
case ${STARCHORUS_SINCE:-} in
    ''|*[!0-9]*) SINCE_JQ= ;;
    *) SINCE_JQ="(if (.generated | type) == \"number\" and .generated >= $STARCHORUS_SINCE then . else null end) | " ;;
esac
WAITING="Waiting for the first scan."
SLOW1="This scan took over 20 s to read."   # the words stay when STARCHORUS_JQ_CAP shortens the cap
SLOW2="Try Settings > Show Last: 1 h."
BAD1="Capture unreadable."
# nodata: what a screen prints when fetch() has nothing to show: the two lines for a capture jq could not read in time, else
# the one line for a capture that is no document, else the waiting line (no capture yet, or only an earlier run's)
nodata() { if [ "$FX_SLOW" = 1 ]; then log "$SLOW1"; log "$SLOW2"; elif [ "$FX_BAD" = 1 ]; then log "$BAD1"; else log "$WAITING"; fi; }
# "Reading..." (BUSY) is the first line of a draw that has to run jq, printed once however many jq runs the draw needs
# (the probe of jq_healthy, then the screen's program). Only the Overview sets OV_LIVE; --once prints no such line.
BUSY="Reading..."
OV_LIVE=0; OV_BUSY=0; FX_SLOW=0; FX_BAD=0; OV_INT=
busy() { [ "$OV_LIVE" = 1 ] && [ "$OV_BUSY" = 0 ] || return 0; OV_BUSY=1; log "$BUSY"; }
# jq runs under `timeout` where the applet exists (BusyBox has it): 20 s, STARCHORUS_JQ_CAP shortens the cap (tests only)
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
# rssit = the page's rssiT on an RSSI (a null counts as 1, as rssiT(null) does in JS; only apprep, i.e. the freshness line,
# still carries one: pgaps replaces it first, see below).
# chloads / busiest (crowding and the busiest channel) follow the page's own pipeline, not apprep:
# pgaps = normalizeDoc for the fields the channel model reads (BSSID key via normMac or "ap<i>", duplicate
# BSSIDs merged with the strongest RSSI and the first non-empty channel/freq/width, a missing RSSI = -75 dBm,
# band via bandOf with its freq/channel fallback, a width outside 20/40/80/160/320 = none), sorted like
# S.apOrder (RSSI desc, then BSSID); chloads lists the channels per band in the order they first appear there
# and sums each load in that order (float addition is not associative: a tie can hinge on it); busiest is the
# FIRST channel with the highest load, as crowdingOf keeps it (not max_by: it keeps the LAST maximum). chloads_of / _busiest
# take the pgaps result and the chloads list, so a screen that needs both (crowding, busiest channel, the Air block) runs pgaps once.
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
# other records still arrive: one blank figure, not a blank screen. The program uses try for that (and, with catch, to turn
# a failed intermediate result into null). _chomp drops trailing newlines, so a one-line value stays one line.
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
# Bluetooth and activity (the radio-pair data, additive in the capture): btlist = the records of `bluetooth` that are objects with a
# numeric rssi, the first 256 (the page's normBt keeps the same, and a numeric string as well: see the divergences below), or null when the capture has no such array; so a capture without the
# array shows nothing, and an empty one shows 0. The figures are ADDRESSES, never devices: random addresses dominate what is heard and
# they change with time, and nothing here links addresses across a rotation. btco = the company a record is counted under: the name btmon gave (blank names do
# not count), else "company id N" for an id in 0..65535, else "company not advertised". The page's fixed addresses are `public` and
# `random-static`; every other value, a missing or an unknown one included, is a rotating address there, so the Overview counts the
# same (fixed = those two types, rotating = the rest). actlist = the entries of `activity` with a numeric freq and 0 < share <= 1, the
# first 69 (the page's normAct); bshare(lo; hi) = the sum of the shares of the frequencies lo <= f < hi (null without one), with the
# band edges of the page's band_from_freq; bar8 = a share as eight cells of # and -, actbar the bar and the whole percent. A share is a
# relative figure (frames heard on a channel over frames heard on all of them), never a count. Divergences from the page: a repeated
# address or frequency counts once on the page (the stronger entry, the later one), twice here; the collector writes neither. A numeric STRING in
# rssi (bluetooth) or in freq or share (activity), "-60" for example, is a number on the page (numOrNull) and is skipped here, as is the rssi of the
# Wi-Fi records above; the collector writes numbers only, and the parity rows use text that is no number at all ('loud', 'wide'), where both agree.
# Alerts (the firmware's deauth/disassoc alert, additive in the capture): alertaps = how many access points the capture reports alerts for. alerts[] is cut
# at 20 as the page cuts it; an entry counts when it is an object of type deauth with a numeric count above 0 (a numeric STRING, "9", is a number on the page
# and is skipped here, like the strings above; the collector writes numbers only); its address is folded as the page folds one (pgmac), counted once however
# many entries name it, and counted only when aps[] holds that address and it is none of this device's own transmitters (center.own_bssids, read as the clouds
# read them), because the page draws its note and its ring for an access point it knows and for no other, and not for its own. The page leaves out one more
# kind, a mobile hotspot (an SSID that names a phone, or an ad-hoc network); this program reads no names for the count, so it counts one that the page does
# not draw. Nothing in an entry but its type, count and address is read, and the times of the reports are not.
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
def alertaps: ([.aps[]? | select(type == "object" and .bssid != null) | .bssid | pgmac]) as $B
  | ([.center.own_bssids[]? | select(type == "string") | pgmac] | .[0:16]) as $own
  | [(.alerts | if type == "array" then .[0:20] else [] end)[] | select(type == "object" and .type == "deauth" and (.n | type) == "number" and .n > 0 and .ap != null)
     | .ap | pgmac | select(length == 17)] | unique | map(. as $a | select([$B[] | select(. == $a)] | length > 0 and ($own | index($a)) == null)) | length;
def btlist: ((.bluetooth // null) | if type == "array" then [.[] | select(type == "object" and (.rssi | type) == "number")] | .[0:256] else null end);
def btco: (.company_name | if type == "string" and (_trimws | length) > 0 then _trimws else null end) as $n
  | (.company | if type == "number" and . >= 0 and . <= 65535 and . == (. | round) then . else null end) as $c
  | if $n != null then $n elif $c != null then "company id \($c)" else "company not advertised" end;
def actlist: ((.activity // null) | if type == "array" then [.[] | select(type == "object" and (.freq | type) == "number" and (.share | type) == "number" and .share > 0 and .share <= 1)] | .[0:69] else [] end);
def bshare($lo; $hi): [actlist[] | select(.freq >= $lo and .freq < $hi) | .share] | if length == 0 then null else add end;
def bar8: (. * 8 | round) as $n | [range(0; 8) | if . < $n then "#" else "-" end] | add;
def actbar($lo; $hi): bshare($lo; $hi) | if . == null then empty else bar8 + " " + (. * 100 | round | tostring) + "%" end;
def _r: tostring;
def _chomp: if type == "string" then until(endswith("\n") | not; .[:-1]) else . end;
def _R($k; f): [try f] | map(_r | split("\n")) | add // [] | "\($k) \(length)", .[];
def _D(body): if . == null or . == false then empty else "ok 0", body end;
def bandcnt($B; $b): $B | map(select(. == $b)) | length;
def _abs: if . < 0 then -. else . end;
def _win($c): select(.r >= $c - 3 and .r <= $c + 3);
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

# Visible failure marker. fetch() sends jq's stderr to /dev/null on purpose (a screen must never print jq noise), so a broken jq
# is told by a probe instead: jq_healthy makes ONE jq call through the same JQLIB path the screens use, on known values, and
# compares the whole answer with the expected array: any jq error (a builtin that is absent or fails when it is called) leaves
# the output empty, so the comparison fails. The probe covers the JQLIB helpers plus add / group_by / sort_by (called outside
# JQLIB by the summary, top and bands filters); --selftest probes each builtin on its own.
# The probe runs once per process (on first use: the first summary, top or bands screen) and the answer is kept
# in JQ_OK, so a draw of the same screen again costs no extra process. In the Overview it runs like the program of a screen (ov_jq,
# without the cap): in the background, with a watcher, so that a B, Left or Right during the first draw ends it at once; a probe that was
# ended is no answer, JQ_OK stays empty and the next draw asks again. Outside the Overview (--once, --selftest) it is a plain call.
# jq_warn is the one place that turns a failed probe into a red line, called first thing in those three
# screens; when the probe passes it prints nothing.
JQ_PROBE='[(" 5 GHz" | bandnorm), ("6g" | bandnorm), ("WPA2/WPA3" | sectag), ("" | sectag), (null | isopenwep),
          ([[1, 2], [3]] | map(length) | add),
          (["b", "a", "b"] | group_by(.) | map({k: .[0], n: length}) | sort_by(-.n) | .[0].k)]'
JQ_PROBE_WANT='["5","6","WPA3","Open",true,3,"b"]'
JQ_OK=
jq_healthy() {
    if [ -z "$JQ_OK" ]; then
        ov_cut && return 0   # the draw is over (see draw): no probe now
        busy
        if [ "$OV_LIVE" = 1 ]; then
            ov_jq "" -n -c "$JQLIB$JQ_PROBE"
            [ "$FX_CUT" != 1 ] || return 0   # a probe that a key ended says nothing about jq
            jh_out=$fx_out
        else
            jh_out=$(jq -n -c "$JQLIB$JQ_PROBE" 2>/dev/null)
        fi
        if [ "$jh_out" = "$JQ_PROBE_WANT" ]; then JQ_OK=1; else JQ_OK=0; fi
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
    g=$1; case $g in ''|0?*|*[!0-9]*) return ;; esac   # no number, or one the shell would read as octal (see scan_age)
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
# as the page's Air drawer) as records, next to the plain counts. "bz" is "2.4 GHz ch 6", the busiest channel (see busiest in
# JQLIB). "interval" (center.interval) is for stale_line below.
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
    _R("bt"; btlist | if . == null then empty else length end),
    _R("alaps"; alertaps),
    _R("center"; .center.label // "This device" | _chomp),
    _R("claim"; (.source // "") | tostring | ascii_downcase | contains("active")),
    _R("fresh"; (.generated | if type == "number" then . else null end) as $g | [.aps[] | apprep | tierof($g)] as $t
       | [range(0;4) as $i | ($t | map(select(. == $i)) | length)] as $c | ($t | map(select(. == null)) | length) as $u
       | "heard < 1 min \($c[0]) · heard < 5 min \($c[1]) · heard < 15 min \($c[2]) · on record \($c[3])" + (if $u > 0 then " · undated \($u)" else "" end)),
    _R("lvl"; [$cl[].load] | (max // 0) as $m | 1 + ([1.5, 3, 5, 8] | map(select($m >= .)) | length)),
    _R("bz"; $cl | _busiest | if . == null then "" else .b + " GHz ch " + (.ch + 0 | tostring) end))'
# bt_figure N -> "  BT 23" for the APs line, in ASCII with two blanks, nothing without a count; "256+" at the cap (the capture holds at
# most 256 addresses, so a document at the cap may hold more than it shows, as the page's counter says)
bt_figure() {
    case ${1:-} in ''|*[!0-9]*) return 0 ;; esac
    if [ "$1" -ge 256 ]; then printf '  BT 256+\n'; else printf '  BT %s\n' "$1"; fi
}
# rnd_note: RN = " (N random, K clouds)" from the rnd / ncl records of the screen just loaded; empty without a randomised free station
rnd_note() {
    RN=
    case ${R_rnd:-} in ''|0|*[!0-9]*) return 0 ;; esac
    case ${R_ncl:-0} in 0|''|*[!0-9]*) RN=" ($R_rnd random)" ;; 1) RN=" ($R_rnd random, 1 cloud)" ;; *) RN=" ($R_rnd random, $R_ncl clouds)" ;; esac
}
# alert_line N -> the one red line for the access points the firmware has reported many deauth/disassoc frames for (alerts[]): nothing for 0, for an
# empty record or for anything that is not a number. At most 40 columns ('Deauth/disassoc frames heard: 20 APs' is 36), ASCII; red because it is an
# alarm, like the open/WEP line. Every screen is drawn on a press and never by itself, so the line is as old as the capture it comes from (the frame
# under it says how old that is).
alert_line() {
    case ${1:-} in ''|0|*[!0-9]*) return 0 ;; esac
    if [ "$1" = 1 ]; then al_w="1 AP"; else al_w="$1 APs"; fi
    log red "Deauth/disassoc frames heard: $al_w"
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
    log       "APs $aps   ·   2.4:$b24  5:$b5  6:$b6$(bt_figure "$R_bt")"
    rnd_note
    log       "Clients  $free free$RN · $assoc associated"
    log       "$R_fresh"
    log       "Crowding ${lvl:-1}/5 ($(crowd_word "${lvl:-1}"))${bz:+ · busiest $bz}"
    [ "${probing:-0}" -gt 0 ] && log "Probe requests: $probing client(s) naming a network"
    if [ "${open:-0}" -gt 0 ]; then log red "Open/WEP networks: $open"; else log "No open/WEP networks"; fi
    alert_line "${R_alaps:-}"
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

# With `activity` in the capture (the Traffic setting) each band line also gets the band's share of all the frames the device heard
# on its channels, as eight cells and a whole percent, and one line under the band lines says what the figure is. The edges are the
# page's band_from_freq (2400-2499, 4900-5924, 5925-7199 MHz). A share is relative: of frames heard, never a count of anything.
JQ_BANDS='_D(
  (try [.aps[] | (.band | bandnorm)] catch null) as $B
  | _R("gen"; .generated // empty),
    _R("b24"; bandcnt($B; "2.4")), _R("b5"; bandcnt($B; "5")), _R("b6"; bandcnt($B; "6")),
    _R("a24"; actbar(2400; 2500)), _R("a5"; actbar(4900; 5925)), _R("a6"; actbar(5925; 7200)),
    _R("sec"; [.aps[] | (.security | sectag)]
        | group_by(.) | map({k:.[0], n:length}) | sort_by(-.n) | .[]
        | "  " + .k + ": " + (.n|tostring)))'
screen_bands() {   # band split + security tally
    jq_warn; ready bands "$JQ_BANDS" || return
    log blue "Bands & security (GEN $GEN)"
    log "  2.4 GHz: ${R_b24:-0} AP(s)${R_a24:+  act $R_a24}"
    log "  5 GHz: ${R_b5:-0} AP(s)${R_a5:+  act $R_a5}"
    log "  6 GHz: ${R_b6:-0} AP(s)${R_a6:+  act $R_a6}"
    [ -z "$R_a24$R_a5$R_a6" ] || log "act = share of frames heard (relative)"
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
        | map(. + { oui:(.bssid[0:8]), pfx:(.bssid[0:14]),
                    ul:( (.bssid[1:2]) as $c | ($c=="2" or $c=="6" or $c=="a" or $c=="e") ) })
        | map(select(.ul|not))
        | group_by(.pfx) | map(select(length>=2))) catch null) as $dl
  | _R("gen"; .generated // empty),
    _R("ndev"; $dl | length),
    _R("ess"; [ .aps[] | select((.ssid // "")!="") | {ssid:.ssid, dev:((.bssid // "")|ascii_downcase|.[0:14])} ]
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
      | "  named: " + .k + "  (x" + (.n|tostring) + ")"))'
screen_probes() {   # who is looking for which network (probe requests, rx only)
    ready probes "$JQ_PROBES" || return
    ACTIVE=$R_claim
    log blue "Probe requests (GEN $GEN)  $(claim short)"
    if [ "${R_n:-0}" -eq 0 ]; then log "No named probe heard."; return; fi
    log "$R_n client(s) with a named probe:"
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
        else (.r|tostring) + " dBm  " + .mac + "  " + (if .a then "assoc " + .a else (if .np>0 then "named probe" else "free" end) end) end))'
screen_clients() {
    ready clients "$JQ_CLIENTS" || return
    ACTIVE=$R_claim
    log blue "Stations (GEN $GEN)  $(claim short)"
    rnd_note
    log "  ${R_free:-0} free$RN · ${R_assoc:-0} associated"
    rec_lines clist | logeach
}

# Bluetooth LE (opt-in in the collector, passive scan only): the addresses the last window heard, counted as ADDRESSES (a phone's
# resolvable address changes about every quarter of an hour, so a count of addresses is not a count of devices), and the strongest
# few by company, the id the advertiser puts in its manufacturer data. Companies are named by the name the collector took from the
# decoding (btco), else "company id N", else "company not advertised". Without a `bluetooth` array in the capture the setting is off
# (or the collector is older): two lines say so. A void window (center.bt_window 0: no valid scan this time) shows the records the
# collector still holds, with a line that says they are held. Every line is at most 40 columns and ASCII (the summary's middle dot
# is the screen's own and the ACTIVE line is the page's wording); at most 12 lines with the frame. `hold` is center.bt_hold, the
# seconds a record is kept (120). A name is cut at 22 characters ("company not advertised" is 22): with a three-digit signal and a
# three-digit count (256 at most) the line is then 40 columns, where a cut at 23 would make 41.
JQ_BT='_D(
  btlist as $L
  | _R("gen"; .generated // empty),
    _R("claim"; (.source // "") | tostring | ascii_downcase | contains("active")),
    _R("on"; $L != null),
    _R("void"; (.center.bt_window // null) == 0),
    _R("hold"; .center.bt_hold // empty),
    _R("n"; ($L // []) | length),
    _R("fixed"; [($L // [])[] | select(.addr_type == "public" or .addr_type == "random-static")] | length),
    _R("blist"; ($L // []) | map({k: btco, r: (.rssi | round)})
      | group_by(.k) | map({k: .[0].k, n: length, r: (map(.r) | max)})
      | sort_by(-.r, .k) | .[0:7][] | " \(.r) dBm  \(.k | oneline | .[0:22] | _rtrimws)  (\(.n))"))'
screen_bluetooth() {
    ready bluetooth "$JQ_BT" || return
    ACTIVE=$R_claim
    bt_max=7
    if [ "$ACTIVE" = true ]; then log blue "Bluetooth LE (GEN $GEN)"; log "$(claim)"; bt_max=6
    else log blue "Bluetooth LE (GEN $GEN)  $(claim short)"; fi
    if [ "$R_on" != true ]; then
        log "No Bluetooth in this scan."
        log "Turn it on in Settings > Bluetooth."
        return 0
    fi
    bt_n=${R_n:-0}; case $bt_n in ''|*[!0-9]*) bt_n=0 ;; esac
    bt_f=${R_fixed:-0}; case $bt_f in ''|*[!0-9]*) bt_f=0 ;; esac
    [ "$bt_f" -le "$bt_n" ] || bt_f=$bt_n
    bt_ns=$bt_n; bt_w=addresses
    if [ "$bt_n" -ge 256 ]; then bt_ns="256+"; elif [ "$bt_n" = 1 ]; then bt_w=address; fi
    log "$bt_ns $bt_w ($((bt_n - bt_f)) rotating, $bt_f fixed)"
    if [ "$bt_n" -gt 0 ]; then
        bt_h=${R_hold:-120}; case $bt_h in ''|0|*[!0-9]*|??????*) bt_h=120 ;; esac
        age_words "$bt_h"
        log "Strongest by company (last $AW):"
        [ "$R_void" != true ] || bt_max=$((bt_max - 1))
        bt_i=0
        while IFS= read -r bt_l; do
            [ "$bt_i" -lt "$bt_max" ] || break
            [ -n "$bt_l" ] || continue
            log "$bt_l"; bt_i=$((bt_i + 1))
        done <<EOF
$(rec_lines blist)
EOF
    fi
    [ "$R_void" != true ] || log "No valid scan now; showing held records."
}

# Air quality: the page's Air drawer as a LOG block. Per band the busiest channels (overlap load) with
# co-/adjacent-channel counts, the least occupied of the usual set, and the beacon airtime as an
# ESTIMATED lower bound (one beacon per AP every 102.4 ms, 200 bytes at 1 Mbit/s on 2.4 GHz or
# 6 Mbit/s on 5/6 GHz).
# On the page's model, as in JQLIB (pgaps, ld2, beaconpct); pgaps runs once for the crowding level and the three band blocks.
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
# and takes one `date`: no jq of its own.
scan_age() {
    # a leading zero is no number here: the shell's arithmetic would read it as octal, and 08 or 09 would end the Overview
    sg=${R_gen-}; case $sg in ''|0?*|*[!0-9]*) return 1 ;; esac
    [ "${#sg}" -le 11 ] || return 1
    si=${R_interval-}; case $si in ''|0|0?*|*[!0-9]*) si=${OV_INT:-${STARCHORUS_INTERVAL:-30}} ;; esac
    case $si in ''|0|0?*|*[!0-9]*) si=30 ;; esac
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
    case ${R_interval-} in ''|0|0?*|*[!0-9]*) ;; *) OV_INT=$R_interval ;; esac
    stamp
    log "A: Refresh   B: Back"
    if [ "$1" = summary ]; then
        fu=${STARCHORUS_PAGE_URL:-}; fu=${fu#http://}; fu=${fu%/}
        [ -z "$fu" ] || log "Web page: $fu"
    fi
}

# ------------------------------------------------------------------ --selftest (read-only device check)
# sh starchorus-display.sh --selftest       (over ssh or from a shell on the device)
# One "[display-selftest]   PASS: name" or "[display-selftest]   FAIL: name" line per check, then a last line
# "[display-selftest] SELFTEST: ALL PASS (N checks)" or "[display-selftest] SELFTEST: FAILED (k of N)".
# Written with printf straight to stdout, not through log(): it is meant to
# be read in a terminal. It runs the REAL JQLIB text above (never a copy) through the jq on PATH, in three
# layers so a failing jq shows WHICH piece is wrong: (1) one probe per jq builtin / syntax form the
# filters use, each on its own line; (2) a small table of bandnorm / secupper / isopenwep / sectag inputs
# (modelled on the oracle in tools/regress.d/jq-noregex.sh, far smaller), with the Bluetooth and activity helpers; (3) the jq_healthy
# probe and screen_summary, screen_bands and screen_bluetooth over a tiny embedded fixture; (4) the key names the Overview's key reader uses (keyname: padded answers, BACK, Escape, lower case); (5) the nap of the key wait (ov_nap: its three stages, and the two places that start the count over). INFO lines are informational and never change the verdict.
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
# st_btdoc SOURCE CENTER-EXTRA: a capture of fourteen records in eleven companies (five named, five by id, one with no company at all), strongest first, for the cap of the Bluetooth screen
st_btdoc() {
    printf '{"source":"%s","center":{"label":"selftest"%s},"unassociated":[],"aps":[],"bluetooth":[' "$1" "$2"
    st_i=0
    while [ "$st_i" -lt 14 ]; do
        case $((st_i % 3)) in
            0) st_c=",\"company\":$((100 + st_i)),\"company_name\":\"Maker $st_i\"" ;;
            1) st_c=",\"company\":$((300 + st_i))" ;;
            *) st_c= ;;
        esac
        [ "$st_i" = 0 ] || printf ','
        printf '{"addr":"02:00:00:00:02:%02d","addr_type":"random-resolvable","rssi":%d%s}' "$st_i" $((-40 - st_i)) "$st_c"
        st_i=$((st_i + 1))
    done
    printf ']}\n'
}
st_cap() {  # st_cap LABEL SOURCE CENTER-EXTRA WANT: screen_bluetooth on that capture shows WANT company lines and at most ten lines in all (the frame adds two: twelve)
    st_btdoc "$2" "$3" > "$ST_TMP"
    st_o=$(screen_bluetooth 2>&1)
    st_n=$(printf '%s\n' "$st_o" | grep -c ' dBm  '); st_l=$(printf '%s\n' "$st_o" | grep -c .)
    if [ "$st_n" = "$4" ] && [ "$st_l" -le 10 ]; then st_pass "screen_bluetooth: the cap on eleven companies, $1: $4 company lines, $st_l lines"
    else st_fail "screen_bluetooth: the cap on eleven companies, $1  (want $4 company lines, got $st_n; $st_l lines, ten at most)"; fi
}
st_has() {  # st_has NAME TEXT grep-args...: PASS iff grep finds its pattern in TEXT (else show the counter lines)
    st_name=$1; st_text=$2; shift 2
    if printf '%s\n' "$st_text" | grep "$@" >/dev/null 2>&1; then st_pass "$st_name"
    else st_fail "$st_name  (got: $(printf '%s\n' "$st_text" | grep -E '^(APs |Open/WEP|No open/WEP|jq incomplete)' | tr '\n' '|'))"; fi
}
st_key() {  # st_key NAME RAW WANT: keyname (the key reader's) turns RAW into WANT: A, B, UP, DOWN, LEFT, RIGHT, or nothing
    keyname "$2"
    if [ "$NK" = "$3" ]; then st_pass "$1"; else st_fail "$1  (got '$NK', want '$3')"; fi
}
# st_cap_state NAME WANT 'PRINTF-ARG' | -: screen_summary on a capture file with that content (- = no file at all) prints exactly the one line WANT
# (the waiting line or the unreadable line), and never the other one. The verdict cache is cleared first: the same file name, size and second would be a hit.
st_cap_run() {   # st_cap_run CONTENT|-: st_o = what screen_summary prints for a capture file of that content (- = none)
    unset CK_summary CV_summary CO_summary
    if [ "$1" = - ]; then JSON=$ST_TMP.none; else printf '%s' "$1" > "$ST_TMP"; JSON=$ST_TMP; fi
    st_o=$(screen_summary 2>&1)
}
st_cap_state() {
    st_cap_run "$3"
    if [ "$st_o" = "$2" ]; then st_pass "$1"; else st_fail "$1  (want '$2', got: $(printf '%s\n' "$st_o" | sed -n 1p | cut -c1-60))"; fi
}
# st_rep N WORD: " WORD" N times (what the stand-in sleep below writes down for N naps of one length)
st_rep() { st_ri=0; while [ "$st_ri" -lt "$1" ]; do printf ' %s' "$2"; st_ri=$((st_ri + 1)); done; }
# st_naps FROM COUNT [fractionless]: the arguments ov_nap passes to sleep over COUNT naps when OV_NAPS stands at FROM. Run in a sub-shell, so the
# stand-in sleep (which only writes its argument down, or, with a third argument, fails on a fraction as an applet with none does) is gone again
st_naps() {
    (
        sleep() { case $1 in *.*) [ -z "$na_w" ] || return 1 ;; esac; printf ' %s' "$1"; }
        na_w=${3:-}; OV_NAPS=$1; na_i=0
        while [ "$na_i" -lt "$2" ]; do ov_nap; na_i=$((na_i + 1)); done
    )
}
# st_wait NAPS FROM: ov_await with the queue empty for NAPS naps, then one key ("50 A"), OV_NAPS standing at FROM when it starts. Prints the arguments
# the stand-in sleep got, then |KEY|KEY_CS|OV_NAPS (the last when it ended). Run in a sub-shell (the caller captures it), so the stand-ins are gone again
st_wait() {
    sleep() { printf ' %s' "$1"; ST_NS=$((ST_NS + 1)); }
    ov_counts() { [ "$ST_NS" -ge "$ST_WN" ] || return 1; CN_L=1; return 0; }
    ov_qnext() { QL="50 A"; OV_QN=1; return 0; }
    ST_WN=$1; ST_NS=0; OV_QN=0; OV_RPID=$$; OV_RDONE=/dev/null; OV_NAPS=$2
    ov_await
    printf '|%s|%s|%s' "$KEY" "$KEY_CS" "$OV_NAPS"
}
# st_draw FROM: draw with OV_NAPS standing at FROM; prints OV_NAPS afterwards (render and frame stand in; sub-shell as above)
st_draw() {
    render() { :; }; frame() { :; }; ov_counts() { return 1; }; ov_cut() { return 1; }
    OV_NAPS=$1; OV_LIVE=
    draw summary
    printf '%s' "$OV_NAPS"
}
# st_nap NAME WANT GOT: PASS iff GOT is WANT
st_nap() {
    if [ "$2" = "$3" ]; then st_pass "$1"; else st_fail "$1  (want '$2', got '$3')"; fi
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
    # (no regex builtin: see the NO REGEX block)

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
    # the Bluetooth screen and the activity bars: a string built with add over a range, a max over numbers, a slice of a sorted list
    st_probe "builtin add over strings" '["#", "-", "-"] | add' '"#--"'
    st_probe "builtin max over numbers after a map" '[{"r": -61}, {"r": -48}] | map(.r) | max' '-48'

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
    # Bluetooth and activity: the list the page keeps (objects with a numeric rssi), the company a record is counted under, the eight cells of
    # a share, and a band's bar (the page's band edges); a capture without the array or the entries shows nothing
    st_lib 'btlist | length' '{"bluetooth":[{"rssi":-50},{"rssi":"x"},3,null,{"rssi":-60}]}' '2'
    st_lib 'btlist' '{}' 'null'
    st_lib btco '{"company_name":"Maker A","company":65535}' '"Maker A"'
    st_lib btco '{"company":65535}' '"company id 65535"'
    st_lib btco '{"company_name":"  ","company":70000}' '"company not advertised"'
    st_lib btco '{"company":2.5}' '"company not advertised"'
    st_lib bar8 '0.78' '"######--"'
    st_lib bar8 '0' '"--------"'
    st_lib bar8 '1' '"########"'
    st_lib 'actbar(2400; 2500)' '{"activity":[{"freq":2412,"share":0.5},{"freq":2437,"share":0.25},{"freq":5180,"share":0.25}]}' '"######-- 75%"'
    st_lib 'actbar(4900; 5925)' '{"activity":[{"freq":2412,"share":0.5},{"freq":5180,"share":0.25},{"freq":5955,"share":0.25}]}' '"##------ 25%"'
    st_lib 'actbar(2400; 2500)' '{"activity":[{"freq":2412,"share":1.5},{"freq":2417,"share":0},{"freq":2422}]}' ''
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
 "bluetooth":[{"addr":"02:00:00:00:00:b1","addr_type":"random-resolvable","rssi":-50,"company":65535,"company_name":"Maker A"},
              {"addr":"02:00:00:00:00:b2","addr_type":"public","rssi":-60}],
 "activity":[{"freq":2412,"share":0.75},{"freq":5180,"share":0.25}],
 "alerts":[{"type":"deauth","t":3,"ap":"02:00:00:00:00:03","n":2},{"type":"deauth","t":2,"ap":"02:00:00:00:00:01","n":5},{"type":"deauth","t":1,"ap":"02:00:00:00:00:99","n":7}],
 "aps":[{"bssid":"02:00:00:00:00:01","ssid":"Test-A","rssi":-40,"band":"2.4GHz","security":"WPA2/WPA3"},
        {"bssid":"02:00:00:00:00:02","ssid":"Test-B","rssi":-50,"band":" 5 GHz","security":"Open"},
        {"bssid":"02:00:00:00:00:03","ssid":"Test-C","rssi":-60,"band":"5","security":"WEP"},
        {"bssid":"02:00:00:00:00:04","ssid":"Test-D","rssi":-70,"band":"6g","security":"WPA3"}]}
ST_JSON
        JSON=$ST_TMP
        st_out=$(screen_summary 2>&1)
        st_bt=$(screen_bluetooth 2>&1)
        st_bd=$(screen_bands 2>&1)
        # the cap of the Bluetooth screen, on a capture of fourteen records in eleven companies (so that it has to take effect): seven company lines, one fewer under a void window and one
        # fewer under the ACTIVE claim (each of them takes a line of the screen's budget), five under both; ten lines in all, twelve with the frame
        st_cap "plain" selftest '' 7
        st_cap "a void window" selftest ',"bt_window":0' 6
        st_cap "the ACTIVE claim" selftest-ACTIVE '' 6
        st_cap "a void window under the ACTIVE claim" selftest-ACTIVE ',"bt_window":0' 5
        rm -f "$ST_TMP"; ST_TMP=
        st_has "screen_summary: band counters are digits" "$st_out" -Eq '2\.4:[0-9]+ +5:[0-9]+ +6:[0-9]+'
        st_has "screen_summary: band counts match the fixture (2.4:1 5:2 6:1)" "$st_out" -qF '2.4:1  5:2  6:1'
        st_has "screen_summary: open/WEP line matches the fixture (2)" "$st_out" -qxF 'Open/WEP networks: 2'
        st_has "screen_summary: the Bluetooth figure follows the band counts (BT 2)" "$st_out" -qxF 'APs 4   ·   2.4:1  5:2  6:1  BT 2'
        st_has "screen_summary: the alert line counts the access points the capture holds (2 of 3 reports)" "$st_out" -qxF 'Deauth/disassoc frames heard: 2 APs'
        st_has "screen_bands: a band's activity bar (2.4: 75 percent)" "$st_bd" -qxF '  2.4 GHz: 1 AP(s)  act ######-- 75%'
        st_has "screen_bands: the note that explains the bar" "$st_bd" -qxF 'act = share of frames heard (relative)'
        st_has "screen_bluetooth: addresses, rotating and fixed (2, 1, 1)" "$st_bt" -qxF '2 addresses (1 rotating, 1 fixed)'
        st_has "screen_bluetooth: the strongest company first" "$st_bt" -qxF ' -50 dBm  Maker A  (1)'
        st_has "screen_bluetooth: an address without a company is counted as such" "$st_bt" -qxF ' -60 dBm  company not advertised  (1)'
    else
        st_fail "screen_summary end-to-end (no temp file for the fixture)"
    fi
    # (3b) a capture that is no document says so: the waiting line is for a file that is not there yet or is still empty, "Capture unreadable." for one
    # that is cut off, is not JSON or is the one word null; a good document says neither
    ST_TMP=$(mktemp "${TMPDIR:-/tmp}/starchorus-display-st.XXXXXX" 2>/dev/null) || ST_TMP=
    if [ -n "$ST_TMP" ]; then
        st_cap_state "capture states: a cut-off document is unreadable, not waiting" "$BAD1" '{"aps":[{"bssid":"02:00'
        st_cap_state "capture states: text that is no JSON is unreadable" "$BAD1" 'not json'
        st_cap_state "capture states: the one word null is unreadable" "$BAD1" 'null'
        st_cap_state "capture states: an empty file is still waiting" "$WAITING" ''
        st_cap_state "capture states: a missing file is still waiting" "$WAITING" -
        st_cap_run '{"aps":[]}'
        if printf '%s\n' "$st_o" | grep -q '^APs 0 ' && ! printf '%s\n' "$st_o" | grep -qxF -e "$BAD1" -e "$WAITING"; then st_pass "capture states: a good document says neither line"
        else st_fail "capture states: a good document says neither line  (got: $(printf '%s\n' "$st_o" | sed -n 1p | cut -c1-60))"; fi
        rm -f "$ST_TMP"; ST_TMP=
    else
        st_fail "capture states (no temp file for the fixtures)"
    fi
    # (4) the key reader's names. Pure shell, no jq: the reader and the shell both turn what WAIT_FOR_INPUT printed into a key with keyname, which strips
    # spaces, tabs and CR with parameter expansions that the device's shell has to get right (the stand-ins of the regression run only prove them on a
    # laptop's); BACK and Escape count as B and a lower-case a or b as the capital; any other word, an empty answer included, is no key (a strike)
    st_key "keyname: BACK is B" "BACK" B
    st_key "keyname: Escape is B" "Escape" B
    st_key "keyname: a lower-case b is B" "b" B
    st_key "keyname: a lower-case a is A" "a" A
    st_key "keyname: spaces, a tab and a CR around the word are stripped" " $TAB RIGHT $TAB$CR" RIGHT
    st_key "keyname: a word nobody knows is no key" "left" ""
    st_key "keyname: an empty answer is no key" "" ""
    # (5) the nap of the key wait: the Overview's three stages and the two places that start them over. Pure shell, no jq; every run is a sub-shell with a
    # stand-in sleep that only writes its argument down, so nothing is slept and no process is started. Stage one is 15 naps of 0.2 s (about 3 s),
    # stage two 54 naps of 0.5 s (up to about 30 s), then 1 s a nap; the counter is the clock
    st_nap "ov_nap: the first 15 naps are 0.2 s" "$(st_rep 15 0.2)" "$(st_naps 0 15)"
    st_nap "ov_nap: the 16th to the 69th nap are 0.5 s" "$(st_rep 54 0.5)" "$(st_naps 15 54)"
    st_nap "ov_nap: the 70th nap and every one after is 1 s" "$(st_rep 4 1)" "$(st_naps 69 4)"
    st_nap "ov_nap: the stages meet where they should (14: 0.2, 0.5, 0.5; 68: 0.5, 1, 1)" "$(st_rep 1 0.2)$(st_rep 2 0.5) $(st_rep 1 0.5)$(st_rep 2 1)" "$(st_naps 14 3) $(st_naps 68 3)"
    st_nap "ov_nap: a sleep with no fractions naps a whole second at every stage" "$(st_rep 72 1)" "$(st_naps 0 72 whole)"
    st_nap "ov_nap_short: 0.2 s whatever the count" "$(st_rep 1 0.2)" "$( (sleep() { printf ' %s' "$1"; }; OV_NAPS=500; ov_nap_short) )"
    # the wait itself: the queue is empty for a few naps, then a key comes (stand-ins for the queue reads; the reader is this shell, which is alive)
    st_nap "ov_await: three naps of 0.2 s, then the key, and the count starts over" "$(st_rep 3 0.2)|A|50|0" "$(st_wait 3 0)"
    st_nap "ov_await: after a long idle the naps are 1 s, and a key taken sets the count back to 0" "$(st_rep 2 1)|A|50|0" "$(st_wait 2 100)"
    # a screen drawn sets the count back too (render and frame stand in, so no jq runs)
    st_nap "draw: a screen drawn sets the count of naps back to 0" "0" "$(st_draw 100)"
    st_verdict
}

# ------------------------------------------------------------------ main loop
render() {
    case "$1" in
        top|bands|devices|probes|clients|bluetooth|air) "screen_$1" ;;
        *) screen_summary ;;
    esac
}

if [ "$1" = "--once" ]; then
    command -v jq >/dev/null 2>&1 || { err_dialog "Overview needs jq."; exit 1; }
    [ -n "$3" ] && JSON=$3
    render "$2"
    exit 0
fi

# draw VIEW: one screen as its block of LOG lines and, last, its frame. A draw that has to run jq says "Reading..." first (busy(),
# once per draw). It runs with the key reader's wait already open. A draw ends early for a key that asks for another screen: while a
# draw runs OV_GATE is 1, and once a B, Left or Right is waiting in the queue (ov_cut) log() prints nothing, fetch() and jq_healthy()
# start no jq, a jq that is running is ended (ov_jq), frame is not started and a cut draw keeps no verdict. An A, Up or Down does not
# end it: the draw finishes, and an A that came in it is answered by it (OV_QC, below). OV_QC is the number of lines the queue held when
# the block was done, before the frame: a key taken with OV_QN at or below it was pressed during this draw, and one above it after the
# screen was complete, because the frame is the last thing printed. The count is read before the frame on purpose, so that a press made
# the moment the frame is out is certainly a later one. R_gen and R_interval are cleared first: a screen that has nothing to show
# (waiting, slow) must not borrow the time of the screen before.
draw() {
    OV_BUSY=0; FX_SLOW=0; FX_BAD=0; unset R_gen R_interval
    [ "$OV_LIVE" != 1 ] || OV_GATE=1
    render "$1"
    ov_counts && OV_QC=$CN_L
    ov_cut || frame "$1"
    OV_GATE=
    OV_NAPS=0   # a screen was drawn: the wait that follows starts with the short nap again
}

# The screens in the order of the list and of Left / Right, wrapping round at both ends. step sets view to the neighbour,
# row_of names the list row of the current view, view_of turns a list answer back into a view (status 1: not one of ours).
step() {
    case $1$view in
        RIGHTsummary) view=top ;; RIGHTtop) view=bands ;; RIGHTbands) view=devices ;; RIGHTdevices) view=probes ;;
        RIGHTprobes) view=clients ;; RIGHTclients) view=bluetooth ;; RIGHTbluetooth) view=air ;; RIGHTair) view=summary ;;
        LEFTsummary) view=air ;; LEFTtop) view=summary ;; LEFTbands) view=top ;; LEFTdevices) view=bands ;;
        LEFTprobes) view=devices ;; LEFTclients) view=probes ;; LEFTbluetooth) view=clients ;; LEFTair) view=bluetooth ;;
    esac
}
row_of() {
    case $view in
        top) ROW="Strongest Networks" ;; bands) ROW="Bands & Security" ;; devices) ROW="Devices & Merges" ;;
        probes) ROW="Probe Requests" ;; clients) ROW=Stations ;; bluetooth) ROW=Bluetooth ;; air) ROW="Air Quality" ;; *) ROW=Summary ;;
    esac
}
view_of() {
    case $1 in
        Summary) view=summary ;; "Strongest Networks") view=top ;; "Bands & Security") view=bands ;;
        "Devices & Merges") view=devices ;; "Probe Requests") view=probes ;; Stations) view=clients ;;
        Bluetooth) view=bluetooth ;; "Air Quality") view=air ;; *) return 1 ;;
    esac
}

# --selftest is dispatched BEFORE the jq gate on purpose (after the screens and the loop's helpers are defined, so that the self-test can run draw): without jq it still has to print "FAIL: jq present"
# and the FAILED line (exit 1) instead of taking the err_dialog + exit 1 path of a normal run.
if [ "${1:-}" = "--selftest" ]; then display_selftest; exit $?; fi

# The Overview. On the device the first things that happen are the traps, the private temp dir and the key reader's first wait, and only
# then the first line (before any jq call, so the screen still answers at once): the wait is registered while the heading goes out, not
# after it, which is the one stretch the start can keep unopened. The reader (see The key reader) runs from then on; every pass of the loop
# is draw (when something asks for one), then take the next key from the queue, napping until there is one, with parent_gone asked after
# each key and again after the list. The first pass draws the summary; after that nothing is drawn unless a key asks for it. The keys are as
# in the header: A draws again, unless it came during a draw (OV_QC, see draw), which answers it; Left and Right step and draw; Up and Down
# ask for nothing; anything else is a strike when it came back within 1 s of its wait being opened (STRIKE_CS) or when there is no clock
# to tell, and the third in a row ends the Overview: an empty answer at once means the key path is broken, and this must not become a busy
# loop (the reader stops on the same third answer, so the queue cannot fill up meanwhile). The same answer after a real wait (a second or
# more) is a UI that took its time: the count starts over. A B ends the reader (it ended itself on that B) and opens the list "Overview",
# which is a wait of its own, so no wait of the reader's is open while it is up; when it returns, a new reader starts and the screen is
# drawn. Every exit is through ov_cleanup. No menu of its own: starting and stopping belong to the payload.
command -v jq >/dev/null 2>&1 || { log blue "Overview"; err_dialog "Overview needs jq."; exit 1; }
view=summary
[ "$ONDEV" = 1 ] || { log blue "Overview"; draw summary; exit 0; }   # dev fallback: one screen, no keys, no reader
# The queue and its files live in a private temp dir (umask 077 makes it 0700 with no process of its own) that the EXIT trap removes. The
# traps come first, so no signal can find a dir they would not clean up; TERM, INT and HUP end the Overview through `exit`, which runs
# ov_cleanup. The files are written once, here, so that a file system with no room left is an error at the start and not three empty
# answers later (ov_await names the same failure later on).
trap ov_cleanup EXIT
ov_trap_exit
OV_TMP=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/starchorus-ov.XXXXXX" 2>/dev/null) || {
    OV_TMP=
    log blue "Overview"
    err_dialog "Overview could not start."
    exit 1
}
OV_QUE=$OV_TMP/queue; OV_CNT=$OV_TMP/count; OV_RAW=$OV_TMP/raw; OV_JQO=$OV_TMP/jq; OV_RDONE=$OV_TMP/done; OV_WPF=$OV_TMP/wpid; OV_QUIT=$OV_TMP/quit
{ printf x > "$OV_QUE" && printf '0 0\n' > "$OV_CNT" && printf x > "$OV_RAW" && printf x > "$OV_JQO" && printf x > "$OV_RDONE" && printf x > "$OV_WPF"; } 2>/dev/null || {
    log blue "Overview"
    err_dialog "Overview could not start."
    exit 1
}
: > "$OV_QUE"; : > "$OV_RDONE"; : > "$OV_WPF"
OV_LIVE=1; bad=0; again=1; first=1
parent_gone && exit 0
ov_rstart
while :; do
    [ -z "$first" ] || { log blue "Overview"; first=; }
    [ "$again" = 0 ] || draw "$view"
    ov_await
    parent_gone && exit 0
    [ -z "$KEY_ERR" ] || { ov_wkill; err_dialog "Overview could not read a key."; exit 1; }   # the orphan wait first, so that it cannot take the dialog's press
    again=0
    case $KEY in
        A) bad=0; [ "$OV_QN" -le "$OV_QC" ] || again=1 ;;
        LEFT|RIGHT) bad=0; step "$KEY"; again=1 ;;
        UP|DOWN) bad=0 ;;
        B) bad=0; row_of
           ov_rstop
           sel=$(pick "Overview" "Summary" "Strongest Networks" "Bands & Security" "Devices & Merges" "Probe Requests" "Stations" "Bluetooth" "Air Quality" "$ROW") || exit 0
           parent_gone && exit 0
           view_of "$sel" || exit 0
           ov_rstart; again=1 ;;
        *) if [ -z "$KEY_CS" ] || [ "$KEY_CS" -lt "$STRIKE_CS" ]; then bad=$((bad + 1)); [ "$bad" -lt 3 ] || exit 0; else bad=0; fi ;;
    esac
done
