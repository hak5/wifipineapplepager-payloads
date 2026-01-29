#!/bin/sh
# SSID Printable Test Harness
# Runs multiple hex→ASCII strategies and prints outputs for diverse test SSIDs

# Portable sanitizers
sanitize_alnum() {
  printf "%s" "$1" | sed 's/[^A-Za-z0-9]//g'
}

sanitize_alnum_space() {
  printf "%s" "$1" | sed 's/[^A-Za-z0-9 ]//g'
}

sanitize_safe_punct() {
  # Keep letters/digits + space + underscore + dash + dot (BusyBox-safe)
  printf "%s" "$1" | sed 's/[^A-Za-z0-9 _.-]//g'
}

# Strategy A: Bulk printf with %b and \xHH (may require bash; shown for comparison)
printable_printf_bulk() {
  hex="$1"
  [ -z "$hex" ] && echo "UNKNOWN_SSID" && return 0
  # Validate even-length hex
  case "$hex" in
    *[!0-9A-Fa-f]*) echo "UNKNOWN_SSID"; return 0 ;;
  esac
  [ $(( ${#hex} % 2 )) -ne 0 ] && echo "UNKNOWN_SSID" && return 0
  escaped=$(echo "$hex" | sed 's/../\\x&/g')
  # BusyBox printf may not support %b fully; include for visibility
  out=$(printf '%b' "$escaped" 2>/dev/null)
  [ -z "$out" ] && out=""
  sanitize_safe_punct "$out"
}

# Strategy B: Per-byte printf loop (portable in ash)
printable_printf_loop() {
  hex="$1"
  [ -z "$hex" ] && echo "UNKNOWN_SSID" && return 0
  case "$hex" in
    *[!0-9A-Fa-f]*) echo "UNKNOWN_SSID"; return 0 ;;
  esac
  [ $(( ${#hex} % 2 )) -ne 0 ] && echo "UNKNOWN_SSID" && return 0
  out=""
  i=0
  len=${#hex}
  while [ $i -lt $len ]; do
    byte=$(echo "$hex" | cut -c $((i+1))-$((i+2)))
    # Use printf with \xHH escapes; BusyBox supports these in the format string itself
    out="${out}$(printf "\\x$byte")"
    i=$((i+2))
  done
  sanitize_safe_punct "$out"
}

# Strategy C: awk with strtonum (not always available; shown for comparison)
printable_awk_strtonum() {
  hex="$1"
  [ -z "$hex" ] && echo "UNKNOWN_SSID" && return 0
  case "$hex" in
    *[!0-9A-Fa-f]*) echo "UNKNOWN_SSID"; return 0 ;;
  esac
  [ $(( ${#hex} % 2 )) -ne 0 ] && echo "UNKNOWN_SSID" && return 0
  out=$(echo "$hex" | awk 'BEGIN{ORS=""} {for(i=1;i<=length($0);i+=2){h=substr($0,i,2); printf("%c", strtonum("0x" h));}}' 2>/dev/null)
  sanitize_safe_punct "$out"
}

# Strategy D: awk manual hex mapping (BusyBox-compatible)
printable_awk_manual() {
  hex="$1"
  [ -z "$hex" ] && echo "UNKNOWN_SSID" && return 0
  case "$hex" in
    *[!0-9A-Fa-f]*) echo "UNKNOWN_SSID"; return 0 ;;
  esac
  [ $(( ${#hex} % 2 )) -ne 0 ] && echo "UNKNOWN_SSID" && return 0
  out=$(echo "$hex" | awk 'BEGIN{ORS=""; map="0123456789ABCDEF"} {
    s=toupper($0);
    for(i=1;i<=length(s);i+=2){
      c1=index(map, substr(s,i,1))-1;
      c2=index(map, substr(s,i+1,1))-1;
      if (c1<0 || c2<0) continue;
      val=c1*16 + c2;
      printf "%c", val;
    }
  }' 2>/dev/null)
  sanitize_safe_punct "$out"
}

# Test cases: hex|label|expected
cat << 'EOF' > /tmp/ssid_test_cases.txt
4F70656E577274|OpenWrt|OpenWrt
436F666665652053686F702057694669|Coffee Shop WiFi|Coffee Shop WiFi
4D792D535349445F322E3447687A21|My-SSID_2.4Ghz!|My-SSID_2.4Ghz
436166C3A95F57692D4669|Cafe Wi-Fi (UTF8 é)|Cafe Wi-Fi
436166C3A95F57694669|Cafe_UTF8|Cafe_WiFi
20204D7920576946692020|Leading/Trailing Spaces|  My WiFi  
57694669C2A05A6F6E65|WiFi NBSP Zone|WiFi Zone
57694669095A6F6E65|WiFi Tab Zone|WiFi Zone
486520736169642022486922|Quoted SSID|He said Hi
4A6F6527732057694669|ASCII Apostrophe|Joe's WiFi
4865207361696420224869|Unmatched Quote|He said Hi
4D7920606C6162602057694669|Backticks|My lab WiFi
3C7363726970743E|Angle Brackets|script
436F72705C4775657374|Backslash|CorpGuest
47756573742B576946693D46617374|Plus Equals|GuestWiFiFast
47756573743A576946693B46617374|Colon Semicolon|GuestWiFiFast
47756573747C57694669|Pipe|GuestWiFi
486F6D657E57694669|Tilde|HomeWiFi
4D792B535349445F322E342E47687A|Plus underscore dot|MySSID_2.4.Ghz
2E68696464656E53534944|Leading Dot|.hiddenSSID
2D77696669|Leading Dash|-wifi
57694669F09F9492|Emoji Lock|WiFi
4A6F65E28099732057694669|Curly Apostrophe|Joes WiFi
|Empty|UNKNOWN_SSID
4F7|OddLength|UNKNOWN_SSID
4f70656e577274|Lowercase|OpenWrt
EOF

print_case() {
  hex="$1"; label="$2"; expected="$3"
  printf "\n== Case: %s\n" "$label"
  printf "Hex: %s\n" "$hex"
  printf "Expected (sanitized): %s\n" "$expected"
  o1=$(printable_printf_bulk "$hex")
  o2=$(printable_printf_loop "$hex")
  o3=$(printable_awk_strtonum "$hex")
  o4=$(printable_awk_manual "$hex")
  printf "A printf_bulk:        '%s' (len %d)\n" "$o1" "${#o1}"
  printf "B printf_loop:        '%s' (len %d)\n" "$o2" "${#o2}"
  printf "C awk_strtonum:       '%s' (len %d)\n" "$o3" "${#o3}"
  printf "D awk_manual:         '%s' (len %d)\n" "$o4" "${#o4}"
}

while IFS='|' read -r hex label expected; do
  print_case "$hex" "$label" "$expected"
done < /tmp/ssid_test_cases.txt

echo "\nDone."
