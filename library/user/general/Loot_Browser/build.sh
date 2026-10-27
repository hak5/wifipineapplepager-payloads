#!/bin/bash
# Cross-compile Loot Browser for the Pager (FPU-less mipsel, freestanding).
# Toolchain: brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
set -e
cd "$(dirname "$0")"
CC="${CC:-mipsel-unknown-linux-gnu-gcc}"
"$CC" -O2 -fno-pic -mno-abicalls -G0 -nostdlib -ffreestanding -fno-tree-loop-distribute-patterns \
      -static -s -Wl,-e,_start -o lootbrowser lootbrowser.c
file lootbrowser; ls -lh lootbrowser | awk '{print "size:",$5}'
if "${CC%gcc}objdump" -d lootbrowser 2>/dev/null | grep -qiE '\$f[0-9]|lwc1|swc1|cvt\.'; then
    echo "WARNING: floating-point instructions present - will SIGILL on device!" >&2
fi
shasum -a 256 lootbrowser
# Desktop preview: cc -O2 -DHOST_PREVIEW -o lootbrowser_host lootbrowser.c && ./lootbrowser_host --preview <dir> /tmp/out
