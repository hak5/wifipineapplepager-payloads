#!/usr/bin/env python3
"""Install OpenWrt .ipk packages on the Pineapple Pager without `opkg install`.

The Pager's opkg build removes the `install`/`remove` sub-commands, so packages
can't be added the normal way. This script uses `opkg download` (which *does*
work) plus Python `tarfile` to unpack packages, and resolves dependencies via
`opkg info`. Only `python3-light` stdlib modules are required.

Usage:
    python3 install_pkg.py <package> [<package> ...]

Examples:
    python3 install_pkg.py python3-ctypes     # on-device UI for VENUS
    python3 install_pkg.py python3-openssl    # online footprint check
"""

import gzip
import io
import os
import re
import subprocess
import sys
import tarfile


def sh(cmd, timeout=180):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout)
    except Exception as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def installed(pkg):
    """Best-effort: is this package already installed?"""
    r = sh(["opkg", "list-installed"])
    if re.search(r"(?m)^%s[ \t]" % re.escape(pkg), r.stdout or ""):
        return True
    r2 = sh(["opkg", "status", pkg])
    return bool((r2.stdout or "").strip())


def opkg_info(pkg):
    return (sh(["opkg", "info", pkg]).stdout or "")


def parse_depends(info):
    """Return package names from a `Depends:` line (first alt, no version)."""
    m = re.search(r"(?m)^Depends:\s*(.*)$", info)
    if not m:
        return []
    deps = []
    for alt in m.group(1).split(","):
        alt = alt.strip()
        if not alt:
            continue
        first = alt.split("|")[0].strip()
        first = re.split(r"\s*[()<>=]", first)[0].strip()
        if first:
            deps.append(first)
    return deps


def collect(pkg, seen, order):
    """Post-order list of missing packages (dependencies first)."""
    if pkg in seen or installed(pkg):
        return
    seen.add(pkg)
    for dep in parse_depends(opkg_info(pkg)):
        collect(dep, seen, order)
    order.append(pkg)


def download(pkg, workdir="/tmp"):
    sh(["opkg", "download", pkg])
    for f in sorted(os.listdir(workdir)):
        if f.startswith(pkg + "_") and f.endswith(".ipk"):
            return os.path.join(workdir, f)
    return None


def install_ipk(path, dest="/"):
    """Unpack an OpenWrt .ipk (gzip'd tar of debian-binary/data/control)."""
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
        members = [m for m in inner.getmembers()
                   if m.name.lstrip("./").split("/", 1)[0] in
                   ("usr", "etc", "lib", "sbin", "bin")]
        inner.extractall(dest, members=members)
        count = len(members)
    return count


def main(argv):
    targets = [a for a in argv[1:] if not a.startswith("-")]
    if not targets:
        print(__doc__)
        return 2
    print("[*] updating package lists (opkg update)...")
    sh(["opkg", "update"])

    workdir = "/tmp"
    os.makedirs(workdir, exist_ok=True)
    os.chdir(workdir)

    seen = set()
    order = []
    for t in targets:
        collect(t, seen, order)

    if not order:
        print("nothing to do: all targets and dependencies are already "
              "installed")
        return 0

    print("[*] install plan: %s" % " ".join(order))
    failed = False
    for pkg in order:
        print("[*] installing %s ..." % pkg, flush=True)
        ipk = download(pkg, workdir)
        if not ipk:
            print("    ! download failed for %s" % pkg)
            failed = True
            continue
        n = install_ipk(ipk)
        print("    %s: %d files unpacked" % (pkg, n))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
