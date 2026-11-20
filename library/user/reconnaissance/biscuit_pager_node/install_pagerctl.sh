#!/bin/bash
# Download only after the launcher receives explicit confirmation.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
BASE=https://raw.githubusercontent.com/pineapple-pager-projects/pineapple_pager_pagerctl/main/payloads/user/utilities/PAGERCTL
mkdir -p "$DIR/lib"
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --connect-timeout 15 --max-time 90 "$1" -o "$2"
    else
        wget -T 30 -O "$2" "$1"
    fi
}
trap 'rm -f "$DIR/lib/pagerctl.py.download" "$DIR/lib/libpagerctl.so.download"' EXIT
fetch "$BASE/pagerctl.py" "$DIR/lib/pagerctl.py.download"
found=0
for path in libpagerctl.so lib/libpagerctl.so; do
    if fetch "$BASE/$path" "$DIR/lib/libpagerctl.so.download"; then
        found=1
        break
    fi
done
if [ "$found" != 1 ]; then
    echo 'No prebuilt library found. Install/build upstream PAGERCTL, or copy pagerctl.py and libpagerctl.so into this payload/lib/.'
    exit 1
fi
mv "$DIR/lib/pagerctl.py.download" "$DIR/lib/pagerctl.py"
mv "$DIR/lib/libpagerctl.so.download" "$DIR/lib/libpagerctl.so"
