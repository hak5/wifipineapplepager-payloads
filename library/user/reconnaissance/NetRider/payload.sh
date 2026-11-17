#!/bin/bash
# Title: NetRider
# Description: Native green map and live WiGLE trail on the Pager display.
# Author: Glytch
# Version: 1.0.0
# Category: reconnaissance

PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/bin:/mmc/sbin:/mmc/usr/bin:/mmc/usr/sbin:${PATH:-}"
export PATH
umask 077
EXPECTED_SHA256='0000000000000000000000000000000000000000000000000000000000000000'
PAYLOAD_DIR="${PAYLOAD_HOME:-${_PAYLOAD_HOME:-${_payload_home:-${payload_home:-${NETRIDER_PAYLOAD_DIR:-}}}}}"
if [ -z "$PAYLOAD_DIR" ]; then
  PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 1
fi
[ ! -f "$PAYLOAD_DIR" ] || PAYLOAD_DIR="$(dirname -- "$PAYLOAD_DIR")"
PAYLOAD_DIR="$(CDPATH= cd -- "$PAYLOAD_DIR" && pwd)" || exit 1
DATA_DIR="${NETRIDER_DATA_DIR:-$PAYLOAD_DIR/data}"
BINARY="$PAYLOAD_DIR/netrider"

diagnose() {
  local status="${2:-1}"
  [[ "$status" =~ ^[0-9]{1,3}$ ]] || status=1
  if [ "${3:-1}" = 1 ] && [ -x /usr/bin/LOG ] && command -v timeout >/dev/null 2>&1; then
    { timeout -k 1 2 /usr/bin/LOG red "NetRider: $1 (status $status)" >/dev/null 2>&1 || :; } 2>/dev/null
  fi
  return 0
}
fail() {
  diagnose "$1"
  if [ "${interactive_launch:-0}" = 1 ] && [ "${boot_launch:-0}" = 0 ] && [ -x /usr/bin/ERROR_DIALOG ]; then
    timeout 10 /usr/bin/ERROR_DIALOG "$1" || :
  fi
  exit 1
}

RELEASE_REPOSITORY='glytchtech/NetRider'
UPDATE_ROOT="https://github.com/$RELEASE_REPOSITORY/releases"
UPDATE_RECEIPT="$PAYLOAD_DIR/.netrider-update-receipt"
update_hash() {
  local digest
  digest="$(openssl dgst -sha256 < "$1" 2>/dev/null)" || return 1
  digest="${digest##* }"; [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}
update_trusted() {
  local hash="$1" line
  [ "$hash" = "$EXPECTED_SHA256" ] && return 0
  [ -f "$UPDATE_RECEIPT" ] && [ ! -L "$UPDATE_RECEIPT" ] || return 1
  [ "$(wc -c < "$UPDATE_RECEIPT")" -le 256 ] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[a-f0-9]{64}$ ]] || return 1
    [ "$line" != "$hash" ] || return 0
  done < "$UPDATE_RECEIPT"
  return 1
}
update_fetch() {
  local url="$1" output="$2" limit="$3" seconds="${4:-45}"
  ( ulimit -f "$(( (limit+511)/512 ))" || exit 1
    exec curl --fail --silent --show-error --location --proto '=https' \
      --proto-redir '=https' --connect-timeout 8 --max-time "$seconds" \
      --max-redirs 5 --max-filesize "$limit" --output "$output" "$url" ) || return 1
  [ -f "$output" ] && [ "$(wc -c < "$output")" -le "$limit" ]
}
update_manifest() {
  local file="$1" line
  [ "$(wc -c < "$file")" -le 256 ] && [ "$(wc -l < "$file")" -eq 1 ] || return 1
  IFS= read -r line < "$file" || return 1
  [ "$(wc -c < "$file")" -eq "$(( ${#line}+1 ))" ] || return 1
  [[ "$line" =~ ^NR_UPDATE\ 1\ ([0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*)\ ([a-f0-9]{64})\ ([1-9][0-9]{0,7})$ ]] || return 1
  update_version="${BASH_REMATCH[1]}"; update_sha="${BASH_REMATCH[3]}"; update_size="${BASH_REMATCH[4]}"
  [ "${#update_version}" -le 64 ] && [ "$update_size" -ge 76 ] && [ "$update_size" -le 33554432 ]
}
update_elf() {
  # Independently verify ELF32 LE MIPS32r2/o32 soft-float before first execution.
  local file="$1" size phoff phnum flags i at typ off length found=0
  local -a h p abi
  size="$(wc -c < "$file")" || return 1
  read -r -a h <<< "$(hexdump -v -n 52 -e '1/1 "%u "' "$file")"
  [ "${#h[@]}" = 52 ] || return 1
  [ "${h[0]} ${h[1]} ${h[2]} ${h[3]} ${h[4]} ${h[5]} ${h[6]}" = '127 69 76 70 1 1 1' ] || return 1
  [ "${h[16]} ${h[17]} ${h[18]} ${h[19]} ${h[20]} ${h[21]} ${h[22]} ${h[23]}" = '2 0 8 0 1 0 0 0' ] || return 1
  [ "${h[40]} ${h[41]} ${h[42]} ${h[43]}" = '52 0 32 0' ] || return 1
  flags=$((h[36]+256*h[37]+65536*h[38]+16777216*h[39]))
  [ "$((flags & 0xf000f000))" = "$((0x70001000))" ] || return 1
  phoff=$((h[28]+256*h[29]+65536*h[30]+16777216*h[31]));phnum=$((h[44]+256*h[45]))
  [ "$phnum" -gt 0 ] && [ "$phnum" -le 32 ] && [ "$phoff" -ge 52 ] && [ "$((phoff+32*phnum))" -le "$size" ] || return 1
  for ((i=0;i<phnum;i++)); do
    at=$((phoff+32*i)); read -r -a p <<< "$(hexdump -v -s "$at" -n 32 -e '1/1 "%u "' "$file")"
    [ "${#p[@]}" = 32 ] || return 1
    typ=$((p[0]+256*p[1]+65536*p[2]+16777216*p[3]))
    [ "$typ" != "$((0x70000003))" ] || {
      [ "$found" = 0 ] || return 1
      off=$((p[4]+256*p[5]+65536*p[6]+16777216*p[7]));length=$((p[16]+256*p[17]+65536*p[18]+16777216*p[19]))
      [ "$length" = 24 ] && [ "$((off+24))" -le "$size" ] || return 1
      read -r -a abi <<< "$(hexdump -v -s "$off" -n 24 -e '1/1 "%u "' "$file")"
      [ "${#abi[@]}" = 24 ] && [ "${abi[0]} ${abi[1]} ${abi[2]} ${abi[3]} ${abi[4]} ${abi[5]} ${abi[6]} ${abi[7]}" = '0 0 32 2 1 0 0 3' ] || return 1
      found=1
    }
  done
  [ "$found" = 1 ]
}
bootstrap() (
  stage='bootstrap prerequisites'; temporary=''; lock=''
  trap 'result=$?; [ -z "$temporary" ] || rm -rf -- "$temporary"; [ -z "$lock" ] || rmdir "$lock" 2>/dev/null; if [ "$result" != 0 ] && [ "$result" != 3 ]; then diagnose "$stage" "$result"; fi' EXIT
  trap 'exit 1' HUP INT TERM
  for required in timeout curl openssl hexdump wc mktemp mkdir chmod sync mv rm rmdir; do
    command -v "$required" >/dev/null 2>&1 || { stage="Required command missing: $required"; exit 1; }
  done
  stage='release repository configuration'
  [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 1
  stage='bootstrap confirmation'
  answer="$(timeout 120 /usr/bin/CONFIRMATION_DIALOG "NetRider is missing. Download it from $RELEASE_REPOSITORY on GitHub?")" || exit 1
  [ "$answer" = 1 ] || exit 3
  stage='bootstrap install lock'
  mkdir "$PAYLOAD_DIR/.netrider-update-lock" 2>/dev/null || exit 1
  lock="$PAYLOAD_DIR/.netrider-update-lock"
  stage='bootstrap staging directory' 
  temporary="$(mktemp -d "$PAYLOAD_DIR/.netrider-bootstrap.XXXXXX")" || exit 1
  stage='bootstrap destination safety'
  [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] && [ ! -L "$UPDATE_RECEIPT" ] || exit 1
  { [ ! -e "$UPDATE_RECEIPT" ] || [ -f "$UPDATE_RECEIPT" ]; } || exit 1
  stage='manifest download'
  update_fetch "$UPDATE_ROOT/latest/download/netrider-update.txt" "$temporary/manifest" 256 10 || exit 1
  stage='manifest format validation'
  update_manifest "$temporary/manifest" || exit 1
  stage='binary download'
  update_fetch "$UPDATE_ROOT/download/v$update_version/netrider" "$temporary/netrider" "$update_size" || exit 1
  stage='binary size validation'
  [ "$(wc -c < "$temporary/netrider")" -eq "$update_size" ] || exit 1
  stage='binary SHA256 validation'
  [ "$(update_hash "$temporary/netrider")" = "$update_sha" ] || exit 1
  stage='binary architecture and ABI validation'
  update_elf "$temporary/netrider" || exit 1
  stage='binary executable permissions'
  chmod 755 "$temporary/netrider" || exit 1
  stage='binary version validation'
  [ "$(timeout 5 "$temporary/netrider" --version)" = "$update_version" ] || exit 1
  stage='verified receipt installation'
  printf '%s\n' "$update_sha" > "$temporary/receipt" || exit 1
  sync && mv -f "$temporary/receipt" "$UPDATE_RECEIPT" && sync || exit 1
  [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] || exit 1
  stage='atomic binary installation'
  mv -f "$temporary/netrider" "$BINARY" && sync
)

interactive_launch=0
[ "$#" != 0 ] || { [ -z "${PAYLOAD_HOME:-${_PAYLOAD_HOME:-${_payload_home:-${payload_home:-}}}}" ] || interactive_launch=1; }
update_mode=''
if [ "$#" = 1 ]; then
  case "$1" in --check-update) update_mode=--check-update; shift ;; --update) update_mode=--install-update; shift ;; esac
fi
boot_launch=0
if [ "$#" = 1 ] && [ "$1" = --boot ]; then
  boot_launch=1; shift
  [ ! -L "$DATA_DIR/start-at-boot" ] && [ -f "$DATA_DIR/start-at-boot" ] || exit 0
  [ "$(cat "$DATA_DIR/start-at-boot")" = 1 ] || exit 1
  [ ! -L "$DATA_DIR/boot-starting" ] || exit 1
  # Claim and disarm before checksum/preflight: a broken binary cannot boot-loop.
  mv -f "$DATA_DIR/start-at-boot" "$DATA_DIR/boot-starting" || exit 1
fi
prepare=0
if [ "$#" = 1 ] && [ "$1" = --prepare ]; then prepare=1; shift; fi
if [ ! -e "$BINARY" ] && [ ! -L "$BINARY" ] && [ "$interactive_launch" = 1 ] && [ -x /usr/bin/CONFIRMATION_DIALOG ]; then
  bootstrap; result=$?
  [ "$result" != 3 ] || exit 0
  if [ "$result" != 0 ]; then
    message='NetRider download failed verification or could not complete. Check network/release availability; no executable was launched.'
    [ ! -x /usr/bin/ERROR_DIALOG ] || timeout 10 /usr/bin/ERROR_DIALOG "$message" || :
    exit 1
  fi
fi
[ ! -L "$BINARY" ] && [ -f "$BINARY" ] || fail 'Native executable missing or symlinked. Upload netrider beside payload.sh.' 
command -v openssl >/dev/null 2>&1 || fail 'Required SHA256 command unavailable.'
checksum="$(update_hash "$BINARY")" || fail 'Cannot verify the native executable.'
update_trusted "$checksum" || fail 'Binary checksum failed. Upload the matching payload.sh and netrider.'
chmod 755 "$BINARY" || fail 'Cannot restore native executable permission.'
[ -z "$update_mode" ] || exec "$BINARY" "$update_mode"
if [ "$prepare" = 1 ]; then
  printf '%s\n' "$PAYLOAD_DIR"
  exit 0
fi
if [ "$boot_launch" = 1 ]; then
  exec "$BINARY" --boot-supervisor --data-dir "$DATA_DIR" --loot /root/loot/wigle
fi
launch_mode="$("$BINARY" --validate-launch "$@")" || fail 'Unsupported launch argument or invalid diagnostic duration/path.'
case "$launch_mode" in ui|diagnostic) ;; *) fail 'Native launcher validation failed.' ;; esac
"$BINARY" --data-dir "$DATA_DIR" --loot /root/loot/wigle "$@"
result=$?
# Only exit 1 confirms UI recovery; never reenter firmware after exit 2/signals.
if [ "$result" != 0 ]; then
  safe_log=0; [ "$result" != 1 ] || safe_log=1
  diagnose 'Native process exited unsuccessfully' "$result" "$safe_log"
fi
[ "$launch_mode" = ui ] || exit "$result"
case "$result" in
  0) exit 0 ;;
  1)
    "$BINARY" --error-dialog 'NetRider could not start or exited unexpectedly.' || :
    exit 1 ;;
  2)
    exit 2 ;;
  *)
    exit "$result" ;;
esac
