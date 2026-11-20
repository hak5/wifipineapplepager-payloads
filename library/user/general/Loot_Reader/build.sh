#!/bin/bash
# Build the Loot Reader program (lootreader) from lootreader.c, on your computer.
# The Pager has no compiler, so you build it here and copy it over (see README.md).
#
# Needs a mipsel cross-compiler (any one of these works):
#   macOS:          brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
#   Debian/Ubuntu:  sudo apt install gcc-mipsel-linux-gnu
#   Anything else:  Docker (see README.md)
# Or point CC at your own:  CC=/path/to/mipsel-...-gcc ./build.sh
set -e
cd "$(dirname "$0")"

if [ -z "$CC" ]; then
    for c in mipsel-unknown-linux-gnu-gcc mipsel-linux-gnu-gcc mipsel-openwrt-linux-musl-gcc mipsel-linux-musl-gcc; do
        command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
    done
fi
if [ -z "$CC" ]; then
    echo "No mipsel cross-compiler found. Install one (see the top of this file or README.md)." >&2
    exit 1
fi
echo "Compiler: $CC ($("$CC" -dumpversion))"

# Freestanding, no libc, integer-only: the Pager's MT7628 CPU has no FPU.
"$CC" -O2 -march=24kc -msoft-float -fno-pic -mno-abicalls -G0 -nostdlib -ffreestanding \
      -fno-tree-loop-distribute-patterns -static -s -Wl,-e,_start -o lootreader lootreader.c

# Sanity checks: a 32-bit little-endian MIPS program with no floating-point instructions.
OBJDUMP="${CC%gcc}objdump"
if command -v "$OBJDUMP" >/dev/null 2>&1; then
    n=$("$OBJDUMP" -d lootreader | grep -cE '\$f[0-9]|lwc1|swc1|ldc1|sdc1|cvt\.|mtc1|mfc1' || true)
    if [ "$n" != "0" ]; then
        echo "ERROR: $n floating-point instructions found - this would crash on the Pager." >&2
        rm -f lootreader; exit 1
    fi
    echo "Floating-point check: OK (0 FPU instructions)"
fi
if command -v file >/dev/null 2>&1; then file lootreader; fi
echo "Size: $(wc -c < lootreader | tr -d ' ') bytes"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 lootreader
elif command -v sha256sum >/dev/null 2>&1; then sha256sum lootreader; fi
echo "Built ./lootreader - copy it into this folder on the Pager (see README.md)."
