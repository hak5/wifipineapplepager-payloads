#!/usr/bin/env python3
"""Install an OpenWrt .ipk package on the Pineapple Pager without `opkg install`.

The Pager's opkg build has the `install`/`remove` sub-commands removed, so
packages can't be added the normal way. This script uses `opkg download`
(which *does* work) and unpacks the package into the root filesystem using
only `python3-light` stdlib modules (gzip + tarfile), so it needs no extra
tools (busybox on the Pager has no `tar` applet).

Usage:
    python3 install_pkg.py python3-ctypes

For VENUS you only need `python3-ctypes` (the on-device UI). The firmware
already ships `libffi.so.8`, so it has no other dependencies.
"""

import gzip
import io
import os
import subprocess
import sys
import tarfile


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def install_ipk(path, dest="/"):
    """Extract an OpenWrt .ipk (a gzip'd tar of debian-binary/data/control)."""
    with gzip.open(path, "rb") as gz:
        outer = tarfile.open(fileobj=gz, mode="r:")
        data_name = None
        for m in outer.getmembers():
            if m.name.rstrip("/").endswith("data.tar.gz"):
                data_name = m.name
                break
        if data_name is None:
            raise SystemExit("no data.tar.gz member in " + path)
        data_bytes = outer.extractfile(data_name).read()
    count = 0
    with tarfile.open(fileobj=io.BytesIO(data_bytes), mode="r:gz") as inner:
        members = []
        for m in inner.getmembers():
            name = m.name.lstrip("./")
            # Only install under /usr (the package's payload); ignore the
            # control tarball and any stray paths.
            if name.startswith("usr/"):
                members.append(m)
        inner.extractall(dest, members=members)
        count = len(members)
    return count


def main(argv):
    pkg = argv[1] if len(argv) > 1 else "python3-ctypes"
    print(f"[*] updating package lists (opkg update)...")
    sh(["opkg", "update"])

    print(f"[*] downloading {pkg} (opkg download)...")
    os.chdir("/tmp")
    r = sh(["opkg", "download", pkg])
    ipk = None
    for f in sorted(os.listdir("/tmp")):
        if f.startswith(pkg + "_") and f.endswith(".ipk"):
            ipk = f
            break
    if not ipk:
        print("download failed:", (r.stderr or r.stdout or "").strip())
        return 1

    print(f"[*] unpacking {ipk} into / ...")
    n = install_ipk(os.path.join("/tmp", ipk))
    print(f"[*] installed {n} files for {pkg}")

    r = sh(["python3", "-c", "import ctypes; print('ctypes OK')"])
    if r.returncode == 0:
        print("[*] import check:", r.stdout.strip())
        return 0
    print("[!] import check failed:", (r.stderr or "").strip())
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
