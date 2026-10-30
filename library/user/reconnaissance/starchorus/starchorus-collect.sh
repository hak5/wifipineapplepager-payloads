#!/bin/sh
#
# Title:        Starchorus passive collector
# Description:  STRICTLY PASSIVE, observation-only Wi-Fi recon collector. Listens for
#               beacons / probe requests / probe responses that are already being
#               broadcast and writes a JSON view of nearby access points and client
#               stations to starchorus.json for a visualisation front end.
#               It NEVER transmits an attack frame: no deauth/disassoc, no rogue/evil AP,
#               no injection, no association/connection, no channel jamming, no active
#               features of the device's AP service. It only RECEIVES what the air already carries.
# Author:       Starchorus
# Version:      0.2.6.2
# Contract:     3
# Category:     reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
# Notes:        Monitor-mode capture (tcpdump / airodump-ng) and reading the already-passive
#               device's recon SQLite store are RX-only. `iw scan` transmits probe requests and
#               is therefore treated as ACTIVE: it is DISABLED by default and only runs if you
#               explicitly opt in with STARCHORUS_ALLOW_ACTIVE=1.
#
# ---------------------------------------------------------------------------------------------
# PASSIVITY CONTRACT (read this):
#   Allowed here      : monitor-mode RX (airodump-ng with NO injection, tcpdump, tshark),
#                       reading an existing recon SQLite DB read-only, channel *tuning*
#                       (receiver retuning is not a transmission), and, opt-in only
#                       (STARCHORUS_SOURCE=pineap), the AP service's two read-only recon list
#                       commands (RECON APS / RECON DEVICES, format=json; docs/device-notes.md V-3).
#                       Opt-in only (STARCHORUS_TRAFFIC=1): one more read-only command of the AP service,
#                       RECON CHANNELS (frames counted per frequency), and the frame counter of the stations
#                       in the recon database. Opt-in only (STARCHORUS_BLUETOOTH=1): ONE passive Bluetooth LE
#                       scan window per cycle (bt_begin, the one place a Bluetooth tool is started: a passive scan,
#                       which sends no scan request and only listens to advertisements that devices broadcast
#                       anyway, and the monitor that decodes what the controller hands the host). A window counts
#                       only when that monitor shows the scan parameters of the collector's own scan with
#                       Type: Passive before the first report (the witness, bt_parse).
#                       Opt-in only (STARCHORUS_BLUETOOTH=1) with STARCHORUS_BT_SOURCE=blue5, or auto on firmware 2.0 where
#                       the firmware's own scanner holds the controller: reading that scanner's database (blue5.db) read-only,
#                       instead of a window of ours -- a copy in RAM, sqlite3 -readonly, a file read and not a tool start.
#                       Whatever mode the Pager's scanner runs in is the Pager's own setting, outside our control; the read sends nothing.
#                       Reading the alert log (STARCHORUS_ALERTS, on by default): $ALERT_DIR/alerts.log, a text file that the companion
#                       alert payload (alert-deauth.sh) appends to when the firmware reports many deauth/disassoc frames heard for an
#                       access point. Nothing is received or sent for it; the file is read as untrusted text (alerts[], below).
#   Never done here   : aireplay/mdk (deauth), hostapd/airbase (rogue AP), hcxdumptool active,
#                       besside/wifite, associating to any BSS, AP-service impersonation / beacon
#                       responses / SSID pool broadcast; a Bluetooth inquiry or active scan, advertising,
#                       a connection, pairing, GATT access or echo request, and any change to the
#                       controller beyond a passive scan's parameters and its enable and disable.
#                       This script contains none of those.
# ---------------------------------------------------------------------------------------------
#
# USAGE:
#   ./starchorus-collect.sh            # run forever, rewrite the JSON every INTERVAL seconds
#   ./starchorus-collect.sh --once     # do a single scan/parse cycle, then exit  (good for crond); exit 0 = the document was published,
#                                        1 = it was not (the directory cannot be made or written, the pass failed and the last document stays)
#   ./starchorus-collect.sh --stop     # stop a previously started background instance (loop+airodump)
#   ./starchorus-collect.sh --status   # report whether a loop / airodump is running
#   ./starchorus-collect.sh --selftest # run offline self-tests with embedded sample data (no HW)
#   ./starchorus-collect.sh --help     # short help
#
# CONFIG (override via environment, e.g. `STARCHORUS_IFACE=wlan1mon ./starchorus-collect.sh`):
#   STARCHORUS_INTERVAL       Seconds between JSON rewrites, 1 to 3600; anything else is 5, with one log line.  (default 5)
#   STARCHORUS_OUTDIR         Directory for starchorus.json.                      (default /tmp/starchorus)
#   STARCHORUS_IFACE          Monitor interface to use, or "auto" to detect. (default auto)
#   STARCHORUS_SOURCE         auto|capture|recondb|pineap|iwscan  data source. pineap = the AP service's
#                        own recon lists (read-only commands, opt-in; see PINEAP below).  (default auto)
#   STARCHORUS_PINEAP_CALLS   pineap only: recent = ONE bounded RECON DEVICES (bytime=true limit=400; its passivity, the
#                        newest-first ordering and the 400-cut are verified on the device, device-notes §5a and §6a),
#                        the access points taken from the beacon records in it; full = RECON APS + RECON DEVICES, both
#                        unbounded, so every device of the AP service's session is parsed (about 22 ms of the device's CPU
#                        each: 46 s for 2,100 devices).  (default recent)
#   STARCHORUS_RECON_DB       Path to recon SQLite DB, or "auto" to find it. (default auto)
#   STARCHORUS_ALLOW_ACTIVE   1 = allow the ACTIVE `iw scan` fallback.       (default 0 = never)
#   STARCHORUS_CREATE_MON     1 = allow creating a monitor VIF if none.      (default 1)
#   STARCHORUS_MAX_AGE        recon.db and pineap only: show only devices seen in the
#                        last N seconds (live-presence view). 0 = off,
#                        show the full accumulated history.             (default 0)
#   STARCHORUS_CAPDIR         Where capture files, the vendor cache and the OUI index are written.   (default $OUTDIR/cap)
#   STARCHORUS_TMPDIR         recondb and pineap only: where the work copy of recon.db lives (RAM: /tmp is tmpfs on
#                        the device, so the 3.5 MB copy is not written to flash every cycle), and, for pineap, the
#                        security cache starchorus-sec.txt (not a writable directory: every access point reads
#                        Unknown). With less room than the database copy needs, $CAPDIR is used for that copy.   (default /tmp)
#   STARCHORUS_SKIP_UNCHANGED  recondb only: 1 = a cycle whose recon.db (size, mtime, journal) is the same as at
#                        the last full pass, and in which no row can have left the window, only refreshes
#                        "generated" in the document of that pass; 0 = always rebuild. The Bluetooth and traffic layers are still taken every
#                        cycle (with Bluetooth on, a skipped cycle lasts about the window).   (default 1)
#   STARCHORUS_PIDDIR         Where pidfiles live.                           (default $OUTDIR)
#   STARCHORUS_VENDOR         1 = add the optional "vendor" / "randomized" fields via a LOCAL,
#                        passive MAC-prefix (OUI) file lookup; 0 = never (no post-pass:
#                        the plain emitter JSON is published).          (default 1)
#   STARCHORUS_OUI_FILE       auto | path. auto tries, in order: /lib/hak5/oui.txt,
#                        /usr/share/nmap/nmap-mac-prefixes, /usr/share/macchanger/OUI.list,
#                        skipping any candidate whose format is not parsable. nmap / IEEE
#                        oui.txt / macchanger / Wireshark-manuf files work (also from a USB
#                        stick). Missing/unusable file => no "vendor" field ("randomized"
#                        is still derived from the MAC itself), one log line.  (default auto)
#   STARCHORUS_BT_COMPANIES_FILE  auto | path. The Bluetooth company-identifier list that names the
#                        companies the blue5 source reports by number alone (id<TAB>name, the id four
#                        hex digits: the firmware's /lib/hak5/bt_companies.txt). auto takes that file
#                        when it parses. Missing/unusable file => the company id alone, as before, one
#                        log line. The window source names companies itself.          (default auto)
#   Everything that depends on device behaviour that is not verified yet is a FLAG, default OFF:
#   STARCHORUS_HOPINFO        1 = top-level "channels": [{"freq", "last_heard"}] from the recon.db `time`
#                        column (the front-end never calls an AP "gone" without it).  (default 0)
#   STARCHORUS_SURVEY         1 = add "busy_pct" / "noise" to channels[] from `iw dev IF survey dump`
#                        (read-only netlink dump; IF = STARCHORUS_SURVEY_IFACE or the monitor VIF). (default 0)
#   STARCHORUS_OWN            1 = center."own_bssids" (this device's interface MACs from
#                        /sys/class/net/*/address) and center."own_ssids" (ONLY from the file in
#                        STARCHORUS_OWN_SSID_FILE, one SSID per line -- never from the AP service's SSID pool). (default 0)
#   STARCHORUS_HOMING_BSSID   one access point to home in on: adds a top-level "homing": {"bssid","dbm","peak","t"} taken from that AP's row
#                        in the same document. Refused, with no field and no error: a station, a BSSID not in this document's aps[] and
#                        one of our own transmitters. Nothing is transmitted or looked up. Also read from the first line of
#                        $STARCHORUS_OUTDIR/homing.target (the device writes it). Coarse: one reading per cycle.  (default: none)
#   STARCHORUS_APCLI_RO       1 = apcli_ro() may run its three literal read-only list lines (see there); nothing calls it
#                        except the pineap source, which switches it on for itself (spec §14.6). The refusal rules are self-tested.  (default 0)
#   STARCHORUS_BLUETOOTH      1 = every cycle runs ONE passive Bluetooth LE scan window (STARCHORUS_BT_WINDOW seconds, in the background
#                        beside the source build) and writes the top-level "bluetooth" array and center."bt_window"/"bt_hold". Needs a
#                        controller (hci0) and the scan tools; without them it stays off with one log line. Addresses, not devices.  (default 0)
#   STARCHORUS_BT_WINDOW      the window length in whole seconds, 5 to 15; anything else is 5 with one log line.  (default 5)
#   STARCHORUS_BT_SOURCE      auto|blue5|window: where the Bluetooth layer gets its records, only with
#                        STARCHORUS_BLUETOOTH=1. auto = the firmware's own database (blue5.db) when present, else our
#                        own window; blue5 = always that database (firmware 2.0); window = always our own passive LE scan.
#                        Any other value turns Bluetooth off for that cycle (one log line).  (default auto)
#   STARCHORUS_BLUE5_DB       the firmware's Bluetooth database for STARCHORUS_BT_SOURCE=blue5 and auto: copied to RAM and
#                        read sqlite3 -readonly, like recon.db but with no flash copy and no read of the live file.  (default /root/recon/blue5.db)
#   STARCHORUS_TRAFFIC        1 = the first cycle and then every second one reads RECON CHANNELS (the fifth literal line of apcli_ro, gated on
#                        this flag alone, in the background) into the top-level "activity" array (a share per frequency, never a count); the
#                        cycles in between publish the answer of the cycle before again, as the AP service counts over a window of 20 to 30 s.
#                        The recon database path adds the cumulative frame counter "packets" to stations heard in the last 300 s.  (default 0)
#   STARCHORUS_ALERTS         1 = each cycle reads $ALERT_DIR/alerts.log when that file exists (the companion alert payload alert-deauth.sh writes it, one
#                        line per deauth/disassoc alert of the firmware: EPOCH, deauth, AP, SOURCE, DESTINATION, CLIENT, tab separated) and writes the
#                        top-level "alerts" array; without the file nothing is read and no key is written. Runs nothing and sends nothing.  (default 1)
#   STARCHORUS_ALERT_DIR      the directory of alerts.log: a directory of its own outside the one the page server serves, default /root/loot/starchorus-alerts
#                             (the companion uses the same default and runs without the payload's environment; the variable is an override for tests)
#   STARCHORUS_ALERT_WINDOW   the seconds an alert stays in "alerts": whole seconds from 60 to 86400; anything else is 600, with one log line.  (default 600)
#   STARCHORUS_SYSFS_BT       tests only: where the controller is looked for (default /sys/class/bluetooth), like STARCHORUS_SYSFS_NET.
#   STARCHORUS_PROC_BT        tests only: where the Bluetooth window code reads /proc from (default /proc).
#
# OPTIONAL JSON FIELDS (all additive; a field is simply ABSENT when unknown, never null):
#   AP     : "vendor" (string, from the OUI file, every source), "rate" (int, Mbit/s: airodump Speed,
#            or the highest legacy rate in a tcpdump beacon, <= 54: without -v tcpdump prints only the
#            Supported Rates IE), "last_seen" (int, Unix seconds, recon.db MAX(time), running schema
#            only, and the pineap source's `time`; airodump's local-time text is deliberately NOT converted: DST-ambiguous). tcpdump
#            also fills "channel"/"freq"/"band" from "CH: n" (or the radiotap MHz prefix) and
#            "security" = "Secured"/"Open" from the PRIVACY bit.
#   client : "vendor", "randomized": true (locally-administered / private MAC, no lookup
#            done), "last_seen" (recon.db and pineap only). Same for associated and unassociated clients.
#   AP, recon.db and the pineap source on firmware 2.0 (never a station): "akm" (["psk","sae",...]), "cipher" ({"group", "pairwise": []}),
#            "auth" (["open","sae",...]) decoded from libwifi's encryption_info (layout pinned above
#            build_from_recondb); "security" says OWE for OWE, "WPA2-Enterprise"/"WPA3-Enterprise" for
#            802.1X AKMs, "WPA2 (TKIP)"/"WPA (TKIP)" for TKIP-only; "responded_ssids" (int >= 2: how many
#            different SSIDs this BSSID answered probes with).
#   center : "max_age" (int, the STARCHORUS_MAX_AGE window; 0 = the whole record) and "interval" (int, seconds
#            between rewrites), always; "own_bssids"/"own_ssids" with STARCHORUS_OWN=1; "bt_window" (int, seconds: the
#            window this document was scanned with, 0 = no valid window this cycle) and "bt_hold" (int, seconds a record
#            is carried after its window) together with the "bluetooth" array. With STARCHORUS_BT_SOURCE=blue5 the
#            document instead carries "bt_source": "blue5" and "bt_hold" and no "bt_window" (the records come from the
#            firmware's database, not a window of ours).
#   station, recon.db only, STARCHORUS_TRAFFIC=1: "packets" (int >= 0: the cumulative frame counter of the rows of that MAC heard
#            in the last 300 s; a new recon session starts a new, smaller counter, so the consumer takes a drop as a first sight).
#   top level: "bluetooth" (array, STARCHORUS_BLUETOOTH=1: one record per ADDRESS heard in the last passive window or held for
#            "bt_hold" seconds: addr, addr_type, rssi, reports, last_seen (our own window: the "generated" of the cycle that heard
#            it; the blue5 source: the database's own value), and when
#            advertised company, company_name, name, connectable; at most 256, strongest first; addresses, not devices: random
#            addresses rotate), "activity" (array,
#            STARCHORUS_TRAFFIC=1: {"freq", "share"} per frequency from RECON CHANNELS, shares of the frames counted on all
#            frequencies from 2400 MHz, three decimals, never a count; "channels" is not touched by it), "alerts" (array, STARCHORUS_ALERTS=1
#            and an alerts.log with lines of the last STARCHORUS_ALERT_WINDOW seconds: {"type": "deauth", "t", "ap", "n"}, one per access
#            point address, "t" the newest epoch of its lines and "n" how many there are; at most 20, newest first, then by address. A line
#            whose epoch is not digits, whose type is not deauth, whose AP is not an address or whose epoch lies more than 60 s ahead is
#            skipped, and said once per episode. It means that many deauth/disassoc frames were heard for that AP: no channel, no signal
#            strength, no count of frames, and the log's source address is usually not the sender's).
#   NOT filled: "first_seen" (the `time` column may be an upsert time), "width" (MHz), "phy" (a/b/g/n/ac/ax), "caps": no
#            passive source on the device carries them (recon.db has no such columns, tcpdump without -v
#            prints no HT/VHT/HE IEs, airodump CSV has no width column). OPTIONAL in the front-end contract. "packets" is
#            filled only by the recon.db path with STARCHORUS_TRAFFIC=1 (what the counter counts: docs/device-notes.md V-10).
#
# SIGNALS: INT, TERM and HUP end the process through cleanup() (exit codes 130, 143, 129), and so does the end of the script
# (EXIT). During a Bluetooth window cleanup() sends SIGINT to the two scan processes at once and again after at most 2 s,
# parses nothing and returns within about 2.5 s; the dead-man timers of their `timeout` wrappers and the next daemon start
# (bt_sweep) end what is left.
#
# The exact monitor interface name, recon DB path, and available tools DIFFER per device.
# This script detects and degrades; see the "NOTES / DEVICE FACTS" section at the bottom.

# --------------------------------------------------------------------------- configuration
INTERVAL=${STARCHORUS_INTERVAL:-5}
OUTDIR=${STARCHORUS_OUTDIR:-/tmp/starchorus}
IFACE=${STARCHORUS_IFACE:-auto}
SOURCE=${STARCHORUS_SOURCE:-auto}
RECON_DB=${STARCHORUS_RECON_DB:-auto}
ALLOW_ACTIVE=${STARCHORUS_ALLOW_ACTIVE:-0}
CREATE_MON=${STARCHORUS_CREATE_MON:-1}
MAX_AGE=${STARCHORUS_MAX_AGE:-0}
CAPDIR=${STARCHORUS_CAPDIR:-$OUTDIR/cap}
TMPDIR_RAM=${STARCHORUS_TMPDIR:-/tmp}
SKIP_UNCHANGED=${STARCHORUS_SKIP_UNCHANGED:-1}
PINEAP_CALLS=${STARCHORUS_PINEAP_CALLS:-recent}
PIDDIR=${STARCHORUS_PIDDIR:-$OUTDIR}
VENDOR=${STARCHORUS_VENDOR:-1}
OUI_FILE=${STARCHORUS_OUI_FILE:-auto}
BTCO_FILE=${STARCHORUS_BT_COMPANIES_FILE:-auto}   # auto | path: the Bluetooth company-identifier list (id<TAB>name) that names the companies the blue5 source reports by number
# Flags, default OFF: see the header (docs/device-notes.md).
HOPINFO=${STARCHORUS_HOPINFO:-0}
SURVEY=${STARCHORUS_SURVEY:-0}
OWN=${STARCHORUS_OWN:-0}
OWN_SSID_FILE=${STARCHORUS_OWN_SSID_FILE:-}
APCLI_RO=${STARCHORUS_APCLI_RO:-0}
BLUETOOTH=${STARCHORUS_BLUETOOTH:-0}
BT_SOURCE=${STARCHORUS_BT_SOURCE:-auto}               # auto|blue5|window: the Bluetooth source when BLUETOOTH=1 (bt_pick)
BLUE5_DB=${STARCHORUS_BLUE5_DB:-/root/recon/blue5.db}  # the firmware's own Bluetooth database, read-only; the auto/blue5 source reads it
TRAFFIC=${STARCHORUS_TRAFFIC:-0}
ALERTS=${STARCHORUS_ALERTS:-1}                    # 1 = read $ALERT_DIR/alerts.log when it exists (the header says what writes it); nothing happens without the file
ALERT_DIR=${STARCHORUS_ALERT_DIR:-/root/loot/starchorus-alerts}   # where the companion alert-deauth.sh writes alerts.log: a directory of its own, outside the one the page server serves
BT_WIN=${STARCHORUS_BT_WINDOW:-5}                 # the window in whole seconds, 5 to 15 (checked below, once the log helper exists)
BT_SYSFS=${STARCHORUS_SYSFS_BT:-/sys/class/bluetooth}   # tests only: where the controller is looked for
# The homing target: ONE access point the operator chose (rules and sources: see STARCHORUS_HOMING_BSSID in the header).
HOMING_BSSID=${STARCHORUS_HOMING_BSSID:-}         # "aa:bb:cc:dd:ee:ff" or empty (then $OUTDIR/homing.target, if it exists)
HOMING_PEAK=""; HOMING_POLLS=0               # peak hold across cycles (a new maximum resets, 12 quiet cycles decay it)

OUTFILE=$OUTDIR/starchorus.json
CAPPREFIX=$CAPDIR/starchorus
AIRODUMP_PIDFILE=$PIDDIR/starchorus-airodump.pid
LOOP_PIDFILE=$PIDDIR/starchorus-loop.pid
CENTER_LABEL="This device"

# Runtime state (filled in by setup)
MONIF=""            # the monitor interface we ended up using
CREATED_MON=0       # 1 if we created it and must tear it down on exit
CAP_METHOD=""       # airodump | tcpdump  (only meaningful when SOURCE resolves to capture)
RESOLVED=none
OUI_PATH=""         # resolved OUI file ("" = none found -> no vendor field)
OUI_CACHE=""        # $CAPDIR/oui-cache.txt once the vendor lookup is active ("" = no cache)
OUI_HDR=""          # header line the cache must carry for OUI_PATH (set by setup_vendor)
OUI_IDX=""          # $CAPDIR/oui-index once it holds the lines of OUI_PATH by first octet ("" = none: a new prefix costs a scan of the OUI file)
OUI_IDX_MAX=1500    # an octet with more lines than this in the OUI file is indexed by its first two octets (see oui_index)
VENDOR_NEWF=""      # this instance's temp file of new cache lines (removed by cleanup)
CACHE_LOCKED=0      # lock depth: >0 while this instance holds $OUI_CACHE.lock (released by cleanup)
VENDOR_STATE=""     # last logged vendor-setup state: setup_vendor logs only when it changes
BTCO_PATH=""        # the Bluetooth company list in use ("" = none: the blue5 source then reports company ids alone)
BTCO_STATE=""       # last logged company-list state: setup_btco logs only when it changes
STARTED_AIRODUMP=0  # 1 if THIS instance started airodump (only then does cleanup stop it)
AD_PID=""           # the pid of that airodump: cleanup stops this one, never the one a later start wrote into the shared pidfile
LOCK_BUDGET=100     # cache_lock: wait at most this long (0.1-s units) for a live holder
LOCK_BUSY_UNTIL=0   # epoch until which cache writes are skipped after a lock give-up (backoff)
# Log-once flags: an episode (a run of cycles with the same failure) is logged once; the flag clears when it ends.
LOCK_BUSY_LOGGED=0  # lock give-up
VENDOR_DROP_LOGGED=0  # dropped cache merge
QDB=""              # the recon.db file the queries read: the RAM copy, the CAPDIR copy or the live file
QDB_RAM=0           # 1 while QDB is a RAM copy this process made (recon_workdone removes it)
RDB_PATH=""         # find_recon_db result kept for the daemon's lifetime (RDB_KEY = the setting it was found for)
RDB_KEY=""
HAS_TIME=""         # ssid has a `time` column: 1 yes, 0 no, "" not known yet (read from the first batch)
RQ_WIN=""           # the alternatives that won in the first batch, " APS1 CLI1 PRB1 " (build_from_recondb; "" = not known: the full batch); dropped with HAS_TIME
RQ_WINT=""          # the TRAFFIC setting they were learnt under (another one: the full batch again)
RQ_STEADY=0         # 1 = this cycle issues the reduced batch (rq_add)
RQ_T=""; RQ_TA=""   # the reduced batch's tail: the numbered alternatives of the groups that have no winner yet, and their names
RQ_SRC=""; RQ_SECT=""   # sq_section: the batch output as one text, and the rows of the section asked for
RW_OFF=0            # passes still to go without the temporary table of the window (rwin): it was refused by the database reader (no marker row after its CREATE), the groups read ssid; 0 = use it
RDB_SCH=""          # the shape of the tables the batch reads (the CREATE texts of ssid, wifi_device and aps), as the pass that learnt RQ_WIN saw it: another one = the file changed shape
RW_USED=0           # 1 = this cycle's batch read rwin
CYC_NOW=""          # the cycle's clock (Unix seconds) while run_cycle has the recon.db document built: build_from_recondb cuts the window from it instead of asking `date` again
RR_N=0; RR_DIR=""; RR_CLS=""; RR_OK=""   # ram_room: cycles since `df` was asked, for which directory and size class, and 1 = the last answer was yes
FLASH_COPY=1        # 1 = a copy under CAPDIR may exist (one made by this process, or by an earlier collector until the first RAM cycle has looked): the next RAM cycle removes it
PACE_T0=""; PACE_NOW=""; PACE_MORE=0   # the loop's pace: when this cycle began and the clock (hundredths of a second since boot, "" = not readable), and the seconds slept beyond INTERVAL after the last cycle
PACE_BT=0           # hundredths of a second this cycle spent waiting (bt_end_timed: the Bluetooth window; build_from_tcpdump: its burst), which is no load and is taken off the cycle's wall time
TEL_T0=0; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0   # the hourly line: when the hour began, the full and the skipped cycles in it, the wall time (hundredths) of the cycles that were timed and their number
DOC_N=""            # doc_whole: the line count of the document it judged whole (rs_keepdoc keeps it for refresh_generated instead of counting again)
RS_SIG=""           # recon.db files (size, mtime, journal) at the last full pass; "" = none, so the next cycle rebuilds
RS_RAW=""           # the same for this cycle, taken once by recon_sample ("" = unknown); the skip test compares it with RS_SIG
RS_NEW=""           # RS_RAW if the next cycle may skip on it (no journal, not changed in the last 2 s), else ""
RS_SZ=0             # size of recon.db in bytes, from the same sample (0 = unknown)
RS_TAKEN=0          # 1 = run_cycle has taken this cycle's sample, build_from_recondb must not take another
RS_WMIN=""          # build_from_recondb: the oldest `time` of any row the window counted ("" = none / not asked)
RS_MIN=""           # the same, kept from the last full pass: the clock the skip test runs the window by ("" = unknown: no skip while there is a window)
RS_DOCV=""          # the document of the last full pass, in this process's memory; a skipped cycle publishes THIS (with a new generated), never what $OUTFILE holds now
RS_DOCN=""          # its line count
CX_EMBED=0          # 1 = build_from_recondb puts center_extra() into the document itself (run_cycle then needs no add_center pass)
CENTER_DONE=0       # 1 = the document of this cycle has its center extras already
RS_TS=0             # when that pass ran
PN_FELL=0           # pineap source: 1 while it has fallen back to recon.db (logged once per episode)
PSEC_T=0            # pineap source: when the security cache was last refreshed from recon.db
PSEC_FAIL=0         # pineap source: 1 while the last security lookup failed (logged once per episode)
RQ_BAIL=""          # "-bail" while the pineap source's security lookup runs its query (see recondb_query)
RQ_ERRF=""          # the file that takes the error output and the exit status of the batch while build_from_recondb runs it ("" = dropped); RQ_WHY = why recondb_failed said so
RQ_WHY=""
RQ_HOLD=""          # set by build_from_recondb when the pass failed on a damaged or torn copy: run_cycle then keeps the last document (see there)
RQ_TORN=""          # set by recon_copy_settle when the file moved during both copies of this cycle: run_cycle says so, once per episode
ST_RAW=""           # recon_stamp's answer, ST_LS = 1 when it is in the `ls` form
ST_LS=1
RS_CFG=""           # the settings the document depends on, then (rs_cfg)
RS_SKIPS=0          # cycles skipped since the last full pass
SKIP_MAX=20         # skip at most this many cycles in a row, then rebuild anyway (belt and braces)
# Bluetooth window state (bt_begin .. bt_end, run_layers). The pids are cleared by bt_begin at its start and by bt_end, and by nothing else.
BT_SPID=""; BT_MPID=""   # the `timeout` wrappers of the scan (S) and of the monitor (M), from $! of the background launch
BT_SKID=""; BT_MKID=""   # the tools themselves, found by command name (bt_kid); empty without /proc
BT_ARM=""           # m / s while the wrapper of the monitor / the scan is being forked: cleanup() then takes its pid from $!
BT_F=""             # this window's text file (the monitor writes it), BT_F.err = stderr of the scan
BT_PF=""            # this collector's pid file, starchorus-bt-<pid>.pid: the one name that bt_begin, bt_note, bt_end, bt_busy and bt_sweep all use
BT_TS=0             # when the scan was started (hundredths of a second, bt_now)
BT_NOW=0            # bt_tick's answer
BT_SLK=0            # extra allowance of the waits that must not end early: 100 while bt_tick has only the whole-second clock of `date`
BT_VOID=""          # why the last window does not count ("" = it does), set by bt_end / bt_judge
BT_NOTES=""         # what happened to the processes of the last window (watchdog, terminated, big)
BT_STRAND=""        # a scan that did not end after a TERM (it may still be scanning, passively): its pid file stays for bt_sweep
BT_BIG=0            # 1 = the text of the last window was over the parse cap (bt_parse read its first and last part only)
BT_RC=3             # bt_begin's answer in this cycle
BT_SRC=window       # bt_pick's choice this cycle: window (our own passive scan), blue5 (read the firmware's database) or none
BT5_DB=""           # the RAM copy of blue5.db this cycle (bt_blue5_copy sets it, bt_blue5_done frees it); "" = none
BT5_RAM=0           # 1 = BT5_DB is a copy of ours to remove after reading
BT5_MAX=4194304     # cap on the blue5.db copy: above this, no Bluetooth this cycle (it is ~40 KB on the device; RAM only)
BT_HELD=""          # last cycle's Bluetooth records (tab separated: the B fields, last_seen, carry); in memory, like RS_DOCV: a file would outlive a killed collector
BT_CUR=" "          # the log keys raised in this cycle, and BT_LOGGED = those of the cycle before: a message is logged once per episode (bt_issue)
BT_LOGGED=" "
BT_FRAC=1           # 0 once a `sleep` of a fraction (0.2 or 0.5) has failed here (bt_nap)
TR_PID=""           # the background RECON CHANNELS call of this cycle
TR_REUSE=0          # 1 = the next cycle reads the answer file of this one again instead of calling: the call is made on the first cycle and then every second one
AL_ON=0             # 1 = alerts.log feeds alerts[] in this cycle (alerts_look: the switch is on and the file is a readable regular file with something in it)
# Bluetooth constants. The times are hundredths of a second of bt_now. A test may set the variables; production never does.
BT_HOLD=120         # seconds a record is carried after its window (center.bt_hold)
BT_T_READY=500      # the monitor has this long to hold its socket before the scan starts (0.5 s idle, over 3 s under a full load on the device, 18 October 2026)
BT_T_KID=100        # how long the tool's own pid is looked for
BT_T_GRACE=100      # the monitor is stopped this long after the scan is gone (it has recorded the disable by then)
BT_T_MON=200        # a monitor that was told to end has this long before TERM, and after TERM before KILL
BT_T_INT=100        # the scan is told to end (INT) this often once it is past its deadline
BT_T_TERM=1200      # after this long without the scan ending on INT: one TERM, never KILL
BT_T_WRAP=200       # a wrapper that outlives its tool by this long gets TERM
BT_MAXB=8388608     # a window's text over this many bytes: the monitor is stopped (busy air)
# Test hooks, all empty or default in production: BT_PROC = where bt_stat reads stat files (the environment's STARCHORUS_PROC_BT, so that a collector
# the self-test starts as a process of its own reads the same stand-in /proc), BT_FAKE = a clock the naps advance (bt_tick, bt_nap; BT_FAKE_NAP = the
# seconds a nap really sleeps then), BT_SIGLOG / BT_SIGMSG = a log of the signals bt_sig sends and a directory that receives INT and TERM instead of
# the processes.
BT_PROC=${STARCHORUS_PROC_BT:-/proc}; BT_FAKE=""; BT_FAKE_NAP=""; BT_SIGLOG=""; BT_SIGMSG=""
# The window length: whole seconds from 5 to 15, anything else is 5, the shortest (the daemon says so once at start, see the main section).
BT_WIN_BAD=""
case $BT_WIN in
    ''|*[!0-9]*) BT_WIN_BAD=$BT_WIN ;;
    *) BT_WIN_N=$BT_WIN
       while [ "${#BT_WIN_N}" -gt 1 ] && [ "${BT_WIN_N#0}" != "$BT_WIN_N" ]; do BT_WIN_N=${BT_WIN_N#0}; done
       if [ "$BT_WIN_N" -ge 5 ] && [ "$BT_WIN_N" -le 15 ]; then BT_WIN=$BT_WIN_N; else BT_WIN_BAD=$BT_WIN; fi ;;
esac
[ -z "$BT_WIN_BAD" ] || BT_WIN=5
BT_MON_S=$((BT_WIN + 8))     # the monitor's own dead-man timer: it covers the readiness wait, the pid lookup and the scan
# The alert window: whole seconds from 60 to 86400, anything else is 600, said once at start (the main section). A function, so that the self-test
# can put many values through it without starting a collector for each. $1 = the setting; sets ALERT_WIN, and ALERT_WIN_BAD to the rejected text (empty = fine).
alert_window() {
    ALERT_WIN_BAD=""; ALERT_WIN=600
    case $1 in
        '') ;;
        *[!0-9]*) ALERT_WIN_BAD=$1 ;;
        *) AW_N=$1
           while [ "${#AW_N}" -gt 1 ] && [ "${AW_N#0}" != "$AW_N" ]; do AW_N=${AW_N#0}; done   # a leading zero is no octal
           if [ "${#AW_N}" -le 5 ] && [ "$AW_N" -ge 60 ] && [ "$AW_N" -le 86400 ]; then ALERT_WIN=$AW_N; else ALERT_WIN_BAD=$1; fi ;;
    esac
}
alert_window "${STARCHORUS_ALERT_WINDOW:-600}"
# The cycle length: whole seconds from 1 to 3600, anything else is 5, said once at start (the main section). Digits only, leading zeros dropped (never octal);
# 0 would run the loop back to back and a word that `sleep` rejects would fail it at once, a log line each time. Sets INTERVAL, and INTERVAL_BAD to the rejected
# text (empty = fine). A function for the same reason as alert_window.
interval_value() {
    INTERVAL_BAD=""; INTERVAL=5
    case $1 in
        '') ;;
        *[!0-9]*) INTERVAL_BAD=$1 ;;
        *) IV_N=$1
           while [ "${#IV_N}" -gt 1 ] && [ "${IV_N#0}" != "$IV_N" ]; do IV_N=${IV_N#0}; done
           if [ "${#IV_N}" -le 4 ] && [ "$IV_N" -ge 1 ] && [ "$IV_N" -le 3600 ]; then INTERVAL=$IV_N; else INTERVAL_BAD=$1; fi ;;
    esac
}
interval_value "${STARCHORUS_INTERVAL:-5}"
# The recon window: whole seconds, 0 = off. Digits only, leading zeros dropped (never octal: 08 would stop the shell in `$((now - MAX_AGE))`, 0300 would be 192
# and the document would carry invalid JSON); anything else, or more than nine digits, is 0 as before. Sets MAX_AGE.
max_age_value() {
    MAX_AGE=0
    case $1 in
        ''|*[!0-9]*) ;;
        *) MA_N=$1
           while [ "${#MA_N}" -gt 1 ] && [ "${MA_N#0}" != "$MA_N" ]; do MA_N=${MA_N#0}; done
           if [ "${#MA_N}" -le 9 ]; then MAX_AGE=$MA_N; fi ;;
    esac
}
max_age_value "${STARCHORUS_MAX_AGE:-0}"

# --------------------------------------------------------------------------- small helpers
log() { printf '[starchorus] %s\n' "$*" >&2; }   # printf, not echo: see find_oui_file
have() { command -v "$1" >/dev/null 2>&1; }

# Remove control bytes that would produce invalid JSON, keeping TAB(011) and LF(012).
# Strips NUL..BS, VT..US (incl CR) and DEL. `"` `\` `\t` are escaped later in awk.
clean_ctrl() { tr -d '\000-\010\013-\037\177'; }
RECON_TAB=$(printf '\t')   # recon.db column separator: the one control byte clean_ctrl keeps besides LF
NL=$(printf '\nx'); NL=${NL%x}   # a newline (a command substitution drops a trailing one, hence the x)

# Pid identity (holder_alive and pid_ours below). A lock directory or a pidfile survives kill -9 / power loss and, on a
# persistent OUTDIR / PIDDIR (/root/loot/starchorus on the device), even a reboot: the pid it names may then belong to a
# long-lived FOREIGN process (init, crond, the AP-service daemon) or, after a pid wrap, to anything. A pid alone proves
# nothing, so the command line must name what was started: /proc/<pid>/cmdline on Linux (empty for a zombie or a kernel
# thread: no match), else `ps -p PID -o args=` (BSD/macOS; busybox has no -p and falls through to `ps w`). The two
# callers differ only when NO command line can be read at all: holder_alive assumes live (never break a live lock
# blindly), pid_ours says not ours (a stop must never signal a stranger).
#
# Is a PID alive?  kill -0 is POSIX and works under busybox, but it also FAILS (EPERM) for a live
# process of another user (a mixed-user dev box; the device runs everything as root), so a failed
# kill is double-checked against /proc (Linux) and `ps -p` (BSD/macOS; busybox rejects -p -> 1).
# A zombie counts as alive here (kill -0 succeeds until it is reaped); holder_alive() below is
# the stricter test used for the cache lock.
pid_alive() {
    [ -n "$1" ] || return 1
    case "$1" in *[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null && return 0
    [ -d "/proc/$1" ] && return 0
    ps -p "$1" >/dev/null 2>&1
}

SELF_BASE=$(basename "$0" 2>/dev/null); [ -n "$SELF_BASE" ] || SELF_BASE=starchorus-collect.sh

# Is $1 the pid of a LIVE process that runs THIS script (a daemon loop or a `--once`)? Used for the cache lock: judged by
# pid alone, a foreign holder would be "live" forever and every cycle would pay the whole lock budget.
holder_alive() {
    pid_alive "$1" || return 1
    if [ -d "/proc/$1" ]; then
        hc=$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    else
        hc=$(ps -p "$1" -o args= 2>/dev/null)
        [ -n "$hc" ] || hc=$(ps w 2>/dev/null | awk -v p="$1" '$1==p')
        [ -n "$hc" ] || return 0
    fi
    case "$hc" in *"$SELF_BASE"*) return 0 ;; esac
    return 1
}

# Working directory of a live pid, read from /proc/PID/cwd (readlink; BusyBox has readlink). Falls
# back to "unknown directory" where /proc is absent (e.g. a macOS development machine).
loop_cwd() {
    _lc=$(readlink "/proc/$1/cwd" 2>/dev/null)
    if [ -n "$_lc" ]; then printf '%s\n' "$_lc"; else printf 'unknown directory\n'; fi
}

# 0 iff pid $1 descends from this shell ($$), following PPid in /proc/PID/status a few levels up. A
# forked subshell (a pipeline member, a command substitution) keeps the script's command line on
# BusyBox, so it looks like a collector loop in `ps w`; it is part of this run, never another loop.
# Without /proc (a macOS development machine) nothing counts as a descendant.
is_own_child() {
    _ic=$1; _id=0
    while [ "$_id" -lt 4 ]; do
        _ic=$(awk '/^PPid:/ { print $2; exit }' "/proc/$_ic/status" 2>/dev/null)
        [ -n "$_ic" ] && [ "$_ic" != 0 ] || return 1
        [ "$_ic" = "$$" ] && return 0
        _id=$((_id + 1))
    done
    return 1
}

# Is $1 the pid of a LIVE process whose command line contains $2? --stop and --status believe a pidfile only while its
# pid still runs what was started there: the loop runs this script, the capture runs airodump.
pid_ours() {
    pid_alive "$1" || return 1
    if [ -d "/proc/$1" ]; then
        oc=$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    else
        oc=$(ps -p "$1" -o args= 2>/dev/null)
        [ -n "$oc" ] || oc=$(ps w 2>/dev/null | awk -v p="$1" '$1==p')
    fi
    case "$oc" in *"$2"*) return 0 ;; esac
    return 1
}

# Kill every running collector DAEMON LOOP, with or without a pidfile (the backstop for the pidfile
# logic): command lines naming this script but NO "--" flag, so --stop/--once/--status/--selftest
# runs, including THIS one, never match; our own PID is skipped.
#
# One collector runs per device: a start or a stop stops every collector loop, not only this OUTDIR's,
# so the two never share the monitor interface / radio. That is deliberate but must be honest, so each
# loop this kills that is NOT the one named by this OUTDIR's pidfile is logged with its pid and working
# directory. $1 is the context ("stop" from --stop, "replace" at daemon start-up); $2, when given, is
# the pid of this OUTDIR's own loop (already reported by stop_pidfile), which is killed but not logged.
kill_loops() {
    _kl_ctx=${1:-stop}
    _kl_own=${2:-}
    # shellcheck disable=SC2009  # busybox pgrep/pkill -f are unreliable here; ps+grep is the portable way
    ps w 2>/dev/null | grep "$SELF_BASE" | grep -v grep | grep -v -- '--' | awk '{print $1}' | \
    while read -r p; do
        [ "$p" = "$$" ] && continue
        is_own_child "$p" && continue   # this run's own subshells, e.g. the one running this loop
        if [ "$p" != "$_kl_own" ]; then
            _kl_dir=$(loop_cwd "$p")
            if [ "$_kl_ctx" = replace ]; then
                log "replaced collector loop pid $p in $_kl_dir: one collector per device"
            else
                log "also stopped collector loop pid $p in $_kl_dir (one collector per device)"
            fi
        fi
        kill "$p" 2>/dev/null
    done
}

# The pids of the `sleep` children of pid $1, one per line: field 4 of /proc/PID/stat is the parent, the name field the command
# (bt_statf); `ps` where there is no /proc (a development machine). The payload's pl_kids finds the same processes.
loop_naps() {
    if [ -r /proc/self/stat ]; then
        for ln_f in /proc/[0-9]*/stat; do
            bt_statf "$ln_f" || continue
            [ "$BT_ST_PPID" = "$1" ] && [ "$BT_ST_COMM" = sleep ] || continue
            ln_p=${ln_f%/stat}; printf '%s\n' "${ln_p##*/}"
        done
    else
        ps -A -o pid= -o ppid= -o comm= 2>/dev/null | awk -v p="$1" '$2 == p && ($3 == "sleep" || $3 ~ /\/sleep$/) { print $1 }'
    fi
}

# Daemon start-up: kill_loops replace, then wait, at most $1 seconds, until the loops it stopped have gone. Their cleanup stops their own
# airodump and removes the monitor interface they made: this start must take neither over before that (it would capture on an interface
# that is about to go). A loop sleeps in the foreground, and BusyBox ash runs its TERM trap only when that sleep returns, so each poll ends
# the sleep children of every loop still there (loop_naps), as the payload's stop does (pl_kill_sleeps): a replaced loop then goes at once,
# whatever interval it sleeps, and only one in the middle of a step (a tcpdump burst) takes longer. A signal to our own processes only.
# The pids are read before the TERM, as kill_loops reads them; one that no longer runs this script is gone (pid_ours). 0 = none left,
# 1 = one still runs after the wait (said once).
replace_loops() {
    # shellcheck disable=SC2009  # see kill_loops()
    rl_old=$(ps w 2>/dev/null | grep "$SELF_BASE" | grep -v grep | grep -v -- '--' | awk '{print $1}')
    kill_loops replace
    rl_n=0
    while :; do
        rl_left=""
        for rl_p in $rl_old; do [ "$rl_p" != "$$" ] && pid_ours "$rl_p" "$SELF_BASE" && rl_left="$rl_left $rl_p"; done
        [ -n "$rl_left" ] || return 0
        if [ "$rl_n" -ge "$1" ]; then
            log "replaced collector loop(s)$rl_left still running after ${1}s; a monitor interface such a loop made goes when it ends"
            return 1
        fi
        for rl_p in $rl_left; do for rl_s in $(loop_naps "$rl_p"); do kill "$rl_s" 2>/dev/null; done; done
        sleep 1; rl_n=$((rl_n + 1))
    done
}

# --------------------------------------------------------------------------- --stop / --status
stop_pidfile() {   # $1 = pidfile, $2 = label, $3 = what its command line holds: kill the pid it names only while it is ours (sets stopped=1), drop the file
    [ -f "$1" ] || return 0
    sp=$(cat "$1" 2>/dev/null)
    if pid_ours "$sp" "$3"; then
        kill "$sp" 2>/dev/null && log "stopped $2 pid $sp" && stopped=1
    elif pid_alive "$sp"; then
        log "left pid $sp alone: it is no $2 any more (stale $(basename "$1"))"
    fi
    rm -f "$1"
}
stop_instances() {
    stopped=0
    own_loop=$(cat "$LOOP_PIDFILE" 2>/dev/null)   # read before stop_pidfile removes the file
    stop_pidfile "$LOOP_PIDFILE" "collector loop" "$SELF_BASE"
    # backstop: any collector loop without a live pidfile (e.g. its pidfile was overwritten by a re-run)
    # shellcheck disable=SC2009  # see kill_loops(): ps+grep is the portable count here
    before=$(ps w 2>/dev/null | grep "$SELF_BASE" | grep -v grep | grep -v -- '--' | grep -vc "^ *$$ ")
    kill_loops stop "$own_loop"
    [ "${before:-0}" -gt 0 ] 2>/dev/null && stopped=1
    stop_pidfile "$AIRODUMP_PIDFILE" airodump airodump
    [ "$stopped" = "1" ] || log "nothing running for this OUTDIR ($OUTDIR)"
}

status_pidfile() {   # $1 = label, $2 = pidfile, $3 = what the command line of a running one holds
    if [ -f "$2" ] && pid_ours "$(cat "$2" 2>/dev/null)" "$3"; then
        log "$1 RUNNING (pid $(cat "$2"))"
    else
        log "$1 not running"
    fi
}
status_instances() {
    status_pidfile loop "$LOOP_PIDFILE" "$SELF_BASE"
    status_pidfile airodump "$AIRODUMP_PIDFILE" airodump
    [ -f "$OUTFILE" ] && log "last JSON: $OUTFILE ($(wc -c < "$OUTFILE" 2>/dev/null) bytes)"
}

# --------------------------------------------------------------------------- interface setup
# The mgmt interfaces, one per line, so that we never touch the 2.4GHz management radio (phy0).
# On the device the mgmt AP interface is wlan0mgmt (often part of br-lan) and carries one of the
# two management addresses the awk below knows. Every interface with one of the fixed names is
# listed, and so is whichever iface carries a known mgmt IP (on the device br-lan, which no phy holds).
mgmt_iface() {
    if have iw; then
        iw dev 2>/dev/null | awk '
            /^[[:space:]]*Interface/ && $2 ~ /^wlan0(mgmt|cli|open|wpa|ent)?$/ { print $2 }'
    fi
    if have ip; then
        ip -o addr show 2>/dev/null | awk '/172\.16\.52\.1|172\.16\.42\.1/{print $2; exit}'
    fi
}

# List interfaces that are ALREADY in monitor mode (the device's recon engine or a prior
# run may have created one). We prefer reusing these read-only rather than fighting them.
# On the device the tri-band recon radio (radio1) surfaces as wlan1mon; the 2.4GHz radio can
# surface wlan0mon; a staged USB adapter surfaces as wlan2mon. setup_monitor_iface() prefers
# wlan1mon among these.
existing_monitors() {
    if have iw; then
        iw dev 2>/dev/null | awk '
            /^[[:space:]]*Interface/ { ifc=$2 }
            /type monitor/           { print ifc }'
    fi
}

# Pick a base (managed) interface that is NOT on the mgmt radio, to host a monitor VIF (and, opt-in, the ACTIVE scan).
# The radio is judged by its phy, not by the name: a phy that holds any mgmt interface (mgmt_iface) or any interface of
# type AP is skipped whole, so wlan0cli, which shares phy0 with wlan0mgmt on the device, is never taken, nor a client
# beside a management AP that a firmware names otherwise. The names reach awk through the environment (a value of two
# lines given with -v is fatal to some awks). Prefer the recon radio (wlan1*).
candidate_base_iface() {
    mg=$(mgmt_iface)
    if have iw; then
        iw dev 2>/dev/null | SC_MG="$mg" awk '
            BEGIN { n = split(ENVIRON["SC_MG"], m, "\n"); for (i = 1; i <= n; i++) if (m[i] != "") mgn[m[i]] = 1 }
            /^phy#/                  { phy=$1; ifc="" }
            /^[[:space:]]*Interface/ { ifc=$2; k++; nm[k]=ifc; ph[k]=phy; if (ifc in mgn) bad[phy]=1 }
            /type AP/                { bad[phy]=1 }
            /type managed/ && ifc != "" { man[k]=1 }
            END {
                for (i = 1; i <= k; i++) {
                    if (!(i in man) || (ph[i] in bad)) continue
                    if (nm[i] ~ /^wlan1/) { print nm[i]; exit }
                    if (alt == "") alt=nm[i] }
                if (alt != "") print alt }'
    fi
}

# Create a monitor VIF on the recon adapter WITHOUT disturbing the mgmt link.
# We deliberately avoid `airmon-ng start` as a first resort because its check-kill can
# tear down processes on the mgmt radio; we add a VIF with `iw` instead.
create_monitor() {
    base=$1
    [ -z "$base" ] && return 1
    newif="${base}mon"
    if have iw; then
        # a name that is taken already is not ours to make, to use or to remove (cleanup deletes what this run made)
        iw dev "$newif" info >/dev/null 2>&1 && return 1
        phy=$(iw dev "$base" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}')
        if [ -n "$phy" ]; then
            if iw phy "$phy" interface add "$newif" type monitor >/dev/null 2>&1; then
                have ip && ip link set "$newif" up 2>/dev/null
                have ifconfig && ifconfig "$newif" up 2>/dev/null
                printf '%s\n' "$newif"; return 0
            fi
        fi
    fi
    # Last resort: airmon-ng (may rename to <base>mon). Only if iw path failed.
    if have airmon-ng; then
        out=$(airmon-ng start "$base" 2>/dev/null)
        m=$(printf '%s\n' "$out" | awk 'tolower($0) ~ /monitor mode.*enabled|vif enabled/ {for(i=1;i<=NF;i++) if($i ~ /mon$/){print $i}}' | tail -1)
        [ -z "$m" ] && m="${base}mon"
        # the name only when that interface is now there in monitor mode: a start that failed made nothing, and
        # cleanup must never delete an interface this run did not make
        iw dev "$m" info 2>/dev/null | grep -q 'type monitor' || return 1
        printf '%s\n' "$m"; return 0
    fi
    return 1
}

# Decide which monitor interface to capture on. Sets MONIF and CREATED_MON.
setup_monitor_iface() {
    if [ "$IFACE" != "auto" ]; then
        MONIF=$IFACE; CREATED_MON=0
        log "using user-specified interface: $MONIF"
        return 0
    fi
    mons=$(existing_monitors)
    if [ -n "$mons" ]; then
        # Prefer the device's tri-band recon monitor (wlan1mon) if present, so we read the same
        # radio the recon engine uses; otherwise take the first non-2.4 mon, else first.
        existing=$(printf '%s\n' "$mons" | grep -x 'wlan1mon' | head -1)
        [ -z "$existing" ] && existing=$(printf '%s\n' "$mons" | grep -v -x 'wlan0mon' | head -1)
        [ -z "$existing" ] && existing=$(printf '%s\n' "$mons" | head -1)
        MONIF=$existing; CREATED_MON=0
        log "reusing existing monitor interface: $MONIF (not created by us)"
        return 0
    fi
    if [ "$CREATE_MON" = "1" ]; then
        base=$(candidate_base_iface)
        if [ -n "$base" ]; then
            m=$(create_monitor "$base")
            if [ -n "$m" ]; then
                MONIF=$m; CREATED_MON=1
                log "created monitor interface $MONIF on base $base"
                return 0
            fi
        fi
        log "could not create a monitor interface (no non-mgmt adapter found?)"
    fi
    return 1
}

# --------------------------------------------------------------------------- recon DB locate
find_recon_db() {
    if [ "$RECON_DB" != "auto" ]; then
        [ -r "$RECON_DB" ] && { printf '%s\n' "$RECON_DB"; return 0; }
        return 1
    fi
    # Common locations first (cheap), then a bounded search. On the device the persistent
    # recon store is /root/recon/recon.db (== /mmc/root/recon/recon.db, same eMMC; confirmed
    # in the AP-service binary as "<reconpath>/recon.db"). Other firmware layouts use
    # /tmp/recon.db or /root/recon.db; we probe both families.
    for c in /root/recon/recon.db /mmc/root/recon/recon.db \
             /tmp/recon.db /root/recon.db /mmc/root/recon.db \
             /etc/pineapple/recon.db; do
        [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    # Bounded find: only the paths the device is likely to use, quiet, first hit wins.
    # (No /sd -- the device has internal eMMC only.)
    for root in /root /mmc /tmp /etc; do
        [ -d "$root" ] || continue
        f=$(find "$root" -maxdepth 4 -name 'recon.db' 2>/dev/null | head -1)
        [ -n "$f" ] && [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# --------------------------------------------------------------------------- source decision
# Resolve SOURCE=auto to a concrete method, honouring the passivity contract and the
# single-recon-radio contention rule:
#   * a monitor iface we did NOT create may belong to the channel-hopping recon engine; a 2nd
#     capture on that PHY would fight it, so the engine's recon DB is preferred (zero contention);
#   * a monitor VIF of our OWN gets our own passive capture (self-contained).
# On the device this resolves to `recondb`: wlan1mon belongs to the Recon engine (CREATED_MON=0)
# and sqlite3 is pre-installed; airodump-ng is not, so the capture fallback there is tcpdump.
# Force a source with STARCHORUS_SOURCE=recondb|capture if auto guesses wrong.
# Sets the global RESOLVED (and, via setup_monitor_iface, MONIF/CREATED_MON): call it directly,
# never as `X=$(resolve_source)` -- a command substitution's subshell would discard those globals.
resolve_source() {
    # A forced source is honoured; capture still needs an interface.
    if [ "$SOURCE" != "auto" ]; then
        RESOLVED=$SOURCE
        [ "$RESOLVED" = "capture" ] && setup_monitor_iface
        if [ "$RESOLVED" = "pineap" ]; then
            # asking for this source IS the opt-in for its two read-only commands (STARCHORUS_APCLI_RO stays 0 otherwise)
            APCLI_RO=1
            apcli_ro present || { log "STARCHORUS_SOURCE=pineap, but the AP service command line is not on this device"; RESOLVED=none; }
        fi
        return 0
    fi
    setup_monitor_iface
    dbpath=$(find_recon_db)
    if [ -n "$MONIF" ] && [ "$CREATED_MON" = "1" ] && { have airodump-ng || have tcpdump; }; then
        RESOLVED=capture; return 0
    fi
    if [ -n "$dbpath" ] && have sqlite3; then
        RESOLVED=recondb; return 0
    fi
    if [ -n "$MONIF" ] && { have airodump-ng || have tcpdump; }; then
        log "WARNING: capturing on pre-existing monitor $MONIF; if the device's recon engine"
        log "         owns this radio, channel-hop contention is possible (still RX-only)."
        RESOLVED=capture; return 0
    fi
    if [ "$ALLOW_ACTIVE" = "1" ] && have iw; then
        RESOLVED=iwscan; return 0
    fi
    RESOLVED=none
}

# --------------------------------------------------------------------------- capture: start
# airodump-ng is inherently passive: it RECEIVES beacons/probes/data headers and channel-hops
# to tune the receiver. It does NOT inject. We pass NO active/injection flags.
start_airodump() {
    [ -n "$MONIF" ] || return 1
    mkdir -p "$CAPDIR"
    rm -f "$CAPDIR"/starchorus-*.csv 2>/dev/null
    # only the interface this run made is brought up; one it found (the recon service's, or STARCHORUS_IFACE) is used as it is
    if [ "$CREATED_MON" = 1 ]; then
        have ip && ip link set "$MONIF" up 2>/dev/null
    fi
    # --write-interval rewrites the CSV on a cadence; --output-format csv keeps it parseable.
    # --background 1 avoids curses; stdout/err are discarded.
    airodump-ng --write-interval 2 --output-format csv --background 1 \
        -w "$CAPPREFIX" "$MONIF" >/dev/null 2>&1 &
    AD_PID=$!; echo "$AD_PID" > "$AIRODUMP_PIDFILE"
    CAP_METHOD="airodump"; STARTED_AIRODUMP=1
    log "started passive airodump-ng (pid $(cat "$AIRODUMP_PIDFILE")) on $MONIF"
    return 0
}

# --------------------------------------------------------------------------- teardown
# cleanup() only tidies up: a trap handler that merely returns does NOT terminate the shell (after a
# caught SIGTERM the interrupted `sleep` returns and the loop would resume as an orphan whose pidfile
# is gone), so the INT/TERM/HUP traps run cleanup AND exit; the EXIT trap runs cleanup alone. It clears
# the four traps first so it never re-enters itself. A Bluetooth window that is still open ends with bt_end abort (first thing, within about 2.5 s).
# INSTANCE-SCOPED: the EXIT trap fires for every `--once` too, and a crond `--once` regularly overlaps
# the daemon's cycle (DB copy + queries take a second or more on the device's MIPS CPU). So cleanup touches
# ONLY what THIS process created: its own pid-stamped temp files, the loop pidfile only if it names
# this pid, the airodump only if this instance started it -- never the daemon's half-written cycle
# (-> source=none for an interval) or its pidfile (-> --status "not running").
cleanup() {
    bt_last=$!
    # a signal between the fork of a Bluetooth wrapper and the assignment of its pid finds the wrapper in $! (as ov_cleanup does in the Overview);
    # a $! of an earlier job is harmless, since bt_is rejects a pid that is not that tool
    if [ "$BT_ARM" = m ] && [ -z "$BT_MPID" ]; then BT_MPID=$bt_last; fi
    if [ "$BT_ARM" = s ] && [ -z "$BT_SPID" ]; then BT_SPID=$bt_last; fi
    trap - INT TERM HUP EXIT
    [ -z "$BT_MPID$BT_SPID" ] || bt_end abort
    # the airodump THIS instance started, by its own pid; the shared pidfile only while it still names that one (a later start may have written its own)
    if [ "$STARTED_AIRODUMP" = "1" ] && [ -n "$AD_PID" ]; then
        pid_ours "$AD_PID" airodump && kill "$AD_PID" 2>/dev/null
        [ "$(cat "$AIRODUMP_PIDFILE" 2>/dev/null)" = "$AD_PID" ] && rm -f "$AIRODUMP_PIDFILE"
    fi
    [ "$(cat "$LOOP_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$LOOP_PIDFILE"
    # This instance's pid-stamped temp files only: the output files of a cycle cut short by the signal (each post-pass's own:
    # .c center, .h homing, .v vendor, .l layers), an OUI index build, the pineap side files and security cache in the making, the RAM copy of recon.db.
    rm -f "$OUTFILE.tmp.$$" "$OUTFILE.tmp.$$.c" "$OUTFILE.tmp.$$.h" "$OUTFILE.tmp.$$.v" "$OUTFILE.tmp.$$.l" "$OUTFILE.gen$$" "${OUI_CACHE:-$CAPDIR/oui-cache.txt}.gat.$$" 2>/dev/null
    # the Bluetooth window's files of this process (the pid file only when no tool is left, bt_end abort decides), the RECON CHANNELS call and its file
    rm -f "$TMPDIR_RAM/starchorus-bt-$$.txt.out" "$TMPDIR_RAM/starchorus-bt-$$.held" "$TMPDIR_RAM/starchorus-bt-$$.new" "$TMPDIR_RAM/starchorus-bt-$$.stat" \
          "$TMPDIR_RAM/starchorus-bt-$$.alog" "$TMPDIR_RAM/starchorus-traffic-$$.json" 2>/dev/null
    if [ -n "$TR_PID" ]; then is_own_child "$TR_PID" && kill "$TR_PID" 2>/dev/null; TR_PID=""; fi
    rm -rf "$CAPDIR"/oui-index.new.$$.* 2>/dev/null
    rm -f "$TMPDIR_RAM/starchorus-pineap-$$.unk" "$TMPDIR_RAM/starchorus-pineap-$$.neg" "$TMPDIR_RAM/starchorus-pineap-$$.all" "${PSEC:-$TMPDIR_RAM/starchorus-sec.txt}.new.$$" 2>/dev/null
    rm -f "$TMPDIR_RAM/starchorus-recon-$$.db" "$TMPDIR_RAM/starchorus-recon-$$.db-wal" "$TMPDIR_RAM/starchorus-recon-$$.db-shm" "$TMPDIR_RAM/starchorus-recon-$$.db-err" 2>/dev/null
    [ -n "$VENDOR_NEWF" ] && rm -f "$VENDOR_NEWF" 2>/dev/null
    [ "${CACHE_LOCKED:-0}" -gt 0 ] 2>/dev/null && CACHE_LOCKED=1  # release fully, whatever the depth
    cache_unlock
    if [ "$CREATED_MON" = "1" ] && [ -n "$MONIF" ]; then
        # only the VIF we created; never the mgmt radio or a VIF we reused
        if have iw; then iw dev "$MONIF" del 2>/dev/null; fi
        log "removed monitor interface $MONIF"
    fi
}

# ============================================================================ BLUETOOTH: ONE PASSIVE LE SCAN WINDOW PER CYCLE (opt-in)
# STARCHORUS_BLUETOOTH=1. STRICTLY PASSIVE: a passive LE scan sends no scan request, it only listens to the advertisements that devices broadcast
# anyway (docs/device-notes.md V-13, SECURITY.md). bt_begin below is the ONLY place a Bluetooth tool is started, and it starts exactly two
# commands, each under `timeout -s INT` as a dead-man timer: the monitor first, then the scan once the monitor holds its socket (so the monitor
# decodes the scan parameters that the scan sets, which is the witness: a window counts only when they say Type: Passive, bt_parse). The window
# runs in the background beside the source build (run_cycle); bt_end ends it, reads it and judges it; add_layers puts the records into the document.
#
# What a window can and cannot say. The controller's address types: most advertisers use random addresses that rotate every quarter of an hour,
# so the records are ADDRESSES, never devices. A record's rssi is the strongest report of the one window it was last heard in, a few seconds of
# listening. The window's text is read by a strict grammar (bt_parse) because an advertiser writes some of it: a name may contain a line feed, and
# the text after it becomes a line of its own. A name is at most 29 bytes (a legacy advertisement holds 31, less its two header bytes), but the Apple
# decoder of BlueZ 5.72 prints the text after a length byte without bounding it to the advertisement, so a line the air writes can run on to about 36
# bytes. The parser therefore acts only on lines that are longer than that (headers, Event type) or counted only in a position that a forged line
# cannot take, and a forged Address type or Address line can only drop the sender's own report.
#
# Processes. `$!` after `timeout ... &` is the `timeout` wrapper; the tool is its child, or the wrapper itself when that `timeout` execs (bt_kid
# finds the tool by command name). Signals go to the TOOL's pid, by bt_sig, after bt_is has checked that the pid still runs that tool: the scan
# gets INT (repeated, by the clock) and at most one TERM, never KILL (it ends the scan only from its INT handler, so a TERM or KILL can leave the
# controller scanning, passively; that is logged and the owner's recovery is in device-notes V-13); the monitor holds no controller state and may be
# escalated; a wrapper is signalled only after its tool is gone. Without /proc (the development machine) no tool pid is known and only INT goes,
# to the wrapper. All waits are measured by the clock (bt_tick), never by counting naps: the payload ends every `sleep` of the loop each 0.5 s
# while it stops the collector, and a killed nap only makes the poll come round again.

# BT_NOW = hundredths of a second since boot, read by the shell itself from /proc/uptime (no process); without it the clock of `date` in whole
# seconds, and where that gives nothing either, 0.2 s more than the last tick (so that no wait can last for ever; the polls are 0.2 s apart, bar the 0.5-s
# steady state of bt_end, where this clock runs slow, a case that the Pager, with its /proc/uptime, does not meet). A whole-second clock can jump by a
# full second between two readings a few milliseconds apart, so the waits that must not end early add BT_SLK to their allowance: 0 with a real clock,
# 100 with the whole-second one (a wait then lasts its time, and up to one second more). `command date`: a test may replace `date`. BT_FAKE (a test)
# is a clock that bt_nap moves on. A wait that runs on every poll takes the time as `bt_tick; VAR=$BT_NOW`: bt_now is the same through a `$( )`, a process of its
# own on ash, and is left to bt_end's one reading at its start.
bt_tick() {
    if [ -n "$BT_FAKE" ]; then BT_NOW=$BT_FAKE; BT_SLK=0; return 0; fi
    BT_SLK=0; bt_u=""
    { read -r bt_u _ < "$BT_PROC/uptime"; } 2>/dev/null
    case $bt_u in
        ''|*[!0-9.]*)
            BT_SLK=100
            bt_d=$(command date +%s 2>/dev/null)
            case $bt_d in ''|*[!0-9]*|0) BT_NOW=$((BT_NOW + 20)) ;; *) BT_NOW=$((bt_d * 100)) ;; esac ;;
        *.*) bt_fr="${bt_u#*.}00"; bt_fr=${bt_fr%"${bt_fr#??}"}; BT_NOW=$((${bt_u%%.*} * 100 + ${bt_fr#0})) ;;
        *) BT_NOW=$((bt_u * 100)) ;;
    esac
}
bt_now() { bt_tick; printf '%s\n' "$BT_NOW"; }
# One short wait between two polls, $1 hundredths of a second (20 without an argument): where `sleep` takes fractions 0.2 s for 20 and 0.5 s for 50,
# else 1 s (the pattern of pl_nap in the payload). Each `sleep` is a process on ash, so only the steady state of bt_end asks for 50, while nothing can
# happen in the next second; every other wait keeps the 0.2 s that its signal rules and one-second holds are measured in. With BT_FAKE set the nap
# moves that clock on by $1 instead. A nap that was killed (status 128 and up) only returns: the caller polls again, by the clock.
bt_nap() {
    if [ -n "$BT_FAKE" ]; then
        BT_FAKE=$((BT_FAKE + ${1:-20})); [ -z "$BT_FAKE_NAP" ] || sleep "$BT_FAKE_NAP" 2>/dev/null
        return 0
    fi
    if [ "$BT_FRAC" = 1 ]; then
        bt_sv=0.2; [ "${1:-20}" != 50 ] || bt_sv=0.5
        sleep "$bt_sv" 2>/dev/null; bt_r=$?
        if [ "$bt_r" = 0 ] || [ "$bt_r" -ge 128 ]; then return 0; fi
        BT_FRAC=0
    fi
    sleep 1
}
# $BT_PROC/PID/stat -> BT_ST_COMM (the name field, the text between the first "(" and the last ")"), BT_ST_STATE, BT_ST_PPID, BT_ST_START (field 22).
# 1 when there is no such file. All builtins: the file is read with `read`, the fields cut with parameter expansion.
bt_statf() {
    bt_sf=$1; BT_ST_COMM=""; BT_ST_STATE=""; BT_ST_PPID=""; BT_ST_START=""
    { read -r bt_sl < "$bt_sf"; } 2>/dev/null || return 1
    case $bt_sl in *') '*) ;; *) return 1 ;; esac
    BT_ST_COMM=${bt_sl#*\(}; BT_ST_COMM=${BT_ST_COMM%) *}
    bt_sr=${bt_sl##*) }
    set -f
    # shellcheck disable=SC2086  # the word splitting is the point
    set -- $bt_sr
    set +f
    BT_ST_STATE=$1; BT_ST_PPID=$2; BT_ST_START=${20}
    return 0
}
bt_stat() { bt_statf "$BT_PROC/$1/stat"; }
# 0 while PID is alive, is no zombie and runs a program whose command name is exactly WORD. This tells a `timeout` wrapper from its tool, which a
# command line cannot (the wrapper's names the tool too). Sets BT_ST_* for the caller (bt_busy and bt_sweep compare the start field).
bt_is() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    bt_stat "$1" || return 1
    [ "$BT_ST_STATE" != Z ] && [ "$BT_ST_STATE" != X ] && [ "$BT_ST_COMM" = "$2" ]
}
# 0 while PID runs and is no zombie, whatever it is (a wrapper; a child that is not waited for yet is a zombie, and kill -0 says yes to those).
# Without /proc the state is asked of `ps` (BusyBox has none of `-p`: then the answer is "alive").
bt_up() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    if bt_stat "$1"; then [ "$BT_ST_STATE" != Z ] && [ "$BT_ST_STATE" != X ]; return; fi
    bt_z=$(ps -o state= -p "$1" 2>/dev/null)
    case $bt_z in Z*) return 1 ;; esac
    return 0
}
# WRAPPER WORD -> prints the pid of the tool: WRAPPER itself when it already runs WORD (a `timeout` that execs), else the child of WRAPPER of that
# name (field 4 of every stat file is the parent), looked for by the clock for up to BT_T_KID. Prints nothing and returns 1 without /proc.
bt_kid() {
    [ -d "$BT_PROC" ] || return 1
    bk_w=$1; bk_n=$2; bt_tick; bk_t=$BT_NOW
    while :; do
        if bt_is "$bk_w" "$bk_n"; then printf '%s\n' "$bk_w"; return 0; fi
        for bk_f in "$BT_PROC"/[0-9]*/stat; do
            bt_statf "$bk_f" || continue
            [ "$BT_ST_PPID" = "$bk_w" ] && [ "$BT_ST_COMM" = "$bk_n" ] || continue
            [ "$BT_ST_STATE" != Z ] && [ "$BT_ST_STATE" != X ] || continue
            bk_p=${bk_f%/stat}; bk_p=${bk_p##*/}
            kill -0 "$bk_p" 2>/dev/null || continue
            printf '%s\n' "$bk_p"; return 0
        done
        bt_tick; [ $((BT_NOW - bk_t)) -lt $((BT_T_KID + BT_SLK)) ] || return 1
        bt_nap
    done
}
# PID (the monitor's own; may be empty): 0 once it holds a socket (an entry of /proc/PID/fd that is a socket, `test -S`), or has written a line other
# than its banner to the window file (the index and note lines come with the socket; the banner "Bluetooth monitor ver 5.72" comes before it: on
# the device 0.1 s after the start against 0.5 s for the socket, five runs on 18 October 2026, so the banner alone would start the scan with the
# monitor not yet attached and the scan's parameters unrecorded); polled by the clock for up to BT_T_READY. No socket, no scan: the window is
# void before anything was asked of the controller.
bt_ready() {
    bt_tick; br_t=$BT_NOW
    while :; do
        if [ -s "$BT_F" ] && grep -q -v '^Bluetooth monitor ver' "$BT_F" 2>/dev/null; then return 0; fi
        if [ -n "$1" ]; then
            # `test -S` is the shell's own (a builtin): the kernel resolves a /proc descriptor link to the object it names, a socket here. It was a readlink
            # process per descriptor, three or four descriptors a poll, a poll every 0.2 s
            for br_f in "$BT_PROC/$1"/fd/*; do
                [ -S "$br_f" ] && return 0
            done
        fi
        bt_tick; [ $((BT_NOW - br_t)) -lt $((BT_T_READY + BT_SLK)) ] || return 1
        bt_nap
    done
}
# The one place a signal is sent to a scan process: SIG PID. The caller has checked the pid with bt_is.
bt_sig() {
    [ -z "$BT_SIGLOG" ] || printf '%s %s\n' "$1" "$2" >> "$BT_SIGLOG"
    if [ -n "$BT_SIGMSG" ] && [ "$1" != KILL ]; then printf '%s\n' "$1" >> "$BT_SIGMSG/$2"; return 0; fi
    kill -s "$1" "$2" 2>/dev/null
}
# The pid file of this window, $BT_PF (starchorus-bt-<pid>.pid): one line per tool, "M|S WRAPPER TOOL START" (START = field 22 of the tool's stat,
# which a reused pid does not share; "-" where unknown). Until both tools are found it holds one marker line "P PID" (bt_begin writes it first). It
# outlives a collector killed with -9, which is what bt_busy and bt_sweep read; both take the holder's pid from the name up to its first dot.
bt_note() {
    {
        if [ -n "$BT_MPID" ]; then
            bn_s=-; if [ -n "$BT_MKID" ] && bt_stat "$BT_MKID"; then bn_s=$BT_ST_START; fi
            printf 'M %s %s %s\n' "$BT_MPID" "${BT_MKID:--}" "$bn_s"
        fi
        if [ -n "$BT_SPID" ]; then
            bn_s=-; if [ -n "$BT_SKID" ] && bt_stat "$BT_SKID"; then bn_s=$BT_ST_START; fi
            printf 'S %s %s %s\n' "$BT_SPID" "${BT_SKID:--}" "$bn_s"
        fi
    } > "$BT_PF" 2>/dev/null
}
# KEY MESSAGE: logged once per episode, an episode being a run of cycles that raise the same key (BT_CUR = this cycle's keys, run_cycle moves
# them to BT_LOGGED at its end, so a key that is not raised in a cycle is forgotten and the next occurrence is logged again).
bt_issue() {
    case $BT_CUR in *" $1 "*) return 0 ;; esac
    BT_CUR="$BT_CUR$1 "
    case $BT_LOGGED in *" $1 "*) return 0 ;; esac
    log "$2"
}

# 0 when another collector's window is live: a pid file of a live holder that is starting its window (the marker line) or whose recorded tool still
# runs (same command name, same start).
bt_busy() {
    for bb_f in "$TMPDIR_RAM"/starchorus-bt-*.pid; do
        [ -e "$bb_f" ] || continue
        bb_h=${bb_f##*/starchorus-bt-}; bb_h=${bb_h%%.*}
        case $bb_h in ''|*[!0-9]*|"$$") continue ;; esac
        holder_alive "$bb_h" || continue
        while read -r bb_k _ bb_t bb_s; do
            case $bb_k in
                P) return 0 ;;
                M) bt_is "$bb_t" btmon && [ "$BT_ST_START" = "$bb_s" ] && return 0 ;;
                S) bt_is "$bb_t" hcitool && [ "$BT_ST_START" = "$bb_s" ] && return 0 ;;
            esac
        done < "$bb_f"
    done
    return 1
}

# bt_pick: choose this cycle's Bluetooth source into BT_SRC from STARCHORUS_BT_SOURCE and whether the firmware's blue5 database is
# there to read. READ-ONLY and cheap (one builtin -e test; no process scan, no find): it runs every cycle BLUETOOTH is on.
#   window = our own passive LE scan (bt_begin, the window path below);
#   blue5  = read blue5.db instead (strictly a file read, like recon.db; the blue5 tools are never run, and are denied by name);
#   none   = no Bluetooth this cycle.
# `auto` reads blue5.db when it is present (firmware 2.0, where the Pager's own scanner holds the controller) and otherwise uses our
# own window (firmware 1.x, or a 2.0 device with no blue5). `auto` never starts a window on a controller a foreign scanner may hold:
# that case is caught by bt_begin's own guard, which stands the window down. An unknown value is `none` (never a window).
bt_pick() {
    case $BT_SOURCE in
        window) BT_SRC=window ;;
        blue5)  BT_SRC=blue5 ;;
        auto)   if [ -e "$BLUE5_DB" ]; then BT_SRC=blue5; else BT_SRC=window; fi ;;
        *)      BT_SRC=none
                bt_issue btsource "Bluetooth: STARCHORUS_BT_SOURCE=$BT_SOURCE is not auto, blue5 or window; no Bluetooth this cycle" ;;
    esac
}

# bt_blue5_copy: copy blue5.db to RAM before reading it, read-only, the same copy-first rule as recon.db (blue5's journal_mode is
# `delete`, so a long read on the live file would hold a SHARED lock that stalls blue5's commits). Built on recon_copy_to and ram_room,
# but with NO flash fallback and NO live-file last resort (unlike recon_workcopy): if the RAM copy cannot be made there is no Bluetooth
# this cycle, the live file is never read. The copy holds addresses, so it is made under umask 077 like the other Bluetooth files.
# $1 = blue5.db. Sets BT5_DB (the copy to query, "" = none) and BT5_RAM (1 = bt_blue5_done removes it).
bt_blue5_copy() {
    BT5_DB=""; BT5_RAM=0
    [ -r "$1" ] || return 1
    file_size "$1"; bc_sz=${FSZ:-0}; case $bc_sz in ''|*[!0-9]*) bc_sz=0 ;; esac
    if [ "$bc_sz" -gt "$BT5_MAX" ] 2>/dev/null; then
        bt_issue blue5big "Bluetooth: the Bluetooth database is over the ${BT5_MAX}-byte cap; not read this cycle"; return 1
    fi
    bc_dst="$TMPDIR_RAM/starchorus-bt5-$$.db"
    if [ -d "$TMPDIR_RAM" ] && [ -w "$TMPDIR_RAM" ] && ram_room "$TMPDIR_RAM" "$bc_sz"; then
        bc_um=$(umask); umask 077
        recon_copy_to "$1" "$bc_dst"; bc_rc=$?
        umask "$bc_um"
        if [ "$bc_rc" = 0 ]; then BT5_DB=$bc_dst; BT5_RAM=1; return 0; fi
    fi
    rm -f "$bc_dst" "$bc_dst-wal" "$bc_dst-shm" 2>/dev/null; RR_OK=""
    return 1
}
# bt_blue5_done: free the RAM copy after reading (one rm), like recon_workdone.
bt_blue5_done() {
    [ "$BT5_RAM" = 1 ] && rm -f "$BT5_DB" "$BT5_DB-wal" "$BT5_DB-shm" 2>/dev/null
    BT5_DB=""; BT5_RAM=0
}

# bt_blue5_sql: $1 = the blue5.db copy, $2 = the cycle clock ts (digits). stdout = one B-line per Bluetooth address (the shape
# add_layers reads, with a 10th field, the real last_seen), then a sentinel line that proves the query ran to the end. All of the
# validation, the de-duplication (the newest row per address) and the TAB/LF/CR neutralisation of the name are done IN SQL, read-only,
# so a hostile advertiser's name can neither shift a column nor forge a record, and a stray value cannot reach the document:
#   * transports=1 keeps LE only; a 12-hex mac becomes lower case and colon-separated; addr_type is derived from the address's top two
#     bits (public, random-static/resolvable/non-resolvable) as the window path does, not a bare "random";
#   * rssi is rssi_avg (steadier than the last sample) and must be a real reading (-127..-1); reports is packets, floored at 1; company
#     is kept only as a real id (0 and 65535 mean "no id"); the name BLOB has TAB/LF/CR turned to spaces and is cut to 32;
#   * only addresses seen within BT_HOLD (120 s) of ts are kept, and never one stamped later than ts (a clock that moved back);
#   * one row per address, the newest, via MAX(last_seen) with its bare columns in a sub-query (the single-aggregate form SQLite defines).
bt_blue5_sql() {
    sqlite3 -readonly -noheader -bail -separator "$RECON_TAB" "$1" "
SELECT 'B',
  lower(substr(mac,1,2)||':'||substr(mac,3,2)||':'||substr(mac,5,2)||':'||substr(mac,7,2)||':'||substr(mac,9,2)||':'||substr(mac,11,2)),
  CASE WHEN le_random=0 THEN 'public'
       WHEN (instr('0123456789ABCDEF',substr(upper(mac),1,1))-1)/4=3 THEN 'random-static'
       WHEN (instr('0123456789ABCDEF',substr(upper(mac),1,1))-1)/4=1 THEN 'random-resolvable'
       WHEN (instr('0123456789ABCDEF',substr(upper(mac),1,1))-1)/4=0 THEN 'random-nonresolvable'
       ELSE 'random' END,
  rssi_avg,
  CASE WHEN packets IS NULL OR packets<1 THEN 1 WHEN packets>2147483647 THEN 2147483647 ELSE packets END,
  CASE WHEN company IS NULL OR company<0 OR company>65535 OR company IN (0,65535) THEN '' ELSE company END,
  '',
  substr(replace(replace(replace(CAST(name AS TEXT),char(9),' '),char(10),' '),char(13),' '),1,32),
  CASE WHEN connectable=1 THEN 1 ELSE 0 END,
  lastseen
FROM (SELECT mac, le_random, rssi_avg, packets, company, name, connectable, MAX(last_seen) AS lastseen
      FROM bt_device
      WHERE transports=1 AND length(mac)=12 AND mac NOT GLOB '*[^0-9A-Fa-f]*'
        AND rssi_avg IS NOT NULL AND rssi_avg BETWEEN -127 AND -1
        AND last_seen<=$2 AND last_seen>=$2-120
      GROUP BY mac)
ORDER BY rssi_avg DESC;
SELECT '#STARCHORUS_BT5OK#';
" 2>/dev/null
}
# bt_blue5_read: $1 = ts. Reads blue5.db (its RAM copy) into $BT_F.out, the file add_layers reads (SC_BTP), as B-lines with the real
# last_seen. 0 = a complete read, the records (maybe none) in $BT_F.out; 1 = transient (no copy, a bad clock, or no complete answer:
# the caller makes it a void cycle, mode 2, so the held records fade instead of the layer blinking off). The blue5 tools are never run.
# The company name, which blue5.db does not hold, is filled from the company list (btco_fill) when one is in use.
bt_blue5_read() {
    case $1 in ''|0|*[!0-9]*) return 1 ;; esac
    bt_blue5_copy "$BLUE5_DB" || return 1
    BT_F="$TMPDIR_RAM/starchorus-bt-$$.txt"
    br_raw=$(bt_blue5_sql "$BT5_DB" "$1")
    bt_blue5_done
    case $br_raw in *"#STARCHORUS_BT5OK#"*) ;; *) return 1 ;; esac
    br_um=$(umask); umask 077
    printf '%s\n' "$br_raw" | grep "^B$RECON_TAB" | btco_fill | clean_ctrl > "$BT_F.out" 2>/dev/null
    umask "$br_um"
    return 0
}

# bt_foreign_holder: 0 = a scanner that is not ours (the firmware's own blue5) is running, so it holds the controller and our own
# passive window must stand down -- strict passivity never drives a controller another program is using. Read-only: it looks for a
# blue5 process in BT_PROC with bt_is (the one process form the passivity check allows); no such process = nonzero, the controller is
# free for our window. On a host without /proc (the dev machine) the glob matches nothing and it returns nonzero, so the window runs.
bt_foreign_holder() {
    for fh_d in "$BT_PROC"/[0-9]*; do
        [ -d "$fh_d" ] || continue
        fh_p=${fh_d##*/}
        bt_is "$fh_p" blue5 && return 0
    done
    return 1
}

# The ONLY place a Bluetooth tool is started (tools/passivity-check.sh: BT_FUNCS, row 'Bluetooth lines in bt_begin'). btmon first,
# and the scan only once btmon holds its monitor socket, so btmon decodes the scan parameters the scan sets (the passivity witness,
# bt_parse). Both under timeout -s INT as dead-man timers. HUP and QUIT are ignored for the two launches only: a terminal that closes
# must not end hcitool past its SIGINT handler (a `timeout` that installs its own handlers, as the device's coreutils one does, starts its command with
# the signals at default: there the measure protects nothing, and the 1-s hold of bt_end abort is what keeps an early INT off a scan that has not yet
# installed its handler). The pid file comes first, with its marker line, and only then is the other collectors' state looked at: of two collectors that
# start at the same moment at most one runs a window (both may stand back once). rc 0 started, 3 flag off, 4 no controller or no tool, 5 another
# collector's window is running, 6 btmon did not get ready (nothing was asked of the controller), 7 a scanner that is not ours (blue5) holds the controller.
bt_begin() {
    BT_SPID=""; BT_MPID=""; BT_SKID=""; BT_MKID=""; BT_TS=0; BT_VOID=""; BT_NOTES=""
    [ "$BLUETOOTH" = "1" ] || return 3
    [ -d "$BT_SYSFS/hci0" ] || return 4
    have hcitool || return 4
    have btmon || return 4
    have timeout || return 4
    if bt_foreign_holder; then return 7; fi   # a scanner that is not ours (the firmware's blue5) holds the controller: stand down, strict passivity
    BT_F="$TMPDIR_RAM/starchorus-bt-$$.txt"; BT_PF="$TMPDIR_RAM/starchorus-bt-$$.pid"
    bt_um=$(umask); umask 077
    printf 'P %s\n' "$$" > "$BT_PF" 2>/dev/null && : > "$BT_F" 2>/dev/null && : > "$BT_F.err" 2>/dev/null; bt_rc=$?
    umask "$bt_um"
    [ "$bt_rc" = 0 ] || { rm -f "$BT_F" "$BT_F.err" "$BT_PF" 2>/dev/null; return 4; }
    if bt_busy; then rm -f "$BT_F" "$BT_F.err" "$BT_PF" 2>/dev/null; return 5; fi
    trap '' HUP QUIT; BT_ARM=m
    timeout -s INT "$BT_MON_S" btmon -i hci0 > "$BT_F" 2>/dev/null &
    BT_MPID=$!; BT_ARM=""
    trap 'cleanup; exit 129' HUP; trap - QUIT
    BT_MKID=$(bt_kid "$BT_MPID" btmon)
    bt_ready "$BT_MKID" || { bt_note; return 6; }
    bt_tick; BT_TS=$BT_NOW; trap '' HUP QUIT; BT_ARM=s
    timeout -s INT "$BT_WIN" hcitool -i hci0 lescan --passive --duplicates > /dev/null 2> "$BT_F.err" &
    BT_SPID=$!; BT_ARM=""
    trap 'cleanup; exit 129' HUP; trap - QUIT
    BT_SKID=$(bt_kid "$BT_SPID" hcitool)
    bt_note
    return 0
}

# [abort]: waits for the window to run its course, stops what is left, reads the text (bt_parse) and judges it (bt_judge). Only by pid, and only
# while bt_is still says the pid runs that tool.
#   1. Wait, by the clock, while the scan lives: at most until the watchdog's deadline, the scan's own end plus 2 s (BT_TS + the window + 2 s). The
#      polls are 0.5 s apart until one second before that deadline (one second after the scan's own end) and 0.2 s apart from then on. One second
#      after the scan is gone the monitor gets INT (it has recorded the disable by then) and up to BT_T_MON more to flush and end. If the window's text
#      grows past BT_MAXB (a runaway, far beyond any window; the size is looked at every 2 s, at the poll that falls due) the monitor is stopped at
#      once and the episode is logged. When the monitor never got ready (BT_SPID empty) only the monitor is stopped, without the second.
#   2. The watchdog. The scan: INT about once a second until it is gone, after BT_T_TERM one TERM and a log line, NEVER KILL; a TERM that did
#      not end it is given a second and then left (its pid file stays for bt_sweep). The monitor: INT, BT_T_MON, TERM, BT_T_MON, KILL. A wrapper
#      that outlives its tool by BT_T_WRAP gets TERM. A window that needed the watchdog is void.
#   3. Wait for the wrappers, parse unless the window is already void, remove the files, clear the pids.
# abort (cleanup(), inside a signal trap): INT to both tools (to a scan younger than a second one second after its start: its handler may not be in
# place before, and an INT before it ends the scan with the controller still scanning), a poll by the clock for up to 2 s, INT again to what is left,
# return. No wait, no parse, no escalation: the dead-man timers and the next start's bt_sweep finish the job, and the whole trap stays within about
# 3 s (the payload's fast stop allows 10 s). The window's text and error files are removed; the pid file stays while a tool still runs.
bt_end() {
    bt_t0=$(bt_now)
    BT_VOID=""; BT_NOTES=""; BT_STRAND=""
    if [ -z "$BT_MPID$BT_SPID" ]; then BT_VOID=none; return 0; fi
    bt_tick
    [ "$BT_TS" -gt 0 ] 2>/dev/null || BT_TS=$bt_t0
    be_ab=0; [ "$1" = abort ] && be_ab=1
    be_dl=$((BT_WIN * 100 + 200)); be_cap=$((be_dl + BT_T_TERM + 100 + BT_T_GRACE + 2 * BT_T_MON + 300 + BT_SLK))
    be_gone=""; be_w0=""; be_si=""; be_st=""; be_sg=""; be_mi=""; be_mt=""; be_mk=""; be_bg=""; be_ck=$bt_t0; be_f1=""; be_wt=""
    while :; do
        bt_tick
        be_sa=""; be_ma=""
        if [ -n "$BT_SKID" ]; then bt_is "$BT_SKID" hcitool && be_sa=$BT_SKID; elif [ -n "$BT_SPID" ] && bt_up "$BT_SPID"; then be_sa=$BT_SPID; fi
        if [ -n "$BT_MKID" ]; then bt_is "$BT_MKID" btmon && be_ma=$BT_MKID; elif [ -n "$BT_MPID" ] && bt_up "$BT_MPID"; then be_ma=$BT_MPID; fi
        if [ "$be_ab" = 1 ]; then
            # a scan younger than a second may not have installed its INT handler yet (a coreutils `timeout` starts it with INT at default): hold the first INT
            if [ -z "$be_f1" ] && [ -n "$be_sa" ] && [ $((BT_NOW - BT_TS)) -lt 100 ]; then bt_nap; continue; fi
            if [ -z "$be_f1" ]; then
                be_f1=$BT_NOW
                [ -z "$be_sa" ] || bt_sig INT "$be_sa"
                [ -z "$be_ma" ] || bt_sig INT "$be_ma"
            elif [ $((BT_NOW - be_f1)) -ge 200 ]; then
                [ -z "$be_sa" ] || bt_sig INT "$be_sa"
                [ -z "$be_ma" ] || bt_sig INT "$be_ma"
                break
            fi
            [ -n "$be_sa$be_ma" ] || break
            bt_nap; continue
        fi
        if [ -n "$be_ma" ] && [ -z "$be_bg" ] && [ $((BT_NOW - be_ck)) -ge 200 ]; then
            be_ck=$BT_NOW; file_size "$BT_F"
            if [ "${FSZ:-0}" -gt "$BT_MAXB" ] 2>/dev/null; then be_bg=1; BT_NOTES="$BT_NOTES big"; bt_sig INT "$be_ma"; be_mi=$BT_NOW; fi
        fi
        if [ -n "$be_sa" ] && [ $((BT_NOW - BT_TS)) -ge "$be_dl" ]; then
            [ -n "$be_w0" ] || { be_w0=$BT_NOW; BT_NOTES="$BT_NOTES watchdog"; }
            if [ -n "$be_st" ]; then
                [ $((BT_NOW - be_st)) -lt 100 ] || be_sg=1
            elif [ $((BT_NOW - be_w0)) -lt "$BT_T_TERM" ]; then
                if [ -z "$be_si" ] || [ $((BT_NOW - be_si)) -ge "$BT_T_INT" ]; then bt_sig INT "$be_sa"; be_si=$BT_NOW; fi
            elif [ -n "$BT_SKID" ]; then
                bt_sig TERM "$be_sa"; be_st=$BT_NOW; BT_NOTES="$BT_NOTES terminated"
            else
                be_sg=1
            fi
        fi
        if [ "$be_sg" = 1 ] && [ -n "$be_sa" ]; then BT_STRAND=$be_sa; be_sa=""; fi
        if [ -z "$be_sa" ]; then
            [ -n "$be_gone" ] || be_gone=$BT_NOW
            be_gr=$BT_T_GRACE; [ -n "$BT_SPID" ] || be_gr=0
            if [ -n "$be_ma" ]; then
                if [ -z "$be_mi" ]; then
                    if [ $((BT_NOW - be_gone)) -ge "$be_gr" ]; then bt_sig INT "$be_ma"; be_mi=$BT_NOW; fi
                elif [ -z "$be_mt" ]; then
                    if [ $((BT_NOW - be_mi)) -ge "$BT_T_MON" ]; then
                        if [ -n "$BT_MKID" ]; then bt_sig TERM "$be_ma"; BT_NOTES="$BT_NOTES watchdog"; fi
                        be_mt=$BT_NOW
                    fi
                elif [ -z "$be_mk" ]; then
                    if [ $((BT_NOW - be_mt)) -ge "$BT_T_MON" ]; then
                        if [ -n "$BT_MKID" ]; then bt_sig KILL "$be_ma"; fi
                        be_mk=$BT_NOW
                    fi
                elif [ $((BT_NOW - be_mk)) -ge 100 ]; then
                    break
                fi
            fi
        fi
        [ -n "$be_sa$be_ma" ] || break
        [ $((BT_NOW - BT_TS)) -lt "$be_cap" ] || break
        # Steady state (the scan alive, no watchdog yet, no big-window stop, the watchdog's deadline more than a second away): nothing is due but the scan's own
        # end and the 2-s size check, so nap 0.5 s, two sleeps a second where 0.2 s takes five; that end, and a runaway window, are then seen up to 0.5 s late
        # instead of 0.2 s, and so is a TERM that reaches only this shell (its trap waits for the nap). The signal rules of the watchdog and of the monitor
        # after the scan, the one-second holds and the abort (it naps and goes on in its own branch above; be_ab only keeps it so) keep the 0.2 s they are measured in.
        be_n=20
        if [ "$be_ab" = 0 ] && [ -n "$be_sa" ] && [ -z "$be_w0" ] && [ -z "$be_bg" ] && [ $((BT_NOW - BT_TS)) -lt $((be_dl - 100)) ]; then be_n=50; fi
        bt_nap "$be_n"
    done
    if [ "$be_ab" = 1 ]; then
        rm -f "$BT_F" "$BT_F.err" 2>/dev/null
        [ -n "$be_sa$be_ma$BT_STRAND" ] || rm -f "$BT_PF" 2>/dev/null
        BT_SPID=""; BT_MPID=""; BT_SKID=""; BT_MKID=""
        return 0
    fi
    be_scan=0; [ -z "$BT_SPID" ] || be_scan=1
    be_wr=""; [ -n "$BT_STRAND" ] || be_wr=$BT_SPID
    [ -n "$be_ma" ] || be_wr="$be_wr $BT_MPID"
    bt_tick; be_w0=$BT_NOW
    # shellcheck disable=SC2086  # a list of pids, some of them empty
    while [ -n "${be_wr# }" ]; do
        bt_tick
        be_live=""
        for be_w in $be_wr; do bt_up "$be_w" && be_live="$be_live $be_w"; done
        [ -n "$be_live" ] || break
        if [ $((BT_NOW - be_w0)) -ge "$BT_T_WRAP" ] && [ -z "$be_wt" ]; then
            for be_w in $be_live; do bt_sig TERM "$be_w"; done
            be_wt=1
        fi
        [ $((BT_NOW - be_w0)) -lt $((BT_T_WRAP + 100 + BT_SLK)) ] || break
        bt_nap
    done
    # shellcheck disable=SC2086
    for be_w in $be_wr; do bt_up "$be_w" || wait "$be_w" 2>/dev/null; done
    case $BT_NOTES in
        *watchdog*) BT_VOID=watchdog
            bt_issue watchdog "Bluetooth: the scan did not end by itself and was stopped; window discarded" ;;
    esac
    case $BT_NOTES in
        *terminated*) bt_issue terminated "Bluetooth: the scan did not end on SIGINT and was terminated; the controller may still be scanning (passive; see device-notes V-13)" ;;
    esac
    case $BT_NOTES in
        *big*) bt_issue busy "Bluetooth: busy air, parsed the first 256 KiB and the end of the window" ;;
    esac
    if [ "$be_scan" = 0 ]; then BT_VOID=nomonitor
    elif [ -n "$BT_VOID" ]; then :
    elif grep -q failed "$BT_F.err" 2>/dev/null; then
        BT_VOID=start
        bt_issue start "Bluetooth: the passive scan could not start (controller down or busy, or a scan still running); no Bluetooth this cycle"
    else
        be_um=$(umask); umask 077; : > "$BT_F.out" 2>/dev/null; umask "$be_um"   # the addresses of a window are for this process only
        bt_parse "$BT_F" > "$BT_F.out"; be_rc=$?
        if [ "$be_rc" = 124 ]; then
            BT_VOID=slow
            bt_issue slow "Bluetooth: the window took too long to read; window discarded"
        else
            bt_judge "$BT_F.out"
        fi
    fi
    rm -f "$BT_F" "$BT_F.err" 2>/dev/null
    [ -n "$be_ma$BT_STRAND" ] || rm -f "$BT_PF" 2>/dev/null
    BT_SPID=""; BT_MPID=""; BT_SKID=""; BT_MKID=""
    return 0
}

# Daemon start, before sweep_stale_workcopies: for each pid file of a collector that is gone, INT (never TERM or KILL) to each recorded tool that
# still runs its program with the recorded start; the file goes when nothing recorded in it lives 2 s later. So a collector killed with -9 leaves a
# tool behind for at most its own dead-man timer while the wrapper lives, and for at most until the next daemon start when the wrapper died too.
bt_sweep() {
    for bs_f in "$TMPDIR_RAM"/starchorus-bt-*.pid; do
        [ -e "$bs_f" ] || continue
        bs_h=${bs_f##*/starchorus-bt-}; bs_h=${bs_h%%.*}
        case $bs_h in ''|*[!0-9]*) continue ;; esac
        holder_alive "$bs_h" && continue
        bt_tick; bs_t0=$BT_NOW; bs_n=0
        for bs_pass in sig wait; do
            bs_n=0
            while read -r bs_k _ bs_t bs_s; do
                bs_hit=""
                case $bs_k in
                    M) bt_is "$bs_t" btmon && [ "$BT_ST_START" = "$bs_s" ] && bs_hit=$bs_t ;;
                    S) bt_is "$bs_t" hcitool && [ "$BT_ST_START" = "$bs_s" ] && bs_hit=$bs_t ;;
                esac
                [ -n "$bs_hit" ] || continue
                bs_n=$((bs_n + 1))
                if [ "$bs_pass" = sig ]; then bt_sig INT "$bs_hit"; fi
            done < "$bs_f"
            [ "$bs_n" -gt 0 ] || break
            if [ "$bs_pass" = sig ]; then
                while :; do
                    bt_tick; [ $((BT_NOW - bs_t0)) -lt $((200 + BT_SLK)) ] || break
                    bt_nap
                done
            fi
        done
        if [ "$bs_n" = 0 ]; then rm -f "$bs_f" 2>/dev/null; fi
    done
}

# --------------------------------------------------------------------------- reading a window: btmon text -> one record per address
# POSIX/BusyBox awk only: no gensub, no interval expressions, no length(array); index() where a fixed string will do. Lengths are in bytes.
# Output, one TAB line per address in the order first heard: B addr addr_type rssi reports company company_name name connectable(0|1), and a last
# line W passive active enabled disabled scanrsp suspect bad, where passive counts only a scan-parameters block with Type: Passive that stands before
# the first report, and bad = the extended commands and reports plus the frame numbers that did not increase (then a line F ext order follows).
#   The witness (a window counts only when all of it holds, bt_judge): a passive parameters block before the first report, no block with Type: Active,
#   no extended scan command and no extended advertising report (another program drives the controller), the scan enabled, strictly increasing frame
#   numbers (#n of the headers). The headers are matched by their opcode, not by the command name: btmon cuts a name to fit the width the process
#   prefix leaves ("LE Set Scan P.."), and prints no [hciN] tag when it was started with -i.
#   The 29-byte rule: a name may carry a line feed, and what follows it is a line of its own; under the legacy scan the controller hands over at most
#   31 bytes of advertising data, so a name is at most 29 bytes and none spans two real lines. It is a rule for names, not for every line the air can
#   write: print_manufacturer_apple of BlueZ 5.72 (company 76 or 19456, type 0x01) prints the bytes after its length byte as text with no bound to
#   the advertisement, so it reads on into the RSSI byte and stale buffer bytes, and in a multi-report event a run the advertiser controls can reach
#   about 36 bytes. The grammar therefore acts only on lines longer than that (headers over 40 bytes that do not start with a blank, Event type at least
#   38) or on lines in a position a forged line cannot take (a forged Address type or Address line, 35 and 34 bytes at least, only drops its sender's own
#   report, by the label order). Length alone does not keep a header out of a name: a 29-byte name "]: < HCI Event: plen 1 #0 1.0" makes a 54-byte line
#   that a test finding the marker anywhere would take for a header and count as frame 0, and one advertiser in range could void every window that way,
#   so the main rule asks for a first byte other than a blank before it asks hdr(). Type / Scanning count only as the FIRST field line after their
#   command header; a report is closed by RSSI, exactly once, and stays pending until the next line is a valid Event type or a header: any other field
#   line there means a forged short RSSI closed it early, and the report is
#   dropped (suspect). A hostile name can at most drop its own report or dress it up (a company name or a short name of its choosing, which it could
#   advertise anyway); it cannot create a record, change another, or touch the witness. Field lines are exactly eight blanks and a label; every
#   other line (ten-blank sub-lines, Flags, Data, TX power ...) is ignored, so the filtered and the unfiltered text give the same answer.
#   A line "#--#" (bt_parse puts it between the first part and the last part of a big window) resets the machine; an unconfirmed report at its
#   end, and one open at the end of the text, are dropped.
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_BT='
    function hdr(l,   p) {
        HP = ""
        if (length(l) <= 40) return 0
        p = l
        if (substr(p, 1, 2) != "< " && substr(p, 1, 2) != "> ") {
            if (!match(p, /\]: [<>] HCI /)) return 0
            p = substr(p, RSTART + 3)
        }
        if (p !~ /^[<>] HCI (Command|Event): /) return 0
        if (p !~ / plen [0-9]+ +#[0-9]+( \[hci[0-9]+\])? [0-9]+\.[0-9]+$/) return 0
        HP = p
        return 1
    }
    function sep() { rs = 0; inev = 0; evnext = 0; blk = ""; first = 0; last = -1 }
    function commit(   a, v) {
        rs = 0
        if (rdir || rscan || raddr == "" || rrssi == "") return
        a = raddr
        if (!(a in seen)) { seen[a] = 1; ord[na++] = a; mx[a] = rrssi + 0; ty[a] = rtype }
        else if (rrssi + 0 > mx[a]) mx[a] = rrssi + 0
        n[a]++
        if (co[a] == "" && rco != "") { co[a] = rco; cn[a] = rcn }
        v = (rnmc != "") ? rnmc : rnms
        if (nm[a] == "" && v != "") nm[a] = v
        if (rconn) cc[a] = 1
    }
    function dropr() { suspect++; rs = 0 }
    function newrep(t) {
        if (rs == 2) commit(); else if (rs == 1) suspect++
        nrep++
        rs = 1; st = 0; raddr = ""; rtype = ""; rrssi = ""; rco = ""; rcn = ""; rnmc = ""; rnms = ""; hc = 0; hnc = 0; hns = 0
        rdir = (index(t, "ADV_DIRECT_IND") > 0); rscan = (index(t, "SCAN_RSP") > 0); rconn = (!rdir && index(t, "ADV_IND") > 0)
        if (rscan) scanrsp++
    }
    function known(b) {
        return (b == "Type" || b == "Scanning" || b == "Event type" || b == "Address type" || b == "Address" || b == "Company" || b == "Name (complete)" || b == "Name (short)" || b == "RSSI")
    }
    function clip(v, k) { gsub(/\t/, " ", v); return substr(v, 1, k) }
    BEGIN { last = -1; na = 0; nrep = 0; rs = 0 }
    {
        l = $0
        if (l == "#--#") { sep(); next }
        # a header starts with "<", ">" or a process prefix, not with a blank: an indented line is never tested as one, so a name line that holds a header
        # ("        Name (complete): ]: < HCI Event: plen 1 #0 1.0") cannot move the frame count, and the field lines of eight blanks, most of the kept
        # lines, skip hdr(); only a process whose own name starts with a blank reads differently
        if (substr(l, 1, 1) != " " && hdr(l)) {
            if (rs == 2) commit(); else if (rs == 1) suspect++
            rs = 0; inev = 0; evnext = 0; blk = ""; first = 0
            p = HP
            t = l; sub(/^.* #/, "", t); sub(/[^0-9].*$/, "", t); f = t + 0
            if (f <= last) order++
            last = f
            d = substr(p, 1, 1)
            if (d == "<" && index(p, "(0x08|0x000b)")) { blk = "par"; first = 1 }
            else if (d == "<" && (index(p, "(0x08|0x0041)") || index(p, "(0x08|0x0042)"))) ext++
            else if (d == "<" && index(p, "(0x08|0x000c)")) { blk = "en"; first = 1 }
            else if (d == ">" && index(p, "LE Meta Event (0x3e)")) evnext = 1
            next
        }
        if (evnext) {
            evnext = 0
            if (l == "      LE Advertising Report (0x02)") { inev = 1; next }
            if (length(l) >= 34 && index(l, "      LE Extended Advertising Report") == 1) { ext++; next }
        }
        if (length(l) < 9 || substr(l, 1, 8) != "        " || substr(l, 9, 1) == " ") next
        t = substr(l, 9)
        b = t; sub(/:.*$/, "", b)
        if (blk != "" && first) {
            first = 0
            if (blk == "par") { if (t == "Type: Passive (0x00)") { if (nrep == 0) passive++ } else if (t == "Type: Active (0x01)") active++ }
            else if (t == "Scanning: Enabled (0x01)") enabled++
            else if (t == "Scanning: Disabled (0x00)") { if (enabled > 0) disabled++ }
            next
        }
        if (!inev || !known(b)) next
        if (b == "Event type" && length(l) >= 38 && l ~ / - [A-Z_]+ \(0x0[0-9a-f]\)$/) { newrep(t); next }
        if (rs == 2) { dropr(); next }
        if (rs != 1) next
        if (b == "Address type") {
            if (st != 0 || length(l) < 35) { dropr(); next }
            split(t, w, " ")
            if (w[3] != "Public" && w[3] != "Random") { dropr(); next }
            st = 1; rtype = w[3]; next
        }
        if (b == "Address") {
            if (st != 1 || length(l) < 34) { dropr(); next }
            split(t, w, " ")
            a = tolower(w[2])
            if (a !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) { dropr(); next }
            st = 2; raddr = a
            if (rtype == "Public") rtype = "public"
            else rtype = (w[3] == "(Static)") ? "random-static" : (w[3] == "(Resolvable)") ? "random-resolvable" : (w[3] == "(Non-Resolvable)") ? "random-nonresolvable" : "random"
            next
        }
        if (st != 2) { dropr(); next }
        if (b == "Company") {
            if (hc) { dropr(); next }
            hc = 1
            x = substr(t, 10)
            if (match(x, /\([0-9]+\)$/)) {
                id = substr(x, RSTART + 1, RLENGTH - 2); v = substr(x, 1, RSTART - 1); sub(/ +$/, "", v)
                if (id + 0 <= 65535) { rco = id + 0; rcn = (v == "not assigned") ? "" : clip(v, 48) }   # the monitor calls an unknown id "not assigned": the id stays, there is no name
            }
            next
        }
        if (b == "Name (complete)") { if (hnc) { dropr(); next } hnc = 1; rnmc = clip(substr(t, 18), 32); next }
        if (b == "Name (short)") { if (hns) { dropr(); next } hns = 1; rnms = clip(substr(t, 15), 32); next }
        if (b == "RSSI") {
            if (index(t, "RSSI: invalid") == 1) { rs = 0; next }
            if (t !~ /^RSSI: -?[0-9]+ dBm \(0x[0-9a-f][0-9a-f]\)$/) { dropr(); next }
            split(t, w, " ")
            if (w[2] + 0 < -127) { dropr(); next }
            if (w[2] + 0 >= 0) { rs = 0; next }   # a non-negative reading is the "no reading" marker (127, 0): dropped like RSSI: invalid, not counted as suspect
            rrssi = w[2] + 0; rs = 2; next
        }
        dropr()
    }
    END {
        for (i = 0; i < na; i++) { a = ord[i]; printf "B\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\n", a, ty[a], mx[a], n[a], co[a], cn[a], nm[a], (cc[a] ? 1 : 0) }
        printf "W\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", passive, active, enabled, disabled, scanrsp, suspect, ext + order
        if (ext + order > 0) printf "F\t%d\t%d\n", ext, order
    }
'
# $1 = the window's text file; stdout = the B and W lines. The first 256 KiB and the last 8 KiB of a bigger file are read (the disable block is at
# the end; BT_BIG says so), cut down by one grep (C speed) to the lines the grammar reads, then clean_ctrl; the awk runs under `timeout 6`, so a
# crowded hall can never hold the Wi-Fi document back for longer than that (rc 124: the caller voids the window). 256 KiB is roughly 600 reports (it was 512 KiB until 18 October 2026, when the Pager's awk, at 0.68 ms per kept line, ran past the 6 s on a 2-MiB test window).
bt_parse() {
    bp_k='(^|\]: )[<>] HCI |^      LE (Extended )?Advertising Report|^        (Type|Scanning|Event type|Address type|Address|Company|Name \(complete\)|Name \(short\)|RSSI): '
    file_size "$1"; bp_n=${FSZ:-0}; BT_BIG=0
    if [ "$bp_n" -gt 278528 ] 2>/dev/null; then BT_BIG=1; fi
    {
        if [ "$BT_BIG" = 1 ]; then
            head -c 262144 "$1" | LC_ALL=C grep -E "$bp_k"
            printf '#--#\n'
            tail -c 8192 "$1" | sed 1d | LC_ALL=C grep -E "$bp_k"
        else
            LC_ALL=C grep -E "$bp_k" "$1"
        fi
    } 2>/dev/null | clean_ctrl | {
        if have timeout; then LC_ALL=C timeout 6 awk "$AWK_BT"; else LC_ALL=C awk "$AWK_BT"; fi
    }
}
# $1 = the output of bt_parse. 0 = the window counts (what is odd about it is logged, once per episode); 1 = it is void, BT_VOID says why.
bt_judge() {
    BT_VOID=""
    # The first W line and the first F line of the output (the B lines come first, W after them, F after W), read with builtins: it was two sed | head pipelines,
    # four processes. A shell reads about 0.2 ms a line, so it reads at most 64 lines for them (a quiet window has some dozens of addresses); an output longer than
    # that, a crowded hall, has them found by the two pipelines as before, which cost the same however long the output is.
    bj_w=""; bj_f=""; bj_n=0
    {
        while IFS= read -r bj_l || [ -n "$bj_l" ]; do
            case $bj_l in
                W*) [ -n "$bj_w" ] || bj_w=$bj_l ;;
                F*) [ -n "$bj_f" ] || bj_f=$bj_l ;;
            esac
            bj_n=$((bj_n + 1))
            [ -z "$bj_w" ] || [ -z "$bj_f" ] || break
            [ "$bj_n" -le 64 ] || [ -n "$bj_w" ] || break
        done < "$1"
    } 2>/dev/null
    if [ -z "$bj_w" ] && [ "$bj_n" -gt 64 ]; then
        bj_w=$(sed -n '/^W/p' "$1" 2>/dev/null | head -n 1)
        bj_f=$(sed -n '/^F/p' "$1" 2>/dev/null | head -n 1)
    fi
    IFS=$RECON_TAB read -r _ bj_pa bj_ac bj_en bj_di bj_sr bj_su bj_bd <<EOF
$bj_w
EOF
    IFS=$RECON_TAB read -r _ bj_ex bj_or <<EOF
$bj_f
EOF
    case $bj_pa$bj_ac$bj_en$bj_di$bj_sr$bj_su$bj_bd in
        ''|*[!0-9]*) bj_pa=0; bj_ac=0; bj_en=0; bj_di=0; bj_sr=0; bj_su=0; bj_bd=0 ;;
    esac
    case ${bj_ex:-0}${bj_or:-0} in *[!0-9]*) bj_ex=0; bj_or=0 ;; esac
    if [ "$bj_ac" != 0 ] || [ "${bj_ex:-0}" != 0 ]; then
        BT_VOID=other
        bt_issue other "Bluetooth: another scan was seen on this device (not ours); window discarded"
    elif [ "${bj_or:-0}" != 0 ]; then
        BT_VOID=order
        bt_issue order "Bluetooth: monitor output out of order; window discarded"
    elif [ "$bj_pa" = 0 ] || [ "$bj_en" = 0 ]; then
        BT_VOID=nopassive
        bt_issue nopassive "Bluetooth: the monitor did not show a passive scan; window discarded"
    fi
    [ -z "$BT_VOID" ] || return 1
    case $BT_NOTES in
        *big*) ;;
        *) [ "$bj_di" != 0 ] || bt_issue nodisable "Bluetooth: no scan disable was seen; the controller may still be scanning (passive); see device-notes V-13" ;;
    esac
    [ "$bj_sr" = 0 ] || bt_issue scanrsp "Bluetooth: $bj_sr scan responses in a passive window (counted, not used)"
    [ "$bj_su" = 0 ] || bt_issue suspect "Bluetooth: $bj_su malformed reports dropped"
    [ "$BT_BIG" = 0 ] || bt_issue busy "Bluetooth: busy air, parsed the first 256 KiB and the end of the window"
    return 0
}

# --------------------------------------------------------------------------- the per-cycle layers: bluetooth, activity, alerts, center.bt_window / bt_hold
# ONE awk over the finished document (stdin), with the window's records (SC_BTP, bt_parse's lines), last cycle's records (SC_BTH, tab separated:
# the B fields, last_seen, carry), the RECON CHANNELS answer (SC_TRF) and a snapshot of the end of alerts.log (SC_ALF, SC_ALWIN seconds wide); it inserts
# "bluetooth": [...],  "activity": [...],  and  "alerts": [...],  (one line each) before the first line that starts  "aps": [  and
# ", "bt_window": N, "bt_hold": H" before the closing brace of the one-line center object, and writes the records for the next cycle to SC_BTN and a
# status file (lines added, records, traffic ok|none|bad|off, center done, alerts written, alert lines skipped) to SC_STAT. The alerts are the one
# input of the pass that the firmware's alert engine feeds through a file the collector did not write, so every field of it is untrusted text:
#   alerts.log: EPOCH TAB deauth TAB AP TAB ...  (the fields after the AP are not read). A line counts when its epoch is digits, its type is deauth, its AP is
#   an address (six pairs of hex digits, either case, written in lower case) and its epoch is at most SC_TS + 60 (a line from the future is a clock that
#   is wrong, not an alert); it is inside the window when SC_TS - SC_ALWIN <= epoch. A blank line is nothing; any other line that does not count is
#   skipped and counted (askip). The lines inside the window are grouped by AP: n = how many, t = the newest epoch. The groups are sorted by t, newest
#   first, then by address, and cut at 20 (insertion into a list of 20: a hall full of APs costs n times 20 steps at most, never n squared). An empty
#   result writes no key at all.
#   SC_BTMODE: 0 = Bluetooth off (nothing is written), 1 = a valid window (its addresses get last_seen = SC_TS, the clock of the cycle that is also the
#   document's "generated": a record is never later than the document that holds it, though the window ends a few seconds after the cycle began),
#   2 = a void one (the held records only; bt_window 0, so the layer runs out with its hold instead of blinking on one bad window).
#   The hold: a record not in this window keeps its line, carry + 1, while SC_TS - hold <= last_seen <= SC_TS and carry <= 4 (a clock that went
#   back cannot keep records alive, and the carry bounds the hold by cycles as well). Records are sorted by rssi descending, then address, and cut at
#   256 (a heap sort: the window of a crowded hall must not cost n squared steps).
#   The traffic answer: {"0":5,"2412":600,...}: blanks removed, ONE object, digit keys and digit values, anything else = bad; the values of the keys
#   from 2400 are summed, each share is value / sum with three decimals, written only where it is at least 0.001, sorted by frequency; a zero sum
#   writes nothing (none). Frames counted over a recent window, so a share, never a count.
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_LAYERS='
    function albefore(t1, a1, t2, a2) {
        if (t1 != t2) return (t1 > t2)
        return (a1 < a2)
    }
    function before(a, b) {
        if (rr[a] != rr[b]) return (rr[a] > rr[b])
        return (ad[a] < ad[b])
    }
    function sift(r, e, ix,   c, v) {
        v = ix[r]
        while ((c = 2 * r + 1) <= e) {
            if (c < e && before(ix[c], ix[c + 1])) c++
            if (before(v, ix[c])) { ix[r] = ix[c]; r = c } else break
        }
        ix[r] = v
    }
    function sortix(n, ix,   i, t) {
        for (i = 0; i < n; i++) ix[i] = i
        for (i = int((n - 2) / 2); i >= 0; i--) sift(i, n - 1, ix)
        for (i = n - 1; i > 0; i--) { t = ix[0]; ix[0] = ix[i]; ix[i] = t; sift(0, i - 1, ix) }
    }
    function addrec(a, ty_, r_, n_, co_, cn_, nm_, cc_, ls_, ca_) {
        ad[nrec] = a; tp[nrec] = ty_; rr[nrec] = r_ + 0; rp[nrec] = n_ + 0; cmp[nrec] = co_; cnm[nrec] = cn_; nmx[nrec] = nm_
        cnx[nrec] = cc_ + 0; lsn[nrec] = ls_ + 0; car[nrec] = ca_ + 0; have[a] = 1; nrec++
    }
    BEGIN {
        ts = ENVIRON["SC_TS"] + 0; hold = ENVIRON["SC_HOLD"] + 0; win = ENVIRON["SC_WIN"] + 0
        mode = ENVIRON["SC_BTMODE"] + 0; trf = ENVIRON["SC_TRAFFIC"] + 0; btsrc = ENVIRON["SC_BTSRC"]
        nrec = 0; added = 0; cdone = 0; adone = 0; btline = ""; actline = ""; tstat = "off"; nout = 0
        alline = ""; alent = 0; alskip = 0; alnap = 0
        alf = ENVIRON["SC_ALF"]
        if (alf != "" && ts > 0) {
            alwin = ENVIRON["SC_ALWIN"] + 0
            while ((getline line < alf) > 0) {
                if (line == "") continue
                aln = split(line, alc, "\t")
                alp = tolower(alc[3])
                if (aln < 3 || alc[1] !~ /^[0-9]+$/ || alc[2] != "deauth" || alp !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) { alskip++; continue }
                ale = alc[1] + 0
                if (ale > ts + 60) { alskip++; continue }
                if (ale < ts - alwin) continue
                if (!(alp in alcnt)) { alap[alnap++] = alp; alcnt[alp] = 0; alnew[alp] = 0 }
                alcnt[alp]++
                if (ale > alnew[alp]) alnew[alp] = ale
            }
            close(alf)
            for (ali = 0; ali < alnap; ali++) {
                alp = alap[ali]; ale = alnew[alp]
                if (alent == 20 && !albefore(ale, alp, alst[19], alsa[19])) continue
                alj = (alent < 20) ? alent : 19
                while (alj > 0 && albefore(ale, alp, alst[alj - 1], alsa[alj - 1])) { alst[alj] = alst[alj - 1]; alsa[alj] = alsa[alj - 1]; alj-- }
                alst[alj] = ale; alsa[alj] = alp
                if (alent < 20) alent++
            }
            alo = ""
            for (ali = 0; ali < alent; ali++) alo = alo (ali ? ", " : "") sprintf("{\"type\": \"deauth\", \"t\": %d, \"ap\": \"%s\", \"n\": %d}", alst[ali], alsa[ali], alcnt[alsa[ali]])
            if (alent > 0) alline = "  \"alerts\": [" alo "],"
        }
        if (mode == 1) {
            f = ENVIRON["SC_BTP"]
            while ((getline line < f) > 0) {
                if (split(line, c, "\t") >= 9 && c[1] == "B") {
                    ls = (c[10] ~ /^[0-9]+$/) ? c[10] + 0 : ts   # a blue5 B-line carries the real last_seen in a 10th field; a window line has none (-> ts, heard now)
                    if (ls > ts) ls = ts                         # never later than the document that holds it (a clock that moved back)
                    if (ls >= ts - hold) addrec(c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], ls, 0)
                }
            }
            close(f)
        }
        if (mode != 0) {
            f = ENVIRON["SC_BTH"]
            while ((getline line < f) > 0) {
                if (split(line, c, "\t") < 10 || (c[1] in have)) continue
                if (c[9] + 0 > ts || c[9] + 0 < ts - hold || c[10] + 1 > 4) continue
                addrec(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10] + 1)
            }
            close(f)
            sortix(nrec, ix)
            nout = (nrec > 256) ? 256 : nrec
            nf = ENVIRON["SC_BTN"]
            o = ""
            for (k = 0; k < nout; k++) {
                i = ix[k]
                o = o (k ? ", " : "") "{\"addr\": \"" jesc(ad[i]) "\", \"addr_type\": \"" jesc(tp[i]) "\", \"rssi\": " rr[i] ", \"reports\": " rp[i] ", \"last_seen\": " lsn[i]
                if (cmp[i] != "") o = o ", \"company\": " cmp[i]
                if (cnm[i] != "") o = o ", \"company_name\": \"" jesc(cnm[i]) "\""
                if (nmx[i] != "") o = o ", \"name\": \"" jesc(nmx[i]) "\""
                if (cnx[i]) o = o ", \"connectable\": true"
                o = o "}"
                printf "%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%d\n", ad[i], tp[i], rr[i], rp[i], cmp[i], cnm[i], nmx[i], cnx[i], lsn[i], car[i] > nf
            }
            close(nf)
            btline = "  \"bluetooth\": [" o "],"
        }
        if (trf == 1) {
            tstat = "bad"; s = ""; f = ENVIRON["SC_TRF"]
            while ((getline line < f) > 0) s = s line
            close(f)
            gsub(/[ \t\r]/, "", s)
            if (s ~ /^\{.*\}$/) {
                s = substr(s, 2, length(s) - 2)
                tstat = (s == "") ? "bad" : "none"
                if (s != "") {
                    np = split(s, pc, ",")
                    for (i = 1; i <= np; i++) {
                        if (pc[i] !~ /^"[0-9]+":[0-9]+$/) { tstat = "bad"; break }
                        q = index(pc[i], "\":"); kq = substr(pc[i], 2, q - 2) + 0
                        if (kq >= 2400) { if (!(kq in fv)) fk[nfk++] = kq; fv[kq] = substr(pc[i], q + 2) + 0 }
                    }
                    if (tstat != "bad") {
                        sum = 0
                        for (i = 0; i < nfk; i++) sum += fv[fk[i]]
                        if (sum > 0) {
                            for (i = 1; i < nfk; i++) { v = fk[i]; j = i - 1; while (j >= 0 && fk[j] > v) { fk[j + 1] = fk[j]; j-- } fk[j + 1] = v }
                            a = ""; na = 0
                            for (i = 0; i < nfk; i++) { x = fv[fk[i]] / sum
                                if (x >= 0.001) { a = a (na ? ", " : "") sprintf("{\"freq\": %d, \"share\": %.3f}", fk[i], x); na++ } }
                            if (na > 0) { actline = "  \"activity\": [" a "],"; tstat = "ok" }
                        }
                    }
                }
            }
        }
    }
    {
        if (!cdone && mode != 0 && index($0, "  \"center\": {") == 1 && match($0, /\},?$/)) {
            if (btsrc == "blue5")   # blue5 has no scan window of its own: no bt_window, a source marker instead (window docs stay exactly as before)
                $0 = substr($0, 1, RSTART - 1) ", \"bt_hold\": " hold ", \"bt_source\": \"blue5\"" substr($0, RSTART)
            else
                $0 = substr($0, 1, RSTART - 1) ", \"bt_window\": " win ", \"bt_hold\": " hold substr($0, RSTART)
            cdone = 1 }
        if (!adone && index($0, "  \"aps\": [") == 1) {
            if (mode != 0) { print btline; added++ }
            if (actline != "") { print actline; added++ }
            if (alline != "") { print alline; added++ }
            adone = 1 }
        print
    }
    END {
        sf = ENVIRON["SC_STAT"]
        printf "added %d\nbt %d\ntraffic %s\ncenter %d\nalerts %d\naskip %d\n", added, (mode != 0 ? nout : -1), tstat, cdone, alent, alskip > sf
        close(sf)
    }
'
# Sets AL_ON for this cycle: 1 when the switch is on and $ALERT_DIR/alerts.log is a readable regular file with something in it. Shell tests only, so a Pager
# that has no such file pays no process for the feature. A name that is there but is no readable regular file (a directory, a pipe, which `tail` would
# wait on for ever) is said once per episode and read as no file.
alerts_look() {
    AL_ON=0
    [ "$ALERTS" = 1 ] && [ -e "$ALERT_DIR/alerts.log" ] || return 0
    if [ -f "$ALERT_DIR/alerts.log" ] && [ -r "$ALERT_DIR/alerts.log" ]; then
        [ -s "$ALERT_DIR/alerts.log" ] && AL_ON=1
    else
        bt_issue alertsread "Alerts: $ALERT_DIR/alerts.log is not a readable file; no alerts this cycle"
    fi
    return 0
}
# $1 = the document (rewritten in place, or left alone when the pass failed its shape check), $2 = the Bluetooth mode (see AWK_LAYERS). Reads $ts,
# BT_HELD, the window's parse output, the RECON CHANNELS file of this process and, when alerts_look set AL_ON, the last 256 KiB of alerts.log: a snapshot,
# so that the awk reads a file that stays as it is while a companion alert appends to the log (the companion keeps 2,000 lines of about 90 bytes, so a
# log of its own is read whole; a larger one is somebody else's, and its first line, cut in the middle, is skipped and said). Returns post_keep's answer;
# BT_HELD_NEW = the records for the next cycle. The alert lines the awk skipped are said once per episode.
add_layers() {
    al_b="$TMPDIR_RAM/starchorus-bt-$$"
    al_um=$(umask); umask 077; : > "$al_b.held" 2>/dev/null; : > "$al_b.new" 2>/dev/null; umask "$al_um"   # addresses: for this process only
    if [ -n "$BT_HELD" ]; then printf '%s\n' "$BT_HELD" > "$al_b.held" 2>/dev/null; fi
    al_w=0; [ "$2" != 1 ] || al_w=$BT_WIN
    al_f=""
    if [ "$AL_ON" = 1 ]; then
        umask 077; : > "$al_b.alog" 2>/dev/null; umask "$al_um"   # addresses again
        if tail -c 262144 "$ALERT_DIR/alerts.log" > "$al_b.alog" 2>/dev/null; then al_f="$al_b.alog"
        else bt_issue alertsread "Alerts: $ALERT_DIR/alerts.log could not be read; no alerts this cycle"; fi
    fi
    SC_TS=$ts SC_HOLD=$BT_HOLD SC_WIN=$al_w SC_BTMODE=$2 SC_BTSRC="$3" SC_TRAFFIC=$TRAFFIC SC_BTP="$BT_F.out" SC_BTH="$al_b.held" SC_BTN="$al_b.new" \
        SC_TRF="$TMPDIR_RAM/starchorus-traffic-$$.json" SC_ALF="$al_f" SC_ALWIN=$ALERT_WIN SC_STAT="$al_b.stat" LC_ALL=C awk "$AWK_JSON_HELPERS$AWK_LAYERS" < "$1" > "$1.l" 2>/dev/null
    post_keep "$1" l $? "$(sed -n 's/^added //p' "$al_b.stat" 2>/dev/null)" || return 1
    al_k=$(sed -n 's/^askip //p' "$al_b.stat" 2>/dev/null)
    case $al_k in
        ''|0|*[!0-9]*) ;;
        *) bt_issue alertsskip "Alerts: $al_k line(s) of alerts.log skipped (a valid line has a digit epoch, deauth and an access point address in its first three fields)" ;;
    esac
    return 0
}
# $1 = the document of this cycle, as it is about to be published. The Bluetooth window of the cycle is ended and judged here (bt_end), the
# RECON CHANNELS call is waited for, add_layers runs (when Bluetooth or Traffic is on, or alerts_look found an alert log), and the records for the next cycle are kept.
run_layers() {
    rl_m=0; rl_src=""
    if [ "$BLUETOOTH" = 1 ] && [ "$BT_SRC" = blue5 ]; then
        rl_src=blue5
        if bt_blue5_read "$ts"; then rl_m=1; else rl_m=2; fi
    elif [ "$BLUETOOTH" = 1 ] && [ "$BT_SRC" = window ]; then
        case $BT_RC in
            0) bt_end_timed
               if [ -z "$BT_VOID" ]; then rl_m=1; else rl_m=2; fi ;;
            5) bt_issue overlap "Bluetooth: another collector's window is running; this one skipped"; rl_m=2 ;;
            6) bt_end_timed; bt_issue monitor "Bluetooth: the monitor did not start in time; no scan this cycle"; rl_m=2 ;;
            7) bt_issue foreign "Bluetooth: the Pager's own scanner holds the controller; our own window stands down this cycle (strict passivity)"; BT_HELD="" ;;
            *) bt_issue nocontroller "Bluetooth: no controller (hci0), or a scan tool or timeout is missing; Bluetooth stays off"; BT_HELD="" ;;
        esac
    fi
    if [ -n "$TR_PID" ]; then wait "$TR_PID" 2>/dev/null; TR_PID=""; fi
    rl_b="$TMPDIR_RAM/starchorus-bt-$$"
    if [ "$rl_m" != 0 ] || [ "$TRAFFIC" = 1 ] || [ "$AL_ON" = 1 ]; then
        if add_layers "$1" "$rl_m" "$rl_src"; then
            [ "$rl_m" = 0 ] || BT_HELD=$(cat "$rl_b.new" 2>/dev/null)
        fi
        if [ "$TRAFFIC" = 1 ] && [ "$(sed -n 's/^traffic //p' "$rl_b.stat" 2>/dev/null)" != ok ] && [ "$(sed -n 's/^traffic //p' "$rl_b.stat" 2>/dev/null)" != none ]; then
            bt_issue traffic "Traffic: the AP service gave no usable channel list"
            TR_REUSE=0   # an answer that gave nothing is not carried to the next cycle: that one calls again
        fi
    fi
    rm -f "$rl_b.held" "$rl_b.new" "$rl_b.stat" "$rl_b.alog" 2>/dev/null
    # the answer file stays for the cycle that reads it again (TR_REUSE, run_cycle); in any other case it goes with the cycle
    [ "$TR_REUSE" = 1 ] || rm -f "$TMPDIR_RAM/starchorus-traffic-$$.json" 2>/dev/null
    [ -z "$BT_F" ] || rm -f "$BT_F.out" 2>/dev/null
}

# ============================================================================ AWK LIBRARIES
# Shared awk helpers, prepended to every JSON-emitting awk program so the emission stays identical
# across sources. POSIX/busybox-awk safe: no gensub, no asorti, no length(array), no {n} interval regex.
AWK_JSON_HELPERS='
    function jesc(s,   i,c,o,n){
        if(!index(s,"\\") && !index(s,"\"") && !index(s,"\t")) return s     # nothing to escape (nearly always): three searches, not a walk over the string
        o=""; n=length(s)
        for(i=1;i<=n;i++){ c=substr(s,i,1)
            if(c=="\\") o=o "\\\\"
            else if(c=="\"") o=o "\\\""
            else if(c=="\t") o=o "\\t"
            else o=o c }
        return o }
    function numval(v){ if(v ~ /^-?[0-9]+$/) return v; return "null" }
    function macfmt(s,   t){ t=s; gsub(/[^0-9A-Fa-f]/,"",t)
        if(length(t)==12){ t=tolower(t); return substr(t,1,2) ":" substr(t,3,2) ":" substr(t,5,2) ":" substr(t,7,2) ":" substr(t,9,2) ":" substr(t,11,2) }
        return s }
    function ismac(s){ return (length(s)==17 && s ~ /^[0-9A-Fa-f:]+$/) }
    function band_from_freq(f){
        if(f>=2400 && f<2500) return "2.4GHz"
        if(f>=4900 && f<5925) return "5GHz"
        if(f>=5925)           return "6GHz"
        return "" }
    function band_norm(b){
        if(b ~ /6/) return "6GHz"; if(b ~ /5/) return "5GHz"
        if(b ~ /2/) return "2.4GHz"; return "" }
    function band_from_ch(ch){ if(ch>=1 && ch<=14) return "2.4GHz"; if(ch>0) return "5GHz"; return "" }
    function ch_from_freq(f){
        if(f>=2412 && f<=2472) return int((f-2407)/5)
        if(f==2484) return 14
        if(f>=5000 && f<5925) return int((f-5000)/5)
        if(f==5935) return 2                          # 6GHz channel 2: the one odd centre (5935 MHz)
        if(f>=5950) return int((f-5950)/5)
        return "" }
    function freq_from_ch(ch){
        if(ch>=1 && ch<=13) return 2407+ch*5
        if(ch==14) return 2484
        if(ch>=15) return 5000+ch*5
        return "" }
    function freq_from_ch6(ch){                       # 6GHz: 5950 + 5*ch, except channel 2 = 5935 MHz
        if(ch==2) return 5935
        if(ch>=1) return 5950+ch*5
        return "" }
    # document pieces shared by every emitter (ts, center and src are set by each emitter via -v)
    function doc_head(){ printf "{\n  \"generated\": %s,\n  \"center\": {\"label\": \"%s\"%s},\n  \"source\": \"%s\",\n", ts, jesc(center), ENVIRON["SC_CX"], src }
    function ap_json(pbss,pssid,pch,pband,pfreq,prssi,psec,pextra,pcli){
        return sprintf("    {\"bssid\": \"%s\", \"ssid\": \"%s\", \"channel\": %s, \"band\": \"%s\", \"freq\": %s, \"rssi\": %s, \"security\": \"%s\"%s, \"clients\": [%s]}", pbss, pssid, pch, pband, pfreq, prssi, psec, pextra, pcli) }
    function cl_json(cmac,crssi,cextra){ return sprintf("    {\"mac\": \"%s\", \"rssi\": %s%s}", cmac, crssi, cextra) }
'

# ============================================================================ VENDOR LOOKUP
# PASSIVE, LOCAL, file-only: the first 3 MAC bytes (OUI-24) are looked up in an OUI text file
# that is already on the device (the firmware ships /lib/hak5/oui.txt; nmap and macchanger ship their
# own). Nothing is fetched, nothing is sent. Implemented as ONE awk post-pass over the finished
# emitter JSON (all sources get it for free, the emitters stay untouched):
#   * collects the prefixes of every "mac"/"bssid" value and looks them up in the persistent prefix
#     cache $CAPDIR/oui-cache.txt  (PREFIX<TAB>vendor; an empty vendor is a NEGATIVE entry = "not in
#     the file", so it is never looked up again),
#   * reads the OUI file for exactly the prefixes that are NOT yet cached, once (stops early when all
#     are found): the index of the file where there is one (oui_index), else the whole file,
#   * appends the new hits + negatives to the cache, then rewrites the JSON lines, inserting
#     `, "vendor": "..."` right after the MAC value (jesc-escaped) or `, "randomized": true`
#     for locally-administered client MACs (U/L bit set: 2nd hex digit 2/6/A/E). Those are
#     never looked up: IEEE assigns no such OUIs and phones rotate them per network, which
#     would otherwise flood the negative cache and force a full file scan nearly every cycle.
#     An AP with a locally-administered BSSID (virtual/guest BSS) gets neither field.
# The cache header "# oui=<path> size=<bytes> mtime=<secs>" ties it to one file; a different,
# resized or rewritten file (or a cache > 20000 lines) restarts it. Any failure in this pass leaves
# the plain emitter JSON untouched -- vendor is optional by contract.
# The details sit at their code: the index at oui_index, the strict cache loader (cload) and the negative
# entries (only after a complete scan) in AWK_VENDOR, the merge at the cache-lock block and cache_append.
# Accepted file formats (one tolerant parser): nmap `AABBCC Vendor`, macchanger `AA BB CC VENDOR`,
# `AA:BB:CC - Vendor`, IEEE oui.txt `AA-BB-CC   (hex)<TAB>Vendor` / `AABBCC (base 16)<TAB>Vendor`,
# Wireshark manuf `AA:BB:CC<TAB>Short<TAB>Long Name`. `#` comments, CRLF, and MA-M/MA-S blocks
# (7/9 hex or /28, /36) are skipped; the first line for a prefix wins.
# A candidate is usable only if it is a regular file AND at least one of its first 300 lines
# parses as a prefix line (`AABBCC<ws>`, `AA:BB:CC`, `AA-BB-CC`, `AA BB CC`). Without this probe a
# file in an unknown format would silently turn every prefix into a negative cache entry and
# "vendor" would never appear, although a known-good file (nmap) sits right next to it.
file_usable() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }   # a readable, non-empty regular file
oui_format_ok() {
    file_usable "$1" || return 1
    head -n 300 "$1" 2>/dev/null | grep -q -E \
        '^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][[:space:]]|^[0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][[:space:]]'
}

# Modification time in Unix seconds ("" if unknown): busybox `date -r FILE` (the device), then
# GNU/busybox stat, then BSD/macOS stat. Used in the cache header so a rewritten OUI file of the
# SAME byte size (firmware update) still restarts the cache.
file_mtime() {
    m=$(date -r "$1" +%s 2>/dev/null)
    case "$m" in *[!0-9]*|"") m=$(stat -c %Y "$1" 2>/dev/null) ;; esac
    case "$m" in *[!0-9]*|"") m=$(stat -f %m "$1" 2>/dev/null) ;; esac
    case "$m" in *[!0-9]*|"") m="" ;; esac
    printf '%s' "$m"
}

# Prints the file to use and returns 0; 1 = none; 2 = the explicit STARCHORUS_OUI_FILE exists but is
# not parsable (setup_vendor logs that). Directories and empty files are never accepted.
# Paths are returned with printf, never echo: a POSIX echo (dash, bash as /bin/sh) interprets
# `\t` `\b` `\n` `\c` ... in a stick path like /mnt/b\ts and the mangled path opens nothing.
find_oui_file() {
    if [ "$OUI_FILE" != "auto" ]; then
        oui_format_ok "$OUI_FILE" && { printf '%s\n' "$OUI_FILE"; return 0; }
        file_usable "$OUI_FILE" && return 2
        return 1
    fi
    for c in /lib/hak5/oui.txt /usr/share/nmap/nmap-mac-prefixes /usr/share/macchanger/OUI.list; do
        oui_format_ok "$c" && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# The Bluetooth company list. The blue5 source reports a company by its Bluetooth SIG identifier alone (blue5.db has no name
# column), where the window source had btmon's decoded name. The firmware ships the list beside the OUI file as
# /lib/hak5/bt_companies.txt, one `XXXX<TAB>Name` line per identifier (four hex digits, upper case). It is a text file that is
# read, like the OUI file; nothing is started. A candidate is usable only if it is a regular file whose first 300 lines hold such
# a line, so a file of another shape cannot turn every identifier into a blank name.
btco_format_ok() {
    file_usable "$1" || return 1
    head -n 300 "$1" 2>/dev/null | grep -q -E '^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][[:space:]]'
}
# Prints the file to use and returns 0; 1 = none; 2 = the explicit STARCHORUS_BT_COMPANIES_FILE exists but does not parse.
find_btco_file() {
    if [ "$BTCO_FILE" != "auto" ]; then
        btco_format_ok "$BTCO_FILE" && { printf '%s\n' "$BTCO_FILE"; return 0; }
        file_usable "$BTCO_FILE" && return 2
        return 1
    fi
    btco_format_ok /lib/hak5/bt_companies.txt && { printf '%s\n' /lib/hak5/bt_companies.txt; return 0; }
    return 1
}
# setup_btco: choose the company list, where setup_vendor chooses the OUI file; it logs only when its state changes.
setup_btco() {
    BTCO_PATH=$(find_btco_file); bc_r=$?
    if [ -z "$BTCO_PATH" ]; then
        if [ "$bc_r" = 2 ]; then
            bc_s="bad:$BTCO_FILE"
            [ "$BTCO_STATE" = "$bc_s" ] || log "warning: no usable company list in STARCHORUS_BT_COMPANIES_FILE=$BTCO_FILE (expected id<TAB>name lines); Bluetooth companies by id alone"
        else
            bc_s="none"
            [ "$BTCO_STATE" = "$bc_s" ] || log "no Bluetooth company list found (STARCHORUS_BT_COMPANIES_FILE=$BTCO_FILE); Bluetooth companies by id alone"
        fi
        BTCO_STATE=$bc_s; return 0
    fi
    [ "$BTCO_STATE" = "$BTCO_PATH" ] || log "Bluetooth companies: $BTCO_PATH"
    BTCO_STATE=$BTCO_PATH
}
# btco_fill: stdin = the B-lines of the blue5 source, stdout = the same lines with the company name (field 7) filled from the
# list where field 6 holds an identifier and the name is still blank; without a list the lines pass unchanged. The identifier is
# looked up as four upper-case hex digits; the first line of an identifier wins; a name is cut to 48 characters, the page's own cap.
btco_fill() {
    if [ -z "$BTCO_PATH" ]; then cat; return 0; fi
    awk -F"$RECON_TAB" -v OFS="$RECON_TAB" -v tbl="$BTCO_PATH" '
        BEGIN { while ((getline l < tbl) > 0) { if (l ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][\t ]/) { k = toupper(substr(l, 1, 4)); v = substr(l, 6); sub(/^[\t ]+/, "", v); sub(/[\r\t ]+$/, "", v); if (v != "" && !(k in nm)) nm[k] = v } } close(tbl) }
        { if (NF >= 7 && $6 ~ /^[0-9]+$/ && $7 == "") { k = sprintf("%04X", $6 + 0); if (k in nm) $7 = substr(nm[k], 1, 48) } print }'
}

# The OUI index. Without an index a new prefix costs a pass over the whole OUI file (38,959 lines on the device, about 14 s of its CPU in awk), and in a
# busy place a new prefix shows up in most cycles. The index is the OUI file split by first octet: $CAPDIR/oui-index/00 ... FF (upper case), each
# holding that octet's lines as they stand in the file, in file order (a few hundred lines each), and hdr: the header line the cache carries for
# the same OUI file (path, size, mtime), and a second line naming the octets that are split further. The IEEE list has a third of its lines
# under 00, so an octet with more than OUI_IDX_MAX lines (the two biggest at most) is split by its first TWO octets (00AB, ...: its lines are in
# those files only). A lookup reads the files of the prefixes it needs with the same parser as a pass over the file, so the vendor strings, the
# first-line-wins rule and the negative entries are the same by construction. The index is built once per OUI file (setup_vendor: at start and
# when the file changed) in a directory of its own, moved into place under the cache lock with hdr written last: a directory with a matching
# hdr and all its files is complete. A missing or mismatching index is no error: the awk scans the OUI file instead.
# Only lines that start with two hex digits are kept. In a split octet a line must also yield its second octet (compact `AABBCC` or separated
# `AA-BB-CC`), or the parser would reject it anyway.
# shellcheck disable=SC2016  # awk program text
AWK_OUIIDX='
    BEGIN{ d=ENVIRON["SC_IDXDIR"]; nh=split(ENVIRON["SC_IDXHEAVY"], HV, " "); for(i=1;i<=nh;i++) HEAVY[HV[i]]=1
        H16="0123456789ABCDEF"; L16="0123456789abcdef"
        for(i=1;i<=16;i++) for(j=1;j<=16;j++){ k=substr(H16,i,1) substr(H16,j,1); F[k]=d "/" k      # F: the file of each octet
            KEY[k]=k; KEY[substr(L16,i,1) substr(H16,j,1)]=k; KEY[substr(H16,i,1) substr(L16,j,1)]=k; KEY[substr(L16,i,1) substr(L16,j,1)]=k } }   # KEY: hex pair in any case -> octet
    { k=KEY[substr($0,1,2)]; if(k==""){ sk++; next }
      if(nh>0 && (k in HEAVY)){ c3=substr($0,3,1)
          o2=toupper((c3==" " || c3==":" || c3=="-") ? substr($0,4,2) : substr($0,3,2))
          if(!(o2 in F)){ sk++; next }
          k=k o2; if(!(k in F)) F[k]=d "/" k }
      print > F[k] }
    END{ for(i=0;i<256;i++){ k=sprintf("%02X",i)      # a file for every octet, empty if the OUI file has none: a missing one means a damaged index
             if(k in HEAVY){ for(j=0;j<256;j++) printf "" > (d "/" k sprintf("%02X",j)) }
             else printf "" > (d "/" k) }
        print NR-sk }
'
oui_index_ok() {   # 0 = $CAPDIR/oui-index was built from the OUI file OUI_HDR names and has all its files
    ih=""; ovf=""; { { IFS= read -r ih; IFS= read -r ovf; } < "$CAPDIR/oui-index/hdr"; } 2>/dev/null
    [ -n "$OUI_HDR" ] && [ "$ih" = "$OUI_HDR" ] || return 1
    # shellcheck disable=SC2086  # the word splitting is the count: the split octets
    set -- $ovf
    ix_c=$((257 + 255 * $#))      # 256 octets and hdr, 255 more for each split octet
    set -- "$CAPDIR/oui-index"/*
    [ $# -eq $ix_c ]
}
oui_index() {   # sets OUI_IDX; builds the index when it is not there for this OUI file
    OUI_IDX=""
    [ -n "$OUI_CACHE" ] || return 0
    ix="$CAPDIR/oui-index"
    if oui_index_ok; then OUI_IDX=$ix; return 0; fi
    nd=$(mktemp -d "$ix.new.$$.XXXXXX" 2>/dev/null) && [ -d "$nd" ] || return 0       # (named for this pid: the start-up sweep removes those of dead ones)
    ix_t0=$(date +%s 2>/dev/null)
    ix_h=$(cut -c1-2 "$OUI_PATH" 2>/dev/null | sort -f | uniq -c -i | sort -rn | head -n 2 | \
           awk -v t="$OUI_IDX_MAX" '$1 + 0 > t + 0 { k = toupper($2); if (k ~ /^[0-9A-F][0-9A-F]$/) printf "%s%s", (n++ ? " " : ""), k }')
    # (the awk keeps up to 256 + 255 per split octet files open: the soft limit of a desktop shell is lower than that)
    # shellcheck disable=SC3045  # BusyBox ash, dash and bash have ulimit -n; where it fails the limit stays and a build that cannot open its files fails whole
    ix_n=$(ulimit -n 1024 2>/dev/null; SC_IDXDIR="$nd" SC_IDXHEAVY="$ix_h" awk "$AWK_OUIIDX" "$OUI_PATH" 2>/dev/null); ix_rc=$?
    # every line the awk kept must be on disk: a file cut short (no room) would turn into negative cache entries for good
    if [ "$ix_rc" = 0 ] && [ "${ix_n:-0}" -gt 0 ] 2>/dev/null && [ "$(cat "$nd"/* 2>/dev/null | wc -l | tr -d ' ')" = "$ix_n" ] \
       && { printf '%s\n%s\n' "$OUI_HDR" "$ix_h" > "$nd/hdr"; } 2>/dev/null; then
        cache_lock; ix_lr=$?
        if [ "$ix_lr" != 2 ]; then
            if oui_index_ok; then :           # another instance has just built the same index
            else rm -rf "$ix" 2>/dev/null; mv "$nd" "$ix" 2>/dev/null; rm -rf "${ix:?}/${nd##*/}" 2>/dev/null; fi
        fi
        cache_unlock
        if oui_index_ok; then
            OUI_IDX=$ix
            ix_t1=$(date +%s 2>/dev/null)
            [ -z "$ix_t0" ] || [ -z "$ix_t1" ] || log "vendor index: $ix_n lines of $OUI_PATH in $ix${ix_h:+ (octets $ix_h split by their first two)}, $((ix_t1 - ix_t0)) s, built once per OUI file"
        fi
    fi
    rm -rf "$nd" 2>/dev/null
}

# Called at startup (after CAPDIR exists) and again every 120 cycles by the daemon loop, so a
# replaced OUI file (firmware update, swapped USB stick) is picked up without a restart. Sets
# OUI_PATH / OUI_CACHE; logs only when the outcome changed. With STARCHORUS_VENDOR=0 the post-pass is
# never run (plain emitter JSON).
setup_vendor() {
    OUI_PATH=""; OUI_CACHE=""; OUI_IDX=""
    if [ "$VENDOR" != "1" ]; then
        [ "$VENDOR_STATE" = "off" ] || log "vendor lookup disabled (STARCHORUS_VENDOR=$VENDOR)"
        VENDOR_STATE="off"; return 0
    fi
    OUI_PATH=$(find_oui_file); fr=$?
    if [ -z "$OUI_PATH" ]; then
        if [ "$fr" = "2" ]; then
            st="bad:$OUI_FILE"
            [ "$VENDOR_STATE" = "$st" ] || log "warning: no usable OUI format in STARCHORUS_OUI_FILE=$OUI_FILE (expected Nmap / IEEE / macchanger / manuf lines); JSON will carry no \"vendor\" field"
        else
            st="none"
            [ "$VENDOR_STATE" = "$st" ] || log "no OUI database found (STARCHORUS_OUI_FILE=$OUI_FILE); JSON will carry no \"vendor\" field"
        fi
        VENDOR_STATE=$st; return 0
    fi
    file_size "$OUI_PATH"; sz=$FSZ
    mt=$(file_mtime "$OUI_PATH")
    hdr="# oui=$OUI_PATH size=${sz:-0} mtime=${mt:-0}"
    vc="$CAPDIR/oui-cache.txt"
    nl=0; [ -f "$vc" ] && nl=$(wc -l < "$vc" | tr -d ' ')
    if [ "$(head -n 1 "$vc" 2>/dev/null)" != "$hdr" ] || [ "${nl:-0}" -gt 20000 ] 2>/dev/null; then
        # (re)start the cache for this file -- under the lock, so a `--once` that is merging lines
        # gathered from the OLD file right now cannot slip them under the NEW header (cache_append
        # also re-checks the header against OUI_HDR once it holds the lock).
        OUI_CACHE=$vc; cache_lock
        { printf '%s\n' "$hdr" > "$vc"; } 2>/dev/null
        cache_unlock; OUI_CACHE=""
    fi
    OUI_HDR=$hdr
    if [ -w "$vc" ]; then
        OUI_CACHE=$vc
        cache_repair          # a crash mid-append may have left an unterminated last line
    fi
    oui_index
    st="$hdr|${OUI_CACHE:-nocache}|${OUI_IDX:-noindex}"
    if [ "$VENDOR_STATE" != "$st" ]; then
        [ -n "$OUI_CACHE" ] || log "warning: cannot write $vc; vendor cache off (OUI file scanned every cycle)"
        log "vendor lookup: $OUI_PATH${OUI_CACHE:+ (cache $OUI_CACHE)}${OUI_IDX:+ (index $OUI_IDX)}"
        [ -z "$OUI_CACHE" ] || [ -n "$OUI_IDX" ] || log "warning: no OUI index in $CAPDIR; a new prefix costs a scan of the OUI file"
    fi
    VENDOR_STATE=$st
}

# awk body of the post-pass. Needs AWK_JSON_HELPERS (jesc) prepended. Environment: SC_CACHE (file or ""),
# SC_OUI (file or ""), SC_IDX (the OUI index directory, or "") with SC_HDR (the header its hdr file must carry),
# SC_NEWF (append target for new cache lines, or ""), SC_TERM (see BEGIN).
# shellcheck disable=SC2016  # awk program text: $0 is awk's field, deliberately not expanded
AWK_VENDOR='
    function vtrim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function vstrip(s,   i,n,c,o){ o=""; n=length(s)      # drop control bytes (CTRL: 1-31, 127)
        for(i=1;i<=n;i++){ c=substr(s,i,1); if(index(CTRL,c)==0) o=o c }
        return o }
    function cload(l,   p,v){
        # Only the prefixes this document has are looked at at all (seen, from collect): a line for any other costs two operations, not eleven.
        # STRICT: exactly 6 upper hex (the seen gate guarantees them: seen holds only prefixes collect took from valid MACs) + ONE tab
        # + a vendor without further tab. A torn, fused or foreign line is ignored, so its prefix is simply looked up again. Control
        # bytes in the vendor part (bit rot, an editor that left a CR) are stripped -- served from the cache they would otherwise make
        # EVERY cycle emit invalid JSON. (The regex gate keeps the per-line cost near zero for the usual plain-ASCII cache.)
        p=substr(l,1,6); if(!(p in seen)) return
        if(index(l,"\t")!=7) return
        v=substr(l,8); if(index(v,"\t")>0) return
        if(v ~ /[^ -~]/) v=vstrip(v)
        if(!(p in V)) V[p]=v }
    function vend(rest,   n,a,i,v){
        rest=vtrim(rest)
        if(substr(rest,1,5)=="(hex)")     rest=substr(rest,6)
        if(substr(rest,1,9)=="(base 16)") rest=substr(rest,10)
        rest=vtrim(rest)
        if(substr(rest,1,1)=="-") rest=substr(rest,2)
        rest=vtrim(rest)
        if(index(rest,"\t")>0){ n=split(rest,a,"\t"); v=""
            for(i=1;i<=n;i++){ if(vtrim(a[i])!="") v=vtrim(a[i]) }
            rest=v }
        return vstrip(rest) }
    function pfx(mac){ return toupper(substr(mac,1,2) substr(mac,4,2) substr(mac,7,2)) }
    function laa(mac){ return (substr(mac,2,1) ~ /[26AEae]/) }
    function ismac17(m){ return (m ~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) }
    # collect() looks at every MAC of the document once and remembers what it found (PF: MAC -> prefix, LA: locally administered), so that enrich()
    # does not have to work it out again; a MAC collect() did not see (the two walk the line a character apart) is judged afresh.
    function collect(line,key,   pos,rest,mac,p,kl){ rest=line; kl=length(key)
        while((pos=index(rest,key))>0){ mac=substr(rest,pos+kl,17)
            if(ismac17(mac)){ if(laa(mac)) LA[mac]=1; else { p=pfx(mac); PF[mac]=p; seen[p]=1 } }
            rest=substr(rest,pos+kl+17) } }
    function enrich(line,key,iscl,   out,pos,rest,mac,p,ins,kl,kind){ out=""; rest=line; kl=length(key)
        while((pos=index(rest,key))>0){ mac=substr(rest,pos+kl,17); ins=""
            if(mac in PF){ kind=1; p=PF[mac] }
            else if(mac in LA) kind=2
            else if(ismac17(mac)){ if(laa(mac)) kind=2; else { kind=1; p=pfx(mac) } }
            else kind=0
            if(kind>0 && substr(rest,pos+kl+17,1)=="\""){
                if(kind==2){ if(iscl) ins=", \"randomized\": true" }
                else if((p in V) && V[p]!="") ins=", \"vendor\": \"" jesc(V[p]) "\"" }
            out=out substr(rest,1,pos+kl+17) ins
            rest=substr(rest,pos+kl+18) }
        return out rest }
    # One file in an OUI format (the OUI file itself, or one file of the index) read until every wanted prefix is found. Returns the last getline
    # status: < 0 = the file could not be read. A line that cannot be a wanted prefix is skipped before the parser sees it (the parser costs about
    # 0.36 ms a line on the device, these tests a third of that or less); they only drop lines the parser would not have taken for a wanted prefix:
    # gate 1 (the file as a whole): the first octet is not wanted; gate 2 (a file of the index, all of one octet): the first six hex digits are
    # neither wanted as they stand (AABBCC) nor as the separated form (AA-BB-CC, any of blank colon dash).
    function ouiscan(f, gate,   r,line,p,rest){
        while((r=(getline line < f))>0){
            if(gate==1){ if(!(toupper(substr(line,1,2)) in OCT)) continue }
            else if(gate==2){ p=toupper(substr(line,1,6)); if(!(p in want)){ p=toupper(substr(line,1,2) substr(line,4,2) substr(line,7,2)); if(!(p in want)) continue } }
            if(substr(line,length(line),1)==CR) line=substr(line,1,length(line)-1)
            if(!match(line,/^[0-9A-Fa-f]+/)) continue
            if(RLENGTH==6){ p=substr(line,1,6); rest=substr(line,7) }
            else if(RLENGTH==2 && line ~ /^[0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f]/){
                p=substr(line,1,2) substr(line,4,2) substr(line,7,2); rest=substr(line,9) }
            else continue
            if(rest!="" && rest !~ /^[ \t]/) continue
            p=toupper(p)
            if(!(p in want)) continue
            delete want[p]; V[p]=vend(rest)
            if(newf!="") printf "%s\t%s\n", p, V[p] >> newf
            nw--; if(nw<=0) break }
        close(f)
        return r }
    # The wanted prefixes from the index (see oui_index): the file of the first octet of each prefix, or of its first two where hdr names the octet as split,
    # the lines in file order, so the first line for a prefix wins as it does in the file. 0 = every file needed was read (what is left in want is not
    # in the OUI file); -1 = no usable index (no hdr naming this OUI file, a file missing or unreadable): the caller scans the OUI file instead.
    function ouiindex(   h,hf,xp,k,i,r){
        hf=idx "/hdr"
        if((getline h < hf)<=0 || h!=ENVIRON["SC_HDR"]){ close(hf); return -1 }
        if((getline h < hf)>0){ k=split(h, IXH, " "); for(i=1;i<=k;i++) IXHEAVY[IXH[i]]=1 }
        close(hf)
        k=0; for(xp in want){ h=(substr(xp,1,2) in IXHEAVY) ? substr(xp,1,4) : substr(xp,1,2); if(!(h in IXS)){ IXS[h]=1; IXO[++k]=h } }
        for(i=1;i<=k && nw>0;i++){ hf=idx "/" IXO[i]; r=ouiscan(hf,2); if(r<0) return -1 }
        return 0 }
    BEGIN{ cache=ENVIRON["SC_CACHE"]; oui=ENVIRON["SC_OUI"]; idx=ENVIRON["SC_IDX"]; newf=ENVIRON["SC_NEWF"]
        KM="\"mac\": \""; KB="\"bssid\": \""; n=0
        CTRL=sprintf("%c",127); for(i=1;i<=31;i++) CTRL=CTRL sprintf("%c",i)
        CR=sprintf("%c",13) }
    { L[++n]=$0; if(index($0,KM)) collect($0,KM); if(index($0,KB)) collect($0,KB) }
    END{
        if(cache!=""){
            # The prefix cache, only for the prefixes of this document (cload). Lines are committed one behind: the LAST line is trusted only if the
            # shell saw the cache end with a newline (SC_TERM=1). A line cut off by a crash looks well-formed to cload() and must not be served
            # when cache_repair could not drop it (unwritable dir).
            have=0
            while((getline l < cache)>0){ if(have) cload(prev); prev=l; have=1 }
            if(have && ENVIRON["SC_TERM"]=="1") cload(prev)
            close(cache) }
        nw=0; for(p in seen) if(!(p in V)){ want[p]=1; nw++ }
        r=0
        if(nw>0 && oui!=""){
            r=-1
            if(idx!="") r=ouiindex()
            if(r<0){ for(p in want) OCT[substr(p,1,2)]=1; r=ouiscan(oui,1) }
            # r<0: the file could not be opened/read (unplugged stick, permissions, i/o error) --
            # then nothing is known about the remaining prefixes, so NO negative entries; they are
            # simply tried again next cycle. Negatives only after a complete scan (r==0; r>0 means
            # every prefix was found and `want` is empty anyway).
            if(newf!=""){
                if(r>=0){ for(p in want){ printf "%s\t\n", p >> newf } }
                close(newf) } }
        for(i=1;i<=n;i++){ l=L[i]
            if(index(l,KM)>0) l=enrich(l,KM,1)
            if(index(l,KB)>0) l=enrich(l,KB,0)
            print l } }
'

# ---- cache write serialisation. Two instances can run at once (daemon loop + `--once` from crond,
# or two --once): every cache WRITE happens under a mkdir lock (atomic on every POSIX filesystem,
# busybox included). The holder writes its pid into $lock/pid, and staleness is judged by that
# pid, NOT by how long we have been waiting (a slow live holder -- a cache merge takes seconds on
# the device's MIPS CPU under load -- must never lose its lock):
#   * holder alive          -> a LIVE PROCESS RUNNING THIS SCRIPT (holder_alive; a reused pid of a
#                              foreign process, a zombie, are no holders): wait (0.2 s ticks; 1 s
#                              where sleep has no fractions), up to LOCK_BUDGET (10 s; a merge
#                              takes < 2 s even on the device), then give up THIS write (return 2;
#                              the lines are gathered again next cycle).
#   * holder dead           -> break at once (killed inside the critical section).
#   * no pid (yet)          -> the holder is between mkdir and the pid write, or died right there,
#                              or the pid is our own from a previous incarnation of this pid
#                              (pid reuse; also a subshell sibling under --selftest): 3 s grace,
#                              then break.
#   * ours, still held      -> re-entrant: depth +1, return 0 at once (cache_unlock counts down).
#   * unbreakable           -> the lock's directory is not writable (ro remount after an FS error /
#                              power loss on the eMMC OUTDIR): it can be neither taken nor broken,
#                              so give up at once (return 2), not after the budget.
# A give-up (return 2) is logged ONCE per episode and starts a 60-s backoff during which every
# cache write is skipped without waiting (vendor is still served; the OUI file is scanned instead).
# Breaking = rename the lock dir away (atomic: of two waiters only one succeeds, the other just
# goes on spinning), verify the moved dir still names the dead pid (a fresh, live lock grabbed in
# between is put back), then delete it. A release race (holder rmdir'ed between our mkdir and the
# `-d` test) gets a second mkdir before we conclude that the directory cannot hold a lock at all
# (plain file in the way -- removed, it is never ours -- or unwritable dir: return 1, the caller
# goes on without a lock, a single instance needs none). Return 0 = locked.
lock_take() {   # one mkdir attempt on $lk; on success the lock is ours (pid file written)
    mkdir "$lk" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$lk/pid" 2>/dev/null
    CACHE_LOCKED=1; LOCK_BUSY_LOGGED=0
}
lock_give_up() {   # $1 = reason. Log once, start the backoff, return 2 (= skip this write).
    [ "$LOCK_BUSY_LOGGED" = "1" ] || log "vendor cache lock: $1; cache writes skipped for 60 s (vendor still served, OUI file scanned each cycle)"
    LOCK_BUSY_LOGGED=1
    lnow=$(date +%s 2>/dev/null)
    case "$lnow" in ""|*[!0-9]*) LOCK_BUSY_UNTIL=0 ;; *) LOCK_BUSY_UNTIL=$((lnow+60)) ;; esac
    return 2
}
cache_lock() {
    [ -n "$OUI_CACHE" ] || return 1
    lk="$OUI_CACHE.lock"; lw=0; lnp=0
    if [ "${CACHE_LOCKED:-0}" -gt 0 ] 2>/dev/null && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ]; then
        CACHE_LOCKED=$((CACHE_LOCKED+1)); return 0      # re-entrant: we hold it already
    fi
    if [ "${LOCK_BUSY_UNTIL:-0}" -gt 0 ] 2>/dev/null; then
        lnow=$(date +%s 2>/dev/null)
        # (a clock set back by more than the backoff -- the device has no battery clock -- must not hold it for hours)
        if [ -n "$lnow" ] && [ "$lnow" -lt "$LOCK_BUSY_UNTIL" ] && [ $((LOCK_BUSY_UNTIL - lnow)) -le 60 ] 2>/dev/null; then return 2; fi
        LOCK_BUSY_UNTIL=0                                # backoff over: try again
    fi
    while :; do
        lock_take && return 0
        if [ ! -d "$lk" ]; then
            [ -f "$lk" ] && rm -f "$lk" 2>/dev/null
            lock_take && return 0
            [ -d "$lk" ] || return 1
        fi
        # A lock is in place. Unbreakable if its directory is not writable (see the list above; access() says so even for root).
        [ -w "${lk%/*}" ] || { lock_give_up "lock directory ${lk%/*} not writable"; return 2; }
        hp=$(cat "$lk/pid" 2>/dev/null)
        if [ -n "$hp" ] && [ "$hp" != "$$" ] && holder_alive "$hp"; then
            lnp=0                                          # live holder: wait
        elif [ -n "$hp" ] && [ "$hp" != "$$" ]; then
            cache_break "$lk" "$hp"; lb=$?                 # dead / foreign holder: break, retry at once
            [ "$lb" = "0" ] && continue
            [ "$lb" = "3" ] && { lock_give_up "stale lock of pid $hp cannot be broken"; return 2; }
        elif [ "$lnp" -ge 30 ]; then
            cache_break "$lk" "$hp"; lb=$?                 # no pid / own stale pid for 3 s: break
            [ "$lb" = "0" ] && continue
            [ "$lb" = "3" ] && { lock_give_up "pid-less lock cannot be broken"; return 2; }
        fi
        [ "$lw" -lt "$LOCK_BUDGET" ] || { lock_give_up "held by live pid ${hp:-?} for over $((LOCK_BUDGET/10)) s"; return 2; }
        if sleep 0.2 2>/dev/null; then lstep=2; else sleep 1; lstep=10; fi
        lw=$((lw+lstep)); lnp=$((lnp+lstep))
    done
}
# Break the lock at $1 whose holder ($2 = pid we saw, "" = none) we found dead. Returns 0 when the
# lock is gone (removed by us or by another waiter meanwhile), 1 when it is still in place, 3 when
# nothing can be created next to it (ro / full directory): unbreakable, do not spin on it.
cache_break() {
    [ -d "$1" ] || return 0
    stdir=$(mktemp -d "$1.stale.XXXXXX" 2>/dev/null) || return 3
    if mv "$1" "$stdir/" 2>/dev/null; then
        lgot=$(cat "$stdir/${1##*/}/pid" 2>/dev/null)
        if [ "$lgot" != "$2" ] && [ "$lgot" != "$$" ] && holder_alive "$lgot" && [ ! -e "$1" ]; then
            # a live holder took a fresh lock between our check and the rename: give it back
            mv "$stdir/${1##*/}" "$1" 2>/dev/null
            rm -rf "$stdir" 2>/dev/null
            return 1
        fi
    fi
    rm -rf "$stdir" 2>/dev/null
    [ -d "$1" ] && return 1
    return 0
}
cache_unlock() {
    if [ "${CACHE_LOCKED:-0}" -gt 1 ] 2>/dev/null; then CACHE_LOCKED=$((CACHE_LOCKED-1)); return 0; fi   # nested
    if [ "$CACHE_LOCKED" = "1" ] && [ -n "$OUI_CACHE" ]; then
        lk="$OUI_CACHE.lock"; hp=$(cat "$lk/pid" 2>/dev/null)
        # only OUR lock (or one whose pid file never made it): a waiter may have broken ours
        # legitimately while this process was stopped, and holds it now
        if [ -z "$hp" ] || [ "$hp" = "$$" ]; then rm -f "$lk/pid" 2>/dev/null; rmdir "$lk" 2>/dev/null; fi
    fi
    CACHE_LOCKED=0
}

# The cache must end with a newline: a cut-off last line (crash, power loss, ENOSPC, killed awk) must never be trusted or appended
# onto. An unterminated last line is DROPPED (the loader would otherwise trust a cut-off vendor name for good, and the next append
# would fuse two lines). cache_fix_unterminated expects the caller to hold the lock.
# An EMPTY (or missing) file counts as terminated: nothing can fuse with it (cache_append re-creates its header).
# One process: a command substitution drops the trailing newline, so the last byte of a terminated file comes back as nothing.
file_terminated() { [ ! -s "$1" ] || { [ -r "$1" ] && [ -z "$(tail -c 1 "$1" 2>/dev/null)" ]; }; }
cache_terminated() { file_terminated "$OUI_CACHE"; }
cache_fix_unterminated() {
    cache_terminated && return 0
    sed '$d' "$OUI_CACHE" > "$OUI_CACHE.fix.$$" 2>/dev/null && mv -f "$OUI_CACHE.fix.$$" "$OUI_CACHE"
    rm -f "$OUI_CACHE.fix.$$" 2>/dev/null
}
cache_repair() {   # cheap lock-free check first; only a damaged cache takes the lock
    cache_terminated && return 0
    cache_lock || return 0
    cache_fix_unterminated
    cache_unlock
}

# Append this instance's new lines ($1 = temp file of PREFIX<TAB>vendor lines). Only well-formed
# lines whose prefix is not in the cache yet are added (the other instance may have scanned the
# same prefixes meanwhile), so parallel instances never duplicate entries. The awk reads the
# cache completely (BEGIN) before its first line of output, and stdout is one small append.
# Whatever keeps the lines out of the cache costs a full scan of the OUI file in every later cycle (the prefixes are "new" again each
# time), so a merge that does not happen says why, once per episode; a successful one ends the episode and logs the growth.
vendor_dropped() {   # $1 = why
    [ "$VENDOR_DROP_LOGGED" = "1" ] || log "vendor cache: merge skipped ($1); the OUI file is scanned again next cycle"
    VENDOR_DROP_LOGGED=1
}
# The merge program, shared by the append and by the check after it. SC_CACHE = the cache, SC_TERM = 1 when the temp file ends with a newline
# (lines are committed one behind: the last one only then, or a line cut short by ENOSPC on /tmp or a killed awk would be persisted as
# a well-formed, wrong vendor for good), SC_CHECK = 1: print how many of the lines are NOT in the cache yet instead of printing them.
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_CAPPEND='
        function wf(l){ return (index(l,"\t")==7 && substr(l,1,6) ~ /^[0-9A-F]+$/ && index(substr(l,8),"\t")==0) }
        function emit(l,   p){ if(!wf(l)) return; p=substr(l,1,6); if(p in seen) return; seen[p]=1; if(chk) miss++; else print l }
        BEGIN{ c=ENVIRON["SC_CACHE"]; chk=(ENVIRON["SC_CHECK"]=="1")
            while((getline l < c)>0){ if(wf(l)) seen[substr(l,1,6)]=1 }
            close(c); have=0 }
        { if(have) emit(prev); prev=$0; have=1 }
        END{ if(have && ENVIRON["SC_TERM"]=="1") emit(prev)
            if(chk) print miss+0 }'
cache_append() {
    cache_lock; lr=$?
    [ "$lr" = "2" ] && return 0      # lock given up (live holder past the budget / backoff): next cycle (cache_lock logged it)
    cache_fix_unterminated
    # A cache that is gone or empty (tmpfs cleaner, a header write cut short and then dropped by
    # the repair) gets its header back right here, under the lock; otherwise the header test below
    # would skip EVERY merge until the daemon's 120-cycle re-check runs setup_vendor again.
    [ -s "$OUI_CACHE" ] || { printf '%s\n' "$OUI_HDR" > "$OUI_CACHE"; } 2>/dev/null
    # Never append onto a cache whose last line is still unterminated (the fix above failed:
    # unwritable directory -- the lines would fuse), nor onto one that setup_vendor has meanwhile
    # restarted for another OUI file (our lines came from the old one).
    if ! cache_terminated; then
        vendor_dropped "the last line of $OUI_CACHE is cut off and cannot be repaired"
        cache_unlock
        return 0
    fi
    if [ "$(head -n 1 "$OUI_CACHE" 2>/dev/null)" != "$OUI_HDR" ]; then
        vendor_dropped "the header of $OUI_CACHE names another OUI file"
        cache_unlock
        return 0
    fi
    cn0=$(wc -l < "$OUI_CACHE" 2>/dev/null | tr -d ' ')
    nt=0; file_terminated "$1" && nt=1
    # SC_TERM: see AWK_CAPPEND.
    # shellcheck disable=SC2094  # awk finishes reading the cache in BEGIN before its first print
    clean_ctrl < "$1" | SC_CACHE="$OUI_CACHE" SC_TERM="$nt" awk "$AWK_CAPPEND" >> "$OUI_CACHE"
    cn1=$(wc -l < "$OUI_CACHE" 2>/dev/null | tr -d ' ')
    if [ "${cn1:-0}" -gt "${cn0:-0}" ] 2>/dev/null; then
        VENDOR_DROP_LOGGED=0; log "vendor cache: $((cn1 - cn0)) new prefix(es), $cn1 lines"
    else
        # Nothing was added. Either the lines were in the cache already (the other instance, a crond --once next to the daemon, gathered the same
        # new prefixes and merged first: nothing is lost, the OUI file is not scanned again) or they could not be written.
        cm=$(clean_ctrl < "$1" | SC_CACHE="$OUI_CACHE" SC_TERM="$nt" SC_CHECK=1 awk "$AWK_CAPPEND")
        if [ "${cm:-1}" = 0 ]; then VENDOR_DROP_LOGGED=0
        else vendor_dropped "nothing was added to $OUI_CACHE (no write access, or no room)"; fi
    fi
    cache_unlock
}

# Daemon start-up, right after kill_loops (no other loop is alive now). The three sweeps (sweep_stale_cache_files, sweep_stale_tmp,
# sweep_stale_workcopies) remove what a previous collector left behind when it died hard (kill -9, power loss), ONLY where the owner
# pid embedded in the name is not a live collector (holder_alive): a crond `--once` may be running right now, and kill_loops leaves
# it alone on purpose. Not for --once.
# This one sweeps the cache's temp files (.new.<pid>.XXXXXX / .fix.<pid> / .gat.<pid>, the last being the gathering file of run_cycle's pass: add_vendor), an index build and the lock. The lock goes when its pid is
# no live collector either (holder_alive decides, see above): left in place it would cost every cycle the whole lock budget and the
# cache would never be written again. A pid-less lock is left to cache_lock's 3-s grace.
sweep_stale_cache_files() {
    for f in "$CAPDIR"/oui-cache.txt.new.* "$CAPDIR"/oui-cache.txt.fix.* "$CAPDIR"/oui-cache.txt.gat.*; do
        [ -e "$f" ] || continue
        p=${f##*.new.}; p=${p##*.fix.}; p=${p##*.gat.}; p=${p%%.*}
        holder_alive "$p" || rm -f "$f" 2>/dev/null
    done
    for f in "$CAPDIR"/oui-index.new.*; do       # an index build that died with its collector
        [ -e "$f" ] || continue
        p=${f##*.new.}; p=${p%%.*}
        holder_alive "$p" || rm -rf "$f" 2>/dev/null
    done
    rm -rf "$CAPDIR"/oui-cache.txt.lock.stale.* 2>/dev/null   # a lock breaker holds one for milliseconds
    lkd="$CAPDIR/oui-cache.txt.lock"
    if [ -d "$lkd" ]; then
        p=$(cat "$lkd/pid" 2>/dev/null)
        if [ -n "$p" ] && ! holder_alive "$p"; then
            log "removing stale vendor cache lock left by pid $p (not a live collector)"
            rm -rf "$lkd" 2>/dev/null
        fi
    fi
}

# The output files of a cycle cut short by a power cut or kill -9: starchorus.json.tmp.<pid>[.c|.v] (cleanup() never ran; the
# file can be zero bytes).
sweep_stale_tmp() {
    for f in "$OUTFILE".tmp.*; do
        [ -e "$f" ] || continue
        p=${f##*.tmp.}; p=${p%%.*}
        case "$p" in ''|*[!0-9]*) continue ;; esac
        holder_alive "$p" || rm -f "$f" 2>/dev/null
    done
}

# stdin = emitter JSON, stdout = same JSON plus optional vendor/randomized. One awk process.
# Paths reach awk via ENVIRON, not -v: -v values get backslash-escape processing (a stick path
# like /mnt/b\s would be mangled and the file silently "missing"). The temp file is created HERE,
# per instance (mktemp): an awk `>>` that cannot open its target is FATAL and would throw the
# whole post-pass away -- if CAPDIR is not writable we merely skip the cache write.
# $1 = "defer": leave the gathered lines in VENDOR_NEWF for a later vendor_merge instead of
# merging them here -- run_cycle publishes the JSON FIRST and merges afterwards, so a contended
# cache lock (up to LOCK_BUDGET) delays the cache, never the visualisation.
add_vendor() {
    newf=""; VENDOR_NEWF=""; term=0; newf_fix=0
    if [ -n "$OUI_CACHE" ]; then
        # the temp name carries OUR pid: the daemon's start-up sweep removes only files of dead pids
        if [ "$1" = "defer" ] && [ ! -s "$OUI_CACHE.gat.$$" ]; then
            # run_cycle's pass (one at a time in this shell): a name that stays, emptied by the redirect below each cycle and removed by cleanup, in place of a mktemp
            # and a rm for the file that nearly always stays empty (a new prefix is the exception). A pass that has left lines there unmerged is not touched: this one takes
            # a mktemp name, as every pass without "defer" does (two instances played in one shell by the self-test, a second add_vendor in the background).
            newf="$OUI_CACHE.gat.$$"; newf_fix=1
        else
            newf=$(mktemp "$OUI_CACHE.new.$$.XXXXXX" 2>/dev/null) || newf="$OUI_CACHE.new.$$.0"
        fi
        if printf '' > "$newf" 2>/dev/null; then VENDOR_NEWF=$newf; else newf=""; fi
        if cache_terminated; then term=1      # tells the loader whether the cache's last line is whole
        else cache_repair; cache_terminated && term=1; fi
    fi
    SC_CACHE="$OUI_CACHE" SC_OUI="$OUI_PATH" SC_IDX="$OUI_IDX" SC_HDR="$OUI_HDR" SC_NEWF="$newf" SC_TERM="$term" awk "$AWK_JSON_HELPERS$AWK_VENDOR"
    arc=$?
    # Merge only after a clean pass: with rc != 0 (ENOSPC on /tmp, awk killed) the temp file may
    # hold a cut-off line -- and run_cycle discards that JSON anyway.
    if [ "$arc" != "0" ] || [ ! -s "$newf" ]; then
        if [ -z "$newf" ]; then :
        elif [ "$newf_fix" != 1 ]; then rm -f "$newf" 2>/dev/null
        elif [ "$arc" != "0" ]; then { : > "$newf"; } 2>/dev/null      # (the name stays; what a failed pass left in it must not be merged by anybody)
        fi
        VENDOR_NEWF=""
    elif [ "$1" != "defer" ]; then
        vendor_merge
    fi
    return $arc
}
# Merge the lines a deferred add_vendor gathered (VENDOR_NEWF) into the cache and drop the temp
# file; with $1 = "discard" the lines are dropped unmerged (the pass's JSON was rejected).
vendor_merge() {
    if [ -n "$VENDOR_NEWF" ]; then
        [ "$1" = "discard" ] || cache_append "$VENDOR_NEWF"
        rm -f "$VENDOR_NEWF" 2>/dev/null
    fi
    VENDOR_NEWF=""
}

# --------------------------------------------------------------------------- JSON: airodump CSV
# airodump CSV has two comma-separated sections separated by a blank line:
#   AP section:      BSSID, First seen, Last seen, channel, Speed, Privacy, Cipher, Auth,
#                    Power(=RSSI dBm), #beacons, #IV, LAN IP, ID-length, ESSID, Key
#   Station section: Station MAC, First seen, Last seen, Power, #packets, BSSID, Probed ESSIDs
# Stations carry the associated AP BSSID (or "(not associated)"), giving us real client->AP
# links when the data frames were overheard. If none were, clients:[] is simply empty.
build_from_csv() {
    # shellcheck disable=SC2012  # need mtime order; busybox has no portable stat -c, ls -t is fine
    csv=$(ls -1t "$CAPDIR"/starchorus-*.csv 2>/dev/null | head -1)
    [ -s "$csv" ] || return 1
    clean_ctrl < "$csv" | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="airodump-csv" \
      "$AWK_JSON_HELPERS"'
        function trim(s){ sub(/^[ ]+/,"",s); sub(/[ ]+$/,"",s); return s }
        BEGIN{ FS=","; mode=""; nap=0; nun=0 }
        /^[ ]*BSSID,/        { mode="ap";  next }
        /^[ ]*Station MAC,/  { mode="sta"; next }
        /^[ ]*$/             { next }
        mode=="ap" {
            bssid=trim($1)
            if(!ismac(bssid)) next
            chan=trim($4)+0
            spd=trim($5)        # airodump "Speed": max rate the AP advertises (-1 = unknown)
            priv=trim($6); ciph=trim($7); auth=trim($8)
            pow=trim($9)
            # ESSID is field 14; Key is the LAST field. Rejoin 14..NF-1 so ESSIDs that
            # themselves contain commas survive; drop the trailing Key column.
            essid=""
            hi = (NF>=15) ? NF-1 : NF
            for(i=14;i<=hi;i++){ essid = essid (i>14?",":"") $i }
            essid=trim(essid)
            sec=priv
            if(auth!="" && auth!="OPN") sec=sec "/" auth
            if(ciph!="") sec=sec "/" ciph
            if(sec=="" || sec=="OPN") sec="Open"
            f=freq_from_ch(chan); b=band_from_freq(f); if(b=="") b=band_from_ch(chan)
            ap_bssid[nap]=macfmt(bssid); ap_ssid[nap]=essid; ap_chan[nap]=chan   # aa:bb:.. like every source
            ap_band[nap]=b; ap_freq[nap]=f; ap_pow[nap]=pow; ap_sec[nap]=sec
            ap_rate[nap]=(spd ~ /^[0-9]+$/ && spd+0>0) ? spd+0 : ""
            ap_index[bssid]=nap   # for client association
            nap++
        }
        mode=="sta" {
            mac=trim($1)
            if(!ismac(mac)) next
            pow=trim($4)
            abss=trim($6)
            if(ismac(abss) && (abss in ap_index)){
                k=ap_index[abss]
                cli[k]=cli[k] (clic[k]?",":"") \
                    "{\"mac\": \"" jesc(macfmt(mac)) "\", \"rssi\": " numval(pow) "}"
                clic[k]++
            } else {
                un[nun]=macfmt(mac); unp[nun]=pow
                pl=""; pc=0; split("", ps)
                for(i=7;i<=NF && pc<8;i++){ v=trim($i); if(v=="" || (v in ps)) continue; ps[v]=1; pc++; pl=pl (pl!=""?", ":"") "\"" jesc(v) "\"" }
                unpr[nun]=pl; nun++
            }
        }
        END{
            doc_head(); printf "  \"aps\": [\n"
            for(i=0;i<nap;i++){
                extra=(ap_rate[i]!="") ? ", \"rate\": " ap_rate[i] : ""
                printf "%s%s\n", ap_json(jesc(ap_bssid[i]), jesc(ap_ssid[i]), numval(ap_chan[i]"" ), jesc(ap_band[i]),
                    (ap_freq[i]!="" && ap_freq[i]>0?ap_freq[i]:"null"), numval(ap_pow[i]), jesc(ap_sec[i]),
                    extra, (i in cli?cli[i]:"")), (i<nap-1?",":"")
            }
            printf "  ],\n  \"unassociated\": [\n"
            for(i=0;i<nun;i++)
                printf "%s%s\n", cl_json(jesc(un[i]), numval(unp[i]), (unpr[i]!="" ? ", \"probes\": [" unpr[i] "]" : "")), (i<nun-1?",":"")
            printf "  ]\n}\n"
        }'
    return 0
}

# --------------------------------------------------------------------------- JSON: tcpdump burst
# Passive fallback when airodump-ng is absent (the device default). Listens for one short burst
# per cycle and classifies MACs: beacon/probe-response source = AP; probe-request source =
# client. Client<->AP association is NOT derived here (left empty, which the schema allows),
# because reliably pairing data frames from tcpdump -e text is fragile.
build_from_tcpdump() {
    [ -n "$MONIF" ] || return 1
    have tcpdump || return 1
    # as in start_airodump: only the interface this run made, never one it found
    if [ "$CREATED_MON" = 1 ]; then
        have ip && ip link set "$MONIF" up 2>/dev/null
    fi
    burst=$INTERVAL
    [ "$burst" -lt 1 ] 2>/dev/null && burst=2
    tcpdump_burst "$burst" | parse_tcpdump_text "$1"
    PACE_BT=$((PACE_BT + burst * 100))     # the burst listens for its whole length whatever the load: no load, taken off the wall time (pace_end)
    return 0
}

# Grab one burst of management frames. `timeout` bounds it to one cycle. If timeout is missing
# we background tcpdump and kill it after $burst seconds. Split out so --selftest can feed text.
tcpdump_burst() {
    burst=$1
    filt='(type mgt subtype beacon) or (type mgt subtype probe-req) or (type mgt subtype probe-resp)'
    if have timeout; then
        timeout "$burst" tcpdump -i "$MONIF" -l -e -s 256 "$filt" 2>/dev/null
    else
        tf="$CAPDIR/tcpdump.$$"
        tcpdump -i "$MONIF" -l -e -s 256 "$filt" >"$tf" 2>/dev/null &
        tdpid=$!
        i=0
        while [ "$i" -lt "$burst" ]; do sleep 1; i=$((i+1)); done
        kill "$tdpid" 2>/dev/null
        cat "$tf" 2>/dev/null; rm -f "$tf"
    fi
}

# Parse tcpdump -e text (fed on stdin) into the JSON schema. Isolated for offline self-test.
parse_tcpdump_text() {
    clean_ctrl | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="tcpdump" \
      "$AWK_JSON_HELPERS"'
        {
            line=$0
            # Split the line at the frame-type token. `head` = radiotap prefix (rate, MHz, dBm)
            # + addresses; `ssid` = the parenthesised SSID; `tail` = what tcpdump prints AFTER it:
            # "[rates Mbit]", ESS/IBSS, "CH: n", ", PRIVACY". AP attributes are searched in `tail`
            # ONLY and RSSI/SA in `head` ONLY. An SSID may itself contain ")" (valid, <= 32 bytes),
            # so the split is at the LAST ")" that is followed by one of those real fields (greedy
            # .*): tcpdump always prints them after the SSID, hence anything an SSID injects -- e.g.
            # "x) CH: 11, PRIVACY" -- stays inside `ssid`, verbatim, and never reaches `tail`.
            head=line; tail=""; ssid=""; tok=""
            if(match(line,/(Beacon|Probe Request|Probe Response) \(.*\)( \[| ESS| IBSS| CH:|, PRIVACY|$)/)){
                head=substr(line,1,RSTART-1); seg=substr(line,RSTART,RLENGTH); tail=substr(line,RSTART+RLENGTH)
                tok=seg; sub(/ \(.*$/,"",tok)
                sub(/^[^(]*\(/,"",seg)                  # seg = "SSID) <start of tail>" or "SSID)"
                i=length(seg); while(i>0 && substr(seg,i,1)!=")") i--
                tail=substr(seg,i+1) tail; ssid=substr(seg,1,i-1)
            } else if(match(line,/(Beacon|Probe Request|Probe Response)/)){
                head=substr(line,1,RSTART-1); tok=substr(line,RSTART,RLENGTH); tail=substr(line,RSTART+RLENGTH)
            }
            # RSSI (dBm), first match e.g. "-45dBm signal"
            rssi=""
            if(match(head,/-?[0-9]+dBm/)){ rssi=substr(head,RSTART,RLENGTH); sub(/dBm/,"",rssi) }
            # Source MAC (avoid {17} interval regex for old busybox awk; grab the run and clip 17)
            sa=""
            if(match(head,/SA:[0-9a-fA-F:][0-9a-fA-F:]*/)){ sa=substr(head,RSTART+3,17) }
            if(sa==""){ next }
            sa=macfmt(sa)
            isap = (tok=="Beacon" || tok=="Probe Response")
            isreq = (tok=="Probe Request")
            if(isap){
                ap_seen[sa]=1
                if(ssid!="") ap_ssid[sa]=ssid
                if(rssi!="" && (!(sa in ap_rssi) || rssi+0 > ap_rssi[sa]+0)) ap_rssi[sa]=rssi
                # DS Parameter Set channel "CH: n" (authoritative; LAST match -- the genuine field
                # is always printed last); radiotap "NNNN MHz" = the frequency the receiver was
                # tuned to (fallback, and 6GHz disambiguation).
                rest=tail; c=0
                while(match(rest,/ CH: [0-9]+/)){ c=substr(rest,RSTART+5,RLENGTH-5)+0; rest=substr(rest,RSTART+RLENGTH) }
                if(c>0) ap_ch[sa]=c
                if(match(head,/ [0-9][0-9][0-9][0-9] MHz/)){ f=substr(head,RSTART+1,4)+0; if(f>0) ap_fq[sa]=f }
                # Supported-Rates IE "[1.0* 2.0* ... 54.0 Mbit]" (last match): keep the highest (<= 54)
                rest=tail; seg=""
                while(match(rest,/\[[0-9. *]+ Mbit\]/)){ seg=substr(rest,RSTART+1,RLENGTH-2); rest=substr(rest,RSTART+RLENGTH) }
                if(seg!=""){ nr=split(seg,ra," ")
                    for(i=1;i<=nr;i++){ v=ra[i]; sub(/\*$/,"",v)
                        if(v ~ /^[0-9.]+$/ && int(v+0) > ap_rate[sa]+0) ap_rate[sa]=int(v+0) } }
                # Capability bits: PRIVACY (whole word in the genuine tail) => encrypted, else Open.
                if(tail ~ /(^|[ ,])PRIVACY([ ,]|$)/) ap_sec[sa]="Secured"
                else if(tail ~ / (ESS|IBSS)( |,|$)/ && ap_sec[sa]!="Secured") ap_sec[sa]="Open"
            } else if(isreq){
                cl_seen[sa]=1
                if(rssi!="" && (!(sa in cl_rssi) || rssi+0 > cl_rssi[sa]+0)) cl_rssi[sa]=rssi
                if(ssid!="" && !((sa SUBSEP ssid) in pseen) && pn[sa]<8){ pseen[sa SUBSEP ssid]=1; pn[sa]++; pr[sa]=pr[sa] (pr[sa]!=""?", ":"") "\"" jesc(ssid) "\"" }
            }
        }
        END{
            doc_head(); printf "  \"aps\": [\n"
            first=1
            for(m in ap_seen){
                r=(m in ap_rssi)?ap_rssi[m]:"null"
                s=(m in ap_ssid)?ap_ssid[m]:""
                c=(m in ap_ch)?ap_ch[m]:""; f=""
                if(c!=""){ f=((m in ap_fq) && ap_fq[m]>=5925) ? freq_from_ch6(c) : freq_from_ch(c) }
                else if(m in ap_fq){ f=ap_fq[m]; c=ch_from_freq(f) }
                b=(f!="")?band_from_freq(f):""
                extra=((m in ap_rate) && ap_rate[m]+0>0) ? ", \"rate\": " ap_rate[m] : ""
                printf "%s%s", (first?"":",\n"), ap_json(jesc(m), jesc(s), (c!=""?c:"null"), b, (f!=""?f:"null"), r,
                    ((m in ap_sec)?ap_sec[m]:""), extra, "")
                first=0
            }
            printf "\n  ],\n  \"unassociated\": [\n"
            first=1
            for(m in cl_seen){
                if(m in ap_seen) continue   # a device that also beacons is an AP, not a stray client
                r=(m in cl_rssi)?cl_rssi[m]:"null"
                printf "%s%s", (first?"":",\n"), cl_json(jesc(m), r, ((m in pr) ? ", \"probes\": [" pr[m] "]" : ""))
                first=0
            }
            printf "\n  ]\n}\n"
        }'
}

# --------------------------------------------------------------------------- JSON: recon DB
# SECONDARY passive source, the PREFERRED one on the device (resolve_source says why); it also gives band via the
# freq column. The engine is RX-only; we open the DB READ-ONLY. One table `ssid`
# holds every observation; `type` is the 802.11 mgmt subtype: 8=beacon and 5=probe-response (APs),
# 4=probe-request (clients). Schema families, tried in this order:
#   * RUNNING firmware (OpenWrt 24.10.1, confirmed live): hash, wifi_device, scan, type, bssid,
#     ssid(BLOB), hidden, time, signal, freq, channel, encryption; client MACs join via
#     ssid.wifi_device -> wifi_device.hash(.mac).
#   * apmac/stamac schema (AP-service binary of the firmware image): UNIQUE(scan,type,apmac,stamac,ssid) with apmac/stamac/band and
#     no `bssid`/`channel`/`time` column; channel is derived from freq.
#   * legacy schema: table `aps` with a text privacy column, colon'd bssid and a channel.
# `encryption` is libwifi's encryption_info uint64 bitmask; awk's doubles lose bits above 2^53, so it
# is split IN SQL into small ints. The live DB is held by the AP-service daemon (journal_mode `delete`, measured on the
# device: a -journal beside it while a write is in flight, no -wal/-shm); it is copied before querying (see recon_workcopy).
# libwifi encryption_info layout, PINNED to libwifi (github.com/libwifi/libwifi) commit c38dbc8d7d7836759300a9512d80a3d2d3e41a4b
# (2026-01-23, "Bump version to 0.0.11"), file src/libwifi/core/misc/security.h. uint64 bit -> meaning:
#   1 WEP · 2 WPA · 3 WPA2 · 4 WPA3 (class bits; libwifi ALSO sets bit 4 for OWE)
#   5..17  group cipher   : 5 WEP40 · 6 TKIP · 7 reserved · 8 CCMP128 · 9 WEP104 · 10 BIP-CMAC128 · 11 not-allowed · 12 GCMP128 · 13 GCMP256 ·
#                           14 CCMP256 · 15 BIP-GMAC128 · 16 BIP-GMAC256 · 17 BIP-CMAC256
#   18..31 pairwise cipher: 18 group · 19 WEP40 · 20 TKIP · 21 reserved · 22 CCMP128 · 23 WEP104 · 24 BIP-CMAC128 · 25 not-allowed · 26 GCMP128 ·
#                           27 GCMP256 · 28 CCMP256 · 29 BIP-GMAC128 · 30 BIP-GMAC256 · 31 BIP-CMAC256
#   32..53 AKM            : 32 reserved · 33 1X · 34 PSK · 35 1X-FT · 36 PSK-FT · 37 1X-SHA256 · (38 unused) · 39 PSK-SHA256 · 40 TDLS · 41 SAE ·
#                           42 SAE-FT · 43 AP-PEER · 44 1X-SuiteB-SHA256 · 45 1X-SuiteB-SHA384 · 46 1X-FT-SHA384 · 47 FILS-SHA256 · 48 FILS-SHA384 ·
#                           49 FILS-SHA256-FT · 50 FILS-SHA384-FT · 51 OWE · 52 PSK-SHA384-FT · 53 PSK-SHA384
#   54..58 auth scheme    : 54 OPEN · 55 SHARED-KEY · 56 FAST-BSS · 57 SAE · 58 VENDOR
# (Bit 38 is genuinely skipped in that header: PSK_SHA256 is bit 39.) The four SQL splits ENC_GRP/ENC_PW/ENC_AKM/ENC_AUTH shift and mask
# these ranges; the awk name tables index them from 0 within each range.
# One sqlite3 process per cycle. $1 = db path, stdin = the SQL (statements ended by `;`). A statement the firmware's schema cannot
# prepare (a column or table it lacks) prints its error on stderr (dropped here) and the NEXT statement still runs: without -bail the
# CLI carries on after an error, which is how the schema-family alternatives below can sit in one batch.
# RQ_BAIL=-bail (the security lookup of the pineap source) stops at the first error, so that a batch which ends in a marker row of its own
# proves that the statements before it ran.
# RQ_ERRF, when set (build_from_recondb), is a file of ours that receives the batch's stderr and, after it, one line "#starchorus-exit N" with sqlite3's exit
# status: a torn or damaged copy says so there ("database disk image is malformed", "disk I/O error", "file is not a database") and recondb_failed reads it.
# Empty (the pineap security lookup, which has its closing marker row for the purpose): stderr is dropped, as before. The status of the function is sqlite3's.
recondb_query() {
    # shellcheck disable=SC2086  # RQ_BAIL is one option or nothing
    sqlite3 -readonly -noheader $RQ_BAIL -separator "$RECON_TAB" "$1" 2>"${RQ_ERRF:-/dev/null}"
    rq_rc=$?
    if [ -n "$RQ_ERRF" ]; then printf '#starchorus-exit %s\n' "$rq_rc" >> "$RQ_ERRF" 2>/dev/null; fi
    return "$rq_rc"
}
# After a batch: 0 iff the file RQ_ERRF says the pass failed, and RQ_WHY is then the reason in a few words. Failed: sqlite3 named a damaged or unreadable database
# (malformed, disk I/O, not a database), or it ended by a signal or a crash (an exit status of 2 or more). NOT failed: an exit status of 1 on its own. The CLI
# gives 1 after ANY statement that did not prepare, and the schema-family alternatives of the batch fail on purpose ("no such table", "no such column"): a healthy
# database ends with 1 as a matter of course. A batch that found no access point at all stays "no data this cycle", as before.
recondb_failed() {
    RQ_WHY=""
    [ -n "$RQ_ERRF" ] && [ -s "$RQ_ERRF" ] || return 1
    # Read with builtins, no process (it was an awk): the same words as before, the last "#starchorus-exit N" line wins.
    rf_m=0; rf_d=0; rf_n=0; rf_x=0
    {
        while IFS= read -r rf_l || [ -n "$rf_l" ]; do
            case $rf_l in
                '#starchorus-exit '*)
                    rf_v=${rf_l#'#starchorus-exit '}
                    case $rf_v in
                        ''|*[!0-9]*) ;;
                        *) while [ "${#rf_v}" -gt 1 ] && [ "${rf_v#0}" != "$rf_v" ]; do rf_v=${rf_v#0}; done
                           if [ "${#rf_v}" -gt 6 ]; then rf_x=999999; else rf_x=$rf_v; fi ;;
                    esac ;;
            esac
            case $rf_l in *[Mm]alformed*) rf_m=1 ;; esac
            case $rf_l in *'disk I/O'*) rf_d=1 ;; esac
            case $rf_l in *'not a database'*) rf_n=1 ;; esac
        done < "$RQ_ERRF"
    } 2>/dev/null
    if [ "$rf_m" = 1 ]; then RQ_WHY="the copy is malformed"
    elif [ "$rf_d" = 1 ]; then RQ_WHY="disk I/O error"
    elif [ "$rf_n" = 1 ]; then RQ_WHY="the copy is not a database"
    elif [ "$rf_x" -ge 2 ] 2>/dev/null; then RQ_WHY="the database reader ended with status $rf_x"
    fi
    [ -n "$RQ_WHY" ]
}
# Add one alternative to the batch RQ: a marker row naming it, then the statement. The marker is `#STARCHORUS_<GROUP><n>#`; recondb_pick
# keeps, per GROUP, the first alternative that produced rows.
# Once the schema is known (RQ_STEADY=1, see build_from_recondb) the batch is the reduced one: HASTIME is not asked again; of a group with alternatives
# (APS, CLI, PRB, RESP) the one that won is issued under the marker the final awk reads (no recondb_pick pass); a group that has no winner yet (it
# gave no row so far: no station heard, no responder) keeps all its alternatives, numbered, in a tail (RQ_T) that sits at the START of the batch (behind the sections the shell
# reads, before the groups: see sq_section for why), between #STARCHORUS_TAIL# and #STARCHORUS_TAILEND#. A tail with no row in it, the usual state, is cut out and
# forgotten (rq_tail); one with a row means that the first non-empty alternative of a group may be another one now, and the pass is asked again as a first batch, which
# is the rule of recondb_pick. The other alternatives of a group WITH a winner stay in the tail as well, as questions of one row at most, so that the rule holds for them too:
# one that comes before the winner, "has it rows?" (it would win); one that comes after it, "has it rows while the winner has none?" (it would win then). A later one that
# reads the same rows by the same clauses as the winner (CLI1 behind CLI0: only the columns differ) has rows exactly when the winner has, and is left out. On the device's
# schema the others name a table or a column that is not there and fail when they are prepared, before anything is read; on a file where they are valid they cost a read each.
rq_add() {   # $1 = GROUP+n, $2 = the statement without its `;`
    if [ "$RQ_STEADY" = 1 ]; then
        case $1 in
            HASTIME) return 0 ;;
            APS[0-9]|CLI[0-9]|PRB[0-9]|RESP[0-9])
                rq_g=${1%[0-9]}
                case $RQ_WIN in
                    *" $1 "*)
                        case $rq_g in CLI) rq_f=CLIENTS; RQ_WCLI=$2 ;; PRB) rq_f=PROBES; RQ_WPRB=$2 ;; APS) rq_f=APS; RQ_WAPS=$2 ;; *) rq_f=$rq_g; RQ_WRESP=$2 ;; esac
                        RQ="$RQ
SELECT '#STARCHORUS_$rq_f#';
$2;"
                        return 0 ;;
                    *" $rq_g"[0-9]" "*)        # another alternative of the group won: asked in the tail whether it would win now
                        case $rq_g in CLI) rq_w=$RQ_WCLI ;; PRB) rq_w=$RQ_WPRB ;; APS) rq_w=$RQ_WAPS ;; *) rq_w=$RQ_WRESP ;; esac
                        if [ -z "$rq_w" ]; then rq_q="SELECT 1 WHERE EXISTS ($2)"      # before the winner
                        elif [ "${2#* FROM }" = "${rq_w#* FROM }" ]; then return 0      # behind it, with the winner's rows
                        else rq_q="SELECT 1 WHERE EXISTS ($2) AND NOT EXISTS ($rq_w)"; fi
                        RQ_T="$RQ_T
SELECT '#STARCHORUS_$1#';
$rq_q;"
                        RQ_TA="$RQ_TA$1 "
                        return 0 ;;
                esac
                RQ_T="$RQ_T
SELECT '#STARCHORUS_$1#';
$2;"
                RQ_TA="$RQ_TA$1 "
                return 0 ;;
        esac
    fi
    RQ="$RQ
SELECT '#STARCHORUS_$1#';
$2;"
}
# stdin = the batch output (control bytes already removed); stdout = per GROUP the rows of its first non-empty alternative, under the
# marker the final awk reads: APS -> #STARCHORUS_APS#, CLI -> CLIENTS, PRB -> PROBES, RESP, plus HOP, HASTIME, WMIN and SCHEMA for the shell. Streams: the
# first row of an alternative claims its group, rows of the other alternatives of that group are dropped. A marker is a whole line of its own;
# no row can start like one (the first column of every query is a MAC, a frequency or a number).
# With $1 = own the output ends with a section #STARCHORUS_OWN# whose one row names the alternative that won per group (APS1 CLI1 PRB1 ...): build_from_recondb
# keeps it, and asks only for those alternatives from the next cycle on.
recondb_pick() {
    awk -v own="$1" '
        BEGIN { OUT["APS"]="APS"; OUT["CLI"]="CLIENTS"; OUT["PRB"]="PROBES"; OUT["RESP"]="RESP"; OUT["HOP"]="HOP"; OUT["HASTIME"]="HASTIME"; OUT["WMIN"]="WMIN"; OUT["SCHEMA"]="SCHEMA" }
        $0 == "#STARCHORUS_RWOK#" { print; next }      # the marker row of the window table (a row of its own, nothing under it): passed on as it is
        /^#STARCHORUS_[A-Z]+[0-9]*#$/ { sec=substr($0, 13, length($0) - 13); grp=sec; sub(/[0-9]+$/, "", grp); next }
        /^[ \t]*$/ { next }
        grp == "" || !(grp in OUT) { next }
        { if (!(grp in owner)) { owner[grp]=sec; printf "#STARCHORUS_%s#\n", OUT[grp] }
          if (owner[grp] == sec) print }
        END { if (own == "own") { n = split("APS CLI PRB RESP", gl, " "); w = ""
                for (i = 1; i <= n; i++) if (gl[i] in owner) w = w (w == "" ? "" : " ") owner[gl[i]]
                if (w != "") printf "#STARCHORUS_OWN#\n%s\n", w } }'
}
# The rows of the section NAME of $RQ_SRC (the batch output as one text that starts and ends with a newline): the lines after the marker line
# #STARCHORUS_NAME# up to the next marker line. Sets RQ_SECT; returns 1 when the section is not there. Builtins only (parameter expansion).
# A marker is a whole line: no field of any row holds a line feed (the SQL turns them into spaces) or starts a line with #STARCHORUS_.
# $2 = end: the marker is the last one of the text (OWN, which recondb_pick writes behind everything), else it is near the start (SCHEMA, HASTIME, WMIN, HOP, APS: the batch asks for
# them first, ahead of the long groups). The shell finds a marker by trying the lengths of prefix one after the other, each try costing the length it tries, so a marker that is far from the
# end it is searched from takes the square of the distance (a 34 KB text: seconds in dash on a fast machine, more in BusyBox ash; the 2 MB of STARCHORUS_MAX_AGE=0: for ever): `#*` counts from the
# start, `##*` from the end. Whatever the shell reads therefore sits within a few hundred bytes of the start (HOP: a row per frequency), and OWN, read once on the first pass, at the end.
sq_section() {
    RQ_SECT=""; sq_m="$NL#STARCHORUS_$1#$NL"
    case $RQ_SRC in *"$sq_m"*) ;; *) return 1 ;; esac
    if [ "$2" = end ]; then sq_r=$NL${RQ_SRC##*"$sq_m"}; else sq_r=$NL${RQ_SRC#*"$sq_m"}; fi
    case $sq_r in
        *"$NL#STARCHORUS_"*) sq_r=${sq_r%%"$NL#STARCHORUS_"*} ;;
        *) sq_r=${sq_r%"$NL"} ;;
    esac
    RQ_SECT=${sq_r#"$NL"}
    return 0
}
# The tail of the reduced batch (the numbered alternatives of the groups that have no winner yet, see rq_add): cut out of $pick, behind the sections the shell reads and before the
# groups. Status 0: nothing in it (the usual state, a few marker lines) or no tail to look at; 1: a row came out of it, so the first non-empty alternative of a group may have
# changed and the pass has to be asked again as a first batch, which learns the winner by recondb_pick's rule (the first non-empty alternative). Every cut is a `%%` that begins with
# a literal (linear) or a `#*` over the start of the text (the sections before the tail, a few hundred bytes), never a search in the text of the groups: with STARCHORUS_MAX_AGE=0 that
# text is 2 MB. The row test comes before the one `#*` that reaches past the tail: a tail WITH rows (a thousand stations heard at once while CLI has no winner) returns at once.
rq_tail() {
    [ -n "$RQ_TA" ] || return 0
    sq_t=${pick%%"$NL#STARCHORUS_TAILEND#"*}
    [ "$sq_t" != "$pick" ] || return 0      # (the pass ended before the tail's end: nothing to take)
    case $sq_t in *"#STARCHORUS_TAIL#"*) ;; *) return 0 ;; esac
    sq_h=${sq_t%%"#STARCHORUS_TAIL#"*}; sq_h=${sq_h%"$NL"}
    sq_t=${sq_t#*"#STARCHORUS_TAIL#"}
    case $sq_t in *"$NL"[!#]*) return 1 ;; esac      # a row: tested BEFORE the cut below, which counts from the start and would cost the square of the tail's rows
    pick="$sq_h${pick#*"$NL#STARCHORUS_TAILEND#"}"
    return 0
}

# recon.db is found once and remembered (the bounded `find` for a non-standard place is not repeated every cycle). Sets RDB_PATH.
recon_db_path() {
    if [ -n "$RDB_PATH" ] && [ "$RDB_KEY" = "$RECON_DB" ] && [ -r "$RDB_PATH" ]; then return 0; fi
    RDB_PATH=$(find_recon_db) || { RDB_PATH=""; return 1; }
    RDB_KEY=$RECON_DB; HAS_TIME=""; RQ_WIN=""; RDB_SCH=""; RW_OFF=0; RR_OK=""      # another file: its schema is learnt afresh, and the room for its copy is looked at again
}

# Size and modification time of files WITHOUT reading them: one `ls -lnL --full-time` (BusyBox and GNU; the device has no `stat`). The line carries
# both, down to the nanosecond where the system keeps one, which is all a fingerprint needs. `wc -c` on the 3.5 MB recon.db costs 0.6 s of the
# device's CPU, a cycle's worth in a quarter of the time. Sets FL = the lines of the files that exist, "" where `ls` cannot (BSD/macOS: no --full-time).
file_ls() {   # $@ = files
    FL=$(ls -lnL --full-time "$@" 2>/dev/null)
    case $FL in -*) ;; *) FL="" ;; esac
}
# Size of a file in bytes, by file_ls, else `wc -c`. Sets FSZ ("" = unknown).
file_size() {   # $1 = file
    file_ls "$1"; FSZ=""
    # shellcheck disable=SC2086  # the word splitting is the point (globbing off: the name is the last word)
    if [ -n "$FL" ]; then set -f; set -- $FL; set +f; FSZ=$5
    else FSZ=$({ wc -c < "$1"; } 2>/dev/null | tr -d ' '); fi   # braces: the shell's own "cannot open" too
    case $FSZ in ''|*[!0-9]*) FSZ="" ;; esac
}

# The stamp of recon.db: what recon_sample takes before the copy and recon_copy_settle takes again after it.
recon_stamp() {   # $1 = recon.db. Sets ST_RAW (the stamp: one line each for the file and a -journal / -wal beside it, "" = unknown) and ST_LS (1 = the `ls` form)
    st_db=$1
    file_ls "$st_db" "$st_db-journal" "$st_db-wal"
    st_f=$FL; ST_LS=1
    if [ -z "$st_f" ]; then
        ST_LS=0
        st_f=$(stat -L -c '%s %Y %n' "$st_db" "$st_db-journal" "$st_db-wal" 2>/dev/null)
        [ -n "$st_f" ] || st_f=$(stat -L -f '%z %m %N' "$st_db" "$st_db-journal" "$st_db-wal" 2>/dev/null)
        if [ -z "$st_f" ]; then
            for st_x in "$st_db" "$st_db-journal" "$st_db-wal"; do
                [ -e "$st_x" ] || continue
                st_f="$st_f${st_f:+$NL}$(wc -c < "$st_x" 2>/dev/null | tr -d ' ') $(file_mtime "$st_x") $st_x"
            done
        fi
    fi
    ST_RAW=$st_f
}
# What recon.db looks like now: size and modification time of the file and of a -journal / -wal beside it, one line each. The device's journal_mode is
# `delete`: a -journal beside the database means a write is in flight. Taken ONCE per cycle (run_cycle; build_from_recondb takes it itself when the
# pineap source falls back to it), BEFORE the copy, so that any later write shows in the next sample. The copy looks at the same files once more when it is
# done (recon_stamp, recon_copy_settle): that look is not a sample, it decides only whether the copy is made again. Two samples are equal iff size and mtime of all
# three files are. Sets RS_RAW (the sample, "" = unknown), RS_SZ (size of recon.db, for the copy's room test) and RS_NEW (RS_RAW if the next cycle
# may skip on it: not with a -journal there, and not when the file changed less than 2 s ago, as the next write inside the same mtime second
# would go unseen). Fallbacks where `ls` has no --full-time: stat (GNU, BSD), then wc + date.
recon_sample() {   # $1 = now (Unix seconds)
    rs_now=$1; RS_RAW=""; RS_SZ=0; RS_NEW=""
    recon_db_path || return 1
    rs_db=$RDB_PATH
    recon_stamp "$rs_db"
    rs_f=$ST_RAW
    if [ "$ST_LS" = 0 ]; then
        rs_l=${rs_f%%"$NL"*}; RS_SZ=${rs_l%% *}
    else
        rs_l=${rs_f%%"$NL"*}; set -f
        # shellcheck disable=SC2086  # as in file_size
        set -- $rs_l; set +f; RS_SZ=$5
    fi
    case $rs_l in *" $rs_db") ;; *) return 1 ;; esac      # the database's own line comes first (a sample without it is no sample)
    case $RS_SZ in ''|*[!0-9]*) RS_SZ=0; return 1 ;; esac
    RS_RAW=$rs_f; RS_NEW=$rs_f
    case $RS_NEW in *"$rs_db-journal"|*"$rs_db-journal$NL"*) RS_NEW="" ;; esac
    if [ -n "$RS_NEW" ]; then
        rs_m=$(date -r "$rs_db" +%s 2>/dev/null)
        case $rs_m in ''|*[!0-9]*) rs_m=$(file_mtime "$rs_db") ;; esac
        case $rs_m in ''|*[!0-9]*) RS_NEW="" ;; *) { [ "${rs_now:-0}" -gt 0 ] 2>/dev/null && [ $((rs_now - rs_m)) -ge 2 ]; } || RS_NEW="" ;; esac
    fi
    return 0
}

# Is there room in directory $1 for a copy of $2 bytes? Needs the copy, half as much again for the temporary files sqlite makes for
# GROUP BY, and 2 MB over. Unknown (no df, odd output) counts as yes: the cp itself is then the test.
# `df` is a process and a sub-shell, and the need follows only the size of the database, so a yes is kept: it stands for the next 19 cycles of the same directory
# and size class (the need in whole MiB), and is asked again at once when the directory or the class changes, after a no (so that the return to RAM is not
# delayed), when the database file changes (recon_db_path) and after a RAM copy that failed (recon_workcopy). A yes that has gone stale costs one cp that
# fails on a full tmpfs, which recon_workcopy answers with the flash copy and removes the cut one: the pre-check only spares the tmpfs the attempt.
ram_room() {
    rr_need=$(( ($2 + 1023) / 1024 ))
    rr_need=$(( rr_need + rr_need / 2 + 2048 ))
    rr_cls=$(( rr_need / 1024 ))
    if [ "$RR_OK" = 1 ] && [ "$RR_DIR" = "$1" ] && [ "$RR_CLS" = "$rr_cls" ] && [ "$RR_N" -lt 19 ]; then RR_N=$((RR_N + 1)); return 0; fi
    RR_OK=""; RR_N=0; RR_DIR=$1; RR_CLS=$rr_cls
    rr_av=$(df -Pk "$1" 2>/dev/null | { read -r _; read -r _ _ _ rr_a _; printf '%s' "$rr_a"; })
    case $rr_av in ''|*[!0-9]*) return 0 ;; esac
    [ "$rr_av" -ge "$rr_need" ] || return 1
    RR_OK=1
}

# Copy-before-query: never lock the live DB the recon engine writes to (its journal_mode is `delete`, so a long read would hold a
# SHARED lock that stalls the engine's commits). The copy goes to RAM ($TMPDIR_RAM: /tmp is tmpfs on the device; CAPDIR is eMMC and a
# 3.5 MB write every cycle is flash wear and IO wait), named for this process so a crond `--once` and the loop never share one. No room
# there, or the copy failed: the flash fallback, CAPDIR; and when that fails too, the live file, read-only. The -journal is NOT copied: a hot
# journal beside a read-only copy cannot be rolled back, and the sig test keeps a half-written moment out of the skip logic.
# A plain `cp` of a file that is being written can hold old and new pages together (a torn copy: the engine rewrites pages in place while it commits, and
# a read of the copy then finds an index that does not match its table, or no database at all). The stamp taken before the copy (recon_sample's RS_RAW) is taken
# once more when the copy is done, with the same single `ls`: size, modification time and the presence of a -journal / -wal; if anything differs, a write ran
# alongside the copy, and the copy is made once more (recon_copy_settle). The copy stays a plain read-only copy of the file: nothing is locked or written on it.
# $1 = recon.db, $2 = its size in bytes, $3 = the stamp from before the copy (RS_RAW; empty = none to compare with). Sets QDB (what to query) and QDB_RAM
# (1 = recon_workdone removes it).
recon_workcopy() {
    QDB_RAM=0; QDB=$1
    cw_sz=${2:-0}; case $cw_sz in *[!0-9]*) cw_sz=0 ;; esac
    cw_dst="$TMPDIR_RAM/starchorus-recon-$$.db"
    if [ -d "$TMPDIR_RAM" ] && [ -w "$TMPDIR_RAM" ] && ram_room "$TMPDIR_RAM" "$cw_sz" && recon_copy_to "$1" "$cw_dst" && recon_copy_settle "$1" "$cw_dst" "$3"; then
        QDB=$cw_dst; QDB_RAM=1
        # a flash copy under CAPDIR is stale once the RAM copy is in use: remove it (3.5 MB of eMMC), once: a cycle that may have made one (FLASH_COPY)
        # asks, and so does one that finds a copy another collector left (the test is a builtin, no process; the rm runs only when there is one)
        if [ "$FLASH_COPY" = 1 ] || [ -e "$CAPDIR/recon_copy.db" ]; then
            rm -f "$CAPDIR/recon_copy.db" "$CAPDIR/recon_copy.db-wal" "$CAPDIR/recon_copy.db-shm" 2>/dev/null
            FLASH_COPY=0
        fi
        return 0
    fi
    rm -f "$cw_dst" "$cw_dst-wal" "$cw_dst-shm" 2>/dev/null     # a copy cut short by a full tmpfs
    RR_OK=""; FLASH_COPY=1      # the room is looked at again next cycle; a copy under CAPDIR may be made now
    mkdir -p "$CAPDIR" 2>/dev/null
    if recon_copy_to "$1" "$CAPDIR/recon_copy.db" && recon_copy_settle "$1" "$CAPDIR/recon_copy.db" "$3"; then
        QDB="$CAPDIR/recon_copy.db"
    else   # QDB stays the live file
        rm -f "$CAPDIR/recon_copy.db" "$CAPDIR/recon_copy.db-wal" "$CAPDIR/recon_copy.db-shm" 2>/dev/null
    fi
}
# $1 = recon.db, $2 = the file to make: the copy of it and of a -wal / -shm beside it, if they are there. 0 iff the database itself was copied.
recon_copy_to() {
    cp "$1" "$2" 2>/dev/null || return 1
    if [ -r "$1-wal" ]; then cp "$1-wal" "$2-wal" 2>/dev/null; fi
    if [ -r "$1-shm" ]; then cp "$1-shm" "$2-shm" 2>/dev/null; fi
    return 0
}
# $1 = recon.db, $2 = its copy, $3 = the stamp from before the copy. 0 = the copy stands (stable, or the best that could be had); 1 = the second copy failed
# (the caller drops the copy). The stamp is taken again; unchanged = no write ran alongside the copy and nothing more is done (one `ls`). Changed: after 0.2 s
# the file is copied once more against a stamp of its own (before and after that copy). Still moving: the second copy is read all the same and the episode is
# said once by run_cycle (a busy night: the next cycle's own sample then differs from this one's, so a copy of a moving file never lets a later cycle skip).
recon_copy_settle() {
    [ -n "$3" ] || return 0
    recon_stamp "$1"
    [ "$ST_RAW" != "$3" ] || return 0
    sleep 0.2 2>/dev/null || sleep 1
    recon_stamp "$1"; cs_b=$ST_RAW
    rm -f "$2-wal" "$2-shm" 2>/dev/null   # a -wal / -shm of the first copy must not stay beside the second one if the source has lost its own
    recon_copy_to "$1" "$2" || return 1
    recon_stamp "$1"
    [ -n "$cs_b" ] && [ "$ST_RAW" = "$cs_b" ] && return 0
    RQ_TORN=1   # run_cycle says so (this runs inside the builder, whose stderr is dropped)
    return 0
}
recon_workdone() {   # the RAM copy is not needed between cycles: free it (and the file of the batch's errors), with one rm
    if [ "$QDB_RAM" = 1 ] && [ -n "$RQ_ERRF" ]; then rm -f "$QDB" "$QDB-wal" "$QDB-shm" "$RQ_ERRF" 2>/dev/null
    elif [ "$QDB_RAM" = 1 ]; then rm -f "$QDB" "$QDB-wal" "$QDB-shm" 2>/dev/null
    elif [ -n "$RQ_ERRF" ]; then rm -f "$RQ_ERRF" 2>/dev/null; fi
    QDB_RAM=0; RQ_ERRF=""
}
# The RAM copies of recon.db (rule: see sweep_stale_cache_files), and the files of a Bluetooth window or a RECON CHANNELS call of a collector that is
# gone (starchorus-bt-<pid>.*, starchorus-traffic-<pid>.json; the .pid files are bt_sweep's: they say which tool to stop, and go with it).
sweep_stale_workcopies() {
    for f in "$TMPDIR_RAM"/starchorus-recon-*.db "$TMPDIR_RAM"/starchorus-recon-*.db-wal "$TMPDIR_RAM"/starchorus-recon-*.db-shm "$TMPDIR_RAM"/starchorus-recon-*.db-err; do
        [ -e "$f" ] || continue
        p=${f##*/starchorus-recon-}; p=${p%%.*}
        holder_alive "$p" || rm -f "$f" 2>/dev/null
    done
    for f in "$TMPDIR_RAM"/starchorus-bt-* "$TMPDIR_RAM"/starchorus-traffic-*; do
        [ -e "$f" ] || continue
        case $f in *.pid) continue ;; esac
        p=${f##*/starchorus-bt-}; p=${p##*/starchorus-traffic-}; p=${p%%.*}
        case $p in ''|*[!0-9]*) continue ;; esac
        holder_alive "$p" || rm -f "$f" 2>/dev/null
    done
}

# ---- encryption_info -> security label, akm / cipher / auth fields. One awk library for every source that has the bitmask
# (the recon.db path and the pineap path's security lookup). Needs AWK_JSON_HELPERS; call sec_init() in BEGIN.
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_SEC='
        # encryption -> security label. Numeric = the class mask recon_enc_sql builds.
        # Text = libwifi string ("WPA2", "WPA3", "OWE", ...) or legacy enum.
        function sec_of(e,   p,u){
            if(e ~ /^[0-9]+$/){
                e=e+0
                if(e==0) return "Open"
                p=""
                if(int(e/16)%2==1) p="WPA3"
                if(int(e/8)%2==1)  p=p (p?"/":"") "WPA2"
                if(int(e/4)%2==1)  p=p (p?"/":"") "WPA"
                if(int(e/2)%2==1)  p=p (p?"/":"") "WEP"
                return (p!="" ? p : "WPA2")
            }
            u=toupper(e)
            if(u=="" || u=="OPN" || u=="OPEN" || u=="[OPEN]" || u=="NONE") return "Open"
            if(u ~ /WPA3|SAE/){ return (u ~ /WPA2/) ? "WPA2/WPA3" : "WPA3" }
            if(u ~ /OWE/)  return "OWE"
            if(u ~ /WPA2/) return "WPA2"
            if(u ~ /WPA/)  return "WPA"
            if(u ~ /WEP/)  return "WEP"
            return e }
        # libwifi bit tables (see the comment above build_from_recondb). A value is one of the small SQL-split ints, or empty (a text encryption):
        # sec_of2() makes them numbers (0 for empty); names() and first() take the raw column and walk its bits only up to the highest one that is
        # set, which for a usual network is a handful of steps, not the whole table.
        function names(v,tbl,n,   i,o,b){ o=""
            if(v !~ /^[0-9]+$/) return ""
            v=v+0
            for(i=1;v>0 && i<=n;i++){ b=v%2; v=(v-b)/2
                if(b && tbl[i]!="-" && tbl[i]!="reserved") o=o (o!=""?", ":"") "\"" tbl[i] "\"" }
            return o }
        function first(v,tbl,n,   i,b){
            if(v !~ /^[0-9]+$/) return ""
            v=v+0
            for(i=1;v>0 && i<=n;i++){ b=v%2; v=(v-b)/2; if(b && tbl[i]!="-" && tbl[i]!="reserved") return tbl[i] }
            return "" }
        # security label from the class bits PLUS the AKM/cipher/auth detail. OWE first: libwifi sets the WPA3 class bit for OWE, so the
        # class alone calls an OWE network "WPA3". 802.1X AKMs -> "...-Enterprise". TKIP as the only pairwise cipher (or, without a
        # pairwise field, as the only group cipher) marks the label "(TKIP)". No AKM/auth field (text encryption) -> the class label.
        # The AKM bits: owe 19; sae 9, 10 (and auth scheme bit 3); psk 2, 4, 7, 20, 21; 802.1X 1, 3, 5, 12-18 (12 and 13 are the WPA3 ones).
        # TKIP is bit 2 of the pairwise ints (bit 1 of the group int); the AEAD ciphers are pairwise bits 4, 8, 9, 10 (group 3, 7, 8, 9).
        function sec_of2(e,grp,pw,akm,auth,   base,owe,sae,psk,ent,ent3,i,b,x,tk,aead){
            base=sec_of(e)
            if(akm !~ /^[0-9]+$/ && auth !~ /^[0-9]+$/) return base
            akm=(akm ~ /^[0-9]+$/) ? akm+0 : 0; auth=(auth ~ /^[0-9]+$/) ? auth+0 : 0; grp=(grp ~ /^[0-9]+$/) ? grp+0 : 0; pw=(pw ~ /^[0-9]+$/) ? pw+0 : 0
            owe=0; sae=int(auth/8)%2; psk=0; ent=0; ent3=0
            x=akm
            for(i=0;x>0;i++){ b=x%2; x=(x-b)/2
                if(!b) continue
                if(i==19) owe=1
                else if(i==9 || i==10) sae=1
                else if(i==2 || i==4 || i==7 || i==20 || i==21) psk=1
                else if(i==1 || i==3 || i==5 || (i>=12 && i<=18)){ ent=1; if(i==12 || i==13) ent3=1 } }
            if(owe && !psk && !sae && !ent) return "OWE"
            if(ent){ if(ent3 || sae) return "WPA3-Enterprise"; if(base=="WPA") return "WPA-Enterprise"; return "WPA2-Enterprise" }
            if(pw>0){ tk=int(pw/4)%2; aead=(int(pw/16)%2 || int(pw/256)%2 || int(pw/512)%2 || int(pw/1024)%2) }
            else { tk=int(grp/2)%2; aead=(int(grp/8)%2 || int(grp/128)%2 || int(grp/256)%2 || int(grp/512)%2) }
            if(tk && !aead && base ~ /WPA/) return base " (TKIP)"
            return base }
        function sec_init(){
            split("reserved 1x psk 1x-ft psk-ft 1x-sha256 - psk-sha256 tdls sae sae-ft ap-peer 1x-suiteb-sha256 1x-suiteb-sha384 1x-ft-sha384 fils-sha256 fils-sha384 fils-sha256-ft fils-sha384-ft owe psk-sha384-ft psk-sha384", AKMN, " ")
            split("wep40 tkip reserved ccmp128 wep104 bip-cmac128 notallowed gcmp128 gcmp256 ccmp256 bip-gmac128 bip-gmac256 bip-cmac256", CGN, " ")
            split("group wep40 tkip reserved ccmp128 wep104 bip-cmac128 notallowed gcmp128 gcmp256 ccmp256 bip-gmac128 bip-gmac256 bip-cmac256", CPN, " ")
            split("open shared-key fast-bss sae vendor", AUTHN, " ") }
        # the optional AP fields (", \"akm\": [...]", ", \"cipher\": {...}", ", \"auth\": [...]") from the four SQL-split ints
        function sec_extra(egrp,epw,eakm,eauth,   sx,t1,t2,t3,cg,cj){
            sx=""; t1=names(eakm,AKMN,22); t2=names(eauth,AUTHN,5); cg=first(egrp,CGN,13); t3=names(epw,CPN,14)
            if(t1!="") sx=sx ", \"akm\": [" t1 "]"
            if(cg!="" || t3!=""){
                cj=""
                if(cg!="") cj="\"group\": \"" cg "\""
                if(t3!="") cj=cj (cj!=""?", ":"") "\"pairwise\": [" t3 "]"
                sx=sx ", \"cipher\": {" cj "}" }
            if(t2!="") sx=sx ", \"auth\": [" t2 "]"
            return sx }
        # exact bits of a decimal integer string (no float): b[0]=LSB.. ; returns the bit count. Dodges awk rounding the raw uint64 away at 2^53.
        function decbit(s,b,   i,n,r,c,q,o,nb){
            nb=0; sub(/^0+/,"",s); if(s=="") s="0"
            while(s!="0"){
                r=0; o=""; n=length(s)
                for(i=1;i<=n;i++){ c=substr(s,i,1)+0; q=int((r*10+c)/2); r=(r*10+c)%2; o=o q }
                b[nb]=r; nb++
                sub(/^0+/,"",o); if(o=="") o="0"; s=o }
            return nb }
        # the pieces recon_enc_sql makes, but from the decimal string: ef["enc"] class mask (WEP 2/WPA 4/WPA2 8/WPA3 16, SAE bit 57 counts as WPA3), ef["grp"]/["pw"]/["akm"]/["auth"] each < 2^22 (exact in awk)
        function encfields(s,ef,   b,i,g,p,a,u){
            decbit(s,b)
            ef["enc"]=(b[1]?2:0)+(b[2]?4:0)+(b[3]?8:0)+((b[4]||b[57])?16:0)
            g=0; for(i=5;i<=17;i++) if(b[i]) g+=2^(i-5)
            p=0; for(i=18;i<=31;i++) if(b[i]) p+=2^(i-18)
            a=0; for(i=32;i<=53;i++) if(b[i]) a+=2^(i-32)
            u=0; for(i=54;i<=58;i++) if(b[i]) u+=2^(i-54)
            ef["grp"]=g; ef["pw"]=p; ef["akm"]=a; ef["auth"]=u }
'

# The SQL that turns the libwifi bitmask into the pieces the awk library reads (sets ENC, ENC_GRP, ENC_PW, ENC_AKM, ENC_AUTH, ENC5).
recon_enc_sql() {
    # Class bits -> small mask (WEP 2 / WPA 4 / WPA2 8 / WPA3 16; the SAE auth bit 57 counts as WPA3).
    # Text encryption values pass straight through.
    ENC="CASE WHEN typeof(encryption)='integer' THEN ((encryption & 30) | (CASE WHEN ((encryption>>57)&1)=1 THEN 16 ELSE 0 END)) ELSE encryption END"
    # The rest as four small non-negative ints (each < 2^22, exact in awk): group cipher bits 5..17, pairwise
    # 18..31, AKM 32..53, auth scheme 54..58 (table above). Text encryption values give '' and keep the class label.
    ENC_GRP="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>5)&8191) ELSE '' END"
    ENC_PW="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>18)&16383) ELSE '' END"
    ENC_AKM="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>32)&4194303) ELSE '' END"
    ENC_AUTH="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>54)&31) ELSE '' END"
    ENC5="($ENC_GRP), ($ENC_PW), ($ENC_AKM), ($ENC_AUTH)"
}

# awk body of the recon.db document: stdin = recondb_pick output or the reduced batch's output (APS, CLIENTS, PROBES, RESP sections), SC_CH = the channels[] text or "". Needs
# AWK_JSON_HELPERS and AWK_SEC prepended.
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_RECONDB='
        BEGIN{ FS=FSU; mode=""; nap=0; nun=0; sec_init()
            MK["#STARCHORUS_APS#"]="ap"; MK["#STARCHORUS_CLIENTS#"]="cli"; MK["#STARCHORUS_PROBES#"]="prb"; MK["#STARCHORUS_RESP#"]="resp"
            MK["#STARCHORUS_HOP#"]="skip"; MK["#STARCHORUS_HASTIME#"]="skip"; MK["#STARCHORUS_WMIN#"]="skip"; MK["#STARCHORUS_OWN#"]="skip"
            MK["#STARCHORUS_SCHEMA#"]="skip"; MK["#STARCHORUS_RWOK#"]="skip"; MK["#STARCHORUS_TAIL#"]="skip"; MK["#STARCHORUS_TAILEND#"]="skip" }      # skip: rows the shell read itself (sq_section)
        ($0 in MK)          { mode=MK[$0]; next }
        /^[ \t]*$/          { next }
        mode=="prb" {
            if($1!=pk){ pk=$1; pm=macfmt(pk) }      # the rows come sorted by station: one macfmt per station, not per row
            m=pm; ss=$2
            if(pk=="" || ss=="" || pn[m]>=8 || (m SUBSEP ss) in pseen) next
            pseen[m SUBSEP ss]=1; pn[m]++
            pr[m]=pr[m] (pr[m]!=""?", ":"") "\"" jesc(ss) "\""
            next
        }
        mode=="resp" { rm=macfmt($1); if(rm!="" && $2 ~ /^[0-9]+$/ && $2+0>1) rc[rm]=$2+0; next }
        mode=="ap" {
            mac=$1; ssid=$2; fr=$3; bnd=$4; ch=$5; sig=$6; enc=$7; hid=$8; last=$9; egrp=$10; epw=$11; eakm=$12; eauth=$13
            if(mac=="") next
            f=(fr ~ /^[0-9]+$/ && fr+0>0) ? fr+0 : ""
            if(f=="" && ch ~ /^[0-9]+$/ && ch+0>0) f=freq_from_ch(ch+0)
            b=(f!="")? band_from_freq(f) : ""
            if(b=="") b=band_norm(bnd)
            if(b=="" && ch ~ /^[0-9]+$/) b=band_from_ch(ch+0)
            c=(ch ~ /^[0-9]+$/ && ch+0>0) ? ch+0 : (f!="" ? ch_from_freq(f) : "")
            if(hid+0==1) ssid=""    # hidden network -> empty SSID (front-end convention)
            ap_mac[nap]=macfmt(mac); ap_ssid[nap]=ssid; ap_ch[nap]=c
            ap_band[nap]=b; ap_freq[nap]=f; ap_sig[nap]=sig; ap_sec[nap]=sec_of2(enc,egrp,epw,eakm,eauth)
            ap_sx[nap]=sec_extra(egrp,epw,eakm,eauth)
            ap_last[nap]=(last ~ /^[0-9]+$/ && last+0>0) ? last+0 : ""
            nap++
        }
        mode=="cli" {
            mac=$1; sig=$2; last=$3
            if(mac=="") next
            un_mac[nun]=macfmt(mac); un_sig[nun]=sig
            un_last[nun]=(last ~ /^[0-9]+$/ && last+0>0) ? last+0 : ""
            pkt=$4; if(pkt ~ /^[0-9]+$/){ sub(/^0+/,"",pkt); if(pkt=="") pkt="0" } else pkt=""     # the frame counter (STARCHORUS_TRAFFIC=1, CLI0), digits only
            un_pk[nun]=pkt
            nun++
        }
        END{
            doc_head()
            if(ENVIRON["SC_CH"]!="") printf "  \"channels\": %s,\n", ENVIRON["SC_CH"]
            printf "  \"aps\": [\n"
            for(i=0;i<nap;i++){
                extra=(ap_last[i]!="") ? ", \"last_seen\": " ap_last[i] : ""
                extra=extra ap_sx[i]
                if(ap_mac[i] in rc) extra=extra ", \"responded_ssids\": " rc[ap_mac[i]]
                printf "%s%s\n", ap_json(jesc(ap_mac[i]), jesc(ap_ssid[i]), (ap_ch[i]!=""?numval(ap_ch[i]""):"null"), jesc(ap_band[i]),
                    (ap_freq[i]!="" && ap_freq[i]>0?ap_freq[i]:"null"), numval(ap_sig[i]), jesc(ap_sec[i]), extra, ""), (i<nap-1?",":"")
            }
            printf "  ],\n  \"unassociated\": [\n"
            for(i=0;i<nun;i++){
                extra=(un_last[i]!="") ? ", \"last_seen\": " un_last[i] : ""
                if(un_pk[i]!="") extra=extra ", \"packets\": " un_pk[i]
                if(un_mac[i] in pr) extra=extra ", \"probes\": [" pr[un_mac[i]] "]"
                printf "%s%s\n", cl_json(jesc(un_mac[i]), numval(un_sig[i]), extra), (i<nun-1?",":"")
            }
            printf "  ]\n}\n"
        }
'

build_from_recondb() {
    recon_db_path || return 1
    db=$RDB_PATH
    have sqlite3 || return 1

    # The sample (RS_RAW / RS_NEW / RS_SZ): see recon_sample (RS_TAKEN: run_cycle has already taken it, else it is taken here).
    if [ "$RS_TAKEN" = 1 ]; then RS_TAKEN=0; else recon_sample "$1"; fi

    recon_workcopy "$db" "$RS_SZ" "$RS_RAW"
    qdb=$QDB
    # the batch's stderr and exit status go to a file of ours beside the copy (none when the RAM directory cannot take it: then they are dropped, as before)
    RQ_ERRF="$TMPDIR_RAM/starchorus-recon-$$.db-err"
    { printf '' > "$RQ_ERRF"; } 2>/dev/null || RQ_ERRF=""

    recon_enc_sql
    # SSID as text with any tab/newline replaced by a space, so no SSID can break the TAB field split.
    SSD="replace(replace(CAST(ssid AS TEXT),char(9),' '),char(10),' ')"

    # Live-presence window (opt-in): with STARCHORUS_MAX_AGE>0 only observations from the last N seconds
    # count, so devices that have left drop off the map. `time` is Unix seconds; the cutoff comes from
    # the LOCAL clock (same UTC epoch as the recon engine's). AGE = predicate for single-table `ssid`
    # queries, AGE_S = the same for the wifi_device JOIN (where a bare `time` is ambiguous). Empty (no
    # filter) when the window is off or unusable.
    AGE=""; AGE_S=""
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null; then
        now=$CYC_NOW; case $now in ''|*[!0-9]*|0) now=$(date +%s 2>/dev/null) ;; esac      # run_cycle's clock where it ran this (no process), else the clock
        if [ -n "$now" ] && [ "$now" -gt "$MAX_AGE" ] 2>/dev/null; then
            cut=$((now - MAX_AGE))
            AGE="AND time > $cut"
            AGE_S="AND s.time > $cut"
        fi
    fi

    # --- access points. 13 tab-separated cols: mac, ssid, freq, band, channel, signal, encryption,
    # hidden, last_seen ('' if unknown), then the four ENC5 splits. last_seen = MAX(time) per BSSID.
    # CAUTION (verified with sqlite3): the ssid/encryption/hidden/freq values are SQLite "bare columns"
    # and come from the MAX(signal) row ONLY while the query has exactly ONE aggregate. A second
    # MAX(time) in the same SELECT makes them arbitrary, so MAX(time) lives in a derived table joined on
    # bssid; the plain query (no `time` column) is the next fallback.
    # the legacy `aps` table differs across builds (signal vs rssi, encryption vs privacy); try each combo.
    APSSD="replace(replace(ssid,char(9),' '),char(10),' ')"
    # Everything below goes into ONE batch (RQ) for ONE sqlite3 process; recondb_pick keeps the first non-empty alternative per group. On a
    # firmware whose ssid table has a `time` column (HAS_TIME=1, learned from the first batch) the no-`time` alternatives are left out: they
    # would run the same scan a second time.
    # The first batch (HAS_TIME not known) asks everything, in the order below, and learns three things: HAS_TIME, the alternative that won per group (RQ_WIN,
    # from recondb_pick) and, below, whether the window can be cut out once. From the second cycle on the batch is the reduced one (rq_add): HASTIME is not asked,
    # a group with a winner asks that alternative under the final marker, and no recondb_pick pass runs. A group that has no winner yet keeps all its alternatives, and the other
    # alternatives of a group with a winner are asked whether they would win now (rq_add, rq_tail: in a tail at the start of the batch; a row there asks the pass again as a first batch). The winners are dropped with HAS_TIME: another file (recon_db_path), a failed pass, a pass that found no access point (the schema may have changed).
    RQ="PRAGMA mmap_size=134217728;"      # (its one output row, before the first marker, is dropped by recondb_pick and ignored by the final awk, which has no section yet; no mmap support: nothing happens)
    RQ_T=""; RQ_TA=""; RQ_H=""; RQ_STEADY=0; RW_USED=0; SST=ssid; RQ_WAPS=""; RQ_WCLI=""; RQ_WPRB=""; RQ_WRESP=""
    case $RQ_WIN in *" APS"[0-9]" "*) [ -z "$HAS_TIME" ] || [ "$RQ_WINT" != "$TRAFFIC" ] || RQ_STEADY=1 ;; esac
    [ -n "$HAS_TIME" ] || RQ_WIN=""
    # The window, cut out ONCE: with a window and a `time` column every group below reads the rows of the window (type 4, 5 and 8, about a thousand of the 22,000 on
    # the device) from a temporary table instead of scanning ssid (no index on `time`) six times. The table lives in the connection's temporary store, not in the
    # file: the copy stays a read-only copy (sqlite3 -readonly). The rows are copied in the order the scan meets them, which is what the groups' bare columns
    # (beside MAX(signal)) are decided by. The first batch, a schema without `time` and STARCHORUS_MAX_AGE=0 keep the statements on ssid. HOP stays on ssid (it asks for the
    # history of a frequency, with no window).
    # The table is judged by its own CREATE: the row that follows it (#STARCHORUS_RWOK#, written only where the table is in the connection's temporary schema) is
    # there or it is not; no other error of the pass says anything about it (a tail alternative that fails prints the statement it ran, rwin and all). Refused: RW_OFF
    # passes without it, and this pass is asked again at once on ssid (below).
    if [ "$HAS_TIME" = 1 ] && [ -n "$AGE" ]; then
        if [ "$RW_OFF" -gt 0 ] 2>/dev/null; then RW_OFF=$((RW_OFF - 1))
        else
            SST=rwin; RW_USED=1
            RQ="$RQ
PRAGMA temp_store=MEMORY;
CREATE TEMP TABLE rwin AS SELECT * FROM ssid WHERE time > $cut AND type IN (4,5,8);
SELECT '#STARCHORUS_RWOK#' FROM sqlite_temp_master WHERE name='rwin';"
        fi
    fi
    # The shape of the tables this batch reads, in every pass: the winners are valid for the shape they were learnt under (RDB_SCH); a pass that sees another one asks again, as a first batch.
    rq_add SCHEMA "SELECT group_concat(s, ' ; ') FROM (SELECT replace(replace(replace(sql,char(10),' '),char(13),' '),char(9),' ') AS s FROM sqlite_master WHERE name IN ('ssid','wifi_device','aps') ORDER BY name)"
    rq_add HASTIME "SELECT COUNT(*) FROM pragma_table_info('ssid') WHERE name='time'"
    # --- the oldest row the window counts (STARCHORUS_MAX_AGE): the clock of the skip test. Rows leave the window one at a time, long before the
    # entry they belong to does (an AP's strong old beacon, a station's old probe), and the document changes when they do. Nothing to ask without a
    # window, and none where `time` does not exist (the statement then fails and the skip test never skips). It comes FIRST, so that the shell finds its
    # section at the start of the output (sq_section).
    RS_WMIN=""
    [ -z "$AGE" ] || rq_add WMIN "SELECT MIN(time) FROM $SST WHERE type IN (4,5,8) $AGE"
    # --- hop awareness (HOPINFO): the last time anything was heard per frequency, from ssid whatever the window. Next to WMIN, at the start of the output, because the shell
    # reads it from there (sq_section: a section far from the start it is searched from costs the square of the distance, and the stations behind it are 2 MB at MAX_AGE=0).
    if [ "$HOPINFO" = "1" ]; then
        rq_add HOP "SELECT freq, MAX(time) FROM ssid WHERE freq IS NOT NULL AND freq>0 AND time IS NOT NULL AND time>0 GROUP BY freq ORDER BY freq"
    fi
    RQ_H=$RQ; RQ=""      # what the shell reads from the start of the output (and the table of the window) ends here; the tail, if any, comes next
    # "hidden" is decided per BSSID by its NEWEST beacon row, not by the strongest row of either kind: h8 = time*2 + hidden of the newest type-8 row (the low bit is
    # the flag), so a hidden network that also answers probes does not flip to named when a probe response is the strongest row, and a network that stops hiding
    # reaches the document as soon as its newest beacon says so. It is the second aggregate of the derived table that already carries MAX(time): no further scan, no
    # bare column. No type-8 row at all (h8 NULL): the row's own flag, as in 0.1. The older schemas below keep the per-row rule.
    rq_add APS1 "SELECT s.bssid, $SSD, IFNULL(s.freq,''), '', IFNULL(s.channel,''), MAX(s.signal), ($ENC), CASE WHEN t.h8 IS NULL THEN IFNULL(s.hidden,0) ELSE t.h8 % 2 END, IFNULL(t.last,''), $ENC5 FROM $SST s JOIN (SELECT bssid, MAX(time) AS last, MAX(CASE WHEN type=8 THEN time*2 + (IFNULL(hidden,0)=1) END) AS h8 FROM $SST WHERE bssid IS NOT NULL AND bssid<>'' AND type IN (5,8) $AGE GROUP BY bssid) t ON t.bssid=s.bssid WHERE s.type IN (5,8) $AGE_S GROUP BY s.bssid"
    [ "$HAS_TIME" = 1 ] || rq_add APS2 "SELECT bssid, $SSD, IFNULL(freq,''), '', IFNULL(channel,''), MAX(signal), ($ENC), IFNULL(hidden,0), '', $ENC5 FROM ssid WHERE bssid IS NOT NULL AND bssid<>'' AND type IN (5,8) $AGE GROUP BY bssid"
    rq_add APS3 "SELECT apmac, $SSD, IFNULL(freq,''), IFNULL(band,''), '', MAX(signal), ($ENC), IFNULL(hidden,0), '', $ENC5 FROM $SST WHERE apmac IS NOT NULL AND apmac<>'' AND type IN (5,8) $AGE GROUP BY apmac"
    rq_add APS4 "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), signal, encryption, 0, '', '', '', '', '' FROM aps"
    rq_add APS5 "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), signal, privacy, 0, '', '', '', '', '' FROM aps"
    rq_add APS6 "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), rssi, encryption, 0, '', '', '', '', '' FROM aps"
    rq_add APS7 "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), rssi, privacy, 0, '', '', '', '', '' FROM aps"

    # --- unassociated stations: probe-request senders (type=4), best-effort. 3 cols: mac, signal,
    # last_seen ('' if unknown). Only the GROUP BY key is a bare column here, so two aggregates are safe.
    # With STARCHORUS_TRAFFIC=1 the first alternative adds the cumulative frame counter of the rows of that MAC heard in the last 300 s (the join is the one CLI1 makes: no
    # second scan of wifi_device; an earlier recon session's larger counter drops out after five minutes). recondb_pick keeps the first alternative of the group that
    # returns rows, so a firmware whose wifi_device has no `packets` or `time` column falls back to CLI1 as before. Only the GROUP BY key is a bare column: the extra
    # aggregate is safe.
    if [ "$TRAFFIC" = "1" ]; then
        pk_now=$1; case $pk_now in ''|*[!0-9]*) pk_now=0 ;; esac
        rq_add CLI0 "SELECT w.mac, MAX(s.signal), IFNULL(MAX(s.time),''), IFNULL(MAX(CASE WHEN w.time > $((pk_now - 300)) THEN w.packets END),'') FROM $SST s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' $AGE_S GROUP BY w.mac"
    fi
    rq_add CLI1 "SELECT w.mac, MAX(s.signal), IFNULL(MAX(s.time),'') FROM $SST s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' $AGE_S GROUP BY w.mac"
    [ "$HAS_TIME" = 1 ] || rq_add CLI2 "SELECT w.mac, MAX(s.signal), '' FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' $AGE_S GROUP BY w.mac"
    rq_add CLI3 "SELECT stamac, MAX(signal), '' FROM $SST WHERE type=4 AND stamac IS NOT NULL AND stamac<>'' $AGE GROUP BY stamac"

    # --- probed SSIDs (optional "probes"): the network a station's probe request names -- received,
    # never sent. 2 cols: mac, ssid; one row per distinct pair, sorted (deterministic output).
    # Wildcard probes (empty SSID) skipped.
    rq_add PRB1 "SELECT w.mac, $SSD FROM $SST s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' AND s.ssid IS NOT NULL AND CAST(s.ssid AS TEXT)<>'' $AGE_S GROUP BY w.mac, 2 ORDER BY w.mac, 2"
    rq_add PRB2 "SELECT stamac, $SSD FROM $SST WHERE type=4 AND stamac IS NOT NULL AND stamac<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY stamac, 2 ORDER BY stamac, 2"

    # --- multi-SSID responders: how many DIFFERENT SSIDs one BSSID answered probes with (type=5). A
    # count only, no SSID list; emitted as ap.responded_ssids when >= 2. Both column families.
    rq_add RESP1 "SELECT bssid, COUNT(DISTINCT CAST(ssid AS TEXT)) FROM $SST WHERE type=5 AND bssid IS NOT NULL AND bssid<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY bssid HAVING COUNT(DISTINCT CAST(ssid AS TEXT))>1"
    rq_add RESP2 "SELECT apmac, COUNT(DISTINCT CAST(ssid AS TEXT)) FROM $SST WHERE type=5 AND apmac IS NOT NULL AND apmac<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY apmac HAVING COUNT(DISTINCT CAST(ssid AS TEXT))>1"

    # --- the one sqlite3 process of this cycle
    if [ -n "$RQ_T" ]; then RQ="$RQ_H
SELECT '#STARCHORUS_TAIL#';$RQ_T
SELECT '#STARCHORUS_TAILEND#';$RQ"
    else RQ="$RQ_H$RQ"; fi
    if [ "$RQ_STEADY" = 1 ]; then
        pick=$(printf '%s\n' "$RQ" | recondb_query "$qdb" | clean_ctrl)
    else
        pick=$(printf '%s\n' "$RQ" | recondb_query "$qdb" | clean_ctrl | recondb_pick own)
    fi
    # A damaged or torn copy is a failed pass, not "the database holds no access point": run_cycle keeps the last document for it (RQ_HOLD) instead of
    # publishing an empty one over a good one, and says so once per episode (this runs inside the builder, whose stderr is dropped).
    RQ_HOLD=""
    if recondb_failed; then RQ_HOLD=$RQ_WHY; fi
    recon_workdone
    if [ -n "$RQ_HOLD" ]; then HAS_TIME=""; RQ_WIN=""; return 1; fi      # nothing to publish from this copy; the schema is learnt afresh next cycle
    # the sections the shell reads itself come out of the text with parameter expansion (sq_section), no process
    if ! rq_tail; then      # a group without a winner has rows: the first batch learns which alternative it is
        HAS_TIME=""; RQ_WIN=""; RDB_SCH=""; RS_TAKEN=1; build_from_recondb "$1"; return $?
    fi
    RQ_SRC="$NL$pick$NL"
    # The table of the window was refused (no marker row after its CREATE), or the file has another shape than the one the winners were learnt under: this pass asked the wrong
    # question. Ask again at once, as the batch of this state is (without the table; as a first batch): the copy of the sample is made again, which a rare case can afford.
    if [ "$RW_USED" = 1 ]; then
        case $RQ_SRC in
            *"$NL#STARCHORUS_RWOK#$NL"*) ;;
            *) RW_OFF=60; RS_TAKEN=1; build_from_recondb "$1"; return $? ;;
        esac
    fi
    if [ "$RQ_STEADY" = 1 ] && [ -n "$RDB_SCH" ] && sq_section SCHEMA && [ "$RQ_SECT" != "$RDB_SCH" ]; then
        HAS_TIME=""; RQ_WIN=""; RDB_SCH=""; RW_OFF=0; RS_TAKEN=1; build_from_recondb "$1"; return $?
    fi
    if [ -n "$AGE" ]; then
        sq_section WMIN; RS_WMIN=${RQ_SECT%%"$NL"*}
        case $RS_WMIN in ''|*[!0-9]*) RS_WMIN="" ;; esac
    fi
    if [ -z "$HAS_TIME" ]; then
        sq_section HASTIME
        case ${RQ_SECT%%"$NL"*} in 0) HAS_TIME=0 ;; [1-9]*) HAS_TIME=1 ;; esac
    fi
    if [ "$RQ_STEADY" != 1 ] && [ -n "$HAS_TIME" ] && sq_section OWN end; then
        RQ_WIN=" $RQ_SECT "; RQ_WINT=$TRAFFIC; RDB_SCH=""
        if sq_section SCHEMA; then RDB_SCH=$RQ_SECT; fi
    fi
    # an access point: rows under the APS marker (the reduced batch always has the marker, the first one only when a row claimed it)
    if sq_section APS; then :; else RQ_SECT=""; fi
    case $RQ_SECT in
        *[![:space:]]*) ;;
        *) HAS_TIME=""; RQ_WIN=""      # no access point: nothing to publish; learn the schema afresh next cycle
           return 1 ;;
    esac

    # --- hop awareness (STARCHORUS_HOPINFO / STARCHORUS_SURVEY, default off): channels[] = per frequency the last
    # time anything was heard there (recon.db `time`; whether that is a first-seen or an upsert time is
    # an OPEN device question) and, with the survey flag, the driver's own busy percentage and noise
    # floor (`iw ... survey dump` is a read-only netlink dump). No channels[] => the front-end never
    # treats a BSSID's absence as "gone" or "stale". (The recon.db rows came in the batch above.)
    chj=""
    if [ "$HOPINFO" = "1" ] || [ "$SURVEY" = "1" ]; then
        chrows=""
        if [ "$HOPINFO" = "1" ]; then
            sq_section HOP; hop=$RQ_SECT
            [ -z "$hop" ] || chrows=$(printf '%s\n' "$hop" | awk -F"$RECON_TAB" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "H\t%s\t%s\n", $1, $2}')
        fi
        if [ "$SURVEY" = "1" ]; then
            sif=${STARCHORUS_SURVEY_IFACE:-$MONIF}
            if [ -n "$sif" ] && have iw; then
                sv=$(iw dev "$sif" survey dump 2>/dev/null | survey_rows)
                [ -z "$sv" ] || chrows=$(printf '%s\n%s' "$chrows" "$sv")
            fi
        fi
        chj=$(printf '%s\n' "$chrows" | channels_json)
    fi

    # the extras of the center object (what add_center would insert) go in here when run_cycle asks: one pass less over the document
    bx=""; if [ "$CX_EMBED" = 1 ]; then bx=$(center_extra); CENTER_DONE=1; fi
    printf '%s\n' "$pick" | \
      SC_CH="$chj" SC_CX="$bx" awk -v ts="$1" -v center="$CENTER_LABEL" -v src="recon-db" -v FSU="$RECON_TAB" "$AWK_JSON_HELPERS$AWK_SEC$AWK_RECONDB"
    return 0
}

# --------------------------------------------------------------------------- JSON: the AP service's own recon lists (opt-in)
# PINEAP. STARCHORUS_SOURCE=pineap asks the device's AP service for what its recon already holds, with READ-ONLY commands (apcli_ro:
# `RECON DEVICES format=json bytime=true limit=400`, or with STARCHORUS_PINEAP_CALLS=full `RECON APS format=json` and `RECON DEVICES
# format=json`), instead of copying recon.db and querying it. The transmit counters of every wireless interface stay unchanged (V-3, and a run
# of the recent form). It is a different VIEW, not the same data, and not a cheaper one: the calls cost 0.3 s of CPU, but the awk below
# walks the answer at about 22 ms per device on the device (9 s for the 400 of `recent`, 46 s for the 2,100 of `full`), against 2 s of CPU for a
# cycle of the database path (docs/device-notes.md §6a). The lists are the CURRENT recon session only (the database is cumulative),
# on firmware 1.x there is no encryption field and no station -> AP link in them (firmware 2.0 adds `encryption` to beacon records: the security item below). So:
#   * APs   : RECON APS. ssid = the strongest (then newest) beacon or probe-response record; a hidden beacon gives "". channel, freq, rssi from
#             the record / the device; last_seen = `time`; responded_ssids from the probe-response records (2 or more distinct).
#   * stations: the RECON DEVICES entries that are not APs (not in RECON APS and no beacon record). rssi, last_seen = `time`; probes[] = the SSIDs
#             of their probe records (distinct, sorted, at most 8).
#   * security: on firmware 2.0 a beacon record carries `encryption` (the full libwifi bitmask, same as recon.db): encfields reads it from the
#             decimal string (so awk never rounds the uint64 at 2^53) and sec_of2/sec_extra label it, with no recon.db lookup. Otherwise (1.x, or an
#             AP seen only by a probe response) it is taken per BSSID from recon.db, rarely: a small cache in $TMPDIR_RAM (starchorus-sec.txt) is read
#             every cycle; ONE query (copy + one sqlite3, the same read-only path as above) runs when a BSSID is not in the cache (at most every
#             60 s) or when the cache holds BSSIDs the database did not know (at most every 10 min). Without either: "Unknown".
#   * STARCHORUS_MAX_AGE applies to `time` of both lists.
# The JSON is parsed in awk (the device's jq is slow): sed puts every JSON string on a line of its own (any character, escaped quotes and
# backslashes, \uXXXX), so awk only walks the short structural chunks between them. SSIDs are carried over with their JSON escapes; \n and \t
# become a space, other control characters (\r, \b, \f, \u0000-\u001f, \u007f) are dropped, as the database path does; \uXXXX above U+007F stays an escape.
json_tokens() {   # stdin: JSON; stdout: one token per line (a string on a line of its own). The newline in the replacement is the portable (POSIX) form.
    sed -E 's/"([^"\\]|\\.)*"/\
&\
/g'
}
# shellcheck disable=SC2016  # awk program text, deliberately not expanded
AWK_PINEAP='
    function cleanstr(r,   i,n,c,d,o,h){ if(index(r,"\\")==0 && index(r,"\t")==0) return r       # (nearly every SSID: nothing to do)
        o=""; n=length(r); i=1
        while(i<=n){ c=substr(r,i,1)
            if(c=="\\"){ d=substr(r,i+1,1)
                if(d=="n" || d=="t"){ o=o " "; i+=2 }
                else if(d=="r" || d=="b" || d=="f"){ i+=2 }
                else if(d=="\"" || d=="\\"){ o=o c d; i+=2 }
                else if(d=="/"){ o=o "/"; i+=2 }
                else if(d=="u"){ h=substr(r,i+2,4)
                    if(h ~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/){
                        if(!(h ~ /^00[01]/ || toupper(h)=="007F")) o=o "\\u" h
                        i+=6 }
                    else i+=2 }
                else i+=2 }
            else { if(c=="\t") c=" "; o=o c; i++ } }
        return o }
    function ri(v){ v=v+0; return int(v + (v<0 ? -0.5 : 0.5)) }
    function isnum(v){ return v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/ }
    function push(c){ depth++; kind[depth]=(c=="{" ? "o" : "a"); expkey[depth]=(c=="{"); key[depth]=""
        if(depth==1 && !root[which]) root[which]=(c=="[") ? 1 : -1
        if(depth==2 && kind[2]=="o") dev_begin()
        if(depth==4 && kind[4]=="o") rec_begin() }
    function pop(){ if(depth==4 && kind[4]=="o") rec_end()
        if(depth==2 && kind[2]=="o") dev_end()
        if(depth==1 && root[which]==1) closed[which]=1
        if(depth>0) depth-- }
    function lit_end(){ if(lit!=""){ onval(lit); lit="" } }
    function tok_str(b){ if(depth>0 && kind[depth]=="o" && expkey[depth]) key[depth]=b; else onval(b) }
    function onval(v,   f){
        if(depth==2 && kind[2]=="o"){ f=key[2]
            if(f=="mac") dmac=v; else if(f=="freq") dfreq=v; else if(f=="signal") dsig=v; else if(f=="time") dtime=v }
        else if(depth==4 && kind[4]=="o"){ f=key[4]
            if(f=="ssid") rssid=cleanstr(v); else if(f=="channel") rch=v; else if(f=="freq") rfreq=v; else if(f=="signal") rsig=v
            else if(f=="time") rtime=v; else if(f=="hidden") rhid=(v=="true"); else if(f=="encryption") renc=v } }
    function dev_begin(   k){ dmac=""; dfreq=""; dsig=""; dtime=""; hascand=0; hasbeacon=0; hasbenc=0; benc=""; bencsig=-1000; nresp=0; np=0
        for(k in rseen) delete rseen[k]
        for(k in pseen) delete pseen[k] }
    function rec_begin(){ rssid=""; rch=""; rfreq=""; rsig=""; rtime=""; rhid=0; renc="" }
    function rec_end(   t,s,tm){ t=key[2]; s=isnum(rsig) ? rsig+0 : -1000; tm=isnum(rtime) ? rtime+0 : 0
        if(t=="beacon" || t=="response"){
            if(t=="beacon"){ hasbeacon=1; if(renc ~ /^[0-9]+$/ && (!hasbenc || s>bencsig)){ hasbenc=1; bencsig=s; benc=renc } }
            if(!hascand || s>bsig || (s==bsig && tm>btime)){ hascand=1; bsig=s; btime=tm; bssid=rssid; bch=rch; bfreq=rfreq; bhid=(t=="beacon" && rhid) }
            if(t=="response" && rssid!="" && !(rssid in rseen)){ rseen[rssid]=1; nresp++ } }
        else if(t=="probe" && rssid!="" && !(rssid in pseen)){ pseen[rssid]=1; p8add(rssid) } }
    # the 8 smallest distinct probed SSIDs of the device, sorted: a station that names thousands of networks costs 8 steps per SSID, not a sort
    function p8add(s,   j){ if(np<8) j=++np; else if(s<plist[8]) j=8; else return
        while(j>1 && plist[j-1]>s){ plist[j]=plist[j-1]; j-- }
        plist[j]=s }
    function dev_end(   m,f,ch,i,pr,ef){
        m=macfmt(dmac); if(!ismac(m)) return
        if(cut+0>0 && !(isnum(dtime) && dtime+0>cut+0)) return
        if(which==2 && (m in isap)) return
        if(which==1 || hasbeacon){
            isap[m]=1
            f=(isnum(dfreq) && dfreq+0>0) ? ri(dfreq) : ((hascand && isnum(bfreq) && bfreq+0>0) ? ri(bfreq) : "")
            ch=(hascand && isnum(bch) && bch+0>0) ? ri(bch) : (f!="" ? ch_from_freq(f) : "")
            ap_mac[nap]=m; ap_ssid[nap]=(hascand && !bhid) ? bssid : ""; ap_f[nap]=f; ap_ch[nap]=ch
            ap_sig[nap]=isnum(dsig) ? ri(dsig) : (hascand && bsig>-1000 ? ri(bsig) : "")
            ap_last[nap]=(isnum(dtime) && dtime+0>0) ? ri(dtime) : ""
            ap_resp[nap]=(nresp>=2) ? nresp : 0
            if(hasbenc){ encfields(benc, ef); ap_jsec[nap]=sec_of2(ef["enc"],ef["grp"],ef["pw"],ef["akm"],ef["auth"]); ap_jext[nap]=sec_extra(ef["grp"],ef["pw"],ef["akm"],ef["auth"]); ap_hasjsec[nap]=1 }
            else ap_hasjsec[nap]=0
            nap++ }
        else {
            pr=""
            for(i=1;i<=np;i++) pr=pr (i>1 ? ", " : "") "\"" plist[i] "\""
            st_mac[nst]=m; st_sig[nst]=isnum(dsig) ? ri(dsig) : ""; st_last[nst]=(isnum(dtime) && dtime+0>0) ? ri(dtime) : ""; st_pr[nst]=pr
            nst++ } }
    # idx[0..n-1] = the indexes of arr[0..n-1] in ascending order, ties by index. A heap sort: n log n; an insertion sort would take n squared
    # steps (90 microseconds each on the device), and the lists have as many entries as the air has devices, thousands in a crowd.
    function sift(r,e,idx,   c,v){ v=idx[r]
        while((c=2*r+1)<=e){ if(c<e && skey[idx[c]]<skey[idx[c+1]]) c++
            if(skey[v]<skey[idx[c]]){ idx[r]=idx[c]; r=c } else break }
        idx[r]=v }
    function sortidx(arr,n,idx,   i,t){ for(i=0;i<n;i++){ idx[i]=i; skey[i]=arr[i] "|" sprintf("%09d", i) }
        for(i=int((n-2)/2);i>=0;i--) sift(i,n-1,idx)
        for(i=n-1;i>0;i--){ t=idx[0]; idx[0]=idx[i]; idx[i]=t; sift(0,i-1,idx) } }
    BEGIN{ sec_init(); depth=0; which=1; nap=0; nst=0; sf=ENVIRON["SC_SEC"]; uf=ENVIRON["SC_UNK"]; nf=ENVIRON["SC_NEG"]; af=ENVIRON["SC_ALL"]
        if(sf!=""){ while((getline l < sf)>0){ n=split(l, q, "\t"); if(n>=2 && ismac(q[1])){ seen[q[1]]=1; slab[q[1]]=q[2]; sext[q[1]]=(n>=3 ? q[3] : "") } } close(sf) } }
    /^#STARCHORUS_DEVICES#$/ { lit_end(); which=2; depth=0; next }
    { line=$0; if(line=="") next
      if(substr(line,1,1)=="\"" && length(line)>=2){ lit_end(); tok_str(substr(line,2,length(line)-2)); next }
      n=length(line)
      for(i=1;i<=n;i++){ c=substr(line,i,1)
          if(c==" " || c=="\t" || c=="\r") lit_end()
          else if(c=="{" || c=="["){ lit_end(); push(c) }
          else if(c=="}" || c=="]"){ lit_end(); pop() }
          else if(c==":"){ lit_end(); if(depth>0) expkey[depth]=0 }
          else if(c==","){ lit_end(); if(depth>0 && kind[depth]=="o") expkey[depth]=1 }
          else lit=lit c }
      lit_end() }
    END{
        if(closed[need+0]!=1) exit 3       # the list the document stands on (RECON APS; in "recent" mode the one RECON DEVICES) gave no complete JSON array: no document
        doc_head()
        sortidx(ap_mac, nap, ai)
        printf "  \"aps\": [\n"
        for(k=0;k<nap;k++){ i=ai[k]; m=ap_mac[i]
            if(ap_hasjsec[i]){ sec=ap_jsec[i]; sx=ap_jext[i] }
            else { if(af!="") print m > af
                if(m in seen){ sec=(slab[m]!="" ? slab[m] : "Unknown"); sx=sext[m]; if(slab[m]=="" && nf!="") print m > nf }
                else { sec="Unknown"; sx=""; if(uf!="") print m > uf } }
            extra=(ap_last[i]!="") ? ", \"last_seen\": " ap_last[i] : ""
            extra=extra sx
            if(ap_resp[i]>0) extra=extra ", \"responded_ssids\": " ap_resp[i]
            b=(ap_f[i]!="") ? band_from_freq(ap_f[i]) : ""
            if(b=="" && ap_ch[i]!="") b=band_from_ch(ap_ch[i])
            printf "%s%s\n", ap_json(jesc(m), ap_ssid[i], (ap_ch[i]!="" ? ap_ch[i] : "null"), b, (ap_f[i]!="" ? ap_f[i] : "null"),
                numval(ap_sig[i] ""), sec, extra, ""), (k<nap-1 ? "," : "") }
        printf "  ],\n  \"unassociated\": [\n"
        sortidx(st_mac, nst, si)
        for(k=0;k<nst;k++){ i=si[k]
            extra=(st_last[i]!="") ? ", \"last_seen\": " st_last[i] : ""
            if(st_pr[i]!="") extra=extra ", \"probes\": [" st_pr[i] "]"
            printf "%s%s\n", cl_json(jesc(st_mac[i]), numval(st_sig[i] ""), extra), (k<nst-1 ? "," : "") }
        printf "  ]\n}\n"
        if(af!="") close(af); if(uf!="") close(uf); if(nf!="") close(nf) }
'

# The pineap document: both lists in, one document out. $1 = now. A failed RECON APS (no complete JSON array) is no document (return 1); a failed
# RECON DEVICES only means no stations.
pineap_doc() {
    { printf '%s\n' "$PA" | clean_ctrl | json_tokens; printf '#STARCHORUS_DEVICES#\n'; printf '%s\n' "$PD" | clean_ctrl | json_tokens; } | \
      SC_SEC="$PSEC" SC_UNK="$PUNK" SC_NEG="$PNEG" SC_ALL="$PALL" awk -v ts="$1" -v center="$CENTER_LABEL" -v src="pineap" -v cut="$PCUT" -v need="$PNEED" "$AWK_JSON_HELPERS$AWK_SEC$AWK_PINEAP"
}
# One query for the security of the APs in file $1 (lower-case MACs, one per line), written as the cache $PSEC: "mac<TAB>label<TAB>extra", and an
# empty label for a BSSID the database does not know (so it is not asked for again before the next 10-minute retry). The same read-only copy
# and batch as the database path; the bitmask is decoded by the same awk library.
pineap_secrefresh() {
    PSEC_T=$2
    recon_db_path && have sqlite3 || return 0
    recon_enc_sql
    pl=$(awk -v q="'" '{ m=toupper($0); gsub(/:/, "", m); if (m ~ /^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$/) printf "%s%s%s%s", (n++ ? "," : ""), q, m, q }' "$1")
    [ -n "$pl" ] || return 0
    file_size "$RDB_PATH"
    recon_workcopy "$RDB_PATH" "$FSZ"
    # -bail: the first error ends the batch, so the closing marker row comes out only when the query ran to the end. An answer without it (a torn
    # copy, a locked file, a missing table) is not "the database does not know these": the cache stays as it was.
    ps_rows=$(printf '%s;\nSELECT %s;\n' "SELECT bssid, ($ENC), $ENC5, MAX(signal) FROM ssid WHERE type IN (5,8) AND bssid IN ($pl) GROUP BY bssid" "'#STARCHORUS_SECEND#'" \
        | { RQ_BAIL=-bail; recondb_query "$QDB"; } | clean_ctrl)
    recon_workdone
    case $NL$ps_rows$NL in
        *"$NL#STARCHORUS_SECEND#$NL"*) PSEC_FAIL=0 ;;
        *) [ "$PSEC_FAIL" = 1 ] || log "pineap: the security lookup in recon.db gave no answer; the labels already known stay (next try in a minute)"
           PSEC_FAIL=1; return 0 ;;
    esac
    { printf '%s\n' "$ps_rows"; } | SC_ALL="$1" awk -v FSU="$RECON_TAB" "$AWK_JSON_HELPERS$AWK_SEC"'
        BEGIN{ FS=FSU; sec_init(); while((getline l < ENVIRON["SC_ALL"])>0) want[l]=1 }
        NF>=6 { m=macfmt($1); if(!ismac(m)) next; delete want[m]; printf "%s\t%s\t%s\n", m, sec_of2($2,$3,$4,$5,$6), sec_extra($3,$4,$5,$6) }
        END{ for(m in want) printf "%s\t\t\n", m }' > "$PSEC.new.$$" 2>/dev/null && mv -f "$PSEC.new.$$" "$PSEC"
    rm -f "$PSEC.new.$$" 2>/dev/null
}
build_from_apcli() {
    apcli_ro present || return 1
    if [ "$PINEAP_CALLS" = recent ]; then
        # one call: the newest 400 devices carry the APs (beacon records) and the stations (probe records); no RECON APS
        PA='[]'; PD=$(apcli_ro recon_devices_recent 2>/dev/null); PNEED=2
    else
        PA=$(apcli_ro recon_aps 2>/dev/null)
        [ -n "$PA" ] || return 1           # nothing at all (hung, killed by the timeout): do not wait for a second call
        PD=$(apcli_ro recon_devices 2>/dev/null); PNEED=1
    fi
    PSEC="$TMPDIR_RAM/starchorus-sec.txt"; PUNK="$TMPDIR_RAM/starchorus-pineap-$$.unk"; PNEG="$TMPDIR_RAM/starchorus-pineap-$$.neg"; PALL="$TMPDIR_RAM/starchorus-pineap-$$.all"
    PCUT=0
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null && [ "$1" -gt "$MAX_AGE" ] 2>/dev/null; then PCUT=$(($1 - MAX_AGE)); fi
    if [ ! -d "$TMPDIR_RAM" ] || [ ! -w "$TMPDIR_RAM" ]; then PUNK=""; PNEG=""; PALL=""; fi      # no RAM directory: no side files, no lookups
    rm -f "$PUNK" "$PNEG" "$PALL" 2>/dev/null
    pdoc=$(pineap_doc "$1"); prc=$?
    if [ "$prc" = 0 ] && [ -n "$PALL" ]; then
        # unknown BSSIDs (none in the cache yet): ask at most every 60 s; BSSIDs the database did not know: retry every 10 min
        # (a clock set back, the device has no battery clock, must not hold the lookups off until it has caught up: that is "due")
        [ "$1" -ge "$PSEC_T" ] 2>/dev/null || PSEC_T=0
        if { [ -s "$PUNK" ] && [ $(($1 - PSEC_T)) -ge 60 ]; } || { [ -s "$PNEG" ] && [ $(($1 - PSEC_T)) -ge 600 ]; }; then
            pineap_secrefresh "$PALL" "$1"
            rm -f "$PUNK" "$PNEG" 2>/dev/null
            pdoc=$(pineap_doc "$1"); prc=$?
        fi
    fi
    rm -f "$PUNK" "$PNEG" "$PALL" 2>/dev/null
    [ "$prc" = 0 ] || return 1
    # an answer without a single AP is no answer (the AP service was just restarted, RECON NEW): run_cycle falls back to recon.db for it
    case $pdoc in *'"bssid": "'*) ;; *) return 2 ;; esac
    printf '%s\n' "$pdoc"
}

# --------------------------------------------------------------------------- JSON: iw scan (ACTIVE!)
# WARNING: `iw dev <iface> scan` TRANSMITS probe-request frames. That is ACTIVE, not passive,
# so it violates the strict passivity contract and is DISABLED unless STARCHORUS_ALLOW_ACTIVE=1.
# It also cannot enumerate client stations (APs only).
build_from_iwscan() {
    [ "$ALLOW_ACTIVE" = "1" ] || return 1
    have iw || return 1
    scanif=$IFACE; [ "$scanif" = "auto" ] && scanif=$(candidate_base_iface)
    [ -n "$scanif" ] || return 1
    log "ACTIVE iw scan on $scanif (transmits probe requests) -- opted in via STARCHORUS_ALLOW_ACTIVE=1"
    iw dev "$scanif" scan 2>/dev/null | clean_ctrl | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="iw-scan-ACTIVE" \
      "$AWK_JSON_HELPERS"'
        function flush(   f,ch){
            if(bss==""){ return }
            f=freq+0; ch=ch_from_freq(f)
            band = band_from_freq(f)
            sec="Open"
            if(rsn && wpa) sec="WPA/WPA2"
            else if(rsn) sec="WPA2/WPA3"
            else if(wpa) sec="WPA"
            else if(wep) sec="WEP"
            out[n++]=ap_json(jesc(macfmt(bss)), jesc(ssid), (ch!=""?int(ch):"null"), band, (f>0?f:"null"),
                (haversig?sig:"null"), sec, "", "")
            bss=""; ssid=""; freq=0; sig=0; haversig=0; rsn=0; wpa=0; wep=0
        }
        BEGIN{ n=0 }
        /^BSS / { flush(); bss=substr($2,1,17); next }
        /freq:/ { for(i=1;i<=NF;i++) if($i=="freq:"){ freq=$(i+1) } }
        /signal:/ { for(i=1;i<=NF;i++) if($i=="signal:"){ sig=int($(i+1)); haversig=1 } }
        /SSID:/ { s=$0; sub(/^[^:]*SSID:[ ]?/,"",s); ssid=s }
        /RSN:/ { rsn=1 }
        /WPA:/ { wpa=1 }
        /Privacy/ { wep=1 }   # capability Privacy w/o RSN/WPA implies WEP
        END{
            flush()
            doc_head(); printf "  \"aps\": [\n"
            for(i=0;i<n;i++) printf "%s%s", out[i], (i<n-1?",\n":"\n")
            printf "  ],\n  \"unassociated\": [\n\n  ]\n}\n"
        }'
    return 0
}

# --------------------------------------------------------------------------- spec §14.6: the AP-service CLI allowlist
# The ONLY functions in which an AP-service CLI command may be written (tools/passivity-check.sh lists them in SEC6_FUNCS and greps every
# other line of the collector, both starchorus-display.sh, payload.sh and library/** for `_pineap`, PINEAPPLE_, WIGLE_, DEAUTH, SSID_POOL,
# GPS_GET and the firmware's other active or outward commands by name and prefix: WIFI_CONNECT, WIFI_PCAP_, OPENVPN_, WIREGUARD_ and the rest
# of SEC6_RE there). Four LITERAL command lines (three commands, one of them also in a bounded form), no eval, no command name from a variable, no
# argument taken from outside (the lines only carry the optional prefix `timeout 10`). `recon_aps` and `recon_devices` are the two read-only
# lists the opt-in source STARCHORUS_SOURCE=pineap reads (verified on the device, docs/device-notes.md V-3: they leave the transmit counters of
# every wireless interface unchanged); there is no `RECON CLIENTS` command on the device, the stations are in `RECON DEVICES`.
# `recon_devices_recent` is the same list newest first and cut at 400 entries (`bytime=true`, the CLI's own argument, from its help). On 1.x the
# former `sort=time sortdir=desc` form passed a 130 s device run on 14 Oct 2026 (counters unchanged); firmware 2.0 rejects `sort=time`, so the
# newest-first form is `bytime=true`, verified read-only on 29 Oct 2026 (the transmit counters of every wireless interface unchanged). `present`
# runs no command at all: it only asks whether the CLI
# exists. The former `monitor` id (listening to one BSSID, never verified on the device and called by nothing) has left the allowlist.
# `recon_channels` is the AP service's frame count per frequency (channel activity, not devices): read-only, its transmit counters measured
# unchanged (docs/device-notes.md V-3), gated on STARCHORUS_TRAFFIC alone: turning Traffic on does not make the other ids callable, and
# STARCHORUS_APCLI_RO=1 does not make this one callable. The command exits 1 while it prints valid JSON, so its answer is judged by its text only.
# rc 0 = ran, 1 = nothing to run (present), 2 = refused, 3 = flag off.
apcli_ro() {
    [ "$APCLI_RO" = "1" ] || [ "$1" = recon_channels ] || return 3
    # the list calls get 10 s (they take well under one on the device): a hung AP service must not hang the cycle. A `timeout`
    # is on the device (docs/device-notes.md §2); without one the call is made as it is.
    ap_to=""; have timeout && ap_to="timeout 10"
    # shellcheck disable=SC2086  # ap_to is "timeout 10" or empty
    case "$1" in
        present)       [ $# -eq 1 ] || return 2; command -v _pineap >/dev/null 2>&1 ;;
        recon_aps)     [ $# -eq 1 ] || return 2; $ap_to _pineap RECON APS format=json ;;
        recon_devices) [ $# -eq 1 ] || return 2; $ap_to _pineap RECON DEVICES format=json ;;
        recon_devices_recent) [ $# -eq 1 ] || return 2; $ap_to _pineap RECON DEVICES format=json bytime=true limit=400 ;;
        recon_channels) [ $# -eq 1 ] || return 2; [ "$TRAFFIC" = "1" ] || return 3; $ap_to _pineap RECON CHANNELS format=json ;;
        *) return 2 ;;
    esac
}
# selftest support: an executable `_pineap` stub in directory $1 that appends its argv to file $2 (one line per call). With $3 and $4 it also
# prints those files for `RECON APS format=json` and `RECON DEVICES format=json` (fixture JSON), with $5 that file for `RECON CHANNELS format=json`;
# any other argument line prints nothing. $3 = hang: a command line that never answers.
apcli_stub() {
    mkdir -p "$1" || return 1
    {
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$2"
        if [ "$3" = hang ]; then printf 'exec sleep 40\n'   # a command line that never answers (the timeout test)
        elif [ -n "$3$5" ]; then
            printf 'case "$*" in\n'
            [ -z "$3" ] || printf '"RECON APS format=json") cat "%s" ;;\n"RECON DEVICES format=json"*) cat "%s" ;;\n' "$3" "$4"
            [ -z "$5" ] || printf '"RECON CHANNELS format=json") cat "%s" ;;\n' "$5"
            printf 'esac\n'
        fi
    } > "$1/_pineap" && chmod +x "$1/_pineap"
}
# The allowlist selftest ($1 = workspace): stub first in PATH; the four allowed ids that run a command (the fifth, present, only asks whether the command
# line exists) produce exactly their literal lines, everything else exits non-zero WITHOUT reaching the stub -- the former `monitor` id with any BSSID
# included, and each id of the lists without APCLI_RO, the channel list without Traffic.
apcli_selftest() {
    pt="$1"; plog="$pt/apcli.log"; : > "$plog"
    apcli_stub "$pt/bin" "$plog"
    p_path=$PATH; p_flag=$APCLI_RO; p_traf=$TRAFFIC
    PATH="$pt/bin:$PATH"; APCLI_RO=1; TRAFFIC=1
    apcli_ro recon_aps; apcli_ro recon_devices; apcli_ro recon_devices_recent; apcli_ro recon_channels
    pl=$(cat "$plog")
    if [ "$pl" = "RECON APS format=json
RECON DEVICES format=json
RECON DEVICES format=json bytime=true limit=400
RECON CHANNELS format=json" ]; then st_pass "apcli_ro: the four allowed ids that run a command (recon_aps, recon_devices, recon_devices_recent, recon_channels) run exactly their literal command lines"; else st_fail "apcli_ro allowed ids: [$pl]"; fi
    apcli_ro present; ap_pr=$?; mkdir -p "$pt/nobin"
    # shellcheck disable=SC2123  # PATH is replaced on purpose: the command line must not be found
    PATH="$pt/nobin"; apcli_ro present; ap_pn=$?; PATH="$pt/bin:$p_path"
    if [ "$ap_pr" = 0 ] && [ "$ap_pn" != 0 ]; then st_pass "apcli_ro: present only asks whether the command line exists (no command run: 0 with the stub, non-zero without: $ap_pn here, 1 on dash and bash, 127 on the device's BusyBox ash)"; else st_fail "apcli_ro present ($ap_pr/$ap_pn)"; fi
    n0=$(wc -l < "$plog" | tr -d ' '); bad=""
    for rid in DEAUTH deauth "RECON STOP" "RECON NEW" "RECON CLIENTS" recon_clients SSID_POOL_ADD WIGLE_UPLOAD GPS_GET WIFI_CONNECT WIFI_PCAP_START OPENVPN_START WIREGUARD_START AUTOSSH_START DNSSPOOF_START INSTALL_FIRMWARE GPS_CONFIGURE FIND_CLIENT_IP "" monitor MONITOR aa:bb:cc:00:00:01; do
        apcli_ro "$rid" >/dev/null 2>&1 && bad="$bad [$rid]"
    done
    apcli_ro recon_aps extra >/dev/null 2>&1 && bad="$bad [recon_aps extra]"
    apcli_ro recon_devices extra >/dev/null 2>&1 && bad="$bad [recon_devices extra]"
    apcli_ro recon_devices "aa:bb:cc:00:00:01;reboot" >/dev/null 2>&1 && bad="$bad [recon_devices injection]"
    apcli_ro recon_devices_recent limit=9999 >/dev/null 2>&1 && bad="$bad [recon_devices_recent arg]"
    apcli_ro present extra >/dev/null 2>&1 && bad="$bad [present extra]"
    apcli_ro recon_channels extra >/dev/null 2>&1; ap_rx=$?
    [ "$ap_rx" = 2 ] || bad="$bad [recon_channels extra rc $ap_rx]"
    apcli_ro recon_channels "aa:bb:cc:00:00:01;reboot" >/dev/null 2>&1 && bad="$bad [recon_channels injection]"
    for pm in aa:bb:cc:00:00:01 ff:ff:ff:ff:ff:ff 01:00:5e:00:00:01 "aa:bb:cc:00:00:01;reboot" 'aa:bb:cc:00:00:01 --x' ""; do
        apcli_ro monitor "$pm" >/dev/null 2>&1 && bad="$bad [monitor $pm]"
    done
    n1=$(wc -l < "$plog" | tr -d ' ')
    if [ -z "$bad" ] && [ "$n0" = "$n1" ]; then st_pass "apcli_ro: refuses DEAUTH/RECON STOP|NEW|CLIENTS/SSID_POOL/WIGLE/GPS ids and the firmware's other outward command names (WIFI_CONNECT, OPENVPN_START, ...), monitor with any BSSID, extra arguments (recon_channels extra: rc 2), injection — no stub call"; else st_fail "apcli_ro refusals:$bad (stub calls $n0 -> $n1)"; fi
    APCLI_RO=0; TRAFFIC=0; apcli_ro recon_aps >/dev/null 2>&1; rc=$?
    n2=$(wc -l < "$plog" | tr -d ' ')
    if [ "$rc" = "3" ] && [ "$n2" = "$n1" ]; then st_pass "apcli_ro: flag off (STARCHORUS_APCLI_RO=0) -> rc 3, no call"; else st_fail "apcli_ro flag off (rc $rc, calls $n1 -> $n2)"; fi
    # one command, one opt-in: with only Traffic on the lists stay shut (rc 3, no call), with only APCLI_RO the channel list stays shut
    APCLI_RO=0; TRAFFIC=1; ap_bad=""
    for ap_id in recon_aps recon_devices recon_devices_recent present; do apcli_ro "$ap_id" >/dev/null 2>&1; [ "$?" = 3 ] || ap_bad="$ap_bad [$ap_id]"; done
    APCLI_RO=1; TRAFFIC=0; apcli_ro recon_channels >/dev/null 2>&1; [ "$?" = 3 ] || ap_bad="$ap_bad [recon_channels without Traffic]"
    n3=$(wc -l < "$plog" | tr -d ' ')
    if [ -z "$ap_bad" ] && [ "$n3" = "$n2" ]; then st_pass "apcli_ro: Traffic alone opens no list command, APCLI_RO alone does not open recon_channels (rc 3, no stub call)"; else st_fail "apcli_ro gates:$ap_bad (stub calls $n2 -> $n3)"; fi
    PATH=$p_path; APCLI_RO=$p_flag; TRAFFIC=$p_traf
}

# --------------------------------------------------------------------------- survey rows, channels[], center extras
# `iw dev IF survey dump` text on stdin -> "S<TAB>freq<TAB>noise<TAB>active_ms<TAB>busy_ms" per channel (fields absent => '-').
survey_rows() {
    awk '
        function flush(){ if(f ~ /^[0-9]+$/) printf "S\t%s\t%s\t%s\t%s\n", f, (n==""?"-":n), (a==""?"-":a), (b==""?"-":b); f=""; n=""; a=""; b="" }
        /^[ \t]*frequency:/            { flush(); f=$2; next }
        /^[ \t]*noise:/                { n=$2; next }
        /^[ \t]*channel active time:/  { a=$4; next }
        /^[ \t]*channel busy time:/    { b=$4; next }
        END{ flush() }'
}
# "H<TAB>freq<TAB>last_heard" and "S<TAB>freq<TAB>noise<TAB>active<TAB>busy" rows on stdin -> one JSON array (sorted by freq), or nothing.
channels_json() {
    awk -F'\t' '
        $1=="H" && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { seen[$2]=1; last[$2]=$3 }
        $1=="S" && $2 ~ /^[0-9]+$/ { seen[$2]=1
            if($3 ~ /^-?[0-9]+$/) noise[$2]=$3
            if($4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $4+0>0){ p=int(100*$5/$4+0.5); if(p>100) p=100; busy[$2]=p } }
        END{ n=0; for(k in seen) key[n++]=k+0
            for(i=1;i<n;i++){ v=key[i]; j=i-1; while(j>=0 && key[j]>v){ key[j+1]=key[j]; j-- } key[j+1]=v }
            if(n==0) exit
            o="["
            for(i=0;i<n;i++){ k=key[i]; o=o (i?", ":"") "{\"freq\": " k
                if(k in last)  o=o ", \"last_heard\": " last[k]
                if(k in busy)  o=o ", \"busy_pct\": " busy[k]
                if(k in noise) o=o ", \"noise\": " noise[k]
                o=o "}" }
            print o "]" }'
}
# center.own_bssids: this device's interface MACs (sysfs; STARCHORUS_SYSFS_NET overrides the directory for tests), unicast, unique, sorted.
own_bssids() {
    d=${STARCHORUS_SYSFS_NET:-/sys/class/net}
    for f in "$d"/*/address; do [ -r "$f" ] && head -n 1 "$f" 2>/dev/null; done | tr 'A-F' 'a-f' | tr -d '\r' | \
        awk '$0 ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/ && $0 != "00:00:00:00:00:00" && $0 != "ff:ff:ff:ff:ff:ff" && !seen[$0]++' | sort
}
# center.own_ssids: ONLY from the operator's file (one per line, <= 32 chars, <= 32 entries). Never read from the AP service's SSID pool.
own_ssids() {
    [ -n "$OWN_SSID_FILE" ] && [ -r "$OWN_SSID_FILE" ] || return 0
    clean_ctrl < "$OWN_SSID_FILE" 2>/dev/null | awk 'length($0)>0 && length($0)<=32 && !seen[$0]++ && n++<32'
}
# The text appended INSIDE the center object: max_age and interval (D1/D3, always), own_bssids/own_ssids (STARCHORUS_OWN=1 only).
center_extra() {
    ma=$MAX_AGE; case $ma in ''|*[!0-9]*) ma=0 ;; esac
    iv=$INTERVAL; case $iv in ''|*[!0-9]*) iv=5 ;; esac
    [ "$PACE_MORE" -gt 0 ] 2>/dev/null && iv=$((iv + PACE_MORE))      # the value the loop sleeps (pace_end): a loaded device announces its longer cadence
    x=", \"max_age\": $ma, \"interval\": $iv"
    if [ "$OWN" = "1" ]; then
        ob=$(own_bssids | awk '{printf "%s\"%s\"", (NR>1?", ":""), $0}')
        [ -z "$ob" ] || x="$x, \"own_bssids\": [$ob]"
        os=$(own_ssids | awk "$AWK_JSON_HELPERS"'{printf "%s\"%s\"", (NR>1?", ":""), jesc($0)}')
        [ -z "$os" ] || x="$x, \"own_ssids\": [$os]"
    fi
    printf '%s' "$x"
}
# A post-pass wrote the document $1 into "$1.$2" with exit status $3. Keep its output only when the pass
# succeeded, the line count is unchanged (or has grown by exactly $4, the number of lines the pass adds: 0 when
# not given) and the last line is still "}": every post-pass only inserts fields into existing lines (the layers
# pass adds whole lines, and says how many), so anything else (e.g. a pass that died half-way yet returned 0) is
# dropped and the document stays as it was (return 1).
post_keep() {
    # The line counts are compared as numbers and UNQUOTED: the word splitting takes off the blanks a BSD `wc` pads them with (a
    # padded number is a bad number to BusyBox's `[`), and no `tr` process is needed for it. An empty count is a failed `[`, so no.
    # shellcheck disable=SC2046
    if [ "$3" = "0" ] && [ -s "$1.$2" ] \
       && [ $(wc -l < "$1" 2>/dev/null) -eq $(($(wc -l < "$1.$2" 2>/dev/null) - ${4:-0})) ] 2>/dev/null && [ "$(tail -n 1 "$1.$2")" = "}" ]; then
        mv -f "$1.$2" "$1"; return 0
    fi
    rm -f "$1.$2" 2>/dev/null; return 1
}
# stdin -> stdout: the JSON with center_extra() inserted into the one-line "center" object.
add_center() {
    SC_CX=$(center_extra) awk '
        !done && /^  "center": \{"label": "[^"]*"\},?$/ {
            p=match($0, /\},?$/); $0=substr($0,1,p-1) ENVIRON["SC_CX"] substr($0,p); done=1 }
        { print }'
}

# Homing: the validated target (lower-case MAC) or nothing. The environment wins over the file; both are read every cycle so the device can change it.
homing_target() {
    t=$HOMING_BSSID
    if [ -z "$t" ] && [ -r "$OUTDIR/homing.target" ]; then t=$(head -n 1 "$OUTDIR/homing.target" 2>/dev/null | tr -d '\r '); fi
    t=$(printf '%s' "$t" | tr 'A-F' 'a-f')
    case $t in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) printf '%s' "$t" ;;
    esac
}
# stdin (the document) -> the target AP's rssi (an integer, e.g. -57) if its row is in aps[]; nothing otherwise (stations never match: they have "mac", not "bssid").
homing_dbm() {
    awk -v t="$1" 'index($0, "\"bssid\": \"" t "\"") && match($0, /"rssi": -?[0-9]+/) { v=substr($0, RSTART+8, RLENGTH-8); print v; exit }'
}
# stdin -> stdout: the document with a "homing" object appended to the generated line.
add_homing() {
    SC_HM="$1" awk '
        !done && /^  "generated": [0-9]+,$/ { sub(/,$/, ", " ENVIRON["SC_HM"] ","); done=1 }
        { print }'
}
# One cycle's homing step on the file $1 (the finished document): keeps the peak, inserts the field, drops the result if the shape changed.
apply_homing() {
    # No usable target: drop the peak. homing_off comes first: with no target at all no process is started.
    if homing_off || { ht=$(homing_target); [ -z "$ht" ]; }; then HOMING_PEAK=""; HOMING_POLLS=0; return 0; fi
    if own_bssids | grep -qx "$ht"; then return 0; fi
    hd=$(homing_dbm "$ht" < "$1"); [ -n "$hd" ] || return 0
    if [ -z "$HOMING_PEAK" ] || [ "$hd" -ge "$HOMING_PEAK" ] || [ "$HOMING_POLLS" -ge 12 ]; then HOMING_PEAK=$hd; HOMING_POLLS=0; else HOMING_POLLS=$((HOMING_POLLS + 1)); fi
    hg=$(sed -n 's/^  "generated": \([0-9][0-9]*\),$/\1/p' "$1" | head -n 1); [ -n "$hg" ] || hg=0
    add_homing "\"homing\": {\"bssid\": \"$ht\", \"dbm\": $hd, \"peak\": $HOMING_PEAK, \"t\": $hg}" < "$1" > "$1.h" 2>/dev/null
    post_keep "$1" h $?
}

# 0 iff the file $1 has the shape every builder gives its document: "{" as the first line, "}" as the last, and one `  "aps": [` line (the explicit empty document's
# `"aps": [],` counts). The check of what is about to be published: an awk that is cut short (a full /tmp, a kill) can still exit 0, and a half document with a
# status of 0 must not replace a whole one.
doc_whole() {
    DOC_N=$(awk 'NR == 1 { f = $0 } /^  "aps": \[/ { n++ } { l = $0 } END { if (f == "{" && l == "}" && n == 1) print NR }' "$1" 2>/dev/null)
    [ -n "$DOC_N" ]      # (and DOC_N is the line count of a whole document: rs_keepdoc keeps it)
}

# --------------------------------------------------------------------------- empty document
write_empty() {
    ts=$1; reason=$2
    printf '{\n  "generated": %s,\n  "center": {"label": "%s"%s},\n  "source": "none",\n  "note": "%s",\n  "aps": [],\n  "unassociated": []\n}\n' \
        "$ts" "$CENTER_LABEL" "$(center_extra)" "$reason"
}

# --------------------------------------------------------------------------- recon.db: a cycle with nothing new
# The recon engine keeps recon.db open and writes whenever it hears something, so on a busy night the file changes every cycle and this
# never fires; in a quiet room it saves the whole copy, the queries, the awk passes and the vendor pass (about 3 s of the device's CPU).
# A skipped cycle still publishes: the document is the same bytes with a new "generated". The page counts a new `generated` as a capture and
# calls a feed that stands still for 6 polls Stale, and the freshness tiers are measured from `generated`, so leaving it alone would make a
# healthy, quiet collector look dead. The document it publishes is the one of this process's last full pass, kept in memory (RS_DOCV, see
# rs_keepdoc): what $OUTFILE holds at that moment (another collector's --once with other settings, an empty document after a failed cycle)
# is not trusted, and is replaced. What may NOT be skipped: the file changed (size, mtime, journal, wal), a row could have left the
# STARCHORUS_MAX_AGE window (see recon_unchanged), a homing target, the survey or the own-device fields are on (they are read every cycle; a
# document with a homing reading must be rebuilt without it once the target goes), a setting changed, the clock went backwards, or SKIP_MAX
# skips in a row have passed.
rs_cfg() {   # RS_CFGNOW = what the document depends on besides recon.db: a changed setting is a rebuild
    RS_CFGNOW="$MAX_AGE|$INTERVAL|$VENDOR|$HOPINFO|$OUTFILE|$RECON_DB|$OUI_PATH|$CENTER_LABEL|$BLUETOOTH|$TRAFFIC"
}
homing_off() { [ -z "$HOMING_BSSID" ] && [ ! -e "$OUTDIR/homing.target" ]; }   # no target, no file: no process needed to know
recon_unchanged() {   # $1 = now, RS_RAW = this cycle's sample. 0 = the document of the last full pass still stands
    [ "$SKIP_UNCHANGED" = 1 ] && [ -n "$RS_SIG" ] && [ "${1:-0}" -gt 0 ] 2>/dev/null || return 1
    [ "$RS_SKIPS" -lt "$SKIP_MAX" ] && [ -n "$RS_DOCV" ] && [ "$SURVEY" != 1 ] && [ "$OWN" != 1 ] || return 1
    [ "$1" -ge "$RS_TS" ] 2>/dev/null || return 1
    rs_cfg; [ "$RS_CFGNOW" = "$RS_CFG" ] || return 1
    homing_off || return 1
    [ -n "$RS_RAW" ] && [ "$RS_RAW" = "$RS_SIG" ] || return 1      # this cycle's sample (recon_sample) is the one of the last full pass
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null; then
        # the build keeps the rows with `time > now - MAX_AGE`: it stands while the oldest row it counted still does (none known: no skip)
        [ -n "$RS_MIN" ] && [ "$RS_MIN" -gt $(($1 - MAX_AGE)) ] 2>/dev/null || return 1
    fi
    return 0
}
# Keep the document $1 of a full pass for refresh_generated. In a variable, not in a file: a file in /tmp would outlive a collector that is killed
# (the loop only hears a TERM after its sleep). 0 = kept; 1 = not (unreadable): the next cycle is a full pass.
rs_keepdoc() {   # $1 = the document, $2 = its line count when the caller has it (doc_whole's DOC_N); else it is counted
    RS_DOCV=$(cat "$1" 2>/dev/null); RS_DOCN=$2
    case $RS_DOCN in ''|*[!0-9]*) RS_DOCN=$(wc -l < "$1" 2>/dev/null) ;; esac
    [ -n "$RS_DOCV" ] && [ -n "$RS_DOCN" ] && return 0
    RS_DOCV=""; return 1
}
# RS_DOCV with a new "generated" and nothing else, put over $2 (default $OUTFILE; run_cycle asks for its work file, so that the per-cycle layers go
# on before anything is published). Same line count and closing brace or it is dropped (return 1).
refresh_generated() {   # $1 = now, $2 = where the document goes
    rg_t="$OUTFILE.gen$$"
    # the new "generated" and, on the center line, the interval as the loop announces it now (what center_extra would write: INTERVAL, or more after a slow cycle)
    rg_iv=$INTERVAL; case $rg_iv in ''|*[!0-9]*) rg_iv=5 ;; esac
    [ "$PACE_MORE" -gt 0 ] 2>/dev/null && rg_iv=$((rg_iv + PACE_MORE))
    printf '%s\n' "$RS_DOCV" | sed -e "s/^  \"generated\": [0-9][0-9]*,\$/  \"generated\": $1,/" -e "/^  \"center\": [{]/s/\"interval\": [0-9][0-9]*/\"interval\": $rg_iv/" > "$rg_t" 2>/dev/null
    # The line counts as in post_keep (compared as numbers, unquoted).
    # shellcheck disable=SC2046,SC2086
    if grep -q "^  \"generated\": $1,\$" "$rg_t" 2>/dev/null \
       && [ $RS_DOCN -eq $(wc -l < "$rg_t" 2>/dev/null) ] 2>/dev/null && [ "$(tail -n 1 "$rg_t")" = "}" ] \
       && mv -f "$rg_t" "${2:-$OUTFILE}" 2>/dev/null; then return 0; fi
    rm -f "$rg_t" 2>/dev/null; return 1
}

# --------------------------------------------------------------------------- one cycle
# In order: (1) the per-cycle layers that run beside the build start, the Bluetooth window (bt_begin, the processes run in the background from here on)
# and the RECON CHANNELS call (on every second cycle, see there); (2) the source build, which on the recon.db path may be a SKIP: the document of the last full pass with a new
# "generated" is the work file, no database copy, no query, no vendor pass; (3) on a built document only: the center extras, the homing reading, the
# vendor fields; (4) on a full build only: keep the base for the next skip, before any layer; (5) the layers: the window ends (bt_end), the traffic
# answer is waited for, add_layers (and the alert log is looked at: alerts_look); (6) publish, then the vendor cache merge. So a skipped cycle still
# carries fresh Bluetooth, activity and alerts layers. With both switches off and no alerts.log a skipped cycle publishes the same bytes as in 0.1. A skip leaves RS_DOCV as it is and RS_SKIPS keeps counting, so SKIP_MAX
# still forces a rebuild; the conditions of a skip are today's (the survey and the own-device fields forbid one; Bluetooth and traffic do not).
run_cycle() {
    ts=$(date +%s 2>/dev/null); [ -n "$ts" ] || ts=0
    tmp="$OUTFILE.tmp.$$"
    ok=1; CENTER_DONE=0; rc_skip=0; RQ_HOLD=""; RQ_TORN=""
    BT_CUR=" "; BT_RC=3; TR_PID=""
    if [ "$BLUETOOTH" = 1 ]; then bt_pick; [ "$BT_SRC" = window ] && { bt_begin; BT_RC=$?; }; fi
    # RECON CHANNELS is called on the first cycle and then every second one: the AP service's command-line client is about 48 ticks a call on the device, and its own
    # counting window is 20 to 30 s wide, so the cycle in between publishes the answer of the cycle before and loses nothing. An empty or missing file is called for.
    if [ "$TRAFFIC" = 1 ]; then
        if [ "$TR_REUSE" = 1 ] && [ -s "$TMPDIR_RAM/starchorus-traffic-$$.json" ]; then TR_REUSE=0
        else TR_REUSE=1; apcli_ro recon_channels 2>/dev/null > "$TMPDIR_RAM/starchorus-traffic-$$.json" & TR_PID=$!; fi
    fi
    case "$RESOLVED" in
        capture)
            if [ "$CAP_METHOD" = "airodump" ]; then
                build_from_csv "$ts" 2>/dev/null > "$tmp" || ok=0
            else
                build_from_tcpdump "$ts" 2>/dev/null > "$tmp" || ok=0
            fi
            ;;
        recondb)
            recon_sample "$ts"; RS_TAKEN=1      # the one look at recon.db's files this cycle: the skip test and the build use it
            if recon_unchanged "$ts" && refresh_generated "$ts" "$tmp"; then
                RS_SKIPS=$((RS_SKIPS + 1)); RS_TAKEN=0; rc_skip=1
            else
                RS_SIG=""
                CX_EMBED=1; CYC_NOW=$ts; build_from_recondb "$ts" 2>/dev/null > "$tmp" || ok=0; CX_EMBED=0; CYC_NOW=""
            fi ;;
        pineap)
            build_from_apcli "$ts" 2>/dev/null > "$tmp"; prc=$?
            if [ "$prc" = 0 ]; then PN_FELL=0
            else
                # no usable answer (failed, hung past the timeout, or no AP at all): recon.db for THIS cycle, said once per episode
                [ "$PN_FELL" = 1 ] || log "pineap: no usable answer from the AP service (rc $prc); using recon.db until it answers again"
                PN_FELL=1
                CX_EMBED=1; CYC_NOW=$ts; build_from_recondb "$ts" 2>/dev/null > "$tmp" || ok=0; CX_EMBED=0; CYC_NOW=""
            fi ;;
        # the ACTIVE source keeps its stderr: the builder's notice that this cycle transmits probe requests is meant for the log, every cycle
        iwscan)  build_from_iwscan  "$ts" > "$tmp" || ok=0 ;;
        *)       ok=0 ;;
    esac
    # What the recon.db copy had to say (build_from_recondb ran with its stderr dropped): said once per episode, like the Bluetooth messages
    [ "$RQ_TORN" != 1 ] || bt_issue torn "recon.db was written to while it was copied, twice in a row; the second copy is read all the same (a busy night)"
    [ -z "$RQ_HOLD" ] || bt_issue recondb "recon.db: the pass failed ($RQ_HOLD); the last document stays until a read succeeds"
    # ... and the pineap source's security lookup, which says so inside build_from_apcli as well, where this cycle drops it (PSEC_FAIL stays 1 until a lookup answers)
    [ "$PSEC_FAIL" != 1 ] || bt_issue psec "pineap: the security lookup in recon.db gave no answer; the labels already known stay (next try in a minute)"
    # Post-passes on a good, freshly built document, none of which can fail the cycle: the center extras (max_age,
    # interval, own_*), the homing reading of the ONE chosen AP, and the optional passive vendor /
    # randomized enrichment (skipped entirely with STARCHORUS_VENDOR=0; "defer": its new cache lines are
    # merged only AFTER the JSON is published, below). A skipped cycle's document has had them all.
    if [ "$ok" = "1" ] && [ "$rc_skip" = 0 ] && [ -s "$tmp" ]; then
        if [ "$CENTER_DONE" != 1 ]; then add_center < "$tmp" > "$tmp.c" 2>/dev/null; post_keep "$tmp" c $?; fi
        apply_homing "$tmp"
        if [ "$VENDOR" = "1" ]; then
            add_vendor defer < "$tmp" > "$tmp.v" 2>/dev/null; post_keep "$tmp" v $? || vendor_merge discard
        fi
    fi
    # Guard: never publish an empty, failed or cut-off temp over a good file. The base document must have the shape every builder gives it (doc_whole: "{"
    # first, "}" last, one "aps" line): a build that was cut short and still said 0 (a full /tmp, an awk that lost its output) fails it, and so does a pass whose
    # copy of recon.db could not be read (RQ_HOLD). Neither is an answer about the air: rc_hold says why, the document published last stays, and the cycle is
    # reported as failed. A pass that merely found nothing still publishes the explicit empty document, so that the front-end always has valid JSON.
    rs_good=0; rc_hold=""; rc_keep=0; rc_pub=0
    if [ "$ok" = 1 ] && [ -s "$tmp" ]; then rs_good=1; fi
    if [ "$rs_good" = 1 ] && ! doc_whole "$tmp"; then
        rs_good=0; rc_hold="cut short"
        bt_issue shape "the document of this cycle came out incomplete (a full disk, or a build that was cut short); the last document stays"
    fi
    if [ -n "$RQ_HOLD" ]; then rs_good=0; rc_hold=$RQ_HOLD; fi      # said where it was found (build_from_recondb)
    if [ "$rs_good" != 1 ] && [ -z "$rc_hold" ]; then
        { write_empty "$ts" "no data this cycle (source=$RESOLVED)" > "$tmp"; } 2>/dev/null
        if ! doc_whole "$tmp"; then
            rc_hold="cannot write"
            bt_issue publish "cannot write $tmp (the directory is read-only, full or gone); the last document stays"
        fi
    fi
    if [ -n "$rc_hold" ]; then
        rc_pub=1; vendor_merge discard      # the lines gathered for a document that is not published are not merged either
        # the last document stays; with none to keep, the explicit empty document is the better answer than a missing file
        if [ -s "$OUTFILE" ]; then rc_keep=1; else { write_empty "$ts" "no data this cycle (source=$RESOLVED)" > "$tmp"; } 2>/dev/null; fi
    fi
    # remember this pass for the skip test of the next cycle: its document (a skipped cycle publishes that one) and the state it stands on. A full build
    # only, and before any layer. Not with a homing reading, the survey or the own-device fields (the rule above recon_unchanged).
    rs_kept=0
    if [ "$rc_skip" = 0 ] && [ "$rs_good" = 1 ] && [ "$RESOLVED" = recondb ] && [ -n "$RS_NEW" ] && [ "$SKIP_UNCHANGED" = 1 ] && [ "$SURVEY" != 1 ] && [ "$OWN" != 1 ] \
       && homing_off && rs_keepdoc "$tmp" "$DOC_N"; then rs_kept=1; fi
    # the layers of this cycle, on the document that is published (never on the base kept above)
    alerts_look
    if [ "$BLUETOOTH" = 1 ] || [ "$TRAFFIC" = 1 ] || [ "$AL_ON" = 1 ]; then run_layers "$tmp"; fi
    if [ "$rc_keep" = 1 ]; then rm -f "$tmp" 2>/dev/null
    elif ! mv -f "$tmp" "$OUTFILE" 2>/dev/null; then    # atomic replace
        rc_pub=1; rm -f "$tmp" 2>/dev/null
        bt_issue publish "cannot write $OUTFILE (the directory is read-only, full or gone); the last document stays"
    fi
    BT_LOGGED=$BT_CUR
    if [ "$rs_kept" = 1 ]; then
        rs_cfg; RS_SIG=$RS_NEW; RS_TS=$ts; RS_SKIPS=0; RS_CFG=$RS_CFGNOW; RS_MIN=$RS_WMIN
    fi
    vendor_merge               # cache write AFTER publication: a lock wait costs the cache, not the view
    return "$rc_pub"           # 0 = the document of this cycle (or the explicit empty one) is published; 1 = it is not (--once exits 1)
}

# --------------------------------------------------------------------------- the loop's pace, and the hourly line
# The loop sleeps INTERVAL after a cycle; on a loaded device a cycle takes much longer than on an idle one (12.4 s wall for a pass that is 3.0 s of CPU, 14 October 2026: docs/device-notes.md section 6a), and
# the collector is then the load it is waiting for. So the sleep is the longer of INTERVAL and three times the wall time of the cycle just ended: nothing on an idle
# device, a backoff exactly when the device is busy. The wall time is read by the shell itself from /proc/uptime (builtins, no process; BT_PROC is the stand-in
# directory of the tests); where that cannot be read there is no backoff and no mean wall time. pace_end leaves PACE_MORE = the seconds to sleep beyond INTERVAL
# (the loop sleeps INTERVAL as before, then PACE_MORE), and center_extra announces INTERVAL + PACE_MORE as center.interval: the value the loop sleeps after the cycle before (the
# document of a cycle is written before pace_end has judged that cycle, so a slow cycle shows in the document of the next one). The wait for a Bluetooth window (bt_end_timed) and the listening of a tcpdump burst (build_from_tcpdump) are no load and do not count.
pace_now() {   # PACE_NOW = hundredths of a second since boot; "" and status 1 where /proc/uptime cannot be read
    PACE_NOW=""; pc_u=""
    { read -r pc_u _ < "$BT_PROC/uptime"; } 2>/dev/null
    case $pc_u in
        ''|*[!0-9.]*|.*|*.*.*) return 1 ;;
        *.*) pc_f="${pc_u#*.}00"; pc_f=${pc_f%"${pc_f#??}"}; PACE_NOW=$((${pc_u%%.*} * 100 + ${pc_f#0})) ;;
        *) PACE_NOW=$((pc_u * 100)) ;;
    esac
}
pace_begin() { PACE_BT=0; if pace_now; then PACE_T0=$PACE_NOW; else PACE_T0=""; fi; }
# bt_end with the time it takes measured: a Bluetooth cycle waits for its window (5 to 15 s) whatever the load, so that wait is no sign of a busy device. pace_end takes it off
# the wall time it judges (the hourly line still reports the whole wall time).
bt_end_timed() {
    if pace_now; then bw_a=$PACE_NOW; else bw_a=""; fi
    bt_end; bw_r=$?
    if [ -n "$bw_a" ] && pace_now && [ "$PACE_NOW" -ge "$bw_a" ]; then PACE_BT=$((PACE_BT + PACE_NOW - bw_a)); fi
    return "$bw_r"
}
# After a cycle: PACE_MORE, and the counters of the hourly line (rc_skip = run_cycle's own: 1 for a cycle that published the kept document).
pace_end() {
    PACE_MORE=0; pc_w=""
    if [ -n "$PACE_T0" ] && pace_now && [ "$PACE_NOW" -ge "$PACE_T0" ]; then pc_w=$((PACE_NOW - PACE_T0)); fi
    if [ -n "$pc_w" ]; then
        pc_n=$((pc_w - PACE_BT)); [ "$pc_n" -ge 0 ] || pc_n=0      # what the cycle took bar the window's waiting
        pc_need=$(( (pc_n * 3 + 99) / 100 ))
        [ "$pc_need" -le 3600 ] || pc_need=3600
        [ "$pc_need" -le "$INTERVAL" ] || PACE_MORE=$((pc_need - INTERVAL))
        TEL_WALL=$((TEL_WALL + pc_w)); TEL_NW=$((TEL_NW + 1))
    fi
    if [ "$rc_skip" = 1 ]; then TEL_SKIP=$((TEL_SKIP + 1)); else TEL_FULL=$((TEL_FULL + 1)); fi
    tel_hour
}
# One log line an hour (by the cycle's own clock, ts): how many cycles were full passes and how many were skipped because recon.db had not changed, and the mean wall
# time of a cycle. It tells how often the skip fires in a real night (docs/device-notes.md §6a had no count). No process: counters and one log call.
tel_hour() {
    case $ts in ''|*[!0-9]*|0) return 0 ;; esac
    if [ "$TEL_T0" -le 0 ] || [ "$ts" -lt "$TEL_T0" ]; then TEL_T0=$ts; return 0; fi      # the first cycle, or a clock that was set back: the hour begins here
    [ $((ts - TEL_T0)) -ge 3600 ] || return 0
    tl_m="not measured here"
    if [ "$TEL_NW" -gt 0 ]; then
        tl_a=$((TEL_WALL / TEL_NW)); tl_f=$((tl_a % 100)); [ "$tl_f" -ge 10 ] || tl_f=0$tl_f
        tl_m="$((tl_a / 100)).$tl_f s"
    fi
    log "last hour, cycles: $TEL_FULL full, $TEL_SKIP skipped (recon.db unchanged), mean wall time $tl_m"
    TEL_T0=$ts; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0
}
# One turn of the loop without its sleep (the self-test plays it with a stand-in clock).
cycle_step() { pace_begin; run_cycle; pace_end; }

# --------------------------------------------------------------------------- selftest support for the Bluetooth window (stubs only: nothing here can reach a controller)
# A stand-in tree under $1 (bin/ cfg/ log/ sig/ proc/ ram/ sys/ in/): `timeout`, and the two scan tools as shell scripts that do nothing but
# record themselves. The window code is run against a stand-in /proc (BT_PROC = $1/proc, one stat file per stub, in the real layout) because a
# development machine has none, and its signals go to files (BT_SIGMSG): a shell script started in the background cannot trap SIGINT (the shell
# ignores it for background jobs, and the scripts inherit that), so a stub that "ends on INT" reads its INT from a file instead. KILL is real.
# Every stub writes its own $$ to log/pid.<role> (S = the scan, M = the monitor, T = the timeout stand-in), its argv to log/argv.<role>, and a stat
# file whose state is Z once it has ended, as a real zombie shows. Modes, in cfg/ (one word per file; a missing file means "ok"):
#   S.mode / M.mode: ok (ends on INT or TERM), ignoreint (ends on TERM only), ignoreall (ends only when killed), fail (S: prints the error the
#                    scan prints when it cannot set its parameters, exits 1), silent (M: no output, no socket), banner (M: only the banner line
#                    "Bluetooth monitor ver 5.72", no socket: the device's state 0.1 to 0.5 s after the start)
#   T.mode: same (the stand-in becomes the tool, as the BusyBox applet makes its program, its watcher delivers the signal at the deadline), parent (the tool is its child;
#           forwards what arrives for the wrapper; returns 124 after delivering its signal), noforward (parent, but a signal that arrives for the
#           wrapper ends the wrapper and leaves the tool alone). Every signal that reaches a wrapper is written to log/wrapper.sigs.
#   M.text: what the monitor prints (the text of a window).
# A stand-in polls its tree (log/) and the shell that wrote it (STP, this shell) and ends by itself when either is gone, so that a run that is interrupted
# (st_abort removes the tree; a kill -9 does not) leaves nothing polling for ever.
bt_tmo() {
    printf '#!/bin/sh\nBTS=%s\nSTP=%s\n' "$1" "$$" > "$1/bin/timeout"
    cat >> "$1/bin/timeout" <<'BTTMO'
sig=TERM
if [ "$1" = -s ]; then sig=$2; shift 2; fi
n=$1; shift
case $1 in awk) if [ "$(cat "$BTS/cfg/slow" 2>/dev/null)" = 1 ]; then exit 124; fi; exec "$@" ;; esac
mode=$(cat "$BTS/cfg/T.mode" 2>/dev/null); [ -n "$mode" ] || mode=parent
echo "-s $sig $n $*" >> "$BTS/log/argv.T"
echo $$ >> "$BTS/log/pid.T"
mkdir -p "$BTS/proc/$$"
printf '%s (timeout) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0\n' "$$" "$PPID" "$$" > "$BTS/proc/$$/stat"
trap 'printf "%s (timeout) Z %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0\n" "$$" "$PPID" "$$" > "$BTS/proc/$$/stat"' EXIT
if [ "$mode" = same ]; then
    p=$$
    ( t0=$(date +%s); while kill -0 "$p" 2>/dev/null && [ $(($(date +%s) - t0)) -lt "$n" ]; do sleep 0.1 2>/dev/null || sleep 1; done
      if kill -0 "$p" 2>/dev/null; then echo "$sig" >> "$BTS/sig/$p"; fi ) &
    exec "$@"
fi
BTS_WPID=$$; export BTS_WPID
( "$@"; echo $? > "$BTS/rc.$$" ) &
t0=$(date +%s); sent=""
while [ ! -e "$BTS/rc.$$" ]; do
    [ -d "$BTS/log" ] && kill -0 "$STP" 2>/dev/null || exit 1
    tp=$(cat "$BTS/tool.$$" 2>/dev/null)
    if [ -s "$BTS/sig/$$" ]; then
        while read -r m; do
            echo "$m" >> "$BTS/log/wrapper.sigs"
            if [ "$mode" = parent ] && [ -n "$tp" ]; then echo "$m" >> "$BTS/sig/$tp"; fi
        done < "$BTS/sig/$$"
        : > "$BTS/sig/$$"
        [ "$mode" = parent ] || exit 143
    fi
    if [ -z "$sent" ] && [ -n "$tp" ] && [ $(($(date +%s) - t0)) -ge "$n" ]; then echo "$sig" >> "$BTS/sig/$tp"; sent=1; fi
    sleep 0.1 2>/dev/null || sleep 1
done
rc=$(cat "$BTS/rc.$$")
[ -z "$sent" ] || exit 124
exit "$rc"
BTTMO
    chmod +x "$1/bin/timeout"
}
# The two scan tools: one script body, the role (S or M) in its first lines. $1 as for bt_tmo; $2, when given, is the pid they watch in place of this shell's.
bt_stub() {
    for bs_i in 1 2; do
        if [ "$bs_i" = 1 ]; then bs_n=hcitool; bs_r=S; else bs_n=btmon; bs_r=M; fi
        printf '#!/bin/sh\nBTS=%s\nROLE=%s\nSTP=%s\n' "$1" "$bs_r" "${2:-$$}" > "$1/bin/$bs_n"
        cat >> "$1/bin/$bs_n" <<'BTSTUB'
echo "$*" >> "$BTS/log/argv.$ROLE"
echo $$ >> "$BTS/log/pid.$ROLE"
mode=$(cat "$BTS/cfg/$ROLE.mode" 2>/dev/null); [ -n "$mode" ] || mode=ok
pp=${BTS_WPID:-$PPID}
mkdir -p "$BTS/proc/$$/fd"
case $ROLE in S) cm=hcitool ;; M) cm=btmon ;; esac
printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0\n' "$$" "$cm" "$pp" "$$" > "$BTS/proc/$$/stat"
echo $$ > "$BTS/tool.$pp"
trap 'printf "%s (%s) Z %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0\n" "$$" "$cm" "$pp" "$$" > "$BTS/proc/$$/stat"' EXIT
grep '^SigIgn' "/proc/$$/status" > "$BTS/log/sigign.$ROLE" 2>/dev/null
if [ "$ROLE" = S ] && [ "$mode" = fail ]; then echo 'Set scan parameters failed: Input/output error' >&2; exit 1; fi
if [ "$ROLE" = M ] && [ "$mode" = banner ]; then echo 'Bluetooth monitor ver 5.72'; fi
if [ "$ROLE" = M ] && [ "$mode" != silent ] && [ "$mode" != banner ]; then
    if [ -S "$BTS/sock" ]; then ln -s "$BTS/sock" "$BTS/proc/$$/fd/3"; else ln -s 'socket:[1]' "$BTS/proc/$$/fd/3"; fi
    cat "$BTS/cfg/M.text" 2>/dev/null
fi
while :; do
    [ -d "$BTS/log" ] && kill -0 "$STP" 2>/dev/null || exit 0
    if [ -s "$BTS/sig/$$" ]; then
        while read -r m; do
            case $m in
                INT) [ "$mode" = ignoreint ] || [ "$mode" = ignoreall ] || exit 0 ;;
                TERM) [ "$mode" = ignoreall ] || exit 0 ;;
            esac
        done < "$BTS/sig/$$"
        : > "$BTS/sig/$$"
    fi
    sleep 0.1 2>/dev/null || sleep 1
done
BTSTUB
        chmod +x "$1/bin/$bs_n"
    done
}

# --------------------------------------------------------------------------- selftest: reading a window (bt_parse, bt_judge), text only, no process
# $1 = the selftest workspace. The windows are written here in btmon's own shape; synthetic addresses (locally administered), placeholder names
# ('Maker A', 'Sensor-1'), the test company id 65535. The worked example is the one of the design notes, with the [hci0] tag btmon prints when it
# was not started with -i; the other windows have no tag and a process prefix on the host's commands, as the real text of the device has.
bt_parse_selftest() {
    bpt="$1/bpt"; mkdir -p "$bpt"
    bpt_t=$RECON_TAB; bpt_n=0; bpt_at=Random
    bpt_hdr() { bpt_n=$((bpt_n + 1)); printf '%s %s  #%s 1.%06d\n' "$1" "$2" "$bpt_n" "$bpt_n"; }
    bpt_pre() {
        bpt_hdr '<' 'HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7'
        printf '        Type: Passive (0x00)\n        Interval: 10.000 msec (0x0010)\n        Window: 10.000 msec (0x0010)\n'
        bpt_hdr '<' 'HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2'
        printf '        Scanning: Enabled (0x01)\n        Filter duplicates: Disabled (0x00)\n'
    }
    bpt_post() { bpt_hdr '<' 'HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2'; printf '        Scanning: Disabled (0x00)\n        Filter duplicates: Disabled (0x00)\n'; }
    # $1 address, $2 suffix, $3 rssi, $4 event type text, then one argument per extra field line (they come before RSSI)
    bpt_rep() {
        bpt_a=$1; bpt_s=$2; bpt_r=$3; bpt_e=$4; shift 4
        bpt_hdr '>' 'HCI Event: LE Meta Event (0x3e) plen 30'
        printf '      LE Advertising Report (0x02)\n        Num reports: 1\n        Event type: %s\n        Address type: %s (0x01)\n        Address: %s (%s)\n        Data length: 3\n' "$bpt_e" "$bpt_at" "$bpt_a" "$bpt_s"
        for bpt_l in "$@"; do printf '%s\n' "$bpt_l"; done
        printf '        RSSI: %s dBm (0xc0)\n' "$bpt_r"
    }
    bpt_adv='Connectable undirected - ADV_IND (0x00)'
    # bpt_run FILE: parse, judge (stderr of the judge to $bpt/log), then BPT_W = the W line, BPT_NB = the number of B lines, BPT_BL = the B lines, bpt_jr = the judge's status
    bpt_run() {
        BT_CUR=" "; BT_LOGGED=" "; BT_NOTES=""; BT_BIG=0
        bt_parse "$1" > "$bpt/out"; bpt_pr=$?
        bt_judge "$bpt/out" 2> "$bpt/log"; bpt_jr=$?
        BPT_W=$(sed -n '/^W/p' "$bpt/out"); BPT_NB=$(grep -c '^B' "$bpt/out"); BPT_BL=$(sed -n '/^B/p' "$bpt/out")
    }
    bpt_f() { printf '%s\n' "$BPT_W" | cut -f"$1"; }

    # 1) the worked example of the design notes -> exactly three lines
    cat > "$bpt/we.txt" <<'BTWE'
Bluetooth monitor ver 5.72
= New Index: 00:00:00:00:00:00 (Primary,USB,hci0)                         [hci0] 0.651216
< HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7              #1 [hci0] 1.204556
        Type: Passive (0x00)
        Interval: 10.000 msec (0x0010)
        Window: 10.000 msec (0x0010)
        Own address type: Public (0x00)
        Filter policy: Accept all advertisement (0x00)
> HCI Event: Command Complete (0x0e) plen 4                             #2 [hci0] 1.205101
      LE Set Scan Parameters (0x08|0x000b) ncmd 1
        Status: Success (0x00)
< HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2                  #3 [hci0] 1.205233
        Scanning: Enabled (0x01)
        Filter duplicates: Disabled (0x00)
> HCI Event: LE Meta Event (0x3e) plen 38                               #5 [hci0] 1.312004
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Random (0x01)
        Address: 42:00:00:00:00:01 (Resolvable)
        Data length: 26
        Flags: 0x1a
          LE General Discoverable Mode
        Company: Maker A (65535)
          Data: 0102030405060708
        RSSI: -61 dBm (0xc3)
> HCI Event: LE Meta Event (0x3e) plen 38                               #6 [hci0] 1.417220
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Random (0x01)
        Address: 42:00:00:00:00:01 (Resolvable)
        Data length: 26
        Company: Maker A (65535)
          Data: 0102030405060708
        RSSI: -58 dBm (0xc6)
> HCI Event: LE Meta Event (0x3e) plen 30                               #7 [hci0] 1.902118
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Non connectable undirected - ADV_NONCONN_IND (0x03)
        Address type: Random (0x01)
        Address: C2:00:00:00:00:02 (Static)
        Data length: 18
        Name (complete): Sensor-1
        RSSI: -77 dBm (0xb3)
> HCI Event: LE Meta Event (0x3e) plen 13                               #8 [hci0] 2.004871
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable directed - ADV_DIRECT_IND (0x01)
        Address type: Public (0x00)
        Address: 02:00:00:00:00:03 (OUI 02-00-00)
        Data length: 0
        RSSI: -70 dBm (0xba)
< HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2                  #9 [hci0] 7.205002
        Scanning: Disabled (0x00)
        Filter duplicates: Disabled (0x00)
BTWE
    bpt_want=$(printf 'B\t42:00:00:00:00:01\trandom-resolvable\t-58\t2\t65535\tMaker A\t\t1\nB\tc2:00:00:00:00:02\trandom-static\t-77\t1\t\t\tSensor-1\t0\nW\t1\t0\t1\t1\t0\t0\t0\n')
    bpt_run "$bpt/we.txt"
    if [ "$(cat "$bpt/out")" = "$bpt_want" ] && [ "$bpt_pr" = 0 ] && [ "$bpt_jr" = 0 ] && [ ! -s "$bpt/log" ]; then st_pass "bt_parse: the worked example gives exactly the three lines (two addresses, the directed report dropped, a clean witness), and the window counts"; else st_fail "bt_parse: worked example [$(cat "$bpt/out")]"; fi
    # the same text without the prefilter (awk alone over every line): the same answer, the grammar does not depend on what the grep removes
    awk "$AWK_BT" "$bpt/we.txt" > "$bpt/out2"
    if cmp -s "$bpt/out" "$bpt/out2"; then st_pass "bt_parse: the grep prefilter changes nothing (the unfiltered text gives the same lines)"; else st_fail "bt_parse: filtered and unfiltered text differ"; fi

    # 3) a scan response: counted, not used; the window counts; one line in the log, none the second time round
    { bpt_n=0; bpt_pre; bpt_rep 02:00:00:00:00:11 Resolvable -50 "$bpt_adv"; bpt_rep 02:00:00:00:00:12 Resolvable -52 'Scan response - SCAN_RSP (0x04)'; bpt_post; } > "$bpt/w3.txt"
    bpt_run "$bpt/w3.txt"; bpt_l1=$(grep -c 'scan responses' "$bpt/log"); BT_LOGGED=$BT_CUR; bt_judge "$bpt/out" 2> "$bpt/log2"; bpt_l2=$(grep -c 'scan responses' "$bpt/log2")
    if [ "$BPT_NB" = 1 ] && [ "$(bpt_f 6)" = 1 ] && [ "$bpt_jr" = 0 ] && [ "$bpt_l1/$bpt_l2" = 1/0 ]; then st_pass "bt_parse: a SCAN_RSP report is counted (scanrsp 1) and not used, the window counts, one anomaly line per episode"; else st_fail "bt_parse: scan response (B $BPT_NB, W [$BPT_W], log $bpt_l1/$bpt_l2)"; fi

    # 4) an active scan parameters block, an extended scan parameters command: void
    { bpt_n=0; bpt_hdr '<' 'HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7'; printf '        Type: Active (0x01)\n'
      bpt_hdr '<' 'HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2'; printf '        Scanning: Enabled (0x01)\n'
      bpt_rep 02:00:00:00:00:21 Resolvable -50 "$bpt_adv"; bpt_post; } > "$bpt/w4a.txt"
    bpt_run "$bpt/w4a.txt"; bpt_va=$BT_VOID; bpt_ga=$(grep -c 'another scan was seen' "$bpt/log")
    { bpt_n=0; bpt_pre; bpt_hdr '<' 'HCI Command: LE Set Extended Scan Parameters (0x08|0x0041) plen 8'; printf '        Own address type: Public (0x00)\n'
      bpt_rep 02:00:00:00:00:22 Resolvable -50 "$bpt_adv"; bpt_post; } > "$bpt/w4b.txt"
    bpt_run "$bpt/w4b.txt"; bpt_vb=$BT_VOID
    if [ "$bpt_va/$bpt_vb/$bpt_ga" = other/other/1 ] && [ "$bpt_jr" = 1 ]; then st_pass "bt_judge: Type: Active in a parameters block, and an extended scan command, void the window ('another scan', logged)"; else st_fail "bt_judge: active/extended ($bpt_va/$bpt_vb/$bpt_ga)"; fi

    # 5) no parameters block (the monitor started late), and a passive block after the first report: void, fails closed
    { bpt_n=0; bpt_rep 02:00:00:00:00:31 Resolvable -50 "$bpt_adv"; bpt_post; } > "$bpt/w5a.txt"
    bpt_run "$bpt/w5a.txt"; bpt_va=$BT_VOID; bpt_ga=$(grep -c 'did not show a passive scan' "$bpt/log")
    { bpt_n=0; bpt_rep 02:00:00:00:00:32 Resolvable -50 "$bpt_adv"; bpt_pre; bpt_post; } > "$bpt/w5b.txt"
    bpt_run "$bpt/w5b.txt"; bpt_vb=$BT_VOID
    if [ "$bpt_va/$bpt_vb/$bpt_ga" = nopassive/nopassive/1 ] && [ "$(bpt_f 2)" = 0 ]; then st_pass "bt_judge: no passive parameters block, or one that stands after the first report, voids the window (the witness fails closed)"; else st_fail "bt_judge: late/missing parameters ($bpt_va/$bpt_vb/$bpt_ga, W [$BPT_W])"; fi

    # 6) an extended advertising report: another program drives the controller
    { bpt_n=0; bpt_pre; bpt_hdr '>' 'HCI Event: LE Meta Event (0x3e) plen 30'; printf '      LE Extended Advertising Report (0x0d)\n        Num reports: 1\n'
      bpt_rep 02:00:00:00:00:41 Resolvable -50 "$bpt_adv"; bpt_post; } > "$bpt/w6.txt"
    bpt_run "$bpt/w6.txt"
    if [ "$BT_VOID" = other ] && [ "$(bpt_f 8)" = 1 ] && grep -q 'another scan was seen' "$bpt/log"; then st_pass "bt_judge: an LE Extended Advertising Report void the window ('another scan')"; else st_fail "bt_judge: extended report (void [$BT_VOID], W [$BPT_W])"; fi

    # 7) forgery: an advertiser writes names, and a name may carry a line feed (what follows is a line of its own; a name is at most 29 bytes)
    bpt_ev='        Event type: Scan resp'
    { bpt_n=0; bpt_pre
      bpt_rep 02:00:00:00:00:51 Static -40 "$bpt_adv" '        Name (complete): evil' '        RSSI: -20 dBm (0xec)'
      bpt_rep 02:00:00:00:00:52 Static -41 "$bpt_adv" '        Name (complete): x' '        Type: Active (0x01)'
      bpt_rep 02:00:00:00:00:53 Static -42 "$bpt_adv" '        Name (complete): y' "$bpt_ev"
      bpt_rep 02:00:00:00:00:54 Static -43 "$bpt_adv" '        Name (complete): z' '        Company: Evil (1)'
      bpt_rep 02:00:00:00:00:55 Static -44 "$bpt_adv" '        Company: Real (7)' '        Name (complete): z' '        Company: Evil (1)'
      bpt_rep 02:00:00:00:00:56 Static -45 "$bpt_adv" "        Name (complete): a${bpt_t}b"
      bpt_rep 02:00:00:00:00:57 Static -46 "$bpt_adv"
      bpt_post; } > "$bpt/w7.txt"
    bpt_run "$bpt/w7.txt"
    bpt_dropped=0; for bpt_x in 51 52 53 55; do printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:$bpt_x" && bpt_dropped=1; done
    if [ "$bpt_dropped" = 0 ] && ! printf '%s\n' "$BPT_BL" | grep -q "${bpt_t}-20${bpt_t}" && [ "$(bpt_f 7)" = 4 ] && [ "$BT_VOID" = "" ] && [ "$(bpt_f 2)/$(bpt_f 3)/$(bpt_f 8)" = 1/0/0 ]; then
        st_pass "forgery: a forged RSSI, Type: Active, a cut Event type and a doubled Company line drop their own report only (suspect 4); no record at -20; the witness is unchanged"
    else st_fail "forgery: dropped [$bpt_dropped] W [$BPT_W] B [$BPT_BL]"; fi
    if printf '%s\n' "$BPT_BL" | grep -q "^B${bpt_t}02:00:00:00:00:54${bpt_t}random-static${bpt_t}-43${bpt_t}1${bpt_t}1${bpt_t}Evil${bpt_t}z${bpt_t}1" \
       && [ "$(printf '%s\n' "$BPT_BL" | grep -c '1[^0-9]*Evil')" = 1 ] && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:57${bpt_t}random-static${bpt_t}-46${bpt_t}1${bpt_t}${bpt_t}${bpt_t}${bpt_t}1"; then
        st_pass "forgery: a company line written into a name reaches its own record only (and only where the report has none); the plain records are untouched"
    else st_fail "forgery: company [$BPT_BL]"; fi
    if printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:56${bpt_t}random-static${bpt_t}-45${bpt_t}1${bpt_t}${bpt_t}${bpt_t}a b${bpt_t}1" && [ "$(printf '%s\n' "$BPT_BL" | awk -F"$bpt_t" '$1 == "B" && NF != 9 { n++ } END { print n + 0 }')" = 0 ]; then
        st_pass "forgery: a TAB in a name becomes a blank, every B line keeps its nine fields"
    else st_fail "forgery: TAB [$BPT_BL]"; fi
    # a forged Type: Passive cannot make a window passive: a window without a parameters block of its own stays void
    { bpt_n=0; bpt_rep 02:00:00:00:00:58 Static -40 "$bpt_adv" '        Name (complete): x' '        Type: Passive (0x00)'; bpt_post; } > "$bpt/w7b.txt"
    bpt_run "$bpt/w7b.txt"
    if [ "$BT_VOID" = nopassive ] && [ "$(bpt_f 2)" = 0 ]; then st_pass "forgery: a Type: Passive line in a name is not a witness (a window with no parameters block of its own is void)"; else st_fail "forgery: forged passive (void [$BT_VOID], W [$BPT_W])"; fi

    # 8) frame numbers that do not increase
    { bpt_n=0; bpt_pre; bpt_rep 02:00:00:00:00:61 Static -50 "$bpt_adv"; bpt_n=1; bpt_rep 02:00:00:00:00:62 Static -51 "$bpt_adv"; bpt_post; } > "$bpt/w8.txt"
    bpt_run "$bpt/w8.txt"
    if [ "$BT_VOID" = order ] && grep -q 'out of order' "$bpt/log"; then st_pass "bt_judge: a frame number that does not increase voids the window"; else st_fail "bt_judge: order (void [$BT_VOID], W [$BPT_W])"; fi

    # 9) RSSI invalid, an address of the wrong shape, a name with a quote, a backslash and a control byte, a name of 40 bytes
    bpt_long=0123456789012345678901234567890123456789
    { bpt_n=0; bpt_pre
      bpt_hdr '>' 'HCI Event: LE Meta Event (0x3e) plen 30'
      printf '      LE Advertising Report (0x02)\n        Num reports: 1\n        Event type: %s\n        Address type: Random (0x01)\n        Address: 02:00:00:00:00:71 (Static)\n        Data length: 3\n        RSSI: invalid (0x7f)\n' "$bpt_adv"
      bpt_rep 02:00:00:00:00 Static -50 "$bpt_adv"
      bpt_rep 02:00:00:00:00:73 Static -51 "$bpt_adv" "$(printf '        Name (complete): a"b\\c\033d')"
      bpt_rep 02:00:00:00:00:74 Static -52 "$bpt_adv" "        Name (complete): $bpt_long"
      bpt_post; } > "$bpt/w9.txt"
    bpt_run "$bpt/w9.txt"
    if ! printf '%s\n' "$BPT_BL" | grep -q '02:00:00:00:00:71' && [ "$BPT_NB" = 2 ] && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:73${bpt_t}random-static${bpt_t}-51${bpt_t}1${bpt_t}${bpt_t}${bpt_t}"'a"b\\cd'"${bpt_t}1" \
       && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:74${bpt_t}random-static${bpt_t}-52${bpt_t}1${bpt_t}${bpt_t}${bpt_t}01234567890123456789012345678901${bpt_t}1\$"; then
        st_pass "bt_parse: RSSI invalid and an address of the wrong shape are dropped, a name keeps its quote and backslash (escaped when written) and loses the control byte, a 40-byte name is cut at 32"
    else st_fail "bt_parse: edge cases [$BPT_BL]"; fi

    # 9b) a non-negative reading is the controller's "no reading" marker (127, 0, or a few dB above it): the report is dropped like RSSI: invalid, and is no suspect; an
    #     unknown company id (btmon: 'Company: not assigned (id)') keeps its id and has no company name, so that no consumer shows 'not assigned' as if it were one
    { bpt_n=0; bpt_pre
      bpt_rep 02:00:00:00:00:a1 Static 127 "$bpt_adv"
      bpt_rep 02:00:00:00:00:a2 Static 0 "$bpt_adv"
      bpt_rep 02:00:00:00:00:a3 Static 20 "$bpt_adv"
      bpt_rep 02:00:00:00:00:a4 Static -1 "$bpt_adv"
      bpt_rep 02:00:00:00:00:a5 Static -60 "$bpt_adv" '        Company: not assigned (4660)'
      bpt_rep 02:00:00:00:00:a6 Static -61 "$bpt_adv" '        Company: Maker A (65535)'
      bpt_post; } > "$bpt/w9b.txt"
    bpt_run "$bpt/w9b.txt"
    if [ "$BPT_NB" = 3 ] && ! printf '%s\n' "$BPT_BL" | grep -q -e ':a1' -e ':a2' -e ':a3' && [ "$(bpt_f 7)" = 0 ] \
       && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:a4${bpt_t}random-static${bpt_t}-1${bpt_t}1${bpt_t}${bpt_t}${bpt_t}${bpt_t}1\$" \
       && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:a5${bpt_t}random-static${bpt_t}-60${bpt_t}1${bpt_t}4660${bpt_t}${bpt_t}${bpt_t}1\$" \
       && printf '%s\n' "$BPT_BL" | grep -q "02:00:00:00:00:a6${bpt_t}random-static${bpt_t}-61${bpt_t}1${bpt_t}65535${bpt_t}Maker A${bpt_t}${bpt_t}1\$"; then
        st_pass "bt_parse: readings of 127, 0 and 20 dBm are dropped (no record, not suspect), -1 is kept; 'Company: not assigned (4660)' gives the id and no name, a named company keeps its name"
    else st_fail "bt_parse: non-negative RSSI and unnamed company (B $BPT_NB, suspect $(bpt_f 7), [$BPT_BL])"; fi

    # 10) an LE Direct Advertising Report event: nothing is read from it
    { bpt_n=0; bpt_pre; bpt_hdr '>' 'HCI Event: LE Meta Event (0x3e) plen 30'
      printf '      LE Direct Advertising Report (0x0b)\n        Num reports: 1\n        Event type: Connectable directed - ADV_DIRECT_IND (0x01)\n        Address type: Random (0x01)\n        Address: 02:00:00:00:00:81 (Static)\n        Direct address type: Random (0x01)\n        Direct address: 02:00:00:00:00:82 (Static)\n        RSSI: -50 dBm (0xce)\n'
      bpt_post; } > "$bpt/w10.txt"
    bpt_run "$bpt/w10.txt"
    if [ "$BPT_NB" = 0 ] && [ "$BT_VOID" = "" ] && [ "$(bpt_f 7)" = 0 ]; then st_pass "bt_parse: an LE Direct Advertising Report event is never entered (no record, no suspect, the window counts)"; else st_fail "bt_parse: direct report (B $BPT_NB, W [$BPT_W])"; fi

    # 11) no scan disable: the window counts, one 'may still be scanning' line
    { bpt_n=0; bpt_pre; bpt_rep 02:00:00:00:00:91 Static -50 "$bpt_adv"; } > "$bpt/w11.txt"
    bpt_run "$bpt/w11.txt"; bpt_l1=$(grep -c 'may still be scanning' "$bpt/log"); BT_LOGGED=$BT_CUR; bt_judge "$bpt/out" 2> "$bpt/log2"; bpt_l2=$(grep -c 'may still be scanning' "$bpt/log2")
    if [ "$BPT_NB" = 0 ] && [ "$(bpt_f 5)" = 0 ] && [ "$bpt_jr" = 0 ]; then bpt_ok=1; else bpt_ok=0; fi
    { bpt_n=0; bpt_pre; bpt_rep 02:00:00:00:00:91 Static -50 "$bpt_adv"; bpt_hdr '>' 'HCI Event: Command Complete (0x0e) plen 4'; } > "$bpt/w11b.txt"
    bpt_run "$bpt/w11b.txt"
    if [ "$bpt_ok" = 1 ] && [ "$BPT_NB" = 1 ] && [ "$bpt_jr" = 0 ] && [ "$bpt_l1/$bpt_l2" = 1/0 ]; then st_pass "bt_judge: no Scanning: Disabled -> the window counts (its reports were heard passively), one 'may still be scanning' line per episode"; else st_fail "bt_judge: no disable (ok $bpt_ok, B $BPT_NB, log $bpt_l1/$bpt_l2, W [$BPT_W])"; fi
    # 12) a name from the air with a newline inside: btmon prints names unfiltered (A10, the device's decode of a crafted btsnoop file, 18 October
    #     2026), so the rest of the name becomes a line of its own. A name is at most 29 bytes, so that line is at most 28 bytes: never a header (41
    #     and more), never an Event type that opens a report (38 with its " - NAME (0x0N)" tail), never an Address (34). A Type: or RSSI: line that
    #     fits is read inside the injecting report only, which is then dropped (suspect); the other reports and the witness are untouched, active
    #     stays 0, the window counts. A line at column 0 (no indentation) is no line of the grammar at all.
    { bpt_n=0; bpt_pre
      bpt_rep c2:00:00:00:00:41 Static -40 "$bpt_adv" '        Name (complete): ' '        Type: Active (0x01)'
      bpt_rep c2:00:00:00:00:42 Static -41 "$bpt_adv" '        Name (complete): ' '        RSSI: -30 dBm (0xe2)'
      bpt_rep c2:00:00:00:00:43 Static -42 "$bpt_adv" '        Name (complete): ' '        Type: Passive (0x00)'
      bpt_rep c2:00:00:00:00:44 Static -43 "$bpt_adv" '        Name (complete): ' '        Event type: X'
      bpt_rep c2:00:00:00:00:45 Static -44 "$bpt_adv" '        Name (complete): ' 'Address: c2:00:00:00:00:99'
      bpt_rep c2:00:00:00:00:46 Static -45 "$bpt_adv" '        Name (complete): Maker-Z'
      bpt_rep c2:00:00:00:00:47 Static -46 "$bpt_adv" '        Name (complete): AAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      bpt_post; } > "$bpt/w12.txt"
    bpt_run "$bpt/w12.txt"
    bpt_want=$(printf 'B\tc2:00:00:00:00:45\trandom-static\t-44\t1\t\t\t\t1\nB\tc2:00:00:00:00:46\trandom-static\t-45\t1\t\t\tMaker-Z\t1\nB\tc2:00:00:00:00:47\trandom-static\t-46\t1\t\t\tAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\t1\n')
    if [ "$BPT_BL" = "$bpt_want" ] && [ "$BPT_W" = "$(printf 'W\t1\t0\t1\t1\t0\t4\t0')" ] && [ "$bpt_jr" = 0 ] \
       && [ "$(grep -c '4 malformed reports dropped' "$bpt/log")" = 1 ] && [ "$(wc -l < "$bpt/log" | tr -d ' ')" = 1 ]; then
        st_pass "bt_parse: a name with a newline inside cannot act as a field outside its own report (Type: Active, RSSI, Type: Passive, Event type injected: four reports dropped, active 0, passive 1, the window counts; a line at column 0 is ignored; a 29-byte name is kept whole)"
    else st_fail "bt_parse: injected name lines [$BPT_W] judge $bpt_jr log [$(cat "$bpt/log")] lines [$BPT_BL]"; fi

    # 13) the main rule tests the first byte before it asks hdr(): a real header never starts with a blank (it starts with "<", ">" or a process prefix), so a
    #     header-shaped line with eight blanks in front is a field line with an unknown label, whatever else it says. This line is not one btmon writes (88
    #     bytes under an unknown label, more than any name the air can set); it pins the shortcut itself. It has its prefix, opcode, plen and frame number
    #     in place, so only the blanks keep it from being a header; a Type: Active line follows it. Read as a header it would open a parameters block that takes
    #     that line as its own (active 1: the window is void, 'another scan') and its frame number (#9) would put the next real header out of order. Read as a
    #     field line, the Type: line drops the injecting report (suspect 1) and nothing else: the clean report beside it is kept, passive stays 1, active 0,
    #     the window counts. 13b is the line btmon does write.
    { bpt_n=0; bpt_pre
      bpt_rep c2:00:00:00:00:b1 Static -40 "$bpt_adv"
      bpt_rep c2:00:00:00:00:b2 Static -41 "$bpt_adv" '        host[1]: < HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7  #9 1.000009' '        Type: Active (0x01)'
      bpt_post; } > "$bpt/w13.txt"
    bpt_run "$bpt/w13.txt"
    bpt_want=$(printf 'B\tc2:00:00:00:00:b1\trandom-static\t-40\t1\t\t\t\t1\n')
    if [ "$BPT_BL" = "$bpt_want" ] && [ "$BPT_W" = "$(printf 'W\t1\t0\t1\t1\t0\t1\t0')" ] && [ "$bpt_jr" = 0 ] && [ -z "$BT_VOID" ] \
       && [ "$(grep -c '1 malformed reports dropped' "$bpt/log")" = 1 ] && [ "$(wc -l < "$bpt/log" | tr -d ' ')" = 1 ]; then
        st_pass "bt_parse: a header-shaped line with eight blanks in front is no header (it opens no parameters block: passive 1, active 0, the frame number #9 not counted); the report that carries it is dropped as suspect, the clean report beside it is kept, the window counts"
    else st_fail "bt_parse: indented header-shaped line [$BPT_W] void [$BT_VOID] judge $bpt_jr log [$(cat "$bpt/log")] lines [$BPT_BL]"; fi

    # 13b) a header inside an advertised name (A10): btmon prints a name unfiltered, so the 29-byte name "]: < HCI Event: plen 1 #0 1.0" becomes the 54-byte line
    #      "        Name (complete): ]: < HCI Event: plen 1 #0 1.0" (and "]: > HCI Event: plen 1 #9 1.0" as Name (short), 51 bytes). Both pass the prefilter and are
    #      over 40 bytes, and a test that finds the marker "]: < HCI " anywhere in a line takes them for headers: each closes its own report and brings a frame
    #      number (#0, #9) that breaks the order of the real ones, so one advertiser in range could void every window ('monitor output out of order'). The
    #      blank at the first byte keeps them out of hdr(): both are Name lines, both reports are kept with the text as their name, nothing is suspect, no
    #      frame number moves, the window counts. The clean reports around them show that the real headers (#1 to #7) are read in order.
    { bpt_n=0; bpt_pre
      bpt_rep c2:00:00:00:00:c1 Static -40 "$bpt_adv"
      bpt_rep c2:00:00:00:00:c2 Static -41 "$bpt_adv" '        Name (complete): ]: < HCI Event: plen 1 #0 1.0'
      bpt_rep c2:00:00:00:00:c3 Static -42 "$bpt_adv" '        Name (short): ]: > HCI Event: plen 1 #9 1.0'
      bpt_rep c2:00:00:00:00:c4 Static -43 "$bpt_adv"
      bpt_post; } > "$bpt/w13b.txt"
    bpt_run "$bpt/w13b.txt"
    bpt_want=$(printf 'B\tc2:00:00:00:00:c1\trandom-static\t-40\t1\t\t\t\t1\nB\tc2:00:00:00:00:c2\trandom-static\t-41\t1\t\t\t]: < HCI Event: plen 1 #0 1.0\t1\nB\tc2:00:00:00:00:c3\trandom-static\t-42\t1\t\t\t]: > HCI Event: plen 1 #9 1.0\t1\nB\tc2:00:00:00:00:c4\trandom-static\t-43\t1\t\t\t\t1\n')
    if [ "$BPT_BL" = "$bpt_want" ] && [ "$BPT_W" = "$(printf 'W\t1\t0\t1\t1\t0\t0\t0')" ] && [ "$bpt_jr" = 0 ] && [ -z "$BT_VOID" ] && [ ! -s "$bpt/log" ]; then
        st_pass "bt_parse: a name that holds a header ('Name (complete): ]: < HCI Event: plen 1 #0 1.0', and a short one with '>' and #9) is a name, not a header: both reports are kept, no frame number moves, nothing is suspect, the window counts"
    else st_fail "bt_parse: header inside a name [$BPT_W] void [$BT_VOID] judge $bpt_jr log [$(cat "$bpt/log")] lines [$BPT_BL]"; fi

    unset -f bpt_hdr bpt_pre bpt_post bpt_rep bpt_run bpt_f
}

# --------------------------------------------------------------------------- selftest: the per-cycle layers (add_layers, run_layers), text and files only
# $1 = the selftest workspace. LAY = its scratch directory. lay_check is called by the blocks that build a document with an emitter (every source) and
# by write_empty's case: the layers must fit every document shape the collector can publish.
LAY=""
lay_prep() {   # a window file and the state add_layers reads, in $LAY
    BT_F="$LAY/ram/starchorus-bt-$$.txt"; TMPDIR_RAM="$LAY/ram"; ts=1789300030; BT_HELD=""; BT_WIN=6; BT_HOLD=120
    printf 'B\t42:00:00:00:00:01\trandom-resolvable\t-58\t2\t65535\tMaker A\t\t1\nB\tc2:00:00:00:00:02\trandom-static\t-77\t1\t\t\tSensor-1\t0\nW\t1\t0\t1\t1\t0\t0\t0\n' > "$BT_F.out"
    printf '{"0":5,"2412":600,"2437":300,"5180":100,"5955":0}\n' > "$LAY/ram/starchorus-traffic-$$.json"
}
# lay_check LABEL DOC: add_layers on a copy of DOC, mode 1 and traffic on: exactly two more lines, valid JSON, the center fields, the two arrays.
lay_check() {
    lc_ram=$TMPDIR_RAM; lc_bf=$BT_F; lc_ts=$ts; lc_held=$BT_HELD; lc_win=$BT_WIN; lc_hold=$BT_HOLD
    lay_prep; lay_d="$LAY/emit.json"; cp "$2" "$lay_d"; lay_n0=$(wc -l < "$lay_d" | tr -d ' ')
    lay_t=$TRAFFIC; TRAFFIC=1; add_layers "$lay_d" 1; lay_rc=$?; TRAFFIC=$lay_t
    lay_n1=$(wc -l < "$lay_d" | tr -d ' ')
    if [ "$lay_rc" = 0 ] && [ "$lay_n1" = $((lay_n0 + 2)) ] && json_ok < "$lay_d" && grep -q '^  "bluetooth": \[{"addr": "42:00:00:00:00:01"' "$lay_d" \
       && grep -q '^  "activity": \[{"freq": 2412, "share": 0.600}' "$lay_d" && grep -q '^  "center": {.*"bt_window": 6, "bt_hold": 120}' "$lay_d"; then
        st_pass "layers: $1 -> exactly the two added lines, valid JSON, bt_window and bt_hold in center"
    else st_fail "layers: $1 (rc $lay_rc, lines $lay_n0 -> $lay_n1)"; fi
    rm -f "$lay_d" "$LAY/ram"/starchorus-bt-* "$LAY/ram"/starchorus-traffic-* 2>/dev/null
    TMPDIR_RAM=$lc_ram; BT_F=$lc_bf; ts=$lc_ts; BT_HELD=$lc_held; BT_WIN=$lc_win; BT_HOLD=$lc_hold
}
lay_selftest() {
    LAY="$1/lay"; mkdir -p "$LAY/ram"
    lsv_ram=$TMPDIR_RAM; lsv_bf=$BT_F; lsv_ts=$ts; lsv_held=$BT_HELD; lsv_win=$BT_WIN; lsv_tr=$TRAFFIC; lsv_bl=$BLUETOOTH; lsv_cur=$BT_CUR; lsv_lg=$BT_LOGGED
    lay_prep
    lay_doc() { write_empty "$1" "layers"; }

    # bt_stat: the name field is whatever stands between the first "(" and the last ")" (blanks and brackets inside it), the fields follow the last ") "
    printf '4242 (a (b) c) S 77 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 9876 0\n' > "$LAY/stat"
    bt_statf "$LAY/stat"
    if [ "$BT_ST_COMM" = "a (b) c" ] && [ "$BT_ST_STATE" = S ] && [ "$BT_ST_PPID" = 77 ] && [ "$BT_ST_START" = 9876 ] && ! bt_statf "$LAY/no-such-stat"; then
        st_pass "bt_stat: the command name (blanks and brackets inside), the state, the parent and the start field of a stat line, nothing for a missing file"
    else st_fail "bt_stat: [$BT_ST_COMM] [$BT_ST_STATE] [$BT_ST_PPID] [$BT_ST_START]"; fi

    # the clock: whole hundredths from a fractional uptime, with a leading zero in the fraction, and the fake clock's naps
    printf '1234.07 4000.00\n' > "$LAY/uptime"; lay_p=$BT_PROC; BT_PROC=$LAY; bt_tick; lay_c1=$BT_NOW
    printf '0.76 1.00\n' > "$LAY/uptime"; bt_tick; lay_c2=$BT_NOW; BT_PROC=$lay_p
    BT_FAKE=1000; bt_nap; bt_nap; bt_tick; lay_c3=$BT_NOW; BT_FAKE=""
    if [ "$lay_c1/$lay_c2/$lay_c3" = 123407/76/1040 ]; then st_pass "bt_tick: hundredths of a second from /proc/uptime (builtins only), and a test clock that bt_nap moves on"; else st_fail "bt_tick: $lay_c1/$lay_c2/$lay_c3"; fi

    # bt_nap's length is its argument in hundredths of a second, 20 without one. On the test clock the nap moves BT_FAKE on by that. On the real one `sleep`
    # (a function here, so that nothing waits and its argument can be read) gets 0.2 for 20 and 0.5 for 50, and 1 for both once a fraction has failed (BT_FRAC drops to 0)
    lay_nl=""; lay_fok=1; lay_fr=$BT_FRAC
    sleep() { lay_nl="$lay_nl $1"; case $1 in *.*) [ "$lay_fok" = 1 ] ;; esac; }
    BT_FRAC=1; bt_nap; bt_nap 50; bt_nap 20; lay_nap1=$lay_nl
    lay_nl=""; lay_fok=0; BT_FRAC=1; bt_nap 50; lay_napf=$BT_FRAC; bt_nap; bt_nap 50; lay_nap2=$lay_nl
    unset -f sleep
    BT_FRAC=$lay_fr
    BT_FAKE=1000; bt_nap; bt_nap 50; bt_nap 20; lay_napc=$BT_FAKE; BT_FAKE=""
    if [ "$lay_nap1/$lay_nap2/$lay_napf/$lay_napc" = " 0.2 0.5 0.2/ 0.5 1 1 1/0/1090" ]; then
        st_pass "bt_nap: the nap is its argument in hundredths of a second (20 without one): 0.2 s, 0.5 s or, where fractions fail, 1 s on the real clock; 20 + 50 + 20 on the test clock"
    else st_fail "bt_nap: [$lay_nap1] [$lay_nap2] frac $lay_napf, test clock $lay_napc"; fi

    # STARCHORUS_BT_WINDOW: whole seconds from 5 to 15, anything else is 5, said once at start (a start that finds no source ends before any window is run)
    lay_o="$LAY/o"; mkdir -p "$lay_o"; lay_wok=1
    for lay_w in 20:5:1 4:5:1 abc:5:1 5:5:0 15:15:0 06:6:0 007:7:0 16:5:1; do
        lay_v=${lay_w%%:*}; lay_r=${lay_w#*:}; lay_x=${lay_r#*:}; lay_r=${lay_r%%:*}
        STARCHORUS_OUTDIR="$lay_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 \
            STARCHORUS_BLUETOOTH=1 STARCHORUS_BT_SOURCE=window STARCHORUS_BT_WINDOW=$lay_v sh "$0" --once > /dev/null 2> "$LAY/w.log"
        lay_m=0; grep -q "STARCHORUS_BT_WINDOW must be whole seconds from 5 to 15 (got '$lay_v'); using 5" "$LAY/w.log" && lay_m=1
        grep -q "one passive LE scan window of ${lay_r}s per cycle" "$LAY/w.log" || lay_wok=0
        [ "$lay_m" = "$lay_x" ] || lay_wok=0
    done
    STARCHORUS_OUTDIR="$lay_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_BT_WINDOW=20 sh "$0" --once > /dev/null 2> "$LAY/w.log"
    if [ "$lay_wok" = 1 ] && ! grep -q 'Bluetooth' "$LAY/w.log"; then st_pass "STARCHORUS_BT_WINDOW: 5 to 15 whole seconds are taken (a leading zero is no octal), anything else is 5 with one log line; with Bluetooth off the collector says nothing about it"; else st_fail "STARCHORUS_BT_WINDOW: ($lay_wok) $(grep Bluetooth "$LAY/w.log" | head -n 2)"; fi
    # the default: no STARCHORUS_BT_WINDOW at all, or an empty one, is a window of 5 s and no complaint (the loop above always names a value, so it cannot tell the default from the fallback)
    lay_dk=1
    for lay_dw in unset empty; do
        ( unset STARCHORUS_BT_WINDOW; [ "$lay_dw" = unset ] || export STARCHORUS_BT_WINDOW=
          STARCHORUS_OUTDIR="$lay_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 \
              STARCHORUS_BLUETOOTH=1 STARCHORUS_BT_SOURCE=window sh "$0" --once > /dev/null 2> "$LAY/w.log" )
        grep -q "one passive LE scan window of 5s per cycle" "$LAY/w.log" && ! grep -q 'must be whole seconds' "$LAY/w.log" || lay_dk=0
    done
    if [ "$lay_dk" = 1 ]; then st_pass "STARCHORUS_BT_WINDOW: unset, or empty, the window is 5 s and the collector logs no complaint about it"; else st_fail "STARCHORUS_BT_WINDOW: default ($lay_dk) $(grep Bluetooth "$LAY/w.log" | head -n 2)"; fi

    # 21) the hold. lay_win TS MODE [ADDR RSSI REPORTS]...: the window's file, add_layers on a fresh document, BT_HELD kept as run_layers keeps it
    lay_win() {
        lw_ts=$1; lw_m=$2; shift 2; ts=$lw_ts; : > "$BT_F.out"
        while [ $# -ge 3 ]; do printf 'B\t%s\trandom-static\t%s\t%s\t\t\t\t0\n' "$1" "$2" "$3" >> "$BT_F.out"; shift 3; done
        lay_doc "$lw_ts" > "$LAY/doc.json"
        if add_layers "$LAY/doc.json" "$lw_m"; then BT_HELD=$(cat "$LAY/ram/starchorus-bt-$$.new" 2>/dev/null); fi
    }
    lay_get() { grep '^  "bluetooth"' "$LAY/doc.json" | sed 's/}, {/}\
{/g' | grep "\"addr\": \"$1\""; }   # the record of an address, or nothing
    A=02:00:00:00:01:0a; B=02:00:00:00:01:0b; C=02:00:00:00:01:0c; t0=1789300000; TRAFFIC=0
    lay_win $t0 1 $A -50 2 $B -60 1 $C -70 3
    lay_r1=$(lay_get $A); lay_h1=$(printf '%s\n' "$BT_HELD" | grep -c .)
    lay_win $((t0 + 44)) 1 $A -55 1
    lay_a2=$(lay_get $A); lay_b2=$(lay_get $B); lay_c2=$(lay_get $C)
    lay_win $((t0 + 88)) 1 $B -62 4
    lay_a3=$(lay_get $A); lay_b3=$(lay_get $B); lay_c3=$(lay_get $C)
    lay_win $((t0 + 132)) 1
    lay_a4=$(lay_get $A); lay_b4=$(lay_get $B); lay_c4=$(lay_get $C)
    if [ "$lay_h1" = 3 ] && printf '%s' "$lay_r1" | grep -q '"rssi": -50, "reports": 2, "last_seen": 1789300000' \
       && printf '%s' "$lay_a2" | grep -q '"rssi": -55, "reports": 1, "last_seen": 1789300044' \
       && printf '%s' "$lay_b2" | grep -q '"rssi": -60, "reports": 1, "last_seen": 1789300000' && printf '%s' "$lay_c2" | grep -q '"reports": 3, "last_seen": 1789300000' \
       && printf '%s' "$lay_b3" | grep -q '"rssi": -62, "reports": 4, "last_seen": 1789300088' && printf '%s' "$lay_a3" | grep -q '"last_seen": 1789300044' \
       && printf '%s' "$lay_c3" | grep -q '"last_seen": 1789300000' && [ -z "$lay_c4" ] && [ -n "$lay_a4" ] && [ -n "$lay_b4" ]; then
        st_pass "hold: addresses that go and come back keep their own window's rssi, reports and last_seen; a record is carried while it is at most 120 s old and then dropped"
    else st_fail "hold: [$lay_a2] [$lay_b2] [$lay_c2] [$lay_a3] [$lay_b3] [$lay_c3] [$lay_a4] [$lay_b4] [$lay_c4]"; fi
    # at most 4 carries, whatever the age (a window every 10 s: the fifth carry would be at 50 s)
    BT_HELD=""; lay_win $t0 1 $A -50 1; lay_k=""
    lay_i=1; while [ "$lay_i" -le 6 ]; do lay_win $((t0 + 10 * lay_i)) 1; if [ -n "$(lay_get $A)" ]; then lay_k="$lay_k$lay_i"; fi; lay_i=$((lay_i + 1)); done
    if [ "$lay_k" = 1234 ]; then st_pass "hold: at most 4 carries (the record survives 4 empty windows 10 s apart, not a fifth, though it is only 50 s old)"; else st_fail "hold: carries survived [$lay_k], want 1234"; fi
    # a clock that went back: a held line from the future is dropped, not kept alive
    BT_HELD=""; lay_win $((t0 + 500)) 1 $A -50 1; lay_win $t0 1 $B -60 1
    if [ -z "$(lay_get $A)" ] && [ -n "$(lay_get $B)" ]; then st_pass "hold: a window end earlier than the held lines (the clock went back) drops those lines"; else st_fail "hold: clock back [$(lay_get $A)]"; fi
    # a void window carries the held lines and says bt_window 0; no held lines gives an empty array, never none
    BT_HELD=""; lay_win $t0 1 $A -50 1 $B -60 1; lay_win $((t0 + 30)) 2
    if [ -n "$(lay_get $A)" ] && [ -n "$(lay_get $B)" ] && grep -q '^  "center": {.*"bt_window": 0, "bt_hold": 120}' "$LAY/doc.json" && json_ok < "$LAY/doc.json"; then
        st_pass "hold: a void window carries the held records, center.bt_window is 0, the layer does not blink"
    else st_fail "hold: void window"; fi
    BT_HELD=""; lay_win $t0 2
    if grep -q '^  "bluetooth": \[\],$' "$LAY/doc.json" && grep -q '"bt_window": 0' "$LAY/doc.json"; then st_pass "hold: a void window with nothing held writes the empty array"; else st_fail "hold: empty array"; fi
    # 300 addresses: the strongest 256, order rssi descending then address
    lay_i=0; : > "$LAY/b300"
    while [ "$lay_i" -lt 300 ]; do printf 'B\t02:00:00:00:%02x:%02x\trandom-static\t-%s\t1\t\t\t\t0\n' $((lay_i / 100)) $((lay_i % 100)) $((30 + (lay_i * 7) % 61)) >> "$LAY/b300"; lay_i=$((lay_i + 1)); done
    ts=$t0; BT_HELD=""; cp "$LAY/b300" "$BT_F.out"; lay_doc $t0 > "$LAY/doc.json"; add_layers "$LAY/doc.json" 1
    sed -n 's/^  "bluetooth": //p' "$LAY/doc.json" | sed 's/}, {/}\
{/g' | sed -n 's/.*"addr": "\([^"]*\)".*"rssi": \(-[0-9]*\),.*/\2 \1/p' > "$LAY/b300.out"
    lay_cnt=$(wc -l < "$LAY/b300.out" | tr -d ' '); LC_ALL=C sort -k1,1nr -k2,2 "$LAY/b300.out" > "$LAY/b300.sorted"
    awk -F'\t' '{ print $4, $2 }' "$LAY/b300" | LC_ALL=C sort -k1,1nr -k2,2 | head -n 256 > "$LAY/b300.want"
    if [ "$lay_cnt" = 256 ] && cmp -s "$LAY/b300.out" "$LAY/b300.sorted" && cmp -s "$LAY/b300.out" "$LAY/b300.want" && json_ok < "$LAY/doc.json"; then
        st_pass "hold: 300 addresses -> the strongest 256, in the order rssi then address"
    else st_fail "hold: cap (count $lay_cnt)"; fi

    # 25b) blue5 source: bt_blue5_read maps blue5.db (read-only, a copy) to the bluetooth layer; add_layers marks center bt_source=blue5, no bt_window
    if [ -n "$LAY_BLUE5_FIX" ] && [ -e "$LAY_BLUE5_FIX" ]; then
        b5="$LAY/blue5"; mkdir -p "$b5" "$LAY/ram"; b5_db="$LAY_BLUE5_FIX"; b5_ts=1000000
        b5_sBL=$BLUE5_DB; b5_sTR=$TMPDIR_RAM; b5_sBF=$BT_F; b5_sMX=$BT5_MAX; b5_sH=$BT_HELD
        BLUE5_DB="$b5_db"; TMPDIR_RAM="$LAY/ram"; BT5_MAX=4194304; BT_HELD=""; ts=$b5_ts
        if bt_blue5_read "$b5_ts"; then b5_rc=0; else b5_rc=1; fi
        lay_doc $b5_ts > "$b5/doc.json"; add_layers "$b5/doc.json" 1 blue5; b5_ar=$?
        b5_line=$(grep '^  "bluetooth": ' "$b5/doc.json")
        b5_cnt=$(printf '%s' "$b5_line" | grep -o '"addr":' | grep -c .)
        b5_src=0; grep -q '"bt_source": "blue5"' "$b5/doc.json" && b5_src=1
        b5_win=0; grep -q 'bt_window' "$b5/doc.json" && b5_win=1
        b5_dup=0; printf '%s' "$b5_line" | grep -q '"addr": "aa:bb:cc:00:00:0a", "addr_type": "public", "rssi": -40, "reports": 7' && b5_dup=1
        b5_sub=0; printf '%s' "$b5_line" | grep -q '"addr": "c0:aa:bb:00:00:02", "addr_type": "random-static"' && printf '%s' "$b5_line" | grep -q '"addr": "40:aa:bb:00:00:03", "addr_type": "random-resolvable"' && b5_sub=1
        b5_nm=0; printf '%s' "$b5_line" | grep -q '"name": "t n"' && b5_nm=1
        b5_ex=0; printf '%s' "$b5_line" | grep -q -e ':00:06' -e ':00:07' -e ':00:09' && b5_ex=1
        if [ "$b5_rc" = 0 ] && [ "$b5_ar" = 0 ] && [ "$b5_cnt" = 5 ] && [ "$b5_src" = 1 ] && [ "$b5_win" = 0 ] && [ "$b5_dup" = 1 ] && [ "$b5_sub" = 1 ] && [ "$b5_nm" = 1 ] && [ "$b5_ex" = 0 ] && json_ok < "$b5/doc.json"; then
            st_pass "blue5: bt_blue5_read maps blue5.db read-only to 5 records (newest per address, LE/rssi/age/MAC filtered, subtype from the address top bits, TAB in a name -> space, 0/65535 company dropped); center bt_source=blue5, no bt_window"
        else st_fail "blue5 read: rc $b5_rc ar $b5_ar cnt $b5_cnt src $b5_src win $b5_win dup $b5_dup sub $b5_sub nm $b5_nm ex $b5_ex"; fi
        # the company list names the identifier the database holds (76 = 004C): that record gets company_name; an identifier the list lacks (12) stays bare
        printf '0000\tEricsson AB\n004C\tApple, Inc.\n0076\tCreative Technology Ltd.\n' > "$b5/companies.txt"; b5_sCP=$BTCO_PATH; BTCO_PATH="$b5/companies.txt"; BT_HELD=""
        bt_blue5_read "$b5_ts"; b5_nrc=$?; lay_doc $b5_ts > "$b5/doc2.json"; add_layers "$b5/doc2.json" 1 blue5
        b5_l2=$(grep '^  "bluetooth": ' "$b5/doc2.json")
        b5_apl=0; printf '%s' "$b5_l2" | grep -q '"addr": "aa:bb:cc:00:00:0a", "addr_type": "public", "rssi": -40, "reports": 7, "last_seen": [0-9]*, "company": 76, "company_name": "Apple, Inc."' && b5_apl=1
        b5_bare=0; printf '%s' "$b5_l2" | grep -q '"addr": "c0:aa:bb:00:00:02"[^}]*"company": 12,' && ! printf '%s' "$b5_l2" | grep -q '"addr": "c0:aa:bb:00:00:02"[^}]*"company_name"' && b5_bare=1
        BTCO_PATH=$b5_sCP
        if [ "$b5_nrc" = 0 ] && [ "$b5_apl" = 1 ] && [ "$b5_bare" = 1 ] && json_ok < "$b5/doc2.json"; then
            st_pass "blue5: the company list names an identifier the database holds (76 -> Apple, Inc.) and leaves one it lacks (12) bare"
        else st_fail "blue5 companies: rc $b5_nrc apple $b5_apl bare $b5_bare"; fi
        BLUE5_DB="$b5/none-such.db"; bt_blue5_read "$b5_ts"; b5_fc=$?
        if [ "$b5_fc" != 0 ]; then st_pass "blue5: a missing blue5.db -> bt_blue5_read fails closed (no Bluetooth this cycle, the live file is never read)"; else st_fail "blue5: fail-closed rc $b5_fc"; fi
        BLUE5_DB=$b5_sBL; TMPDIR_RAM=$b5_sTR; BT_F=$b5_sBF; BT5_MAX=$b5_sMX; BT_HELD=$b5_sH
    fi

    # 26) traffic: RECON CHANNELS through run_layers (Bluetooth off)
    BLUETOOTH=0; TRAFFIC=1; BT_RC=3; TR_PID=""; ts=$t0; lay_tf="$LAY/ram/starchorus-traffic-$$.json"
    lay_tr() {   # $1 = the answer, $2 = a name; document -> $LAY/tr.json, the layers' log -> $LAY/tr.log
        printf '%s\n' "$1" > "$lay_tf"; printf '{\n  "generated": 1,\n  "center": {"label": "x"},\n  "channels": [{"freq": 2412, "last_heard": 7}],\n  "aps": [\n  ],\n  "unassociated": [\n  ]\n}\n' > "$LAY/tr.json"
        BT_CUR=" "; run_layers "$LAY/tr.json" 2> "$LAY/tr.log"; BT_LOGGED=$BT_CUR
    }
    lay_tr '{"0":5,"2412":600,"2437":300,"5180":100,"5955":0}' ok
    if grep -q '^  "activity": \[{"freq": 2412, "share": 0.600}, {"freq": 2437, "share": 0.300}, {"freq": 5180, "share": 0.100}\],$' "$LAY/tr.json" \
       && grep -q '^  "channels": \[{"freq": 2412, "last_heard": 7}\],$' "$LAY/tr.json" && ! grep -q '"bluetooth"' "$LAY/tr.json" && ! grep -q 'bt_window' "$LAY/tr.json" && json_ok < "$LAY/tr.json" && [ ! -s "$LAY/tr.log" ]; then
        st_pass "traffic: the answer {\"0\":5,\"2412\":600,...} gives the shares 0.600 / 0.300 / 0.100 (the key 0 and the 6 GHz zero left out), channels[] untouched, no Bluetooth fields while Bluetooth is off"
    else st_fail "traffic: shares ($(grep activity "$LAY/tr.json"))"; fi
    lay_ok=1
    for lay_a in '[]' '{"2412":"x"}' '' '{}' 'not json' '{"2412":600,}' '{"2412":6.5}'; do
        BT_LOGGED=" "; lay_tr "$lay_a" bad
        grep -q '"activity"' "$LAY/tr.json" && lay_ok=0
        [ "$(grep -c 'gave no usable channel list' "$LAY/tr.log")" = 1 ] || lay_ok=0
        json_ok < "$LAY/tr.json" || lay_ok=0
    done
    lay_tr '{"2412":600}' x; lay_tr '[]' bad; lay_tr '[]' again; lay_l=$(grep -c 'gave no usable channel list' "$LAY/tr.log")
    lay_tr '{"0":9,"2412":0}' zero
    if [ "$lay_ok" = 1 ] && [ "$lay_l" = 0 ] && ! grep -q '"activity"' "$LAY/tr.json" && [ ! -s "$LAY/tr.log" ]; then
        st_pass "traffic: [], an object with a text value or a decimal, an empty answer, {}, a trailing comma: no array and one log line each; the same fault again is not logged again; a zero sum is no array and no complaint"
    else st_fail "traffic: bad answers (ok $lay_ok, again-log $lay_l)"; fi
    printf '{"2412":1,"2437":999999}\n' > "$lay_tf"; printf '{\n  "generated": 1,\n  "aps": [\n  ]\n}\n' > "$LAY/tr.json"; run_layers "$LAY/tr.json" 2>/dev/null
    if grep -q '"activity": \[{"freq": 2437, "share": 1.000}\]' "$LAY/tr.json"; then st_pass "traffic: a share below 0.001 is not written (2412 holds one frame in a million)"; else st_fail "traffic: small share ($(grep activity "$LAY/tr.json"))"; fi

    # a hung AP service: the cycle publishes on time and without the array (a stand-in for the device's timeout cuts the call after 1 s here, the
    # collector asks for 10), and the gate: turning Traffic on makes the call, STARCHORUS_APCLI_RO stays off
    mkdir -p "$LAY/hb"; apcli_stub "$LAY/hb" "$LAY/hlog" hang
    # shellcheck disable=SC2016  # the stand-in script text is written out literally
    printf '#!/bin/sh\nshift\n"$@" &\np=$!\n( sleep 1; kill "$p" 2>/dev/null ) &\nw=$!\nwait "$p"\nkill "$w" 2>/dev/null\nexit 0\n' > "$LAY/hb/timeout"; chmod +x "$LAY/hb/timeout"
    lay_pa=$PATH; lay_ao=$APCLI_RO; lay_rs=$RESOLVED; lay_cm=$CAP_METHOD; lay_of=$OUTFILE; lay_od=$OUTDIR; lay_ve=$VENDOR
    PATH="$LAY/hb:$PATH"; APCLI_RO=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$LAY/hung.json"; OUTDIR="$LAY"; VENDOR=0; TRAFFIC=1; TR_REUSE=0
    lay_a=$(command date +%s); BT_LOGGED=" "; run_cycle 2> "$LAY/hung.log" >/dev/null; lay_b=$(command date +%s)
    PATH=$lay_pa; APCLI_RO=$lay_ao; RESOLVED=$lay_rs; CAP_METHOD=$lay_cm; OUTFILE=$lay_of; OUTDIR=$lay_od; VENDOR=$lay_ve
    if [ $((lay_b - lay_a)) -le 4 ] && json_ok < "$LAY/hung.json" && ! grep -q '"activity"' "$LAY/hung.json" && grep -q 'gave no usable channel list' "$LAY/hung.log" \
       && [ "$(head -n 1 "$LAY/hlog" 2>/dev/null)" = "RECON CHANNELS format=json" ]; then
        st_pass "traffic: a hung AP service costs the cycle one cut-off call: published in $((lay_b - lay_a)) s, no array, one log line (the call was made with only Traffic on)"
    else st_fail "traffic: hung call ($((lay_b - lay_a)) s, [$(head -n 1 "$LAY/hlog" 2>/dev/null)], $(cat "$LAY/hung.log" | head -n 3))"; fi

    # the answer of the AP service reaches the document through a whole cycle (only Traffic on; the one literal call is all the stub sees)
    mkdir -p "$LAY/tb"; printf '{"0":3,"2437":300,"5180":100}\n' > "$LAY/chan.json"; apcli_stub "$LAY/tb" "$LAY/tlog" "" "" "$LAY/chan.json"
    lay_pa=$PATH; lay_ao=$APCLI_RO; lay_rs=$RESOLVED; lay_cm=$CAP_METHOD; lay_of=$OUTFILE; lay_od=$OUTDIR; lay_ve=$VENDOR
    PATH="$LAY/tb:$PATH"; APCLI_RO=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$LAY/chan.out"; OUTDIR="$LAY"; VENDOR=0; TRAFFIC=1; TR_REUSE=0; : > "$LAY/tlog"
    run_cycle 2> /dev/null > /dev/null
    PATH=$lay_pa; APCLI_RO=$lay_ao; RESOLVED=$lay_rs; CAP_METHOD=$lay_cm; OUTFILE=$lay_of; OUTDIR=$lay_od; VENDOR=$lay_ve
    if json_ok < "$LAY/chan.out" && grep -q '^  "activity": \[{"freq": 2437, "share": 0.750}, {"freq": 5180, "share": 0.250}\],$' "$LAY/chan.out" && [ "$(cat "$LAY/tlog")" = "RECON CHANNELS format=json" ] \
       && ! grep -q '"bluetooth"' "$LAY/chan.out"; then
        st_pass "traffic: a whole cycle with only Traffic on makes the one literal call, and the document carries the shares (0.750 / 0.250), no Bluetooth field"
    else st_fail "traffic: whole cycle ([$(cat "$LAY/tlog")], $(grep activity "$LAY/chan.out"))"; fi

    # the cadence: three cycles against the same stand-in. The call is made on the first cycle and on the third, not on the second, which publishes the answer of the first
    # (the stand-in's answer changes after the first cycle, so a reused file and a new call tell apart); every one of the three documents carries activity[]
    lay_pa=$PATH; lay_ao=$APCLI_RO; lay_rs=$RESOLVED; lay_cm=$CAP_METHOD; lay_of=$OUTFILE; lay_od=$OUTDIR; lay_ve=$VENDOR
    PATH="$LAY/tb:$PATH"; APCLI_RO=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$LAY/alt.out"; OUTDIR="$LAY"; VENDOR=0; TRAFFIC=1; TR_REUSE=0; : > "$LAY/tlog"
    printf '{"0":3,"2437":300,"5180":100}\n' > "$LAY/chan.json"
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt1.json"; lay_n1=$(wc -l < "$LAY/tlog" | tr -d ' ')
    printf '{"2412":100,"2437":100}\n' > "$LAY/chan.json"
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt2.json"; lay_n2=$(wc -l < "$LAY/tlog" | tr -d ' ')
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt3.json"; lay_n3=$(wc -l < "$LAY/tlog" | tr -d ' ')
    PATH=$lay_pa; APCLI_RO=$lay_ao; RESOLVED=$lay_rs; CAP_METHOD=$lay_cm; OUTFILE=$lay_of; OUTDIR=$lay_od; VENDOR=$lay_ve; TR_REUSE=0; rm -f "$LAY/ram/starchorus-traffic-$$.json"
    if [ "$lay_n1/$lay_n2/$lay_n3" = 1/1/2 ] && [ "$(sort -u "$LAY/tlog")" = "RECON CHANNELS format=json" ] && json_ok < "$LAY/alt1.json" && json_ok < "$LAY/alt2.json" && json_ok < "$LAY/alt3.json" \
       && grep -q '^  "activity": \[{"freq": 2437, "share": 0.750}, {"freq": 5180, "share": 0.250}\],$' "$LAY/alt1.json" \
       && grep -q '^  "activity": \[{"freq": 2437, "share": 0.750}, {"freq": 5180, "share": 0.250}\],$' "$LAY/alt2.json" \
       && grep -q '^  "activity": \[{"freq": 2412, "share": 0.500}, {"freq": 2437, "share": 0.500}\],$' "$LAY/alt3.json"; then
        st_pass "traffic: every second cycle: three cycles with Traffic on call the AP service on the first and the third ($lay_n1/$lay_n2/$lay_n3 calls after each), the second publishes the first's answer, activity[] is in all three documents"
    else st_fail "traffic: every second cycle (calls after each cycle $lay_n1/$lay_n2/$lay_n3, want 1/1/2; $(grep -h activity "$LAY/alt1.json" "$LAY/alt2.json" "$LAY/alt3.json" | cut -c1-110 | tr '\n' '|'))"; fi
    # an answer that gave nothing is not carried: the cycle after it calls again, and the answer it gets is carried to the one after that
    PATH="$LAY/tb:$PATH"; APCLI_RO=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$LAY/alt.out"; OUTDIR="$LAY"; VENDOR=0; TRAFFIC=1; TR_REUSE=0; : > "$LAY/tlog"; BT_LOGGED=" "
    printf '[]\n' > "$LAY/chan.json"
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt1.json"; lay_n1=$(wc -l < "$LAY/tlog" | tr -d ' ')
    printf '{"2412":100,"2437":100}\n' > "$LAY/chan.json"
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt2.json"; lay_n2=$(wc -l < "$LAY/tlog" | tr -d ' ')
    run_cycle 2> /dev/null > /dev/null; cp "$OUTFILE" "$LAY/alt3.json"; lay_n3=$(wc -l < "$LAY/tlog" | tr -d ' ')
    PATH=$lay_pa; APCLI_RO=$lay_ao; RESOLVED=$lay_rs; CAP_METHOD=$lay_cm; OUTFILE=$lay_of; OUTDIR=$lay_od; VENDOR=$lay_ve; TR_REUSE=0; rm -f "$LAY/ram/starchorus-traffic-$$.json"
    if [ "$lay_n1/$lay_n2/$lay_n3" = 1/2/2 ] && json_ok < "$LAY/alt1.json" && ! grep -q '"activity"' "$LAY/alt1.json" \
       && grep -q '^  "activity": \[{"freq": 2412, "share": 0.500}, {"freq": 2437, "share": 0.500}\],$' "$LAY/alt2.json" \
       && grep -q '^  "activity": \[{"freq": 2412, "share": 0.500}, {"freq": 2437, "share": 0.500}\],$' "$LAY/alt3.json"; then
        st_pass "traffic: every second cycle: an answer that gave nothing usable is not carried (no array that cycle, the next one calls again: $lay_n1/$lay_n2/$lay_n3 calls after each), and the usable answer after it is carried to the cycle after that"
    else st_fail "traffic: bad answer then good (calls after each cycle $lay_n1/$lay_n2/$lay_n3, want 1/2/2; $(grep -h activity "$LAY/alt1.json" "$LAY/alt2.json" "$LAY/alt3.json" | cut -c1-110 | tr '\n' '|'))"; fi

    # 29) a window of 2 MiB: the first 256 KiB and the end are read, the disable block at the end is found, 'busy air' once
    awk 'BEGIN { pad = ""; for (i = 0; i < 100; i++) pad = pad "00"
        n = 1; printf "< HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7  #%d 1.%06d\n        Type: Passive (0x00)\n", n, n; n++
        printf "< HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2  #%d 1.%06d\n        Scanning: Enabled (0x01)\n", n, n; n++
        for (i = 0; i < 3700; i++) { printf "> HCI Event: LE Meta Event (0x3e) plen 30  #%d 2.%06d\n      LE Advertising Report (0x02)\n        Num reports: 1\n        Event type: Connectable undirected - ADV_IND (0x00)\n        Address type: Random (0x01)\n        Address: 02:00:00:00:%02x:%02x (Static)\n        Data length: 3\n        Company: Maker A (65535)\n          Data: %s\n        RSSI: -%d dBm (0xc0)\n", n, n, int(i / 100), i % 100, pad, 30 + i % 60; n++ }
        printf "< HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2  #%d 9.%06d\n        Scanning: Disabled (0x00)\n", n, n }' > "$LAY/big.txt"
    lay_sz=$(wc -c < "$LAY/big.txt" | tr -d ' ')
    BT_CUR=" "; BT_LOGGED=" "; BT_NOTES=""; lay_a=$(command date +%s); bt_parse "$LAY/big.txt" > "$LAY/big.out"; lay_pr=$?; lay_b=$(command date +%s); bt_judge "$LAY/big.out" 2> "$LAY/big.log"; lay_jr=$?
    lay_w=$(sed -n '/^W/p' "$LAY/big.out"); lay_rep=$(awk -F'\t' '$1 == "B" { n += $5 } END { print n + 0 }' "$LAY/big.out"); lay_nb=$(grep -c '^B' "$LAY/big.out")
    if [ "$lay_sz" -gt 2000000 ] && [ "$lay_pr" = 0 ] && [ "$lay_jr" = 0 ] && [ "$BT_BIG" = 1 ] && [ "$lay_rep" -gt 300 ] && [ "$lay_rep" -lt 800 ] && [ "$lay_nb" -gt 0 ] \
       && [ "$(printf '%s\n' "$lay_w" | cut -f5)" = 1 ] && [ "$(printf '%s\n' "$lay_w" | cut -f2)" = 1 ] && [ "$(grep -c 'busy air' "$LAY/big.log")" = 1 ] && [ $((lay_b - lay_a)) -le 6 ]; then
        st_pass "size: a $((lay_sz / 1024)) KiB window -> the first 256 KiB ($lay_rep reports) and the end are parsed in $((lay_b - lay_a)) s, the disable block at the end is found, one 'busy air' line"
    else st_fail "size: big window (size $lay_sz, rc $lay_pr/$lay_jr, big $BT_BIG, reports $lay_rep, W [$lay_w], $((lay_b - lay_a)) s)"; fi
    # the parse over its time: the stand-in for the timeout that ends the awk with 124 voids the window; the file of a window that is not there at all
    lay_pa=$PATH; printf '#!/bin/sh\nexit 124\n' > "$LAY/hb/timeout"; PATH="$LAY/hb:$PATH"
    BT_CUR=" "; BT_LOGGED=" "; bt_parse "$LAY/big.txt" > "$LAY/slow.out"; lay_pr=$?; PATH=$lay_pa
    bt_parse "$LAY/no-such-window.txt" > "$LAY/none.out"; lay_pn=$?; bt_judge "$LAY/none.out" 2>/dev/null; lay_jn=$?
    if [ "$lay_pr" = 124 ] && [ "$lay_jn" = 1 ] && [ "$BT_VOID" = nopassive ]; then st_pass "bt_parse: an awk that runs out of its 6 s is rc 124 (the window is void), a window file that is not there is void too (nothing witnessed)"; else st_fail "bt_parse: time limit ($lay_pr, $lay_pn/$lay_jn/$BT_VOID)"; fi

    # 30) alerts: alerts.log through the snapshot, the awk and the shape check. lal_run is run_layers with Bluetooth and Traffic off, so that alerts_look is the only
    # gate; the last rows run whole cycles. The clock of the cycle is a function `date` for the block: 1789300000, the same second in every row.
    # lal_l EPOCH AP = one line as the companion writes it (EPOCH deauth AP SOURCE DESTINATION CLIENT, tab separated).
    lal_ad="$LAY/al"; mkdir -p "$lal_ad"
    lal_so=$OUTDIR; lal_sad=$ALERT_DIR; lal_sa=$ALERTS; lal_sw=$ALERT_WIN; lal_sb=$ALERT_WIN_BAD; lal_str=$TRAFFIC; lal_sbl=$BLUETOOTH; lal_sbr=$BT_RC; lal_stp=$TR_PID
    lal_srs=$RESOLVED; lal_scm=$CAP_METHOD; lal_sof=$OUTFILE; lal_sve=$VENDOR
    BLUETOOTH=0; TRAFFIC=0; BT_RC=3; TR_PID=""; ALERTS=1; ALERT_WIN=600; ts=1789300000; OUTDIR=$lal_ad; ALERT_DIR=$lal_ad; BT_LOGGED=" "
    date() { if [ "$1" = "+%s" ]; then printf '%s\n' 1789300000; else command date "$@"; fi; }
    lal_l() { printf '%s\tdeauth\t%s\t02:00:00:00:0b:01\t02:00:00:00:0c:01\t02:00:00:00:0c:02\n' "$1" "$2"; }
    lal_doc() { printf '{\n  "generated": 1,\n  "center": {"label": "x"},\n  "aps": [\n  ],\n  "unassociated": [\n  ]\n}\n' > "$LAY/al.json"; }
    lal_run() {   # document -> $LAY/al.json, what the layers logged -> $LAY/al.log; BT_LOGGED carries the episode from one run to the next
        lal_doc; BT_CUR=" "; { alerts_look; run_layers "$LAY/al.json"; } 2> "$LAY/al.log"; BT_LOGGED=$BT_CUR
    }
    lal_doc; cp "$LAY/al.json" "$LAY/al.pristine"
    lal_p1=02:00:00:00:0a:01; lal_p2=02:00:00:00:0a:02; lal_p3=02:00:00:00:0a:03

    # ten lines, three APs: seven count; one has no epoch, one is a second older than the window, one is 61 s ahead. P1 and P2 end on the same t, so the address orders them;
    # the newest line of P1 is not its first or last
    {
        lal_l 1789299990 $lal_p1
        lal_l 1789299700 $lal_p3
        lal_l 1789299800 $lal_p1
        lal_l 1789299995 $lal_p3
        lal_l 1789299600 $lal_p1
        lal_l 1789299990 $lal_p2
        lal_l 1789299900 $lal_p2
        printf 'not-an-epoch\tdeauth\t%s\n' "$lal_p3"
        lal_l 1789299399 $lal_p1
        lal_l 1789300061 $lal_p2
    } > "$lal_ad/alerts.log"
    lal_run; cp "$LAY/al.log" "$LAY/al.log1"; lal_run
    lal_w='  "alerts": [{"type": "deauth", "t": 1789299995, "ap": "02:00:00:00:0a:03", "n": 2}, {"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:0a:01", "n": 3}, {"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:0a:02", "n": 2}],'
    if [ "$(wc -l < "$lal_ad/alerts.log" | tr -d ' ')" = 10 ] && grep -qxF "$lal_w" "$LAY/al.json" && [ "$(sed -n '/"alerts"/{n;p;}' "$LAY/al.json")" = '  "aps": [' ] \
       && [ "$(wc -l < "$LAY/al.json" | tr -d ' ')" = 9 ] && json_ok < "$LAY/al.json" && [ "$(grep -c 'Alerts: 2 line(s) of alerts.log skipped' "$LAY/al.log1")" = 1 ] && [ ! -s "$LAY/al.log" ]; then
        st_pass "alerts: ten lines, three APs, one without an epoch, one older than the window, one 61 s ahead -> three entries with n 2 / 3 / 2 and the newest t of each, newest first and then by address, in one added line before aps; two lines skipped and said once, not again for the same file"
    else st_fail "alerts: ten lines ($(grep -c '"alerts"' "$LAY/al.json") alerts lines, $(sed -n '/"alerts"/p' "$LAY/al.json" | cut -c1-200), log [$(cat "$LAY/al.log1")] [$(cat "$LAY/al.log")])"; fi

    # the rules one by one: not deauth, no AP, a short or non-hex address, an epoch of letters, blanks for tabs, two fields (seven skipped, and the ninth is a blank line, which is nothing);
    # the edge of the window counts (upper-case address, joined with the lower-case form of the same AP), 60 s ahead counts, 61 s ahead is the eighth skipped line
    {
        printf '%s\tdisassoc\t%s\n' 1789299990 $lal_p1
        printf '%s\tdeauth\t-\n' 1789299990
        printf '%s\tdeauth\t02:00:00:00:0a\n' 1789299990
        printf '%s\tdeauth\t02:00:00:00:0a:0g\n' 1789299990
        printf 'abc\tdeauth\t%s\n' $lal_p1
        printf '1789299990 deauth %s\n' $lal_p1
        printf '%s\tdeauth\n' 1789299990
        printf '\n'
        lal_l 1789299400 02:00:00:00:0A:01
        lal_l 1789300060 $lal_p1
        lal_l 1789300061 $lal_p1
    } > "$lal_ad/alerts.log"
    BT_LOGGED=" "; lal_run
    if grep -qxF '  "alerts": [{"type": "deauth", "t": 1789300060, "ap": "02:00:00:00:0a:01", "n": 2}],' "$LAY/al.json" && [ "$(wc -l < "$LAY/al.json" | tr -d ' ')" = 9 ] && json_ok < "$LAY/al.json" \
       && [ "$(grep -c 'Alerts: 8 line(s) of alerts.log skipped' "$LAY/al.log")" = 1 ]; then
        st_pass "alerts: skip rules: not deauth, no address, a short or a non-hex address, an epoch of letters, blanks for tabs and two fields are skipped (8 with the one 61 s ahead; a blank line is nothing); the window's edge and 60 s ahead count, and an upper-case address is the same AP"
    else st_fail "alerts: skip rules ($(sed -n '/"alerts"/p' "$LAY/al.json" | cut -c1-200), log [$(cat "$LAY/al.log")])"; fi

    # 25 APs: the cut at 20. First every AP on its own t (the newest 20 stay), then all on one t, in the opposite order in the file (the 20 lowest addresses stay)
    lal_i=1; while [ "$lal_i" -le 25 ]; do lal_l $((1789299990 - lal_i)) "$(printf '02:00:00:00:%02x:01' "$lal_i")"; lal_i=$((lal_i + 1)); done > "$lal_ad/alerts.log"
    lal_run; lal_n1=$(grep -o '"ap"' "$LAY/al.json" | wc -l | tr -d ' '); cp "$LAY/al.json" "$LAY/al.cut1"
    lal_i=25; while [ "$lal_i" -ge 1 ]; do lal_l 1789299990 "$(printf '02:00:00:00:%02x:01' "$lal_i")"; lal_i=$((lal_i - 1)); done > "$lal_ad/alerts.log"
    lal_run; lal_n2=$(grep -o '"ap"' "$LAY/al.json" | wc -l | tr -d ' ')
    if [ "$lal_n1/$lal_n2" = 20/20 ] && grep -q '^  "alerts": \[{"type": "deauth", "t": 1789299989, "ap": "02:00:00:00:01:01", "n": 1}, ' "$LAY/al.cut1" \
       && grep -q ', {"type": "deauth", "t": 1789299970, "ap": "02:00:00:00:14:01", "n": 1}\],$' "$LAY/al.cut1" && ! grep -q '02:00:00:00:15:01' "$LAY/al.cut1" \
       && grep -q '^  "alerts": \[{"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:01:01", "n": 1}, ' "$LAY/al.json" \
       && grep -q '"ap": "02:00:00:00:0a:01", "n": 1}, {"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:0b:01"' "$LAY/al.json" \
       && grep -q ', {"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:14:01", "n": 1}\],$' "$LAY/al.json" && ! grep -q '02:00:00:00:15:01' "$LAY/al.json" && json_ok < "$LAY/al.json"; then
        st_pass "alerts: 25 APs -> 20 entries: the 20 newest when the t differ (APs 01 to 14 in hex, the last at t-20), the 20 lowest addresses when the t are equal, whatever the order in the file"
    else st_fail "alerts: 25 APs (entries $lal_n1/$lal_n2, $(sed -n '/"alerts"/p' "$LAY/al.json" | cut -c1-160))"; fi

    # nothing to write: no file, an empty file, a file whose lines are all out of the window. No key, the document is the one that went in, and nothing is logged
    lal_ok=1
    rm -f "$lal_ad/alerts.log"; lal_run; cmp -s "$LAY/al.json" "$LAY/al.pristine" && [ ! -s "$LAY/al.log" ] || lal_ok=0
    : > "$lal_ad/alerts.log"; lal_run; cmp -s "$LAY/al.json" "$LAY/al.pristine" && [ ! -s "$LAY/al.log" ] || lal_ok=0
    lal_l 1789299399 $lal_p1 > "$lal_ad/alerts.log"; lal_run; cmp -s "$LAY/al.json" "$LAY/al.pristine" && [ ! -s "$LAY/al.log" ] || lal_ok=0
    if [ "$lal_ok" = 1 ]; then st_pass "alerts: no file, an empty file, and a file with only old lines write no key at all and log nothing"; else st_fail "alerts: nothing to write (ok $lal_ok, log [$(cat "$LAY/al.log")])"; fi

    # a name that is no readable regular file (a directory here; a pipe would hold `tail` for ever): read as no file, said once per episode
    rm -f "$lal_ad/alerts.log"; mkdir "$lal_ad/alerts.log"; BT_LOGGED=" "
    lal_run; cp "$LAY/al.log" "$LAY/al.log1"; lal_cmp1=0; cmp -s "$LAY/al.json" "$LAY/al.pristine" && lal_cmp1=1
    lal_run; lal_cmp2=0; cmp -s "$LAY/al.json" "$LAY/al.pristine" && lal_cmp2=1
    rmdir "$lal_ad/alerts.log"
    if [ "$lal_cmp1$lal_cmp2" = 11 ] && [ "$(grep -c 'alerts.log is not a readable file; no alerts this cycle' "$LAY/al.log1")" = 1 ] && [ ! -s "$LAY/al.log" ]; then
        st_pass "alerts: a directory named alerts.log is no file: no key, one log line, the same fault again is not logged again"
    else st_fail "alerts: a directory ($lal_cmp1$lal_cmp2, log [$(cat "$LAY/al.log1")] [$(cat "$LAY/al.log")])"; fi

    # a regular file that `tail` cannot read at the moment although it looked readable (a stand-in `tail` that fails): no key, the document as it came, one log line, once per episode
    lal_l 1789299990 $lal_p1 > "$lal_ad/alerts.log"; BT_LOGGED=" "
    tail() { return 1; }
    lal_run; cp "$LAY/al.log" "$LAY/al.log1"; lal_cmp1=0; cmp -s "$LAY/al.json" "$LAY/al.pristine" && lal_cmp1=1
    lal_run; lal_cmp2=0; cmp -s "$LAY/al.json" "$LAY/al.pristine" && lal_cmp2=1
    unset -f tail
    if [ "$lal_cmp1$lal_cmp2" = 11 ] && [ "$(grep -c 'alerts.log could not be read; no alerts this cycle' "$LAY/al.log1")" = 1 ] && [ ! -s "$LAY/al.log" ]; then
        st_pass "alerts: a read that fails: a log that exists but cannot be read gives no key and one log line, and the same fault again is not logged again"
    else st_fail "alerts: a read that fails ($lal_cmp1$lal_cmp2, log [$(cat "$LAY/al.log1")] [$(cat "$LAY/al.log")])"; fi

    # the switch, through whole cycles (capture source, the sample CSV of the first case): on = the line is there, in front of aps, the capture is intact; off = the document of a
    # cycle without any file, byte for byte (the same second, so even generated is the same)
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$lal_ad/cycle.json"; VENDOR=0
    { lal_l 1789299970 $lal_p1; lal_l 1789299980 $lal_p1; lal_l 1789299995 $lal_p2; } > "$lal_ad/alerts.log"
    ALERTS=1; run_cycle 2>/dev/null >/dev/null; cp "$OUTFILE" "$LAY/al.on"
    ALERTS=0; run_cycle 2>/dev/null >/dev/null; cp "$OUTFILE" "$LAY/al.off"
    rm -f "$lal_ad/alerts.log"; ALERTS=1; run_cycle 2>/dev/null >/dev/null; cp "$OUTFILE" "$LAY/al.none"
    if json_ok < "$LAY/al.on" && grep -qxF '  "alerts": [{"type": "deauth", "t": 1789299995, "ap": "02:00:00:00:0a:02", "n": 1}, {"type": "deauth", "t": 1789299980, "ap": "02:00:00:00:0a:01", "n": 2}],' "$LAY/al.on" \
       && grep -q 'HomeNet' "$LAY/al.on" && ! grep -q '"alerts"' "$LAY/al.off" && cmp -s "$LAY/al.off" "$LAY/al.none" && [ "$(wc -l < "$LAY/al.on" | tr -d ' ')" = $(($(wc -l < "$LAY/al.none" | tr -d ' ') + 1)) ]; then
        st_pass "alerts: the switch: a whole cycle with STARCHORUS_ALERTS=1 and an alerts.log carries the line (one more than without), STARCHORUS_ALERTS=0 reads nothing and gives the document of a cycle with no file, byte for byte"
    else st_fail "alerts: the switch (on [$(sed -n '/"alerts"/p' "$LAY/al.on" | cut -c1-200)], off has key $(grep -c '"alerts"' "$LAY/al.off"), off=none $(cmp -s "$LAY/al.off" "$LAY/al.none" && echo yes || echo no))"; fi
    RESOLVED=$lal_srs; CAP_METHOD=$lal_scm; OUTFILE=$lal_sof; VENDOR=$lal_sve

    # with Traffic on in the same pass: both arrays, activity first, two lines added and nothing else touched
    { lal_l 1789299990 $lal_p1; lal_l 1789299995 $lal_p3; } > "$lal_ad/alerts.log"
    TRAFFIC=1; printf '{"2412":600,"2437":400}\n' > "$LAY/ram/starchorus-traffic-$$.json"; lal_run; TRAFFIC=0
    if json_ok < "$LAY/al.json" && [ "$(wc -l < "$LAY/al.json" | tr -d ' ')" = 10 ] \
       && [ "$(sed -n '/"activity"/{n;p;}' "$LAY/al.json")" = '  "alerts": [{"type": "deauth", "t": 1789299995, "ap": "02:00:00:00:0a:03", "n": 1}, {"type": "deauth", "t": 1789299990, "ap": "02:00:00:00:0a:01", "n": 1}],' ] \
       && grep -qxF '  "activity": [{"freq": 2412, "share": 0.600}, {"freq": 2437, "share": 0.400}],' "$LAY/al.json" && [ ! -s "$LAY/al.log" ]; then
        st_pass "alerts: with Traffic on in the same pass the document gets activity[] and alerts[] (two lines, valid JSON), each as it is without the other"
    else st_fail "alerts: with Traffic ($(wc -l < "$LAY/al.json" | tr -d ' ') lines, $(sed -n '/"activity"/,/"aps"/p' "$LAY/al.json" | cut -c1-120 | tr '\n' '|'))"; fi

    # the window: 60 to 86400 whole seconds; a leading zero is no octal; anything else is 600 and is named
    lal_ok=1
    for lal_c in 60:60: 86400:86400: 600:600: 0600:600: 060:60: 00090:90: 59:600:59 86401:600:86401 0:600:0 abc:600:abc 6.5:600:6.5 -5:600:-5 1e3:600:1e3 999999999999999999999:600:999999999999999999999 600s:600:600s; do
        lal_v=${lal_c%%:*}; lal_r=${lal_c#*:}; lal_b=${lal_r#*:}; lal_r=${lal_r%%:*}
        alert_window "$lal_v"
        [ "$ALERT_WIN/$ALERT_WIN_BAD" = "$lal_r/$lal_b" ] || { lal_ok=0; echo "    alert_window '$lal_v' -> $ALERT_WIN/$ALERT_WIN_BAD, want $lal_r/$lal_b" >&2; }
    done
    alert_window ""; [ "$ALERT_WIN/$ALERT_WIN_BAD" = 600/ ] || lal_ok=0
    if [ "$lal_ok" = 1 ]; then st_pass "STARCHORUS_ALERT_WINDOW: values: 60, 86400, 600, 0600 and 060 are taken (a leading zero is no octal), 59, 86401, 0, letters, a decimal, a sign, a unit, a huge number are 600 and named, an empty one is 600 and quiet"; else st_fail "STARCHORUS_ALERT_WINDOW: values"; fi

    # said once at start, by a collector of its own (a start that finds no source ends after the line): a bad value, a good one, the switch off
    lal_o="$LAY/alo"; mkdir -p "$lal_o"; lal_ok=1
    for lal_c in 20:1 abc:1 86401:1 60:0 600:0 86400:0 0600:0; do
        lal_v=${lal_c%%:*}; lal_x=${lal_c#*:}
        STARCHORUS_OUTDIR="$lal_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_ALERTS=1 STARCHORUS_ALERT_WINDOW=$lal_v sh "$0" --once > /dev/null 2> "$LAY/w.log"
        lal_m=$(grep -c "Alerts: STARCHORUS_ALERT_WINDOW must be whole seconds from 60 to 86400 (got '$lal_v'); using 600" "$LAY/w.log")
        [ "$lal_m" = "$lal_x" ] && [ "$(grep -c 'Alerts' "$LAY/w.log")" = "$lal_x" ] || { lal_ok=0; echo "    window '$lal_v': $lal_m message(s), want $lal_x" >&2; }
    done
    STARCHORUS_OUTDIR="$lal_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_ALERT_WINDOW=20 STARCHORUS_ALERTS=0 sh "$0" --once > /dev/null 2> "$LAY/w.log"
    grep -q 'Alerts' "$LAY/w.log" && lal_ok=0
    STARCHORUS_OUTDIR="$lal_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_ALERTS=1 STARCHORUS_ALERT_WINDOW='' sh "$0" --once > /dev/null 2> "$LAY/w.log"
    grep -q 'Alerts' "$LAY/w.log" && lal_ok=0
    if [ "$lal_ok" = 1 ]; then st_pass "STARCHORUS_ALERT_WINDOW: the log line: a bad value is named once at start, a good one, an empty one and a bad one with STARCHORUS_ALERTS=0 say nothing"; else st_fail "STARCHORUS_ALERT_WINDOW: the log line ($(grep Alerts "$LAY/w.log" | head -n 2))"; fi

    # STARCHORUS_INTERVAL: whole seconds from 1 to 3600, anything else is 5 and named once at start. The loop sleeps this long (0 would run it back to back, a word
    # `sleep` rejects would fail it at once and fill the log), and the document prints the same number.
    ivs_keep=$INTERVAL; ivs_keepb=$INTERVAL_BAD; ivs_ok=1
    ivs_t() { interval_value "$1"; [ "$INTERVAL/$INTERVAL_BAD" = "$2/$3" ] || { ivs_ok=0; echo "    interval_value '$1' -> $INTERVAL/$INTERVAL_BAD, want $2/$3" >&2; }; }
    ivs_t 1 1 ""; ivs_t 5 5 ""; ivs_t 30 30 ""; ivs_t 3600 3600 ""; ivs_t 0030 30 ""; ivs_t 007 7 ""; ivs_t 00001 1 ""; ivs_t "" 5 ""
    ivs_t 0 5 0; ivs_t 0000 5 0000; ivs_t 3601 5 3601; ivs_t 99999 5 99999; ivs_t 99999999999999999999 5 99999999999999999999
    ivs_t abc 5 abc; ivs_t 5s 5 5s; ivs_t -5 5 -5; ivs_t +5 5 +5; ivs_t 1.5 5 1.5; ivs_t " 5" 5 " 5"; ivs_t 0x10 5 0x10
    INTERVAL=$ivs_keep; INTERVAL_BAD=$ivs_keepb
    if [ "$ivs_ok" = 1 ]; then st_pass "STARCHORUS_INTERVAL: values: 1, 3600, 30, 0030 and 007 are taken (a leading zero is no octal), 0, 3601, letters, a unit, a sign, a decimal, a blank, hex and a huge number are 5 and named, an empty one is 5 and quiet"; else st_fail "STARCHORUS_INTERVAL: values"; fi
    ivs_o="$LAY/ivo"; mkdir -p "$ivs_o"; ivs_ok=1
    for ivs_c in 0:1:5 abc:1:5 5s:1:5 3601:1:5 -5:1:5 1.5:1:5 5:0:5 30:0:30 3600:0:3600 0030:0:30 007:0:7; do
        ivs_v=${ivs_c%%:*}; ivs_r=${ivs_c#*:}; ivs_x=${ivs_r%%:*}; ivs_d=${ivs_r#*:}
        rm -f "$ivs_o/starchorus.json"
        STARCHORUS_OUTDIR="$ivs_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$LAY/none-such.db" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_INTERVAL=$ivs_v sh "$0" --once > /dev/null 2> "$LAY/w.log"
        ivs_m=$(grep -c "STARCHORUS_INTERVAL must be whole seconds from 1 to 3600 (got '$ivs_v'); using 5" "$LAY/w.log")
        ivs_j=$(grep -o '"interval": [0-9]*' "$ivs_o/starchorus.json" 2>/dev/null)
        [ "$ivs_m" = "$ivs_x" ] && [ "$(grep -c 'STARCHORUS_INTERVAL' "$LAY/w.log")" = "$ivs_x" ] && [ "$ivs_j" = "\"interval\": $ivs_d" ] || { ivs_ok=0; echo "    interval '$ivs_v': $ivs_m message(s), document $ivs_j, want $ivs_x and $ivs_d" >&2; }
    done
    if [ "$ivs_ok" = 1 ]; then st_pass "STARCHORUS_INTERVAL: the log line: 0, abc, 5s, 3601, -5 and 1.5 are named once at start and the document says 5 (the number the loop sleeps), 5, 30, 3600, 0030 and 007 say nothing and the document agrees"; else st_fail "STARCHORUS_INTERVAL: the log line"; fi

    # the window works: a line 5 minutes old and one 2 hours old
    { lal_l 1789299700 $lal_p1; lal_l 1789292800 $lal_p2; } > "$lal_ad/alerts.log"
    lal_ok=1
    ALERT_WIN=60; lal_run; grep -q '"alerts"' "$LAY/al.json" && lal_ok=0
    ALERT_WIN=600; lal_run; grep -qxF '  "alerts": [{"type": "deauth", "t": 1789299700, "ap": "02:00:00:00:0a:01", "n": 1}],' "$LAY/al.json" || lal_ok=0
    ALERT_WIN=86400; lal_run; grep -qxF '  "alerts": [{"type": "deauth", "t": 1789299700, "ap": "02:00:00:00:0a:01", "n": 1}, {"type": "deauth", "t": 1789292800, "ap": "02:00:00:00:0a:02", "n": 1}],' "$LAY/al.json" || lal_ok=0
    if [ "$lal_ok" = 1 ]; then st_pass "alerts: the window is the one set: 60 s drops a line 5 minutes old, 600 s keeps it and drops one 2 hours old, 86400 s keeps both"; else st_fail "alerts: the window ($lal_ok, $(sed -n '/"alerts"/p' "$LAY/al.json" | cut -c1-200))"; fi

    unset -f date lal_l lal_doc lal_run
    OUTDIR=$lal_so; ALERT_DIR=$lal_sad; ALERTS=$lal_sa; ALERT_WIN=$lal_sw; ALERT_WIN_BAD=$lal_sb; TRAFFIC=$lal_str; BLUETOOTH=$lal_sbl; BT_RC=$lal_sbr; TR_PID=$lal_stp; AL_ON=0
    unset lal_p1 lal_p2 lal_p3 lal_w

    TMPDIR_RAM=$lsv_ram; BT_F=$lsv_bf; ts=$lsv_ts; BT_HELD=$lsv_held; BT_WIN=$lsv_win; TRAFFIC=$lsv_tr; BLUETOOTH=$lsv_bl; BT_CUR=$lsv_cur; BT_LOGGED=$lsv_lg
    unset -f lay_doc lay_win lay_get lay_tr; unset A B C t0
}

# --------------------------------------------------------------------------- selftest: the window against stand-ins (processes, signals, the clock)
BTS=""
# bt_env on | off: the window code against the stand-in tree $BTS (the stand-ins first in PATH, a stand-in /proc, signals to files, a 1-s window and
# shorter waits where a case would otherwise sit still), or back at what the selftest had.
bt_env() {
    if [ "$1" = on ]; then
        be0_path=$PATH; be0_ram=$TMPDIR_RAM; be0_bl=$BLUETOOTH; be0_sys=$BT_SYSFS; be0_proc=$BT_PROC; be0_sl=$BT_SIGLOG; be0_sm=$BT_SIGMSG; be0_win=$BT_WIN; be0_mon=$BT_MON_S
        be0_t1=$BT_T_GRACE; be0_t2=$BT_T_WRAP; be0_t3=$BT_T_MON; be0_t4=$BT_T_READY; be0_t5=$BT_T_TERM; be0_fk=$BT_FAKE; be0_fn=$BT_FAKE_NAP
        PATH="$BTS/bin:$PATH"; TMPDIR_RAM="$BTS/ram"; BLUETOOTH=1; BT_SYSFS="$BTS/sys"; BT_PROC="$BTS/proc"; BT_SIGLOG="$BTS/log/sig.log"; BT_SIGMSG="$BTS/sig"
        BT_WIN=1; BT_MON_S=9; BT_T_GRACE=0; BT_T_WRAP=100; BT_T_MON=100; BT_FAKE=""; BT_FAKE_NAP=""
    else
        PATH=$be0_path; TMPDIR_RAM=$be0_ram; BLUETOOTH=$be0_bl; BT_SYSFS=$be0_sys; BT_PROC=$be0_proc; BT_SIGLOG=$be0_sl; BT_SIGMSG=$be0_sm; BT_WIN=$be0_win; BT_MON_S=$be0_mon
        BT_T_GRACE=$be0_t1; BT_T_WRAP=$be0_t2; BT_T_MON=$be0_t3; BT_T_READY=$be0_t4; BT_T_TERM=$be0_t5; BT_FAKE=$be0_fk; BT_FAKE_NAP=$be0_fn
    fi
}
# every stand-in process that was started (log/pid.*) is ended and reaped, the work files are cleared
bts_reap() {
    bs_pids=$(cat "$BTS"/log/pid.* 2>/dev/null)
    for bs_p in $bs_pids; do
        bs_st=$(sed -n 's/^[0-9]* (.*) \([A-Z]\) .*/\1/p' "$BTS/proc/$bs_p/stat" 2>/dev/null)
        [ "$bs_st" = Z ] || kill -9 "$bs_p" 2>/dev/null
    done
    for bs_p in $bs_pids; do wait "$bs_p" 2>/dev/null; done
    rm -rf "$BTS"/log/* "$BTS"/sig/* "$BTS"/proc/* "$BTS"/ram/* "$BTS"/rc.* "$BTS"/tool.* "$BTS"/cfg/S.mode "$BTS"/cfg/M.mode "$BTS"/cfg/T.mode "$BTS"/cfg/slow 2>/dev/null
}
# after a cycle: no window state left behind (the pids are empty, no stand-in is alive: each was reaped by the window's own wait, or by bts_reap)
bts_idle() {
    bi_bad=""
    [ -z "$BT_SPID$BT_MPID$BT_SKID$BT_MKID" ] || bi_bad="$bi_bad pids[$BT_SPID/$BT_MPID/$BT_SKID/$BT_MKID]"
    bi_pids=$(cat "$BTS"/log/pid.* 2>/dev/null)
    for bi_p in $bi_pids; do kill -0 "$bi_p" 2>/dev/null && bi_bad="$bi_bad alive:$bi_p"; done
    set -- "$BTS"/ram/starchorus-bt-*.txt "$BTS"/ram/starchorus-bt-*.err "$BTS"/ram/starchorus-bt-*.pid
    for bi_f in "$@"; do [ -e "$bi_f" ] && bi_bad="$bi_bad file:${bi_f##*/}"; done
    if [ -z "$bi_bad" ]; then st_pass "window state: $1 -> the four pids are empty, no stand-in process is alive, no window file is left"; else st_fail "window state: $1 ->$bi_bad"; fi
}
# every process as "pid ppid command" (where `ps -A` is not known, the processes of this terminal), for the case that ends the naps
# shellcheck disable=SC2009  # BusyBox has no pgrep that could do this
bts_ps() { ps -A -o pid= -o ppid= -o comm= 2>/dev/null | grep . || ps -o pid= -o ppid= -o comm= 2>/dev/null; }
# 0 when a stand-in with this pid is not there any more (it has been waited for)
bts_gone() { ! kill -0 "$1" 2>/dev/null; }

bt_selftest() {
    BTS="$1/bts"; rm -rf "$BTS"; mkdir -p "$BTS/bin" "$BTS/cfg" "$BTS/log" "$BTS/sig" "$BTS/proc" "$BTS/ram" "$BTS/sys/hci0" "$BTS/in"
    bt_stub "$BTS"; bt_tmo "$BTS"
    # A real socket file for the monitor stand-in's descriptor: bt_ready asks `test -S`, which a link to the text socket:[1] does not satisfy. python3 binds one (from inside the
    # directory: a socket path is short, 104 bytes on a Mac); where it cannot, the stand-in keeps the text link and the checks that need the socket say SKIP.
    bts_sock=0
    if have python3 && (cd "$BTS" && python3 -I -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind("sock")') 2>/dev/null && [ -S "$BTS/sock" ]; then bts_sock=1; fi
    bts_q() { grep -c "^$2 $1\$" "$BTS/log/sig.log" 2>/dev/null; }   # the signals SIG sent to PID by the window code: bts_q PID SIG
    bts_win() {   # one whole window as run_cycle runs it: bt_begin, and bt_end unless nothing was started; the log goes to log/err
        : > "$BTS/log/err"
        { bt_begin; BTW_RC=$?
          case $BTW_RC in 0|6) bt_end ;; esac
        } 2>> "$BTS/log/err"
    }
    # another collector's window, as bt_busy looks for it: a process named like this script, a pid file naming a live tool of the recorded start (BTS_OH, BTS_OT)
    bts_other() {
        # shellcheck disable=SC2016  # script text for the stand-in: it ends when its file or this shell is gone (an interrupted run leaves no loop named like the collector)
        printf '#!/bin/sh\nwhile [ -f "$0" ] && kill -0 %s 2>/dev/null; do sleep 1; done\n' "$$" > "$BTS/$SELF_BASE"
        sh "$BTS/$SELF_BASE" 2>/dev/null & BTS_OH=$!
        sleep 60 & BTS_OT=$!
        mkdir -p "$BTS/proc/$BTS_OT"; printf '%s (btmon) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0\n' "$BTS_OT" "$BTS_OH" "$BTS_OT" > "$BTS/proc/$BTS_OT/stat"
        printf 'M %s %s %s\n' "$BTS_OH" "$BTS_OT" "$BTS_OT" > "$BTS/ram/starchorus-bt-$BTS_OH.pid"
    }
    bts_other_end() { kill -9 "$BTS_OH" "$BTS_OT" 2>/dev/null; wait "$BTS_OH" "$BTS_OT" 2>/dev/null; rm -f "$BTS/ram"/starchorus-bt-*.pid; }
    # A collector of its own: a real process (`sh $0 --once`, the Wi-Fi source without data, the Bluetooth window on, the stand-ins first in PATH, its sysfs and
    # /proc from the environment), so that the pid file it writes is the one the code writes, under the name the code gives it; nothing here types that name.
    # bts_child [WINDOW [PATTERN]]: waits until a file in ram/ has a line that PATTERN (a grep expression, default the scan's line) matches; then BTS_CH = the
    # collector's pid, BTS_CF = that file and, for the default pattern, BTS_CM / BTS_CS = the pids of its monitor and its scan. Returns 1 when that did not happen.
    bts_child() {
        mkdir -p "$BTS/child"
        STARCHORUS_OUTDIR="$BTS/child" STARCHORUS_PIDDIR="$BTS/child" STARCHORUS_CAPDIR="$BTS/child/cap" STARCHORUS_TMPDIR="$BTS/ram" STARCHORUS_SOURCE=iwscan \
            STARCHORUS_ALLOW_ACTIVE=0 STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_BLUETOOTH=1 STARCHORUS_BT_SOURCE=window STARCHORUS_TRAFFIC=0 STARCHORUS_APCLI_RO=0 \
            STARCHORUS_BT_WINDOW="${1:-15}" STARCHORUS_SYSFS_BT="$BTS/sys" STARCHORUS_PROC_BT="$BTS/proc" sh "$0" --once > "$BTS/log/child.out" 2> "$BTS/log/child.err" &
        BTS_CH=$!; BTS_CF=""; BTS_CM=""; BTS_CS=""; bc_pat=${2:-'^S [0-9][0-9]* [0-9][0-9]* [0-9]'}; bc_n=0
        while [ "$bc_n" -lt 150 ]; do
            BTS_CF=$(grep -l -- "$bc_pat" "$BTS"/ram/* 2>/dev/null | head -n 1)
            [ -z "$BTS_CF" ] || break
            sleep 0.1 2>/dev/null || sleep 1
            bc_n=$((bc_n + 1))
        done
        [ -n "$BTS_CF" ] || return 1
        [ -n "$2" ] && return 0
        BTS_CM=$(sed -n 's/^M [0-9]* \([0-9]*\) .*/\1/p' "$BTS_CF"); BTS_CS=$(sed -n 's/^S [0-9]* \([0-9]*\) .*/\1/p' "$BTS_CF")
        [ -n "$BTS_CM" ] && [ -n "$BTS_CS" ]
    }
    bts_child_end() { kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null; bts_reap; }
    cat > "$BTS/in/win.txt" <<'BTWIN'
Bluetooth monitor ver 5.72
scanner[3550]: < HCI Command: LE Set Scan P.. (0x08|0x000b) plen 7  #1 1.531002
        Type: Passive (0x00)
        Interval: 10.000 msec (0x0010)
> HCI Event: Command Complete (0x0e) plen 4                         #2 1.533412
      LE Set Scan Parameters (0x08|0x000b) ncmd 1
        Status: Success (0x00)
scanner[3550]: < HCI Command: LE Set Scan E.. (0x08|0x000c) plen 2  #3 1.533820
        Scanning: Enabled (0x01)
        Filter duplicates: Disabled (0x00)
> HCI Event: LE Meta Event (0x3e) plen 29                           #5 1.546345
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Random (0x01)
        Address: 02:00:00:00:00:02 (Resolvable)
        Data length: 17
        Company: Maker A (65535)
          Data: 0000000000
        RSSI: -51 dBm (0xcd)
> HCI Event: LE Meta Event (0x3e) plen 43                           #6 1.648735
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Public (0x00)
        Address: 02:00:00:00:00:03 (OUI 02-00-00)
        Data length: 31
        RSSI: -97 dBm (0x9f)
> HCI Event: LE Meta Event (0x3e) plen 29                          #10 1.700001
      LE Advertising Report (0x02)
        Num reports: 1
        Event type: Connectable undirected - ADV_IND (0x00)
        Address type: Random (0x01)
        Address: 02:00:00:00:00:02 (Resolvable)
        Data length: 17
        Company: Maker A (65535)
          Data: 0000000000
        RSSI: -49 dBm (0xcf)
scanner[3550]: < HCI Command: LE Set Sca.. (0x08|0x000c) plen 2  #338 11.528127
        Scanning: Disabled (0x00)
        Filter duplicates: Disabled (0x00)
BTWIN
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"
    bt_env on
    # the stand-ins must be what the names resolve to: first in PATH, and nothing else in their directory
    bts_ok=1; bts_nb=0
    case $PATH in "$BTS/bin:"*) ;; *) bts_ok=0 ;; esac
    for bts_f in "$BTS"/bin/*; do bts_nb=$((bts_nb + 1)); [ "$(command -v "${bts_f##*/}")" = "$bts_f" ] || bts_ok=0; done
    if [ "$bts_ok" = 1 ] && [ "$bts_nb" = 3 ]; then st_pass "window stand-ins: the two scan tools and the dead-man stand-in are what the names resolve to (a case that set PATH wrongly must not scan)"; else st_fail "window stand-ins: PATH does not put the stand-ins first [$bts_nb files]"; bt_env off; return 1; fi

    # 12) argv: exactly the two lines, each under the stand-in with -s INT, default window (5 s, the monitor's dead-man timer 13 s); flag off and no controller: no call
    BT_WIN=5; BT_MON_S=13; : > "$BTS/log/err"; printf 'ignoreint\n' > "$BTS/cfg/S.mode"
    bt_begin 2>> "$BTS/log/err"; bts_rc=$?
    sleep 1
    bts_mp=$(tail -n 1 "$BTS/log/pid.M" 2>/dev/null); bts_sp=$(tail -n 1 "$BTS/log/pid.S" 2>/dev/null)
    bts_a1=$(cat "$BTS/log/argv.M" 2>/dev/null); bts_a2=$(cat "$BTS/log/argv.S" 2>/dev/null)
    bts_a3=$(sed -n 1p "$BTS/log/argv.T" 2>/dev/null); bts_a4=$(sed -n 2p "$BTS/log/argv.T" 2>/dev/null); bts_a5=$(wc -l < "$BTS/log/argv.T" | tr -d ' ')
    bts_w1="-s INT 13 btmon -i hci0"; bts_w2="-s INT 5 hcitool -i hci0 lescan --passive --duplicates"
    if [ "$bts_rc" = 0 ] && [ "$bts_a1" = "-i hci0" ] && [ "$bts_a2" = "-i hci0 lescan --passive --duplicates" ] && [ "$bts_a3" = "$bts_w1" ] && [ "$bts_a4" = "$bts_w2" ] && [ "$bts_a5" = 2 ]; then
        st_pass "bt_begin: runs exactly the monitor pinned to hci0 and the passive scan pinned to hci0 with --duplicates, each under the dead-man stand-in with -s INT and its time of 13 s and 5 s, the monitor first"
    else st_fail "bt_begin: argv rc $bts_rc [$bts_a1] [$bts_a2] [$bts_a3] [$bts_a4]"; fi
    # 13) terminal signals: HUP and QUIT are ignored for the two launches only (the stand-in tools inherit them; no /proc here: nothing to read)
    if [ -r /proc/self/status ] && [ -s "$BTS/log/sigign.S" ]; then
        bts_ig=1
        for bts_x in S M; do
            bts_h=$(sed -n 's/^SigIgn:[[:space:]]*//p' "$BTS/log/sigign.$bts_x"); bts_lo=${bts_h#"${bts_h%??}"}
            [ $((0x$bts_lo & 5)) = 5 ] || bts_ig=0
        done
        if [ "$bts_ig" = 1 ]; then st_pass "bt_begin: the two tools start with HUP and QUIT ignored (SigIgn), so a closing terminal cannot end the scan past its INT handler"; else st_fail "bt_begin: SigIgn lines [$(cat "$BTS"/log/sigign.* 2>/dev/null)]"; fi
    else log "  SKIP: bt_begin SigIgn check needs /proc (this is not Linux)"; fi
    # the pid file: one line per tool, wrapper, tool and start (the stand-in /proc gives the start field)
    bts_pf=$(cat "$BT_PF" 2>/dev/null)
    case $bts_pf in "M "*"$bts_mp $bts_mp"*) bts_pfm=1 ;; *) bts_pfm=0 ;; esac
    if [ "$bts_pfm" = 1 ] && [ "$(printf '%s\n' "$bts_pf" | wc -l | tr -d ' ')" = 2 ] && printf '%s\n' "$bts_pf" | grep -q "^S [0-9]* $bts_sp $bts_sp\$"; then st_pass "bt_note: the pid file has one line per tool (wrapper, tool pid, start)"; else st_fail "bt_note: [$bts_pf]"; fi
    # 18) abort: INT to both tools at once and again after at most 2 s, back within 3 s, no parse, the pid file kept while a tool lives (the scan ignores INT)
    : > "$BTS/log/sig.log"; bts_t0=$(date +%s); bt_end abort 2>> "$BTS/log/err"; bts_t1=$(date +%s)
    if [ $((bts_t1 - bts_t0)) -le 3 ] && [ "$(bts_q "$bts_mp" INT)" -ge 1 ] && [ "$(bts_q "$bts_sp" INT)" -ge 1 ] && [ ! -e "$BT_F" ] && [ ! -e "$BT_F.err" ] \
       && [ -z "$BT_SPID$BT_MPID$BT_SKID$BT_MKID" ]; then
        bts_ab=1
    else bts_ab=0; fi
    bts_wp=$(cat "$BTS/log/pid.T" 2>/dev/null)
    bts_bad=""; for bts_x in $bts_wp; do grep -q "^[A-Z]* $bts_x\$" "$BTS/log/sig.log" 2>/dev/null && bts_bad=1; done
    # the monitor (ok) ended on the first INT; the scan stand-in here only ignores the message, so this checks the 2-s repeat only for it
    bts_q2=$(bts_q "$bts_sp" INT)
    bt_up "$bts_mp" && bts_ml=1 || bts_ml=0
    bts_pidkept=0; [ -e "$BT_PF" ] && bts_pidkept=1
    if [ "$bts_ab" = 1 ] && [ "$bts_q2" = 2 ] && [ -z "$bts_bad" ] && [ ! -e "$BT_F.out" ]; then
        st_pass "bt_end abort: INT to both tool pids at once and once more after 2 s (the scan ignores it: 2 INT), back in $((bts_t1 - bts_t0)) s, no parse, files cleared, no signal to a wrapper"
    else st_fail "bt_end abort [$((bts_t1 - bts_t0)) s, INT scan $bts_q2, tools alive monitor $bts_ml, ab $bts_ab, wrapper signalled $bts_bad]"; fi
    if [ "$bts_pidkept" = 1 ]; then st_pass "bt_end abort: the pid file stays while a tool still lives (bt_sweep needs it)"; else st_fail "bt_end abort: pid file gone while the scan lives"; fi
    bts_reap; BT_WIN=1; BT_MON_S=9
    # abort hold: a scan younger than a second gets its first INT one second after its start (a coreutils `timeout` starts it with INT at default, and an INT before
    # its handler is in place would end it with the scan on); an older one at once. The clock is the test clock (the naps move it), both tools ignore INT, so the
    # abort runs its two rounds: the first INT, 2 s later the second.
    for bts_age in 0 500; do
        bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'ignoreint\n' > "$BTS/cfg/S.mode"; printf 'ignoreint\n' > "$BTS/cfg/M.mode"; printf 'parent\n' > "$BTS/cfg/T.mode"
        BT_WIN=6; BT_MON_S=14; : > "$BTS/log/sig.log"; bt_begin 2>/dev/null
        BT_FAKE=$((BT_TS + bts_age)); bt_end abort 2>/dev/null; bts_el=$((BT_FAKE - BT_TS - bts_age)); BT_FAKE=""
        bts_ni=$(bts_q "$(tail -n 1 "$BTS/log/pid.S")" INT)
        if [ "$bts_age" = 0 ]; then bts_el_0=$bts_el; bts_ni_0=$bts_ni; else bts_el_500=$bts_el; bts_ni_500=$bts_ni; fi
    done
    bts_reap; BT_WIN=1; BT_MON_S=9; rm -f "$BTS/cfg/M.mode"
    if [ "$bts_el_0" -ge 290 ] && [ "$bts_el_500" -le 240 ] && [ "$bts_ni_0" = 2 ] && [ "$bts_ni_500" = 2 ]; then
        st_pass "bt_end abort: the first INT to a scan younger than a second waits for its first second ($bts_el_0 hundredths of the test clock in all, against $bts_el_500 for an older scan), both rounds are sent"
    else st_fail "bt_end abort: hold (young scan $bts_el_0, old scan $bts_el_500 hundredths; INT to the scan $bts_ni_0/$bts_ni_500)"; fi
    # a signal between the fork of a wrapper and the assignment of its pid: cleanup() takes it from $!
    sleep 30 & bts_sl=$!
    BT_ARM=s; BT_SPID=""; BT_MPID=""; BT_F="$BTS/ram/starchorus-bt-$$.txt"; BT_PF="$BTS/ram/starchorus-bt-$$.pid"; : > "$BTS/log/sig.log"
    cleanup 2>/dev/null; st_arm   # cleanup() clears the INT, TERM and HUP traps of the run
    if [ "$(bts_q "$bts_sl" INT)" -ge 1 ] && [ -z "$BT_SPID$BT_MPID" ]; then st_pass "cleanup: a wrapper forked just before a signal is found in \$! and told to end (INT), the pids are cleared"; else st_fail "cleanup: fork race ([$(cat "$BTS/log/sig.log")] arm [$BT_ARM] spid [$BT_SPID])"; fi
    BT_ARM=""; kill -9 "$bts_sl" 2>/dev/null; wait "$bts_sl" 2>/dev/null
    bts_reap

    # 2) the real text of the device (10 s of passive scan, addresses and names masked): the counts it was recorded with
    bts_fx="$(dirname "$0")/tests/fixtures/btmon-window.txt"
    if [ -r "$bts_fx" ]; then
        bt_parse "$bts_fx" > "$BTS/fx.out"; bts_pr=$?; BT_CUR=" "; BT_LOGGED=" "; BT_NOTES=""; bt_judge "$BTS/fx.out" 2> "$BTS/fx.log"; bts_jr=$?
        bts_t=$RECON_TAB
        bts_rep=$(awk -F"$bts_t" '$1 == "B" { n += $5 } END { print n + 0 }' "$BTS/fx.out")
        bts_adr=$(grep -c '^B' "$BTS/fx.out")
        bts_co=$(awk -F"$bts_t" '$1 == "B" && $6 != "" { n += $5 } END { print n + 0 }' "$BTS/fx.out")
        bts_ty=$(awk -F"$bts_t" '$1 == "B" { t[$3]++ } END { printf "%d/%d/%d", t["public"], t["random-static"], t["random-resolvable"] }' "$BTS/fx.out")
        bts_cn=$(awk -F"$bts_t" '$1 == "B" && $9 == 1' "$BTS/fx.out" | wc -l | tr -d ' ')
        # independently, from the file with grep and one awk of another shape: reports, RSSI lines, Company lines, distinct addresses, address types, and the maximum per address
        bts_i1=$(grep -c '^        Event type: ' "$bts_fx"); bts_i2=$(grep -c '^        RSSI: ' "$bts_fx"); bts_i3=$(grep -c '^        Company: ' "$bts_fx")
        bts_i4=$(grep '^        Address: ' "$bts_fx" | tr 'A-F' 'a-f' | awk '{ print $2 }' | sort -u | wc -l | tr -d ' ')
        bts_i5=$(grep -c '^        Address type: Random' "$bts_fx"); bts_i6=$(grep -c '^        Address type: Public' "$bts_fx")
        awk '/^        Address: /{ a = tolower($2) } /^        RSSI: /{ r = $2 + 0; n[a]++; if (!(a in m) || r > m[a]) m[a] = r } END { for (a in n) printf "%s %d %d\n", a, m[a], n[a] }' "$bts_fx" | LC_ALL=C sort > "$BTS/fx.indep"
        awk -F"$bts_t" '$1 == "B" { printf "%s %d %d\n", $2, $4, $5 }' "$BTS/fx.out" | LC_ALL=C sort > "$BTS/fx.mine"
        if [ "$bts_pr" = 0 ] && [ "$bts_jr" = 0 ] && [ ! -s "$BTS/fx.log" ] && [ "$bts_rep/$bts_i1/$bts_i2" = 333/333/333 ] && [ "$bts_adr/$bts_i4" = 20/20 ] && [ "$bts_co/$bts_i3" = 329/329 ] \
           && [ "$bts_i5/$bts_i6" = 297/36 ] && [ "$bts_ty" = 3/10/7 ] && [ "$bts_cn" = 14 ] && [ "$(sed -n '/^W/p' "$BTS/fx.out")" = "$(printf 'W\t1\t0\t1\t1\t0\t0\t0')" ] && cmp -s "$BTS/fx.indep" "$BTS/fx.mine"; then
            st_pass "bt_parse: the real window of the device (333 reports, 333 RSSI lines, 329 Company lines, 297 random and 36 public) gives 20 addresses with their maxima and counts, a clean witness"
        else st_fail "bt_parse: fixture (reports $bts_rep/$bts_i1/$bts_i2, addresses $bts_adr/$bts_i4, company $bts_co/$bts_i3, types $bts_ty, connectable $bts_cn, W [$(sed -n '/^W/p' "$BTS/fx.out")])"; fi
        awk "$AWK_BT" "$bts_fx" > "$BTS/fx.out2"
        if cmp -s "$BTS/fx.out" "$BTS/fx.out2"; then st_pass "bt_parse: the real window gives the same answer with and without the prefilter"; else st_fail "bt_parse: prefilter changes the real window's answer"; fi
    else log "  SKIP: bt_parse on the fixture (tests/fixtures/btmon-window.txt is not next to this script)"; fi

    # whole windows against the stand-ins: the two shapes of timeout stand-in that run the window to its end (it execs; it keeps the tool as a child)
    for bts_m in same parent; do
        bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf '%s\n' "$bts_m" > "$BTS/cfg/T.mode"; : > "$BTS/log/sig.log"
        bts_t0=$(date +%s); bts_win; bts_t1=$(date +%s)
        bts_mp=$(tail -n 1 "$BTS/log/pid.M" 2>/dev/null); bts_sp=$(tail -n 1 "$BTS/log/pid.S" 2>/dev/null)
        bts_bl=$(sed -n '/^B/p' "$BT_F.out" 2>/dev/null); bts_t=$RECON_TAB
        bts_wb=$(printf 'B\t02:00:00:00:00:02\trandom-resolvable\t-49\t2\t65535\tMaker A\t\t1\nB\t02:00:00:00:00:03\tpublic\t-97\t1\t\t\t\t1')
        bts_all=$(cat "$BTS/log/sig.log"); bts_wsig=0; [ -s "$BTS/log/wrapper.sigs" ] && bts_wsig=1
        if [ "$BTW_RC" = 0 ] && [ -z "$BT_VOID" ] && [ "$bts_bl" = "$bts_wb" ] && [ "$bts_all" = "INT $bts_mp" ] && [ "$bts_wsig" = 0 ] && [ -z "$BT_NOTES" ] \
           && [ ! -e "$BT_F" ] && [ ! -e "$BT_F.err" ] && [ ! -e "$BT_PF" ] && [ ! -s "$BTS/log/err" ]; then
            st_pass "window $bts_m: the window runs its course in $((bts_t1 - bts_t0)) s, both tools end (the scan on its own deadline, the monitor on the one INT after it), two addresses, the verdict counts, no wrapper signalled, no file left, nothing logged"
        else st_fail "window $bts_m: rc $BTW_RC void [$BT_VOID] notes [$BT_NOTES] signals [$bts_all] wrapper-signalled $bts_wsig B [$bts_bl] log [$(cat "$BTS/log/err")]"; fi
        bts_idle "$bts_m"
        rm -f "$BT_F.out"
    done
    bts_reap

    # 14) overlap: another collector's window is live, written by a real collector process (bts_child): its pid file, under the name the code gives it, is read
    #     by bt_busy; a start field that differs (a reused pid) and a holder that is gone are no window; a start meets the live window with rc 5 and no call
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; rm -f "$BTS/cfg/S.mode" "$BTS/cfg/M.mode"
    if bts_child; then
        bts_c0=$(cat "$BTS/log/argv.M" "$BTS/log/argv.S" 2>/dev/null | wc -l | tr -d ' ')
        bt_busy; bts_b1=$?
        cp "$BTS_CF" "$BTS/in/child.pid"; sed 's/ [0-9]*$/ 1/' "$BTS/in/child.pid" > "$BTS_CF"; bt_busy; bts_b2=$?; cp "$BTS/in/child.pid" "$BTS_CF"
        bt_begin 2>/dev/null; bts_rc=$?
        bts_c1=$(cat "$BTS/log/argv.M" "$BTS/log/argv.S" 2>/dev/null | wc -l | tr -d ' ')
        set -- "$BTS"/ram/starchorus-bt-$$.*; bts_own=0; [ -e "$1" ] && bts_own=1
        : > "$BTS/log/err"; BT_RC=5; BLUETOOTH=1; printf '{\n  "generated": 1,\n  "center": {"label": "x"},\n  "aps": [\n  ]\n}\n' > "$BTS/doc.json"
        BT_CUR=" "; BT_LOGGED=" "; run_layers "$BTS/doc.json" 2>> "$BTS/log/err"; BT_LOGGED=$BT_CUR
        BT_CUR=" "; run_layers "$BTS/doc.json" 2>> "$BTS/log/err"; BT_LOGGED=$BT_CUR
        bts_ln=$(grep -c "another collector's window is running" "$BTS/log/err")
        kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null; bt_busy; bts_b3=$?
        if [ "$bts_b1/$bts_b2/$bts_b3" = 0/1/1 ] && [ "$bts_rc" = 5 ] && [ "$bts_c0" = 2 ] && [ "$bts_c1" = 2 ] && [ "$bts_own" = 0 ] && [ "$bts_ln" = 1 ] \
           && grep -q '"bt_window": 0' "$BTS/doc.json" && grep -q '^  "bluetooth": \[\],' "$BTS/doc.json"; then
            st_pass "overlap: a real collector's live window (its own pid file) -> bt_busy 0, bt_begin rc 5 with no call and no file of its own left; a start field that differs, or a holder that is gone, is no window; the cycle is a void one (bt_window 0), one log line over two cycles"
        else st_fail "overlap: busy $bts_b1/$bts_b2/$bts_b3 (want 0/1/1), rc $bts_rc, calls $bts_c0/$bts_c1 (want 2/2), own file $bts_own, log lines $bts_ln, child log [$(head -n 2 "$BTS/log/child.err" 2>/dev/null)]"; fi
    else st_fail "overlap: the stand-in collector did not write a pid file naming both tools [$(head -n 3 "$BTS/log/child.err" 2>/dev/null)]"; fi
    bts_child_end; BT_RC=3

    # 15) the monitor does not get ready (no output, no socket): rc 6 after the wait, no scan was asked for, the monitor is stopped
    bts_reap; printf 'silent\n' > "$BTS/cfg/M.mode"; BT_T_READY=100
    bts_t0=$(date +%s); bts_win; bts_t1=$(date +%s); BT_T_READY=500
    if [ "$BTW_RC" = 6 ] && [ ! -e "$BTS/log/argv.S" ] && [ -e "$BTS/log/argv.M" ] && [ "$BT_VOID" = nomonitor ] && [ $((bts_t1 - bts_t0)) -le 5 ]; then
        st_pass "bt_begin: a monitor that holds no socket and writes nothing -> rc 6, the scan is never started, the monitor is stopped, the window is void"
    else st_fail "bt_begin: not ready (rc $BTW_RC, scan argv [$(cat "$BTS/log/argv.S" 2>/dev/null)], void [$BT_VOID], $((bts_t1 - bts_t0)) s)"; fi
    bts_idle "monitor not ready"
    # 15b) the monitor has written its banner but holds no socket yet (the device's order: banner after 0.1 s, socket after 0.5 s): not ready either
    bts_reap; printf 'banner\n' > "$BTS/cfg/M.mode"; BT_T_READY=100
    bts_t0=$(date +%s); bts_win; bts_t1=$(date +%s); BT_T_READY=500
    if [ "$BTW_RC" = 6 ] && [ ! -e "$BTS/log/argv.S" ] && [ -e "$BTS/log/argv.M" ] && [ "$BT_VOID" = nomonitor ] && [ $((bts_t1 - bts_t0)) -le 5 ]; then
        st_pass "bt_begin: a monitor that has written only its banner and holds no socket is not ready -> rc 6, the scan is never started, the window is void"
    else st_fail "bt_begin: banner counted as ready (rc $BTW_RC, scan argv [$(cat "$BTS/log/argv.S" 2>/dev/null)], void [$BT_VOID], $((bts_t1 - bts_t0)) s)"; fi
    bts_idle "monitor banner only"
    # 16) the scan cannot start (it prints its failure and exits 1): void, one log line per episode
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'fail\n' > "$BTS/cfg/S.mode"; printf 'same\n' > "$BTS/cfg/T.mode"
    BT_CUR=" "; BT_LOGGED=" "; bts_win; bts_v1=$BT_VOID; bts_l1=$(grep -c 'could not start' "$BTS/log/err")
    BT_LOGGED=$BT_CUR; bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'fail\n' > "$BTS/cfg/S.mode"; printf 'same\n' > "$BTS/cfg/T.mode"
    BT_CUR=" "; bts_win; bts_v2=$BT_VOID; bts_l2=$(grep -c 'could not start' "$BTS/log/err"); BT_LOGGED=$BT_CUR
    if [ "$bts_v1/$bts_v2" = start/start ] && [ "$bts_l1/$bts_l2" = 1/0 ]; then st_pass "bt_end: a scan that fails to set its parameters (its stderr says so) voids the window, logged once over two cycles"; else st_fail "bt_end: scan failure (void $bts_v1/$bts_v2, log $bts_l1/$bts_l2)"; fi
    bts_idle "scan failure"

    # 17) the watchdog, in each shape of the timeout stand-in. A clock the naps move on (BT_FAKE) stands in for the seconds; the processes are real.
    #  a) a scan that ignores INT: INT about once a second after its deadline plus 2 s, ONE TERM after the last, never KILL; no wrapper signalled while its tool lived
    for bts_m in same parent noforward; do
        bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf '%s\n' "$bts_m" > "$BTS/cfg/T.mode"; printf 'ignoreint\n' > "$BTS/cfg/S.mode"; : > "$BTS/log/sig.log"
        BT_CUR=" "; BT_LOGGED=" "; BT_T_TERM=200; BT_T_GRACE=100; BT_T_MON=200
        { bt_begin; BTW_RC=$?; BT_FAKE=$BT_TS; BT_FAKE_NAP=0.05; bt_end; BT_FAKE=""; BT_FAKE_NAP=""; } 2> "$BTS/log/err"
        BT_T_TERM=1200
        bts_sp=$(tail -n 1 "$BTS/log/pid.S"); bts_mp=$(tail -n 1 "$BTS/log/pid.M"); bts_wsig=0; [ -s "$BTS/log/wrapper.sigs" ] && bts_wsig=1
        bts_ni=$(bts_q "$bts_sp" INT); bts_nt=$(bts_q "$bts_sp" TERM); bts_nk=$(bts_q "$bts_sp" KILL)
        if [ "$BTW_RC" = 0 ] && [ "$BT_VOID" = watchdog ] && [ "$bts_ni" -ge 2 ] && [ "$bts_nt" = 1 ] && [ "$bts_nk" = 0 ] && [ "$bts_wsig" = 0 ] \
           && grep -q 'did not end by itself' "$BTS/log/err" && grep -q 'was terminated; the controller may still be scanning' "$BTS/log/err" && bts_gone "$bts_sp" && [ "$(bts_q "$bts_mp" INT)" = 1 ]; then
            st_pass "watchdog $bts_m: a scan that ignores INT gets INT every second, $bts_ni of them, then one TERM and the log lines, never KILL; the window is void; the monitor ends on its one INT; no wrapper was signalled"
        else st_fail "watchdog $bts_m: void [$BT_VOID] INT $bts_ni TERM $bts_nt KILL $bts_nk wrapper-signalled $bts_wsig log [$(cat "$BTS/log/err")]"; fi
    done
    #  a2) the cadence of the wait (the test clock again; `sleep` is a function that notes the clock after each nap, so nothing waits, and BT_FAKE_NAP only has to be set for bt_nap
    #      to call it). While the scan lives and the watchdog's deadline (BT_WIN * 100 + 200 after the scan's start) is more than a second away the wait goes on in steps of 0.5 s;
    #      from there to the deadline in steps of 0.2 s, so that the watchdog starts at the deadline itself. A scan that is gone, a window that is being stopped for its size and
    #      an abort keep 0.2 s.
    #      Only the clocks up to the deadline are read; what the stand-ins do after it is the business of the cases b to d.
    #      bts_steps START END "CLOCKS": the steps between the clocks, up to END: bts_sa of 0.5 s, bts_sb of 0.2 s, bts_so of any other length, bts_sh = 1 when END was one of the clocks.
    bts_steps() {
        bts_sr=$(printf '%s\n' "$3" | awk -v p="$1" -v e="$2" '{ for (i = 1; i <= NF; i++) { d = $i - p; p = $i; if (d == 50) a++; else if (d == 20) b++; else o++; if (p == e) { h = 1; exit } } }
            END { print a + 0 "/" b + 0 "/" o + 0 "/" h + 0 }')
        bts_sa=${bts_sr%%/*}; bts_sr=${bts_sr#*/}; bts_sb=${bts_sr%%/*}; bts_sr=${bts_sr#*/}; bts_so=${bts_sr%%/*}; bts_sh=${bts_sr#*/}
    }
    bts_vg=$BT_T_GRACE; bts_vm=$BT_T_MON; bts_vw=$BT_WIN; bts_vx=$BT_MAXB
    #  the scan alive, a window of 6 s (deadline 800 hundredths after the start): 14 steps of 0.5 s to 700, 5 of 0.2 s to 800
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; rm -f "$BTS/cfg/S.mode" "$BTS/cfg/M.mode"; : > "$BTS/log/sig.log"
    BT_CUR=" "; BT_LOGGED=" "; BT_T_GRACE=100; BT_T_MON=200; BT_WIN=6
    bt_begin 2> "$BTS/log/err"
    bts_nl=""; bts_end=$((BT_TS + 800))
    sleep() { bts_nl="$bts_nl $BT_FAKE"; }
    BT_FAKE=$BT_TS; BT_FAKE_NAP=1; bt_end 2>> "$BTS/log/err"; BT_FAKE=""; BT_FAKE_NAP=""
    unset -f sleep
    bts_steps "$BT_TS" "$bts_end" "$bts_nl"; bts_cd1="$bts_sa/$bts_sb/$bts_so/$bts_sh"
    bts_reap
    #  the scan gone before its deadline (it ended on its own after 1 s of the real clock, and the window code is told the window was 6 s): nothing is due, but the monitor's
    #  one second is measured in 0.2 s
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; : > "$BTS/log/sig.log"
    BT_CUR=" "; BT_LOGGED=" "; BT_WIN=1
    bt_begin 2> "$BTS/log/err"; bts_sp=$(tail -n 1 "$BTS/log/pid.S"); bts_w=0
    while kill -0 "$bts_sp" 2>/dev/null && [ "$bts_w" -lt 100 ]; do sleep 0.1 2>/dev/null || sleep 1; bts_w=$((bts_w + 1)); done
    BT_WIN=6; bts_nl=""
    sleep() { bts_nl="$bts_nl $BT_FAKE"; }
    BT_FAKE=$((BT_TS + 100)); BT_FAKE_NAP=1; bt_end 2>> "$BTS/log/err"; BT_FAKE=""; BT_FAKE_NAP=""
    unset -f sleep
    bts_steps "$((BT_TS + 100))" 0 "$bts_nl"; bts_cd2="$bts_sa/$bts_so"; bts_cd2b=$bts_sb
    bts_reap
    #  a window of 3 s (deadline 500) whose text is over BT_MAXB: the monitor is stopped at the first look at the size (200 hundredths in), and from there the steps are 0.2 s
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; : > "$BTS/log/sig.log"
    BT_CUR=" "; BT_LOGGED=" "; BT_WIN=3; BT_MAXB=1
    bt_begin 2> "$BTS/log/err"; bts_w=0
    while [ ! -s "$BT_F" ] && [ "$bts_w" -lt 50 ]; do sleep 0.1 2>/dev/null || sleep 1; bts_w=$((bts_w + 1)); done
    bts_nl=""; bts_end=$((BT_TS + 500))
    sleep() { bts_nl="$bts_nl $BT_FAKE"; }
    BT_FAKE=$BT_TS; BT_FAKE_NAP=1; bt_end 2>> "$BTS/log/err"; BT_FAKE=""; BT_FAKE_NAP=""
    unset -f sleep
    bts_steps "$BT_TS" "$bts_end" "$bts_nl"; bts_cd3="$bts_sa/$bts_sb/$bts_so/$bts_sh"
    BT_MAXB=$bts_vx
    #  an abort (bt_end abort, as cleanup() calls it) on a scan of 6 s younger than a second, both tools ignoring INT: the hold of the first INT (5 steps), the first INT, the 2 s
    #  to the second (10), all of 0.2 s. The abort is not in the steady state however far the scan's deadline is.
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'ignoreint\n' > "$BTS/cfg/S.mode"; printf 'ignoreint\n' > "$BTS/cfg/M.mode"; printf 'parent\n' > "$BTS/cfg/T.mode"; : > "$BTS/log/sig.log"
    BT_CUR=" "; BT_LOGGED=" "
    bt_begin 2> "$BTS/log/err"
    bts_nl=""
    sleep() { bts_nl="$bts_nl $BT_FAKE"; }
    BT_FAKE=$BT_TS; BT_FAKE_NAP=1; bt_end abort 2>> "$BTS/log/err"; BT_FAKE=""; BT_FAKE_NAP=""
    unset -f sleep
    bts_steps "$BT_TS" 0 "$bts_nl"; bts_cd4="$bts_sa/$bts_sb/$bts_so"
    bts_reap; BT_T_GRACE=$bts_vg; BT_T_MON=$bts_vm; BT_WIN=$bts_vw
    if [ "$bts_cd1" = 14/5/0/1 ] && [ "$bts_cd2" = 0/0 ] && [ "$bts_cd2b" -ge 5 ] && [ "$bts_cd3" = 4/15/0/1 ] && [ "$bts_cd4" = 0/15/0 ]; then
        st_pass "bt_end: the wait polls every 0.5 s while the scan lives and the watchdog's deadline is over a second away (14 steps for a 6 s window), then every 0.2 s up to the deadline (5), which is a clock of its own; a scan that is gone, a window stopped for its size and an abort keep 0.2 s"
    else st_fail "bt_end: cadence of the wait (scan alive $bts_cd1, want 14/5/0/1; scan gone: 0.5 s steps / other $bts_cd2, want 0/0, and $bts_cd2b steps of 0.2 s, want 5 or more; big window $bts_cd3, want 4/15/0/1; abort $bts_cd4, want 0/15/0)"; fi
    #  b) a scan that ignores INT and TERM: 12 INT (one a second), one TERM at 12 s, never KILL; it is still there afterwards (the pid file stays for bt_sweep)
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'same\n' > "$BTS/cfg/T.mode"; printf 'ignoreall\n' > "$BTS/cfg/S.mode"; : > "$BTS/log/sig.log"
    BT_CUR=" "; BT_LOGGED=" "
    { bt_begin; BTW_RC=$?; BT_FAKE=$BT_TS; bt_end; BT_FAKE=""; } 2> "$BTS/log/err"
    bts_sp=$(tail -n 1 "$BTS/log/pid.S"); bts_ni=$(bts_q "$bts_sp" INT); bts_nt=$(bts_q "$bts_sp" TERM); bts_nk=$(bts_q "$bts_sp" KILL)
    bts_alive=0; kill -0 "$bts_sp" 2>/dev/null && bts_alive=1
    if [ "$bts_ni/$bts_nt/$bts_nk" = 12/1/0 ] && [ "$bts_alive" = 1 ] && [ "$BT_VOID" = watchdog ] && [ -e "$BT_PF" ] && grep -q 'was terminated' "$BTS/log/err"; then
        st_pass "watchdog: a scan that ignores INT and TERM: 12 INT, one TERM at 12 s, never KILL, still alive afterwards, its pid file kept for bt_sweep, both log lines"
    else st_fail "watchdog: INT/TERM/KILL $bts_ni/$bts_nt/$bts_nk (want 12/1/0), alive $bts_alive, void [$BT_VOID], pid file [$(cd "$BTS/ram" 2>/dev/null && echo *)]"; fi
    bts_reap
    #  c) a monitor that ignores INT and TERM: INT, 2 s, TERM, 2 s, KILL (it holds no controller state); the scan ended on its own deadline first (real seconds)
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; printf 'ignoreall\n' > "$BTS/cfg/M.mode"; : > "$BTS/log/sig.log"
    BT_T_GRACE=100; BT_T_MON=200; BT_CUR=" "; BT_LOGGED=" "
    bt_begin 2> "$BTS/log/err"; bts_sp=$(tail -n 1 "$BTS/log/pid.S"); bts_mp=$(tail -n 1 "$BTS/log/pid.M"); bts_w=0
    while kill -0 "$bts_sp" 2>/dev/null && [ "$bts_w" -lt 100 ]; do sleep 0.1 2>/dev/null || sleep 1; bts_w=$((bts_w + 1)); done
    { BT_FAKE=$((BT_TS + 400)); bt_end; BT_FAKE=""; } 2>> "$BTS/log/err"
    BT_T_GRACE=0; BT_T_MON=100
    bts_ni=$(bts_q "$bts_mp" INT); bts_nt=$(bts_q "$bts_mp" TERM); bts_nk=$(bts_q "$bts_mp" KILL); bts_wsig=0; [ -s "$BTS/log/wrapper.sigs" ] && bts_wsig=1
    if [ "$bts_ni/$bts_nt/$bts_nk" = 1/1/1 ] && [ "$BT_VOID" = watchdog ] && [ "$bts_wsig" = 0 ] && [ "$(bts_q "$bts_sp" KILL)$(bts_q "$bts_sp" TERM)" = 00 ]; then
        st_pass "watchdog: a monitor that ignores INT and TERM gets INT, TERM, KILL in that order and is gone; the scan got nothing; no wrapper was signalled while its tool lived"
    else st_fail "watchdog: monitor INT/TERM/KILL $bts_ni/$bts_nt/$bts_nk (want 1/1/1), void [$BT_VOID], wrapper-signalled $bts_wsig"; fi
    bts_reap
    #  d) without /proc (no tool pid is known): only INT, only to the wrapper, and the wait ends
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; printf 'ignoreint\n' > "$BTS/cfg/S.mode"; : > "$BTS/log/sig.log"
    bts_pp=$BT_PROC; BT_PROC="$BTS/no-proc"; BT_T_TERM=200; BT_T_GRACE=100; BT_T_MON=200; BT_CUR=" "; BT_LOGGED=" "
    { bt_begin; BT_FAKE=$BT_TS; BT_FAKE_NAP=0.05; bt_end; BT_FAKE=""; BT_FAKE_NAP=""; } 2> "$BTS/log/err"
    BT_PROC=$bts_pp; BT_T_TERM=1200
    bts_kinds=$(awk '{ print $1 }' "$BTS/log/sig.log" | sort -u | tr '\n' ' ')
    bts_wp=$(tr '\n' ' ' < "$BTS/log/pid.T"); bts_toolsig=0; bts_sp2=$(awk '{ print $2 }' "$BTS/log/sig.log" | sort -u)
    for bts_x in $bts_sp2; do case " $bts_wp" in *" $bts_x "*) ;; *) bts_toolsig=1 ;; esac; done
    if [ "$bts_kinds" = "INT " ] && [ "$bts_toolsig" = 0 ] && [ -n "$bts_wp" ] && [ "$BT_VOID" = watchdog ]; then st_pass "watchdog: without /proc only INT is sent, and only to the wrappers (no tool pid is known), and the wait ends"; else st_fail "watchdog: without /proc (signals [$bts_kinds], tool signalled $bts_toolsig, void [$BT_VOID])"; fi
    bts_reap

    # 19) killed naps: a helper ends every sleep child of this shell each 0.5 s while a window runs; the deadlines still hold by the clock
    if bts_ps | grep -q .; then
        cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'same\n' > "$BTS/cfg/T.mode"; : > "$BTS/log/sig.log"; : > "$BTS/log/naps"
        # shellcheck disable=SC2016  # the helper's own script text
        ( while [ -d "$BTS/log" ] && kill -0 "$$" 2>/dev/null; do bts_ps | awk -v p="$$" '$2 == p && ($3 == "sleep" || $3 ~ /\/sleep$/) { print $1 }' | while read -r np; do kill "$np" 2>/dev/null && echo "$np" >> "$BTS/log/naps"; done; sleep 0.5; done ) 2>/dev/null &
        bts_kp=$!
        bts_t0=$(date +%s); bts_win; bts_t1=$(date +%s)
        kill -9 "$bts_kp" 2>/dev/null; wait "$bts_kp" 2>/dev/null
        bts_nn=$(wc -l < "$BTS/log/naps" | tr -d ' ')
        if [ "$BTW_RC" = 0 ] && [ -z "$BT_VOID" ] && [ "$bts_nn" -ge 1 ] && [ $((bts_t1 - bts_t0)) -le 12 ] && [ "$(sed -n '/^B/p' "$BT_F.out" 2>/dev/null | wc -l | tr -d ' ')" = 2 ]; then
            st_pass "naps: with $bts_nn of its sleeps ended by a helper the window still runs its course by the clock, in $((bts_t1 - bts_t0)) s, and the verdict counts"
        else st_fail "naps: window under a nap killer [rc $BTW_RC, void $BT_VOID, naps killed $bts_nn, $((bts_t1 - bts_t0)) s]"; fi
        rm -f "$BT_F.out"; bts_reap
    else log "  SKIP: killed naps (ps -o pid= -o ppid= -o comm= is not available here)"; fi

    # 20) the sweep at daemon start, on real collectors killed with -9 in the middle of their window (their tools run on, their pid file stays, under the
    #     name the code gave it): INT, never TERM or KILL, to each tool that runs with the recorded start; a start that differs is left alone; the file goes
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"; rm -f "$BTS/cfg/S.mode" "$BTS/cfg/M.mode"
    if bts_child; then
        kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null
        bts_up=0; bt_is "$BTS_CM" btmon && bt_is "$BTS_CS" hcitool && [ -e "$BTS_CF" ] && bts_up=1
        : > "$BTS/log/sig.log"; bt_busy; bts_bz=$?
        bt_sweep 2>/dev/null
        bts_x=0; while [ "$bts_x" -lt 30 ]; do bt_up "$BTS_CM" || bt_up "$BTS_CS" || break; sleep 0.1 2>/dev/null || sleep 1; bts_x=$((bts_x + 1)); done
        bts_gone=0; bt_up "$BTS_CM" || { bt_up "$BTS_CS" || bts_gone=1; }
        if [ "$bts_up" = 1 ] && [ "$bts_bz" = 1 ] && [ "$bts_gone" = 1 ] && [ "$(bts_q "$BTS_CM" INT)/$(bts_q "$BTS_CS" INT)" = 1/1 ] && [ "$(grep -c -e '^TERM' -e '^KILL' "$BTS/log/sig.log")" = 0 ] \
           && [ ! -e "$BTS_CF" ]; then
            st_pass "bt_sweep: a collector killed with -9 during its window (pid file written by the code, tools still running) -> the next daemon start's sweep sends one INT to the monitor and one to the scan, both end, the file goes; never TERM or KILL"
        else st_fail "bt_sweep: -9 case (tools running before $bts_up, busy $bts_bz, ended $bts_gone, signals [$(tr '\n' ' ' < "$BTS/log/sig.log")], file left $([ -e "$BTS_CF" ] && echo yes || echo no))"; fi
    else st_fail "bt_sweep: the stand-in collector did not write a pid file naming both tools [$(head -n 3 "$BTS/log/child.err" 2>/dev/null)]"; fi
    bts_child_end
    # a start field that differs (a pid that was reused): that tool is left alone, the other one gets its INT, and the file goes with nothing recorded left running
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"
    if bts_child; then
        kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null
        sed '/^M /s/ [0-9]*$/ 1/' "$BTS_CF" > "$BTS/in/child.pid"; cp "$BTS/in/child.pid" "$BTS_CF"; : > "$BTS/log/sig.log"
        bt_sweep 2>/dev/null
        bts_x=0; while [ "$bts_x" -lt 30 ]; do bt_up "$BTS_CS" || break; sleep 0.1 2>/dev/null || sleep 1; bts_x=$((bts_x + 1)); done
        bts_gs=0; bt_up "$BTS_CS" || bts_gs=1; bts_am=0; bt_up "$BTS_CM" && bts_am=1
        if [ "$bts_gs" = 1 ] && [ "$bts_am" = 1 ] && [ "$(bts_q "$BTS_CS" INT)/$(bts_q "$BTS_CM" INT)" = 1/0 ] && [ "$(grep -c -e '^TERM' -e '^KILL' "$BTS/log/sig.log")" = 0 ] && [ ! -e "$BTS_CF" ]; then
            st_pass "bt_sweep: a tool whose recorded start differs is left alone (no signal), the other gets its INT, the file goes"
        else st_fail "bt_sweep: differing start (scan gone $bts_gs, monitor alive $bts_am, signals [$(tr '\n' ' ' < "$BTS/log/sig.log")], file left $([ -e "$BTS_CF" ] && echo yes || echo no))"; fi
    else st_fail "bt_sweep: the second stand-in collector did not write a pid file naming both tools"; fi
    bts_child_end
    # and the same for the scan: its recorded start differs (a reused pid), so the scan gets no signal at all (hcitool is only ever sent INT, and not to a stranger), the monitor still gets its one INT,
    # and the file goes once nothing recorded in it lives. The check of the start is on the S line of bt_sweep as it is on the M line, and bt_busy has it on both (the overlap case).
    bts_reap; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"
    if bts_child; then
        kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null
        sed '/^S /s/ [0-9]*$/ 1/' "$BTS_CF" > "$BTS/in/child.pid"; cp "$BTS/in/child.pid" "$BTS_CF"; : > "$BTS/log/sig.log"
        bt_sweep 2>/dev/null
        bts_x=0; while [ "$bts_x" -lt 30 ]; do bt_up "$BTS_CM" || break; sleep 0.1 2>/dev/null || sleep 1; bts_x=$((bts_x + 1)); done
        bts_gm=0; bt_up "$BTS_CM" || bts_gm=1; bts_as=0; bt_up "$BTS_CS" && bts_as=1
        if [ "$bts_gm" = 1 ] && [ "$bts_as" = 1 ] && [ "$(bts_q "$BTS_CM" INT)/$(bts_q "$BTS_CS" INT)" = 1/0 ] && [ "$(bts_q "$BTS_CS" TERM)$(bts_q "$BTS_CS" KILL)" = 00 ] \
           && [ "$(grep -c -e '^TERM' -e '^KILL' "$BTS/log/sig.log")" = 0 ] && [ ! -e "$BTS_CF" ]; then
            st_pass "bt_sweep: a scan whose recorded start differs is left alone (no signal), the monitor gets its one INT, the file goes"
        else st_fail "bt_sweep: differing scan start (monitor gone $bts_gm, scan alive $bts_as, signals [$(tr '\n' ' ' < "$BTS/log/sig.log")], file left $([ -e "$BTS_CF" ] && echo yes || echo no))"; fi
    else st_fail "bt_sweep: the third stand-in collector did not write a pid file naming both tools"; fi
    bts_child_end
    # the marker: a collector still waiting for its monitor holds only the marker line "P PID" (its monitor says nothing and holds no socket for 3 s). A start meets it as a
    # live window (rc 5, no call, no file of its own left: two starts at one moment cannot both run), and once that collector is gone the file is no window and the sweep removes it
    bts_reap; printf 'silent\n' > "$BTS/cfg/M.mode"; printf 'parent\n' > "$BTS/cfg/T.mode"
    if bts_child 15 '^P [0-9]'; then
        bts_mk=$(cat "$BTS_CF" 2>/dev/null); bts_c0=$(cat "$BTS/log/argv.M" "$BTS/log/argv.S" 2>/dev/null | wc -l | tr -d ' ')
        bt_busy; bts_b1=$?
        bt_begin 2>/dev/null; bts_rc=$?
        bts_c1=$(cat "$BTS/log/argv.M" "$BTS/log/argv.S" 2>/dev/null | wc -l | tr -d ' ')
        set -- "$BTS"/ram/starchorus-bt-$$.*; bts_own=0; [ -e "$1" ] && bts_own=1
        kill -9 "$BTS_CH" 2>/dev/null; wait "$BTS_CH" 2>/dev/null
        bt_busy; bts_b2=$?; bt_sweep 2>/dev/null; bts_gone=0; [ -e "$BTS_CF" ] || bts_gone=1
        if [ "$bts_mk" = "P $BTS_CH" ] && [ "$bts_b1/$bts_b2" = 0/1 ] && [ "$bts_rc" = 5 ] && [ "$bts_c0" = "$bts_c1" ] && [ "$bts_own" = 0 ] && [ "$bts_gone" = 1 ]; then
            st_pass "bt_begin: a collector that has only written its marker line (\"P pid\") counts as a live window: rc 5, no call, no file left; once it is gone the file is no window and bt_sweep removes it"
        else st_fail "bt_begin: marker case [$bts_mk] busy $bts_b1/$bts_b2 (want 0/1), rc $bts_rc, calls $bts_c0/$bts_c1, own file $bts_own, file gone after the sweep $bts_gone"; fi
    else st_fail "bt_begin: the stand-in collector did not write its marker line [$(head -n 3 "$BTS/log/child.err" 2>/dev/null)]"; fi
    bts_child_end; rm -f "$BTS/cfg/M.mode"

    # 23) bookkeeping through a whole cycle: the capture source, with a window against the stand-ins; then the flag off must leave every Bluetooth variable and file alone
    cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"
    bts_rs=$RESOLVED; bts_cm=$CAP_METHOD; bts_of=$OUTFILE; bts_ve=$VENDOR; bts_od=$OUTDIR; bts_hd=$BT_HELD
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$BTS/cycle.json"; OUTDIR="$BTS"; VENDOR=0; BT_HELD=""
    bts_t0=$(date +%s); run_cycle 2> "$BTS/log/err" >/dev/null; bts_t1=$(date +%s)
    bts_c1=0; json_ok < "$OUTFILE" && bts_c1=1
    bts_c2=0; grep -q '^  "bluetooth": \[{"addr": "02:00:00:00:00:02", "addr_type": "random-resolvable", "rssi": -49, "reports": 2, "last_seen": [0-9]*, "company": 65535, "company_name": "Maker A", "connectable": true}, {"addr": "02:00:00:00:00:03"' "$OUTFILE" && bts_c2=1
    bts_c3=0; grep -q '"bt_window": 1, "bt_hold": 120' "$OUTFILE" && bts_c3=1
    bts_c4=0; grep -q '"ssid": "HomeNet"' "$OUTFILE" && bts_c4=1
    bts_c5=0; [ -n "$BT_HELD" ] && bts_c5=1
    if [ "$bts_c1$bts_c2$bts_c3$bts_c4$bts_c5" = 11111 ]; then
        st_pass "run_cycle: a capture-source cycle with a Bluetooth window, in $((bts_t1 - bts_t0)) s, publishes the Wi-Fi document with the bluetooth array, bt_window and bt_hold, and keeps the records for the next cycle"
    else st_fail "run_cycle: capture cycle with a window (checks $bts_c1$bts_c2$bts_c3$bts_c4$bts_c5, $(grep bluetooth "$OUTFILE" | cut -c1-200), log [$(head -n 3 "$BTS/log/err")])"; fi
    bts_idle "capture cycle"
    bts_reap
    BLUETOOTH=0; BT_RC=3; run_cycle 2>/dev/null >/dev/null
    if json_ok < "$OUTFILE" && ! grep -q '"bluetooth"' "$OUTFILE" && ! grep -q 'bt_window' "$OUTFILE" && [ ! -e "$BTS/log/argv.M" ]; then st_pass "run_cycle: with Bluetooth off no tool is called and no Bluetooth field is written"; else st_fail "run_cycle: Bluetooth off still writes or calls"; fi
    # the iwscan route without its opt-in has no data: the cycle publishes the explicit empty document, and the layer goes on that one too (another
    # collector's window makes the cycle a void one, which costs no time; the records of the capture cycle are held for the next 120 s)
    BLUETOOTH=1; bts_other; RESOLVED=iwscan; run_cycle 2>/dev/null >/dev/null
    if json_ok < "$OUTFILE" && grep -q 'no data this cycle' "$OUTFILE" && grep -q '^  "bluetooth": \[{"addr": "02:00:00:00:00:02"' "$OUTFILE" && grep -q '"bt_window": 0, "bt_hold": 120' "$OUTFILE"; then
        st_pass "run_cycle: a cycle without data (the iwscan route, not opted in) publishes the empty document with the layer on it: the held records, bt_window 0"
    else st_fail "run_cycle: empty document with the layer, $(grep -c . "$OUTFILE") lines"; fi
    bts_other_end; bts_idle "iwscan cycle"
    RESOLVED=$bts_rs; CAP_METHOD=$bts_cm; OUTFILE=$bts_of; VENDOR=$bts_ve; OUTDIR=$bts_od; BT_HELD=$bts_hd
    bts_reap
    # ---- the readiness poll and the verdict without processes (0.2.6): bt_ready asks `test -S` of each descriptor (it was a readlink process per descriptor, three or four
    #      polls of three or four descriptors), bt_judge reads its two lines with builtins (it was two sed | head pipelines). Each check is also run against the
    #      planted old form, which must fail it: a check that the old text passes would prove nothing. A logging stand-in for readlink, sed and head counts the processes.
    gc_proc=$BT_PROC; gc_fake=$BT_FAKE; gc_bf=$BT_F; gc_tr=$BT_T_READY; gc_path=$PATH
    gc_cur=$BT_CUR; gc_logged=$BT_LOGGED; gc_notes=$BT_NOTES; gc_big=$BT_BIG
    mkdir -p "$BTS/gccnt" "$BTS/gcproc/777/fd" "$BTS/gcproc/778/fd" "$BTS/gcproc/779/fd"
    for gc_n in readlink sed head; do
        gc_real=$(command -v "$gc_n"); printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "%s/gc.log"\nexec %s "$@"\n' "$gc_n" "$BTS" "$gc_real" > "$BTS/gccnt/$gc_n"; chmod +x "$BTS/gccnt/$gc_n"
    done
    : > "$BTS/gc.txt"; BT_F="$BTS/gc.txt"; BT_T_READY=300; BT_PROC="$BTS/gcproc"
    ln -s /dev/null "$BTS/gcproc/777/fd/0"; ln -s /dev/null "$BTS/gcproc/777/fd/1"; [ "$bts_sock" = 0 ] || ln -s "$BTS/sock" "$BTS/gcproc/777/fd/3"
    ln -s /dev/null "$BTS/gcproc/778/fd/0"; ln -s 'socket:[1]' "$BTS/gcproc/778/fd/3"
    ln -s /dev/null "$BTS/gcproc/779/fd/0"; ln -s /dev/null "$BTS/gcproc/779/fd/1"
    # the planted old form of bt_ready (one readlink per descriptor), run through gc_rdy
    # shellcheck disable=SC2329  # called by name from gc_rdy
    bt_ready_old() {
        bt_tick; br_t=$BT_NOW
        while :; do
            if [ -s "$BT_F" ] && grep -q -v '^Bluetooth monitor ver' "$BT_F" 2>/dev/null; then return 0; fi
            if [ -n "$1" ]; then
                for br_f in "$BT_PROC/$1"/fd/*; do
                    case $(readlink "$br_f" 2>/dev/null) in socket:*) return 0 ;; esac
                done
            fi
            bt_tick; [ $((BT_NOW - br_t)) -lt $((BT_T_READY + BT_SLK)) ] || return 1
            bt_nap
        done
    }
    # gc_rdy new|old PID: prints "RC/readlink-calls"; the clock is a fake one the naps move on, so that nothing sleeps
    gc_rdy() { : > "$BTS/gc.log"; BT_FAKE=1000; PATH="$BTS/gccnt:$gc_path"; case $1 in new) bt_ready "$2" ;; *) bt_ready_old "$2" ;; esac >/dev/null 2>&1; gc_r=$?; PATH=$gc_path; BT_FAKE=$gc_fake; printf '%s/%s' "$gc_r" "$(grep -c readlink "$BTS/gc.log")"; }
    if [ "$bts_sock" = 1 ]; then
        gc_a=$(gc_rdy new 777); gc_b=$(gc_rdy new 778); gc_c=$(gc_rdy new 779); gc_d=$(gc_rdy old 777); gc_e=$(gc_rdy old 779)
        # new: a descriptor that is a socket is ready, a text link to socket:[1] and plain devices are not, and no readlink process is started; the old form starts one per
        # descriptor and does not see the stand-in's socket (a link to a path, not to text), so the same check turns red on it
        if [ "${gc_a%%/*}/${gc_b%%/*}/${gc_c%%/*}" = 0/1/1 ] && [ "${gc_a#*/}${gc_b#*/}${gc_c#*/}" = 000 ] && [ "${gc_d%%/*}" = 1 ] && [ "${gc_d#*/}" -ge 1 ] && [ "${gc_e#*/}" -ge 2 ]; then
            st_pass "bt_ready: a monitor that holds a socket (a real one in the stand-in /proc) is ready by test -S with no process, a text link and plain descriptors are not; the old readlink form starts $((${gc_d#*/} + ${gc_e#*/})) processes in the same polls and does not see the socket (fails the same check)"
        else st_fail "bt_ready: test -S (rc/readlink calls $gc_a $gc_b $gc_c, want 0 1 1 with no readlink; old form $gc_d $gc_e)"; fi
    else log "  SKIP: bt_ready on a real socket (python3 could not bind a socket file here; the stand-in keeps the text link socket:[1], which test -S does not accept; device appointment D7)"; fi
    # bt_judge: the same verdicts as before on four outputs (W only, W and F, a long output whose W comes after 64 lines, no output), and no sed or head process for a short one
    printf 'B\t02:00:00:00:00:02\tpublic\t-60\t2\t\t\t\t1\nB\t02:00:00:00:00:03\tpublic\t-70\t1\t\t\t\t1\nW\t1\t0\t1\t1\t0\t0\t0\n' > "$BTS/gcj.1"
    printf 'B\t02:00:00:00:00:02\tpublic\t-60\t2\t\t\t\t1\nW\t1\t0\t1\t1\t0\t0\t1\nF\t1\t0\n' > "$BTS/gcj.2"
    { gc_i=0; while [ "$gc_i" -lt 100 ]; do printf 'B\t02:00:00:00:%02x:%02x\tpublic\t-60\t1\t\t\t\t1\n' $((gc_i / 256)) $((gc_i % 256)); gc_i=$((gc_i + 1)); done
      printf 'W\t1\t0\t1\t1\t0\t0\t1\nF\t0\t1\n'; } > "$BTS/gcj.3"
    : > "$BTS/gcj.4"
    gc_j=""
    for gc_k in 1 2 3 4; do
        BT_CUR=" "; BT_LOGGED=" "; BT_NOTES=""; BT_BIG=0
        : > "$BTS/gc.log"; PATH="$BTS/gccnt:$gc_path"; bt_judge "$BTS/gcj.$gc_k" 2>/dev/null; gc_r=$?; PATH=$gc_path
        gc_j="$gc_j $gc_r:${BT_VOID:-ok}:$(grep -c . "$BTS/gc.log")"
    done
    # the planted old form: the two pipelines, counted by the same stand-ins
    : > "$BTS/gc.log"; PATH="$BTS/gccnt:$gc_path"; sed -n '/^W/p' "$BTS/gcj.1" 2>/dev/null | head -n 1 > /dev/null; sed -n '/^F/p' "$BTS/gcj.1" 2>/dev/null | head -n 1 > /dev/null; PATH=$gc_path
    gc_old=$(grep -c . "$BTS/gc.log")
    if [ "$gc_j" = " 0:ok:0 1:other:0 1:order:4 1:nopassive:0" ] && [ "$gc_old" = 4 ]; then
        st_pass "bt_judge: the verdicts are the old ones (W only counts; an F line voids it as another scan; a long output is judged from its end; no output is no passive block), a short output starts no sed or head process (the old two pipelines start $gc_old), a long one falls back to them"
    else st_fail "bt_judge: by builtins ($gc_j, want 0:ok:0 1:other:0 1:order:4 1:nopassive:0; old form $gc_old processes)"; fi
    BT_PROC=$gc_proc; BT_FAKE=$gc_fake; BT_F=$gc_bf; BT_T_READY=$gc_tr; PATH=$gc_path; BT_CUR=$gc_cur; BT_LOGGED=$gc_logged; BT_NOTES=$gc_notes; BT_BIG=$gc_big
    unset -f bt_ready_old gc_rdy
    bt_env off
    unset -f bts_q bts_win
}

# ============================================================================ SELF TEST
# Runs entirely offline with embedded sample data (airodump CSV, recon.db in every schema family,
# tcpdump -e text, OUI files): every emitter, the post-passes (center extras, homing, vendor with
# its cache and lock), run_cycle, a real overlapping --once and the apcli_ro allowlist.
json_ok() {
    # Validate JSON on stdin. Prefer jq, then python3, else a minimal brace-balance sanity check.
    if have jq; then jq -e . >/dev/null 2>&1
    elif have python3; then python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1
    else
        awk '{n+=gsub(/{/,"{"); m+=gsub(/}/,"}")} END{exit (n>0 && n==m)?0:1}'
    fi
}

selftest() {
    # Verdict = the FAIL counter ST_FAILS (a deliberately unique name: a short global like `rc`
    # can be clobbered by any helper called later and silently turn a red run green).
    ST_FAILS=0; ST_PASS=0
    # Nothing here may reach a radio or the controller, whatever the environment holds: the switches are forced off, for this process and for the collectors
    # it starts (they read the environment), and the controller's sysfs points at nothing. A case that needs a switch sets it itself, inside its stand-in
    # block (bt_env, the apcli stubs, a child's own environment). The alert log is out of reach too: a device that has logged an alert has a non-empty
    # alerts.log, which would put a layer (and a recent line) into every document and fail the cycle and vendor cases for a reason that is no fault of the collector.
    STARCHORUS_BLUETOOTH=0; STARCHORUS_TRAFFIC=0; STARCHORUS_APCLI_RO=0; STARCHORUS_ALLOW_ACTIVE=0; STARCHORUS_SYSFS_BT=/nonexistent/starchorus-selftest-bt
    STARCHORUS_ALERTS=0; STARCHORUS_ALERT_DIR=/nonexistent/starchorus-selftest-alerts
    # The Bluetooth source is pinned to the window, and the firmware's database and the company list to paths that do not exist: on a 2.0 Pager
    # /root/recon/blue5.db is there, and `auto` would read the device's real database (real addresses in a test's output) where the cases
    # expect their own stand-ins. A case that reads blue5.db or a company list sets BLUE5_DB or BTCO_PATH itself, inside its block.
    STARCHORUS_BT_SOURCE=window; STARCHORUS_BLUE5_DB=/nonexistent/starchorus-selftest-blue5.db; STARCHORUS_BT_COMPANIES_FILE=/nonexistent/starchorus-selftest-bt-companies.txt
    export STARCHORUS_BLUETOOTH STARCHORUS_TRAFFIC STARCHORUS_APCLI_RO STARCHORUS_ALLOW_ACTIVE STARCHORUS_SYSFS_BT STARCHORUS_ALERTS STARCHORUS_ALERT_DIR
    export STARCHORUS_BT_SOURCE STARCHORUS_BLUE5_DB STARCHORUS_BT_COMPANIES_FILE
    BLUETOOTH=0; TRAFFIC=0; APCLI_RO=0; ALLOW_ACTIVE=0; BT_SYSFS=$STARCHORUS_SYSFS_BT; ALERTS=0; ALERT_DIR=$STARCHORUS_ALERT_DIR
    BT_SOURCE=window; BLUE5_DB=$STARCHORUS_BLUE5_DB; BT_SRC=window; BTCO_FILE=$STARCHORUS_BT_COMPANIES_FILE; BTCO_PATH=""
    tdir=$(mktemp -d 2>/dev/null || echo /tmp/starchorus-selftest.$$)
    mkdir -p "$tdir"
    OUTDIR="$tdir"; CAPDIR="$tdir/cap"; mkdir -p "$CAPDIR"
    # An interrupted run (Ctrl-C, a hang-up, the time limit of tools/device-probe.sh) removes its workspace and ends with 128 plus the signal (a trap that only
    # returned would leave the shell running, as cleanup() explains). The long-lived stand-ins poll that workspace and this shell and end by themselves
    # within a second of either going, so none is left polling until a reboot or later reported as another collector's loop. Two things in the code under test
    # change these traps: cleanup() clears them (the case that calls it re-arms them with st_arm), and bt_begin sets a HUP trap of its own (cleanup, then exit),
    # so a hang-up after the first Bluetooth window leaves the workspace behind; the stand-ins still end with the shell.
    # shellcheck disable=SC2329  # called by name from the traps
    st_abort() { trap - INT TERM HUP; rm -rf "$tdir" 2>/dev/null; exit "$1"; }
    st_arm() { trap 'st_abort 130' INT; trap 'st_abort 143' TERM; trap 'st_abort 129' HUP; }
    st_arm
    log "selftest workspace: $tdir"

    st_pass() { log "  PASS: $1"; ST_PASS=$((ST_PASS+1)); }
    st_fail() { log "  FAIL: $1"; ST_FAILS=$((ST_FAILS+1)); }
    check() {  # desc, haystack, needle (basic regex)
        if printf '%s' "$2" | grep -q -- "$3"; then st_pass "$1"; else st_fail "$1  (missing: $3)"; fi
    }
    checkf() {  # desc, haystack, FIXED-string needle (for needles containing \ or ")
        if printf '%s' "$2" | grep -qF -- "$3"; then st_pass "$1"; else st_fail "$1  (missing: $3)"; fi
    }
    checkno() {  # desc, haystack, needle that must be ABSENT
        if printf '%s' "$2" | grep -q -- "$3"; then st_fail "$1  (unexpected: $3)"; else st_pass "$1"; fi
    }
    jcheck() {  # name, document: "<name> valid JSON"
        if printf '%s' "$2" | json_ok; then st_pass "$1 valid JSON"; else st_fail "$1 JSON"; fi
    }

    # ---- 1) airodump CSV -------------------------------------------------------------------
    cat > "$CAPDIR/starchorus-01.csv" <<'CSV'
BSSID, First time seen, Last time seen, channel, Speed, Privacy, Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
AA:BB:CC:00:11:22, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 6, 130, WPA2, CCMP, PSK, -42, 100, 0, 0.0.0.0, 8, HomeNet,
DD:EE:FF:33:44:55, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 149, 866, OPN, , , -70, 50, 0, 0.0.0.0, 7, Caf, e Guest,

Station MAC, First time seen, Last time seen, Power, # packets, BSSID, Probed ESSIDs
11:22:33:44:55:66, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -55, 20, AA:BB:CC:00:11:22,
99:88:77:66:55:44, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -80, 5, (not associated), FreeWifi
CSV
    out=$(build_from_csv 1710000000 2>/dev/null)
    jcheck "airodump-csv" "$out"
    check "airodump: source label"        "$out" '"source": "airodump-csv"'
    check "airodump: WPA2 AP"             "$out" '"security": "WPA2/PSK/CCMP"'
    check "airodump: 5GHz band from ch149" "$out" '"band": "5GHz"'
    check "airodump: comma-in-ESSID kept"  "$out" 'Caf, e Guest'
    check "airodump: associated client"    "$out" '"mac": "11:22:33:44:55:66"'
    check "airodump: unassociated client"  "$out" '"mac": "99:88:77:66:55:44"'
    checkf "airodump: probed ESSID -> probes" "$out" '"rssi": -80, "probes": ["FreeWifi"]'
    check "airodump: rate from Speed (130)" "$out" '"security": "WPA2/PSK/CCMP", "rate": 130, "clients"'
    check "airodump: rate from Speed (866)" "$out" '"rate": 866'

    # ---- 1a) an interrupted run: a second copy of this selftest is started and told to stop with TERM (as tools/device-probe.sh does at its time limit) as soon as it has made
    #          its workspace; it must end with 143 and take that workspace with it (st_abort). A background job cannot trap INT, so TERM stands for the three signals.
    #          The second copy is told whose it is (STARCHORUS_SELFTEST_NESTED holds the pid of this shell, which a copy takes for its own only when it is also its parent's pid) and
    #          leaves this case out: otherwise it would reach it before it is stopped, start a third copy and leave that one running, and so on without end.
    if [ "${STARCHORUS_SELFTEST_NESTED:-}" != "$PPID" ]; then
        sab_o="$tdir/abort.out"; sab_w=""; sab_hung=0
        exec 4>&2 2>/dev/null
        STARCHORUS_SELFTEST_NESTED=$$ sh "$0" --selftest > "$sab_o" 2>&1 & sab_p=$!
        sab_n=0
        while [ -z "$sab_w" ] && [ "$sab_n" -lt 100 ]; do
            sab_w=$(sed -n 's/^\[starchorus\] selftest workspace: //p' "$sab_o" | head -n 1)
            [ -n "$sab_w" ] || { sleep 0.2 2>/dev/null || sleep 1; }
            sab_n=$((sab_n + 1))
        done
        if [ -n "$sab_w" ]; then
            kill -TERM "$sab_p"
            sab_n=0; while kill -0 "$sab_p" && [ "$sab_n" -lt 50 ]; do sleep 0.2 2>/dev/null || { sleep 1; sab_n=$((sab_n + 4)); }; sab_n=$((sab_n + 1)); done
        fi
        if kill -0 "$sab_p"; then kill -9 "$sab_p"; sab_hung=1; fi
        wait "$sab_p"; sab_rc=$?
        sab_gone=0; [ -n "$sab_w" ] && [ ! -d "$sab_w" ] && sab_gone=1
        [ -z "$sab_w" ] || rm -rf "$sab_w"
        exec 2>&4 4>&-
        if [ "$sab_rc/$sab_gone/$sab_hung" = 143/1/0 ]; then st_pass "selftest: an interrupted run (TERM) ends with 143 and removes its workspace"
        else st_fail "selftest: an interrupted run (rc $sab_rc, workspace [$sab_w] gone $sab_gone, had to be killed $sab_hung)"; fi
    else
        log "  SKIP: the interrupted-run case is left to the copy that started this one"
    fi

    # ---- 1b) Bluetooth, the per-cycle layers and the traffic call: the text of a window (no process), the layers (files), a window against stand-ins
    bt_parse_selftest "$tdir"
    # blue5 fixture for the layers selftest, built here where a non-read-only sqlite3 is a test fixture (not a production read); lay_selftest reads it
    LAY_BLUE5_FIX="$tdir/blue5-fix.db"
    if have sqlite3; then rm -f "$LAY_BLUE5_FIX"; sqlite3 "$LAY_BLUE5_FIX" "CREATE TABLE bt_device(scan INT,mac TEXT,first_seen INT,last_seen INT,transports INT,le_random INT,connectable INT,rssi INT,rssi_min INT,rssi_max INT,rssi_avg INT,tx_power INT,company INT,cod INT,packets INT,name BLOB,name_complete INT,PRIMARY KEY(scan,mac));
INSERT INTO bt_device(scan,mac,last_seen,transports,le_random,connectable,rssi_avg,packets,company,name) VALUES
 (1,'AABBCC000001',1000000,1,0,1,-50,10,76,'Pub'),(1,'C0AABB000002',1000000,1,1,1,-60,5,12,'Stat'),
 (1,'40AABB000003',1000000,1,1,0,-70,1,46517,'Res'),(1,'AABBCC000005',1000000,1,0,1,-55,0,65535,'t'||char(9)||'n'),
 (1,'AABBCC000006',1000000,1,0,1,NULL,10,76,'x'),(1,'AABBCC000007',999800,1,0,1,-50,10,76,'old'),
 (1,'AABBCC000009',1000000,2,0,1,-50,10,76,'cls'),(1,'AABBCC00000A',999990,1,0,1,-90,3,76,'o'),
 (2,'AABBCC00000A',1000000,1,0,1,-40,7,76,'n');" 2>/dev/null; else LAY_BLUE5_FIX=""; fi
    lay_selftest "$tdir"
    printf '%s\n' "$out" > "$tdir/emit-csv.json"; lay_check "airodump-csv document" "$tdir/emit-csv.json"
    write_empty 1710000000 "no data" > "$tdir/emit-empty.json"; lay_check "write_empty document" "$tdir/emit-empty.json"
    bt_selftest "$tdir"

    # ---- 2) recon.db, running `ssid` schema --------------------------------------------------
    if have sqlite3; then
        pdb="$tdir/recon_ssid.db"
        # 1<<57 = 144115188075855872 ; +16 (WPA3 bit) exercises the >2^53 SQL bit-extraction.
        sqlite3 "$pdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid (scan INTEGER, type INTEGER, apmac TEXT, stamac TEXT, ssid BLOB,
                   encryption INTEGER, freq INTEGER, signal INTEGER, hidden INTEGER, band TEXT);
CREATE TABLE wifi_device (hash INTEGER, mac TEXT, packets INTEGER);
-- APs (type 8 beacon):  open, WPA2, WPA3-SAE(6GHz), hidden(2.4)
INSERT INTO ssid VALUES (1,8,'aabbcc001122','', 'OpenAir',      0,   2437, -40, 0, '2');
INSERT INTO ssid VALUES (1,8,'aabbcc334455','', 'SecureHome',   8,   5240, -55, 0, '5');
INSERT INTO ssid VALUES (1,8,'aabbcc667788','', 'Mesh6E', 144115188075855888, 5955, -66, 0, '6');
INSERT INTO ssid VALUES (1,8,'aabbccaabbcc','', '',             8,   2412, -60, 1, '2');
-- 6GHz channel 2 sits at 5935 MHz (not 5950+2*5); this schema has no channel column
INSERT INTO ssid VALUES (1,8,'aabbcc66aa02','', 'Mesh6E-Ch2',   8,   5935, -70, 0, '6');
-- duplicate/older observation of SecureHome, weaker signal, must be deduped by GROUP BY
INSERT INTO ssid VALUES (2,8,'aabbcc334455','', 'SecureHome',   8,   5240, -77, 0, '5');
-- probe-response (type 5) for an AP not seen via beacon
INSERT INTO ssid VALUES (1,5,'aabbccddeeff','', 'ProbeRespNet', 4,   2462, -50, 0, '2');
-- probe requests (type 4) -> unassociated clients
INSERT INTO ssid VALUES (1,4,'','1122aabbccdd','FreeWifi',      0,   0,    -72, 0, '');
INSERT INTO ssid VALUES (1,4,'','1122aabbccee','',              0,   0,    -83, 0, '');
SQL
        out=$(RECON_DB="$pdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(ssid)" "$out"
        printf '%s\n' "$out" > "$tdir/emit-recon0.json"; lay_check "recon.db document" "$tdir/emit-recon0.json"
        check "recon: source label"      "$out" '"source": "recon-db"'
        check "recon: open AP"           "$out" '"ssid": "OpenAir"'
        check "recon: Open security"     "$out" '"security": "Open"'
        check "recon: WPA2"              "$out" '"security": "WPA2"'
        check "recon: WPA3 via SAE bit"  "$out" '"security": "WPA3"'
        check "recon: 6GHz band"         "$out" '"band": "6GHz"'
        check "recon: bssid colonised"   "$out" '"bssid": "aa:bb:cc:00:11:22"'
        check "recon: probe-resp AP"     "$out" 'ProbeRespNet'
        check "recon: unassociated probe" "$out" '"mac": "11:22:aa:bb:cc:dd"'
        checkf "recon: probed SSID -> probes" "$out" '"probes": ["FreeWifi"]'
        checkf "recon: wildcard probe carries no probes" "$out" '"mac": "11:22:aa:bb:cc:ee", "rssi": -83}'
        check "recon: 6GHz channel 2 from freq 5935" "$(printf '%s\n' "$out" | grep 'aa:bb:cc:66:aa:02')" '"channel": 2, "band": "6GHz", "freq": 5935'
        # dedup: SecureHome must appear exactly once, and at the strong -55 (not -77)
        cnt=$(printf '%s\n' "$out" | grep -c 'SecureHome')
        if [ "$cnt" = "1" ]; then st_pass "recon dedup (SecureHome x1)"; else st_fail "recon dedup (x$cnt)"; fi
        check "recon: strong signal kept" "$out" '"rssi": -55'

        # ---- 2b) recon.db, RUNNING-firmware `ssid` schema (bssid + channel + wifi_device join).
        #      Uses the real encryption integers observed on-device (libwifi bitmask: bit3=WPA2,
        #      bit4=WPA3) to prove the SQL bit-extraction decodes real values correctly.
        rdb="$tdir/recon_real.db"
        sqlite3 "$rdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT,
                  UNIQUE(hash) ON CONFLICT REPLACE);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT,
                  packets INT, UNIQUE(hash) ON CONFLICT REPLACE);
-- beacons (type 8): open(enc 0), WPA2, WPA3(SAE), WPA2/WPA3 transition, hidden, 6GHz
INSERT INTO ssid VALUES (1,0,1,8,'AABBCC001122','OpenGuest',        0,0,-50,5220,44, 0);
INSERT INTO ssid VALUES (2,0,1,8,'AABBCC334455','HomeNet-5G',   0,0,-55,5500,64, 17184063752);
INSERT INTO ssid VALUES (3,0,1,8,'AABBCC667788','SAE-Only',         0,0,-66,5955, 1, 6597073961232);
INSERT INTO ssid VALUES (4,0,1,8,'AABBCC99AABB','Transition',       0,0,-58,2437, 6, 2216207319320);
INSERT INTO ssid VALUES (5,0,1,8,'AABBCCCCDDEE','',                 1,0,-71,5785,157,17184063752);
-- older, weaker duplicate observation of the WPA2 net -> must dedupe to one, keep -55
INSERT INTO ssid VALUES (6,0,2,8,'AABBCC334455','HomeNet-5G',   0,0,-77,5500,64, 17184063752);
-- probe-response (type 5) AP not seen via beacon
INSERT INTO ssid VALUES (7,0,1,5,'AABBCCF00D01','ProbeRespOnly',    0,0,-52,2462,11, 17184063752);
-- probe-request stations (type 4) linked through wifi_device
INSERT INTO ssid VALUES (8,101,1,4,'FFFFFFFFFFFF','FreeWifi',       0,0,-72,0,0, 0);
INSERT INTO ssid VALUES (9,102,1,4,'FFFFFFFFFFFF','',               0,0,-83,0,0, 0);
INSERT INTO wifi_device VALUES (101,1,'1122AABBCCDD',0,-72,0,5);
INSERT INTO wifi_device VALUES (102,1,'1122AABBCCEE',0,-83,0,2);
SQL
        out=$(RECON_DB="$rdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(real ssid)" "$out"
        check "real: open (enc 0)"        "$out" '"ssid": "OpenGuest"'
        check "real: WPA2 (bit3)"         "$out" '"security": "WPA2"'
        check "real: WPA3 (bit4/SAE)"     "$out" '"security": "WPA3"'
        check "real: WPA2/WPA3 transition" "$out" '"security": "WPA3/WPA2"'
        check "real: 6GHz from freq 5955"  "$out" '"band": "6GHz"'
        check "real: probe-resp AP"        "$out" 'ProbeRespOnly'
        checkf "real: probed SSID -> probes"  "$out" '"probes": ["FreeWifi"]'
        checkf "real: wildcard probe no probes" "$out" '"mac": "11:22:aa:bb:cc:ee", "rssi": -83}'
        check "real: bssid colonised"      "$out" '"bssid": "aa:bb:cc:00:11:22"'
        check "real: client via wifi_device join" "$out" '"mac": "11:22:aa:bb:cc:dd"'
        rcnt=$(printf '%s\n' "$out" | grep -c 'HomeNet-5G')
        if [ "$rcnt" = "1" ]; then st_pass "real dedup (HomeNet-5G x1)"; else st_fail "real dedup (x$rcnt)"; fi

        # ---- 2c) STARCHORUS_MAX_AGE live-presence window: only recent rows survive -----------------
        adb="$tdir/recon_age.db"; now=$(date +%s 2>/dev/null); [ -n "$now" ] || now=1789312406
        old=$((now - 100000))
        sqlite3 "$adb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'AAAAAAAA0001','RecentAP',0,$now,-50,2437,6,8);
INSERT INTO ssid VALUES (2,0,1,8,'BBBBBBBB0002','StaleAP', 0,$old,-60,2437,6,8);
INSERT INTO ssid VALUES (3,301,1,4,'FFFFFFFFFFFF','',0,$now,-70,0,0,0);
INSERT INTO ssid VALUES (4,302,1,4,'FFFFFFFFFFFF','',0,$old,-80,0,0,0);
INSERT INTO wifi_device VALUES (301,1,'AA11AA11AA11',$now,-70,0,1);
INSERT INTO wifi_device VALUES (302,1,'BB22BB22BB22',$old,-80,0,1);
SQL
        full=$(RECON_DB="$adb" MAX_AGE=0 build_from_recondb 1710000000 2>/dev/null)
        live=$(RECON_DB="$adb" MAX_AGE=300 build_from_recondb 1710000000 2>/dev/null)
        if printf '%s' "$full" | grep -q 'RecentAP' && printf '%s' "$full" | grep -q 'StaleAP'; then
            st_pass "MAX_AGE=0 keeps full history (RecentAP+StaleAP)"; else st_fail "MAX_AGE=0 history"; fi
        if printf '%s' "$live" | grep -q 'RecentAP' && ! printf '%s' "$live" | grep -q 'StaleAP'; then
            st_pass "MAX_AGE=300 drops stale AP, keeps recent"; else st_fail "MAX_AGE window (AP)"; fi
        if printf '%s' "$live" | grep -q 'aa:11:aa:11:aa:11' && ! printf '%s' "$live" | grep -q 'bb:22:bb:22:bb:22'; then
            st_pass "MAX_AGE=300 drops stale client (join uses s.time)"; else st_fail "MAX_AGE window (client)"; fi

        # ---- 2d) libwifi encryption_info in full (group/pairwise cipher, AKM, auth) and multi-SSID responders -------------------------
        #      Integers built from the pinned libwifi layout (bit 3 WPA2 class, 4 WPA3, 6 group TKIP, 8 group CCMP128, 20 pairwise TKIP, 22 pairwise
        #      CCMP128, 26 pairwise GCMP128, 33 AKM 1X, 34 PSK, 41 SAE, 44 1X-SuiteB-SHA256, 51 OWE, 54 auth OPEN, 57 auth SAE). All above 2^32,
        #      OWE/SAE above 2^41: they only survive because the bit extraction happens in SQL.
        sdb="$tdir/recon_sec.db"
        sqlite3 "$sdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
INSERT INTO ssid VALUES (1,0,1,8,'A0A0A0000001','Sec-OWE',    0,0,-50,5220,44,20266198327361808);
INSERT INTO ssid VALUES (2,0,1,8,'A0A0A0000002','Sec-SAE',    0,0,-50,5220,44,144117387103306000);
INSERT INTO ssid VALUES (3,0,1,8,'A0A0A0000003','Sec-PSK',    0,0,-50,5220,44,18014415693545736);
INSERT INTO ssid VALUES (4,0,1,8,'A0A0A0000004','Sec-ENT2',   0,0,-50,5220,44,18014407103611144);
INSERT INTO ssid VALUES (5,0,1,8,'A0A0A0000005','Sec-ENT3',   0,0,-50,5220,44,18031990762635536);
INSERT INTO ssid VALUES (6,0,1,8,'A0A0A0000006','Sec-WPATKIP',0,0,-50,2437,6,17180917828);
INSERT INTO ssid VALUES (7,0,1,8,'A0A0A0000007','Sec-WPA2TKIP',0,0,-50,2437,6,17180917832);
INSERT INTO ssid VALUES (8,0,1,8,'A0A0A0000008','Sec-MIXED',  0,0,-50,2437,6,17185112392);
INSERT INTO ssid VALUES (9,0,1,8,'A0A0A0000009','Sec-TRANS',  0,0,-50,2437,6,18016614716801304);
-- multi-SSID responder: one BSSID answers probes for three different SSIDs (type 5), another for one
INSERT INTO ssid VALUES (10,0,1,5,'A0A0A0000010','ResponderA',0,0,-60,2437,6,8);
INSERT INTO ssid VALUES (11,0,1,5,'A0A0A0000010','ResponderB',0,0,-61,2437,6,8);
INSERT INTO ssid VALUES (12,0,1,5,'A0A0A0000010','ResponderC',0,0,-62,2437,6,8);
INSERT INTO ssid VALUES (13,0,1,5,'A0A0A0000011','SingleSsid',0,0,-63,2437,6,8);
SQL
        out=$(RECON_DB="$sdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(security suite)" "$out"
        sl() { printf '%s\n' "$out" | grep -- "$1" | head -1; }
        checkf "sec: OWE is OWE, not WPA3 (libwifi sets the WPA3 class bit for OWE)" "$(sl 'a0:a0:a0:00:00:01')" '"security": "OWE", "akm": ["owe"]'
        checkf "sec: OWE auth scheme open"       "$(sl 'a0:a0:a0:00:00:01')" '"auth": ["open"]'
        checkf "sec: SAE (AKM bit 41 + auth SAE) is WPA3" "$(sl 'a0:a0:a0:00:00:02')" '"security": "WPA3", "akm": ["sae"]'
        checkf "sec: SAE auth scheme listed"     "$(sl 'a0:a0:a0:00:00:02')" '"auth": ["sae"]'
        checkf "sec: PSK is WPA2 with its ciphers" "$(sl 'a0:a0:a0:00:00:03')" '"security": "WPA2", "akm": ["psk"], "cipher": {"group": "ccmp128", "pairwise": ["ccmp128"]}, "auth": ["open"]'
        checkf "sec: 802.1X is WPA2-Enterprise"  "$(sl 'a0:a0:a0:00:00:04')" '"security": "WPA2-Enterprise", "akm": ["1x"]'
        checkf "sec: Suite-B 802.1X is WPA3-Enterprise" "$(sl 'a0:a0:a0:00:00:05')" '"security": "WPA3-Enterprise", "akm": ["1x-suiteb-sha256"]'
        checkf "sec: TKIP-only WPA is marked"    "$(sl 'a0:a0:a0:00:00:06')" '"security": "WPA (TKIP)"'
        checkf "sec: TKIP-only WPA2 is marked"   "$(sl 'a0:a0:a0:00:00:07')" '"security": "WPA2 (TKIP)"'
        checkf "sec: TKIP+CCMP mixed mode is not marked" "$(sl 'a0:a0:a0:00:00:08')" '"security": "WPA2", "akm": ["psk"], "cipher": {"group": "tkip", "pairwise": ["tkip", "ccmp128"]}'
        checkf "sec: WPA2+WPA3 transition keeps both AKMs" "$(sl 'a0:a0:a0:00:00:09')" '"security": "WPA3/WPA2", "akm": ["psk", "sae"]'
        checkf "resp: BSSID answering for 3 SSIDs -> responded_ssids 3" "$(sl 'a0:a0:a0:00:00:10')" '"responded_ssids": 3'
        checkno "resp: a single-SSID responder carries no count" "$(sl 'a0:a0:a0:00:00:11')" 'responded_ssids'
        checkno "packets: never on a station (no client field carries it)" "$out" '"packets"'
        # nothing in the additive fields may leak a client identity: only AP lines carry akm/cipher/auth/responded_ssids
        cl=$(printf '%s\n' "$out" | grep -c '"mac".*\("akm"\|"cipher"\|"auth"\|"responded_ssids"\)')
        if [ "$cl" = "0" ]; then st_pass "sec: akm/cipher/auth/responded_ssids only on AP lines"; else st_fail "sec: additive fields on a client line ($cl)"; fi

        # ---- 2e) channels[] (hop info + survey), center max_age/interval, own_bssids/own_ssids, run_cycle post-pass ----------------------
        hdb="$tdir/recon_hop.db"; hnow=1710000000
        sqlite3 "$hdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
INSERT INTO ssid VALUES (1,0,1,8,'B0B0B0000001','HopA',0,$((hnow-5)),-50,2412,1,8);
INSERT INTO ssid VALUES (2,0,1,8,'B0B0B0000002','HopB',0,$((hnow-60)),-60,2412,1,8);
INSERT INTO ssid VALUES (3,0,1,8,'B0B0B0000003','HopC',0,$((hnow-30)),-60,5180,36,8);
SQL
        RECON_DB="$hdb"
        out=$(HOPINFO=0 SURVEY=0 build_from_recondb "$hnow" 2>/dev/null)
        checkno "hop: no channels[] by default (flag off)" "$out" '"channels"'
        out=$(HOPINFO=1 build_from_recondb "$hnow" 2>/dev/null)
        if printf '%s' "$out" | json_ok; then st_pass "hop: valid JSON with channels[]"; else st_fail "hop: JSON"; fi
        checkf "hop: last_heard per frequency = newest row" "$out" '"channels": [{"freq": 2412, "last_heard": 1709999995}, {"freq": 5180, "last_heard": 1709999970}],'
        RECON_DB=auto
        sv=$(printf 'Survey data from wlan1mon\n\tfrequency:\t\t\t2412 MHz [in use]\n\tnoise:\t\t\t\t-95 dBm\n\tchannel active time:\t\t1000 ms\n\tchannel busy time:\t\t250 ms\nSurvey data from wlan1mon\n\tfrequency:\t\t\t5180 MHz\n\tnoise:\t\t\t\t-101 dBm\n\tchannel active time:\t\t0 ms\n\tchannel busy time:\t\t0 ms\n' | survey_rows)
        chj=$( { printf 'H\t2412\t1709999995\n'; printf '%s\n' "$sv"; } | channels_json)
        checkf "survey: busy_pct = 100*busy/active, noise kept, a zero active time gives no percentage" "$chj" '[{"freq": 2412, "last_heard": 1709999995, "busy_pct": 25, "noise": -95}, {"freq": 5180, "noise": -101}]'
        mkdir -p "$tdir/sys/wlan0" "$tdir/sys/wlan1mon" "$tdir/sys/lo" "$tdir/sys/br0"
        printf '00:C0:CA:11:22:33\n' > "$tdir/sys/wlan0/address"; printf '00:c0:ca:11:22:33\n' > "$tdir/sys/wlan1mon/address"
        printf '00:00:00:00:00:00\n' > "$tdir/sys/lo/address"; printf 'not-a-mac\n' > "$tdir/sys/br0/address"
        printf 'MyOwnNet\n\nMyOwnNet\nSecond "quoted" net\n' > "$tdir/own_ssids.txt"
        cx=$(OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys" OWN_SSID_FILE="$tdir/own_ssids.txt" MAX_AGE=120 INTERVAL=7 center_extra)
        checkf "own: max_age, interval, unique lower-case interface MACs, file SSIDs (dedup, escaped)" "$cx" ', "max_age": 120, "interval": 7, "own_bssids": ["00:c0:ca:11:22:33"], "own_ssids": ["MyOwnNet", "Second \"quoted\" net"]'
        cx=$(OWN=0 STARCHORUS_SYSFS_NET="$tdir/sys" MAX_AGE=0 INTERVAL=5 center_extra)
        if [ "$cx" = ', "max_age": 0, "interval": 5' ]; then st_pass "own: flag off -> only max_age and interval"; else st_fail "own flag off: [$cx]"; fi
        # run_cycle (recon source): the published document carries the extras, on the same line, and stays valid JSON
        RESOLVED=recondb; RECON_DB="$sdb"; OUTFILE="$tdir/cycle.json"; VENDOR=0; MAX_AGE=90; INTERVAL=9
        run_cycle >/dev/null 2>&1
        pub=$(cat "$OUTFILE" 2>/dev/null)
        if printf '%s' "$pub" | json_ok; then st_pass "run_cycle: center-extra post-pass keeps valid JSON"; else st_fail "run_cycle center post-pass JSON"; fi
        checkf "run_cycle: center carries max_age + interval" "$pub" '"center": {"label": "This device", "max_age": 90, "interval": 9},'
        # ---- 2f) homing: the reading of the ONE chosen AP, peak hold, refusals (station / unknown / own / garbage), file vs environment
        checkno "homing: no target -> no homing field" "$pub" '"homing"'
        OUTDIR_SAVE=$OUTDIR; OUTDIR=$tdir; rm -f "$tdir/homing.target"
        MAX_AGE=0   # the fixture rows carry time 0: a 90 s window above would give the empty document
        hp=$(run_cycle >/dev/null 2>&1; cat "$OUTFILE" 2>/dev/null); pub=$hp; checkf "homing: the fixture cycle is a real document (a0:a0:a0:00:00:03 is there)" "$pub" '"bssid": "a0:a0:a0:00:00:03"'
        hcyc() { run_cycle >/dev/null 2>&1; cat "$OUTFILE" 2>/dev/null; }
        HOMING_BSSID="A0:A0:A0:00:00:03"; hp=$(hcyc)
        if printf '%s' "$hp" | json_ok; then st_pass "homing: valid JSON with the field"; else st_fail "homing: JSON"; fi
        checkf "homing: bssid lower-cased, dbm from the AP's own row, peak, t = generated" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:03", "dbm": -50, "peak": -50, "t": '
        if [ "$(printf '%s\n' "$hp" | grep -c '"homing"')" = 1 ] && [ "$(printf '%s\n' "$hp" | wc -l | tr -d ' ')" = "$(printf '%s\n' "$pub" | wc -l | tr -d ' ')" ]; then st_pass "homing: exactly one field, same line count as without"; else st_fail "homing: line count / count"; fi
        HOMING_BSSID="11:22:aa:bb:cc:dd"; hp=$(hcyc); checkno "homing: a station (a MAC with no aps[] row) is refused" "$hp" '"homing"'
        HOMING_BSSID="de:ad:be:ef:00:01"; hp=$(hcyc); checkno "homing: a BSSID that is not in this document is refused" "$hp" '"homing"'
        HOMING_BSSID="not-a-mac"; hp=$(hcyc); checkno "homing: garbage is refused" "$hp" '"homing"'
        HOMING_BSSID="a0:a0:a0:00:00:03"; OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys"; printf 'A0:A0:A0:00:00:03\n' > "$tdir/sys/wlan0/address"
        hp=$(OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys" hcyc); checkno "homing: one of our own transmitters is refused" "$hp" '"homing"'
        printf '00:C0:CA:11:22:33\n' > "$tdir/sys/wlan0/address"
        HOMING_BSSID=""; printf 'A0:A0:A0:00:00:04\r\nignored line\n' > "$tdir/homing.target"; hp=$(hcyc)
        checkf "homing: the file target works (first line, CRLF, upper case)" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:04"'
        HOMING_BSSID="a0:a0:a0:00:00:03"; hp=$(hcyc); checkf "homing: the environment wins over the file" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:03"'
        # peak hold (the state lives in this shell, so the cycles run here, not in a $(...) subshell): a weaker reading keeps it, 12 quiet cycles decay it
        hrun() { run_cycle >/dev/null 2>&1; hp=$(cat "$OUTFILE" 2>/dev/null); }
        HOMING_BSSID="a0:a0:a0:00:00:03"; HOMING_PEAK=-40; HOMING_POLLS=0
        hrun; checkf "homing: a weaker reading keeps the peak (-40 stays, dbm -50)" "$hp" '"dbm": -50, "peak": -40,'
        n=0; while [ "$n" -lt 12 ]; do hrun; n=$((n + 1)); done
        checkf "homing: 12 quiet cycles later the peak has decayed to the current reading" "$hp" '"dbm": -50, "peak": -50,'
        HOMING_BSSID=""; rm -f "$tdir/homing.target"; hrun; checkno "homing: target removed -> field gone" "$hp" '"homing"'
        if [ -z "$HOMING_PEAK" ]; then st_pass "homing: the peak is dropped with the target"; else st_fail "homing: peak kept ($HOMING_PEAK)"; fi
        OUTDIR=$OUTDIR_SAVE; HOMING_BSSID=${STARCHORUS_HOMING_BSSID:-}; HOMING_PEAK=""; HOMING_POLLS=0
        RESOLVED=none; RECON_DB=auto; OUTFILE=$OUTDIR/starchorus.json; VENDOR=${STARCHORUS_VENDOR:-1}; MAX_AGE=${STARCHORUS_MAX_AGE:-0}; INTERVAL=${STARCHORUS_INTERVAL:-5}
        apcli_selftest "$tdir"

        # ---- 3) recon.db, legacy `aps` schema ----------------------------------------------------
        mdb="$tdir/recon_legacy.db"
        sqlite3 "$mdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE aps (bssid TEXT, ssid TEXT, channel INTEGER, signal INTEGER, privacy TEXT);
INSERT INTO aps VALUES ('aa:bb:cc:aa:00:01','LegacyNet', 11, -48, 'WPA2');
INSERT INTO aps VALUES ('aa:bb:cc:aa:00:02','OldOpen',    1, -75, 'OPN');
SQL
        out=$(RECON_DB="$mdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(legacy aps)" "$out"
        check "legacy: LegacyNet WPA2"    "$out" '"security": "WPA2"'
        check "legacy: channel->band 2.4" "$out" '"band": "2.4GHz"'
        check "legacy: OPN->Open"         "$out" '"security": "Open"'

        # ---- 3b) recon.db: the RAM work copy, ONE sqlite3 process per cycle in every schema family, and a cycle with nothing new.
        #      A logging stub `sqlite3` in front of PATH counts the calls and keeps the SQL it was given (stdin); `df` and `date` are stubbed
        #      where the test needs a full tmpfs or a clock it can move.
        rsq=$(command -v sqlite3); rpt="$tdir/rq"; mkdir -p "$rpt/bin" "$rpt/ram"
        cat > "$rpt/bin/sqlite3" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$SHIM_LOG"
tee -a "$SHIM_SQL" | "$SHIM_REAL" "$@"
SHIM
        chmod +x "$rpt/bin/sqlite3"
        r_path=$PATH; r_res=$RESOLVED; r_db=$RECON_DB; r_of=$OUTFILE; r_ven=$VENDOR; r_age=$MAX_AGE; r_tmp=$TMPDIR_RAM; r_od=$OUTDIR; r_int=$INTERVAL
        PATH="$rpt/bin:$PATH"; export SHIM_REAL="$rsq" SHIM_LOG="$rpt/calls" SHIM_SQL="$rpt/sql"
        : > "$SHIM_LOG"; : > "$SHIM_SQL"
        TMPDIR_RAM="$rpt/ram"; RECON_DB="$rdb"; HAS_TIME=""; RDB_PATH=""
        calls() { wc -l < "$SHIM_LOG" | tr -d ' '; }
        rm -f "$CAPDIR/recon_copy.db"
        build_from_recondb 1710000000 > "$rpt/o1.json" 2>/dev/null
        if json_ok < "$rpt/o1.json" && grep -q '"ssid": "OpenGuest"' "$rpt/o1.json" && [ "$(calls)" = 1 ]; then st_pass "recon batch: one sqlite3 process for the whole cycle (running schema)"; else st_fail "recon batch: running schema (calls $(calls))"; fi
        if grep -q "$rpt/ram/starchorus-recon-" "$SHIM_LOG" && [ ! -e "$CAPDIR/recon_copy.db" ] && [ -z "$(ls "$rpt/ram")" ]; then st_pass "recon copy: made in the RAM directory, nothing in CAPDIR, removed after the queries"; else st_fail "recon copy: $(cat "$SHIM_LOG") / $(ls "$rpt/ram" "$CAPDIR")"; fi
        if [ "$HAS_TIME" = 1 ] && [ "$(grep -c "STARCHORUS_APS2#" "$SHIM_SQL")" = 1 ]; then st_pass "recon batch: the first batch asks the no-time alternatives too and learns that ssid has a time column"; else st_fail "recon batch: HAS_TIME=$HAS_TIME"; fi
        build_from_recondb 1710000000 > "$rpt/o2.json" 2>/dev/null
        if [ "$(calls)" = 2 ] && [ "$(grep -c "STARCHORUS_APS2#" "$SHIM_SQL")" = 1 ] && [ "$(grep -c "STARCHORUS_CLI2#" "$SHIM_SQL")" = 1 ] && cmp -s "$rpt/o1.json" "$rpt/o2.json"; then st_pass "recon batch: once learnt, the duplicate no-time scans are left out; the document is the same"; else st_fail "recon batch: second batch (calls $(calls))"; fi
        # a statement the firmware cannot prepare (apmac family: no bssid column; legacy: no ssid table) must not stop the later ones, and still one process
        for rfam in "$pdb:OpenAir" "$mdb:LegacyNet" "$sdb:Sec-OWE"; do
            : > "$SHIM_LOG"; RECON_DB=${rfam%%:*}
            build_from_recondb 1710000000 > "$rpt/of.json" 2>/dev/null
            if [ "$(calls)" = 1 ] && grep -q "\"ssid\": \"${rfam##*:}\"" "$rpt/of.json"; then st_pass "recon batch: ${rfam##*:} found in ONE process although other alternatives fail"; else st_fail "recon batch: ${rfam##*:} (calls $(calls))"; fi
        done
        # a ssid table without a time column: the no-time alternatives answer, no last_seen, HAS_TIME=0
        ndb="$tdir/recon_notime.db"
        sqlite3 "$ndb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB, hidden INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'C0C0C0000001','NoTimeAP',0,-50,2437,6,8);
INSERT INTO ssid VALUES (2,401,1,4,'FFFFFFFFFFFF','Wanted',0,-60,0,0,0);
INSERT INTO wifi_device VALUES (401,1,'C0C0C0000009',0,-60,0,1);
SQL
        : > "$SHIM_LOG"; RECON_DB="$ndb"
        build_from_recondb 1710000000 > "$rpt/on.json" 2>/dev/null
        if [ "$(calls)" = 1 ] && [ "$HAS_TIME" = 0 ] && grep -q '"ssid": "NoTimeAP"' "$rpt/on.json" && grep -q '"mac": "c0:c0:c0:00:00:09"' "$rpt/on.json" && ! grep -q last_seen "$rpt/on.json" && grep -q '"probes": \["Wanted"\]' "$rpt/on.json"; then st_pass "recon batch: a ssid table without a time column is answered by the no-time alternatives (no last_seen)"; else st_fail "recon batch: no-time schema (calls $(calls), HAS_TIME=$HAS_TIME)"; fi
        # the hop query joins the same batch
        : > "$SHIM_LOG"; RECON_DB="$hdb"; HOPINFO=1
        build_from_recondb 1710000000 > "$rpt/oh.json" 2>/dev/null; HOPINFO=0
        if [ "$(calls)" = 1 ] && grep -q '"channels": \[{"freq": 2412, "last_heard": 1709999995}' "$rpt/oh.json"; then st_pass "recon batch: HOPINFO adds its query to the same single process"; else st_fail "recon batch: hop (calls $(calls))"; fi
        # recondb_pick: the first alternative with rows wins, later ones are dropped; an SSID that looks like a marker is data, not a section
        pk=$(printf '%s\n' '#STARCHORUS_APS1#' '#STARCHORUS_APS2#' 'a1	one' 'a2	two' '#STARCHORUS_APS3#' 'a3	three' '#STARCHORUS_CLI1#' 'c1	-50	77' '#STARCHORUS_PRB1#' 'p1	#STARCHORUS_APS#' '#STARCHORUS_HASTIME#' '1' | recondb_pick)
        if [ "$pk" = "#STARCHORUS_APS#
a1	one
a2	two
#STARCHORUS_CLIENTS#
c1	-50	77
#STARCHORUS_PROBES#
p1	#STARCHORUS_APS#
#STARCHORUS_HASTIME#
1" ]; then st_pass "recondb_pick: first non-empty alternative per group, marker-like data stays data"; else st_fail "recondb_pick: [$pk]"; fi
        # a full tmpfs: the copy falls back to CAPDIR and the cycle still works
        printf '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\ntmpfs 1000 999 1 99%% /tmp\\n"\n' > "$rpt/bin/df"; chmod +x "$rpt/bin/df"
        : > "$SHIM_LOG"; RECON_DB="$rdb"
        build_from_recondb 1710000000 > "$rpt/ot.json" 2>/dev/null
        if [ "$(calls)" = 1 ] && [ -s "$CAPDIR/recon_copy.db" ] && [ -z "$(ls "$rpt/ram")" ] && grep -q "$CAPDIR/recon_copy.db" "$SHIM_LOG" && json_ok < "$rpt/ot.json"; then st_pass "recon copy: no room in the RAM directory -> the old place (CAPDIR), cycle intact"; else st_fail "recon copy: full tmpfs ($(cat "$SHIM_LOG"))"; fi
        rm -f "$rpt/bin/df" "$CAPDIR/recon_copy.db"
        TMPDIR_RAM="$rpt/no-such-dir"; : > "$SHIM_LOG"
        build_from_recondb 1710000000 > "$rpt/ot.json" 2>/dev/null
        if [ -s "$CAPDIR/recon_copy.db" ] && json_ok < "$rpt/ot.json"; then st_pass "recon copy: no RAM directory at all -> the old place (CAPDIR)"; else st_fail "recon copy: missing RAM directory"; fi
        rm -f "$CAPDIR/recon_copy.db"; TMPDIR_RAM="$rpt/ram"
        # stale RAM copies of dead collectors are swept, a live one's is kept
        : > "$rpt/ram/starchorus-recon-999999.db"; : > "$rpt/ram/starchorus-recon-$$.db"
        sweep_stale_workcopies
        if [ ! -e "$rpt/ram/starchorus-recon-999999.db" ] && [ -e "$rpt/ram/starchorus-recon-$$.db" ]; then st_pass "sweep: a dead collector's RAM copy removed, a live one's kept"; else st_fail "sweep: RAM copies ($(ls "$rpt/ram"))"; fi
        rm -f "$rpt/ram"/starchorus-recon-*
        # ---- 3b3) the cheaper cycle (0.2.6): one scan of the window, the reduced batch, and the small savings of the full pass, each against stand-ins that count the
        #      processes (the sqlite3 stand-in keeps the SQL it is given; awk, wc, rm, df and cp log their calls; date is a function that logs). Every check that counts a
        #      process or compares a text also runs the form without the change (the batch of the first cycle is the old text; a planted old function where the old text is
        #      a function) and says what that form comes to: a check that the old form passes would prove nothing. Everything this block changes is put back.
        cg="$tdir/cyc"; rm -rf "$cg"; mkdir -p "$cg/bin" "$cg/ram" "$cg/ram2" "$cg/out" "$cg/proc" "$cg/cap"
        cg_t=$RECON_TAB
        cg_path=$PATH; cg_ram=$TMPDIR_RAM; cg_db=$RECON_DB; cg_age=$MAX_AGE; cg_hop=$HOPINFO; cg_res=$RESOLVED; cg_of=$OUTFILE; cg_od=$OUTDIR; cg_ven=$VENDOR; cg_iv=$INTERVAL
        cg_su=$SKIP_UNCHANGED; cg_tr=$TRAFFIC; cg_proc=$BT_PROC; cg_cap=$CAPDIR; cg_sm=$SKIP_MAX; cg_hb=$HOMING_BSSID; cg_own=$OWN
        # the stand-ins: sqlite3 keeps the SQL (and moves a stand-in clock when asked to), the others log their name and run the real program
        # (SHIM_REAL: the real sqlite3 when the logging shim of the recon.db block is still first in PATH)
        CYC_LOG="$cg/calls"; CYC_SQL="$cg/sql"; CYC_REAL=${SHIM_REAL:-$(command -v sqlite3)}; CYC_STUB="$cg/stub.log"; CYC_UP=""; CYC_UPV=""; CYC_DFFULL=""; CYC_CPFAIL=""; CYC_NOCREATE=""
        export CYC_LOG CYC_SQL CYC_REAL CYC_STUB CYC_UP CYC_UPV CYC_DFFULL CYC_CPFAIL CYC_NOCREATE
        # shellcheck disable=SC2016  # the stand-ins' text: the variables are theirs
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$CYC_LOG"\n[ -z "$CYC_UP" ] || printf "%%s 1.00\\n" "$CYC_UPV" > "$CYC_UP"\nif [ -n "$CYC_NOCREATE" ]; then tee -a "$CYC_SQL" | sed "/^CREATE TEMP TABLE rwin /d" | "$CYC_REAL" "$@"; else tee -a "$CYC_SQL" | "$CYC_REAL" "$@"; fi\n' > "$cg/bin/sqlite3"
        for cg_n in awk wc rm; do
            # shellcheck disable=SC2016
            printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$CYC_STUB"\nexec %s "$@"\n' "$cg_n" "$(command -v "$cg_n")" > "$cg/bin/$cg_n"
        done
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nprintf "df\\n" >> "$CYC_STUB"\nif [ -n "$CYC_DFFULL" ]; then printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\ntmpfs 1000 999 1 99%%%% /tmp\\n"; exit 0; fi\nexec %s "$@"\n' "$(command -v df)" > "$cg/bin/df"
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nprintf "cp\\n" >> "$CYC_STUB"\nif [ -n "$CYC_CPFAIL" ]; then for a; do last=$a; done; case $last in */ram/*) exit 1 ;; esac; fi\nexec %s "$@"\n' "$(command -v cp)" > "$cg/bin/cp"
        chmod +x "$cg/bin"/*
        PATH="$cg/bin:$PATH"; TMPDIR_RAM="$cg/ram"; MAX_AGE=3600; HOPINFO=0; TRAFFIC=0; RESOLVED=recondb; OUTFILE="$cg/out/starchorus.json"; OUTDIR="$cg/out"; CAPDIR="$cg/cap"; VENDOR=0
        SKIP_UNCHANGED=0; SKIP_MAX=20; HOMING_BSSID=""; OWN=0; INTERVAL=30
        cg_now=$(command date +%s)
        gdb="$cg/gc.db"
        sqlite3 "$gdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB, hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'020000D10001','GcAP-One',0,$((cg_now - 30)),-50,2437,6,8);
INSERT INTO ssid VALUES (2,0,1,8,'020000D10002','GcAP-Two',0,$((cg_now - 20)),-60,2412,1,0);
INSERT INTO ssid VALUES (3,0,1,5,'020000D10001','GcAP-One',0,$((cg_now - 25)),-45,2437,6,8);
INSERT INTO ssid VALUES (4,0,1,5,'020000D10002','GcOnlyAnswer',0,$((cg_now - 22)),-61,2412,1,0);
INSERT INTO ssid VALUES (11,0,1,8,'020000E00001','TieAP-A',0,$((cg_now - 10)),-50,2412,1,8);
INSERT INTO ssid VALUES (12,0,1,8,'020000E00001','TieAP-B',0,$((cg_now - 20)),-50,2437,6,0);
INSERT INTO ssid VALUES (21,701,1,4,'FFFFFFFFFFFF','GcProbed',0,$((cg_now - 15)),-70,0,0,0);
INSERT INTO ssid VALUES (22,702,1,4,'FFFFFFFFFFFF','GcAlso',0,$((cg_now - 14)),-72,0,0,0);
INSERT INTO ssid VALUES (90,0,1,8,'020000D10009','GcOldAP',0,$((cg_now - 100000)),-40,2437,6,8);
INSERT INTO ssid VALUES (91,703,1,4,'FFFFFFFFFFFF','GcOldProbe',0,$((cg_now - 100000)),-40,0,0,0);
INSERT INTO wifi_device VALUES (701,1,'020000D20001',$((cg_now - 15)),-70,0,5);
INSERT INTO wifi_device VALUES (702,1,'020000D20002',$((cg_now - 14)),-72,0,6);
INSERT INTO wifi_device VALUES (703,1,'020000D20009',$((cg_now - 100000)),-40,0,7);
SQL
        cg_calls() { grep -c . "$CYC_LOG"; }
        cg_stubs() { grep -c "^$1" "$CYC_STUB"; }                                 # how many times the stand-in NAME ran since the stub log was last emptied
        cg_n() { printf '%s\n' "$1" | grep -c -- "$2"; }                          # lines of the text $1 that match $2
        cg_b() { : > "$CYC_LOG"; : > "$CYC_SQL"; : > "$CYC_STUB"; build_from_recondb 1710000000 > "$1" 2>/dev/null; cg_rc=$?; }   # one build: the document in $1; this build's calls, SQL and processes alone
        cg_fresh() { RECON_DB="$1"; RDB_PATH=""; HAS_TIME=""; RQ_WIN=""; RR_OK=""; }
        cg_m() { cg_n "$1" "SELECT '#STARCHORUS_"; }                              # the groups in a batch text
        cg_e() { printf '%s\n' "$1" | grep -cE -- "$2"; }                         # lines of the text $1 that match the extended expression $2

        # ---- 1) one scan of the window: the temporary table, in the second batch and the later ones
        cg_fresh "$gdb"
        cg_b "$cg/o1.json"; cg_s1=$(cat "$CYC_SQL"); cg_c1=$(cg_calls); cg_a1=$(cg_stubs awk); cg_w1=$RQ_WIN; cg_wm1=$RS_WMIN
        cg_b "$cg/o2.json"; cg_s2=$(cat "$CYC_SQL"); cg_c2=$(cg_calls); cg_l2=$(cat "$CYC_LOG"); cg_a2=$(cg_stubs awk); cg_w2=$RQ_WIN; cg_wm2=$RS_WMIN
        cg_b "$cg/o3.json"; cg_s3=$(cat "$CYC_SQL")
        MAX_AGE=0; cg_b "$cg/o0.json"; cg_s0=$(cat "$CYC_SQL"); cg_c0=$(cg_calls); MAX_AGE=3600
        # the temporary table once, and no group reads ssid any more (the only FROM ssid is the one that fills the table)
        cg_rw() { [ "$(cg_n "$1" 'CREATE TEMP TABLE rwin AS SELECT \* FROM ssid WHERE time > [0-9]* AND type IN (4,5,8);')" = 1 ] && [ "$(cg_n "$1" 'FROM ssid')" = 1 ] && [ "$(cg_n "$1" 'FROM rwin')" -ge 4 ]; }
        if ! cg_rw "$cg_s1" && cg_rw "$cg_s2" && cg_rw "$cg_s3" && ! cg_rw "$cg_s0" && [ "$(cg_n "$cg_s1$NL$cg_s0" rwin)" = 0 ] \
           && [ "$cg_c1/$cg_c2/$cg_c0" = 1/1/1 ] && [ "$(cg_n "$cg_l2" '-readonly')" = 1 ]; then
            st_pass "recon batch: the window is cut out once (CREATE TEMP TABLE rwin) in a batch with HAS_TIME=1 and a window, and every group reads it; the first batch and MAX_AGE=0 keep ssid (the old text); one sqlite3 process, -readonly"
        else st_fail "recon batch: the temporary table (rwin lines $(cg_n "$cg_s1" rwin)/$(cg_n "$cg_s2" rwin)/$(cg_n "$cg_s3" rwin)/$(cg_n "$cg_s0" rwin), calls $cg_c1/$cg_c2/$cg_c0)"; fi
        # the same bytes from every form; the temporary table does not touch the file (the copy stays a read-only copy)
        cp "$gdb" "$cg/ro.db"; cg_x=$(sqlite3 -readonly "$cg/ro.db" "CREATE TEMP TABLE t AS SELECT * FROM ssid WHERE type = 8; SELECT COUNT(*) FROM t;" </dev/null 2>&1)
        if cmp -s "$cg/o1.json" "$cg/o2.json" && cmp -s "$cg/o2.json" "$cg/o3.json" && [ "$cg_x" = 5 ] && cmp -s "$gdb" "$cg/ro.db" && [ "$(grep -c '"bssid"' "$cg/o1.json")" = 3 ]; then
            st_pass "recon batch: the document is the same bytes from the first batch (ssid), the second (rwin) and the third; sqlite3 -readonly accepts a temporary table and leaves the file as it was"
        else st_fail "recon batch: the forms differ ($(cmp "$cg/o1.json" "$cg/o2.json" 2>&1 | head -n 1), temp table [$cg_x])"; fi
        # The tie: two beacons of one BSSID, the same signal, other columns different. The bare columns beside MAX(signal) come from the row the scan meets first, the first of the table,
        # in both forms (the temporary table is filled in that order). A table filled in another order would flip it: shown with the same query on a table ordered by time.
        cg_ord=$(sqlite3 -readonly -noheader -separator "$cg_t" "$gdb" "CREATE TEMP TABLE rwin AS SELECT * FROM ssid WHERE type IN (5,8) ORDER BY time; SELECT ssid, MAX(signal) FROM rwin WHERE bssid='020000E00001' GROUP BY bssid;" </dev/null)
        cg_tie='"bssid": "02:00:00:e0:00:01", "ssid": "TieAP-A", "channel": 1, "band": "2.4GHz", "freq": 2412'
        if grep -qF "$cg_tie" "$cg/o1.json" && grep -qF "$cg_tie" "$cg/o2.json" && ! grep -q TieAP-B "$cg/o1.json" "$cg/o2.json" && [ "$cg_ord" = "TieAP-B${cg_t}-50" ]; then
            st_pass "recon batch: a tie (one BSSID, equal signal) is decided by the first row of the table in both forms (TieAP-A, channel 1, 2412 MHz); a table filled in the order of time gives TieAP-B"
        else st_fail "recon batch: tie ($(grep -F 02:00:00:e0:00:01 "$cg/o2.json" | cut -c1-130), ordered table [$cg_ord])"; fi

        # ---- 2) the reduced batch: from the second cycle on only the winners are asked, under their final names, and no recondb_pick pass runs
        # (RESP has no row in this database: its two alternatives stay, numbered, after the rest of the batch, and the first non-empty one is taken with builtins)
        # the tail of the second batch (TAIL to TAILEND): RESP's two alternatives as they are, and the other alternatives of the groups with a winner as questions of one row
        # (APS3 to APS7, CLI3, PRB2: behind their winner, so "has it rows while the winner has none?"); none of them outside the tail
        cg_tl=$(printf '%s\n' "$cg_s2" | sed -n "/^SELECT '#STARCHORUS_TAIL#';$/,/^SELECT '#STARCHORUS_TAILEND#';$/p")
        if [ "$(cg_m "$cg_s1")" = 17 ] && [ "$cg_w1" = " APS1 CLI1 PRB1 " ] && [ "$(cg_m "$cg_s2")" = 17 ] && [ "$cg_w2" = " APS1 CLI1 PRB1 " ] \
           && [ "$(cg_n "$cg_s2" "STARCHORUS_HASTIME#")" = 0 ] && [ "$(cg_e "$cg_s2" "STARCHORUS_(APS|CLI|PRB)[0-9]#")" = 7 ] && [ "$(cg_e "$cg_tl" "STARCHORUS_(APS|CLI|PRB|RESP)[0-9]#")" = 9 ] \
           && [ "$(cg_e "$cg_tl" "^SELECT 1 WHERE EXISTS \(.* AND NOT EXISTS \(SELECT ")" = 7 ] && [ "$(cg_n "$cg_s2" "^SELECT 1 WHERE")" = 7 ] \
           && [ "$(cg_n "$cg_s2" "STARCHORUS_APS#")" = 1 ] && [ "$(cg_n "$cg_s2" "STARCHORUS_CLIENTS#")" = 1 ] && [ "$(cg_n "$cg_s2" "STARCHORUS_PROBES#")" = 1 ] \
           && [ "$(cg_n "$cg_s2" "STARCHORUS_RESP[12]#")" = 2 ] && [ "$(cg_n "$cg_s2" "STARCHORUS_TAIL#")" = 1 ] && [ "$cg_a1/$cg_a2" = 2/1 ] \
       && [ "$cg_wm1/$cg_wm2" = "$((cg_now - 30))/$((cg_now - 30))" ]; then
            st_pass "recon batch: the first batch asks 17 groups (pick and the document: 2 awk), the second 17 (APS, CLIENTS, PROBES, WMIN under their final names, the shape of the tables and the marker of the window's table; between TAIL and TAILEND at the start RESP's two alternatives and the other alternatives of APS, CLI and PRB as seven questions of one row each, none outside), no HASTIME, no pick pass (1 awk); the winners were APS1 CLI1 PRB1; the oldest row of the window (WMIN, taken from the text by parameter expansion) is the same in both"
        else st_fail "recon batch: reduced batch (groups $(cg_m "$cg_s1")/$(cg_m "$cg_s2"), tail $(cg_e "$cg_tl" "STARCHORUS_(APS|CLI|PRB|RESP)[0-9]#"), winners [$cg_w1][$cg_w2], awk $cg_a1/$cg_a2, WMIN $cg_wm1/$cg_wm2)"; fi
        # a responder appears: the tail's first non-empty alternative (RESP1) joins the document, the winner is kept, the next batch has RESP under its final name only; every form of the same database gives the same bytes
        sqlite3 "$gdb" "INSERT INTO ssid VALUES (31,0,1,5,'020000D10002','GcSecond',0,$((cg_now - 21)),-62,2412,1,0);" </dev/null
        cg_b "$cg/r1.json"; cg_wr1=$RQ_WIN
        cg_b "$cg/r2.json"; cg_sr2=$(cat "$CYC_SQL"); cg_wr2=$RQ_WIN
        cg_fresh "$gdb"; cg_b "$cg/r3.json"
        if grep -qF '"responded_ssids": 2' "$cg/r1.json" && [ "$cg_wr1" = " APS1 CLI1 PRB1 RESP1 " ] && [ "$cg_wr2" = "$cg_wr1" ] && [ "$(cg_m "$cg_sr2")" = 17 ] && [ "$(cg_n "$cg_sr2" "STARCHORUS_RESP#")" = 1 ] \
           && [ "$(cg_n "$cg_sr2" "STARCHORUS_TAIL#")" = 1 ] && [ "$(cg_n "$cg_sr2" "^SELECT 1 WHERE EXISTS (SELECT apmac, COUNT(DISTINCT .* AND NOT EXISTS (SELECT bssid, COUNT(DISTINCT ")" = 1 ] \
           && cmp -s "$cg/r1.json" "$cg/r2.json" && cmp -s "$cg/r2.json" "$cg/r3.json"; then
            st_pass "recon batch: a group that had no winner (RESP) with a row in the tail is asked again as a first batch, which takes the first non-empty alternative, is asked under its final name from then on (7 groups, and RESP2 becomes a question of the tail like the others: 17), and the document is the same bytes as a first batch of the same database"
        else st_fail "recon batch: late winner (win [$cg_wr1][$cg_wr2], groups $(cg_m "$cg_sr2"), $(cmp "$cg/r1.json" "$cg/r3.json" 2>&1 | head -n 1))"; fi
        # the pick keeps its own rule (existing check above) and, asked with `own`, adds who won
        cg_pk=$(printf '%s\n' '#STARCHORUS_APS1#' '#STARCHORUS_APS2#' 'a1	one' '#STARCHORUS_APS3#' 'a3	three' '#STARCHORUS_CLI1#' 'c1	-50	77' '#STARCHORUS_PRB1#' '#STARCHORUS_RESP2#' 'r	3' | recondb_pick own)
        cg_pn=$(printf '%s\n' '#STARCHORUS_APS1#' '#STARCHORUS_APS2#' 'a1	one' '#STARCHORUS_APS3#' 'a3	three' '#STARCHORUS_CLI1#' 'c1	-50	77' '#STARCHORUS_PRB1#' '#STARCHORUS_RESP2#' 'r	3' | recondb_pick)
        RQ_SRC="$NL#STARCHORUS_A#$NL#STARCHORUS_B#${NL}r1${NL}r2$NL#STARCHORUS_C#$NL#STARCHORUS_D#${NL}last$NL"
        sq_section B; cg_sb=$RQ_SECT; sq_section A; cg_sa=$RQ_SECT; sq_section D; cg_sd=$RQ_SECT; sq_section C; cg_sc=$RQ_SECT; sq_section Z; cg_sz=$?; sq_section B end; cg_sbe=$RQ_SECT; sq_section D end; cg_sde=$RQ_SECT
        if [ "${cg_pk#"$cg_pn"}" = "$NL#STARCHORUS_OWN#${NL}APS2 CLI1 RESP2" ] && [ -z "$cg_sa" ] && [ "$cg_sb" = "r1${NL}r2" ] && [ -z "$cg_sc" ] && [ "$cg_sd" = last ] && [ "$cg_sz" = 1 ] && [ "$cg_sbe" = "$cg_sb" ] && [ "$cg_sde" = last ]; then
            st_pass "recondb_pick own: the same output as without, and a section naming the winners (APS2 CLI1 RESP2); sq_section: the rows of a section by parameter expansion (empty, two rows, last, missing; counted from the start or, for the sections behind the long ones, from the end)"
        else st_fail "recondb_pick own / sq_section ([${cg_pk#"$cg_pn"}] [$cg_sa|$cg_sb|$cg_sc|$cg_sd|$cg_sz])"; fi

        # ---- 3) the winners are dropped when the schema check fails or the file changes shape (and the pass found no access point, or the copy was torn)
        sqlite3 "$cg/legacy.db" >/dev/null 2>&1 <<'SQL'
CREATE TABLE aps (bssid TEXT, ssid TEXT, channel INTEGER, signal INTEGER, privacy TEXT);
INSERT INTO aps VALUES ('02:00:00:aa:00:01','LegacyGc', 11, -48, 'WPA2');
SQL
        cp "$gdb" "$cg/sw.db"; cg_fresh "$cg/sw.db"; cg_b "$cg/w1.json"; cg_b "$cg/w2.json"; cg_ws=$RQ_WIN
        cp "$cg/legacy.db" "$cg/sw.db"; cg_b "$cg/w3.json"; cg_r3=$cg_rc; cg_h3="$HAS_TIME|$RQ_WIN"
        cg_b "$cg/w4.json"; cg_r4=$cg_rc; cg_h4="$HAS_TIME|$RQ_WIN"
        printf 'this is not a database\n' > "$cg/sw.db"; cg_b "$cg/w5.json"; cg_r5=$cg_rc; cg_h5="$HAS_TIME|$RQ_WIN|$RQ_HOLD"
        cp "$gdb" "$cg/sw.db"; cg_b "$cg/w6.json"; cg_r6=$cg_rc; cg_b "$cg/w7.json"; cg_h7=$RQ_WIN
        if [ "$cg_ws" = " APS1 CLI1 PRB1 RESP1 " ] && [ "$cg_r3" = 0 ] && [ "$cg_h3" = "0| APS5 " ] && grep -q '"ssid": "LegacyGc"' "$cg/w3.json" && [ "$cg_r4" = 0 ] && grep -q '"ssid": "LegacyGc"' "$cg/w4.json" && [ "$cg_h4" = "0| APS5 " ] \
           && [ "$cg_r5" = 1 ] && [ "$cg_h5" = "||the copy is not a database" ] && [ "$cg_r6" = 0 ] && [ "$cg_h7" = "$cg_ws" ] && cmp -s "$cg/w2.json" "$cg/w7.json"; then
            st_pass "recon batch: the winners are dropped with HAS_TIME: the file changes shape (the pass sees another shape of the tables and asks again at once as a first batch: the legacy table is learnt in the same cycle, APS5), a torn copy, and back; a new learning pass gives the old document"
        else st_fail "recon batch: schema reset (win [$cg_ws], legacy $cg_r3 [$cg_h3] $cg_r4 [$cg_h4], torn $cg_r5 [$cg_h5], back $cg_r6 [$cg_h7])"; fi

        # ---- 3b) the table of the window is judged by its own CREATE, not by what a failing alternative of the tail prints (the statement it ran, rwin and all); a refusal costs no pass
        cg_fresh "$gdb"; cg_b "$cg/x1.json"; cg_b "$cg/x2.json"; cg_x2="$RW_USED|$RW_OFF"
        CYC_NOW=$((cg_now + 200000)); cg_b "$cg/x3.json"; cg_x3="$cg_rc|$HAS_TIME|$RQ_WIN|$RW_OFF|$RW_USED"; CYC_NOW=""
        cg_b "$cg/x4.json"; cg_b "$cg/x5.json"; cg_s5=$(cat "$CYC_SQL"); cg_x5="$RW_USED|$RW_OFF"
        # the old rule (a line of the error text names rwin, and ssid is there) on the text sqlite3 prints for the tail's RESP2 on this schema: it latched the table off for good
        printf 'Parse error near line 12: no such column: apmac\n  SELECT apmac, COUNT(DISTINCT CAST(ssid AS TEXT)) FROM rwin WHERE type=5 AND apmac IS NOT NULL\n                 error here ---^\n#starchorus-exit 1\n' > "$cg/old-err.txt"
        cg_old=0; grep -q rwin "$cg/old-err.txt" && ! grep -q 'no such table: ssid' "$cg/old-err.txt" && cg_old=1
        # a database reader that refuses the table (the stand-in drops the CREATE): the marker row is missing, this pass is asked again at once without the table, the next ones too, until the count runs out
        CYC_NOCREATE=1; cg_b "$cg/x6.json"; cg_x6="$cg_rc|$RW_OFF|$(cg_calls)"; cg_sx6=$(cat "$CYC_SQL"); CYC_NOCREATE=""
        RW_OFF=1; cg_b "$cg/x7.json"; cg_s7=$(cat "$CYC_SQL"); cg_x7="$RW_OFF"; cg_b "$cg/x8.json"; cg_s8=$(cat "$CYC_SQL"); cg_x8="$RW_USED|$RW_OFF"
        if [ "$cg_x2" = "1|0" ] && [ "$cg_x3" = "1|||0|1" ] && [ "$cg_x5" = "1|0" ] && [ "$(cg_n "$cg_s5" 'FROM rwin')" -ge 4 ] && cmp -s "$cg/x2.json" "$cg/x5.json" && [ "$cg_old" = 1 ] \
           && [ "$cg_x6" = "0|59|2" ] && [ "$(cg_n "$cg_sx6" 'CREATE TEMP TABLE rwin')" = 1 ] && [ "$(cg_n "$cg_sx6" 'FROM ssid')" -ge 6 ] && cmp -s "$cg/x2.json" "$cg/x6.json" \
           && [ "$(cg_n "$cg_s7" rwin)" = 0 ] && [ "$cg_x7" = 0 ] && cmp -s "$cg/x2.json" "$cg/x7.json" && [ "$(cg_n "$cg_s8" 'CREATE TEMP TABLE rwin')" = 1 ] && [ "$cg_x8" = "1|0" ] && cmp -s "$cg/x2.json" "$cg/x8.json"; then
            st_pass "recon batch: a pass with no access point in the window (one empty hour, a tail whose alternatives fail and print rwin) leaves the table on (the old rule, rwin in an error line, switched it off for good); a reader that refuses it is asked again in the same cycle on ssid (2 sqlite3 starts, the same document), the table is left alone for 59 passes and then tried again"
        else st_fail "recon batch: the window's table ($cg_x2 / empty window [$cg_x3] / again $cg_x5, old rule $cg_old, refused [$cg_x6] [$cg_x7] [$cg_x8])"; fi

        # ---- 3c) the file changes shape under the winners and the access points still come back: the reduced batch alone would publish no station at all (CLI1 and PRB1 name a table that is gone)
        cp "$gdb" "$cg/sw2.db"; cg_fresh "$cg/sw2.db"; cg_b "$cg/y1.json"; cg_b "$cg/y2.json"; cg_ys=$(cat "$CYC_SQL"); cg_yw=$RQ_WIN
        sqlite3 "$cg/sw2.db" >/dev/null 2>&1 <<'SQL'
ALTER TABLE wifi_device RENAME TO wifi_dev_old;
ALTER TABLE ssid ADD COLUMN stamac TEXT;
UPDATE ssid SET stamac = (SELECT mac FROM wifi_dev_old WHERE wifi_dev_old.hash = ssid.wifi_device) WHERE type = 4;
SQL
        cg_yo=$(printf '%s\n' "$cg_ys" | sqlite3 -readonly -noheader -separator "$cg_t" "$cg/sw2.db" 2>/dev/null)
        RQ_SRC="$NL$cg_yo$NL"; sq_section CLIENTS; cg_yc=$RQ_SECT; sq_section APS; cg_ya=$RQ_SECT
        cg_b "$cg/y3.json"; cg_y3="$cg_rc|$RQ_WIN"
        cg_fresh "$cg/sw2.db"; cg_b "$cg/y4.json"
        if [ "$cg_yw" = " APS1 CLI1 PRB1 RESP1 " ] && [ -z "$cg_yc" ] && [ -n "$cg_ya" ] && [ "$cg_y3" = "0| APS1 CLI3 PRB2 RESP1 " ] && cmp -s "$cg/y3.json" "$cg/y4.json" \
           && [ "$(grep -c '02:00:00:d2:00:0[12]' "$cg/y3.json")" = 2 ] && [ "$(grep -c '02:00:00:d2:00:0[12]' "$cg/y2.json")" = 2 ]; then
            st_pass "recon batch: a file that changes shape under the winners with its access points intact (wifi_device gone, stamac in ssid) gives the clients in the same cycle, the winners are learnt again (CLI3, PRB2; APS1 and RESP1 stay) and the document is the first batch's; the winners' own batch on that file finds no station"
        else st_fail "recon batch: shape change with access points (win [$cg_yw], old batch clients [$cg_yc] aps [$(printf '%s' "$cg_ya" | cut -c1-30)], after [$cg_y3], $(cmp "$cg/y3.json" "$cg/y4.json" 2>&1 | head -n 1))"; fi

        # ---- 3d) the first non-empty alternative holds for a group WITH a winner too: a file with the legacy table beside ssid, both valid. The window empties: the legacy table
        # is the first non-empty alternative and is published in the same cycle (the tail's question "APS5 has rows while APS1 has none" gave a row); the window fills again: APS1
        # comes before the winner APS5, its question gives a row, and ssid's access points are back in the same cycle. The oracle is a first batch of the same state (recondb_pick).
        cp "$gdb" "$cg/hy.db"; sqlite3 "$cg/hy.db" >/dev/null 2>&1 <<'SQL'
CREATE TABLE aps (bssid TEXT, ssid TEXT, channel INTEGER, signal INTEGER, privacy TEXT);
INSERT INTO aps VALUES ('02:00:00:aa:00:02','LegacyHy', 11, -48, 'WPA2');
SQL
        cg_fresh "$cg/hy.db"; cg_b "$cg/k1.json"; cg_b "$cg/k2.json"; cg_k2="$RQ_WIN|$(cg_calls)"; cg_sk2=$(cat "$CYC_SQL")
        CYC_NOW=$((cg_now + 200000)); cg_b "$cg/k3.json"; cg_k3="$cg_rc|$RQ_WIN|$(cg_calls)"; cg_b "$cg/k4.json"; cg_k4="$cg_rc|$RQ_WIN|$(cg_calls)"; cg_sk4=$(cat "$CYC_SQL")
        CYC_NOW=""; cg_b "$cg/k5.json"; cg_k5="$cg_rc|$RQ_WIN|$(cg_calls)"; cg_b "$cg/k6.json"; cg_k6="$cg_rc|$RQ_WIN|$(cg_calls)"
        CYC_NOW=$((cg_now + 200000)); cg_fresh "$cg/hy.db"; cg_b "$cg/kE.json"; CYC_NOW=""; cg_fresh "$cg/hy.db"; cg_b "$cg/kF.json"
        cg_kq() { cg_e "$1" "^SELECT 1 WHERE EXISTS \\(SELECT bssid, .* FROM aps\\) AND NOT EXISTS \\(SELECT s\\.bssid, "; }      # APS4 to APS7 asked behind APS1
        if [ "$cg_k2" = " APS1 CLI1 PRB1 RESP1 |1" ] && [ "$(cg_kq "$cg_sk2")" = 4 ] && [ "$cg_k3" = "0| APS5 |2" ] && [ "$cg_k4" = "0| APS5 |1" ] \
           && [ "$(cg_e "$cg_sk4" "^SELECT 1 WHERE EXISTS \\(SELECT s\\.bssid, .*\\);$")" = 1 ] && [ "$cg_k5" = "0| APS1 CLI1 PRB1 RESP1 |2" ] && [ "$cg_k6" = "0| APS1 CLI1 PRB1 RESP1 |1" ] \
           && grep -q '"ssid": "LegacyHy"' "$cg/kE.json" && ! grep -q '"ssid": "LegacyHy"' "$cg/kF.json" && grep -q '"ssid": "GcAP-One"' "$cg/kF.json" \
           && cmp -s "$cg/k1.json" "$cg/kF.json" && cmp -s "$cg/k2.json" "$cg/kF.json" && cmp -s "$cg/k3.json" "$cg/kE.json" && cmp -s "$cg/k4.json" "$cg/kE.json" \
           && cmp -s "$cg/k5.json" "$cg/kF.json" && cmp -s "$cg/k6.json" "$cg/kF.json"; then
            st_pass "recon batch: a file with the legacy table beside ssid: the window empties and the legacy table is published in the same cycle (APS5 learnt), the window fills and ssid's access points are back in the same cycle (APS1 learnt again); every document is the first batch's of the same state (the winner alone kept the legacy table)"
        else st_fail "recon batch: winner that comes back empty ([$cg_k2] q $(cg_kq "$cg_sk2") [$cg_k3] [$cg_k4] [$cg_k5] [$cg_k6], $(cmp "$cg/k5.json" "$cg/kF.json" 2>&1 | head -n 1))"; fi

        # ---- 3e) a batch with the window's table that goes through recondb_pick (HAS_TIME known, the winners learnt under another STARCHORUS_TRAFFIC) keeps the table's marker
        # row and the table (one sqlite3 start); the next batch is the reduced one, and CLI1, which reads CLI0's rows by CLI0's clauses, is not asked behind it
        cg_fresh "$gdb"; cg_b "$cg/t1.json"; cg_b "$cg/t2.json"
        TRAFFIC=1; cg_b "$cg/t3.json"; cg_t3="$cg_rc|$RW_USED|$RW_OFF|$(cg_calls)|$(cg_stubs awk)|$RQ_WIN"; cg_st3=$(cat "$CYC_SQL")
        cg_b "$cg/t4.json"; cg_t4="$RW_USED|$(cg_calls)|$(cg_stubs awk)"; cg_st4=$(cat "$CYC_SQL")
        cg_fresh "$gdb"; cg_b "$cg/tF.json"; TRAFFIC=0
        if [ "$cg_t3" = "0|1|0|1|2| APS1 CLI0 PRB1 RESP1 " ] && [ "$(cg_n "$cg_st3" 'CREATE TEMP TABLE rwin')" = 1 ] && [ "$(cg_n "$cg_st3" "STARCHORUS_CLI0#")" = 1 ] && cmp -s "$cg/t3.json" "$cg/tF.json" \
           && [ "$cg_t4" = "1|1|1" ] && [ "$(cg_n "$cg_st4" "STARCHORUS_CLI1#")" = 0 ] && [ "$(cg_n "$cg_st4" "STARCHORUS_CLI3#")" = 1 ] && [ "$(cg_n "$cg_st4" "STARCHORUS_CLIENTS#")" = 1 ] \
           && cmp -s "$cg/t4.json" "$cg/tF.json" && grep -q '"packets"' "$cg/tF.json"; then
            st_pass "recon batch: a batch that goes through the pick keeps the window table's marker (the table stays on, one sqlite3 start, the first batch's document); behind the winner CLI0 its twin CLI1 is not asked, CLI3 is"
        else st_fail "recon batch: the pick and the window's marker [$cg_t3] [$cg_t4] ($(cmp "$cg/t3.json" "$cg/tF.json" 2>&1 | head -n 1))"; fi

        # ---- 3f) rq_tail: a tail with rows returns before the cut that counts from the start (the text is left as it was); a tail without one is cut out
        cg_rows=""; cg_i=0; while [ "$cg_i" -lt 50 ]; do cg_rows="$cg_rows${NL}020000F0$cg_i${cg_t}-60"; cg_i=$((cg_i + 1)); done
        RQ_TA="CLI1 "; pick="#STARCHORUS_WMIN#${NL}5${NL}#STARCHORUS_TAIL#${NL}#STARCHORUS_CLI1#$cg_rows${NL}#STARCHORUS_TAILEND#${NL}#STARCHORUS_APS#${NL}a"; cg_p0=$pick
        rq_tail; cg_q1=$?; cg_q1p=$pick
        pick="#STARCHORUS_WMIN#${NL}5${NL}#STARCHORUS_TAIL#${NL}#STARCHORUS_CLI1#${NL}#STARCHORUS_TAILEND#${NL}#STARCHORUS_APS#${NL}a"; rq_tail; cg_q2="$?|$pick"; RQ_TA=""; pick=""
        if [ "$cg_q1" = 1 ] && [ "$cg_q1p" = "$cg_p0" ] && [ "$cg_q2" = "0|#STARCHORUS_WMIN#${NL}5${NL}#STARCHORUS_APS#${NL}a" ]; then
            st_pass "rq_tail: a tail with rows says so before anything is cut (the text untouched: no search past the tail's rows), a tail without rows is cut out and the sections around it are kept"
        else st_fail "rq_tail: rows [$cg_q1, text $( [ "$cg_q1p" = "$cg_p0" ] && echo kept || echo cut)] none [$cg_q2]"; fi

        # ---- 4) HOP and an access point alone: the section by expansion, and no marker row taken for an access point
        HOPINFO=1; cg_fresh "$gdb"; cg_b "$cg/h1.json"; cg_h1s=$(cat "$CYC_SQL"); cg_b "$cg/h2.json"; cg_hs=$(cat "$CYC_SQL"); HOPINFO=0
        sqlite3 "$cg/ap.db" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB, hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'020000D30001','LonelyAP',0,$((cg_now - 5)),-50,2437,6,8);
SQL
        cg_fresh "$cg/ap.db"; cg_b "$cg/p1.json"; cg_b "$cg/p2.json"
        if grep -q '"channels": \[{"freq": 2412' "$cg/h1.json" && cmp -s "$cg/h1.json" "$cg/h2.json" && [ "$(cg_n "$cg_hs" 'FROM ssid')" = 2 ] \
           && [ "$(grep -c '"bssid"' "$cg/p1.json")" = 1 ] && ! grep -q STARCHORUS "$cg/p1.json" && cmp -s "$cg/p1.json" "$cg/p2.json"; then
            st_pass "recon batch: HOPINFO asks ssid (its history has no window) in the reduced batch too and gives the same channels[]; a database with one access point, no station and a window publishes that one access point (the WMIN row was once taken for two more)"
        else st_fail "recon batch: hop / lone AP ($(grep -c '"bssid"' "$cg/p1.json") aps, $(cg_n "$cg_hs" 'FROM ssid') FROM ssid)"; fi

        # ---- 4b) what the shell reads sits at the start of the batch: HOP is asked before every group (the shell finds a section by trying prefix after prefix, so one behind the
        # 2 MB of stations of STARCHORUS_MAX_AGE=0 costs the square of that: 30 s in dash for a build, the first version of this read it from the end)
        cg_hp() {
            cg_hl=$(printf '%s\n' "$1" | grep -n "SELECT '#STARCHORUS_HOP#'" | head -n 1 | cut -d: -f1); [ -n "$cg_hl" ] || return 1
            cg_gl=$(printf '%s\n' "$1" | grep -n -E "SELECT '#STARCHORUS_(APS|CLI|PRB|RESP|CLIENTS|PROBES)[0-9]*#'" | head -n 1 | cut -d: -f1)
            [ -n "$cg_gl" ] && [ "$cg_hl" -lt "$cg_gl" ]
        }
        cg_hold=$(printf "%s\n" "SELECT '#STARCHORUS_APS1#';" 'SELECT 1;' "SELECT '#STARCHORUS_CLI1#';" 'SELECT 2;' "SELECT '#STARCHORUS_HOP#';" 'SELECT 3;' "SELECT '#STARCHORUS_RESP1#';")
        if cg_hp "$cg_h1s" && cg_hp "$cg_hs" && ! cg_hp "$cg_hold" && [ "$(cg_n "$cg_hs" "STARCHORUS_HOP#")" = 1 ]; then
            st_pass "recon batch: HOP is asked right behind WMIN, before every group, in the first batch and the reduced one (read from the start of the output); a batch that asks it behind the groups is told apart"
        else st_fail "recon batch: HOP position (first $(cg_hp "$cg_h1s" && echo ok || echo late), reduced $(cg_hp "$cg_hs" && echo ok || echo late), old order $(cg_hp "$cg_hold" && echo ok || echo late))"; fi

        # ---- 4c) the rows the shell read itself are skipped by the final awk, marker by marker: an access point, then ONE marker with a row (a number) behind it (a marker that is not
        # known keeps the mode of the section before it, so each is tried straight behind the access point); the same program with that marker's entry gone takes the marker line, or its row, for a second access point
        cg_ap="02:00:00:00:00:01${cg_t}Net-A${cg_t}2412${cg_t}${cg_t}1${cg_t}-50${cg_t}0${cg_t}0${cg_t}1700000000${cg_t}0${cg_t}0${cg_t}0${cg_t}0"
        cg_fa() {   # $1 = the marker, $2 = the awk program: the access points the final awk makes of an APS section followed by that marker and a row
            { printf '#STARCHORUS_APS#\n%s\n#STARCHORUS_%s#\n' "$cg_ap" "$1"; [ "$1" = RWOK ] || [ "$1" = TAIL ] || [ "$1" = TAILEND ] || printf '1700000000\n'; } \
              | SC_CH="" SC_CX="" awk -v ts=1 -v center="$CENTER_LABEL" -v src=recon-db -v FSU="$cg_t" "$AWK_JSON_HELPERS$AWK_SEC$2" | grep -c '"bssid"'
        }
        cg_fq=""; cg_fn=0
        for cg_k in WMIN SCHEMA RWOK HASTIME HOP OWN TAIL TAILEND; do
            cg_fn=$((cg_fn + 1))
            cg_pl=$(printf '%s' "$AWK_RECONDB" | sed "s|MK\[\"#STARCHORUS_${cg_k}#\"\]|MK[\"#STARCHORUS_${cg_k}_X#\"]|")
            [ "$cg_pl" != "$AWK_RECONDB" ] && [ "$(cg_fa "$cg_k" "$AWK_RECONDB")" = 1 ] && [ "$(cg_fa "$cg_k" "$cg_pl")" -gt 1 ] || cg_fq="$cg_fq $cg_k"
        done
        if [ "$cg_fn" = 8 ] && [ -z "$cg_fq" ]; then
            st_pass "recon batch: the final awk takes one access point out of an APS section followed by any of the markers the shell reads itself, each with a row behind it (WMIN, SCHEMA, RWOK, HASTIME, HOP, OWN, TAIL, TAILEND); with that marker's entry gone it takes more (the oldest-row marker was once taken for two access points)"
        else st_fail "recon batch: skipped markers (entries that change nothing:${cg_fq:- none})"; fi

        # ---- 5) the process a cycle no longer starts: date (the cycle's clock reaches the builder), df (every 20th cycle), rm of the flash copy (once), wc of the kept document, the stderr awk
        CG_FAKE=""; : > "$cg/dates"
        date() { printf '%s\n' "$*" >> "$cg/dates"; if [ "$1" = "+%s" ] && [ -n "$CG_FAKE" ]; then printf '%s\n' "$CG_FAKE"; else command date "$@"; fi; }
        cg_fresh "$gdb"; : > "$cg/dates"; run_cycle >/dev/null 2>&1; cg_d1=$(grep -c -x -- '+%s' "$cg/dates")
        : > "$cg/dates"; build_from_recondb 1710000000 >/dev/null 2>&1; cg_d2=$(grep -c -x -- '+%s' "$cg/dates")
        if [ "$cg_d1/$cg_d2" = 1/1 ] && json_ok < "$OUTFILE"; then
            st_pass "run_cycle: the clock is read once (date +%s), the builder cuts the window from the cycle's own value; the builder asked on its own still reads the clock (1), so the count sees it"
        else st_fail "run_cycle: date +%s calls $cg_d1/$cg_d2 (want 1/1)"; fi
        # ram_room: df is asked at the first cycle, then every 20th, at once for another size class or directory, after a no, and the old form asked every time
        ram_room_old() {
            rr_need=$(( ($2 + 1023) / 1024 )); rr_need=$(( rr_need + rr_need / 2 + 2048 ))
            rr_av=$(df -Pk "$1" 2>/dev/null | { read -r _; read -r _ _ _ rr_a _; printf '%s' "$rr_a"; })
            case $rr_av in ''|*[!0-9]*) return 0 ;; esac
            [ "$rr_av" -ge "$rr_need" ]
        }
        RR_OK=""; : > "$CYC_STUB"; cg_i=0; while [ "$cg_i" -lt 25 ]; do ram_room "$cg/ram" 3500000; cg_i=$((cg_i + 1)); done; cg_k1=$(cg_stubs df)
        : > "$CYC_STUB"; ram_room "$cg/ram" 9000000; cg_k2=$(cg_stubs df)
        : > "$CYC_STUB"; ram_room "$cg/ram2" 9000000; cg_k3=$(cg_stubs df)
        RR_OK=""; CYC_DFFULL=1; : > "$CYC_STUB"; ram_room "$cg/ram2" 9000000; cg_f1=$?; ram_room "$cg/ram2" 9000000; cg_f2=$?; ram_room "$cg/ram2" 9000000; cg_f3=$?; cg_k4=$(cg_stubs df); CYC_DFFULL=""
        : > "$CYC_STUB"; ram_room "$cg/ram2" 9000000; cg_f4=$?; cg_k5=$(cg_stubs df)
        : > "$CYC_STUB"; cg_i=0; while [ "$cg_i" -lt 25 ]; do ram_room_old "$cg/ram" 3500000; cg_i=$((cg_i + 1)); done; cg_k6=$(cg_stubs df)
        if [ "$cg_k1/$cg_k2/$cg_k3/$cg_k4/$cg_k5/$cg_k6" = 2/1/1/3/1/25 ] && [ "$cg_f1$cg_f2$cg_f3$cg_f4" = 1110 ]; then
            st_pass "ram_room: df runs at the first of 25 cycles and the 21st (2), at once for another size class (1) or directory (1), at every cycle after a no (3 of 3, all refused) and when room is back (1); the old form asked 25 times"
        else st_fail "ram_room: df calls $cg_k1/$cg_k2/$cg_k3/$cg_k4/$cg_k5/$cg_k6 (want 2/1/1/3/1/25), answers $cg_f1$cg_f2$cg_f3$cg_f4 (want 1110)"; fi
        # a yes that went stale (the tmpfs filled up since): the cp fails, the flash copy is used and removed again when RAM works, and the room is asked again
        cg_fresh "$gdb"; cg_b "$cg/m1.json"; cg_k1=$(cg_stubs df); cg_o1=$RR_OK
        CYC_CPFAIL=1; cg_b "$cg/m2.json"; cg_k2=$(cg_stubs df); cg_fl=0; [ -s "$CAPDIR/recon_copy.db" ] && cg_fl=1; cg_o2="$RR_OK|$FLASH_COPY"; CYC_CPFAIL=""
        CYC_DFFULL=1; cg_b "$cg/m3.json"; cg_k3=$(cg_stubs df); cg_fl3=0; [ -s "$CAPDIR/recon_copy.db" ] && cg_fl3=1; CYC_DFFULL=""
        cg_b "$cg/m4.json"; cg_k4=$(cg_stubs df); cg_fl4=0; [ -e "$CAPDIR/recon_copy.db" ] && cg_fl4=1
        if [ "$cg_k1/$cg_o1" = 1/1 ] && [ "$cg_k2/$cg_fl/$cg_o2" = 0/1/"|1" ] && [ "$cg_k3/$cg_fl3" = 1/1 ] && [ "$cg_k4/$cg_fl4/$FLASH_COPY" = 1/0/0 ] \
           && cmp -s "$cg/m1.json" "$cg/m2.json" && cmp -s "$cg/m2.json" "$cg/m3.json" && cmp -s "$cg/m3.json" "$cg/m4.json"; then
            st_pass "recon copy: a cached yes whose tmpfs has filled meanwhile falls to the flash copy at the failed cp (df not asked, copy made, room forgotten), df is asked at the next cycle (no room: flash again), then RAM, the flash copy removed; the document is the same bytes each time"
        else st_fail "recon copy: stale yes (df $cg_k1/$cg_k2/$cg_k3/$cg_k4, flash $cg_fl/$cg_fl3/$cg_fl4, state $cg_o1 [$cg_o2] $FLASH_COPY)"; fi
        # the flash copy's rm: once (a copy may be there), not on every cycle
        FLASH_COPY=1; : > "$CAPDIR/recon_copy.db"; RR_OK=""; : > "$CYC_STUB"; cg_i=0; while [ "$cg_i" -lt 5 ]; do build_from_recondb 1710000000 >/dev/null 2>&1; cg_i=$((cg_i + 1)); done
        cg_r1=$(grep -c '^rm .*recon_copy\.db' "$CYC_STUB"); cg_rf=0; [ -e "$CAPDIR/recon_copy.db" ] && cg_rf=1
        : > "$CYC_STUB"; cg_i=0; while [ "$cg_i" -lt 5 ]; do rm -f "$CAPDIR/recon_copy.db" "$CAPDIR/recon_copy.db-wal" "$CAPDIR/recon_copy.db-shm"; cg_i=$((cg_i + 1)); done; cg_r2=$(grep -c '^rm .*recon_copy\.db' "$CYC_STUB")
        if [ "$cg_r1/$cg_rf/$FLASH_COPY/$cg_r2" = 1/0/0/5 ]; then
            st_pass "recon copy: the stale flash copy is removed by the first RAM cycle (1 rm in 5 cycles, the file gone, the flag clear); the old statement ran 5 times"
        else st_fail "recon copy: flash rm $cg_r1/$cg_rf/$FLASH_COPY/$cg_r2 (want 1/0/0/5)"; fi
        # a full pass keeps its document: the line count comes from doc_whole (no wc); the skipped cycle after it announces the interval as it is now
        SKIP_UNCHANGED=1; MAX_AGE=0; PACE_MORE=0; RS_SIG=""; RS_SKIPS=0; RS_DOCV=""; cg_fresh "$gdb"
        CG_FAKE=$((cg_now + 1000)); : > "$CYC_STUB"; run_cycle >/dev/null 2>&1; cg_wc1=$(cg_stubs wc); cg_nl=$(grep -c '' "$OUTFILE")
        cg_dn="$RS_DOCN/$DOC_N"; cg_k1=$RS_SKIPS
        CG_FAKE=$((cg_now + 1010)); PACE_MORE=8; : > "$CYC_LOG"; : > "$CYC_STUB"; run_cycle >/dev/null 2>&1; cg_s=$(cg_calls); cg_i38=$(grep -c '"interval": 38' "$OUTFILE"); cg_g=$(grep -c "\"generated\": $CG_FAKE," "$OUTFILE")
        CG_FAKE=$((cg_now + 1020)); PACE_MORE=0; run_cycle >/dev/null 2>&1; cg_i30=$(grep -c '"interval": 30' "$OUTFILE"); cg_i38b=$(grep -c '"interval": 38' "$OUTFILE")
        : > "$CYC_STUB"; rs_keepdoc "$OUTFILE" >/dev/null 2>&1; cg_wc2=$(cg_stubs wc)
        printf '{\n  "aps": [\n  ]\n}\n' > "$cg/dw.json"; doc_whole "$cg/dw.json"; cg_dw="$DOC_N"; printf '{\n  "aps": [\n' > "$cg/dw2.json"; doc_whole "$cg/dw2.json"; cg_dw2="$?|$DOC_N"
        if [ "$cg_wc1" = 0 ] && [ "$cg_dn" = "$cg_nl/$cg_nl" ] && [ "$cg_k1" = 0 ] && [ "$cg_s" = 0 ] && [ "$cg_i38/$cg_g" = 1/1 ] && [ "$cg_i30/$cg_i38b" = 1/0 ] && [ "$cg_wc2" = 1 ] && [ "$cg_dw" = 4 ] && [ "$cg_dw2" = "1|" ]; then
            st_pass "run_cycle: a full pass keeps its document without a wc (line count from doc_whole: $cg_nl), the cycle after it is skipped (no sqlite3) and says interval 38 while the loop sleeps 8 s more, and 30 when it does not; rs_keepdoc asked without the count still counts (1 wc)"
        else st_fail "run_cycle: kept document (wc $cg_wc1/$cg_wc2, lines $cg_dn want $cg_nl, calls $cg_s, interval $cg_i38/$cg_g/$cg_i30/$cg_i38b, doc_whole $cg_dw $cg_dw2)"; fi
        unset -f date; CG_FAKE=""

        # ---- 6) the loop's pace and the hourly line, against a /proc/uptime of our own
        BT_PROC="$cg/proc"; INTERVAL=30; SKIP_UNCHANGED=0; PACE_MORE=0
        printf '1000.00 900.00\n' > "$cg/proc/uptime"; cg_fresh "$gdb"; CYC_UP="$cg/proc/uptime"; CYC_UPV=1012.40; export CYC_UP CYC_UPV
        TEL_T0=0; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0
        cycle_step >/dev/null 2>&1; cg_p1=$PACE_MORE; cg_e1=$(center_extra)
        CYC_UP=""; export CYC_UP
        printf '1100.00 900.00\n' > "$cg/proc/uptime"; PACE_T0=110000; printf '1100.30 900.00\n' > "$cg/proc/uptime"; pace_end; cg_p2=$PACE_MORE; cg_e2=$(center_extra)
        PACE_T0=100000; printf '1010.00 9.00\n' > "$cg/proc/uptime"; pace_end; cg_p3=$PACE_MORE
        PACE_T0=100000; printf '1010.01 9.00\n' > "$cg/proc/uptime"; pace_end; cg_p4=$PACE_MORE
        PACE_T0=100000; printf '5000.00 9.00\n' > "$cg/proc/uptime"; pace_end; cg_p5=$PACE_MORE
        BT_PROC="$cg/no-proc"; PACE_T0=100000; pace_end; cg_p6=$PACE_MORE; pace_begin; cg_p7="$PACE_T0"; BT_PROC="$cg/proc"
        if [ "$cg_p1" = 8 ] && printf '%s' "$cg_e1" | grep -q '"interval": 38' && [ "$cg_p2" = 0 ] && printf '%s' "$cg_e2" | grep -q '"interval": 30' \
           && [ "$cg_p3/$cg_p4/$cg_p5/$cg_p6/$cg_p7" = 0/1/3570/0/ ]; then
            st_pass "loop pace: a cycle of 12.4 s through cycle_step sleeps 38 s (INTERVAL 30 + 8) and announces interval 38; 0.3 s sleeps 30; 10.00 s is 30, 10.01 s is 31, a cycle of 4000 s is capped at 3600; without /proc/uptime there is no backoff"
        else st_fail "loop pace: more $cg_p1/$cg_p2/$cg_p3/$cg_p4/$cg_p5/$cg_p6/[$cg_p7], interval [$cg_e1] [$cg_e2]"; fi
        # the hourly line: one per hour of the cycles' own clock, with what happened in it; none before the hour is out; a clock set back begins a new hour
        printf '102.00 9.00\n' > "$cg/proc/uptime"
        TEL_T0=0; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0; : > "$cg/tel.log"
        ts=1000000; rc_skip=0; PACE_T0=10000; pace_end 2>> "$cg/tel.log"
        ts=1001800; rc_skip=1; PACE_T0=10000; pace_end 2>> "$cg/tel.log"; cg_tl1=$(grep -c . "$cg/tel.log")
        ts=999000; rc_skip=1; PACE_T0=10000; pace_end 2>> "$cg/tel.log"; cg_tl2=$(grep -c . "$cg/tel.log"); cg_tt="$TEL_T0"
        ts=1002600; rc_skip=0; PACE_T0=10000; pace_end 2>> "$cg/tel.log"; cg_tl3=$(grep -c . "$cg/tel.log")
        BT_PROC="$cg/no-proc"; TEL_T0=0; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0; : > "$cg/tel2.log"
        ts=2000000; rc_skip=1; PACE_T0=""; pace_end 2>> "$cg/tel2.log"; ts=2003600; rc_skip=1; PACE_T0=""; pace_end 2>> "$cg/tel2.log"; BT_PROC="$cg/proc"
        if [ "$cg_tl1/$cg_tl2/$cg_tt/$cg_tl3" = 0/0/999000/1 ] && grep -qF '[starchorus] last hour, cycles: 2 full, 2 skipped (recon.db unchanged), mean wall time 2.00 s' "$cg/tel.log" \
           && grep -qF 'last hour, cycles: 0 full, 2 skipped (recon.db unchanged), mean wall time not measured here' "$cg/tel2.log" && [ "$(grep -c . "$cg/tel2.log")" = 1 ]; then
            st_pass "hourly line: nothing before the hour is out, a clock set back begins a new hour, then one line with the full and the skipped cycles and the mean wall time (2.00 s; 'not measured here' without /proc/uptime)"
        else st_fail "hourly line: lines $cg_tl1/$cg_tl2/$cg_tl3, T0 $cg_tt: $(cat "$cg/tel.log" "$cg/tel2.log" | tr '\n' '|')"; fi

        # ---- 6b) the Bluetooth window's waiting is no load: a cycle that computes 0.3 s and waits 5.2 s for the window at INTERVAL 5 sleeps no more (the whole 5.5 s would say 17 s); a cycle
        # that computes 12 s still backs off; the hourly line keeps the whole wall time. run_layers measures bt_end (stand-ins for it and add_layers, in a sub-shell of their own)
        cg_pb=$(
            bt_end() { printf '%s 9.00\n' "$CG_UPE" > "$cg/proc/uptime"; }
            add_layers() { return 1; }
            BT_PROC="$cg/proc"; INTERVAL=5; BLUETOOTH=1; BT_RC=0; BT_VOID=""; TRAFFIC=0; AL_ON=0; TR_PID=""; PACE_MORE=0; ts=0; rc_skip=0
            CG_UPE=1005.50; printf '1000.00 9.00\n' > "$cg/proc/uptime"; pace_begin; printf '1000.30 9.00\n' > "$cg/proc/uptime"
            run_layers "$cg/pb.json" >/dev/null 2>&1; a=$PACE_BT; pace_end 2>/dev/null; b="$PACE_MORE/$TEL_WALL"
            PACE_BT=0; pace_end 2>/dev/null; c=$PACE_MORE
            CG_UPE=1012.60; printf '1000.00 9.00\n' > "$cg/proc/uptime"; pace_begin; printf '1012.00 9.00\n' > "$cg/proc/uptime"
            run_layers "$cg/pb.json" >/dev/null 2>&1; pace_end 2>/dev/null; d=$PACE_MORE
            printf '%s|%s|%s|%s' "$a" "$b" "$c" "$d"
        )
        if [ "$cg_pb" = "520|0/550|12|31" ]; then
            st_pass "loop pace: the window's wait is taken off the wall time (0.3 s of work and 5.2 s of window at INTERVAL 5: no backoff, 0 where the whole 5.5 s gave 12; 12 s of work and 0.6 s of window: 31; the hourly line adds 5.50 s)"
        else st_fail "loop pace: window wait [$cg_pb] (want 520|0/550|12|31)"; fi

        # ---- 7) recondb_failed by builtins says what the awk said, line for line
        recondb_failed_old() {
            RQ_WHY=""
            [ -n "$RQ_ERRF" ] && [ -s "$RQ_ERRF" ] || return 1
            RQ_WHY=$(awk '
                /[Mm]alformed/ { m = 1 }
                /disk I\/O/ { d = 1 }
                /not a database/ { n = 1 }
                /^#starchorus-exit [0-9]+$/ { x = $2 + 0 }
                END { if (m) print "malformed"; else if (d) print "diskio"; else if (n) print "notdb"; else if (x >= 2) print "status " x }' "$RQ_ERRF" 2>/dev/null)
            case $RQ_WHY in
                malformed) RQ_WHY="the copy is malformed" ;;
                diskio) RQ_WHY="disk I/O error" ;;
                notdb) RQ_WHY="the copy is not a database" ;;
                status*) RQ_WHY="the database reader ended with $RQ_WHY" ;;
            esac
            [ -n "$RQ_WHY" ]
        }
        cg_fa=""; cg_i=0; cg_sv=$RQ_ERRF; RQ_ERRF="$cg/err.txt"
        for cg_c in 'x|#starchorus-exit 0' 'x|#starchorus-exit 1' 'Error: near line 3: no such column: stamac|#starchorus-exit 1' 'Parse error: database disk image is malformed|#starchorus-exit 11' \
                    'Error: disk I/O error|#starchorus-exit 10' 'Error: file is not a database|#starchorus-exit 26' 'x|#starchorus-exit 2' 'x|#starchorus-exit 139' 'x|#starchorus-exit 007' \
                    'Error: MALFORMED|#starchorus-exit 1' 'Error: Malformed schema|#starchorus-exit 1' 'Error: something else' 'Error: x|#starchorus-exit abc' 'x|#starchorus-exit 3|#starchorus-exit 0' \
                    'x|#starchorus-exit 1|#starchorus-exit 2' 'no newline at the end' ''; do
            cg_i=$((cg_i + 1)); printf '%s\n' "$cg_c" | tr '|' '\n' > "$cg/err.txt"
            [ "$cg_c" != 'no newline at the end' ] || printf 'Error: file is not a database' > "$cg/err.txt"
            [ -n "$cg_c" ] || : > "$cg/err.txt"
            recondb_failed; cg_r1="$?|$RQ_WHY"; recondb_failed_old; cg_r2="$?|$RQ_WHY"
            [ "$cg_r1" = "$cg_r2" ] || cg_fa="$cg_fa [$cg_i: $cg_r1 / $cg_r2]"
        done
        RQ_ERRF=$cg_sv; unset -f recondb_failed_old
        if [ -z "$cg_fa" ]; then st_pass "recondb_failed: by builtins, the same answer as the awk it replaced on $cg_i error files (damage words, exit statuses 0 to 139 and 007, several exit lines, no exit line, no newline, empty)"; else st_fail "recondb_failed: differs from the awk in$cg_fa"; fi

        # ---- put everything back
        PATH=$cg_path; TMPDIR_RAM=$cg_ram; RECON_DB=$cg_db; MAX_AGE=$cg_age; HOPINFO=$cg_hop; RESOLVED=$cg_res; OUTFILE=$cg_of; OUTDIR=$cg_od; VENDOR=$cg_ven; INTERVAL=$cg_iv
        SKIP_UNCHANGED=$cg_su; TRAFFIC=$cg_tr; BT_PROC=$cg_proc; CAPDIR=$cg_cap; SKIP_MAX=$cg_sm; HOMING_BSSID=$cg_hb; OWN=$cg_own
        HAS_TIME=""; RDB_PATH=""; RQ_WIN=""; RR_OK=""; RS_SIG=""; RS_SKIPS=0; RS_DOCV=""; PACE_MORE=0; PACE_T0=""; FLASH_COPY=1; CYC_UP=""; RW_OFF=0; RDB_SCH=""; PACE_BT=0; CYC_NOW=""
        TEL_T0=0; TEL_FULL=0; TEL_SKIP=0; TEL_WALL=0; TEL_NW=0
        unset CYC_LOG CYC_SQL CYC_REAL CYC_STUB CYC_UP CYC_UPV CYC_DFFULL CYC_CPFAIL CYC_NOCREATE
        unset -f cg_calls cg_stubs cg_n cg_e cg_b cg_fresh cg_m cg_rw ram_room_old cg_hp cg_mk cg_fa
        # ---- end 3b3

        # ---- 3c) a cycle with nothing new: only "generated" moves. A fake clock (FAKE_NOW) drives run_cycle; the database mtime is real and old.
        FAKE_NOW=0
        date() { if [ "$1" = "+%s" ]; then printf '%s\n' "$FAKE_NOW"; else command date "$@"; fi; }
        n0=$(command date +%s); kdb="$tdir/recon_skip.db"
        sqlite3 "$kdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'D0D0D0000001','OldAP',0,$((n0 + 50)),-50,2437,6,8);
INSERT INTO ssid VALUES (2,0,1,8,'D0D0D0000002','NewerAP',0,$((n0 + 80)),-60,2437,6,8);
INSERT INTO ssid VALUES (3,501,1,4,'FFFFFFFFFFFF','Q',0,$((n0 + 80)),-70,0,0,0);
INSERT INTO wifi_device VALUES (501,1,'D1D1D1000001',$((n0 + 80)),-70,0,1);
SQL
        RESOLVED=recondb; RECON_DB="$kdb"; OUTFILE="$rpt/skip.json"; OUTDIR="$rpt"; VENDOR=0; MAX_AGE=300; INTERVAL=30; HOMING_BSSID=""; OWN=0
        HAS_TIME=""; RDB_PATH=""; RS_SIG=""; RS_SKIPS=0; SKIP_MAX=20; SKIP_UNCHANGED=1; rm -f "$OUTFILE" "$rpt/homing.target" "$kdb-journal"
        cyc() { FAKE_NOW=$1; : > "$SHIM_LOG"; run_cycle >/dev/null 2>&1; }
        cyc $((n0 + 100)); c1=$(calls)
        grep -v '"generated"' "$OUTFILE" > "$rpt/s1.body"
        if [ "$c1" = 1 ] && grep -q '"generated": '$((n0 + 100))',' "$OUTFILE" && grep -q OldAP "$OUTFILE" && [ -n "$RS_SIG" ]; then st_pass "skip: the first cycle is a full pass and records recon.db's state"; else st_fail "skip: first cycle (calls $c1, sig [$RS_SIG])"; fi
        cyc $((n0 + 130)); c2=$(calls)
        grep -v '"generated"' "$OUTFILE" > "$rpt/s2.body"
        if [ "$c2" = 0 ] && grep -q '"generated": '$((n0 + 130))',' "$OUTFILE" && cmp -s "$rpt/s1.body" "$rpt/s2.body" && json_ok < "$OUTFILE" && [ "$RS_SKIPS" = 1 ]; then st_pass "skip: nothing changed -> no sqlite3, no copy; the file is the same but for a new generated"; else st_fail "skip: second cycle (calls $c2, skips $RS_SKIPS)"; fi
        cyc $((n0 + 340)); c3=$(calls)
        if [ "$c3" = 0 ] && grep -q OldAP "$OUTFILE"; then st_pass "skip: just before the oldest entry leaves the window the cycle is still skipped"; else st_fail "skip: before the cut-off (calls $c3)"; fi
        cyc $((n0 + 350)); c4=$(calls)
        if [ "$c4" = 1 ] && ! grep -q OldAP "$OUTFILE" && grep -q NewerAP "$OUTFILE" && json_ok < "$OUTFILE"; then st_pass "skip: the entry that ages out of STARCHORUS_MAX_AGE forces a full pass and disappears"; else st_fail "skip: ageing (calls $c4)"; fi
        cyc $((n0 + 360)); c5=$(calls)
        if [ "$c5" = 0 ]; then st_pass "skip: after the ageing pass the next quiet cycle is skipped again"; else st_fail "skip: after ageing (calls $c5)"; fi
        i=0; while [ "$i" -lt 150 ]; do printf "INSERT INTO ssid VALUES (%s,0,1,8,'D2D2D2%06d','Grown%s',0,%s,-80,2437,6,8);\n" $((100 + i)) "$i" "$i" $((n0 + 90)); i=$((i + 1)); done | "$rsq" "$kdb" >/dev/null 2>&1
        cyc $((n0 + 370)); c6=$(calls)
        if [ "$c6" = 1 ] && grep -q Grown149 "$OUTFILE"; then st_pass "skip: recon.db changed (size) -> full pass, the new entries are in"; else st_fail "skip: changed db (calls $c6)"; fi
        MAX_AGE=2000; cyc $((n0 + 380)); c7=$(calls); cyc $((n0 + 390)); c8=$(calls)
        if [ "$c7" = 1 ] && [ "$c8" = 0 ]; then st_pass "skip: a changed setting (STARCHORUS_MAX_AGE) is a full pass, the cycle after it is skipped again"; else st_fail "skip: settings change (calls $c7/$c8)"; fi
        MAX_AGE=0; cyc $((n0 + 410)); cyc $((n0 + 420)); c9=$(calls)
        if [ "$c9" = 0 ] && [ "$RS_SKIPS" -ge 1 ]; then st_pass "skip: without a window (MAX_AGE=0) nothing can age out, an unchanged database is skipped"; else st_fail "skip: MAX_AGE=0 (calls $c9)"; fi
        SKIP_MAX=2; RS_SIG=""; cyc $((n0 + 430)); d1=$(calls); cyc $((n0 + 440)); d2=$(calls); cyc $((n0 + 450)); d3=$(calls); cyc $((n0 + 460)); d4=$(calls); SKIP_MAX=20
        if [ "$d1/$d2/$d3/$d4" = 1/0/0/1 ]; then st_pass "skip: at most SKIP_MAX cycles in a row, then a full pass anyway"; else st_fail "skip: SKIP_MAX (calls $d1/$d2/$d3/$d4, want 1/0/0/1)"; fi
        cyc $((n0 + 470)); cyc $((n0 + 480)); HOMING_BSSID="d0:d0:d0:00:00:02"; cyc $((n0 + 490)); c12=$(calls)
        if [ "$c12" = 1 ]; then st_pass "skip: a homing target is read every cycle -> never skipped"; else st_fail "skip: homing (calls $c12)"; fi
        HOMING_BSSID=""; cyc $((n0 + 500)); c13=$(calls); cyc $((n0 + 510)); c14=$(calls)
        if [ "$c13" = 1 ] && [ "$c14" = 0 ] && ! grep -q '"homing"' "$OUTFILE"; then st_pass "skip: the target removed -> one full pass without the homing field, then skipping resumes"; else st_fail "skip: homing removed (calls $c13/$c14)"; fi
        : > "$kdb-journal"; cyc $((n0 + 520)); cyc $((n0 + 530)); c15=$(calls)
        rm -f "$kdb-journal"
        if [ "$c15" = 1 ]; then st_pass "skip: a -journal beside recon.db (a write in flight) is never recorded, never skipped"; else st_fail "skip: journal (calls $c15)"; fi
        SKIP_UNCHANGED=0; cyc $((n0 + 540)); cyc $((n0 + 550)); c16=$(calls); SKIP_UNCHANGED=1
        if [ "$c16" = 1 ]; then st_pass "skip: STARCHORUS_SKIP_UNCHANGED=0 -> every cycle is a full pass"; else st_fail "skip: flag off (calls $c16)"; fi
        cyc $((n0 + 560)); cyc $((n0 + 570)); cyc $((n0 + 100)); c17=$(calls)
        if [ "$c17" = 1 ]; then st_pass "skip: a clock set back -> full pass"; else st_fail "skip: clock back (calls $c17)"; fi
        # One ROW leaves the window while its entry stays: an AP with a strong old beacon and a weak new one, a station with an old and a new probe
        # (window 300 s). The oldest row the full pass counted is the clock, not the entry's last_seen; the document must change when the old rows go.
        wdb="$tdir/recon_rows.db"
        sqlite3 "$wdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (11,0,1,8,'E0E0E0000001','StrongOld',0,$((n0 + 50)),-30,2437,6,8);
INSERT INTO ssid VALUES (12,0,1,8,'E0E0E0000001','WeakNew',0,$((n0 + 200)),-80,2437,6,8);
INSERT INTO ssid VALUES (13,601,1,4,'FFFFFFFFFFFF','OldProbe',0,$((n0 + 50)),-70,0,0,0);
INSERT INTO ssid VALUES (14,601,1,4,'FFFFFFFFFFFF','NewProbe',0,$((n0 + 200)),-70,0,0,0);
INSERT INTO wifi_device VALUES (601,1,'E1E1E1000001',$((n0 + 200)),-70,0,1);
SQL
        RECON_DB="$wdb"; HAS_TIME=""; RDB_PATH=""; RS_SIG=""; MAX_AGE=300; SKIP_UNCHANGED=1
        cyc $((n0 + 300)); w1=$(calls); wd1=$(cat "$OUTFILE")
        cyc $((n0 + 340)); w2=$(calls)
        cyc $((n0 + 360)); w3=$(calls); wd3=$(cat "$OUTFILE")
        if [ "$w1" = 1 ] && [ "$w2" = 0 ] && printf '%s\n' "$wd1" | grep -q '"ssid": "StrongOld".*"rssi": -30' && printf '%s\n' "$wd1" | grep -q '"probes": \["NewProbe", "OldProbe"\]'; then
            st_pass "skip: while the oldest row of the window is still in it, the cycle is skipped"; else st_fail "skip: rows before the cut-off (calls $w1/$w2)"; fi
        if [ "$w3" = 1 ] && printf '%s\n' "$wd3" | grep -q '"ssid": "WeakNew".*"rssi": -80' && printf '%s\n' "$wd3" | grep -q '"probes": \["NewProbe"\]' && ! printf '%s\n' "$wd3" | grep -q 'StrongOld\|OldProbe'; then
            st_pass "skip: an old row leaves the window while its entry stays -> full pass (strongest beacon, ssid and probes follow the rows that are left)"
        else st_fail "skip: a row left the window (calls $w3)"; fi
        # what $OUTFILE holds is not trusted: another writer's document (a --once with other settings, a failed cycle's empty one) is replaced, not re-stamped
        cyc $((n0 + 390)); write_empty 1 "another cycle failed" > "$OUTFILE"
        cyc $((n0 + 420)); w4=$(calls)
        if [ "$w4" = 0 ] && grep -q '"source": "recon-db"' "$OUTFILE" && grep -q '"ssid": "WeakNew"' "$OUTFILE" && grep -q '"generated": '$((n0 + 420))',' "$OUTFILE" && json_ok < "$OUTFILE"; then
            st_pass "skip: a document someone else put in $OUTFILE is replaced by this process's own (no rebuild needed), not re-stamped"
        else st_fail "skip: foreign document (calls $w4)"; fi
        rm -f "$OUTFILE"; cyc $((n0 + 450)); w5=$(calls)
        if [ "$w5" = 0 ] && [ -s "$OUTFILE" ] && json_ok < "$OUTFILE"; then st_pass "skip: a missing $OUTFILE is written again from the kept document"; else st_fail "skip: file gone (calls $w5)"; fi
        # the document is kept in the process, not in a file: no RAM directory is needed for the skip, and none is left behind
        RS_SIG=""; TMPDIR_RAM="$rpt/no-such-dir"; cyc $((n0 + 480)); cyc $((n0 + 510)); w6=$(calls); TMPDIR_RAM="$rpt/ram"
        if [ "$w6" = 1 ] && [ -z "$(ls "$rpt/ram")" ]; then st_pass "skip: the kept document needs no file (a missing RAM directory changes nothing, nothing is left in the RAM directory)"; else st_fail "skip: no RAM directory (calls $w6, [$(ls "$rpt/ram")])"; fi
        RECON_DB="$kdb"; HAS_TIME=""; RDB_PATH=""; RS_SIG=""; MAX_AGE=0
        # The sample reads nothing and is taken once per cycle. A counting `ls` in front of PATH (it logs, then runs the real one) sees two
        # --full-time calls in a full pass (the sample before the copy, and the same look once more after it: recon_copy_settle) and one in a
        # skipped cycle, which makes no copy; nothing else in the cycle runs `ls`. (This expectation was one call in a full pass until the look
        # after the copy came in; it was moved to two on purpose, because that second look is the production
        # behaviour. It is an update to the behaviour, not a weaker check: the skipped cycle's one look and its zero reads are unchanged.)
        SHIM_REAL_LS=$(command -v ls); SHIM_LS="$rpt/lscalls"; export SHIM_REAL_LS SHIM_LS
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\necho x >> "$SHIM_LS"\nexec "$SHIM_REAL_LS" "$@"\n' > "$rpt/bin/ls"; chmod +x "$rpt/bin/ls"
        RS_SIG=""; : > "$SHIM_LS"; cyc $((n0 + 600)); l1=$(wc -l < "$SHIM_LS" | tr -d ' '); c18=$(calls)
        : > "$SHIM_LS"; cyc $((n0 + 630)); l2=$(wc -l < "$SHIM_LS" | tr -d ' '); c19=$(calls)
        rm -f "$rpt/bin/ls"
        if [ "$l1/$c18" = 2/1 ] && [ "$l2/$c19" = 1/0 ]; then st_pass "skip: recon.db's files are looked at twice in a full pass (one ls before the copy, one after it) and once in a skipped cycle, in which nothing is read"; else st_fail "skip: sample per cycle (ls $l1/$l2, sqlite3 $c18/$c19, want 2/1 and 1/0)"; fi
        # Without `ls --full-time` and without `stat` (the device has neither stat nor, on other systems, the long option): wc + date, the same decisions,
        # the -journal included. (A failing stand-in for each, in front of PATH.)
        printf '#!/bin/sh\nexit 1\n' > "$rpt/bin/ls"; cp "$rpt/bin/ls" "$rpt/bin/stat"; chmod +x "$rpt/bin/ls" "$rpt/bin/stat"
        RS_SIG=""; cyc $((n0 + 700)); cyc $((n0 + 730)); f1=$(calls); fsz=$RS_SZ
        : > "$kdb-journal"; cyc $((n0 + 760)); cyc $((n0 + 790)); f2=$(calls); rm -f "$kdb-journal"
        cyc $((n0 + 820)); cyc $((n0 + 850)); f3=$(calls)
        rm -f "$rpt/bin/ls" "$rpt/bin/stat"
        if [ "$f1/$f2/$f3" = 0/1/0 ] && [ "$fsz" = "$(wc -c < "$kdb" | tr -d ' ')" ]; then st_pass "skip: with neither ls --full-time nor stat the wc + date fallback decides alike (skipped, a -journal makes it a full pass, skipped again)"; else st_fail "skip: wc fallback (calls $f1/$f2/$f3, want 0/1/0; size $fsz)"; fi
        # file_size: the byte count of wc -c, from ls; a name with blanks and a glob character is one name
        printf 'abcdefg' > "$rpt/a b*c"; file_size "$rpt/a b*c"; fs1=$FSZ; file_size "$rpt/no such file"; fs2=$FSZ
        if [ "$fs1" = 7 ] && [ -z "$fs2" ]; then st_pass "file_size: bytes from ls (a name with a blank and a star), nothing for a missing file"; else st_fail "file_size: [$fs1] [$fs2]"; fi
        # ---- 3b2) the copy is stamped again when it is made (recon_copy_settle), and a pass whose copy cannot be read keeps the last document.
        #      Stand-ins first in PATH: `ls` that counts, `cp` that copies and then plays the engine (cut1 = the FIRST copy comes out cut short and the source moves
        #      during it; move = the source moves during every copy), `sqlite3` that says what a damaged copy says. Each case is a full pass (RS_SIG empty).
        #   a) the look at the files: two in a full pass (the sample before the copy, the stamp after it), one in a skipped cycle, nothing is read in that one
        SHIM_REAL_LS=$(command -v ls); SHIM_LS="$rpt/lscalls"; export SHIM_REAL_LS SHIM_LS
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\necho x >> "$SHIM_LS"\n"$SHIM_REAL_LS" "$@"\n' > "$rpt/bin/ls"; chmod +x "$rpt/bin/ls"
        RS_SIG=""; : > "$SHIM_LS"; cyc $((n0 + 900)); l3=$(wc -l < "$SHIM_LS" | tr -d ' '); c20=$(calls)
        : > "$SHIM_LS"; cyc $((n0 + 930)); l4=$(wc -l < "$SHIM_LS" | tr -d ' '); c21=$(calls)
        rm -f "$rpt/bin/ls"
        if [ "$l3/$c20" = 2/1 ] && [ "$l4/$c21" = 1/0 ]; then st_pass "recon copy: the files are looked at twice in a full pass (the sample, and once more after the copy) and once in a skipped cycle"; else st_fail "recon copy: looks at the files (ls $l3/$l4, sqlite3 $c20/$c21, want 2/1 and 1/0)"; fi
        #   b) cp stand-in
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\necho "$*" >> "$CP_LOG"\necho x >> "$CP_LOG.seq"\nn=$(wc -l < "$CP_LOG" | tr -d " ")\nq=$(wc -l < "$CP_LOG.seq" | tr -d " ")\n"$CP_REAL" "$@" || exit 1\ncase $CP_MODE:$n in\n    cut1:1) head -c 1500 "$1" > "$2"; touch -t "2020010100$(printf %%02d "$q")" "$1" ;;\n    move:*) touch -t "2020010100$(printf %%02d "$q")" "$1" ;;\nesac\nexit 0\n' > "$rpt/bin/cp"
        CP_REAL=$(command -v cp); chmod +x "$rpt/bin/cp"; hash -r 2>/dev/null   # (the shell remembers where it found `cp` before the stand-in was there)
        CP_LOG="$rpt/cpcalls"; CP_MODE=""; : > "$CP_LOG.seq"; export CP_REAL CP_LOG CP_MODE
        cycl() { FAKE_NOW=$1; : > "$SHIM_LOG"; RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; }
        : > "$rpt/cplog"; : > "$CP_LOG"; cycl $((n0 + 1000)); cp1=$(wc -l < "$CP_LOG" | tr -d ' ')
        if [ "$cp1" = 1 ] && json_ok < "$OUTFILE" && grep -q '"ssid": "OldAP"' "$OUTFILE" && [ ! -s "$rpt/cplog" ]; then st_pass "recon copy: a copy of a file that did not move is the only copy (one cp, nothing logged)"; else st_fail "recon copy: stable copy (cp calls $cp1, log: $(head -n 1 "$rpt/cplog"))"; fi
        CP_MODE=cut1; export CP_MODE; : > "$CP_LOG"; cycl $((n0 + 1030)); cp2=$(wc -l < "$CP_LOG" | tr -d ' ')
        if [ "$cp2" = 2 ] && json_ok < "$OUTFILE" && grep -q '"ssid": "OldAP"' "$OUTFILE" && [ ! -s "$rpt/cplog" ]; then st_pass "recon copy: a source that moved during the copy gives a second copy, and that one is read (a cut first copy is not), nothing logged"; else st_fail "recon copy: torn copy (cp calls $cp2, log: $(head -n 1 "$rpt/cplog"))"; fi
        CP_MODE=move; export CP_MODE; : > "$CP_LOG"; cycl $((n0 + 1060)); cp3=$(wc -l < "$CP_LOG" | tr -d ' '); tl1=$(grep -c 'written to while it was copied' "$rpt/cplog")
        : > "$CP_LOG"; cycl $((n0 + 1090)); tl2=$(grep -c 'written to while it was copied' "$rpt/cplog")
        CP_MODE=""; export CP_MODE; cycl $((n0 + 1120)); tl3=$(grep -c 'written to while it was copied' "$rpt/cplog")
        CP_MODE=move; export CP_MODE; cycl $((n0 + 1150)); tl4=$(grep -c 'written to while it was copied' "$rpt/cplog")
        if [ "$cp3" = 2 ] && [ "$tl1/$tl2/$tl3/$tl4" = 1/1/1/2 ] && json_ok < "$OUTFILE" && grep -q '"ssid": "OldAP"' "$OUTFILE"; then st_pass "recon copy: a source that moves during both copies is read all the same and said once per episode (twice cp, then 1, 1, 1, 2 lines over four cycles)"; else st_fail "recon copy: moving source (cp calls $cp3, lines $tl1/$tl2/$tl3/$tl4)"; fi
        CP_MODE=""; export CP_MODE
        # a copy that cannot be made twice (the second cp fails) falls back to the next place, not to a cut file
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\necho "$*" >> "$CP_LOG"\nn=$(wc -l < "$CP_LOG" | tr -d " ")\nif [ "$n" = 2 ]; then exit 1; fi\n"$CP_REAL" "$@" || exit 1\ntouch -t "2020010100$(printf %%02d "$n")" "$1"\nexit 0\n' > "$rpt/bin/cp"
        : > "$CP_LOG"; cycl $((n0 + 1180))
        if json_ok < "$OUTFILE" && grep -q '"ssid": "OldAP"' "$OUTFILE" && [ -z "$(ls "$rpt/ram")" ]; then st_pass "recon copy: a second copy that fails is dropped, the next place answers, nothing is left in the RAM directory"; else st_fail "recon copy: failing second copy ($(ls "$rpt/ram"))"; fi
        rm -f "$rpt/bin/cp"; hash -r 2>/dev/null; unset CP_REAL CP_LOG CP_MODE
        #   c) sqlite3 stand-ins (a directory of their own, first in PATH while one is wanted): a damaged copy, a status of 3, and the exit 1 of a schema that lacks a
        #      table (a healthy file says that all the time)
        sq_path=$PATH; mkdir -p "$rpt/fake"
        sqf_on() {   # sqf_on STDERR_COMMAND STATUS
            printf '#!/bin/sh\ncat > /dev/null\n%s\nexit %s\n' "$1" "$2" > "$rpt/fake/sqlite3"; chmod +x "$rpt/fake/sqlite3"; PATH="$rpt/fake:$sq_path"; hash -r 2>/dev/null
        }
        sqf_off() { PATH=$sq_path; hash -r 2>/dev/null; }
        cycl $((n0 + 1210)); cp "$OUTFILE" "$rpt/good.json"
        sqf_on 'echo "Parse error near line 1: database disk image is malformed" >&2' 1
        : > "$rpt/cplog"; FAKE_NOW=$((n0 + 1240)); RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; sg_rc1=$?
        FAKE_NOW=$((n0 + 1270)); RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; sg_rc2=$?
        if [ "$sg_rc1/$sg_rc2" = 1/1 ] && cmp -s "$OUTFILE" "$rpt/good.json" && [ "$(grep -c 'recon.db: the pass failed (the copy is malformed)' "$rpt/cplog")" = 1 ]; then
            st_pass "recon pass: sqlite3 saying the copy is malformed -> the last document stays, the cycle is reported as failed, one log line over two cycles"
        else st_fail "recon pass: malformed copy (rc $sg_rc1/$sg_rc2, same file: $(cmp -s "$OUTFILE" "$rpt/good.json" && echo yes || echo no), lines: $(grep -c 'pass failed' "$rpt/cplog"))"; fi
        if [ -z "$(ls "$rpt/ram")" ]; then st_pass "recon pass: the copy and the error file are removed after a failed pass"; else st_fail "recon pass: left in the RAM directory: $(ls "$rpt/ram")"; fi
        sqf_off; cycl $((n0 + 1300)); cp "$OUTFILE" "$rpt/good.json"
        sqf_on '' 3
        : > "$rpt/cplog"; FAKE_NOW=$((n0 + 1330)); RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; sg_rc3=$?
        if [ "$sg_rc3" = 1 ] && cmp -s "$OUTFILE" "$rpt/good.json" && grep -q 'recon.db: the pass failed (the database reader ended with status 3)' "$rpt/cplog"; then st_pass "recon pass: sqlite3 ending with a status of 2 or more (here 3) is a failed pass too"; else st_fail "recon pass: status 3 (rc $sg_rc3, $(head -n 2 "$rpt/cplog"))"; fi
        sqf_on 'echo "Parse error near line 3: no such table: ssid" >&2' 1
        : > "$rpt/cplog"; FAKE_NOW=$((n0 + 1360)); RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; sg_rc4=$?
        if [ "$sg_rc4" = 0 ] && grep -q '"source": "none"' "$OUTFILE" && ! grep -q 'pass failed' "$rpt/cplog"; then st_pass "recon pass: exit 1 on a missing table is no failed pass (the batch's own alternatives do that): no access point -> the explicit empty document, as before"; else st_fail "recon pass: missing table (rc $sg_rc4, $(head -n 2 "$rpt/cplog"))"; fi
        sqf_on 'echo "Error: file is not a database" >&2' 1
        rm -f "$OUTFILE"; : > "$rpt/cplog"; FAKE_NOW=$((n0 + 1390)); RS_SIG=""; run_cycle >/dev/null 2>>"$rpt/cplog"; sg_rc5=$?
        if [ "$sg_rc5" = 1 ] && json_ok < "$OUTFILE" && grep -q '"source": "none"' "$OUTFILE" && grep -q 'the copy is not a database' "$rpt/cplog"; then st_pass "recon pass: a failed pass with no document yet publishes the explicit empty one (and still reports failure)"; else st_fail "recon pass: nothing to keep (rc $sg_rc5)"; fi
        sqf_off; cycl $((n0 + 1420))
        if json_ok < "$OUTFILE" && grep -q '"ssid": "OldAP"' "$OUTFILE"; then st_pass "recon pass: the next good read publishes again"; else st_fail "recon pass: no recovery"; fi
        unset SHIM_REAL_LS SHIM_LS

        # ---- 3c2) the layers on the recon.db path: the frame counter of stations (STARCHORUS_TRAFFIC), hidden networks, and a skipped
        #      cycle that still carries a fresh Bluetooth layer (a window against the stand-ins of bt_selftest). A database of its own, times relative to LT.
        lt=1790000000; ldb="$tdir/recon_layers.db"
        "$rsq" "$ldb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'020000010101','Plain',0,$((lt - 100)),-50,2437,6,8);
INSERT INTO ssid VALUES (2,0,1,8,'020000010102','Garden',1,$((lt - 90)),-55,2412,1,8);
INSERT INTO ssid VALUES (3,0,1,8,'020000010103','Orchard',1,$((lt - 80)),-60,2412,1,8);
INSERT INTO ssid VALUES (4,0,1,5,'020000010103','Orchard',0,$((lt - 70)),-40,2412,1,8);
INSERT INTO ssid VALUES (5,0,1,8,'020000010104','Meadow',1,$((lt - 100)),-50,2412,1,8);
INSERT INTO ssid VALUES (6,0,1,8,'020000010104','Meadow',0,$((lt - 60)),-52,2412,1,8);
INSERT INTO ssid VALUES (7,0,1,8,'020000010105','',1,$((lt - 50)),-70,2412,1,8);
INSERT INTO ssid VALUES (8,0,1,8,'020000010106','  Pad  ',1,$((lt - 40)),-71,2412,1,8);
INSERT INTO ssid VALUES (10,501,1,4,'FFFFFFFFFFFF','Q',0,$((lt - 1000)),-60,0,0,0);
INSERT INTO wifi_device VALUES (501,1,'020000020201',$((lt - 1000)),-60,0,9999);
INSERT INTO ssid VALUES (11,502,2,4,'FFFFFFFFFFFF','Q',0,$((lt - 10)),-60,0,0,0);
INSERT INTO wifi_device VALUES (502,2,'020000020201',$((lt - 10)),-60,0,40);
INSERT INTO ssid VALUES (12,503,1,4,'FFFFFFFFFFFF','R',0,$((lt - 1000)),-70,0,0,0);
INSERT INTO wifi_device VALUES (503,1,'020000020202',$((lt - 1000)),-70,0,777);
INSERT INTO ssid VALUES (13,504,2,4,'FFFFFFFFFFFF','S',0,$((lt - 5)),-65,0,0,0);
INSERT INTO wifi_device VALUES (504,2,'020000020203',$((lt - 5)),-65,0,0);
SQL
        RECON_DB="$ldb"; HAS_TIME=""; RDB_PATH=""; MAX_AGE=0; : > "$SHIM_LOG"
        TRAFFIC=1; build_from_recondb $lt > "$rpt/lp1.json" 2>/dev/null; lp_c1=$(calls); TRAFFIC=0
        build_from_recondb $lt > "$rpt/lp0.json" 2>/dev/null
        if [ "$lp_c1" = 1 ] && json_ok < "$rpt/lp1.json" \
           && grep -q '"mac": "02:00:00:02:02:01", "rssi": -60, "last_seen": 1789999990, "packets": 40, "probes": \["Q"\]}' "$rpt/lp1.json" \
           && ! grep '02:00:00:02:02:02' "$rpt/lp1.json" | grep -q packets && grep -q '"mac": "02:00:00:02:02:03".*"packets": 0' "$rpt/lp1.json"; then
            st_pass "station packets: STARCHORUS_TRAFFIC=1 takes the counter of the rows heard in the last 300 s (the newer session's 40, not the old session's 9999), none for a station not heard for five minutes, a zero counter is 0, one query batch"
        else st_fail "station packets: [$(grep '"mac"' "$rpt/lp1.json" | head -n 4)]"; fi
        if ! grep -q packets "$rpt/lp0.json" && json_ok < "$rpt/lp0.json"; then st_pass "station packets: with STARCHORUS_TRAFFIC=0 no station has a packets field"; else st_fail "station packets: field written with Traffic off"; fi
        # a firmware whose wifi_device has no packets (or time) column: the CLI1 alternative claims the group, stations without the counter
        npdb="$tdir/recon_nopk.db"
        "$rsq" "$npdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB, hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, signal INT);
INSERT INTO ssid VALUES (1,0,1,8,'020000030101','OnlyAP',0,$((lt - 100)),-50,2437,6,8);
INSERT INTO ssid VALUES (2,601,1,4,'FFFFFFFFFFFF','Q',0,$((lt - 10)),-60,0,0,0);
INSERT INTO wifi_device VALUES (601,1,'020000020301',-60);
SQL
        RECON_DB="$npdb"; HAS_TIME=""; RDB_PATH=""; TRAFFIC=1; build_from_recondb $lt > "$rpt/lp2.json" 2>/dev/null; TRAFFIC=0
        if grep -q '"mac": "02:00:00:02:03:01"' "$rpt/lp2.json" && ! grep -q packets "$rpt/lp2.json" && json_ok < "$rpt/lp2.json"; then st_pass "station packets: a schema without wifi_device.packets or .time -> CLI1 claims the group, the stations come without the counter"; else st_fail "station packets: schema without packets ($(grep '"mac"' "$rpt/lp2.json"))"; fi
        # hidden networks: ssid stays "" whatever name the row holds (the 0.1 convention; on the device a hidden beacon holds zero bytes only, device-notes 4a); the NEWEST beacon decides
        RECON_DB="$ldb"; HAS_TIME=""; RDB_PATH=""
        lp_row() { grep "\"bssid\": \"$1\"" "$2"; }
        if lp_row 02:00:00:01:01:02 "$rpt/lp0.json" | grep -q '"ssid": "", "channel": 1, "band": "2.4GHz", "freq": 2412, "rssi": -55, "security": "WPA2", "last_seen": 1789999910' \
           && lp_row 02:00:00:01:01:01 "$rpt/lp0.json" | grep -q '"ssid": "Plain"' && ! grep -q -e Garden -e Orchard -e Pad -e ssid_recorded "$rpt/lp0.json"; then
            st_pass "hidden networks: a hidden beacon row gives ssid \"\" whatever name the row holds (no other field carries it); a plain network keeps its name"
        else st_fail "hidden networks: [$(lp_row 02:00:00:01:01:02 "$rpt/lp0.json")]"; fi
        if lp_row 02:00:00:01:01:03 "$rpt/lp0.json" | grep -q '"ssid": "",'; then st_pass "hidden networks: a stronger probe response of the same BSSID does not make a hidden network named (the newest beacon decides)"; else st_fail "hidden networks: probe response row [$(lp_row 02:00:00:01:01:03 "$rpt/lp0.json")]"; fi
        if lp_row 02:00:00:01:01:04 "$rpt/lp0.json" | grep -q '"ssid": "Meadow"'; then st_pass "hidden networks: a newer non-hidden beacon row of a network that hid before -> named"; else st_fail "hidden networks: network that stopped hiding [$(lp_row 02:00:00:01:01:04 "$rpt/lp0.json")]"; fi
        if lp_row 02:00:00:01:01:05 "$rpt/lp0.json" | grep -q '"ssid": ""' && lp_row 02:00:00:01:01:06 "$rpt/lp0.json" | grep -q '"ssid": ""'; then st_pass "hidden networks: a hidden beacon with an empty name and one with a blank-padded name both give ssid \"\""; else st_fail "hidden networks: empty/padded [$(lp_row 02:00:00:01:01:05 "$rpt/lp0.json")] [$(lp_row 02:00:00:01:01:06 "$rpt/lp0.json")]"; fi
        printf '%s\n' "$(cat "$rpt/lp1.json")" > "$rpt/lp1b.json"; lay_check "recon.db document with packets" "$rpt/lp1b.json"
        unset -f lp_row
        # a skipped cycle still carries a fresh Bluetooth layer: the base document is the kept one, the window is new (against the stand-ins of bt_selftest)
        bt_env on; cp "$BTS/in/win.txt" "$BTS/cfg/M.text"; printf 'parent\n' > "$BTS/cfg/T.mode"
        RECON_DB="$kdb"; HAS_TIME=""; RDB_PATH=""; RS_SIG=""; RS_SKIPS=0; MAX_AGE=0; SKIP_MAX=20; OUTFILE="$rpt/skipbt.json"; rm -f "$OUTFILE"; BT_HELD=""; BLUETOOTH=1
        cyc $((n0 + 1000)); k1=$(calls); cp "$OUTFILE" "$rpt/k1.json"
        cyc $((n0 + 1030)); k2=$(calls); cp "$OUTFILE" "$rpt/k2.json"
        lp_strip() { grep -v '"generated"' "$1" | grep -v '^  "bluetooth"' | sed 's/, "bt_window": [0-9]*, "bt_hold": [0-9]*//'; }
        lp_strip "$rpt/k1.json" > "$rpt/k1.body"; lp_strip "$rpt/k2.json" > "$rpt/k2.body"
        if [ "$k1/$k2" = 1/0 ] && [ "$RS_SKIPS" = 1 ] && grep -q '"generated": '$((n0 + 1030))',' "$rpt/k2.json" && cmp -s "$rpt/k1.body" "$rpt/k2.body" && json_ok < "$rpt/k2.json" \
           && grep -q '^  "bluetooth": \[{"addr": "02:00:00:00:00:02", "addr_type": "random-resolvable", "rssi": -49, "reports": 2, "last_seen": '$((n0 + 1030))',' "$rpt/k2.json" \
           && grep -q '"bt_window": 1, "bt_hold": 120' "$rpt/k2.json" && grep -q '"ssid": "OldAP"' "$rpt/k2.json"; then
            st_pass "skip with layers: nothing changed in recon.db, Bluetooth on -> the sqlite3 shim sees no call, the published document has the new generated, a bluetooth line of this cycle's window, and otherwise the kept bytes"
        else st_fail "skip with layers (calls $k1/$k2, skips $RS_SKIPS, [$(grep '^  "bluetooth"' "$rpt/k2.json" | cut -c1-160)])"; fi
        bts_idle "skip path"
        # 22 quiet cycles with Bluetooth on (another collector's window makes each one a void window, which costs no time): the skip counter is not reset by a skip, so SKIP_MAX trips
        bts_reap; bts_other
        RS_SIG=""; RS_SKIPS=0; lp_seq=""; lp_i=1
        while [ "$lp_i" -le 22 ]; do cyc $((n0 + 1100 + 30 * lp_i)); lp_seq="$lp_seq$(calls)"; lp_i=$((lp_i + 1)); done
        if [ "$lp_seq" = "$(printf '1%020d1' 0)" ] && grep -q '^  "bluetooth": \[' "$OUTFILE" && grep -q '"bt_window": 0' "$OUTFILE" && json_ok < "$OUTFILE"; then
            st_pass "skip with layers: 22 quiet cycles with Bluetooth on -> a full pass, 20 skipped cycles, then SKIP_MAX forces the next full pass; every document carries the layer (void window: held records, bt_window 0)"
        else st_fail "skip with layers: sqlite3 calls per cycle [$lp_seq]"; fi
        bts_other_end; BLUETOOTH=0; bt_env off; unset -f lp_strip
        TRAFFIC=0; RECON_DB="$kdb"; HAS_TIME=""; RDB_PATH=""; RS_SIG=""; MAX_AGE=0; OUTFILE="$rpt/skip.json"

        # ---- 3d) the opt-in source `pineap`: a stub of the AP service command line prints fixture JSON (placeholders only). The parser must carry
        #      SSIDs with any character, pick the strongest beacon/response record, keep stations apart from APs, apply the window, take the
        #      security from recon.db rarely (one sqlite3 process per lookup) and never run a command that is not one of the two listed.
        ppt="$tdir/pn"; mkdir -p "$ppt/ram"; pt0=1710000000
        pl_of() { printf '%s\n' "$1" | grep -- "$2" | head -1; }
        printf '[{"mac": "AA:BB:CC:00:00:01", "freq": 2437, "signal": -48, "packets": 9, "time": %s, "beacon": {"1111": {"ssid": "HomeNet", "ssidlen": 7, "channel": 6, "freq": 2437, "signal": -50, "count": 10, "time": %s, "hidden": false}, "2222": {"ssid": "Guest", "ssidlen": 5, "channel": 6, "freq": 2437, "signal": -40, "count": 3, "time": %s, "hidden": false}}, "response": {"3333": {"ssid": "RespA", "ssidlen": 5, "channel": 6, "freq": 2437, "signal": -60, "count": 1, "time": %s}, "3334": {"ssid": "RespB", "ssidlen": 5, "channel": 6, "freq": 2437, "signal": -61, "count": 1, "time": %s}}}, {"mac": "AA:BB:CC:00:00:02", "freq": 5180, "signal": -70, "packets": 2, "time": %s, "beacon": {"4444": {"ssid": "", "ssidlen": 0, "channel": 36, "freq": 5180, "signal": -70, "count": 4, "time": %s, "hidden": true}}}, {"time": %s, "signal": -66.5, "freq": 5955, "packets": 1, "mac": "02:bb:cc:00:00:03", "beacon": {"5555": {"count": 2, "time": %s, "signal": -66.5, "freq": 5955, "channel": 1, "ssidlen": 30, "ssid": "Caf\\u00e9 \\"Q\\" \\\\ x\\ty\\u0001z\\n", "hidden": false}}}, {"mac": "AA:BB:CC:00:00:04", "freq": 2412, "signal": -80, "packets": 1, "time": %s, "beacon": {"6666": {"ssid": "Gone", "ssidlen": 4, "channel": 1, "freq": 2412, "signal": -80, "count": 1, "time": %s, "hidden": false}}}]\n' \
            $((pt0 - 10)) $((pt0 - 10)) $((pt0 - 12)) $((pt0 - 20)) $((pt0 - 22)) $((pt0 - 30)) $((pt0 - 30)) $((pt0 - 40)) $((pt0 - 40)) $((pt0 - 7200)) $((pt0 - 7200)) > "$ppt/aps.json"
        { printf '[\n'
          cat "$ppt/aps.json" | sed -e '1s/^\[//' -e '$s/\]$//' | sed -e 's/$/,/'
          printf '  {"mac": "10:22:33:44:55:66", "freq": 2412, "signal": -55, "packets": 5, "time": %s,\n    "probe": {"9001": {"ssid": "FreeWifi", "ssidlen": 8, "channel": 1, "freq": 2412, "signal": -55, "count": 2, "time": %s},\n      "9002": {"ssid": "", "ssidlen": 0, "channel": 1, "freq": 2412, "signal": -55, "count": 1, "time": %s},\n      "9003": {"ssid": "Home\\"Net", "ssidlen": 8, "channel": 1, "freq": 2412, "signal": -55, "count": 1, "time": %s}}},\n' $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 6))
          printf '  {"mac": "9A:88:77:66:55:44", "freq": 2437, "signal": -80, "packets": 1, "time": %s, "probe": {' $((pt0 - 8))
          i=1; while [ "$i" -le 10 ]; do printf '%s"%s": {"ssid": "P%02d", "ssidlen": 3, "channel": 6, "freq": 2437, "signal": -80, "count": 1, "time": %s}' "$([ "$i" -gt 1 ] && printf ', ')" $((8000 + i)) $((11 - i)) $((pt0 - 8)); i=$((i + 1)); done
          printf '}},\n  {"mac": "10:22:33:44:55:77", "freq": 2412, "signal": -90, "packets": 1, "time": %s, "probe": {"9100": {"ssid": "Old", "ssidlen": 3, "channel": 1, "freq": 2412, "signal": -90, "count": 1, "time": %s}}},\n  {"mac": "not-a-mac", "time": %s}\n]\n' $((pt0 - 7200)) $((pt0 - 7200)) $((pt0 - 1))
        } > "$ppt/dev.json"
        apcli_stub "$ppt/bin" "$ppt/log" "$ppt/aps.json" "$ppt/dev.json"
        p_path2=$PATH; p_flag2=$APCLI_RO; p_tmp2=$TMPDIR_RAM; p_db2=$RECON_DB; p_age2=$MAX_AGE; p_calls2=$PINEAP_CALLS
        # unless the environment says otherwise the source makes the ONE bounded call (every device of the AP service's session would be parsed otherwise)
        if [ "$PINEAP_CALLS" = recent ] || [ -n "${STARCHORUS_PINEAP_CALLS:-}" ]; then st_pass "pineap: the default is the one bounded call (recent)"; else st_fail "pineap: default calls $PINEAP_CALLS"; fi
        PINEAP_CALLS=full      # the fixtures below are written for the two full lists; "recent" is tested on its own further down
        PATH="$ppt/bin:$PATH"; APCLI_RO=1; TMPDIR_RAM="$ppt/ram"; RECON_DB="$tdir/none-such.db"; RDB_PATH=""; MAX_AGE=0; PSEC_T=0; rm -f "$ppt/ram/starchorus-sec.txt"
        : > "$ppt/log"
        # pnb BINDIR TS: one cycle's document into $pn (no command substitution around the build: its state, PSEC_T, must survive)
        : > "$ppt/e.log"
        pnb() { PATH="$1:$p_path2"; build_from_apcli "$2" > "$ppt/o.json" 2>>"$ppt/e.log"; pnrc=$?; PATH=$p_path2; pn=$(cat "$ppt/o.json"); }
        pnb "$ppt/bin" $pt0
        if [ "$pnrc" = 0 ] && printf '%s\n' "$pn" | json_ok; then st_pass "pineap: valid JSON from RECON APS + RECON DEVICES fixtures"; else st_fail "pineap: document (rc $pnrc)"; fi
        printf '%s\n' "$pn" > "$ppt/emit.json"; lay_check "pineap document" "$ppt/emit.json"
        if [ "$(cat "$ppt/log")" = "RECON APS format=json
RECON DEVICES format=json" ]; then st_pass "pineap: exactly the two read-only list commands were run, once each"; else st_fail "pineap: commands [$(cat "$ppt/log")]"; fi
        check   "pineap: source label"                     "$pn" '"source": "pineap"'
        checkf  "pineap: strongest beacon record names the AP, hidden=false kept, last_seen = time" "$(pl_of "$pn" 'aa:bb:cc:00:00:01')" '"ssid": "Guest", "channel": 6, "band": "2.4GHz", "freq": 2437, "rssi": -48, "security": "Unknown", "last_seen": 1709999990, "responded_ssids": 2'
        checkf  "pineap: hidden beacon -> empty SSID, 5 GHz from freq" "$(pl_of "$pn" 'aa:bb:cc:00:00:02')" '"ssid": "", "channel": 36, "band": "5GHz", "freq": 5180, "rssi": -70'
        checkf  "pineap: escapes kept (unicode escape, quote, backslash), tab -> space, control escapes dropped, float signal rounded, 6 GHz" "$(pl_of "$pn" '02:bb:cc:00:00:03')" '"ssid": "Caf\u00e9 \"Q\" \\ x yz ", "channel": 1, "band": "6GHz", "freq": 5955, "rssi": -67'
        checkf  "pineap: a station keeps its probed SSIDs (distinct, sorted, wildcard dropped, escaped quote kept)" "$(pl_of "$pn" '10:22:33:44:55:66')" '"rssi": -55, "last_seen": 1709999995, "probes": ["FreeWifi", "Home\"Net"]'
        checkf  "pineap: at most 8 probed SSIDs, sorted" "$(pl_of "$pn" '9a:88:77:66:55:44')" '"probes": ["P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08"]'
        if [ "$(printf '%s\n' "$pn" | grep -c '"mac": "aa:bb:cc')" = 0 ] && ! printf '%s\n' "$pn" | grep -q 'not-a-mac'; then st_pass "pineap: APs are not listed as stations, an entry without a MAC is dropped"; else st_fail "pineap: AP/station split"; fi
        pnl=$(printf '%s\n' "$pn" | grep -c '"bssid"'); pnc=$(printf '%s\n' "$pn" | grep -c '"mac"')
        if [ "$pnl/$pnc" = 4/3 ]; then st_pass "pineap: 4 APs, 3 stations without a window"; else st_fail "pineap: counts $pnl/$pnc"; fi
        # no AP carries an empty or a missing security: the page and the Overview both read a missing field as Open (an unresolved one is "Unknown")
        if [ "$pnl" = "$(printf '%s\n' "$pn" | grep -c '"security": "[^"]')" ] && ! printf '%s\n' "$pn" | grep -q '"security": ""'; then st_pass "pineap: every AP carries a non-empty security (Unknown until recon.db names it, never empty or absent)"; else st_fail "pineap: security field missing or empty"; fi
        MAX_AGE=3600; pnb "$ppt/bin" $pt0; MAX_AGE=0
        pnl=$(printf '%s\n' "$pn" | grep -c '"bssid"'); pnc=$(printf '%s\n' "$pn" | grep -c '"mac"')
        if [ "$pnl/$pnc" = 3/2 ] && ! printf '%s\n' "$pn" | grep -q 'Gone'; then st_pass "pineap: STARCHORUS_MAX_AGE applies to time (the AP and the station from 2 h ago are gone)"; else st_fail "pineap: window counts $pnl/$pnc"; fi
        # a hidden beacon: ssid stays empty (the 0.1 convention), whatever name its record holds
        printf '[{"mac": "AA:BB:CC:00:00:51", "freq": 2412, "signal": -50, "time": %s, "beacon": {"1": {"ssid": "Garden", "channel": 1, "freq": 2412, "signal": -50, "time": %s, "hidden": true}}},\n {"mac": "AA:BB:CC:00:00:52", "freq": 2412, "signal": -60, "time": %s, "beacon": {"2": {"ssid": "  Pad  ", "channel": 1, "freq": 2412, "signal": -60, "time": %s, "hidden": true}}},\n {"mac": "AA:BB:CC:00:00:53", "freq": 2412, "signal": -61, "time": %s, "beacon": {"3": {"ssid": "", "channel": 1, "freq": 2412, "signal": -61, "time": %s, "hidden": true}}},\n {"mac": "AA:BB:CC:00:00:54", "freq": 2412, "signal": -62, "time": %s, "beacon": {"4": {"ssid": "Open", "channel": 1, "freq": 2412, "signal": -62, "time": %s, "hidden": false}}}]\n' \
            $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) $((pt0 - 5)) > "$ppt/aps12.json"
        printf '[]\n' > "$ppt/dev12.json"; apcli_stub "$ppt/bin12" "$ppt/log12" "$ppt/aps12.json" "$ppt/dev12.json"
        pnb "$ppt/bin12" $pt0; pn12=$pn
        if [ "$(pl_of "$pn12" 'aa:bb:cc:00:00:51' | grep -c '"ssid": ""')" = 1 ] && pl_of "$pn12" 'aa:bb:cc:00:00:52' | grep -q '"ssid": ""' && pl_of "$pn12" 'aa:bb:cc:00:00:53' | grep -q '"ssid": ""' \
           && pl_of "$pn12" 'aa:bb:cc:00:00:54' | grep -q '"ssid": "Open"' && ! printf '%s\n' "$pn12" | grep -q -e Garden -e Pad -e ssid_recorded && printf '%s\n' "$pn12" | json_ok; then
            st_pass "pineap: a hidden beacon gives ssid \"\" whatever name its record holds (no other field carries it); a plain network keeps its name"
        else st_fail "pineap: hidden beacon [$(pl_of "$pn12" 'aa:bb:cc:00:00:51')]"; fi
        # the same lists, pretty-printed and with the key order reversed in one object: the tokeniser does not care about layout
        sed -e 's/, "/,\
 "/g' "$ppt/aps.json" > "$ppt/aps2.json"; apcli_stub "$ppt/bin2" "$ppt/log2" "$ppt/aps2.json" "$ppt/dev.json"
        pnb "$ppt/bin2" $pt0; pn2=$pn
        if [ "$(printf '%s\n' "$pn2" | grep -c '"bssid"')" = 4 ] && printf '%s\n' "$pn2" | json_ok; then st_pass "pineap: a differently laid-out list gives the same APs"; else st_fail "pineap: layout"; fi
        # failures: no JSON array from RECON APS -> no document; a bad RECON DEVICES -> APs only
        printf 'error: not running\n' > "$ppt/aps3.json"; apcli_stub "$ppt/bin3" "$ppt/log3" "$ppt/aps3.json" "$ppt/dev.json"
        pnb "$ppt/bin3" $pt0
        if [ "$pnrc" != 0 ]; then st_pass "pineap: no JSON from RECON APS -> no document (the cycle publishes the explicit empty one)"; else st_fail "pineap: garbage accepted"; fi
        printf '%s\n' '[]' > "$ppt/aps4.json"; apcli_stub "$ppt/bin4" "$ppt/log4" "$ppt/aps4.json" "$ppt/aps3.json"
        pnb "$ppt/bin4" $pt0; pn4=$pn
        if [ "$pnrc" = 2 ] && [ -z "$pn4" ]; then st_pass "pineap: an empty AP list is no answer (rc 2: run_cycle falls back to recon.db)"; else st_fail "pineap: empty lists (rc $pnrc)"; fi
        # "recent": one bounded RECON DEVICES, no RECON APS; the APs come from the beacon records, the document is the same
        : > "$ppt/log"; PINEAP_CALLS=recent; pnb "$ppt/bin" $pt0; pnr=$pn; PINEAP_CALLS=full
        if [ "$(cat "$ppt/log")" = "RECON DEVICES format=json bytime=true limit=400" ] && printf '%s\n' "$pnr" | json_ok \
           && [ "$(printf '%s\n' "$pnr" | grep -c '"bssid"')" = 4 ] && [ "$(printf '%s\n' "$pnr" | grep -c '"mac"')" = 3 ]; then
            st_pass "pineap recent: one bounded RECON DEVICES call, the same 4 APs and 3 stations without RECON APS"
        else st_fail "pineap recent: [$(cat "$ppt/log")]"; fi
        printf 'error\n' > "$ppt/dev9.json"; apcli_stub "$ppt/bin9" "$ppt/log9" "$ppt/aps.json" "$ppt/dev9.json"
        PINEAP_CALLS=recent; pnb "$ppt/bin9" $pt0; PINEAP_CALLS=full
        if [ "$pnrc" != 0 ]; then st_pass "pineap recent: no JSON array from the one call -> no document"; else st_fail "pineap recent: garbage accepted"; fi
        # security from recon.db: ONE query for unknown BSSIDs, none while nothing is new, one retry for BSSIDs the database did not know
        sqlite3 "$tdir/recon_pn.db" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
INSERT INTO ssid VALUES (1,0,1,8,'AABBCC000001','Guest',0,0,-40,2437,6,17184063752);
INSERT INTO ssid VALUES (2,0,1,8,'02BBCC000003','x',0,0,-66,5955,1,6597073961232);
SQL
        RECON_DB="$tdir/recon_pn.db"; RDB_PATH=""; PSEC_T=0; rm -f "$ppt/ram/starchorus-sec.txt"; : > "$SHIM_LOG"
        pnb "$ppt/bin" $pt0; pc1=$(calls)
        checkf  "pineap: security (and akm/cipher) of a known BSSID from recon.db"  "$(pl_of "$pn" 'aa:bb:cc:00:00:01')" '"security": "WPA2", "last_seen": 1709999990, "akm": ["psk"], "cipher": {"group": "ccmp128", "pairwise": ["ccmp128"]}, "responded_ssids": 2'
        checkf  "pineap: SAE from recon.db is WPA3" "$(pl_of "$pn" '02:bb:cc:00:00:03')" '"security": "WPA3"'
        checkf  "pineap: a BSSID the database does not know stays Unknown" "$(pl_of "$pn" 'aa:bb:cc:00:00:02')" '"security": "Unknown"'
        pnb "$ppt/bin" $((pt0 + 30)); pc2=$(calls)
        pnb "$ppt/bin" $((pt0 + 700)); pc3=$(calls)
        if [ "$pc1" = 1 ] && [ "$pc2" = 1 ] && [ "$pc3" = 2 ]; then st_pass "pineap: one sqlite3 process for the first lookup, none while nothing is new, one retry after 10 minutes"; else st_fail "pineap: lookups $pc1/$pc2/$pc3 (want 1/1/2)"; fi
        # an unknown BSSID appears: at most every 60 s
        sed -e 's/AA:BB:CC:00:00:04/AA:BB:CC:00:00:09/g' "$ppt/aps.json" > "$ppt/aps5.json"; apcli_stub "$ppt/bin5" "$ppt/log5" "$ppt/aps5.json" "$ppt/dev.json"
        c0=$(calls); pnb "$ppt/bin5" $((pt0 + 710)); c1=$(calls)
        pnb "$ppt/bin5" $((pt0 + 780)); c2=$(calls)
        if [ "$c1" = "$c0" ] && [ "$c2" -gt "$c1" ]; then st_pass "pineap: a new BSSID is looked up at most once a minute"; else st_fail "pineap: new BSSID lookups $c0/$c1/$c2"; fi
        if grep -q -- '-readonly -noheader -bail ' "$SHIM_LOG"; then st_pass "pineap: the lookup runs sqlite3 read-only with -bail (its closing marker row proves the query ran to the end)"; else st_fail "pineap: lookup flags ($(tail -n 1 "$SHIM_LOG"))"; fi
        # a lookup that fails (torn copy, locked file: a stand-in sqlite3 that prints nothing and exits 1) is no answer: the labels known so far stay, nothing turns into
        # "the database does not know it", and the next lookup is not held off for 10 minutes
        sed -e 's/AA:BB:CC:00:00:04/AA:BB:CC:00:00:0A/g' "$ppt/aps.json" > "$ppt/aps8.json"; apcli_stub "$ppt/bin8" "$ppt/log8" "$ppt/aps8.json" "$ppt/dev.json"
        printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "$ppt/bin8/sqlite3"; chmod +x "$ppt/bin8/sqlite3"
        pnb "$ppt/bin8" $((pt0 + 860)); pn8=$pn
        checkf  "pineap: a failed lookup keeps the label already known (WPA2 stays)" "$(pl_of "$pn8" 'aa:bb:cc:00:00:01')" '"security": "WPA2"'
        checkf  "pineap: the new BSSID is Unknown until a lookup answers" "$(pl_of "$pn8" 'aa:bb:cc:00:00:0a')" '"security": "Unknown"'
        pnb "$ppt/bin8" $((pt0 + 930)); pn8=$pn
        checkf  "pineap: after a second failed lookup the old label is still there" "$(pl_of "$pn8" 'aa:bb:cc:00:00:01')" '"security": "WPA2"'
        if [ "$PSEC_FAIL" = 1 ] && [ "$(grep -c 'security lookup in recon.db gave no answer' "$ppt/e.log")" = 1 ]; then st_pass "pineap: a failed lookup is remembered, and logged once per episode"; else st_fail "pineap: PSEC_FAIL=$PSEC_FAIL, log [$(cat "$ppt/e.log")]"; fi
        # the database learns the new BSSID; the same command line, sqlite3 answering again: one lookup a minute later, the new label in, the old one kept
        "$rsq" "$tdir/recon_pn.db" "INSERT INTO ssid VALUES (3,0,1,8,'AABBCC00000A','New',0,0,-40,2437,6,17184063752);" >/dev/null 2>&1
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$rsq" > "$ppt/bin8/sqlite3"
        pnb "$ppt/bin8" $((pt0 + 1000))
        checkf  "pineap: the lookup that answers resolves the new BSSID" "$(pl_of "$pn" 'aa:bb:cc:00:00:0a')" '"security": "WPA2"'
        checkf  "pineap: ... and the old label is the same" "$(pl_of "$pn" 'aa:bb:cc:00:00:01')" '"security": "WPA2"'
        if [ "$PSEC_FAIL" = 0 ]; then st_pass "pineap: a lookup that answers ends the failure episode"; else st_fail "pineap: PSEC_FAIL=$PSEC_FAIL after an answer"; fi
        # a clock set back: the refresh timer (PSEC_T) lies in the future; a new BSSID is looked up anyway
        sed -e 's/AA:BB:CC:00:00:04/AA:BB:CC:00:00:0B/g' "$ppt/aps.json" > "$ppt/aps10.json"; apcli_stub "$ppt/bin10" "$ppt/log10" "$ppt/aps10.json" "$ppt/dev.json"
        PSEC_T=$((pt0 + 90000)); c0=$(calls); pnb "$ppt/bin10" $((pt0 + 1010)); c1=$(calls)
        if [ "$c1" -gt "$c0" ] && [ "$PSEC_T" = $((pt0 + 1010)) ]; then st_pass "pineap: a clock set back does not hold the lookups off (it counts as due)"; else st_fail "pineap: clock back (lookups $c0 -> $c1, PSEC_T $PSEC_T)"; fi
        # ---- 3e) pineap on firmware 2.0: the AP security straight from the beacon JSON `encryption` bitmask, with no recon.db lookup. The field is
        #      the full libwifi uint64 (class bits low, AKM/cipher/auth high); encfields reads it from the decimal string, so awk never rounds it at 2^53.
        et3=$((pt0 - 5))
        printf '[{"mac": "02:00:00:00:00:11", "freq": 2437, "signal": -48, "time": %s, "beacon": {"1": {"ssid": "EncWPA2", "channel": 6, "freq": 2437, "signal": -50, "time": %s, "hidden": false, "encryption": 17184063752, "encryption_str": "[WPA2-PSK-CCMP128]"}}}, {"mac": "02:00:00:00:00:12", "freq": 2437, "signal": -55, "time": %s, "beacon": {"2": {"ssid": "EncWPA3", "channel": 6, "freq": 2437, "signal": -70, "time": %s, "hidden": false, "encryption": 2199027450128}}, "response": {"3": {"ssid": "EncWPA3", "channel": 6, "freq": 2437, "signal": -40, "time": %s}}}, {"mac": "02:00:00:00:00:13", "freq": 2437, "signal": -60, "time": %s, "beacon": {"4": {"ssid": "NoEnc", "channel": 6, "freq": 2437, "signal": -60, "time": %s, "hidden": false}}}, {"mac": "02:00:00:00:00:14", "freq": 2437, "signal": -52, "time": %s, "beacon": {"5": {"ssid": "EncHigh", "channel": 6, "freq": 2437, "signal": -52, "time": %s, "hidden": false, "encryption": 144115188075855880}}}]\n' \
            "$et3" "$et3" "$et3" "$et3" "$et3" "$et3" "$et3" "$et3" "$et3" > "$ppt/enc_aps.json"
        { clean_ctrl < "$ppt/enc_aps.json" | json_tokens; printf '#STARCHORUS_DEVICES#\n'; printf '[]\n' | json_tokens; } \
          | awk -v ts="$pt0" -v center="This device" -v src=pineap -v cut=0 -v need=1 "$AWK_JSON_HELPERS$AWK_SEC$AWK_PINEAP" > "$ppt/enc.json" 2>"$ppt/enc.err"
        if json_ok < "$ppt/enc.json"; then st_pass "pineap 2.0: valid JSON from beacon records that carry encryption"; else st_fail "pineap 2.0: document [$(cat "$ppt/enc.err")]"; fi
        checkf  "pineap 2.0: a WPA2 beacon takes its security and akm/cipher from the JSON, with no recon.db at all" "$(pl_of "$(cat "$ppt/enc.json")" '02:00:00:00:00:11')" '"security": "WPA2", "last_seen": '"$et3"', "akm": ["psk"], "cipher": {"group": "ccmp128", "pairwise": ["ccmp128"]}'
        checkf  "pineap 2.0: a response wins the record but a weaker beacon carries encryption, so WPA3 comes from the beacon (the latch)" "$(pl_of "$(cat "$ppt/enc.json")" '02:00:00:00:00:12')" '"security": "WPA3", "last_seen": '"$et3"', "akm": ["sae"]'
        checkf  "pineap 2.0: a beacon with no encryption keeps the old path (no cache here, so Unknown)" "$(pl_of "$(cat "$ppt/enc.json")" '02:00:00:00:00:13')" '"security": "Unknown"'
        checkf  "pineap 2.0: a bitmask above 2^53 is read exactly (WPA3/WPA2 with the SAE auth bit), where double-precision awk would round" "$(pl_of "$(cat "$ppt/enc.json")" '02:00:00:00:00:14')" '"security": "WPA3/WPA2", "last_seen": '"$et3"', "auth": ["sae"]'
        # a crowd: 120 APs and 400 stations in scrambled order come out sorted by MAC, every one of them there
        awk 'BEGIN{ n=401; printf "["
            for(i=0;i<120;i++){ v=(i*53)%131; printf "%s{\"mac\": \"%s\", \"freq\": 2437, \"signal\": -%d, \"time\": %d, \"beacon\": {\"%d\": {\"ssid\": \"Crowd%d\", \"channel\": 6, \"freq\": 2437, \"signal\": -%d, \"time\": %d, \"hidden\": false}}}", (i?",":""), sprintf("02:aa:00:00:%02x:%02x", int(v/256), v%256), 40+i%40, '$pt0' - 5, i, i, 40+i%40, '$pt0' - 5 }
            printf "]\n" }' > "$ppt/aps11.json"
        awk 'BEGIN{ n=401; printf "["
            for(i=0;i<n;i++){ v=(i*389)%n; printf "%s{\"mac\": \"%s\", \"freq\": 2412, \"signal\": -60, \"time\": %d, \"probe\": {\"%d\": {\"ssid\": \"Q%d\", \"channel\": 1, \"freq\": 2412, \"signal\": -60, \"time\": %d}}}", (i?",":""), sprintf("10:bb:00:00:%02x:%02x", int(v/256), v%256), '$pt0' - 5, i, i, '$pt0' - 5 }
            printf "]\n" }' > "$ppt/dev11.json"
        apcli_stub "$ppt/bin11" "$ppt/log11" "$ppt/aps11.json" "$ppt/dev11.json"
        pnb "$ppt/bin11" $((pt0 + 1100))
        pnl=$(printf '%s\n' "$pn" | grep -c '"bssid"'); pnc=$(printf '%s\n' "$pn" | grep -c '"mac"')
        if [ "$pnl/$pnc" = 120/401 ] && printf '%s\n' "$pn" | sed -n 's/^ *{"bssid": "\([^"]*\)".*/\1/p' | sort -c 2>/dev/null \
           && printf '%s\n' "$pn" | sed -n 's/^ *{"mac": "\([^"]*\)".*/\1/p' | sort -c 2>/dev/null && printf '%s\n' "$pn" | json_ok; then
            st_pass "pineap: 120 APs and 401 stations in scrambled order are all there, each list sorted by MAC"
        else st_fail "pineap: crowd ($pnl APs, $pnc stations, rc $pnrc)"; fi
        # STARCHORUS_SOURCE=pineap is the opt-in for the two commands, and needs the command line to exist
        # absent = a PATH with nothing in it (everything resolve_source needs is a shell builtin): the device has the real command line on PATH
        mkdir -p "$ppt/nobin"
        # shellcheck disable=SC2123  # PATH is replaced on purpose
        PATH="$ppt/nobin"; r_src=$SOURCE; SOURCE=pineap; APCLI_RO=0; RESOLVED=x
        resolve_source 2>/dev/null; rs1=$RESOLVED
        PATH="$ppt/bin:$p_path2"; APCLI_RO=0; resolve_source 2>/dev/null; rs2=$RESOLVED; rf2=$APCLI_RO
        SOURCE=$r_src
        if [ "$rs1" = none ] && [ "$rs2" = pineap ] && [ "$rf2" = 1 ]; then st_pass "pineap: STARCHORUS_SOURCE=pineap needs the command line on the device, and switches on apcli_ro for itself"; else st_fail "pineap: resolve ($rs1/$rs2/$rf2)"; fi
        # run_cycle publishes it with the usual post-passes
        RESOLVED=pineap; OUTFILE="$rpt/pn.json"; OUTDIR="$rpt"; VENDOR=0; MAX_AGE=0; PSEC_T=0; PATH="$ppt/bin:$p_path2"; RECON_DB="$tdir/none-such.db"; RDB_PATH=""
        run_cycle >/dev/null 2>&1
        if json_ok < "$OUTFILE" && grep -q '"source": "pineap"' "$OUTFILE" && grep -q '"center": {"label": "This device", "max_age": 0, "interval"' "$OUTFILE"; then st_pass "pineap: run_cycle publishes it, center extras included"; else st_fail "pineap: run_cycle"; fi
        # ... with a Bluetooth layer (another collector's window makes it a void one): the AP service's document carries the layer, nothing is left behind
        bts_reap; bt_env on; bts_other; BLUETOOTH=1; BT_HELD=""
        run_cycle >/dev/null 2>&1
        if json_ok < "$OUTFILE" && grep -q '"source": "pineap"' "$OUTFILE" && grep -q '^  "bluetooth": \[\],$' "$OUTFILE" && grep -q '"bt_window": 0, "bt_hold": 120' "$OUTFILE"; then st_pass "pineap: a cycle with the Bluetooth layer on publishes the AP service's document with the layer (a void window: the empty array, bt_window 0)"; else st_fail "pineap: cycle with the Bluetooth layer"; fi
        bts_other_end; bts_idle "pineap cycle"; BLUETOOTH=0; bt_env off
        # no usable answer (an empty list; a hung or failing command line): recon.db for that cycle, said once; then pineap again
        RECON_DB="$tdir/recon_pn.db"; RDB_PATH=""; PN_FELL=0; PATH="$ppt/bin4:$p_path2"
        run_cycle >/dev/null 2>"$ppt/err1"; run_cycle >/dev/null 2>"$ppt/err2"
        if grep -q '"source": "recon-db"' "$OUTFILE" && json_ok < "$OUTFILE" && grep -q 'pineap: no usable answer' "$ppt/err1" && ! grep -q 'pineap: no usable answer' "$ppt/err2"; then st_pass "pineap: an empty answer -> recon.db for that cycle, logged once per episode"; else st_fail "pineap: fallback ($(cat "$ppt/err1" "$ppt/err2" | head -2))"; fi
        PATH="$ppt/bin:$p_path2"; run_cycle >/dev/null 2>&1
        if grep -q '"source": "pineap"' "$OUTFILE" && [ "$PN_FELL" = 0 ]; then st_pass "pineap: back on the AP service's lists as soon as it answers"; else st_fail "pineap: no return from the fallback"; fi
        # a hung command line: a stand-in `timeout` (the device has a `timeout`) cuts the call off after the 10 s the collector asks for
        apcli_stub "$ppt/bin6" "$ppt/hanglog" hang
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nn=$1; shift; "$@" & p=$!; ( sleep "$n"; kill "$p" 2>/dev/null ) & w=$!; wait "$p"; rc=$?; kill "$w" 2>/dev/null; exit "$rc"\n' "$ppt/tolog" > "$ppt/bin6/timeout"
        chmod +x "$ppt/bin6/timeout"; : > "$ppt/tolog"
        PATH="$ppt/bin6:$p_path2"; PN_FELL=0; pt_a=$(command date +%s); run_cycle >/dev/null 2>&1; pt_b=$(command date +%s)
        case $(head -n 1 "$ppt/tolog") in "10 "*"RECON APS format=json") pt_to=1 ;; *) pt_to=0 ;; esac
        if [ $((pt_b - pt_a)) -lt 30 ] && [ "$pt_to" = 1 ] && grep -q '"source": "recon-db"' "$OUTFILE"; then st_pass "pineap: the list calls run under timeout 10; a hung command line is cut off and recon.db answers"; else st_fail "pineap: hang not cut off ($((pt_b - pt_a)) s, [$(head -n 1 "$ppt/tolog")])"; fi
        PATH=$p_path2; APCLI_RO=$p_flag2; TMPDIR_RAM=$p_tmp2; RECON_DB=$p_db2; MAX_AGE=$p_age2; PSEC_T=0; RDB_PATH=""; PINEAP_CALLS=$p_calls2
        unset -f date calls cyc
        PATH=$r_path; RESOLVED=$r_res; RECON_DB=$r_db; OUTFILE=$r_of; VENDOR=$r_ven; MAX_AGE=$r_age; TMPDIR_RAM=$r_tmp; OUTDIR=$r_od; INTERVAL=$r_int
        RS_SIG=""; RS_SKIPS=0; HAS_TIME=""; unset SHIM_REAL SHIM_LOG SHIM_SQL
    else
        log "  SKIP: recon.db tests (sqlite3 not installed here)"
    fi

    # ---- 4) tcpdump text -------------------------------------------------------------------
    # Real `tcpdump -e` shapes: with radiotap prefix (rate, MHz, dBm), rates IE "[... Mbit]",
    # capabilities ESS / ", PRIVACY", DS channel "CH: n"; an MCS/6GHz beacon without DS IE; a
    # legacy short line without radiotap; and an SSID that tries to inject "CH: 6 ... PRIVACY".
    line_of() { printf '%s\n' "$1" | grep -- "$2" | head -1; }   # first output line containing $2
    # (a plain file, not td=$(cat <<EOF): bash's $(...) parser trips over the unbalanced ")" below)
    cat > "$tdir/tcpdump.txt" <<'TXT'
10:00:00.000000 1.0 Mb/s 2437 MHz 11g -45dBm signal antenna 0 BSSID:aa:bb:cc:00:11:22 DA:ff:ff:ff:ff:ff:ff SA:aa:bb:cc:00:11:22 Beacon (HomeNet) [1.0* 2.0* 5.5* 11.0* 6.0 9.0 12.0 18.0 Mbit] ESS CH: 6, PRIVACY
10:00:00.100000 -78dBm signal antenna 0 BSSID:ff:ff:ff:ff:ff:ff DA:ff:ff:ff:ff:ff:ff SA:99:88:77:66:55:44 Probe Request (FreeWifi) [1.0* 2.0* 5.5* 11.0* Mbit]
10:00:00.200000 6.0 Mb/s 5745 MHz 11a -60dBm signal antenna 0 BSSID:de:ad:be:ef:00:01 DA:11:22:33:44:55:66 SA:de:ad:be:ef:00:01 Probe Response (OtherNet) [6.0* 9.0 12.0* 18.0 24.0* 36.0 48.0 54.0 Mbit] ESS CH: 149
10:00:00.300000 MCS 7 20 MHz lon GI 5955 MHz 11a -66dBm signal antenna 0 BSSID:a8:bb:cc:66:77:88 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:88 Beacon (Mesh6E) [6.0* 9.0 12.0* Mbit] ESS
10:00:00.400000 1.0 Mb/s 2462 MHz 11g -50dBm signal antenna 0 BSSID:a8:bb:cc:00:99:99 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:99 Beacon (CH: 6 [54.0 Mbit] PRIVACY) [1.0* 2.0* 5.5* 11.0* Mbit] ESS CH: 11
10:00:00.500000 -52dBm signal antenna 0 12500us BSSID:aa:bb:cc:00:11:22 DA:ff:ff:ff:ff:ff:ff SA:aa:bb:cc:00:11:22 Beacon (HomeNet) [1.0* 2.0*] CH: 6
10:00:00.600000 1.0 Mb/s 2437 MHz 11g -47dBm signal antenna 0 BSSID:a8:bb:cc:00:99:98 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:98 Beacon (x) CH: 11, PRIVACY) [1.0* 2.0* Mbit] ESS CH: 6
10:00:00.700000 1.0 Mb/s 2462 MHz 11g -49dBm signal antenna 0 BSSID:a8:bb:cc:00:99:97 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:97 Beacon (x CH: 6 [54.0 Mbit] PRIVACY, y) [1.0* 2.0* 5.5* 11.0* Mbit] ESS CH: 11
10:00:00.800000 MCS 7 20 MHz lon GI 5955 MHz 11a -64dBm signal antenna 0 BSSID:a8:bb:cc:66:77:89 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:89 Beacon (Mesh6E-DS) [6.0* 9.0 12.0* Mbit] ESS CH: 1
10:00:00.900000 1.0 Mb/s 2412 MHz 11g -58dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8a DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8a Beacon (Ch1-24) [1.0* 2.0* Mbit] ESS CH: 1
10:00:01.000000 MCS 7 20 MHz lon GI 5935 MHz 11a -70dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8b DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8b Beacon (Mesh6E-Ch2) [6.0* Mbit] ESS CH: 2
10:00:01.100000 MCS 7 20 MHz lon GI 5935 MHz 11a -71dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8c DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8c Beacon (Mesh6E-Ch2-noDS) [6.0* Mbit] ESS
TXT
    out=$(parse_tcpdump_text 1710000000 < "$tdir/tcpdump.txt" 2>/dev/null)
    jcheck "tcpdump" "$out"
    printf '%s\n' "$out" > "$tdir/emit-tcpdump.json"; lay_check "tcpdump document" "$tdir/emit-tcpdump.json"
    check "tcpdump: source label"   "$out" '"source": "tcpdump"'
    check "tcpdump: beacon AP"      "$out" '"bssid": "aa:bb:cc:00:11:22"'
    check "tcpdump: probe-resp AP"  "$out" '"bssid": "de:ad:be:ef:00:01"'
    check "tcpdump: probe client"   "$out" '"mac": "99:88:77:66:55:44", "rssi": -78'
    checkf "tcpdump: probe SSID -> probes" "$out" '"rssi": -78, "probes": ["FreeWifi"]'
    hn=$(line_of "$out" 'aa:bb:cc:00:11:22')
    check "tcpdump: channel from DS 'CH: 6'"      "$hn" '"channel": 6, "band": "2.4GHz", "freq": 2437'
    check "tcpdump: PRIVACY -> security Secured"  "$hn" '"security": "Secured"'
    check "tcpdump: rate = highest legacy rate"   "$hn" '"rate": 18'
    check "tcpdump: strongest RSSI kept (-45)"    "$hn" '"rssi": -45'
    check "tcpdump: probe-resp ch149/Open/rate 54" "$(line_of "$out" 'de:ad:be:ef:00:01')" \
        '"channel": 149, "band": "5GHz", "freq": 5745, "rssi": -60, "security": "Open", "rate": 54'
    check "tcpdump: 6GHz from radiotap MHz (no CH:)" "$(line_of "$out" 'a8:bb:cc:66:77:88')" \
        '"channel": 1, "band": "6GHz", "freq": 5955, "rssi": -66, "security": "Open", "rate": 12'
    # the DS channel number alone is ambiguous ("CH: 1" is 2412 MHz on 2.4GHz, 5955 MHz on 6GHz):
    # only the radiotap MHz prefix decides; a mutant using freq_from_ch(c) alone turns this red
    check "tcpdump: 6GHz with DS 'CH: 1' -> freq 5955 (radiotap disambiguates)" "$(line_of "$out" 'a8:bb:cc:66:77:89')" \
        '"channel": 1, "band": "6GHz", "freq": 5955, "rssi": -64'
    check "tcpdump: 2.4GHz with DS 'CH: 1' -> freq 2412 (counter-check)" "$(line_of "$out" 'a8:bb:cc:66:77:8a')" \
        '"channel": 1, "band": "2.4GHz", "freq": 2412, "rssi": -58'
    check "tcpdump: 6GHz channel 2 = 5935 MHz (DS CH: 2)"      "$(line_of "$out" 'a8:bb:cc:66:77:8b')" '"channel": 2, "band": "6GHz", "freq": 5935'
    check "tcpdump: 6GHz channel 2 = 5935 MHz (radiotap only)" "$(line_of "$out" 'a8:bb:cc:66:77:8c')" '"channel": 2, "band": "6GHz", "freq": 5935'
    inj=$(line_of "$out" 'a8:bb:cc:00:99:99')
    check "tcpdump: injected SSID kept verbatim"  "$inj" '"ssid": "CH: 6 \[54.0 Mbit\] PRIVACY"'
    check "tcpdump: injection ignored (ch11/Open/11)" "$inj" '"channel": 11, "band": "2.4GHz", "freq": 2462, "rssi": -50, "security": "Open", "rate": 11'
    # an SSID containing ")" must not move its own remainder into the field area (ch 11 / Secured)
    pj=$(line_of "$out" 'a8:bb:cc:00:99:98')
    checkf "tcpdump: SSID with ')' kept verbatim"           "$pj" '"ssid": "x) CH: 11, PRIVACY"'
    check  "tcpdump: ')' injection ignored (ch6/Open/2)"     "$pj" '"channel": 6, "band": "2.4GHz", "freq": 2437, "rssi": -47, "security": "Open", "rate": 2'
    # " CH: 6" WITH its leading space and "PRIVACY," as a whole word inside the SSID
    sj=$(line_of "$out" 'a8:bb:cc:00:99:97')
    checkf "tcpdump: ' CH: 6 ... PRIVACY,' SSID kept verbatim" "$sj" '"ssid": "x CH: 6 [54.0 Mbit] PRIVACY, y"'
    check  "tcpdump: ' CH:' injection ignored (ch11/Open/11)" "$sj" '"channel": 11, "band": "2.4GHz", "freq": 2462, "rssi": -49, "security": "Open", "rate": 11'

    # ---- 5) none path + atomic write -------------------------------------------------------
    empty=$(write_empty 1710000000 "test reason")
    jcheck "none-doc" "$empty"
    check "none: source none"  "$empty" '"source": "none"'
    check "none: note present" "$empty" '"note": "test reason"'
    RESOLVED=none; OUTFILE="$tdir/starchorus.json"; run_cycle
    if [ -s "$OUTFILE" ] && json_ok < "$OUTFILE"; then st_pass "run_cycle wrote valid JSON atomically"; else st_fail "run_cycle output"; fi

    # ---- 6) vendor lookup (passive, local OUI file) + optional fields ---------------------
    vbase() { printf '%s\n' "$base" | add_vendor 2>/dev/null; }          # the post-pass over the emitter document
    vreset() { printf '%s\n' "$(head -n 1 "$OUI_CACHE")" > "$OUI_CACHE"; }   # the cache back to its header line
    # Test MACs: A8:BB:CC / A8:BB:CD / 10:22:33 / 98:76:54 have the U/L bit CLEAR (real OUIs);
    # 9A:... and AA:... have it SET (randomized client / virtual BSSID). Speed -1 = unknown rate.
    rm -f "$CAPDIR"/starchorus-*.csv 2>/dev/null
    cat > "$CAPDIR/starchorus-06.csv" <<'CSV'
BSSID, First time seen, Last time seen, channel, Speed, Privacy, Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
A8:BB:CC:00:11:22, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 6, 130, WPA2, CCMP, PSK, -42, 100, 0, 0.0.0.0, 7, AcmeNet,
A8:BB:CD:00:11:23, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 11, 54, WPA2, CCMP, PSK, -61, 10, 0, 0.0.0.0, 6, Quoted,
AA:BB:CC:33:44:55, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 36, -1, OPN, , , -70, 50, 0, 0.0.0.0, 26, "mac": "00:11:22:33:44:55",

Station MAC, First time seen, Last time seen, Power, # packets, BSSID, Probed ESSIDs
10:22:33:44:55:66, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -55, 20, A8:BB:CC:00:11:22,
9A:88:77:66:55:44, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -80, 5, (not associated), FreeWifi
98:76:54:32:10:00, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -85, 1, (not associated),
CSV
    base=$(build_from_csv 1710000000 2>/dev/null)     # plain emitter output (no post-pass)
    checkno "vendor: emitter omits rate for Speed -1" "$(line_of "$base" 'aa:bb:cc:33:44:55')" '"rate"'
    # 6a) nmap format (hit for AP + associated client; duplicate, MA-M/MA-S and comment lines)
    cat > "$tdir/oui-nmap.txt" <<'TXT'
# Nmap MAC prefixes (test file)
A8BBCC Acme Networks
A8BBCC Duplicate Must Lose
A8BBCD Acme "Quoted" \ Corp
102233 Client Corp
0055DA0 Skip MA-M
70B3D5001 Skip MA-S
TXT
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    if [ "$OUI_PATH" = "$tdir/oui-nmap.txt" ] && [ -n "$OUI_CACHE" ] && [ -f "$OUI_CACHE" ]; then
        st_pass "vendor: explicit STARCHORUS_OUI_FILE found, cache created"; else st_fail "vendor: setup_vendor"; fi
    out=$(vbase)
    jcheck "vendor(Nmap):" "$out"
    check   "vendor(Nmap): AP vendor after bssid (first line wins)" "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks", "ssid": "AcmeNet"'
    check   "vendor(Nmap): associated client vendor"  "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp", "rssi": -55'
    checkf  "vendor(Nmap): quote + backslash escaped" "$out" '"vendor": "Acme \"Quoted\" \\ Corp"'
    check   "vendor: rate survives beside vendor"     "$out" '"rate": 130'
    check   "vendor: randomized client flagged"       "$out" '"mac": "9a:88:77:66:55:44", "randomized": true, "rssi": -80'
    checkno "vendor: randomized client has no vendor" "$(line_of "$out" '9a:88:77:66:55:44')" '"vendor"'
    laa=$(line_of "$out" 'aa:bb:cc:33:44:55')
    checkno "vendor: LAA bssid gets no vendor"        "$laa" '"vendor"'
    checkno "vendor: LAA bssid gets no randomized"    "$laa" '"randomized"'
    checkf  "vendor: SSID injection inert"            "$laa" '"ssid": "\"mac\": \"00:11:22:33:44:55\""'
    checkno "vendor: unknown prefix -> no field"      "$(line_of "$out" '98:76:54:32:10:00')" '"vendor"'
    ccache=$(cat "$OUI_CACHE" 2>/dev/null)
    checkf  "vendor: cache header ties cache to file" "$ccache" "# oui=$tdir/oui-nmap.txt size="
    check   "vendor: cache positive entry"            "$ccache" "^A8BBCC${RECON_TAB}Acme Networks\$"
    check   "vendor: cache negative entry"            "$ccache" "^987654${RECON_TAB}\$"
    # a merge says so: the growth of the cache is logged, and a merge that cannot happen is logged once with its reason (without that, a cache
    # that stops growing -- and an OUI file scanned every cycle because of it -- is invisible)
    vreset; VENDOR_DROP_LOGGED=0
    vlog=$(printf '%s\n' "$base" | add_vendor 2>&1 >/dev/null)
    check   "vendor: the merge logs the new prefixes and the cache size" "$vlog" 'vendor cache: [0-9]* new prefix(es), [0-9]* lines'
    vreset; OUI_HDR_SAVE=$OUI_HDR; OUI_HDR="# oui=elsewhere size=1 mtime=1"
    vlog=$(printf '%s\n' "$base" | add_vendor 2>&1 >/dev/null)
    OUI_HDR=$OUI_HDR_SAVE
    check   "vendor: a merge dropped because the cache header names another OUI file says so" "$vlog" 'merge skipped (the header of'
    # two instances gather the same new prefixes before either has merged (the daemon and a crond --once): the second merge finds them in the cache. It says nothing
    # about a failed write (they are there, the OUI file is not scanned again), and the episode flag is clear. A merge that really cannot write still says so.
    printf '%s\n' "$base" > "$tdir/vdoc"
    vreset; VENDOR_DROP_LOGGED=0
    add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; vn1=$VENDOR_NEWF; VENDOR_NEWF=""
    add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; vn2=$VENDOR_NEWF
    VENDOR_NEWF=$vn1; vendor_merge 2>/dev/null
    VENDOR_NEWF=$vn2; vendor_merge 2>"$tdir/vlog2"
    vlog2=$(cat "$tdir/vlog2")
    vc2=$(cat "$OUI_CACHE")
    checkno "vendor: a merge whose lines another instance merged first claims no write failure" "$vlog2" 'merge skipped'
    if [ "$VENDOR_DROP_LOGGED" = 0 ] && [ "$(printf '%s\n' "$vc2" | grep -c '^A8BBCC')" = 1 ] && printf '%s\n' "$vc2" | grep -q '^102233'; then
        st_pass "vendor: ... the cache holds each prefix once and the drop flag stays clear"; else st_fail "vendor: second merge (flag $VENDOR_DROP_LOGGED, cache [$vc2])"; fi
    vreset; VENDOR_DROP_LOGGED=0
    add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1
    chmod a-w "$OUI_CACHE"
    if [ ! -w "$OUI_CACHE" ]; then
        vlog3=$(vendor_merge 2>&1 >/dev/null); VENDOR_NEWF=""
        check "vendor: a merge that cannot write still says so" "$vlog3" 'merge skipped (nothing was added'
    else rm -f "$VENDOR_NEWF"; VENDOR_NEWF=""; fi      # (root writes through the mode bits: nothing to test)
    chmod u+w "$OUI_CACHE"; vreset; VENDOR_DROP_LOGGED=0
    # the gathering file of run_cycle's pass (0.2.6): a fixed name (.gat.<pid>) in place of a mktemp and a rm for the pass that finds nothing new, which is nearly every pass.
    # A pass whose lines nobody has merged yet, and every pass without "defer", keep the mktemp name. Stand-ins for mktemp and rm log what they are asked.
    gat="$OUI_CACHE.gat.$$"; gx_dir="$tdir/gatbin"; rm -rf "$gx_dir"; mkdir -p "$gx_dir"; : > "$tdir/gat.log"
    # shellcheck disable=SC2016  # the stand-ins' text: the variables are theirs
    for gx_n in mktemp rm; do printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/gat.log"\nexec %s "$@"\n' "$gx_n" "$tdir" "$(command -v "$gx_n")" > "$gx_dir/$gx_n"; chmod +x "$gx_dir/$gx_n"; done
    printf '%s\n' "$base" > "$tdir/vdoc"; gx_pth=$PATH; PATH="$gx_dir:$PATH"
    vreset; VENDOR_DROP_LOGGED=0; : > "$tdir/gat.log"
    add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; gx_f1=$VENDOR_NEWF; gx_s1=0; [ -s "$gat" ] && gx_s1=1
    vendor_merge 2>/dev/null; gx_m1="$(grep -c '^mktemp' "$tdir/gat.log")/$(grep -c '^rm .*\.gat\.' "$tdir/gat.log")"
    : > "$tdir/gat.log"; add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; gx_f2=$VENDOR_NEWF; vendor_merge 2>/dev/null
    gx_m2="$(grep -c '^mktemp' "$tdir/gat.log")/$(grep -c '^rm' "$tdir/gat.log")"
    vreset; : > "$tdir/gat.log"
    add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; gx_a=$VENDOR_NEWF; VENDOR_NEWF=""; add_vendor defer < "$tdir/vdoc" >/dev/null 2>&1; gx_b=$VENDOR_NEWF
    gx_m3=$(grep -c '^mktemp' "$tdir/gat.log"); VENDOR_NEWF=$gx_a; vendor_merge 2>/dev/null; VENDOR_NEWF=$gx_b; vendor_merge 2>/dev/null
    vreset; : > "$tdir/gat.log"; add_vendor < "$tdir/vdoc" >/dev/null 2>&1; gx_m4=$(grep -c '^mktemp' "$tdir/gat.log")
    PATH=$gx_pth
    if [ "$gx_f1" = "$gat" ] && [ "$gx_s1" = 1 ] && [ "$gx_m1" = 0/1 ] && [ -z "$gx_f2" ] && [ "$gx_m2" = 0/0 ] && [ "$gx_a" = "$gat" ] && [ -n "$gx_b" ] && [ "$gx_b" != "$gat" ] && [ "$gx_m3" = 1 ] && [ "$gx_m4" = 1 ] \
       && [ ! -e "$gx_b" ] && [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ]; then
        st_pass "vendor: run_cycle's pass gathers into a fixed .gat.<pid> file: no mktemp, no rm for a pass that finds nothing new (0/0); a pass with new prefixes needs no mktemp and one rm at the merge; a pass whose lines are unmerged, and a pass without defer, take a mktemp name (the old behaviour)"
    else st_fail "vendor: gathering file (new $gx_m1 [$gx_f1], nothing new $gx_m2 [$gx_f2], pending $gx_m3 [$gx_a|$gx_b], without defer $gx_m4)"; fi
    # swept like the other temp files: a dead collector's, never a live one's
    : > "$CAPDIR/oui-cache.txt.gat.999999"; : > "$CAPDIR/oui-cache.txt.gat.$$"; sweep_stale_cache_files 2>/dev/null
    gx_sw=0; [ ! -e "$CAPDIR/oui-cache.txt.gat.999999" ] && [ -e "$CAPDIR/oui-cache.txt.gat.$$" ] && gx_sw=1; rm -f "$CAPDIR/oui-cache.txt.gat.$$" "$CAPDIR/oui-cache.txt.gat.999999"
    if [ "$gx_sw" = 1 ]; then st_pass "vendor: the gathering file is swept when its collector is dead (a live one's is kept)"; else st_fail "vendor: sweep of the gathering file"; fi
    # and the end of a collector removes its own (cleanup): a real --once with the vendor pass leaves none; with an rm that skips the file it is there, so that the first result
    # is the cleanup's, not the pass's. (The child reads recon.db: it needs sqlite3.)
    if have sqlite3; then
        gx_o="$tdir/gatc"; rm -rf "$gx_o"; mkdir -p "$gx_o"; printf 'A8BBCC Gat Networks\n' > "$gx_o/oui.txt"
        gx_run() { PATH="$1$PATH" STARCHORUS_OUTDIR="$gx_o" STARCHORUS_CAPDIR="$gx_o/cap" STARCHORUS_TMPDIR="$gx_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$tdir/recon_ssid.db" STARCHORUS_VENDOR=1 \
            STARCHORUS_OUI_FILE="$gx_o/oui.txt" STARCHORUS_CREATE_MON=0 STARCHORUS_PIDDIR="$gx_o" sh "$0" --once >/dev/null 2>&1; }
        gx_run ""; gx_c1=""; for gx_x in "$gx_o/cap"/*; do [ -e "$gx_x" ] && gx_c1="$gx_c1 ${gx_x##*/}"; done
        mkdir -p "$gx_dir/norm"
        # shellcheck disable=SC2016  # the stand-in's text
        printf '#!/bin/sh\nfor a; do case $a in -*|*.gat.*) ;; *) %s -rf -- "$a" ;; esac; done\n' "$(command -v rm)" > "$gx_dir/norm/rm"; chmod +x "$gx_dir/norm/rm"
        rm -rf "$gx_o/cap"; gx_run "$gx_dir/norm:"; gx_c2=""; for gx_x in "$gx_o/cap"/*; do [ -e "$gx_x" ] && gx_c2="$gx_c2 ${gx_x##*/}"; done
        case $gx_c1 in *oui-cache.txt*) gx_h1=1 ;; *) gx_h1=0 ;; esac; case $gx_c1 in *.gat.*) gx_g1=1 ;; *) gx_g1=0 ;; esac; case $gx_c2 in *.gat.*) gx_g2=1 ;; *) gx_g2=0 ;; esac
        if [ "$gx_h1/$gx_g1/$gx_g2" = 1/0/1 ]; then
            st_pass "vendor: a collector removes its own gathering file at its end (a --once with the vendor pass leaves none; with an rm that skips the file the file is there)"
        else st_fail "vendor: the gathering file's end (run $gx_c1, planted $gx_c2)"; fi
    else log "  SKIP: vendor: the end of the gathering file (the --once child reads recon.db, and sqlite3 is not installed here)"; fi
    unset -f gx_run
    # the lock backoff is judged against a clock that may have been set back (the device has no battery clock)
    LOCK_BUSY_UNTIL=$(( $(date +%s) + 30 )); cache_lock; lbr=$?; cache_unlock
    LOCK_BUSY_UNTIL=$(( $(date +%s) + 99999 )); cache_lock; lbr2=$?; cache_unlock; LOCK_BUSY_UNTIL=0
    if [ "$lbr" = 2 ] && [ "$lbr2" != 2 ]; then st_pass "vendor lock: a backoff of 30 s holds, one that lies days in the future (clock set back) is dropped"; else st_fail "vendor lock: backoff ($lbr/$lbr2)"; fi
    vreset; vbase >/dev/null; VENDOR_DROP_LOGGED=0     # leave the cache as the checks below expect it: filled
    # 6b) cache reuse: OUI file gone, 2nd run must be served from the cache and not grow it
    n1=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    OUI_PATH="$tdir/oui-gone.txt"
    out2=$(vbase)
    n2=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    if [ "$out" = "$out2" ]; then st_pass "vendor: 2nd run served from cache (byte-identical)"; else st_fail "vendor: cache reuse output"; fi
    if [ "$n1" = "$n2" ] && [ "$n1" -gt 1 ]; then st_pass "vendor: cache unchanged on 2nd run ($n1 lines)"; else st_fail "vendor: cache grew/shrank ($n1 -> $n2)"; fi
    # 6c) macchanger "AA BB CC NAME" and "AA:BB:CC - Name"; a different file restarts the cache
    printf '%s\n' 'A8 BB CC ACME NETWORKS' '10 22 33 CLIENT CORP' 'A8:BB:CD - Dash Style' > "$tdir/oui-mc.txt"
    OUI_FILE="$tdir/oui-mc.txt"; setup_vendor 2>/dev/null
    n3=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    if [ "$n3" = "1" ]; then st_pass "vendor: new file restarts cache (header only)"; else st_fail "vendor: cache restart ($n3 lines)"; fi
    out=$(vbase)
    check "vendor(macchanger): 'AA BB CC NAME'"      "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "ACME NETWORKS"'
    check "vendor(macchanger): client"               "$out" '"mac": "10:22:33:44:55:66", "vendor": "CLIENT CORP"'
    check "vendor(dash): 'AA:BB:CC - Name'"          "$out" '"bssid": "a8:bb:cd:00:11:23", "vendor": "Dash Style"'
    # 6d) IEEE oui.txt ((hex) + (base 16) + address lines) and Wireshark manuf (tabs, CRLF, /28)
    { printf 'OUI/MA-L\t\t\t\t\t\tOrganization\ncompany_id\t\t\t\t\t\tOrganization\n\t\t\t\t\t\tAddress\n\n'
      printf 'A8-BB-CC   (hex)\t\tAcme Networks Ltd\nA8BBCC     (base 16)\t\tAcme Networks Ltd\n'
      printf '\t\t\t\t1 Acme Way\n\t\t\t\tAcmeville  CA  90000\n\t\t\t\tUS\n\n'
      printf '10:22:33\tCli\tClient Corp Long\r\n00:55:DA:00:00:00/28\tSkip\tLong Block\r\n'; } > "$tdir/oui-ieee.txt"
    OUI_FILE="$tdir/oui-ieee.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    jcheck "vendor(ieee):" "$out"
    check "vendor(ieee): '(hex)' line, first wins"   "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks Ltd"'
    vcnt=$(printf '%s\n' "$out" | awk '{n+=gsub(/Acme Networks Ltd/,"&")} END{print n+0}')
    if [ "$vcnt" = "1" ]; then st_pass "vendor(ieee): vendor inserted exactly once"; else st_fail "vendor(ieee): inserted x$vcnt"; fi
    check "vendor(manuf): last tab field, CRLF ok"   "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp Long"'
    # 6e) missing OUI file: one log line, no vendor field, randomized still flagged, JSON valid
    VENDOR_STATE=""; OUI_FILE="$tdir/no-such-oui.txt"; setup_vendor 2>"$tdir/log6e"
    check "vendor: missing file logged"              "$(cat "$tdir/log6e")" 'no OUI database found'
    if [ -z "$OUI_PATH" ] && [ -z "$OUI_CACHE" ]; then st_pass "vendor: missing file -> no path, no cache"; else st_fail "vendor: missing file state"; fi
    out=$(vbase)
    jcheck "vendor(none):" "$out"
    checkno "vendor: missing file -> no vendor field" "$out" '"vendor"'
    check   "vendor: missing file -> randomized kept" "$out" '"randomized": true'
    # 6f) run_cycle integration (airodump path) and STARCHORUS_VENDOR=0 => emitter output identical
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; run_cycle
    if [ -s "$OUTFILE" ] && json_ok < "$OUTFILE" && grep -q '"vendor": "Acme Networks"' "$OUTFILE"; then
        st_pass "vendor: run_cycle publishes vendor (airodump path)"; else st_fail "vendor: run_cycle airodump"; fi
    VENDOR=0; setup_vendor 2>/dev/null; run_cycle
    # run_cycle always inserts max_age/interval into the one-line center object, so "identical" means identical apart from that line
    # (and `generated`); the center line itself must be the emitter's line with exactly center_extra() inside its closing brace.
    if ! grep -q '"vendor"' "$OUTFILE" && ! grep -q '"randomized"' "$OUTFILE" && \
       [ "$(grep -v -e '"generated"' -e '"center"' "$OUTFILE")" = "$(printf '%s\n' "$base" | grep -v -e '"generated"' -e '"center"')" ] && \
       [ "$(grep '"center"' "$OUTFILE")" = "$(printf '%s\n' "$base" | grep '"center"' | sed "s/}\(,\{0,1\}\)\$/$(center_extra | sed 's/[\/&]/\\&/g')}\1/")" ]; then
        st_pass "vendor: STARCHORUS_VENDOR=0 -> emitter output byte-identical (apart from the center extras)"; else st_fail "vendor: STARCHORUS_VENDOR=0 output differs"; fi
    VENDOR=1
    # 6g) recon.db path via run_cycle: vendor + last_seen, bare-column integrity, client fields
    if have sqlite3; then
        vdb="$tdir/recon_vendor.db"
        sqlite3 "$vdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
-- same BSSID twice: ssid/encryption must come from the STRONGER (-55, older, WPA2, "OLD") row,
-- last_seen must be the NEWER time 2000 (SQLite bare-column trap, see build_from_recondb)
INSERT INTO ssid VALUES (1,0,1,8,'A8BBCC000001','HomeNet-OLD',0,1000,-55,2437,6,8);
INSERT INTO ssid VALUES (2,0,2,8,'A8BBCC000001','HomeNet-NEW',0,2000,-77,2437,6,24);
INSERT INTO ssid VALUES (3,0,1,8,'A8BBCD000002','NoTime',0,0,-60,5180,36,8);
INSERT INTO ssid VALUES (4,301,1,4,'FFFFFFFFFFFF','',0,1300,-70,0,0,0);
INSERT INTO ssid VALUES (5,301,2,4,'FFFFFFFFFFFF','',0,1100,-60,0,0,0);
INSERT INTO ssid VALUES (6,302,1,4,'FFFFFFFFFFFF','',0,1500,-90,0,0,0);
INSERT INTO wifi_device VALUES (301,1,'102233AABBCC',1300,-70,0,5);
INSERT INTO wifi_device VALUES (302,1,'9A8877665544',1500,-90,0,1);
SQL
        OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
        RESOLVED=recondb; RECON_DB="$vdb"; run_cycle; RECON_DB=auto
        rout=$(cat "$OUTFILE" 2>/dev/null)
        jcheck "recon+vendor:" "$rout"
        check   "recon: AP vendor via run_cycle"         "$rout" '"bssid": "a8:bb:cc:00:00:01", "vendor": "Acme Networks"'
        check   "recon: last_seen = MAX(time) per AP"    "$rout" '"rssi": -55, "security": "WPA2", "last_seen": 2000'
        check   "recon: bare columns from MAX(signal) row" "$rout" '"ssid": "HomeNet-OLD"'
        checkno "recon: time 0 -> no last_seen"          "$(line_of "$rout" 'NoTime')" '"last_seen"'
        check   "recon: client vendor + last_seen"       "$rout" '"mac": "10:22:33:aa:bb:cc", "vendor": "Client Corp", "rssi": -60, "last_seen": 1300'
        check   "recon: randomized client + last_seen"   "$rout" '"mac": "9a:88:77:66:55:44", "randomized": true, "rssi": -90, "last_seen": 1500'
    fi

    # ---- 6h) cache robustness: the failure paths ------------------------------------------
    # (1) OUI file unreadable/unplugged while a NEW prefix shows up: no negative entry may be
    #     written (it would hide that vendor for good); once the file is back, the vendor appears.
    printf '%s\n' '005056 VMware Inc' >> "$tdir/oui-nmap.txt"
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null      # size changed -> fresh cache
    newcl=$(printf '%s\n' "$base" | sed 's/98:76:54:32:10:00/00:50:56:12:34:56/')
    save_ix=$OUI_IDX; OUI_IDX=""        # (this one is about the pass over the OUI file; with an index the lookup does not need the file, see 6j)
    OUI_PATH="$tdir/oui-gone.txt"
    out=$(printf '%s\n' "$newcl" | add_vendor 2>/dev/null); jrc=$?
    if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: unreadable OUI file -> post-pass rc 0, valid JSON"; else st_fail "cache: unreadable OUI file rc=$jrc"; fi
    checkno "cache: unreadable OUI file -> NO negative entry"  "$(cat "$OUI_CACHE")" "^005056${RECON_TAB}\$"
    checkno "cache: unreadable OUI file -> no vendor (yet)"    "$(line_of "$out" '00:50:56:12:34:56')" '"vendor"'
    OUI_PATH="$tdir/oui-nmap.txt"
    out=$(printf '%s\n' "$newcl" | add_vendor 2>/dev/null)
    check   "cache: file back -> vendor found (cache not poisoned)" "$out" '"mac": "00:50:56:12:34:56", "vendor": "VMware Inc"'
    check   "cache: file back -> positive entry cached"        "$(cat "$OUI_CACHE")" "^005056${RECON_TAB}VMware Inc\$"
    OUI_IDX=$save_ix
    # (2) corrupt cache lines: an unterminated last line (crash mid-append) is dropped, a fused
    #     two-tab line and a lowercase prefix are ignored, and those prefixes are resolved again.
    vreset
    { printf 'A8BBCD\tFused\tLine\n'; printf 'a8bbcc\tlowercase\n'
      printf 'A8BBCC\tAcme Net'; } >> "$OUI_CACHE"        # last line cut off, no newline
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "cache: corrupt lines -> valid JSON"; else st_fail "cache: corrupt lines JSON"; fi
    checkno "cache: cut-off last line not trusted"          "$out" 'Acme Net"'
    checkno "cache: fused two-tab line not trusted"         "$out" 'Fused'
    checkno "cache: lowercase-prefix line not trusted"      "$out" 'lowercase'
    check   "cache: cut-off prefix resolved from the file"  "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks"'
    checkf  "cache: fused-line prefix resolved from the file" "$out" '"vendor": "Acme \"Quoted\" \\ Corp"'
    cc=$(cat "$OUI_CACHE")
    checkno "cache: cut-off line removed from the cache"    "$cc" "Acme Net\$"
    check   "cache: repaired cache got the real entry"      "$cc" "^A8BBCC${RECON_TAB}Acme Networks\$"
    if cache_terminated; then st_pass "cache: cache ends with a newline again"; else st_fail "cache: cache still unterminated"; fi
    # (3) a file in an unknown format ("AABBCC=Vendor") and a directory are rejected up front,
    #     never silently turned into an all-negative cache
    printf '%s\n' 'A8BBCC=Acme Networks' '102233=Client Corp' > "$tdir/oui-weird.txt"
    if oui_format_ok "$tdir/oui-nmap.txt" && oui_format_ok "$tdir/oui-mc.txt" && oui_format_ok "$tdir/oui-ieee.txt" \
       && ! oui_format_ok "$tdir/oui-weird.txt" && ! oui_format_ok "$tdir"; then
        st_pass "cache: format probe accepts Nmap/macchanger/ieee, rejects '=' format and a directory"
    else st_fail "cache: format probe"; fi
    VENDOR_STATE=""; OUI_FILE="$tdir/oui-weird.txt"; setup_vendor 2>"$tdir/log6h"
    check "cache: unusable explicit file is logged"    "$(cat "$tdir/log6h")" 'no usable OUI format'
    if [ -z "$OUI_PATH" ] && [ -z "$OUI_CACHE" ]; then st_pass "cache: unusable file -> no path, no cache"; else st_fail "cache: unusable file state ($OUI_PATH)"; fi
    out=$(vbase)
    checkno "cache: unusable file -> no vendor field"   "$out" '"vendor"'
    check   "cache: unusable file -> randomized kept"   "$out" '"randomized": true'
    VENDOR_STATE=""; OUI_FILE="$tdir"; setup_vendor 2>"$tdir/log6h2"
    check "cache: directory as STARCHORUS_OUI_FILE rejected" "$(cat "$tdir/log6h2")" 'no OUI database found'
    # (4) two instances at once on a COLD cache (daemon loop + `--once` from crond): every entry
    #     exactly once, no torn lines, both outputs complete, lock and temp files released
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '%s\n' "$base" | add_vendor > "$tdir/par1" 2>/dev/null &
    printf '%s\n' "$base" | add_vendor > "$tdir/par2" 2>/dev/null &
    wait
    dups=$(grep -v '^#' "$OUI_CACHE" | sort | uniq -d | wc -l | tr -d ' ')
    badl=$(grep -v '^#' "$OUI_CACHE" | awk -F "$RECON_TAB" 'NF!=2{n++} END{print n+0}')
    nent=$(grep -vc '^#' "$OUI_CACHE")
    if [ "$dups" = "0" ] && [ "$badl" = "0" ] && [ "$nent" = "4" ]; then
        st_pass "cache: 2 parallel instances -> 4 entries, no duplicates, no torn lines"
    else st_fail "cache: parallel instances (dups=$dups torn=$badl entries=$nent)"; fi
    for pf in par1 par2; do
        if json_ok < "$tdir/$pf" && grep -q '"vendor": "Acme Networks"' "$tdir/$pf" && grep -q '"vendor": "Client Corp"' "$tdir/$pf"; then
            st_pass "cache: parallel instance $pf output complete"; else st_fail "cache: parallel instance $pf output"; fi
    done
    if [ ! -d "$OUI_CACHE.lock" ] && [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ] \
       && [ -z "$(ls -d "$OUI_CACHE".lock.stale.* 2>/dev/null)" ]; then
        st_pass "cache: lock and temp files released"; else st_fail "cache: lock/temp file left behind"; fi
    # (5) a rewritten OUI file of the SAME byte size (firmware update) restarts the cache (mtime)
    printf '%s\n' 'A8BBCC Acme' > "$tdir/oui-same.txt"; touch -t 202001010000 "$tdir/oui-same.txt" 2>/dev/null
    m1=$(file_mtime "$tdir/oui-same.txt")
    OUI_FILE="$tdir/oui-same.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    check "cache: mtime baseline vendor"                "$out" '"vendor": "Acme"'
    printf '%s\n' 'A8BBCC Bcme' > "$tdir/oui-same.txt"       # same byte count, new content, newer mtime
    m2=$(file_mtime "$tdir/oui-same.txt")
    if [ -z "$m1" ] || [ -z "$m2" ] || [ "$m1" = "$m2" ]; then
        log "  SKIP: cache: same-size rewrite (mtime unavailable or unchanged here: '$m1' -> '$m2')"
    else
        setup_vendor 2>/dev/null
        out=$(vbase)
        check  "cache: same-size rewritten file restarts the cache (mtime)" "$out" '"vendor": "Bcme"'
        checkf "cache: header carries the mtime"        "$(head -n 1 "$OUI_CACHE")" "mtime=$m2"
    fi
    # (6) a backslash sequence in the OUI/CAPDIR path (stick paths are user input) must survive
    #     every hand-over verbatim: `\t` is an echo escape under dash / bash-as-sh (so paths travel
    #     via printf) AND an awk -v escape (so they travel via ENVIRON). `b\s` would test neither.
    bsd="$tdir/b\\ts"
    mkdir -p "$bsd" && cp "$tdir/oui-nmap.txt" "$bsd/oui.txt"
    save_cap=$CAPDIR; CAPDIR=$bsd; OUI_FILE="$bsd/oui.txt"; VENDOR_STATE=""; setup_vendor 2>"$tdir/log6h6"
    if [ "$OUI_PATH" = "$bsd/oui.txt" ] && [ "$OUI_CACHE" = "$bsd/oui-cache.txt" ]; then
        st_pass "cache: '\\t' in the path resolved verbatim (printf, not echo)"
    else st_fail "cache: '\\t' path mangled (OUI_PATH='$OUI_PATH')"; fi
    out=$(vbase)
    check  "cache: backslash in OUI path handled (ENVIRON, not -v)" "$out" '"vendor": "Acme Networks"'
    check  "cache: backslash in cache path handled"      "$(cat "$bsd/oui-cache.txt" 2>/dev/null)" "^A8BBCC${RECON_TAB}Acme Networks\$"
    checkf "log: backslash sequence printed verbatim"    "$(cat "$tdir/log6h6")" "vendor lookup: $bsd/oui.txt"
    CAPDIR=$save_cap
    # (7) CAPDIR turns read-only after start (full / ro eMMC): the post-pass must still deliver
    #     vendor + randomized (no cache write, no fatal awk). chmod does not stop root (the device
    #     runs everything as root), so the cache is ALSO pointed under a plain file (ENOTDIR for
    #     everyone): mktemp and printf fail there and must not take the awk down.
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        chmod 555 "$CAPDIR" 2>/dev/null
        out=$(vbase); jrc=$?
        chmod 755 "$CAPDIR" 2>/dev/null
        if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: read-only CAPDIR -> post-pass rc 0, valid JSON"; else st_fail "cache: read-only CAPDIR rc=$jrc"; fi
        check "cache: read-only CAPDIR -> vendor still delivered"     "$out" '"vendor": "Acme Networks"'
        check "cache: read-only CAPDIR -> randomized still delivered" "$out" '"randomized": true'
    else
        log "  SKIP: cache: read-only CAPDIR via chmod (no effect for root; ENOTDIR variant below)"
    fi
    printf '' > "$tdir/afile"; save_oc=$OUI_CACHE; OUI_CACHE="$tdir/afile/oui-cache.txt"
    out=$(vbase); jrc=$?
    OUI_CACHE=$save_oc
    if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: unwritable cache path (ENOTDIR) -> post-pass rc 0, valid JSON"; else st_fail "cache: ENOTDIR cache path rc=$jrc"; fi
    check "cache: ENOTDIR cache path -> vendor still delivered"     "$out" '"vendor": "Acme Networks"'
    check "cache: ENOTDIR cache path -> randomized still delivered" "$out" '"randomized": true'
    # (8) the periodic re-check (daemon loop) logs only when something changed
    VENDOR_STATE=""; setup_vendor 2>"$tdir/log6i"; setup_vendor 2>>"$tdir/log6i"; setup_vendor 2>>"$tdir/log6i"
    nlog=$(grep -c 'vendor lookup:' "$tdir/log6i")
    if [ "$nlog" = "1" ]; then st_pass "cache: repeated setup_vendor logs once"; else st_fail "cache: repeated setup_vendor logged x$nlog"; fi
    # (9) control bytes: a foreign/rotten cache line (ESC sequence, CR from a CRLF editor) must not
    #     make every cycle emit invalid JSON; an OUI line with a control byte is cleaned on entry
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf 'A8BBCC\tAcme\033[0m Corp\n102233\tClient Corp\r\n' >> "$OUI_CACHE"
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "cache: control bytes in cache lines -> valid JSON"; else st_fail "cache: control bytes in cache lines -> invalid JSON"; fi
    check "cache: ESC stripped from cached vendor"       "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme\[0m Corp"'
    check "cache: CR stripped from cached vendor"        "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp", "rssi": -55'
    printf 'A8BBCC Bell\007 Labs\n' > "$tdir/oui-bel.txt"
    OUI_FILE="$tdir/oui-bel.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "vendor: control byte in OUI line -> valid JSON"; else st_fail "vendor: control byte in OUI line -> invalid JSON"; fi
    check "vendor: control byte stripped on entry (BEL)" "$out" '"vendor": "Bell Labs"'
    check "vendor: cache entry written without the BEL"  "$(cat "$OUI_CACHE")" "^A8BBCC${RECON_TAB}Bell Labs\$"
    # (10) a temp file whose last line was cut short (ENOSPC on /tmp, killed awk) must not persist
    #      that line as a "well-formed" wrong vendor; the terminated lines before it are merged
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '102233\tClient Corp\nA8BBCC\tAcme Net' > "$tdir/newf-cut"
    cache_append "$tdir/newf-cut"
    cc=$(cat "$OUI_CACHE")
    check   "cache: terminated temp line merged"         "$cc" "^102233${RECON_TAB}Client Corp\$"
    checkno "cache: cut-off temp line NOT merged"        "$cc" "^A8BBCC"
    if cache_terminated && [ ! -d "$OUI_CACHE.lock" ]; then st_pass "cache: cache whole and lock released after the merge"; else st_fail "cache: state after cut temp merge"; fi
    # (11) lock semantics: the holder's liveness decides, never the waiting time
    lk="$OUI_CACHE.lock"
    #   a) lock of a DEAD pid is broken at once
    sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
    mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    if [ "$lr" = "0" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ $((t1-t0)) -le 1 ]; then
        st_pass "lock: dead holder broken at once, lock now ours"; else st_fail "lock: dead holder (rc=$lr, $((t1-t0)) s)"; fi
    cache_unlock
    if [ ! -d "$lk" ]; then st_pass "lock: unlock removed our lock"; else st_fail "lock: unlock left the lock behind"; fi
    #   b) lock without a pid (holder died between mkdir and pid write) is broken after ~3 s grace
    mkdir "$lk"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s); el=$((t1-t0))
    if [ "$lr" = "0" ] && [ "$el" -ge 2 ] && [ "$el" -le 10 ]; then st_pass "lock: pid-less lock broken after the grace period ($el s)"; else st_fail "lock: pid-less lock (rc=$lr, $el s)"; fi
    cache_unlock
    #   c) lock of a LIVE collector pid is waited for (not broken while it lives), broken once dead.
    #      A holder is a live process whose command line names this script (holder_alive), so the
    #      stand-ins below run as `sh -c '...' "$SELF_BASE"` ("sleep N; exit 0": a lone command
    #      would be exec'ed by bash and the name lost).
    sh -c 'sleep 2; exit 0' "$SELF_BASE" & spid=$!
    mkdir "$lk" && printf '%s\n' "$spid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s); el=$((t1-t0))
    wait "$spid" 2>/dev/null
    if [ "$lr" = "0" ] && [ "$el" -ge 1 ] && [ "$el" -le 10 ]; then st_pass "lock: live holder waited for ($el s), broken once dead"; else st_fail "lock: live holder (rc=$lr, $el s)"; fi
    cache_unlock
    #   d) ordering: a holder (own pid, 3 s critical section) appends its line BEFORE releasing;
    #      an add_vendor started meanwhile must merge AFTER it (a spin-count break would invert this)
    vreset
    sh -c 'mkdir "$1" && printf "%s\n" "$$" > "$1/pid"; sleep 3; printf "ZZZZZZ\tHolder\n" >> "$2"; rm -f "$1/pid"; rmdir "$1"' "$SELF_BASE" "$lk" "$OUI_CACHE" &
    hpid=$!
    sleep 1
    t0=$(date +%s)
    out=$(vbase)
    t1=$(date +%s); el=$((t1-t0))
    wait "$hpid" 2>/dev/null
    hl=$(grep -n 'Holder' "$OUI_CACHE" | head -1 | cut -d: -f1); al=$(grep -n '^A8BBCC' "$OUI_CACHE" | head -1 | cut -d: -f1)
    if [ -n "$hl" ] && [ -n "$al" ] && [ "$hl" -lt "$al" ] && [ "$el" -ge 1 ]; then
        st_pass "lock: waited for the live holder ($el s); holder's line precedes ours"
    else st_fail "lock: live holder overtaken (holder line ${hl:-none}, ours ${al:-none}, waited $el s)"; fi
    check "lock: output complete after waiting"          "$out" '"vendor": "Acme Networks"'
    if [ ! -d "$lk" ] && [ -z "$(ls -d "$lk".stale.* 2>/dev/null)" ]; then st_pass "lock: nothing left behind"; else st_fail "lock: leftovers"; fi
    #   e) pid reuse: the pid in a left-over lock (persistent OUTDIR across a reboot / kill -9, pid
    #      wrap) now belongs to a LIVE process that is NOT this collector -> no holder, broken at
    #      once (judged by pid alone it would block every cycle for the whole budget, for good)
    sleep 30 & fpid=$!
    mkdir "$lk" && printf '%s\n' "$fpid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
    if [ "$lr" = "0" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ $((t1-t0)) -le 1 ]; then
        st_pass "lock: live FOREIGN pid (pid reuse) is no holder: broken at once"
    else st_fail "lock: foreign live pid (rc=$lr, $((t1-t0)) s)"; fi
    #   f) re-entrant: a nested cache_lock in the SAME process returns at once; the lock is released
    #      only by the matching (outer) cache_unlock
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    if [ "$lr" = "0" ] && [ "$CACHE_LOCKED" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: nested cache_lock re-enters at once (depth 2)"; else st_fail "lock: nested cache_lock (rc=$lr, depth $CACHE_LOCKED, $((t1-t0)) s)"; fi
    cache_unlock
    if [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ "$CACHE_LOCKED" = "1" ]; then st_pass "lock: inner unlock keeps the lock (depth 1)"; else st_fail "lock: inner unlock released the lock"; fi
    cache_unlock
    if [ ! -d "$lk" ] && [ "$CACHE_LOCKED" = "0" ]; then st_pass "lock: outer unlock releases it"; else st_fail "lock: outer unlock"; fi
    #   g) cache_unlock must never remove a lock that is not ours, even when this process believes
    #      it holds one (a waiter broke ours while we were stopped and holds it now)
    sh -c 'sleep 5; exit 0' "$SELF_BASE" & fh=$!
    mkdir "$lk" && printf '%s\n' "$fh" > "$lk/pid"
    CACHE_LOCKED=1; cache_unlock
    if [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$fh" ]; then st_pass "lock: unlock leaves a foreign lock alone"; else st_fail "lock: unlock removed a foreign lock"; fi
    kill "$fh" 2>/dev/null; wait "$fh" 2>/dev/null; rm -rf "$lk"
    #   h) the merge re-checks the header under the lock: lines gathered from the OLD OUI file must
    #      not land under a header setup_vendor has meanwhile written for a NEW one
    vreset
    printf '102233\tClient Corp\n' > "$tdir/newf-hdr"
    save_hdr=$OUI_HDR; OUI_HDR="# oui=$tdir/some-other-file.txt size=1 mtime=1"
    cache_append "$tdir/newf-hdr"; OUI_HDR=$save_hdr
    checkno "lock: merge skipped when the cache was restarted for another file meanwhile" "$(cat "$OUI_CACHE")" '^102233'
    if [ ! -d "$lk" ]; then st_pass "lock: released after the skipped merge"; else st_fail "lock: left behind after the skipped merge"; fi
    #   i) cache_append itself repairs an unterminated cache before appending (no fused line)
    vreset; printf 'A8BBCC\tAcme Net' >> "$OUI_CACHE"
    cache_append "$tdir/newf-hdr"
    cc=$(cat "$OUI_CACHE")
    checkno "cache: merge drops the cut-off line first"      "$cc" 'Acme Net'
    check   "cache: merge appends after the repair"          "$cc" "^102233${RECON_TAB}Client Corp\$"
    if cache_terminated; then st_pass "cache: whole after repair + merge"; else st_fail "cache: unterminated after repair + merge"; fi
    #   j) budget + backoff: a live collector holding the lock longer than LOCK_BUDGET (shortened
    #      here) makes cache_lock give up (rc 2), log ONCE, and skip further lock attempts for 60 s
    #      without waiting; a later success re-arms the log
    sh -c 'sleep 6; exit 0' "$SELF_BASE" & lh=$!
    mkdir "$lk" && printf '%s\n' "$lh" > "$lk/pid"
    save_budget=$LOCK_BUDGET; LOCK_BUDGET=20; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    t0=$(date +%s); cache_lock 2>"$tdir/log11j"; lr=$?; t1=$(date +%s); el=$((t1-t0))
    if [ "$lr" = "2" ] && [ "$el" -ge 1 ] && [ "$el" -le 5 ]; then st_pass "lock: live holder past the budget -> rc 2 after $el s"; else st_fail "lock: budget (rc=$lr, $el s)"; fi
    t0=$(date +%s); cache_lock 2>>"$tdir/log11j"; lr=$?; t1=$(date +%s)
    if [ "$lr" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: backoff -> next attempt gives up at once"; else st_fail "lock: backoff (rc=$lr, $((t1-t0)) s)"; fi
    cache_repair 2>>"$tdir/log11j"; cache_append "$tdir/newf-hdr" 2>>"$tdir/log11j"
    nl=$(grep -c 'vendor cache lock' "$tdir/log11j")
    if [ "$nl" = "1" ]; then st_pass "lock: give-up logged exactly once per episode"; else st_fail "lock: give-up logged x$nl"; fi
    check "lock: log names the holder and the budget" "$(cat "$tdir/log11j")" "held by live pid $lh for over 2 s"
    LOCK_BUDGET=$save_budget; LOCK_BUSY_UNTIL=0
    kill "$lh" 2>/dev/null; wait "$lh" 2>/dev/null; rm -rf "$lk"
    cache_lock; lr=$?
    if [ "$lr" = "0" ] && [ "$LOCK_BUSY_LOGGED" = "0" ]; then st_pass "lock: taken again after the episode (log re-armed)"; else st_fail "lock: after episode (rc=$lr)"; fi
    cache_unlock
    #   k) UNBREAKABLE stale lock (dead pid) on a directory that cannot be written (ro remount):
    #      cache_lock / cache_repair must return at once, not spin through the budget
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
        mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
        printf 'A8BBCC\tcut' >> "$OUI_CACHE"                   # also damaged: cache_repair wants the lock
        chmod 555 "$CAPDIR" 2>/dev/null
        LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
        t0=$(date +%s); cache_lock 2>/dev/null; lr=$?; cache_repair 2>/dev/null; t1=$(date +%s)
        chmod 755 "$CAPDIR" 2>/dev/null
        if [ "$lr" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: unbreakable lock on a read-only directory -> give up at once (rc 2, $((t1-t0)) s)"; else st_fail "lock: ro dir + stale lock (rc=$lr, $((t1-t0)) s)"; fi
        LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0; rm -rf "$lk"
        cache_repair
        if cache_terminated; then st_pass "cache: repaired once writable again"; else st_fail "cache: still damaged after ro episode"; fi
    else
        log "  SKIP: lock: read-only directory via chmod (no effect for root)"
    fi
    #   l) daemon start-up sweep: temp files and the lock of a pid that is no live collector go,
    #      those of a live collector (our own pid runs this script) stay
    sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
    mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
    : > "$OUI_CACHE.new.$dpid.abc"; : > "$OUI_CACHE.fix.$dpid"; : > "$OUI_CACHE.new.$$.abc"; mkdir "$lk.stale.xyz"
    sweep_stale_cache_files 2>"$tdir/log11l"
    if [ ! -d "$lk" ] && [ ! -e "$OUI_CACHE.new.$dpid.abc" ] && [ ! -e "$OUI_CACHE.fix.$dpid" ] && [ ! -d "$lk.stale.xyz" ] && [ -e "$OUI_CACHE.new.$$.abc" ]; then
        st_pass "sweep: dead pid's lock + temp files removed, live collector's kept"
    else st_fail "sweep: lock=$([ -d "$lk" ] && echo kept || echo gone) new.dead=$([ -e "$OUI_CACHE.new.$dpid.abc" ] && echo kept || echo gone) new.own=$([ -e "$OUI_CACHE.new.$$.abc" ] && echo kept || echo gone)"; fi
    check "sweep: stale lock removal is logged" "$(cat "$tdir/log11l")" "removing stale vendor cache lock left by pid $dpid"
    rm -f "$OUI_CACHE.new.$$.abc"
    mkdir "$lk" && printf '%s\n' "$$" > "$lk/pid"
    sweep_stale_cache_files 2>/dev/null
    if [ -d "$lk" ]; then st_pass "sweep: lock of a live collector kept"; else st_fail "sweep: removed a live collector's lock"; fi
    rm -rf "$lk"
    #   m) pidfiles are believed only while their pid still runs what was started (a pid reused after a reboot): a pidfile
    #      naming a foreign live process is dropped by --stop without a signal and reads "not running"; our own loop and
    #      airodump (stand-ins whose command lines name this script and airodump) are seen and stopped. Every process here is
    #      double-forked, so none of them lingers as a zombie of this shell.
    mkdir -p "$tdir/own"
    # shellcheck disable=SC2016  # script text for the stand-ins: each ends when its file or this shell is gone (an interrupted run leaves no loop named like the collector)
    printf 'while [ -f "$0" ] && kill -0 %s 2>/dev/null; do sleep 1; done\n' "$$" > "$tdir/own/$SELF_BASE"; cp "$tdir/own/$SELF_BASE" "$tdir/own/airodump-ng"
    ( sleep 30 >/dev/null 2>&1 & echo $! > "$tdir/own/f.pid" )
    ( sh "$tdir/own/$SELF_BASE" </dev/null >/dev/null 2>&1 & echo $! > "$tdir/own/l.pid" )
    ( sh "$tdir/own/airodump-ng" </dev/null >/dev/null 2>&1 & echo $! > "$tdir/own/a.pid" )
    fpid=$(cat "$tdir/own/f.pid"); opid=$(cat "$tdir/own/l.pid"); apid=$(cat "$tdir/own/a.pid")
    pl_save=$LOOP_PIDFILE; pa_save=$AIRODUMP_PIDFILE; LOOP_PIDFILE="$tdir/own/loop.pid"; AIRODUMP_PIDFILE="$tdir/own/ad.pid"
    printf '%s\n' "$fpid" > "$LOOP_PIDFILE"; printf '%s\n' "$fpid" > "$AIRODUMP_PIDFILE"
    sout=$(status_pidfile loop "$LOOP_PIDFILE" "$SELF_BASE" 2>&1; status_pidfile airodump "$AIRODUMP_PIDFILE" airodump 2>&1)
    stopped=0
    stop_pidfile "$LOOP_PIDFILE" "collector loop" "$SELF_BASE" 2>/dev/null; stop_pidfile "$AIRODUMP_PIDFILE" airodump airodump 2>/dev/null
    if pid_alive "$fpid" && [ "$stopped" = 0 ] && [ ! -e "$LOOP_PIDFILE" ] && [ ! -e "$AIRODUMP_PIDFILE" ] \
       && [ "$(printf '%s\n' "$sout" | grep -c 'not running$')" = 2 ]; then
        st_pass "stop/status: a pidfile naming a foreign process (pid reuse) -> no signal, file dropped, 'not running'"
    else st_fail "stop/status: foreign pid $fpid alive=$(pid_alive "$fpid" && echo yes || echo no) stopped=$stopped status=[$sout]"; fi
    printf '%s\n' "$opid" > "$LOOP_PIDFILE"; printf '%s\n' "$apid" > "$AIRODUMP_PIDFILE"
    sout=$(status_pidfile loop "$LOOP_PIDFILE" "$SELF_BASE" 2>&1; status_pidfile airodump "$AIRODUMP_PIDFILE" airodump 2>&1)
    stop_pidfile "$LOOP_PIDFILE" "collector loop" "$SELF_BASE" 2>/dev/null; stop_pidfile "$AIRODUMP_PIDFILE" airodump airodump 2>/dev/null
    n=0; while { pid_alive "$opid" || pid_alive "$apid"; } && [ "$n" -lt 25 ]; do sleep 0.2 2>/dev/null || sleep 1; n=$((n + 1)); done
    if ! pid_alive "$opid" && ! pid_alive "$apid" && [ "$stopped" = 1 ] \
       && printf '%s\n' "$sout" | grep -q "loop RUNNING (pid $opid)" && printf '%s\n' "$sout" | grep -q "airodump RUNNING (pid $apid)"; then
        st_pass "stop/status: our own loop and airodump are seen running and stopped"
    else st_fail "stop/status: own loop $opid / airodump $apid: stopped=$stopped status=[$sout]"; fi
    LOOP_PIDFILE=$pl_save; AIRODUMP_PIDFILE=$pa_save
    #   n) the daemon's start-up sweep of temporary output files: those of a dead pid, or of a pid that now runs something
    #      else (reused after a reboot), go; a live run's stay (a --once may be mid-cycle); a name without a pid is not ours
    of_save=$OUTFILE; OUTFILE="$tdir/own/starchorus.json"
    : > "$OUTFILE.tmp.$dpid"; : > "$OUTFILE.tmp.$dpid.v"; : > "$OUTFILE.tmp.$fpid"; : > "$OUTFILE.tmp.$$"; : > "$OUTFILE.tmp.$$.c"; : > "$OUTFILE.tmp.x"
    sweep_stale_tmp
    if [ ! -e "$OUTFILE.tmp.$dpid" ] && [ ! -e "$OUTFILE.tmp.$dpid.v" ] && [ ! -e "$OUTFILE.tmp.$fpid" ] \
       && [ -e "$OUTFILE.tmp.$$" ] && [ -e "$OUTFILE.tmp.$$.c" ] && [ -e "$OUTFILE.tmp.x" ]; then
        st_pass "sweep: starchorus.json.tmp.* of a dead or foreign pid removed, a live run's kept"
    else st_fail "sweep: tmp files left: $(cd "$tdir/own" && printf '%s ' starchorus.json.tmp.*)"; fi
    kill "$fpid" "$opid" "$apid" 2>/dev/null
    rm -rf "$tdir/own"; OUTFILE=$of_save
    # (12) the loader must not trust a cut-off last cache line when cache_repair could not drop it
    #      (unwritable directory): the shell passes SC_TERM, the awk commits lines one behind
    vreset; printf 'A8BBCC\tAcme Net' >> "$OUI_CACHE"
    out=$(printf '%s\n' "$base" | SC_CACHE="$OUI_CACHE" SC_OUI="" SC_NEWF="" SC_TERM=0 awk "$AWK_JSON_HELPERS$AWK_VENDOR" 2>/dev/null)
    checkno "loader: cut-off last line ignored when unrepaired (SC_TERM=0)" "$out" 'Acme Net"'
    out=$(printf '%s\n' "$base" | SC_CACHE="$OUI_CACHE" SC_OUI="" SC_NEWF="" SC_TERM=1 awk "$AWK_JSON_HELPERS$AWK_VENDOR" 2>/dev/null)
    check   "loader: same line served when the cache is whole (SC_TERM=1)"  "$out" '"vendor": "Acme Net"'
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        chmod 555 "$CAPDIR" 2>/dev/null
        out=$(vbase); jrc=$?
        chmod 755 "$CAPDIR" 2>/dev/null
        checkno "loader: ro CAPDIR + cut-off line -> not served (rc $jrc)"   "$out" 'Acme Net"'
        check   "loader: ro CAPDIR + cut-off line -> resolved from the file" "$out" '"vendor": "Acme Networks"'
        if ! cache_terminated; then st_pass "cache: ro CAPDIR -> nothing appended onto the cut-off line"; else st_fail "cache: ro CAPDIR -> cache was written"; fi
    fi
    cache_repair
    if cache_terminated; then st_pass "cache: repaired once the directory is writable again"; else st_fail "cache: repair failed"; fi
    # (13) a post-pass that FAILS after gathering its lines (rc != 0 -- here: a closed stdout, the
    #      stand-in for ENOSPC on /tmp or a killed awk) must merge nothing: run_cycle discards that
    #      JSON, and its temp file may hold a cut-off line
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '%s\n' "$base" | add_vendor >&- 2>/dev/null; jrc=$?
    if [ "$jrc" != "0" ]; then
        if [ "$(grep -vc '^#' "$OUI_CACHE")" = "0" ]; then st_pass "cache: failed post-pass (rc $jrc) merged nothing"; else st_fail "cache: failed post-pass (rc $jrc) merged lines"; fi
    else log "  SKIP: cache: failed post-pass (awk here returns 0 on a closed stdout)"; fi
    if [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ]; then st_pass "cache: temp file removed after a failed pass"; else st_fail "cache: temp file left after a failed pass"; fi
    # (14) a cache that is EMPTY (a header cut short by ENOSPC and dropped by the repair), one whose
    #      header lacks its newline, or one that is GONE (tmpfs cleaner) must be rebuilt by the very
    #      next merge -- not first by the daemon's 120-cycle re-check (until then every cycle would
    #      scan the whole OUI file, take the lock and rewrite nothing)
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    for cs in empty noeol gone; do
        case "$cs" in
            empty) : > "$OUI_CACHE" ;;
            noeol) printf '%s' "$OUI_HDR" > "$OUI_CACHE" ;;
            gone)  rm -f "$OUI_CACHE" ;;
        esac
        out=$(vbase)
        check  "cache($cs): vendor delivered"                     "$out" '"vendor": "Acme Networks"'
        checkf "cache($cs): header rewritten by the merge"        "$(head -n 1 "$OUI_CACHE" 2>/dev/null)" "$OUI_HDR"
        check  "cache($cs): entries appended under it"            "$(cat "$OUI_CACHE" 2>/dev/null)" "^A8BBCC${RECON_TAB}Acme Networks\$"
        nh=$(grep -c '^#' "$OUI_CACHE" 2>/dev/null)
        if [ "$nh" = "1" ] && cache_terminated; then st_pass "cache($cs): exactly one header, whole file"; else st_fail "cache($cs): headers x$nh"; fi
    done
    # (15) publication is decoupled from the merge: with the cache lock held by another live
    #      collector, run_cycle must publish the JSON (with vendor) BEFORE it waits for the lock. The holder lives for the whole test
    #      (killed below) and the budget is 5 s, so the cycle's own run time (a second or two on the device's CPU) cannot decide whether
    #      the holder is still there; the publication is judged against the end of the cycle (at least 3 s earlier), not against a clock.
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset          # cold: there will be lines to merge
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; rm -f "$OUTFILE"
    sh -c 'sleep 60; exit 0' "$SELF_BASE" & lh=$!
    mkdir "$lk" && printf '%s\n' "$lh" > "$lk/pid"
    save_budget=$LOCK_BUDGET; LOCK_BUDGET=50; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    t0=$(date +%s)
    run_cycle 2>/dev/null &
    cpid=$!
    pub=""
    while [ $(($(date +%s) - t0)) -lt 40 ]; do
        if grep -q '"vendor": "Acme Networks"' "$OUTFILE" 2>/dev/null && [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$lh" ]; then pub=$(date +%s); break; fi
        sleep 0.2 2>/dev/null || sleep 1
    done
    wait "$cpid" 2>/dev/null; t1=$(date +%s)
    if [ -n "$pub" ] && [ $((t1-pub)) -ge 3 ]; then st_pass "run_cycle: JSON published while the cache lock was still held ($((t1-pub)) s before the cycle ended)"; else st_fail "run_cycle: publication waited for the lock (published at ${pub:-never}, cycle ended at $t1)"; fi
    if [ $((t1-t0)) -ge 4 ]; then st_pass "run_cycle: the merge itself waited for the lock ($((t1-t0)) s, budget 5)"; else st_fail "run_cycle: merge did not wait ($((t1-t0)) s)"; fi
    if [ "$(grep -vc '^#' "$OUI_CACHE")" = "0" ]; then st_pass "run_cycle: nothing merged under a foreign live lock"; else st_fail "run_cycle: merged under a foreign live lock ($(grep -vc '^#' "$OUI_CACHE") lines, cycle $((t1-t0)) s, published after ${pub:+$((pub-t0))} s)"; fi
    if [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ]; then st_pass "run_cycle: deferred temp file removed"; else st_fail "run_cycle: deferred temp file left"; fi
    LOCK_BUDGET=$save_budget; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    kill "$lh" 2>/dev/null; wait "$lh" 2>/dev/null; rm -rf "$lk"
    run_cycle 2>/dev/null
    check "run_cycle: merged once the lock is free" "$(cat "$OUI_CACHE")" "^A8BBCC${RECON_TAB}Acme Networks\$"

    # ---- 6j) the OUI index (the OUI file split by first octet, see oui_index): the same answers as a pass over the file, without the file
    st_count() { set -- "$1"/*; if [ -e "$1" ]; then echo $#; else echo 0; fi; }      # entries in directory $1
    ox="$tdir/oui-ix.txt"
    { printf '# test file: every shape the parser accepts\n'
      printf 'A8BBCC Acme Networks\nA8BBCC Duplicate Must Lose\na8bbcd lower case hex\nA8-BB-CE Dash Corp\nA8:BB:CF Colon Corp\nA8 BB D0 Space Corp\n'
      printf 'A8BBD1\tTab Corp\r\n0055DA0 Skip MA-M\n70B3D5001 Skip MA-S\n102233 Client Corp\n'
      printf 'A8-BB-D2   (hex)\t\tIEEE Hex Corp\nA8BBD2     (base 16)\t\tIEEE Hex Corp Again\n'
      printf 'ZZ not a prefix\n\n00:50:56\tVMware\tVMware, Inc.\nA8BBD3 Acme "Q" \\ Corp\nA8-ZZ-CC junk\nA8\tno prefix\n'; } > "$ox"
    oxd=$(printf '{\n  "generated": 1,\n  "aps": [\n'
          for oxp in a8:bb:cc a8:bb:cd a8:bb:ce a8:bb:cf a8:bb:d0 a8:bb:d1 a8:bb:d2 a8:bb:d3 10:22:33 00:50:56 00:55:da 70:b3:d5 11:11:11; do
              printf '    {"bssid": "%s:00:00:01", "ssid": "x"},\n' "$oxp"
          done
          printf '    {"bssid": "a8:bb:cc:00:00:02", "ssid": "y"}\n  ]\n}\n')
    VENDOR_STATE=""; OUI_FILE="$ox"; setup_vendor 2>"$tdir/log6j"
    if [ -n "$OUI_IDX" ] && oui_index_ok && [ "$(st_count "$OUI_IDX")" = "257" ]; then st_pass "index: built beside the cache, 256 buckets and hdr, hdr names the OUI file"; else st_fail "index: not built ($OUI_IDX)"; fi
    check "index: the build is logged with the size of what it indexed" "$(cat "$tdir/log6j")" 'vendor index: 16 lines of'
    check "index: the lookup line names it" "$(cat "$tdir/log6j")" 'vendor lookup: .* (index '
    if [ "$(cat "$OUI_IDX"/?? | wc -l | tr -d ' ')" = "16" ] && [ "$(cat "$OUI_IDX/A8" | wc -l | tr -d ' ')" = "12" ] && grep -q "^A8BBCC Duplicate" "$OUI_IDX/A8"; then
        st_pass "index: bucket A8 holds its lines as they stand in the file (duplicates kept, in file order); comments, blank and non-hex lines are not indexed"
    else st_fail "index: bucket contents ($(cat "$OUI_IDX"/?? | wc -l | tr -d ' ') lines)"; fi
    vreset; oxi=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxic=$(grep -v '^#' "$OUI_CACHE" | sort)
    save_ix=$OUI_IDX; OUI_IDX=""; vreset; oxs=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxsc=$(grep -v '^#' "$OUI_CACHE" | sort); OUI_IDX=$save_ix
    if [ "$oxi" = "$oxs" ] && [ "$oxic" = "$oxsc" ] && [ -n "$oxic" ]; then st_pass "index: the document and the cache lines are byte-identical to those of a pass over the OUI file"; else st_fail "index: differs from the pass over the file"; fi
    jcheck "index:" "$oxi"
    checkf "index: first line for a prefix wins, vendor escaped"   "$oxi" '"bssid": "a8:bb:cc:00:00:01", "vendor": "Acme Networks"'
    checkf "index: lower-case hex line found"                      "$oxi" '"bssid": "a8:bb:cd:00:00:01", "vendor": "lower case hex"'
    checkf "index: dash, colon and space forms"                    "$oxi" '"vendor": "Dash Corp"'
    checkf "index: CRLF line"                                      "$oxi" '"vendor": "Tab Corp"'
    checkf "index: (hex) line wins over the (base 16) line"        "$oxi" '"vendor": "IEEE Hex Corp"'
    checkf "index: quote and backslash escaped"                    "$oxi" '"vendor": "Acme \"Q\" \\ Corp"'
    checkf "index: last tab field of a manuf line"                 "$oxi" '"vendor": "VMware, Inc."'
    checkno "index: MA-M / MA-S lines give no vendor"              "$(line_of "$oxi" '00:55:da:00:00:01')$(line_of "$oxi" '70:b3:d5:00:00:01')" '"vendor"'
    check  "index: a prefix the file lacks is a negative entry"    "$oxic" "^111111${RECON_TAB}\$"
    # an octet with many lines (here: more than 3) is split by its first two octets: one file per second octet, the lines that cannot be accepted dropped
    save_max=$OUI_IDX_MAX; OUI_IDX_MAX=3; rm -rf "$CAPDIR/oui-index"; setup_vendor 2>/dev/null; OUI_IDX_MAX=$save_max
    if [ -n "$OUI_IDX" ] && oui_index_ok && [ "$(st_count "$OUI_IDX")" = "512" ] && [ "$(sed -n 2p "$OUI_IDX/hdr")" = "A8" ] && [ ! -e "$OUI_IDX/A8" ] \
       && [ "$(cat "$OUI_IDX/A8BB" | wc -l | tr -d ' ')" = "10" ] && [ "$(cat "$OUI_IDX"/[0-9A-F][0-9A-F]* | wc -l | tr -d ' ')" = "14" ]; then
        st_pass "index: an octet with more than OUI_IDX_MAX lines is split by its first two octets (A8 -> A8BB with its 10 lines, the 2 unacceptable lines dropped), hdr names it"
    else st_fail "index: split octet ($(st_count "$OUI_IDX") files, hdr [$(sed -n 2p "$OUI_IDX/hdr")])"; fi
    vreset; oxh=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxhc=$(grep -v '^#' "$OUI_CACHE" | sort)
    if [ "$oxh" = "$oxi" ] && [ "$oxhc" = "$oxic" ]; then st_pass "index: with a split octet the document and the cache lines are the same as from a pass over the OUI file"; else st_fail "index: split octet differs from the pass over the file"; fi
    rm -f "$OUI_IDX/A8BB"
    vreset; oxh=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxhc=$(grep -v '^#' "$OUI_CACHE" | sort)
    if [ "$oxh" = "$oxi" ] && [ "$oxhc" = "$oxic" ] && ! oui_index_ok; then st_pass "index: a file of a split octet gone -> not ok, the OUI file is scanned, same answers"; else st_fail "index: split octet damaged"; fi
    rm -rf "$CAPDIR/oui-index"; setup_vendor 2>/dev/null
    # no OUI file, same answers: the stick is gone, the index (on flash, beside the cache) is not
    mv "$ox" "$ox.away"; OUI_PATH="$ox"
    vreset; oxg=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxgc=$(grep -v '^#' "$OUI_CACHE" | sort)
    mv "$ox.away" "$ox"
    if [ "$oxg" = "$oxi" ] && [ "$oxgc" = "$oxic" ]; then st_pass "index: with the OUI file gone the same document and the same cache lines (the index serves)"; else st_fail "index: OUI file gone"; fi
    # a damaged index is no error: the awk scans the OUI file, and the answers stay the same
    for ixd in "bucket:rm -f $OUI_IDX/A8" "hdr:printf '# oui=elsewhere size=1 mtime=1\\n' > $OUI_IDX/hdr" "nohdr:rm -f $OUI_IDX/hdr"; do
        eval "${ixd#*:}"
        vreset; oxd1=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); oxdc=$(grep -v '^#' "$OUI_CACHE" | sort)
        if [ "$oxd1" = "$oxi" ] && [ "$oxdc" = "$oxic" ]; then st_pass "index: damaged (${ixd%%:*}) -> the OUI file is scanned, same answers"; else st_fail "index: damaged (${ixd%%:*}) gives other answers"; fi
        setup_vendor 2>/dev/null
        if oui_index_ok && [ "$(st_count "$OUI_IDX")" = "257" ]; then st_pass "index: damaged (${ixd%%:*}) -> rebuilt by the next setup_vendor"; else st_fail "index: not rebuilt after damage (${ixd%%:*})"; fi
    done
    # an unreadable OUI file with a damaged index and a new prefix: nothing is known, so no negative entry (as in 6h)
    rm -f "$OUI_IDX/A8"; OUI_PATH="$tdir/oui-gone.txt"; vreset
    printf '%s\n' "$oxd" | add_vendor >/dev/null 2>&1
    checkno "index: damaged index and no OUI file -> no negative entry for a prefix that is in the file" "$(cat "$OUI_CACHE")" "^A8BBCC${RECON_TAB}\$"
    OUI_PATH="$ox"; setup_vendor 2>/dev/null
    # the OUI file changes (new size): a new index, with the new content
    printf 'CCDDEE New Corp\n' >> "$ox"; setup_vendor 2>/dev/null
    out=$(printf '    {"bssid": "cc:dd:ee:00:00:01", "ssid": "z"}\n' | add_vendor 2>/dev/null)
    if oui_index_ok && printf '%s' "$out" | grep -q '"vendor": "New Corp"'; then st_pass "index: a changed OUI file gets a new index (and the cache restarts)"; else st_fail "index: changed OUI file"; fi
    # two instances starting together (a daemon and a crond --once): one index, whole, no build directory or lock left
    rm -rf "$CAPDIR/oui-index"
    ( setup_vendor >/dev/null 2>&1 ) & ( setup_vendor >/dev/null 2>&1 ) & wait
    if oui_index_ok && [ "$(st_count "$CAPDIR/oui-index")" = "257" ] && [ -z "$(ls -d "$CAPDIR"/oui-index.new.* "$OUI_CACHE".lock 2>/dev/null)" ]; then st_pass "index: two instances building at once leave one whole index, no build directory, no lock"; else st_fail "index: parallel build ($(echo "$CAPDIR"/*))"; fi
    # start-up sweep: the build directory of a dead collector goes, that of a live one stays
    sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
    mkdir "$CAPDIR/oui-index.new.$dpid.abc" "$CAPDIR/oui-index.new.$$.abc"
    sweep_stale_cache_files 2>/dev/null
    if [ ! -d "$CAPDIR/oui-index.new.$dpid.abc" ] && [ -d "$CAPDIR/oui-index.new.$$.abc" ]; then st_pass "sweep: an index build directory of a dead collector removed, a live collector's kept"; else st_fail "sweep: index build directories"; fi
    rm -rf "$CAPDIR/oui-index.new.$$.abc"
    # an index that cannot be built (here: no mktemp -d) is no error either: one warning, the lookups scan the file, the answers are the same
    mkdir -p "$tdir/nomk"; printf '#!/bin/sh\nexit 1\n' > "$tdir/nomk/mktemp"; chmod +x "$tdir/nomk/mktemp"
    rm -rf "$CAPDIR/oui-index"; VENDOR_STATE=""
    ix_path=$PATH; PATH="$tdir/nomk:$PATH"; setup_vendor 2>"$tdir/log6j2"; vreset; oxm=$(printf '%s\n' "$oxd" | add_vendor 2>/dev/null); PATH=$ix_path
    if [ -z "$OUI_IDX" ] && [ ! -d "$CAPDIR/oui-index" ] && [ "$oxm" = "$oxi" ]; then st_pass "index: cannot be built -> no index, the same document from the pass over the file"; else st_fail "index: build failure ($OUI_IDX)"; fi
    check "index: ... and says so once" "$(cat "$tdir/log6j2")" 'warning: no OUI index'
    rm -rf "$tdir/nomk"
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR_STATE=""; setup_vendor 2>/dev/null

    # ---- 6k) a crond `--once` finishing while the daemon's cycle is still emitting (on the device
    #          the DB copy + queries take a second or more, so the overlap is routine): its EXIT
    #          cleanup must touch only ITS OWN artefacts -- not the daemon's temp file (the daemon
    #          would then publish source=none for one interval), not the loop pidfile (--status
    #          "not running", --stop only via the ps backstop), not an airodump it did not start.
    #          A REAL second process is needed: a subshell shares $$ and could not tell them apart.
    if have sqlite3; then
        PIDDIR="$tdir"; LOOP_PIDFILE="$tdir/starchorus-loop.pid"; AIRODUMP_PIDFILE="$tdir/starchorus-airodump.pid"
        odb="$tdir/recon_once.db"
        sqlite3 "$odb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'A8BBCC0000CE','OnceNet',0,0,-50,2437,6,8);
SQL
        printf '%s\n' "$base" > "$tdir/base.json"
        printf '%s\n' "$$" > "$LOOP_PIDFILE"                       # the "daemon" (this process) is registered
        sleep 30 & fake_ad=$!; printf '%s\n' "$fake_ad" > "$AIRODUMP_PIDFILE"   # an airodump the --once did not start
        rm -f "$tdir/go"
        # the daemon's cycle: its emitter holds $OUTFILE.tmp.<pid> open until the go-file appears
        ( build_from_csv() { w=0; while [ ! -e "$tdir/go" ] && [ "$w" -lt 150 ]; do sleep 0.2 2>/dev/null || sleep 1; w=$((w+1)); done; cat "$tdir/base.json"; }
          VENDOR=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; run_cycle ) &
        dpid=$!
        sleep 1
        STARCHORUS_OUTDIR="$tdir" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$odb" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 \
            sh "$0" --once >"$tdir/once.out" 2>"$tdir/once.log"; orc=$?
        : > "$tdir/go"
        wait "$dpid" 2>/dev/null
        if [ "$orc" = "0" ] && grep -q 'single cycle complete' "$tdir/once.log"; then st_pass "once: real --once process ran a recondb cycle in the same OUTDIR"; else st_fail "once: --once rc=$orc ($(tail -n 1 "$tdir/once.log" 2>/dev/null))"; fi
        oj=$(cat "$tdir/starchorus.json" 2>/dev/null)
        check   "once: daemon's overlapping cycle still published its data" "$oj" '"ssid": "AcmeNet"'
        checkno "once: daemon's cycle was not turned into source=none"      "$oj" '"source": "none"'
        if [ "$(cat "$LOOP_PIDFILE" 2>/dev/null)" = "$$" ]; then st_pass "once: loop pidfile of the daemon survives a --once"; else st_fail "once: loop pidfile after --once: $([ -f "$LOOP_PIDFILE" ] && cat "$LOOP_PIDFILE" || echo MISSING)"; fi
        if [ -f "$AIRODUMP_PIDFILE" ] && pid_alive "$fake_ad"; then st_pass "once: airodump it did not start is left running (pidfile kept)"; else st_fail "once: foreign airodump killed / pidfile removed"; fi
        kill "$fake_ad" 2>/dev/null; wait "$fake_ad" 2>/dev/null; rm -f "$AIRODUMP_PIDFILE" "$LOOP_PIDFILE"
        set -- "$tdir"/starchorus.json.tmp.*
        if [ ! -e "$1" ]; then st_pass "once: no temp file left by either instance"; else st_fail "once: temp files left: $*"; fi

        # ---- 6k2) a document that is cut short, a directory that cannot be written, and what --once says about it. The base document is the one above
        #          (AcmeNet). Cycles run in subshells with a builder of their own (build_from_csv replaced); their stderr is the log.
        b3="$tdir/b3"; mkdir -p "$b3/ram" "$b3/bin"
        if doc_whole "$tdir/base.json" && ! head -c 200 "$tdir/base.json" | doc_whole - && ! sed '$d' "$tdir/base.json" | doc_whole - \
           && ! cat "$tdir/base.json" "$tdir/base.json" | doc_whole - && ! { echo x; cat "$tdir/base.json"; } | doc_whole - \
           && write_empty 1710000000 "no data" | doc_whole - && ! : | doc_whole -; then st_pass "doc_whole: a whole document and the explicit empty one pass; cut short, no closing line, two aps lines, a stray first line and nothing fail"
        else st_fail "doc_whole: shapes"; fi
        b3_run() {   # b3_run KIND: two cycles in a subshell (so that the once-per-episode flags carry over), with the builder (and what else) KIND names; prints "exit status/exit status"
            ( RESOLVED=capture; CAP_METHOD=airodump; VENDOR=0; OUTFILE="$b3/starchorus.json"; TMPDIR_RAM="$b3/ram"
              case $1 in
                  good)   build_from_csv() { cat "$tdir/base.json"; } ;;
                  cut)    build_from_csv() { head -c 300 "$tdir/base.json"; } ;;
                  noclose) build_from_csv() { sed '$d' "$tdir/base.json"; } ;;
                  double) build_from_csv() { cat "$tdir/base.json" "$tdir/base.json"; } ;;
                  tmpdir) build_from_csv() { cat "$tdir/base.json"; }; mkdir "$OUTFILE.tmp.$$" 2>/dev/null ;;
                  mvfail) build_from_csv() { cat "$tdir/base.json"; }; mv() { case "$*" in *starchorus.json) return 1 ;; esac; command mv "$@"; } ;;
              esac
              run_cycle >/dev/null 2>>"$b3/log"; b3_x=$?; run_cycle >/dev/null 2>>"$b3/log"; echo "$b3_x/$?" )
        }
        rm -f "$b3/starchorus.json" "$b3/log"; : > "$b3/log"
        b3_r0=$(b3_run good); cp "$b3/starchorus.json" "$b3/good.json" 2>/dev/null
        if [ "$b3_r0" = 0/0 ] && json_ok < "$b3/starchorus.json" && grep -q '"ssid": "AcmeNet"' "$b3/starchorus.json" && [ ! -s "$b3/log" ]; then st_pass "publish: a whole document is published (exit 0, nothing logged)"; else st_fail "publish: good cycle (rc $b3_r0, $(head -n 1 "$b3/log"))"; fi
        : > "$b3/log"; b3_r1=$(b3_run cut)
        if [ "$b3_r1" = 1/1 ] && cmp -s "$b3/starchorus.json" "$b3/good.json" && [ "$(grep -c 'came out incomplete' "$b3/log")" = 1 ]; then st_pass "publish: a document cut short by an awk that still exits 0 is not published (the last one stays, exit 1, one log line over two cycles)"; else st_fail "publish: cut-off document (rc $b3_r1, same: $(cmp -s "$b3/starchorus.json" "$b3/good.json" && echo yes || echo no), lines $(grep -c 'incomplete' "$b3/log"))"; fi
        b3_r3=$(b3_run noclose)
        b3_r4=$(b3_run double)
        if [ "$b3_r3/$b3_r4" = 1/1/1/1 ] && cmp -s "$b3/starchorus.json" "$b3/good.json"; then st_pass "publish: whole lines without the closing brace, and two documents in one, are not published either"; else st_fail "publish: wrong shapes (rc $b3_r3 $b3_r4)"; fi
        : > "$b3/log"; b3_r5=$(b3_run tmpdir); rmdir "$b3"/starchorus.json.tmp.* 2>/dev/null
        if [ "$b3_r5" = 1/1 ] && cmp -s "$b3/starchorus.json" "$b3/good.json" && [ "$(grep -c 'cannot write' "$b3/log")" = 1 ] && ! grep -q 'cannot create' "$b3/log"; then st_pass "publish: a temp file that cannot be written (here: a directory in its place) -> the last document stays, exit 1, one line over two cycles, no shell error"; else st_fail "publish: unwritable temp file (rc $b3_r5, log: $(head -n 2 "$b3/log"))"; fi
        : > "$b3/log"; b3_r7=$(b3_run mvfail)
        if [ "$b3_r7" = 1/1 ] && cmp -s "$b3/starchorus.json" "$b3/good.json" && [ "$(grep -c "cannot write $b3/starchorus.json" "$b3/log")" = 1 ] && { set -- "$b3"/starchorus.json.tmp.*; [ ! -e "$1" ]; }; then st_pass "publish: a rename that fails -> the last document stays, exit 1, one log line over two cycles, no temp file left"; else st_fail "publish: failing rename (rc $b3_r7, log: $(head -n 2 "$b3/log"))"; fi
        rm -f "$b3/starchorus.json"; : > "$b3/log"; b3_r9=$(b3_run cut)
        if [ "$b3_r9" = 1/1 ] && json_ok < "$b3/starchorus.json" && grep -q '"source": "none"' "$b3/starchorus.json"; then st_pass "publish: a cut-off document with no earlier document to keep -> the explicit empty one is published (exit 1)"; else st_fail "publish: nothing to keep (rc $b3_r9)"; fi
        # the same in real processes: --once
        b3_o="$b3/once"; mkdir -p "$b3_o"; rm -f "$b3_o"/*
        b3_once() { STARCHORUS_OUTDIR="$b3_o" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$odb" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_TMPDIR="$b3/ram" sh "$0" --once; }
        b3_once >/dev/null 2>"$b3/once.log"; b3_c0=$?; cp "$b3_o/starchorus.json" "$b3/once-good.json" 2>/dev/null
        AWK_REAL=$(command -v awk); export AWK_REAL
        # shellcheck disable=SC2016  # the stand-in script text is written out literally
        printf '#!/bin/sh\nfor a in "$@"; do case $a in *doc_head*unassociated*) "$AWK_REAL" "$@" | head -c 300; exit 0 ;; esac; done\n"$AWK_REAL" "$@"\n' > "$b3/bin/awk"; chmod +x "$b3/bin/awk"
        b3_path=$PATH; PATH="$b3/bin:$PATH"; b3_once >/dev/null 2>"$b3/once2.log"; b3_c1=$?; PATH=$b3_path
        if [ "$b3_c0" = 0 ] && [ "$b3_c1" = 1 ] && cmp -s "$b3_o/starchorus.json" "$b3/once-good.json" && grep -q 'came out incomplete' "$b3/once2.log" && grep -q 'single cycle failed' "$b3/once2.log" && ! grep -q 'single cycle complete' "$b3/once2.log"; then
            st_pass "once: an awk that cuts the document short and exits 0 -> nothing is published, the previous file stays, exit 1, no \"single cycle complete\""
        else st_fail "once: cut-off document (rc $b3_c0/$b3_c1, $(tail -n 2 "$b3/once2.log" | tr '\n' '|'))"; fi
        rm -f "$b3/bin/awk"; unset AWK_REAL
        : > "$b3/afile"
        STARCHORUS_OUTDIR="$b3/afile/sub" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$odb" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 STARCHORUS_TMPDIR="$b3/ram" sh "$0" --once >/dev/null 2>"$b3/once3.log"; b3_c2=$?
        if [ "$b3_c2" = 1 ] && grep -q 'cannot create or write the output directory' "$b3/once3.log" && ! grep -q 'single cycle' "$b3/once3.log" && [ "$(grep -c . "$b3/once3.log")" = 1 ]; then
            st_pass "once: an output directory that cannot be made -> exit 1 with one message, no cycle, no \"single cycle complete\""
        else st_fail "once: unwritable OUTDIR (rc $b3_c2, $(tr '\n' '|' < "$b3/once3.log"))"; fi
    else
        log "  SKIP: once: overlap test needs sqlite3"
    fi

    # ---- 6l) kill_loops scope and honesty: one collector runs per device, so a start or a stop stops
    #          EVERY collector loop, not only this OUTDIR's. Each loop killed that is NOT this OUTDIR's
    #          own is logged with its pid and working directory; our own loop (named by the pidfile) is
    #          not double-reported; and a --once / --status run (a "--" on its command line) is never
    #          touched. The stand-in loops are real processes, but kill_loops sees them only through a
    #          stand-in `ps` that prints a fixed table in the BusyBox 1.36 `ps w` layout ("PID USER VSZ
    #          STAT COMMAND", COMMAND as "{starchorus-coll} /bin/sh ./starchorus-collect.sh" when the
    #          comm differs, or plain "sh /path/..."), with the recorded pids. So the real grep is checked
    #          against device-format lines, the real `ps` is never consulted (on the device it would list
    #          the operator's own collector), and a stand-in `readlink` answers /proc/PID/cwd from a map.
    #          Every wait is bounded; the stand-ins hold no inherited descriptor (a survivor would keep a caller's pipe open).
    klw="$tdir/klscope"; klbin="$klw/bin"; mkdir -p "$klbin" "$klw/d1" "$klw/d2" "$klw/own" "$klw/status"
    # shellcheck disable=SC2016  # script text for the stand-ins: each ends when its file or this shell is gone (an interrupted run leaves no loop named like the collector)
    printf '#!/bin/sh\nwhile [ -f "$0" ] && kill -0 %s 2>/dev/null; do sleep 1; done\n' "$$" > "$klw/d1/starchorus-collect.sh"
    for kd in d2 own status; do cp "$klw/d1/starchorus-collect.sh" "$klw/$kd/starchorus-collect.sh"; done
    chmod +x "$klw"/*/starchorus-collect.sh
    # shellcheck disable=SC2016   # script text for the stand-in, expanded when it runs
    printf '#!/bin/sh\n# stand-in BusyBox `ps w`: the prepared table\ncat "$KLTAB"\n' > "$klbin/ps"
    cat > "$klbin/readlink" <<'KLRL'
#!/bin/sh
# stand-in readlink: /proc/PID/cwd from $KLMAP (lines "PID DIR"); unmapped -> nothing, exit 1 (the fallback)
case $1 in
  /proc/*/cwd) klp=${1#/proc/}; klp=${klp%/cwd}
    awk -v k="$klp" '$1 == k { $1 = ""; sub(/^ /, ""); print; f = 1 } END { exit !f }' "$KLMAP" 2>/dev/null; exit $? ;;
esac
exit 1
KLRL
    chmod +x "$klbin/ps" "$klbin/readlink"
    # shellcheck disable=SC2086   # $2 is an optional flag (--status) or nothing
    # Detached (double fork): the stand-in is re-parented away from this shell, as another collector loop
    # would be, so kill_loops does not skip it as one of this run's own subshells (is_own_child).
    kl_spawn() {
        ( ( cd "$klw/$1" && exec sh "$klw/$1/starchorus-collect.sh" $2 ) </dev/null >/dev/null 2>&1 & echo $! > "$klw/spawn.pid" )
        klsp=$(cat "$klw/spawn.pid"); KLPIDS="$KLPIDS $klsp"
    }
    kl_wait() {   # kl_wait PID -> 0 once PID is gone, 1 after ~10 s (0.2 s polls)
        kli=0
        while kill -0 "$1" 2>/dev/null && [ "$kli" -lt 50 ]; do sleep 0.2 2>/dev/null || { sleep 1; kli=$((kli + 4)); }; kli=$((kli + 1)); done
        ! kill -0 "$1" 2>/dev/null
    }
    kl_cleanup() {   # kill every stand-in still alive by recorded pid; reap only the dead (never blocks)
        for klp in $KLPIDS; do kill -9 "$klp" 2>/dev/null; done
        for klp in $KLPIDS; do kl_wait "$klp" && wait "$klp" 2>/dev/null; done
    }
    KLPIDS=""
    exec 4>&2 2>/dev/null   # no job "Terminated" lines while stand-ins come and go
    kl_spawn d1; klf1=$klsp; kl_spawn d2; klf2=$klsp; kl_spawn own; klown=$klsp; kl_spawn status --status; klst=$klsp
    exec 2>&4 4>&-
    # The two decoy lines (a sleep, a grep) must be filtered out. Their pids lie above the kernel's pid ceiling (4194304), so no process has them: were the filter
    # to regress, kill_loops would signal nothing (pids 1 and 2 would be init and the kernel's thread daemon, signalled as root).
    {   printf '  PID USER       VSZ STAT COMMAND\n'
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klf1" "$klw"
        printf '%5s root      1508 S    sh %s/d2/starchorus-collect.sh\n' "$klf2" "$klw"
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh ./starchorus-collect.sh\n' "$klown"
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh ./starchorus-collect.sh --status\n' "$klst"
        printf '%5s root      1200 S    sleep 1\n' 4194305
        printf '%5s root      1200 S    grep starchorus-collect.sh\n' 4194306
    } > "$klw/ps.txt"
    printf '%s %s\n' "$klf1" "$klw/d1" > "$klw/proc.map"   # d1 mapped (its directory is reported); d2 unmapped (the fallback)
    export KLTAB="$klw/ps.txt" KLMAP="$klw/proc.map"
    klsave=$PATH; PATH="$klbin:$PATH"
    kill_loops stop "$klown" 2>"$klw/kl.log"           # the --stop path: own loop already reported by stop_pidfile
    PATH=$klsave
    exec 4>&2 2>/dev/null
    kl_wait "$klf1"; klr1=$?; kl_wait "$klf2"; klr2=$?; kl_wait "$klown"; klro=$?
    kill -0 "$klst" 2>/dev/null; klrs=$?
    for klp in "$klf1" "$klf2" "$klown"; do kill -0 "$klp" 2>/dev/null || wait "$klp" 2>/dev/null; done   # reap the dead only
    exec 2>&4 4>&-
    klbad=""
    [ "$klr1" = 0 ] || klbad="$klbad foreign1-alive-after-10s"
    [ "$klr2" = 0 ] || klbad="$klbad foreign2-alive-after-10s"
    [ "$klro" = 0 ] || klbad="$klbad own-alive-after-10s"
    [ "$klrs" = 0 ] || klbad="$klbad status-killed"
    grep -qF "also stopped collector loop pid $klf1 in $klw/d1 (one collector per device)" "$klw/kl.log" || klbad="$klbad no-foreign1-report"
    grep -qF "also stopped collector loop pid $klf2 in unknown directory (one collector per device)" "$klw/kl.log" || klbad="$klbad no-foreign2-fallback"
    grep -q "pid $klown " "$klw/kl.log" && klbad="$klbad own-double-reported"
    grep -q "pid $klst " "$klw/kl.log" && klbad="$klbad status-reported"
    grep -qE "pid (1|2|4194305|4194306) " "$klw/kl.log" && klbad="$klbad sleep-or-grep-line-matched"   # the decoys; 1 and 2 stay in, as nothing may ever report them
    if [ -z "$klbad" ]; then st_pass "kill_loops --stop (BusyBox ps w lines): foreign loops stopped and reported with directory (d1 named, d2 -> unknown directory); own loop not double-reported; --status untouched"; else st_fail "kill_loops --stop scope/honesty:$klbad"; fi
    # start-up "replace" wording: each loop replaced is reported (one collector per device)
    exec 4>&2 2>/dev/null
    kl_spawn d1; klf3=$klsp
    exec 2>&4 4>&-
    { printf '  PID USER       VSZ STAT COMMAND\n'; printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klf3" "$klw"; } > "$klw/ps.txt"
    printf '%s %s\n' "$klf3" "$klw/d1" > "$klw/proc.map"
    PATH="$klbin:$PATH"
    kill_loops replace 2>"$klw/kl2.log"
    PATH=$klsave
    exec 4>&2 2>/dev/null
    kl_wait "$klf3"; klr3=$?; kill -0 "$klf3" 2>/dev/null || wait "$klf3" 2>/dev/null
    exec 2>&4 4>&-
    klbad=""
    [ "$klr3" = 0 ] || klbad="$klbad foreign3-alive-after-10s"
    grep -qF "replaced collector loop pid $klf3 in $klw/d1: one collector per device" "$klw/kl2.log" || klbad="$klbad no-replace-report"
    if [ -z "$klbad" ]; then st_pass "kill_loops start-up: each replaced loop reported (one collector per device)"; else st_fail "kill_loops replace wording:$klbad"; fi
    # a subshell of THIS run looks like a loop in BusyBox `ps w` but is never one: skipped, not reported
    if [ -r "/proc/$$/status" ]; then
        exec 4>&2 2>/dev/null
        ( cd "$klw/d1" && exec sh "$klw/d1/starchorus-collect.sh" ) </dev/null >/dev/null 2>&1 & klch=$!
        exec 2>&4 4>&-
        { printf '  PID USER       VSZ STAT COMMAND\n'; printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klch" "$klw"; } > "$klw/ps.txt"
        : > "$klw/proc.map"
        PATH="$klbin:$PATH"
        kill_loops replace 2>"$klw/kl3.log"
        PATH=$klsave
        sleep 1
        if kill -0 "$klch" 2>/dev/null && ! grep -q "pid $klch " "$klw/kl3.log"; then
            st_pass "kill_loops: this run's own subshell is skipped and not reported"
        else st_fail "kill_loops: own subshell killed or reported"; fi
        exec 4>&2 2>/dev/null; kill -9 "$klch" 2>/dev/null; wait "$klch" 2>/dev/null; exec 2>&4 4>&-
    else
        log "  SKIP: kill_loops own-subshell case needs /proc"
    fi
    # The stand-ins of the Bluetooth window end by themselves, within seconds, when the tree they poll is removed or the shell they watch is gone (an interrupted run, see st_abort).
    # A scan stand-in (bt_stub makes two, one body) is run on its own in two trees, as the loops above are run (kl_spawn starts a script of this name in a directory of klscope),
    # the first tree removed and the pid the second watches (a sleep here) killed. A stand-in that is still there is killed by kl_cleanup.
    for klb in bs1 bs2; do mkdir -p "$klw/$klb/bin" "$klw/$klb/cfg" "$klw/$klb/log" "$klw/$klb/sig" "$klw/$klb/proc"; done
    exec 4>&2 2>/dev/null
    sleep 60 & klbw=$!
    bt_stub "$klw/bs1"; bt_stub "$klw/bs2" "$klbw"
    for klb in bs1 bs2; do for klf in "$klw/$klb/bin"/*; do cp "$klf" "$klw/$klb/starchorus-collect.sh"; done; done
    kl_spawn bs1; klb1=$klsp; kl_spawn bs2; klb2=$klsp
    sleep 1
    klb_up=0; kill -0 "$klb1" 2>/dev/null && kill -0 "$klb2" 2>/dev/null && klb_up=1
    rm -rf "$klw/bs1"; kill -9 "$klbw"; wait "$klbw"
    kl_wait "$klb1"; klb_d1=$?; kl_wait "$klb2"; klb_d2=$?
    exec 2>&4 4>&-
    if [ "$klb_up/$klb_d1/$klb_d2" = 1/0/0 ]; then st_pass "window stand-ins: a scan stand-in runs while its tree and its shell are there, and ends by itself once its tree is removed, and once its shell is gone"
    else st_fail "window stand-ins: ending by itself (up $klb_up, tree removed -> wait status $klb_d1, shell killed -> wait status $klb_d2; 0 = gone)"; fi
    exec 4>&2 2>/dev/null
    kl_cleanup
    exec 2>&4 4>&-
    klleft=""; for klp in $KLPIDS; do kill -0 "$klp" 2>/dev/null && klleft="$klleft $klp"; done
    if [ -z "$klleft" ]; then st_pass "kill_loops: no stand-in loop left running"; else st_fail "kill_loops: stand-ins still alive after kill -9:$klleft"; fi
    unset KLTAB KLMAP

    # ---- 6j) run_cycle must not publish a post-pass result that is structurally wrong even when
    #          the pass returned 0 (an awk write error not reflected in its exit code). The mutants
    #          replace add_vendor for the rest of the run (POSIX sh cannot copy a function back),
    #          so this block stays LAST.
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"
    add_vendor() { printf '{"partial": true\n'; return 0; }          # fewer lines, no closing brace
    run_cycle
    if json_ok < "$OUTFILE" && grep -q '"ssid": "AcmeNet"' "$OUTFILE" && ! grep -q partial "$OUTFILE"; then
        st_pass "run_cycle: truncated post-pass output (rc 0) discarded, emitter JSON published"
    else st_fail "run_cycle: truncated post-pass output published"; fi
    add_vendor() { sed '$d'; printf '"junk": 1\n'; return 0; }       # same line count, last line not "}"
    run_cycle
    if json_ok < "$OUTFILE" && grep -q '"ssid": "AcmeNet"' "$OUTFILE" && ! grep -q junk "$OUTFILE"; then
        st_pass "run_cycle: post-pass output without closing brace (rc 0) discarded"
    else st_fail "run_cycle: broken post-pass tail published"; fi

    trap - INT TERM HUP
    rm -rf "$tdir" 2>/dev/null
    if [ "$ST_FAILS" = "0" ]; then log "SELFTEST: ALL PASS ($ST_PASS checks)"; else log "SELFTEST: $ST_FAILS FAILURES, $ST_PASS passed (see above)"; fi
    [ "$ST_FAILS" = "0" ]
}

usage() {
    # the USAGE/CONFIG block of the header, selected by its first and last line (not by line numbers)
    sed -n '/^# USAGE:$/,/one log line\.  (default auto)$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
    # The header goes on from there under a heading that calls every flag default OFF, and the alert log is not (default 1), so the rest is
    # set out here with the true defaults: the same flags as the entries of that part of the header, one line each (the pin in operator-tools.sh lists them).
    printf '%s\n' '  ./starchorus-collect.sh -h         # the same as --help'
    printf '%s\n' 'Opt-in layers, each off by default; none of them transmits (each reads, or listens):'
    printf '%s\n' '  STARCHORUS_HOPINFO         1 = channels[]: when each frequency was last heard (recon.db).  (default 0)'
    printf '%s\n' '  STARCHORUS_SURVEY          1 = busy_pct / noise per channel, from a read-only survey dump;'
    printf '%s\n' '                             STARCHORUS_SURVEY_IFACE picks the interface.  (default 0)'
    printf '%s\n' '  STARCHORUS_OWN             1 = the interface addresses of this device; STARCHORUS_OWN_SSID_FILE'
    printf '%s\n' '                             lists its own SSIDs, one per line.  (default 0)'
    printf '%s\n' '  STARCHORUS_HOMING_BSSID    one access point to home in on, or the first line of homing.target in STARCHORUS_OUTDIR.  (default none)'
    printf '%s\n' '  STARCHORUS_APCLI_RO        1 = the read-only list commands of the AP service (the pineap source sets it itself).  (default 0)'
    printf '%s\n' '  STARCHORUS_BLUETOOTH       1 = one passive Bluetooth LE listening window per cycle, of STARCHORUS_BT_WINDOW'
    printf '%s\n' '                             seconds (5 to 15, default 5).  (default 0)'
    printf '%s\n' '  STARCHORUS_BT_SOURCE       auto|blue5|window: where the Bluetooth layer reads (only with STARCHORUS_BLUETOOTH=1);'
    printf '%s\n' '                             auto reads blue5.db when it exists, else our own window.  (default auto)'
    printf '%s\n' '  STARCHORUS_BLUE5_DB        that database, copied and read read-only.  (default /root/recon/blue5.db)'
    printf '%s\n' '  STARCHORUS_TRAFFIC         1 = the share of frames per frequency; on recon.db also a frame counter per station.  (default 0)'
    printf '%s\n' 'On by default:'
    printf '%s\n' '  STARCHORUS_ALERTS          0 = do not read alerts.log (the companion alert payload) from STARCHORUS_ALERT_DIR,'
    printf '%s\n' '                             default /root/loot/starchorus-alerts.  (default 1)'
    printf '%s\n' '  STARCHORUS_ALERT_WINDOW    the seconds an alert is kept, 60 to 86400.  (default 600)'
    printf '%s\n' 'Tests only: STARCHORUS_SYSFS_BT, STARCHORUS_PROC_BT and STARCHORUS_SYSFS_NET name another root for sysfs and /proc.'
    printf '%s\n' 'Everything here is receive-only except the active scan opt-in, STARCHORUS_ALLOW_ACTIVE=1 (default 0: off).'
}

# --------------------------------------------------------------------------- main
case "$1" in
    --stop)      mkdir -p "$OUTDIR" 2>/dev/null; stop_instances;   exit 0 ;;
    --status)    status_instances; exit 0 ;;
    --selftest)  selftest; exit $? ;;
    --help|-h)   usage; exit 0 ;;
    --once|'')   ;;
    *)           log "unknown option: $1 (see --help)"; exit 2 ;;   # not the daemon: that would replace the running collector
esac

mkdir -p "$OUTDIR" "$CAPDIR" "$PIDDIR" 2>/dev/null
# The output directory must exist and take a file: without it nothing can be published. --once has nothing else to do and says so (exit 1); the daemon
# says so once and carries on (the directory may come back, e.g. a mount: every cycle that cannot publish says so once per episode as well).
if [ ! -d "$OUTDIR" ] || [ ! -w "$OUTDIR" ]; then
    if [ "$1" = "--once" ]; then log "cannot create or write the output directory $OUTDIR (STARCHORUS_OUTDIR); nothing is published"; exit 1; fi
    log "cannot create or write the output directory $OUTDIR (STARCHORUS_OUTDIR); no document is published until it can be written"
fi

# Signals clean up AND exit (a returning handler would otherwise resume the loop); EXIT only cleans. HUP is here for a collector started from a
# terminal that closes (a Bluetooth window's tools must not outlive it). Set before anything is made: the OUI index and cache lock (setup_vendor),
# a monitor interface (resolve_source) and airodump (start_airodump) are then undone by a signal at any point, and so by the exit when no source is found.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap cleanup EXIT

# Daemon start: one collector per device. Every other collector loop is stopped and waited for (replace_loops) BEFORE this run picks a
# monitor interface or starts airodump, so that the cleanup of a replaced loop cannot take either away from it. Its sleep is ended, so
# it goes within about a second; the bound covers one in the middle of a cycle's step, and a margin for its cleanup. The loop pidfile
# is still written only once the source is resolved and the capture runs (the payload's start counts it as "up" and allows about 10 s).
[ "$1" = "--once" ] || replace_loops $((INTERVAL + 15))

# Locate the local OUI file + cache once (logs once if none; never fatal).
setup_vendor
[ "$BLUETOOTH" = 1 ] && setup_btco   # the company list for the blue5 source; without Bluetooth there is nothing to name and no log line

[ -z "$INTERVAL_BAD" ] || log "STARCHORUS_INTERVAL must be whole seconds from 1 to 3600 (got '$INTERVAL_BAD'); using 5"
resolve_source
log "resolved data source: $RESOLVED  (interface: ${MONIF:-n/a}, created_mon=$CREATED_MON)"
if [ "$BLUETOOTH" = 1 ]; then
    bt_pick
    case $BT_SRC in
        window) [ -z "$BT_WIN_BAD" ] || log "Bluetooth: STARCHORUS_BT_WINDOW must be whole seconds from 5 to 15 (got '$BT_WIN_BAD'); using 5"
                log "Bluetooth: one passive LE scan window of ${BT_WIN}s per cycle (STARCHORUS_BLUETOOTH=1); addresses, not devices" ;;
        blue5)  log "Bluetooth: reads the Pager's own Bluetooth database each cycle, read-only (STARCHORUS_BT_SOURCE=${BT_SOURCE}); addresses, not devices" ;;
    esac
fi
if [ "$ALERTS" = 1 ] && [ -n "$ALERT_WIN_BAD" ]; then
    log "Alerts: STARCHORUS_ALERT_WINDOW must be whole seconds from 60 to 86400 (got '$ALERT_WIN_BAD'); using 600"
fi

if [ "$RESOLVED" = "none" ]; then
    ts=$(date +%s 2>/dev/null); [ -n "$ts" ] || ts=0
    write_empty "$ts" "no passive data source available (need tcpdump/airodump-ng + monitor iface, or a readable recon.db)" > "$OUTFILE"
    log "no usable passive source; wrote an empty document to $OUTFILE"
    log "hint: set STARCHORUS_IFACE=<monitor-if>, or STARCHORUS_RECON_DB=<path>, or (ACTIVE) STARCHORUS_ALLOW_ACTIVE=1."
    exit 1
fi

# Our own capture: start airodump once and let it keep the CSV fresh; without it the capture is tcpdump bursts.
if [ "$RESOLVED" = "capture" ]; then
    if have airodump-ng; then
        start_airodump || log "airodump start failed; will fall back to tcpdump bursts"
    fi
    [ "$CAP_METHOD" = "" ] && CAP_METHOD="tcpdump"
fi

if [ "$1" = "--once" ]; then
    # For a single cycle with airodump, give it a moment to populate the CSV.
    [ "$CAP_METHOD" = "airodump" ] && sleep "$INTERVAL"
    if run_cycle; then
        log "single cycle complete -> $OUTFILE"
        exit 0
    fi
    log "single cycle failed: this cycle's document was not published to $OUTFILE (see above)"
    exit 1
fi

# Daemon loop. Idempotent start: every collector loop already running for this script (pidfile-tracked or orphaned) was stopped at
# the start (replace_loops), so repeated starts -- e.g. re-running the payload -- never stack duplicate loops fighting over one
# starchorus.json. kill_loops() skips our own PID and reports every other collector loop it replaces (one collector per device).
sweep_stale_cache_files
bt_sweep
sweep_stale_workcopies
sweep_stale_tmp
echo $$ > "$LOOP_PIDFILE"
log "collecting every ${INTERVAL}s -> $OUTFILE (Ctrl-C or --stop to end; loop pid $$)"
cyc=0
while :; do
    cycle_step
    # Every 120 cycles (10 min at the default interval) re-check the OUI file: a replaced /
    # rewritten file (firmware update, swapped USB stick) restarts the cache. Cheap: a few stats.
    cyc=$((cyc+1)); if [ "$cyc" -ge 120 ]; then cyc=0; setup_vendor; [ "$BLUETOOTH" = 1 ] && setup_btco; fi
    # A plain foreground sleep: under busybox ash a caught INT/TERM is handled after the current
    # sleep returns, so --stop takes effect within at most the longer of one INTERVAL and the backoff below (3600 s at most). Backgrounding the sleep and
    # `wait`-ing on it does NOT deliver the trap sooner under ash.
    sleep "$INTERVAL"
    # A slow cycle (pace_end): the rest of three times its wall time. Nothing on an idle device.
    [ "$PACE_MORE" -le 0 ] || sleep "$PACE_MORE"
done

# =============================================================================================
# NOTES / DEVICE FACTS (read-only checks on the device, OpenWrt 24.10.1 with BusyBox 1.36.1, and on
# the AP-service binary and UCI configs of its unpacked firmware image; dated figures: docs/device-notes.md).
#   1. INTERFACES: radio0 = 2.4GHz (mgmt `wlan0mgmt`, client
#      `wlan0cli`, and a 2.4 monitor `wlan0mon`); `wlan1mon` is the recon engine's
#      channel-hopping monitor; a staged USB adapter is `wlan2mon`. Override STARCHORUS_IFACE=<name>.
#      Auto-mode prefers wlan1mon, then any non-wlan0mon monitor, then the first; it never
#      touches the mgmt radio and only creates/removes a VIF it made itself (none, on the device).
#   2. SINGLE RECON RADIO: wlan1mon is owned by the Recon engine, which channel-hops. Do NOT run
#      a 2nd airodump on that PHY. Auto-mode therefore prefers reading recon.db (zero
#      contention). Force with STARCHORUS_SOURCE=recondb (read engine) or =capture (own tcpdump).
#   3. RECON DB: `/root/recon/recon.db` (== /mmc/root/recon/recon.db); schema families, copy and
#      read-only access: see build_from_recondb. `encryption` values: 0=Open (e.g. "OpenGuest");
#      bit3(=8)=WPA2 (majority); bit4(=16)=WPA3; bit3+bit4 => WPA2/WPA3 transition; bit2(=4)=WPA;
#      large 64-bit ints (AKM/cipher bits high up).
#   4. TOOLS: sqlite3, tcpdump, iw, iwinfo, jq, curl, wget,
#      nc, crond and a `timeout` are pre-installed. airodump-ng and python3 are NOT.
#      awk/grep are busybox (no `grep -P`, no gawk-only awk functions). So on the device the
#      recon.db path works out of the box; the capture fallback is tcpdump (not airodump).
#   5. OUTPUT DIR: defaults to /tmp/starchorus (volatile). For persistence use the loot convention on
#      the internal eMMC: STARCHORUS_OUTDIR=/root/loot/starchorus (== /mmc/root/loot/starchorus). There is NO
#      SD card and NO /sd on the device. Serve index.html from there.
#   6. iw scan is ACTIVE (transmits probes) and lists APs only -- left OFF unless you set
#      STARCHORUS_ALLOW_ACTIVE=1 on purpose.
#   7. CLIENT<->AP LINKS: only airodump CSV yields real associations (from overheard data
#      frames). recondb lists probe-req senders as `unassociated`; tcpdump/recondb/iwscan leave
#      per-AP clients:[] empty -- that is expected and schema-valid.
#   8. MANAGEMENT: SSH as root@<device> (tools/install.sh has the default address); mgmt_iface()
#      knows the management addresses.
#   9. MAC VENDOR (OUI) FILES, all already on the device, read-only, nothing fetched:
#      /lib/hak5/oui.txt (the firmware's own, used by the device UI; `00:00:00<TAB>NAME`; the parser takes it
#      and the index is built from it), /usr/share/nmap/nmap-mac-prefixes (`AABBCC Vendor`, upstream also
#      has 7/9-hex MA-M/MA-S lines which are skipped), /usr/share/macchanger/OUI.list (`AA BB CC VENDOR`, dated).
#      Override with STARCHORUS_OUI_FILE=<path> (e.g. a newer file on a USB stick). Parser, cache,
#      index and lock: see VENDOR LOOKUP. The index is built once, when the daemon starts; the size and
#      line count of the file and the CPU figures: docs/device-notes.md (V-8, §6a).
#  10. BLUETOOTH (the brief's read-only checks of 16 Oct 2026, docs/device-notes.md V-13): BlueZ 5.72 with hcitool and btmon on the stock firmware, no
#      rfkill; hci0 is an internal USB controller of the same combo chip as a Wi-Fi radio. `hcitool lescan --passive --duplicates` works and sends no
#      scan request; `btmon` alone starts no scan, it only decodes what another scanner causes, so a window is the scan as starter and btmon as reader.
#      Random addresses dominate (854 of 890 reports in 30 s) and rotate, so the records are addresses. The text of the device's btmon, a 10-s sample
#      kept as tests/fixtures/btmon-window.txt (addresses and names masked), has no [hciN] tag, puts the sender's name in front of the host's own
#      commands ("<name>[pid]: < HCI Command: ...") and cuts a command name that no longer fits ("LE Set Scan P.."): bt_parse reads a header by its
#      opcode and its shape, never by its name, and takes the tag when there is one.
#      NOT covered by --selftest (timing races, documented rather than faked): a live holder
#      grabbing a fresh lock in the microseconds between a breaker's check and its rename
#      (cache_break gives it back), and setup_vendor's restart racing an in-flight merge (the
#      header re-check under the lock is tested; the restart-under-lock itself is not).
# =============================================================================================
