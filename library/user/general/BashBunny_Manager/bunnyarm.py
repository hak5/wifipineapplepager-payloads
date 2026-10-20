#!/usr/bin/env python3
"""BunnyArm — manage a docked BashBunny from the Pager via its ARMING-MODE serial console.
No bunny-side software needed: logs into the bunny's Debian console over /dev/ttyACM* and runs
shell commands. Subcommands: status | list | preview <relpath> | assign <1|2> <libpath> | swap | run <cmd>.
Port is expected pre-set to raw 115200 by the wrapper (or pass --stty to do it here)."""
import os, sys, time, select, argparse, re, base64, hashlib, shutil

def parse_readiness(text):
    """Return (attackmode, sorted_unique_tool_deps) from a payload.txt body."""
    am = ""
    m = re.search(r'^ATTACKMODE\s+(.*)$', text, re.M)
    if m:
        am = m.group(1).strip().split()[0] if m.group(1).strip() else ""
    deps = sorted(set(re.findall(r'/tools/[A-Za-z0-9._-]+', text)))
    return am, deps

def _safe_name(s):
    """True if s is safe to interpolate into a remote shell command (no shell metachars, no traversal)."""
    return bool(s) and re.match(r'^[A-Za-z0-9._/-]+$', s) is not None and '..' not in s

def parse_cfg(text):
    """Return [(key, rawvalue)] for top-level KEY=value assignments whose value is empty
    or a placeholder (CHANGE/REPLACE/YOUR/ENTER/TODO/EXAMPLE/PLACEHOLDER/XXX / <...>) -
    i.e. the settings a freshly-assigned payload still needs the operator to fill in."""
    out = []
    for line in text.splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2)
        v = raw.strip().strip('"').strip("'"); vu = v.upper()
        if (v == "" or v.startswith("<")
                or vu.startswith("XXX")
                or any(t in vu for t in ("CHANGE", "REPLACE", "YOUR", "ENTER", "TODO", "EXAMPLE", "PLACEHOLDER"))):
            out.append((key, raw))
    return out

PW = os.environ.get("BUNNY_PW", "hak5bunny")
USER = os.environ.get("BUNNY_USER", "root")
# In arming mode the bunny exports udisk as mass storage, so /root/udisk is unmounted. The udisk
# backing partition is /dev/nandf — mount it ourselves (it is NOT the exported LUN on this unit).
UDISK_DEV = os.environ.get("BUNNY_UDISK_DEV", "/dev/nandf")
MNT = "/mnt/bunnyarm_udisk"
PAYLOADS = MNT + "/payloads"

def open_port(port, do_stty):
    if do_stty: os.system("stty -F %s 115200 raw -echo 2>/dev/null" % port)
    return os.open(port, os.O_RDWR | os.O_NOCTTY)

def w(fd, s): os.write(fd, s.encode())

def read_until(fd, pats, timeout=8):
    buf = ""; end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try: d = os.read(fd, 4096).decode("utf-8", "replace")
            except OSError: break
            if not d: break
            buf += d
            for p in pats:
                if p in buf: return buf, p
    return buf, None

def drain(fd, t=0.5):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: os.read(fd, 4096)
            except OSError: break
        else: break

def shell_ok(fd):
    # Only a real shell evaluates arithmetic; a login prompt echoes the text literally.
    drain(fd, 0.2)
    w(fd, "echo RC=$((6*7))\r")
    buf, _ = read_until(fd, ["RC=42"], 4)
    return "RC=42" in buf

def login(fd):
    drain(fd)
    if shell_ok(fd):
        w(fd, "stty -echo 2>/dev/null\r"); drain(fd, 0.5); return True
    # not a shell — trigger + drive the getty login
    w(fd, "\r"); buf, _ = read_until(fd, ["login:", "assword"], 5)
    if "login:" in buf:
        w(fd, USER + "\r"); read_until(fd, ["assword"], 6); w(fd, PW + "\r"); drain(fd, 2.0)
    elif "assword" in buf:
        w(fd, PW + "\r"); drain(fd, 2.0)
    if shell_ok(fd):
        w(fd, "stty -echo 2>/dev/null\r"); drain(fd, 0.5); return True
    return False

S, E = "@@BZS@@", "@@BZE@@"
def run(fd, cmd, timeout=15):
    drain(fd, 0.2)
    w(fd, "echo %s; %s; echo %s\r" % (S, cmd, E))
    buf, _ = read_until(fd, [E], timeout)
    buf = buf.replace("\r", "")
    if S in buf and E in buf.split(S, 1)[1]:
        return buf.split(S, 1)[1].split(E, 1)[0].strip("\n")
    return ""

def _remote_sha(fd, path, timeout=15):
    return run(fd, "sha256sum '%s' 2>/dev/null | cut -d' ' -f1" % path, timeout=timeout).strip()

def _remote_list_files(fd, remote_dir, timeout=30):
    """Relative file paths under remote_dir (bunny side)."""
    out = run(fd, "cd '%s' 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\\./##'" % remote_dir, timeout=timeout)
    return [l for l in out.splitlines() if l.strip()]

def _local_list_files(local_dir):
    out = []
    for root, _, names in os.walk(local_dir):
        for n in names:
            out.append(os.path.relpath(os.path.join(root, n), local_dir))
    return out

def pull_file(fd, remote_path, local_path, timeout=60):
    """Download remote_path (bunny) to local_path (Pager), verified by sha256."""
    if "'" in remote_path or "'" in local_path:
        return False
    sha_remote = _remote_sha(fd, remote_path)
    if not sha_remote:
        return False
    b64 = run(fd, "base64 '%s' 2>/dev/null | tr -d '\\n'" % remote_path, timeout=timeout)
    try:
        data = base64.b64decode(b64)
    except Exception:
        return False
    d = os.path.dirname(local_path)
    if d: os.makedirs(d, exist_ok=True)
    with open(local_path, "wb") as f: f.write(data)
    return hashlib.sha256(data).hexdigest() == sha_remote

def push_file(fd, local_path, remote_path, timeout=60):
    """Upload local_path (Pager) to remote_path (bunny), verified by sha256. Chunked to keep console lines short."""
    if "'" in local_path or "'" in remote_path:
        return False
    with open(local_path, "rb") as f: data = f.read()
    b64 = base64.b64encode(data).decode()
    sha_local = hashlib.sha256(data).hexdigest()
    tmp = remote_path + ".b64"
    run(fd, "mkdir -p '%s'; rm -f '%s'" % (os.path.dirname(remote_path), tmp), timeout=10)
    CHUNK = 4000
    for i in range(0, len(b64), CHUNK):
        run(fd, "printf '%%s' '%s' >> '%s'" % (b64[i:i + CHUNK], tmp), timeout=timeout)
    run(fd, "base64 -d '%s' > '%s' 2>/dev/null && rm -f '%s'" % (tmp, remote_path, tmp), timeout=timeout)
    return _remote_sha(fd, remote_path) == sha_local

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyACM2")
    ap.add_argument("--stty", action="store_true")
    ap.add_argument("cmd", nargs="+")
    a = ap.parse_args()
    fd = open_port(a.port, a.stty)
    if not login(fd):
        print("[bunnyarm] login failed on %s" % a.port); sys.exit(1)
    # mount the udisk so payloads are reachable (arming mode leaves it unmounted)
    m = run(fd, "mkdir -p %s; mountpoint -q %s || mount %s %s 2>&1; ls -d %s >/dev/null 2>&1 && echo MOK || echo MFAIL"
                % (MNT, MNT, UDISK_DEV, MNT, PAYLOADS))
    if "MOK" not in m:
        print("[bunnyarm] could not mount udisk (%s): %s" % (UDISK_DEV, m)); os.close(fd); sys.exit(1)
    sub = a.cmd[0]; rest = a.cmd[1:]
    if sub == "status":
        print("backend: console")
        print("bunny:   " + run(fd, "hostname"))
        print("kernel:  " + run(fd, "uname -r"))
        for s in ("1", "2"):
            t = run(fd, "grep -m1 -i '^# *Title:' %s/switch%s/payload.txt 2>/dev/null | sed 's/^#.*[Tt]itle: *//' || true" % (PAYLOADS, s))
            print("switch%s: %s" % (s, t.strip() or "(empty)"))
        print("udisk:   " + run(fd, "df -h %s | awk 'NR==2{print $4\" free / \"$2}'" % PAYLOADS))
    elif sub == "switches":
        for s in ("1", "2"):
            exists = run(fd, "[ -f %s/switch%s/payload.txt ] && echo Y || echo N" % (PAYLOADS, s)).strip()
            if exists != "Y":
                print("SW%s = (empty)" % s); continue
            t = run(fd, "grep -m1 -i '^# *Title:' %s/switch%s/payload.txt 2>/dev/null | sed 's/^#.*[Tt]itle: *//'" % (PAYLOADS, s)).strip() or "(untitled)"
            v = run(fd, "grep -m1 -i '^# *Version:' %s/switch%s/payload.txt 2>/dev/null | sed 's/^#.*[Vv]ersion: *//'" % (PAYLOADS, s)).strip()
            if v:
                t = "%s v%s" % (t, v)
            print("SW%s = %s" % (s, t))
    elif sub == "list":
        print(run(fd, "ls -1 %s/library" % PAYLOADS))
    elif sub == "libpayloads":
        # every assignable payload under library, as "category/Name" (one per line)
        print(run(fd, "cd %s/library 2>/dev/null && find . -name payload.txt 2>/dev/null | sed 's#^\\./##; s#/payload.txt$##' | sort" % PAYLOADS, timeout=20))
    elif sub == "preview":
        print(run(fd, "head -20 %s/%s" % (PAYLOADS, rest[0])))
    elif sub == "assign":
        sw, lib = rest[0], rest[1]
        if sw not in ("1", "2"):
            print("ERR bad switch: %s" % sw)
        elif not _safe_name(lib):
            print("ERR bad name: %s" % lib)
        else:
            print(run(fd, "rm -rf %s/switch%s && mkdir -p %s/switch%s && cp -a %s/library/%s/. %s/switch%s/ && sync && echo assigned '%s' to switch%s || echo FAILED"
                          % (PAYLOADS, sw, PAYLOADS, sw, PAYLOADS, lib, PAYLOADS, sw, lib, sw)))
    elif sub == "swap":
        print(run(fd, "cd %s && rm -rf .swap && mv switch1 .swap && mv switch2 switch1 && mv .swap switch2 && sync && echo swapped" % PAYLOADS))
    elif sub == "run":
        print(run(fd, " ".join(rest), timeout=30))
    elif sub == "clear-switch":
        sw = rest[0]
        if sw not in ("1", "2"):
            print("ERR bad switch: %s" % sw)
        else:
            print(run(fd, "rm -rf %s/switch%s && mkdir -p %s/switch%s && sync && echo OK cleared switch%s"
                          % (PAYLOADS, sw, PAYLOADS, sw, sw)))
    elif sub == "loot-list":
        print(run(fd, "cd %s/loot 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\\./##' | sort "
                      "| while IFS= read -r r; do printf '%%s\\t%%s\\n' \"$(wc -c < \"$r\" | tr -d ' ')\" \"$r\"; done" % MNT, timeout=30))
    elif sub == "loot-empty":
        print(run(fd, "rm -rf %s/loot/* %s/loot/.[!.]* 2>/dev/null; mkdir -p %s/loot; sync; echo OK emptied loot" % (MNT, MNT, MNT)))
    elif sub == "delete-lib":
        lib = rest[0]
        if not _safe_name(lib):
            print("ERR bad name: %s" % lib)
        else:
            print(run(fd, "d=%s/library/%s; [ -d \"$d\" ] && rm -rf \"$d\" && sync && echo OK deleted %s || echo ERR no such payload: %s"
                          % (PAYLOADS, lib, lib, lib)))
    elif sub == "readiness":
        sw = rest[0]
        if sw not in ("1", "2"):
            print("ERR bad switch: %s" % sw)
        else:
            exists = run(fd, "[ -f %s/switch%s/payload.txt ] && echo Y || echo N" % (PAYLOADS, sw)).strip()
            if exists != "Y":
                print("ERR switch%s empty" % sw)
            else:
                body = run(fd, "cat %s/switch%s/payload.txt 2>/dev/null" % (PAYLOADS, sw), timeout=20)
                am, deps = parse_readiness(body)
                print("ATTACKMODE: " + (am or "(none)"))
                miss = 0
                for dep in deps:
                    ex = run(fd, "[ -e %s%s ] && echo Y || echo N" % (MNT, dep))
                    if ex.strip() == "Y": print("present: " + dep)
                    else: print("MISSING: " + dep); miss += 1
                print("readiness: OK" if miss == 0 else "readiness: MISSING %d" % miss)
    elif sub == "cfg-list":
        sw = rest[0]
        if sw not in ("1", "2"):
            print("ERR bad switch: %s" % sw)
        else:
            body = run(fd, "cat %s/switch%s/payload.txt 2>/dev/null" % (PAYLOADS, sw), timeout=20)
            for k, v in parse_cfg(body):
                print("%s\t%s" % (k, v))
    elif sub == "cfg-set":
        sw, key, val = rest[0], rest[1], " ".join(rest[2:])
        if sw not in ("1", "2"):
            print("ERR bad switch: %s" % sw)
        elif not re.match(r'^[A-Za-z0-9_]+$', key):
            print("ERR bad key: %s" % key)
        else:
            b64 = base64.b64encode(val.encode()).decode()
            cmd = ("V=$(printf %%s '%s' | base64 -d); export V; f=%s/switch%s/payload.txt; "
                   "if [ -f \"$f\" ] && grep -q '^%s=' \"$f\"; then "
                   "awk -v k='%s' '{ if (index($0,k\"=\")==1) print k\"=\"ENVIRON[\"V\"]; else print }' \"$f\" > \"$f.t\" "
                   "&& mv \"$f.t\" \"$f\" && sync && echo 'OK set %s on switch%s'; "
                   "else echo 'ERR no such setting: %s'; fi"
                   ) % (b64, PAYLOADS, sw, key, key, key, sw, key)
            print(run(fd, cmd, timeout=20).strip())
    elif sub == "eject":
        run(fd, "sync")
        print("OK safe to undock")
    elif sub == "loot-pull":
        rel, destdir = rest[0], rest[1]
        remote = MNT + "/loot/" + rel
        local = os.path.join(destdir, rel)
        if pull_file(fd, remote, local):
            print("OK pulled %s" % rel)
        else:
            print("ERR pull failed: %s" % rel)
    elif sub == "loot-pull-all":
        destdir = rest[0]
        got = skip = 0
        for rel in _remote_list_files(fd, MNT + "/loot"):
            remote = MNT + "/loot/" + rel
            local = os.path.join(destdir, rel)
            remote_sha = _remote_sha(fd, remote)
            local_sha = ""
            if os.path.isfile(local):
                try:
                    with open(local, "rb") as f: local_sha = hashlib.sha256(f.read()).hexdigest()
                except OSError: pass
            if remote_sha and local_sha == remote_sha:
                skip += 1; continue
            if pull_file(fd, remote, local): got += 1
        print("OK pulled %d (%d skipped)" % (got, skip))
    elif sub == "upload":
        src, mode = rest[0], rest[1]
        cat = rest[2] if len(rest) > 2 else ""
        if mode == "file":
            name = os.path.splitext(os.path.basename(src))[0]
            if not os.path.isfile(src):
                print("ERR not a file: %s" % src)
            elif "'" in src:
                print("ERR bad name: %s" % src)
            elif not _safe_name(name):
                print("ERR bad name: %s" % name)
            else:
                remote_dir = "%s/library/uploaded/%s" % (PAYLOADS, name)
                run(fd, "mkdir -p '%s'" % remote_dir, timeout=10)
                if push_file(fd, src, remote_dir + "/payload.txt"):
                    run(fd, "sync"); print("OK uploaded file -> uploaded/%s" % name)
                else:
                    print("ERR upload failed")
        elif mode == "dir":
            cat = cat or "uploaded"
            name = os.path.basename(os.path.normpath(src))
            if not os.path.isdir(src):
                print("ERR not a dir: %s" % src)
            elif not _safe_name(cat):
                print("ERR bad category: %s" % cat)
            elif "'" in src:
                print("ERR bad name: %s" % src)
            elif not _safe_name(name):
                print("ERR bad name: %s" % name)
            else:
                remote_dir = "%s/library/%s/%s" % (PAYLOADS, cat, name)
                run(fd, "rm -rf '%s'; mkdir -p '%s'" % (remote_dir, remote_dir), timeout=15)
                ok = True
                for rel in _local_list_files(src):
                    if not push_file(fd, os.path.join(src, rel), remote_dir + "/" + rel): ok = False
                if ok:
                    run(fd, "sync"); print("OK uploaded dir -> %s/%s" % (cat, name))
                else:
                    print("ERR upload failed")
        elif mode == "sync":
            if not os.path.isdir(src):
                print("ERR not a dir: %s" % src)
            else:
                lib = "%s/library" % PAYLOADS
                run(fd, "mkdir -p '%s'" % lib, timeout=10)
                ok = True
                for rel in _local_list_files(src):
                    if not push_file(fd, os.path.join(src, rel), lib + "/" + rel): ok = False
                if ok:
                    run(fd, "sync"); print("OK synced staging -> library")
                else:
                    print("ERR upload failed")
        else:
            print("ERR bad mode: %s (file|dir|sync)" % mode)
    elif sub == "backup":
        destdir = rest[0]
        os.makedirs(destdir, exist_ok=True)
        manifest = []
        for s in ("1", "2"):
            remote_dir = "%s/switch%s" % (PAYLOADS, s)
            local_dir = os.path.join(destdir, "switch%s" % s)
            shutil.rmtree(local_dir, ignore_errors=True)
            os.makedirs(local_dir, exist_ok=True)
            for rel in _remote_list_files(fd, remote_dir):
                pull_file(fd, remote_dir + "/" + rel, os.path.join(local_dir, rel))
            title = run(fd, "grep -m1 -iE '^# *[Tt]itle:' %s/payload.txt 2>/dev/null | sed 's/^#.*[Tt]itle: *//'" % remote_dir, timeout=15).strip()
            manifest.append("switch%s: %s" % (s, title or "(empty)"))
        tmp_manifest = os.path.join(destdir, "manifest.txt.tmp")
        with open(tmp_manifest, "w") as f:
            f.write("\n".join(manifest) + "\n")
        os.replace(tmp_manifest, os.path.join(destdir, "manifest.txt"))
        print("OK backed up -> %s" % destdir)
    elif sub == "restore":
        srcdir = rest[0]
        if not os.path.isdir(os.path.join(srcdir, "switch1")):
            print("ERR no backup at: %s" % srcdir)
        else:
            for s in ("1", "2"):
                local_dir = os.path.join(srcdir, "switch%s" % s)
                if not os.path.isdir(local_dir):
                    continue
                remote_dir = "%s/switch%s" % (PAYLOADS, s)
                run(fd, "rm -rf '%s'; mkdir -p '%s'" % (remote_dir, remote_dir), timeout=15)
                for rel in _local_list_files(local_dir):
                    push_file(fd, os.path.join(local_dir, rel), remote_dir + "/" + rel)
            run(fd, "sync")
            print("OK restored from %s" % srcdir)
    else:
        print("usage: status | list | preview <relpath> | assign <1|2> <lib> | swap | run <cmd> | "
              "clear-switch <n> | loot-list | loot-pull <rel> <destdir> | loot-pull-all <destdir> | "
              "loot-empty | upload <src> <file|dir|sync> [cat] | delete-lib <cat/Name> | "
              "backup <destdir> | restore <srcdir> | readiness <n> | eject")
    run(fd, "sync; umount %s 2>/dev/null" % MNT)      # flush + release so the bunny can remount cleanly
    os.close(fd)

if __name__ == "__main__":
    main()
