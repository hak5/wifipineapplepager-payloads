#!/bin/sh
# TITLE: Wigle Stats
# AUTHOR Nomaran
# DESCRIPTION Looks at the most recent Wigle.csv file and counts the amount of auth types and estimated distance traveled

# Check is Python is installed

if ! command -v python3 >/dev/null 2>&1; then
  LOG "ERROR: python3 is not installed. Install with: opkg install python3"
  exit 1
fi

# Get the latest CSV file, skipped the first two rows.
wigle=$(ls -t /root/loot/wigle/*.csv 2>/dev/null | head -n 1)

SKIP_ROWS=2
UNIQUE_COL=4

# Total networks (data rows only)
network_count=$(awk 'NR>2' "$wigle" | wc -l)

# New and previously seen networks

read new_networks previously_seen <<EOF
$(awk -F',' '
NR>2 {
  mac = $1
  first = $4

  # Track earliest FirstSeen per MAC
  if (!(mac in earliest) || first < earliest[mac]) {
    earliest[mac] = first
  }

  total++
}
END {
  new = 0
  for (m in earliest)
    new++

  prev = total - new
  print new, prev
}
' "$wigle")
EOF

# Authentication breakdown by unique network (MAC-based)

auth_breakdown=$(awk -F',' '
NR>2 {
  mac = $1
  auth = $3

  # Only process each MAC once
  if (mac in seen)
    next
  seen[mac] = 1

  if (auth ~ /OPEN/)
    print "OPEN"
  else if (auth ~ /WEP/)
    print "WEP"
  else if (auth ~ /WPA2/ && auth ~ /WPA3/)
    print "WPA2+WPA3"
  else if (auth ~ /WPA3/)
    print "WPA3"
  else if (auth ~ /WPA2/)
    print "WPA2"
  else if (auth ~ /WPA/)
    print "WPA"
  else
    print "UNKNOWN"
}
' "$wigle" | sort | uniq -c | sort -nr)

# Call Python program to get approx distance traveled
distance_km=$(python3 /mmc/root/payloads/user/general/wigle_stats/wigle_distance.py "$wigle")

# LOG Data to the Pager

# LOG new and previously seen networks
LOG "New networks (first observed): $new_networks"
LOG "Previously seen networks: $previously_seen"
LOG -------------------------------------------------

# LOG Auth Breakdown
LOG "Authentication breakdown:"
echo "$auth_breakdown" | while read -r count mode; do
LOG "  $mode: $count"
done
LOG -------------------------------------------------

# LOG Distance
LOG "Estimated distance traveled: ${distance_km} km"