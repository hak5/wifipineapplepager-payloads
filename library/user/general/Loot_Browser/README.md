# Loot Browser

Browse `/root/loot` right on the Pager screen: walk the folders, read the text and
log files, and get an info card for anything that can't be shown on the device.

- **Author:** Jenx
- **Version:** 1.1
- **Category:** general

## What it does

- **Folder view** — lists the current folder: subfolders first (blue, with a `/`),
  then files with their size. A scrollbar appears when there are more than fit.
- **Text reader** — opens `.txt`, `.log`, `.csv`, `.tsv`, `.md`, `.conf`, `.json` and
  any other text file in a scrolling, word-wrapped reader (up to the first 128 KB of
  very large files). Up/Down scroll a line, Left/Right a page, with a line counter
  and percentage.
- **Info card** — for anything that isn't text (pcap, handshakes, images, archives,
  databases...), it shows the type and size and tells you to copy it off, with the
  exact `scp` path and the web UI address. The Pager can't open those itself.

Whether a file is "text" is decided by its extension and by sniffing the first couple
of kilobytes for binary bytes, so an odd extension still opens if it's really text.

## Works on any theme

Loot Browser ships with its own clean dark look that works on **any** Pager theme.
On the Dockside themes it also draws a custom, matching look - it detects the active
theme at launch:

- **Any theme** -> the browser's own dark layout (always available).
- **Dockside** -> a custom light Finder window (traffic lights, a Favorites sidebar
  with Loot highlighted, Pager HD, Name/Size columns, a live "Pager HD > loot > ..."
  path bar at the bottom and the folder name up top).
- **Dockside Dark** -> the same Finder window in the dark palette.

The path bar and the folder name are real and update as you move through the
folders. `payload.sh` reads the theme name from the Pager's preferences API and
passes it to the browser.

## Controls (hold the Pager the normal way)

- **Folder view:** Up/Down pick · Green or Right open · Left up a folder · Red exit
- **Reader:** Up/Down line · Left/Right page · Green page down · Red back to the list
- **Info card:** Green or Red back to the list
- **Power:** the Pager's usual display sleep

## Read-only and safe

It only ever **reads** from `/root/loot`: it never writes, moves, renames or deletes
anything, and it can't browse above `/root/loot`. It takes the screen with the
official `UI_TAKEOVER` / `UI_RELEASE` handoff and keeps no files of its own.

## A note on capitals

The Pager's small pixel font is uppercase-only, so file names and file contents are
shown in capitals. The text is still accurate, just not in its original case.

## How it works

`lootbrowser` (source in `lootbrowser.c`) is a small native program: freestanding,
no libc, raw MIPS system calls, integer-only (the MT7628 has no FPU). It lists folders
with `getdents64`, reads files directly, and draws at 20 fps. `payload.sh` just hands
it the screen and launches it.

## Files

- `lootbrowser` — prebuilt static MIPS binary
- `lootbrowser.c` — full source
- `font5x7.h` — the pixel font
- `build.sh` — cross-compile it
- `payload.sh` — launcher

## Verifying the binary

`lootbrowser` is built from `lootbrowser.c` with nothing added, and the build is
reproducible: the same compiler and flags give a byte-for-byte identical file.

- **Compiler:** GCC 15.2.0, `mipsel-unknown-linux-gnu-gcc` from
  `brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu`
- **Flags:** as in `build.sh`
- **SHA-256 of `lootbrowser` (v1.1):**
  `279467079a4b7b7ca368fde1d2e3ecfb2b90a66a98b0a56ffdbc8bb19cabe280`

```sh
./build.sh               # prints the SHA-256; it must match the hash above
```

Desktop preview (browse any folder on your computer and render the screens):

```sh
cc -O2 -DHOST_PREVIEW -o lootbrowser_host lootbrowser.c
./lootbrowser_host --preview /some/folder /tmp/out
```
