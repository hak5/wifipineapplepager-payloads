#!/bin/bash
# Title: The Hacker Culture Trail
# Author: Aleff
# Version: 1.0
# -----------------------------------------------------------------------------
# The Hacker Culture Trail
#
# This project is a small playable tribute to hacker culture, inspired by the
# spirit described in Steven Levy's "Hackers: Heroes of the Computer Revolution":
# radical curiosity, love for technical elegance, sharing knowledge, and the joy
# of exploration.
#
# The game is a branching story (a narrative "maze"): each step is a node that
# presents choices, clues, commands, and tiny challenges. The point is not to
# "win" in the usual sense, but to travel through the ideas, episodes, and
# attitudes that shaped the hacker ethic-highlighting creativity and learning,
# not pointless damage.
#
# It's meant to be educational, playful, and hackerful (?): a guided trail through
# history, principles, and references, where every turn teaches something and
# invites you to think like an explorer.
# -----------------------------------------------------------------------------

set -euo pipefail

PAYLOAD_NAME="hctrail"

# Payload base directory
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STORY_TSV="${BASE_DIR}/story/story.tsv"
LOCALES_DIR="${BASE_DIR}/locales"
node_id="WELCOME"
NEXT1=""
NEXT2=""

LANG_CODE="en"
LOCALE_FILE="${LOCALES_DIR}/${LANG_CODE}.lang"

_lang_get() {
  local key="$1"
  local file="$2"

  awk -F'=' -v k="$key" '$1==k{ $1=""; sub(/^=/,""); print; exit }' "$file"
}

sanitize_ids() {
  _trim_var() {
    local __name="$1"
    local __v="${!__name}"

    __v="${__v//$'\r'/}"

    __v="${__v#"${__v%%[!$' \t']*}"}"
    __v="${__v%"${__v##*[!$' \t']}"}"

    printf -v "$__name" '%s' "$__v"
  }

  _trim_var "node_id"
  _trim_var "NEXT1"
  _trim_var "NEXT2"
}

rand_0_49() {
  echo $(( RANDOM % 50 ))
}

resolve_next() {
  local raw="$1"

  raw="${raw//$'\r'/}"
  raw="${raw#"${raw%%[!$' \t']*}"}"
  raw="${raw%"${raw##*[!$' \t']}"}"

  # Normal case: it is not RANDOM
  if [[ "$raw" != RANDOM:* ]]; then
    node_id="$raw"
    return 0
  fi

  # RANDOM case: X@w1|Y@w2 (we continue reading like this, but ignore the weights)
  local spec="${raw#RANDOM:}"
  local left="${spec%%|*}"
  local right="${spec#*|}"

  local n1="${left%@*}"   # es: FROGGER.WIN
  local n2="${right%@*}"  # es: FROGGER.LOSE

  local r
  r="$(rand_0_49)"
  # LOG "Valore random. $r"

  if [ "$r" -eq 42 ]; then
    node_id="$n1"
  else
    node_id="$n2"
  fi

  return 0
}

t() {
  local key="$1"
  local val=""

  if [ -f "$LOCALE_FILE" ]; then
    val="$(_lang_get "$key" "$LOCALE_FILE" || true)"
  fi

  printf '%b' "$val"
}

node_nexts() {
  local id="$1"
  local _id n1 n2 extra

  # global reset 
  NEXT1=""
  NEXT2=""

  # Read line by line: ID<TAB>NEXT1<TAB>NEXT2
  while IFS=$'\t' read -r _id n1 n2 extra; do
    # Remove BOM only on the first field (if present)
    _id="${_id#$'\ufeff'}"

    _id="${_id//$'\r'/}"
    n1="${n1//$'\r'/}"
    n2="${n2//$'\r'/}"

    if [ "$_id" = "$id" ]; then
      NEXT1="$n1"
      NEXT2="$n2"
      # LOG "DEBUG node_nexts: id=[$id] NEXT1=[$NEXT1] NEXT2=[$NEXT2]"
      return 0
    fi
  done < "$STORY_TSV"

  # LOG "DEBUG node_nexts: id=[$id] NON TROVATO"
  return 2
}

choose_next_node_popup() {
  local node_id="$1"
  local c1 c2
  local key

  c1="$(t "p.${node_id}.c1")"
  c2="$(t "p.${node_id}.c2")"
  [ -z "$c1" ] && c1="Scelta 1"
  [ -z "$c2" ] && c2="Scelta 2"

  # Show the two options
  PROMPT "[←] ${c1}\n[→] ${c2}\n\n"

  # Wait for LEFT/RIGHT
  while true; do
    key="$(WAIT_FOR_INPUT)"
    case "$key" in
      B) exit 0 ;;
      LEFT)  return 1 ;;  # choose c1
      RIGHT) return 2 ;;  # choose c2
      *)     ;;           # ignore other stuff
    esac
  done
}

if [ ! -f "$STORY_TSV" ]; then
  ERROR_DIALOG "Missing story.tsv in: ${STORY_TSV}"
  exit 1
fi

if [ ! -f "$LOCALE_FILE" ]; then
  ERROR_DIALOG "Missing locale file in: ${LOCALE_FILE}"
  exit 1
fi

on_enter_node() {
  local id="$1"

  case "$id" in
    SCOPRI-DEFCON)
      RINGTONE "LoveMeBetter:d=16,o=4,b=136:16.a#4,16.p,16.a#4,8p,8.a#4,16.p,16.a#4,32.a4,32f4,16.p,32.a#4,32g4,32.p,32a4,4a#4,8p,8.a#4,16.p,8.a#4,16.p,8a#4,32.g#4,32f#4,32f4,4p,8.a#4,16.p,32.a#4,32.p,16.a#4,16.p,16.a#4,8p,8.a#4,16.p,16.a#4,32.a4,32f4,16.p,32.a#4,32g4,32.p,32a4,4a#4,8p,8.a#4,16.p,8.a#4,16.p,8a#4,32.g#4,32f#4,32f4,4p,8.a#4,16.p,32.a#4,32.p,16.a#4,16.p,16.a#4,8p,8.a#4,16.p,16.a#4,32.a4,32f4,16.p,32.a#4,32g4,32.p,32a4,4a#4,8p,8.a#4,16.p,8.a#4,16.p,8a#4,32.g#4,32f#4,32f4,4p,8.a#4,16.p,32.a#4,32.p,16.a#4,16.p,16.a#4,8p,8.a#4,16.p,16.a#4,32.a4,32f4,16.p,32.a#4,32g4,32.p,32a4,4a#4,8p,8.a#4,16.p,8.a#4,16.p,8a#4,32.g#4,32f#4,32f4,4p,8.a#4,16.p,32.a#4,32.p,16.a#4,16.p,16.a#4,8p,8.a#4,16.p,16.a#4,32.a4,32f4,16.p,32.a#4,32g4,32.p,32a4,4a#4,8p,8.a#4,16.p,8.a#4,16.p,8a#4,32.g#4,32f#4,32f4,4p,8.a#4,16.p,32.a#4,32.p,16.a#4"
      ;;
  esac
}

show_node_popup() {
  local node_id="$1"
  local txt chunk
  local CHUNK_SIZE=250

  txt="$(t "p.${node_id}.body")"
  [ -z "$txt" ] && txt="(testo mancante: p.${node_id}.body)"

  local total_len=${#txt}
  local offset=0

  while true; do
    chunk="${txt:offset:CHUNK_SIZE}"
.
    PROMPT "${chunk}\n\n[←]   [→]"

    key="$(WAIT_FOR_INPUT)"

    case "$key" in
      LEFT)
        # Go back only if you are not already at the beginning of the text
        if [ "$offset" -ge "$CHUNK_SIZE" ]; then
          offset=$((offset - CHUNK_SIZE))
        else
          offset=0
        fi
        ;;
      RIGHT|OK)
        # If you are showing the last page, exit (and then show the choices)
        if [ $((offset + CHUNK_SIZE)) -ge "$total_len" ]; then
          break
        fi
        offset=$((offset + CHUNK_SIZE))
        ;;
    esac
  done
}

check_lang() {

  if [[ "$LANG_CODE" == "it" ]]; then
    question="Would you like to continue in Italian?"
    other_lang="en"
  else
    question="Would you like to continue in English?"
    other_lang="it"
  fi

  resp=$(CONFIRMATION_DIALOG "$question") || exit 0

  if [[ "$resp" == "0" ]]; then
    LANG_CODE="${other_lang}"
    LOCALE_FILE="${LOCALES_DIR}/${LANG_CODE}.lang"
  fi
}

main() {
  
  check_lang

  while true; do
    show_node_popup "$node_id"

    node_nexts "$node_id" || exit 0
    sanitize_ids
    on_enter_node "$node_id"
    
    set +e
    choose_next_node_popup "$node_id"
    choice=$?
    set -e
    case "$choice" in
      1)
          resolve_next "$NEXT1"
          sanitize_ids
          if [[ "$node_id" == *END* ]]; then
            exit 0
          fi
          ;;
      2)
          resolve_next "$NEXT2"
          sanitize_ids
          if [[ "$node_id" == *END* ]]; then
            exit 0
          fi
          ;;
      *)
          exit 0
          ;;
    esac

    # If for some reason the TSV points to nothing, exit
    [ -z "$node_id" ] && exit 0
  done
}

main