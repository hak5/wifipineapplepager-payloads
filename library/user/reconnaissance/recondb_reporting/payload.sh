#!/bin/bash
# Title: Recon-DB Engagement Report Generator
# Description: Queries native recon database and produces a plain-text
#              engagement report. Uses exec stdout redirect for reliable
#              file writing on BusyBox.
# Author: 0xD1G5
# Version: 3.5
# Type: User payload
# Category: Reorting
# Requires: sqlite3 (opkg install sqlite3-cli if missing)

# CONFIG
RECON_DB=/root/recon/recon.db
RECON_DB_COPY=/tmp/recon_report.db
WIGLE_DIR=/root/loot/wigle
HANDSHAKE_DIR=/root/loot/handshakes
ROGUE_LOG=/root/loot/rogue_ap/detections.log
REPORT_DIR=/root/loot/reports

# PREFLIGHT
if ! which sqlite3 > /dev/null 2>&1; then
    ALERT "sqlite3 not found. Run: opkg install sqlite3-cli"
    exit 1
fi

if [ ! -f $RECON_DB ]; then
    ALERT "Recon database not found at $RECON_DB"
    exit 1
fi

# METADATA
engagement="DATE_LOCATION_WIRELESS_RECON"
target_org="Acme Corp"
operator="UPDATE_WITH_YOUR_NAME"

# SETUP
mkdir -p $REPORT_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RF=$REPORT_DIR/report_$TIMESTAMP.txt
GENERATED_AT=$(date +%Y-%m-%d_%H:%M:%S)

SPINNER1=$(START_SPINNER "Gathering data...")

cp $RECON_DB $RECON_DB_COPY
DB=$RECON_DB_COPY

# GPS - 5 second timeout, fail gracefully
gps_raw=$(timeout 5 GPS_GET 2>/dev/null)
gps_lat=$(echo "$gps_raw" | cut -d' ' -f1)
gps_lon=$(echo "$gps_raw" | cut -d' ' -f2)
gps_alt=$(echo "$gps_raw" | cut -d' ' -f3)
gps_acc=$(echo "$gps_raw" | cut -d' ' -f4)
gps_available=0
if [ -n "$gps_lat" ] && [ "$gps_lat" != "0" ] && [ "$gps_lat" != "0.000000" ]; then
    gps_available=1
fi

# WiGLE
wigle_file=$(ls -t $WIGLE_DIR/*.csv 2>/dev/null | head -1)
wigle_available=0
wigle_ap_count=0
if [ -n "$wigle_file" ] && [ -f "$wigle_file" ]; then
    wigle_available=1
    wigle_ap_count=$(tail -n +3 $wigle_file | grep -c WIFI 2>/dev/null)
    [ -z "$wigle_ap_count" ] && wigle_ap_count=0
fi

# COUNTS - all via sqlite3
session_count=$(sqlite3 $DB "SELECT count(*) FROM scan;")
ap_total=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8;")
ap_hidden=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND hidden=1;")
ap_open=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND (encryption=0 OR encryption IS NULL);")
client_total=$(sqlite3 $DB "SELECT count(DISTINCT w.hash) FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4;")
enc_wpa2=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND (encryption & 8) != 0 AND (encryption & 16) = 0 AND (encryption & 64) = 0;")
enc_wpa3=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND ((encryption & 16) != 0 OR (encryption & 64) != 0);")
enc_mixed=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND (encryption & 4) != 0 AND (encryption & 8) != 0 AND (encryption & 16) = 0 AND (encryption & 64) = 0;")
enc_wep=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND (encryption & 2) != 0 AND (encryption & 8) = 0;")
band_24=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND s.freq < 5000;" 2>/dev/null || sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND freq < 5000;")
band_5=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND freq >= 5000 AND freq < 5925;")
band_6=$(sqlite3 $DB "SELECT count(*) FROM ssid WHERE type=8 AND freq >= 5925;")
hs_pcap=$(find $HANDSHAKE_DIR -name "*.pcap" 2>/dev/null | wc -l | tr -d ' ')
hs_crack=$(find $HANDSHAKE_DIR -name "*.22000" 2>/dev/null | wc -l | tr -d ' ')
rogue_count=0
[ -f $ROGUE_LOG ] && rogue_count=$(grep -c ROGUE $ROGUE_LOG 2>/dev/null || echo 0)
cred_count=$(sqlite3 $DB "SELECT count(*) FROM hostap_basic;")

STOP_SPINNER $SPINNER1
SPINNER2=$(START_SPINNER "Writing report...")

# REDIRECT STDOUT TO REPORT FILE
# Save original stdout to fd 3, redirect stdout to report file.
# All echo and sqlite3 output below goes directly to the file.
# Restore stdout before ALERT/VIBRATE/LOG at the end.
exec 3>&1
exec 1>$RF

echo "================================================================================"
echo "  WIRELESS RECONNAISSANCE ENGAGEMENT REPORT"
echo "  WiFi Pineapple Pager -- Hak5 (8th gen PineAP)"
echo "================================================================================"
echo ""
echo "  Engagement  : $engagement"
echo "  Target      : $target_org"
echo "  Operator    : $operator"
echo "  Generated   : $GENERATED_AT"
if [ $gps_available -eq 1 ]; then
    echo "  Location    : $gps_lat, $gps_lon  (alt: ${gps_alt}m  acc: ${gps_acc}m)"
fi

echo ""
echo "================================================================================"
echo "  EXECUTIVE SUMMARY"
echo "================================================================================"
echo ""
echo "  Recon sessions   : $session_count"
echo "  Access points    : $ap_total observed  ($ap_hidden hidden, $ap_open open)"
echo "  Client devices   : $client_total observed"
echo "  Handshakes       : $hs_pcap captured  ($hs_crack Hashcat-ready)"
[ $wigle_available -eq 1 ] && echo "  GPS-tagged APs   : $wigle_ap_count"
echo "  Rogue AP events  : $rogue_count"
[ "$cred_count" -gt 0 ] && echo "  !! Credentials   : $cred_count captured via Evil WPA"
echo ""
echo "  Encryption:"
echo "    Open             : $ap_open"
echo "    WEP              : $enc_wep"
echo "    WPA2             : $enc_wpa2"
echo "    WPA/WPA2 Mixed   : $enc_mixed"
echo "    WPA3             : $enc_wpa3"
echo ""
echo "  Bands:"
echo "    2.4 GHz : $band_24 APs"
echo "    5 GHz   : $band_5 APs"
echo "    6 GHz   : $band_6 APs"

echo ""
echo "================================================================================"
echo "  SECTION 1 -- RECON SESSIONS"
echo "================================================================================"
sqlite3 $DB "SELECT '  Session ' || id || ': ' || COALESCE(name,'unnamed') || '  started ' || datetime(time,'unixepoch') FROM scan ORDER BY time;"

echo ""
echo "================================================================================"
echo "  SECTION 2 -- ACCESS POINTS  ($ap_total observed)"
echo "================================================================================"
echo ""
echo "  BSSID               SSID                     Band    Ch  Encryption           Sig  Pkts  Last seen"
echo "  ----------------------------------------------------------------------------------------------------"
sqlite3 $DB "SELECT printf('  %-19s %-24s %-7s %-3s %-20s %-4s %-4s %s', substr(s.bssid,1,2)||':'||substr(s.bssid,3,2)||':'||substr(s.bssid,5,2)||':'||substr(s.bssid,7,2)||':'||substr(s.bssid,9,2)||':'||substr(s.bssid,11,2), COALESCE(NULLIF(CAST(s.ssid AS TEXT),''),'[hidden]'), CASE WHEN s.freq >= 5925 THEN '6 GHz' WHEN s.freq >= 5000 THEN '5 GHz' ELSE '2.4GHz' END, s.channel, CASE WHEN s.encryption IS NULL OR s.encryption = 0 THEN 'Open' WHEN (s.encryption & 2) != 0 AND (s.encryption & 8) = 0 THEN 'WEP' WHEN ((s.encryption & 16) != 0 OR (s.encryption & 64) != 0) AND (s.encryption & 8) != 0 THEN 'WPA2/WPA3' WHEN (s.encryption & 16) != 0 OR (s.encryption & 64) != 0 THEN 'WPA3' WHEN (s.encryption & 4) != 0 AND (s.encryption & 8) != 0 THEN 'WPA/WPA2' WHEN (s.encryption & 8) != 0 THEN 'WPA2' ELSE 'Unknown' END, s.signal, w.packets, datetime(s.time,'unixepoch')) FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=8 ORDER BY s.signal DESC LIMIT 200;"

echo ""
echo "================================================================================"
echo "  SECTION 3 -- OPEN NETWORKS  ($ap_open found)"
echo "================================================================================"
if [ "$ap_open" -eq 0 ]; then
    echo "  No open access points observed."
else
    echo "  !! Unencrypted -- client traffic visible in plaintext."
    echo ""
    sqlite3 $DB "SELECT printf('  %-19s %-24s %-7s CH%-3s  %s dBm', substr(s.bssid,1,2)||':'||substr(s.bssid,3,2)||':'||substr(s.bssid,5,2)||':'||substr(s.bssid,7,2)||':'||substr(s.bssid,9,2)||':'||substr(s.bssid,11,2), COALESCE(NULLIF(CAST(s.ssid AS TEXT),''),'[hidden]'), CASE WHEN s.freq >= 5925 THEN '6 GHz' WHEN s.freq >= 5000 THEN '5 GHz' ELSE '2.4GHz' END, s.channel, s.signal) FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=8 AND (s.encryption=0 OR s.encryption IS NULL) ORDER BY s.signal DESC;"
fi

echo ""
echo "================================================================================"
echo "  SECTION 4 -- CLIENT DEVICES  ($client_total observed, top 100 by signal)"
echo "================================================================================"
echo ""
echo "  Note: Modern devices randomize MACs. Empty SSID = passive scan."
echo ""
echo "  MAC                  Probed SSID              Sig   Band    First seen"
echo "  ------------------------------------------------------------------------"
if [ "$client_total" -eq 0 ]; then
    echo "  No client devices observed."
else
    sqlite3 $DB "SELECT printf('  %-19s %-24s %-5s %-7s %s', substr(w.mac,1,2)||':'||substr(w.mac,3,2)||':'||substr(w.mac,5,2)||':'||substr(w.mac,7,2)||':'||substr(w.mac,9,2)||':'||substr(w.mac,11,2), COALESCE(NULLIF(CAST(s.ssid AS TEXT),''),'[broadcast]'), s.signal, CASE WHEN s.freq >= 5925 THEN '6 GHz' WHEN s.freq >= 5000 THEN '5 GHz' ELSE '2.4GHz' END, datetime(s.time,'unixepoch')) FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 GROUP BY w.mac ORDER BY s.signal DESC LIMIT 100;"
fi

echo ""
echo "================================================================================"
echo "  SECTION 5 -- HANDSHAKE CAPTURES"
echo "================================================================================"
if [ "$hs_pcap" -eq 0 ]; then
    echo "  No handshakes captured."
    echo "  Tip: PINEAPPLE_EXAMINE_BSSID <bssid> locks channel to improve capture rate."
else
    echo "  Total    : $hs_pcap"
    echo "  Hashcat  : $hs_crack (.22000 format)"
    echo ""
    find $HANDSHAKE_DIR -name "*.pcap" 2>/dev/null | sort | while IFS= read -r f; do
        size=$(ls -lh $f 2>/dev/null | awk '{print $5}')
        echo "    $size  $(basename $f)"
    done
    echo ""
    echo "  hashcat -m 22000 -a 0 capture.22000 wordlist.txt"
fi

echo ""
echo "================================================================================"
echo "  SECTION 6 -- CAPTURED CREDENTIALS (Evil WPA)"
echo "================================================================================"
if [ "$cred_count" -eq 0 ]; then
    echo "  No credentials captured."
else
    echo "  !! $cred_count credential set(s) captured"
    echo ""
    sqlite3 $DB "SELECT printf('  %-20s %-12s %-20s %s', datetime(time,'unixepoch'), type, identity, password) FROM hostap_basic ORDER BY time;"
fi

echo ""
echo "================================================================================"
echo "  SECTION 7 -- GPS AND AP LOCATIONS"
echo "================================================================================"
if [ $gps_available -eq 1 ]; then
    echo "  GPS fix at report time:"
    echo "    Latitude  : $gps_lat"
    echo "    Longitude : $gps_lon"
    echo "    Altitude  : ${gps_alt}m"
    echo "    Accuracy  : ${gps_acc}m"
    echo ""
    echo "  Maps: https://maps.google.com/?q=${gps_lat},${gps_lon}"
else
    echo "  No GPS fix. Connect USB GPS and ensure clear sky view."
fi
echo ""
if [ $wigle_available -eq 0 ]; then
    echo "  No WiGLE log. Enable: Recon > Settings > WiGLE (requires GPS)"
else
    echo "  WiGLE log  : $(basename $wigle_file)"
    echo "  GPS-tagged : $wigle_ap_count APs"
    echo ""
    echo "  Upload: WIGLE_LOGIN and WIGLE_UPLOAD"
fi

echo ""
echo "================================================================================"
echo "  SECTION 8 -- ROGUE AP DETECTIONS"
echo "================================================================================"
if [ "$rogue_count" -eq 0 ]; then
    if [ -f $ROGUE_LOG ]; then
        echo "  Detector ran -- no events detected."
    else
        echo "  No detection log. Deploy Rogue AP Detector payload to enable."
    fi
else
    echo "  Total events : $rogue_count"
    echo ""
    grep ROGUE $ROGUE_LOG
fi

echo ""
echo "================================================================================"
echo "  SECTION 9 -- LOOT RETRIEVAL"
echo "================================================================================"
echo ""
echo "  Pager IP: 172.16.42.1"
echo ""
echo "  Report     : scp root@172.16.42.1:$RF ./"
echo "  Full loot  : scp -r root@172.16.42.1:/root/loot/ ./loot_$TIMESTAMP/"
echo "  Recon DB   : scp root@172.16.42.1:$RECON_DB ./recon_$TIMESTAMP.db"
echo "  WiGLE      : scp root@172.16.42.1:/root/loot/wigle/*.csv ./"
echo "  Handshakes : scp -r root@172.16.42.1:$HANDSHAKE_DIR/ ./handshakes/"
echo ""
echo "================================================================================"
echo "  END OF REPORT -- $GENERATED_AT"
echo "================================================================================"

# CSV OUTPUT - written while stdout is still redirected to report file
# Restore stdout first so CSV goes to its own file
exec 1>&3
exec 3>&-

CF=$REPORT_DIR/report_$TIMESTAMP.csv

# AP CSV
sqlite3 -csv $DB "SELECT 'BSSID','SSID','Band','Channel','Encryption','Signal','Packets','Hidden','Last_Seen';" > $CF
sqlite3 -csv $DB "SELECT substr(s.bssid,1,2)||':'||substr(s.bssid,3,2)||':'||substr(s.bssid,5,2)||':'||substr(s.bssid,7,2)||':'||substr(s.bssid,9,2)||':'||substr(s.bssid,11,2), CAST(s.ssid AS TEXT), CASE WHEN s.freq >= 5925 THEN '6 GHz' WHEN s.freq >= 5000 THEN '5 GHz' ELSE '2.4 GHz' END, s.channel, CASE WHEN s.encryption IS NULL OR s.encryption = 0 THEN 'Open' WHEN (s.encryption & 2) != 0 AND (s.encryption & 8) = 0 THEN 'WEP' WHEN ((s.encryption & 16) != 0 OR (s.encryption & 64) != 0) AND (s.encryption & 8) != 0 THEN 'WPA2/WPA3' WHEN (s.encryption & 16) != 0 OR (s.encryption & 64) != 0 THEN 'WPA3' WHEN (s.encryption & 4) != 0 AND (s.encryption & 8) != 0 THEN 'WPA/WPA2' WHEN (s.encryption & 8) != 0 THEN 'WPA2' ELSE 'Unknown' END, s.signal, w.packets, s.hidden, datetime(s.time,'unixepoch') FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=8 ORDER BY s.signal DESC LIMIT 500;" >> $CF

LOG "CSV: $CF"

# CLEANUP AND NOTIFY
STOP_SPINNER $SPINNER2
rm -f $RECON_DB_COPY

LOG "Report: $RF"
VIBRATE "alert"
ALERT "Report ready"

exit 0
