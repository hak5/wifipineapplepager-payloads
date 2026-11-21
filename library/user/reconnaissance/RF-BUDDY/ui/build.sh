#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/rf-buddy-ui}"

command -v go >/dev/null 2>&1 || {
  echo "ERROR: Go is required to build the RF-BUDDY UI." >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
(
  cd "$HERE"
  CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
    go build -mod=vendor -trimpath -ldflags '-s -w' -o "$OUT" .
)
chmod 755 "$OUT"
echo "RF-BUDDY UI BUILD OK -> $OUT"
