# Loot Reader

Read `/root/loot` right on the Pager screen: walk the folders, read the text and
log files, and get an info card for anything that can't be shown on the device.

- **Author:** Jenx
- **Version:** 1.2
- **Category:** general

> **One setup step:** this payload ships as source code only. Before the first run,
> build the `lootreader` program on your computer and copy it into the payload folder
> on the Pager. It takes a couple of minutes; see [Build and install](#build-and-install).

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

Loot Reader ships with its own clean dark look that works on **any** Pager theme.
On the Dockside themes it also draws a custom, matching look - it detects the active
theme at launch:

- **Any theme** -> the reader's own dark layout (always available).
- **Dockside** -> a custom light Finder window (traffic lights, a Favorites sidebar
  with Loot highlighted, Pager HD, Name/Size columns, a live "Pager HD > loot > ..."
  path bar at the bottom and the folder name up top).
- **Dockside Dark** -> the same Finder window in the dark palette.

The path bar and the folder name are real and update as you move through the
folders. `payload.sh` reads the theme name from the Pager's preferences API and
passes it to the reader.

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

## Build and install

The Pager has no compiler, so you build `lootreader` on your computer (Mac, Linux, or
Windows) and copy it to the Pager. The program is about 20 KB and is built only from
the files in this folder: `lootreader.c` and `font5x7.h`.

### 1. Get a cross-compiler (once)

Pick the one for your computer:

- **macOS** (Homebrew):
  ```sh
  brew install messense/macos-cross-toolchains/mipsel-unknown-linux-gnu
  ```
- **Debian / Ubuntu** (also Windows with WSL):
  ```sh
  sudo apt install gcc-mipsel-linux-gnu
  ```
- **Anything with Docker** (no install needed beyond Docker): skip to step 2 and use
  the Docker command.

### 2. Build

From this payload's folder:

```sh
./build.sh
```

Or with Docker instead:

```sh
docker run --rm -v "$PWD":/src -w /src debian:bookworm sh -c \
  'apt-get update -qq && apt-get install -y -qq gcc-mipsel-linux-gnu file >/dev/null && ./build.sh'
```

`build.sh` finds the compiler, builds `lootreader`, and checks the result: it must be
a 32-bit little-endian MIPS program with **0 floating-point instructions** (the
Pager's CPU has no FPU, so any would crash it). It stops with an error if that check
fails, and prints the program's SHA-256 so you can compare builds.

### 3. Copy it to the Pager

Put `lootreader` next to `payload.sh` in the payload's folder on the Pager:
`/root/payloads/user/general/Loot_Reader/`

- **Terminal** (Pager connected by USB-C):
  ```sh
  scp lootreader root@172.16.52.1:/root/payloads/user/general/Loot_Reader/
  ```
- **Browser** (firmware 2.0): open the Pager's web UI at `http://172.16.52.1:1471`,
  go to **Files**, open `/root/payloads/user/general/Loot_Reader/` and upload
  `lootreader`. Uploads can lose the "executable" setting; that's fine, the payload
  sets it again each time it starts.

Then run **Payloads > general > Loot Reader** on the Pager. If you forget this step,
the payload tells you the program is missing and points you back here.

## How it works

`lootreader` (source in `lootreader.c`) is a small native program: freestanding,
no libc, raw MIPS system calls, integer-only (the MT7628 has no FPU). It lists folders
with `getdents64`, reads files directly, and draws at 20 fps. `payload.sh` just hands
it the screen and launches it.

## Files

- `payload.sh` — launcher
- `lootreader.c` — full source of the screen program
- `font5x7.h` — the pixel font
- `build.sh` — builds `lootreader` (see above)

## Desktop preview

To try the screens without a Pager, build a desktop version that browses any folder
on your computer and saves each screen as an image:

```sh
cc -O2 -DHOST_PREVIEW -o lootreader_host lootreader.c
./lootreader_host --preview /some/folder /tmp/out
```
