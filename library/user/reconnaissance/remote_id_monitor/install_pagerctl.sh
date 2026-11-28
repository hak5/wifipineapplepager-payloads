#!/bin/bash
# Download a pinned pagerctl runtime after explicit on-device confirmation.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
REV=30ef1028500ba1d0303d24ea5d62497407bac77d
PY_SHA=57238e7720498d0de65504efcebc1a8f27f8c1b952ed3bbb718595006d951b08
SO_SHA=f0f5d3213c77e360fa4cf912c5a122d2dd1b39713ae2cdf7c6ba6dc7ead5e4e5
LIB_ROOT="$DIR/lib"
VERSIONS="$LIB_ROOT/versions"
VERSION_ID="${REV}-${PY_SHA}-${SO_SHA}"
VERSION="$VERSIONS/$VERSION_ID"
STAGE="$VERSIONS/.${VERSION_ID}.download.$$"
ACTIVE="$LIB_ROOT/active"
LINK_TMP="$LIB_ROOT/.active.$$"
BASE="https://raw.githubusercontent.com/pineapple-pager-projects/pineapple_pager_pagerctl/$REV/payloads/user/utilities/PAGERCTL"

mkdir -p "$VERSIONS"
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --connect-timeout 15 --max-time 90 "$1" -o "$2"
  else
    wget -T 30 -O "$2" "$1"
  fi
}
verify() {
  actual=$(sha256sum "$2" | awk '{print $1}')
  [ "$actual" = "$1" ]
}
rm -rf "$STAGE"
mkdir "$STAGE"
trap 'rm -rf "$STAGE" "$LINK_TMP"' EXIT
fetch "$BASE/pagerctl.py" "$STAGE/pagerctl.py"
fetch "$BASE/libpagerctl.so" "$STAGE/libpagerctl.so"
verify "$PY_SHA" "$STAGE/pagerctl.py"
verify "$SO_SHA" "$STAGE/libpagerctl.so"
if [ -d "$VERSION" ] && verify "$PY_SHA" "$VERSION/pagerctl.py" && verify "$SO_SHA" "$VERSION/libpagerctl.so"; then
  rm -rf "$STAGE"
else
  # Publish immutable version content before changing the active pointer.
  if [ -e "$VERSION" ]; then
    VERSION="$VERSIONS/${VERSION_ID}.repair.$$"
  fi
  mv "$STAGE" "$VERSION"
fi
ln -s "versions/$(basename "$VERSION")" "$LINK_TMP"
mv -fT "$LINK_TMP" "$ACTIVE"
