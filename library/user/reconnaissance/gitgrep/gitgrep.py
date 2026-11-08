#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GITGREP - GitHub / git secret hunter for the WiFi Pineapple Pager.

Scans a GitHub user, organisation or repository (or a local folder / local git
history) for credentials that were committed by mistake: cloud keys, API
tokens, private keys, webhooks and generic high-entropy secrets.

Design notes
------------
* Pure standard library.  Only ``python3-light`` is required; ``python3-openssl``
  is needed for HTTPS (the payload offers to install it).
* Remote scans stream the repository tarball straight into ``tarfile`` so a
  100 MB repo never has to fit in RAM.
* Findings are masked in the report by default.  ``--show`` reveals them.
* Nothing is ever written back to GitHub.  The tool is read-only.

Author: sinXne0
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import ssl
except ImportError:  # python3-light without python3-openssl
    ssl = None

VERSION = "1.0.0"
DEFAULT_LOOT = "/root/loot/gitgrep"
USER_AGENT = "GITGREP-Pager/" + VERSION
API = "https://api.github.com"


# --------------------------------------------------------------------------
# Detection rules
# --------------------------------------------------------------------------
# (name, severity, regex, mask_group, entropy_gated)
# mask_group == -1 means "mask the whole match" (group 0).
RULES = [
    ("private-key", "high",
     r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----",
     -1, False),
    ("aws-access-key-id", "high",
     r"\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b", -1, False),
    ("aws-secret-access-key", "high",
     r"(?i)\baws[_\- ]?(?:secret[_\- ]?)?access[_\- ]?key\b\s*[:=]\s*['\"]?([0-9A-Za-z/+]{40})['\"]?",
     1, True),
    ("github-token", "high",
     r"\b(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{36}\b", -1, False),
    ("github-fine-grained-pat", "high",
     r"\bgithub_pat_[0-9A-Za-z_]{82}\b", -1, False),
    ("gitlab-token", "high",
     r"\bglpat-[0-9A-Za-z_\-]{20,}\b", -1, False),
    ("slack-token", "high",
     r"\bxox[baprs]-[0-9A-Za-z\-]{10,72}\b", -1, False),
    ("slack-webhook", "high",
     r"https://hooks\.slack\.com/services/T[0-9A-Za-z_]+/B[0-9A-Za-z_]+/[0-9A-Za-z_]+",
     -1, False),
    ("discord-webhook", "high",
     r"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/[0-9]{17,20}/[A-Za-z0-9_\-]+",
     -1, False),
    ("stripe-live-key", "high",
     r"\b(?:sk|rk)_live_[0-9A-Za-z]{20,}\b", -1, False),
    ("stripe-test-key", "medium",
     r"\b(?:sk|rk)_test_[0-9A-Za-z]{20,}\b", -1, False),
    ("sendgrid-key", "high",
     r"\bSG\.[0-9A-Za-z_\-]{22}\.[0-9A-Za-z_\-]{43}\b", -1, False),
    ("mailgun-key", "medium",
     r"\bkey-[0-9a-zA-Z]{32}\b", -1, False),
    ("mailchimp-key", "high",
     r"\b[0-9a-f]{32}-us[0-9]{1,2}\b", -1, False),
    ("google-api-key", "high",
     r"\bAIza[0-9A-Za-z_\-]{35}\b", -1, False),
    ("google-oauth-client-secret", "high",
     r"\bGOCSPX-[0-9A-Za-z_\-]{28}\b", -1, False),
    ("gcp-service-account", "medium",
     r"\"type\"\s*:\s*\"service_account\"", -1, False),
    ("azure-storage-key", "high",
     r"AccountKey=[A-Za-z0-9+/=]{88}", -1, False),
    ("twilio-account-sid", "medium",
     r"\bAC[0-9a-fA-F]{32}\b", -1, False),
    ("telegram-bot-token", "high",
     r"\b[0-9]{8,10}:AA[0-9A-Za-z_\-]{33}\b", -1, False),
    ("npm-token", "high",
     r"\bnpm_[0-9A-Za-z]{36}\b", -1, False),
    ("pypi-token", "high",
     r"\bpypi-AgEIcHlwaS5vcmc[0-9A-Za-z_\-]{50,}\b", -1, False),
    ("anthropic-key", "high",
     r"\bsk-ant-[A-Za-z0-9_\-]{20,}\b", -1, False),
    ("openai-key", "medium",
     r"\bsk-(?!ant-)(?:proj-)?[A-Za-z0-9_\-]{32,}\b", -1, False),
    ("huggingface-token", "high",
     r"\bhf_[0-9A-Za-z]{34,}\b", -1, False),
    ("digitalocean-token", "high",
     r"\bdop_v1_[a-f0-9]{64}\b", -1, False),
    ("shopify-token", "high",
     r"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b", -1, False),
    ("postman-key", "high",
     r"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b", -1, False),
    ("newrelic-key", "high",
     r"\bNRAK-[A-Z0-9]{27}\b", -1, False),
    ("grafana-token", "medium",
     r"\bglc_[A-Za-z0-9+/]{32,}\b", -1, False),
    ("vault-token", "high",
     r"\bhvs\.[A-Za-z0-9_\-]{90,}\b", -1, False),
    ("age-secret-key", "high",
     r"\bAGE-SECRET-KEY-1[0-9A-Z]{58}\b", -1, False),
    ("jwt", "medium",
     r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b",
     -1, False),
    ("basic-auth-url", "medium",
     r"\b[a-z][a-z0-9+.\-]*://[^/\s:@]{1,64}:([^/\s@]{3,128})@[^/\s]+",
     1, True),
    ("facebook-access-token", "medium",
     r"\bEAACEdEose0cBA[0-9A-Za-z]+\b", -1, False),
    ("firebase-url", "low",
     r"https://[a-z0-9\-]+\.firebaseio\.com", -1, False),
    # Generic last so specific rules win dedupe.
    ("generic-secret", "low",
     r"(?i)\b(?:api[_\-]?key|apikey|secret[_\-]?key|secret|token|passwd|password|"
     r"auth[_\-]?token|access[_\-]?token|client[_\-]?secret|private[_\-]?key)\b"
     r"\s*[:=]\s*['\"]?([A-Za-z0-9_\-./+=]{12,120})['\"]?",
     1, True),
]

COMPILED_RULES = [(name, sev, re.compile(pat), grp, ent)
                  for (name, sev, pat, grp, ent) in RULES]

# Paths and formats that never contain useful secrets and cost a lot of time.
SKIP_DIRS = {
    ".git", "node_modules", "bower_components", "vendor", "dist", "build",
    "coverage", "__pycache__", ".venv", "venv", "site-packages", ".next",
    ".nuxt", "Pods", ".cache", ".tox", ".mypy_cache", ".pytest_cache",
}
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".tif", ".tiff",
    ".woff", ".woff2", ".ttf", ".eot", ".otf", ".mp3", ".mp4", ".m4a", ".wav",
    ".avi", ".mov", ".mkv", ".webm", ".zip", ".gz", ".tgz", ".bz2", ".xz",
    ".7z", ".rar", ".jar", ".war", ".exe", ".dll", ".so", ".dylib", ".bin",
    ".class", ".pyc", ".pyo", ".o", ".a", ".lib", ".db", ".sqlite", ".sqlite3",
    ".pdf", ".psd", ".ai", ".sketch", ".fig", ".lockb", ".map",
}
SKIP_NAMES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "composer.lock",
    "Gemfile.lock", "poetry.lock", "Cargo.lock", "go.sum",
}

PLACEHOLDER_RE = re.compile(
    r"(?i)(example|sample|placeholder|changeme|change_me|your[_-]|xxxx|todo|"
    r"redacted|dummy|fake|insert[_-]|replace[_-]|lorem|ipsum|notreal|invalid|"
    r"<[^>]+>|\$\{|%[A-Z_]+%|\{\{|^0{8,}$|^1{8,}$|^a{8,}$)"
)

BORING_VALUES = {
    "true", "false", "null", "none", "nil", "undefined", "string", "number",
    "boolean", "object", "array", "default", "required", "optional", "value",
    "secret", "token", "password", "apikey", "api_key", "api-key",
    "1234567890", "abcdefghij", "test123", "password123", "secret123",
}


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def entropy(value):
    """Shannon entropy in bits per character."""
    if not value:
        return 0.0
    counts = {}
    for ch in value:
        counts[ch] = counts.get(ch, 0) + 1
    n = float(len(value))
    return -sum((c / n) * math.log(c / n, 2) for c in counts.values())


def looks_placeholder(value):
    v = value.strip()
    if not v:
        return True
    if v.lower() in BORING_VALUES:
        return True
    if len(set(v)) <= 2:            # aaaaaaaa / 00000000
        return True
    if PLACEHOLDER_RE.search(v):
        return True
    return False


def mask(value, keep=4, with_len=True):
    """Redact a secret but keep enough to recognise it."""
    v = value.strip()
    suffix = " (len %d)" % len(v) if with_len else ""
    if len(v) <= 4:
        return "*" * len(v) + suffix
    if len(v) <= keep * 2 + 2:
        return v[:2] + "\u2026" + v[-2:] + suffix
    return v[:keep] + "\u2026" + v[-keep:] + suffix


def count_line(text, pos):
    return text.count("\n", 0, pos) + 1


def line_around(text, start, end):
    left = text.rfind("\n", 0, start) + 1
    right = text.find("\n", end)
    if right == -1:
        right = len(text)
    return text[left:right].strip()


def is_probably_binary(data):
    if b"\x00" in data[:4096]:
        return True
    # UTF-16 text is full of NULs and not worth scanning.
    return False


def slugify(value):
    out = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_")
    return out[:60] or "scan"


class State(object):
    """Counters shared by every scan mode."""

    def __init__(self, limits):
        self.limits = limits
        self.start = time.time()
        self.repos = 0
        self.files = 0
        self.bytes = 0
        self.findings = []
        self.skipped_big = 0
        self.errors = []
        self.stop = False
        self._seen = set()

    def out_of_time(self):
        return (time.time() - self.start) > self.limits["max_minutes"] * 60

    def full(self):
        return len(self.findings) >= self.limits["max_findings"]

    def record(self, finding):
        if self.full():
            self.stop = True
            return
        # Collapse the same secret found in both the working tree and in an
        # old commit, or repeated across commits.  The path keeps the file
        # name but drops the "@commit" suffix history adds.
        norm = re.sub(r"@[0-9a-f]{7,40}$", "", finding["path"])
        key = (finding["rule"], finding["repo"], norm, finding["secret_id"])
        if key in self._seen:
            return
        self._seen.add(key)
        self.findings.append(finding)


# --------------------------------------------------------------------------
# Core scanner
# --------------------------------------------------------------------------
def scan_text(text, location, state, show=False, line_offset=0):
    """Scan one decoded blob.  ``location`` is a display path."""
    if not text:
        return
    seen = set()
    for name, severity, rx, grp, ent_gated in COMPILED_RULES:
        if state.full():
            state.stop = True
            return
        hits = 0
        for m in rx.finditer(text):
            hits += 1
            if hits > 40:           # a single rule cannot flood one file
                break
            try:
                if grp == -1:
                    secret = m.group(0)
                else:
                    secret = m.group(grp) or ""
            except IndexError:
                continue
            if not secret:
                continue
            if looks_placeholder(secret):
                continue
            if ent_gated:
                if len(secret) < 12 or entropy(secret) < 3.2:
                    continue
                # Generic assignment: reject obvious code identifiers.
                if re.match(r"^[a-z_]+$", secret) and ":" not in secret:
                    continue
                if re.search(r"[\{\}\$\[\]]", secret):
                    continue
            line_no = count_line(text, m.start()) + line_offset
            # A blob can produce the same secret from several rules; keep the
            # first (most specific) rule because specific rules are listed
            # before generic-secret.
            key = (line_no, secret)
            if key in seen:
                continue
            seen.add(key)
            ctx = line_around(text, m.start(), m.end())
            if not show and secret in ctx:
                ctx = ctx.replace(secret, mask(secret, with_len=False), 1)
            state.record({
                "repo": location.get("repo", ""),
                "path": location.get("path", ""),
                "line": line_no,
                "rule": name,
                "severity": severity,
                "secret_id": hashlib.sha1(secret.encode("utf-8", "replace")).hexdigest()[:12],
                "match": secret if show else mask(secret),
                "context": _clip(ctx, 200) if show else _clip(ctx, 200),
                "commit": location.get("commit", ""),
                "author": location.get("author", ""),
                "date": location.get("date", ""),
            })


def _clip(value, limit):
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "\u2026"


def should_scan_path(path):
    base = os.path.basename(path)
    if base in SKIP_NAMES:
        return False
    ext = os.path.splitext(base)[1].lower()
    if ext in SKIP_EXT:
        return False
    if base.endswith(".min.js") or base.endswith(".min.css"):
        return False
    parts = path.replace("\\", "/").split("/")
    for part in parts[:-1]:
        if part in SKIP_DIRS:
            return False
    return True


def scan_bytes(data, location, state, show=False):
    if len(data) > state.limits["max_file_bytes"]:
        state.skipped_big += 1
        return
    if is_probably_binary(data):
        return
    state.files += 1
    state.bytes += len(data)
    text = data.decode("utf-8", "replace")
    scan_text(text, location, state, show=show)


# --------------------------------------------------------------------------
# Local folder / history
# --------------------------------------------------------------------------
def scan_local(root, state, show=False):
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        raise SystemExit("Not a directory: %s" % root)
    print("[*] local folder: %s" % root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames
                             if d not in SKIP_DIRS and d != ".git")
        for name in sorted(filenames):
            if state.stop or state.out_of_time():
                state.stop = True
                return
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if not should_scan_path(rel):
                continue
            try:
                size = os.path.getsize(full)
                if size > state.limits["max_file_bytes"]:
                    state.skipped_big += 1
                    continue
                with open(full, "rb") as fh:
                    data = fh.read(state.limits["max_file_bytes"] + 1)
            except (IOError, OSError) as exc:
                state.errors.append("%s: %s" % (rel, exc))
                continue
            scan_bytes(data, {"repo": "local", "path": rel}, state, show=show)
            if state.files % 100 == 0:
                print("[*] %d files, %d findings" % (state.files, len(state.findings)))


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def scan_git_history(root, state, show=False, max_commits=300, repo="history"):
    """Scan added lines in ``git log -p`` output.  Added lines only keeps the
    run fast and matches what a reviewer would call 'committed a secret'."""
    if not shutil.which("git"):
        print("[!] git not installed - history scan skipped")
        return
    if not os.path.isdir(os.path.join(root, ".git")):
        print("[!] %s is not a git repository - history scan skipped" % root)
        return
    print("[*] git history: %s (max %d commits)" % (root, max_commits))
    cmd = ["git", "-C", root, "log", "--all", "-p", "--no-color",
           "--no-ext-diff", "-n", str(max_commits),
           "--pretty=format:@@GITGREP@@%H%x09%an%x09%ad"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError as exc:
        state.errors.append("git log: %s" % exc)
        return
    commit = author = date = ""
    current_file = ""
    new_line = 0
    skip_file = True
    files_seen = set()
    try:
        for raw in proc.stdout:
            if state.stop or state.out_of_time():
                state.stop = True
                break
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("@@GITGREP@@"):
                commit, author, date = _split_commit(line)
                current_file = ""
                new_line = 0
                skip_file = True
                continue
            if line.startswith("diff --git "):
                continue
            if line.startswith("+++ b/"):
                current_file = line[6:]
                skip_file = not should_scan_path(current_file)
                continue
            if line.startswith("+++ ") or line.startswith("--- "):
                continue
            hunk = HUNK_RE.match(line)
            if hunk:
                new_line = int(hunk.group(1)) - 1
                continue
            if line.startswith("\\"):        # "\ No newline at end of file"
                continue
            if line.startswith("+"):
                new_line += 1
                if skip_file or not current_file or not line[1:].strip():
                    continue
                if len(line) < 9:            # nothing a rule can match
                    continue
                loc = {"repo": repo, "path": current_file,
                       "commit": commit, "author": author, "date": date}
                scan_text(line[1:], loc, state, show=show,
                          line_offset=new_line - 1)
                if not state.stop:
                    files_seen.add(current_file)
                continue
            if line.startswith("-"):
                continue
            new_line += 1                    # context line
    finally:
        try:
            proc.stdout.close()
        except Exception:
            pass
        proc.wait()
    state.files += len(files_seen)


def _split_commit(line):
    payload = line[len("@@GITGREP@@"):]
    parts = payload.split("\t")
    while len(parts) < 3:
        parts.append("")
    return parts[0], parts[1], parts[2]


# --------------------------------------------------------------------------
# GitHub client
# --------------------------------------------------------------------------
class GitHubError(Exception):
    def __init__(self, code, body):
        self.code = code
        self.body = body
        Exception.__init__(self, "HTTP %s: %s" % (code, body[:200]))


class LimitedReader(object):
    def __init__(self, fh, limit):
        self.fh = fh
        self.limit = limit
        self.read_bytes = 0

    def read(self, size=-1):
        data = self.fh.read(size)
        self.read_bytes += len(data)
        if self.read_bytes > self.limit:
            raise GitHubError(0, "download exceeded limit of %d bytes" % self.limit)
        return data


class GitHub(object):
    def __init__(self, token=None, timeout=30):
        self.token = token
        self.timeout = timeout
        self.remaining = None
        self.reset = None
        self.insecure_fallback = False

    def headers(self, accept):
        h = {
            "User-Agent": USER_AGENT,
            "Accept": accept,
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        return h

    def open(self, url, accept="application/vnd.github+json"):
        req = urllib.request.Request(url, headers=self.headers(accept))
        try:
            return self._open(req)
        except urllib.error.HTTPError as exc:
            body = b""
            try:
                body = exc.read(4000)
            except Exception:
                pass
            raise GitHubError(exc.code, body.decode("utf-8", "replace"))
        except urllib.error.URLError as exc:
            raise GitHubError(0, str(exc))

    def _open(self, req):
        try:
            resp = urllib.request.urlopen(req, timeout=self.timeout)
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", None)
            text = str(exc)
            if ssl is not None and (
                    isinstance(reason, ssl.SSLError) or
                    "CERTIFICATE_VERIFY_FAILED" in text):
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                self.insecure_fallback = True
                resp = urllib.request.urlopen(req, timeout=self.timeout, context=ctx)
            else:
                raise
        self._track(resp)
        return resp

    def _track(self, resp):
        try:
            rem = resp.headers.get("X-RateLimit-Remaining")
            if rem is not None:
                self.remaining = int(rem)
            reset = resp.headers.get("X-RateLimit-Reset")
            if reset is not None:
                self.reset = int(reset)
        except Exception:
            pass

    def get_json(self, url):
        resp = self.open(url)
        try:
            data = resp.read()
        finally:
            resp.close()
        try:
            return json.loads(data.decode("utf-8", "replace"))
        except ValueError:
            raise GitHubError(0, "invalid JSON from " + url)

    def check_quota(self):
        if self.remaining is not None and self.remaining <= 1:
            when = ""
            if self.reset:
                when = time.strftime(" (resets %H:%M:%S)", time.localtime(self.reset))
            raise GitHubError(403, "GitHub API rate limit exhausted%s. "
                                   "Add a token for 5000 requests/hour." % when)


# --------------------------------------------------------------------------
# GitHub target discovery
# --------------------------------------------------------------------------
def parse_target(target):
    """Return ('repo', owner, name) or ('user', login) or ('org', login)."""
    t = target.strip()
    t = re.sub(r"^git@([^:]+):", r"\1/", t)      # git@github.com:owner/repo
    t = re.sub(r"^(?:https?|ssh)://", "", t)
    t = re.sub(r"^[^/@]+@", "", t)               # ssh://git@github.com/...
    t = re.sub(r"^www\.", "", t)
    t = re.sub(r"^github\.com/", "", t)
    t = t.strip("/")
    t = re.sub(r"\.git$", "", t)
    t = t.split("?")[0].split("#")[0]
    parts = [p for p in t.split("/") if p]
    if len(parts) >= 2:
        return ("repo", parts[0], parts[1])
    if len(parts) == 1:
        return ("unknown", parts[0])
    raise SystemExit("Could not parse target: %r" % target)


def resolve_login(gh, login):
    """Decide whether a single name is a user or an organisation."""
    try:
        data = gh.get_json(API + "/users/" + urllib.parse.quote(login))
        return data.get("type", "User")
    except GitHubError as exc:
        if exc.code == 404:
            raise SystemExit("GitHub account not found: %s" % login)
        raise


def list_repos(gh, login, kind, limit, include_forks=False):
    repos = []
    page = 1
    per_page = 100
    base = API + ("/orgs/" if kind == "Organization" else "/users/")
    while len(repos) < limit and page <= 10:
        gh.check_quota()
        url = "%s%s/repos?per_page=%d&page=%d&sort=updated" % (
            base, urllib.parse.quote(login), per_page, page)
        batch = gh.get_json(url)
        if not isinstance(batch, list) or not batch:
            break
        for repo in batch:
            if repo.get("fork") and not include_forks:
                continue
            repos.append(repo)
            if len(repos) >= limit:
                break
        if len(batch) < per_page:
            break
        page += 1
    return repos


# --------------------------------------------------------------------------
# Remote scanning
# --------------------------------------------------------------------------
def scan_remote_repo(gh, repo, state, show=False, ref=None):
    owner = repo["owner"]["login"]
    name = repo["name"]
    label = "%s/%s" % (owner, name)
    branch = ref or repo.get("default_branch") or "main"
    size_kb = int(repo.get("size") or 0)
    if size_kb > state.limits["max_repo_kb"]:
        msg = "[!] skip %s: %d KB exceeds --max-repo-kb=%d" % (
            label, size_kb, state.limits["max_repo_kb"])
        print(msg)
        state.errors.append(msg)
        return
    state.repos += 1
    print("[*] repo %s (%s, %d KB)" % (label, branch, size_kb))
    url = "%s/repos/%s/%s/tarball/%s" % (
        API, urllib.parse.quote(owner), urllib.parse.quote(name),
        urllib.parse.quote(branch))
    try:
        resp = gh.open(url, accept="application/vnd.github+json")
    except GitHubError as exc:
        state.errors.append("%s: %s" % (label, exc))
        print("[!] %s: %s" % (label, exc))
        return
    limit_bytes = state.limits["max_tarball_bytes"]
    reader = LimitedReader(resp, limit_bytes)
    try:
        tf = tarfile.open(fileobj=reader, mode="r|gz")
        for member in tf:
            if state.stop or state.out_of_time():
                state.stop = True
                break
            if not member.isfile():
                continue
            # Tarball paths are "owner-repo-sha/path/to/file".
            parts = member.name.split("/", 1)
            rel = parts[1] if len(parts) == 2 else member.name
            if not should_scan_path(rel):
                continue
            if member.size > state.limits["max_file_bytes"]:
                state.skipped_big += 1
                continue
            try:
                fh = tf.extractfile(member)
                if fh is None:
                    continue
                data = fh.read(state.limits["max_file_bytes"] + 1)
            except (IOError, OSError, tarfile.TarError):
                continue
            scan_bytes(data, {"repo": label, "path": rel}, state, show=show)
            if state.files % 100 == 0:
                print("[*] %s: %d files, %d findings" % (
                    label, state.files, len(state.findings)))
    except (tarfile.TarError, GitHubError) as exc:
        state.errors.append("%s: %s" % (label, exc))
        print("[!] %s: %s" % (label, exc))
    finally:
        try:
            resp.close()
        except Exception:
            pass


def scan_gists(gh, login, state, show=False):
    print("[*] gists for %s" % login)
    try:
        gists = gh.get_json("%s/users/%s/gists?per_page=100" % (
            API, urllib.parse.quote(login)))
    except GitHubError as exc:
        print("[!] gists: %s" % exc)
        return
    if not isinstance(gists, list):
        return
    for gist in gists[: state.limits["max_gists"]]:
        if state.stop or state.out_of_time():
            state.stop = True
            return
        for fname, meta in (gist.get("files") or {}).items():
            if state.stop:
                return
            size = int(meta.get("size") or 0)
            if size > state.limits["max_file_bytes"]:
                state.skipped_big += 1
                continue
            raw_url = meta.get("raw_url")
            if not raw_url:
                continue
            try:
                resp = gh.open(raw_url, accept="*/*")
                data = resp.read(state.limits["max_file_bytes"] + 1)
                resp.close()
            except (GitHubError, IOError, OSError) as exc:
                state.errors.append("gist %s/%s: %s" % (gist.get("id"), fname, exc))
                continue
            scan_bytes(data, {"repo": "gist:" + (gist.get("id") or "?")[:12],
                              "path": fname}, state, show=show)


def clone_for_history(gh, repo, state, show=False):
    """Shallow-ish partial clone so history can be scanned without burning
    GitHub API quota (git talks to github.com directly)."""
    if not shutil.which("git"):
        print("[!] git not installed - remote history scan skipped")
        return
    owner = repo["owner"]["login"]
    name = repo["name"]
    label = "%s/%s" % (owner, name)
    size_kb = int(repo.get("size") or 0)
    if size_kb > state.limits["max_repo_kb"]:
        print("[!] skip history for %s: %d KB" % (label, size_kb))
        return
    tmp = "/tmp/gitgrep-clone-%d" % os.getpid()
    if os.path.isdir(tmp):
        shutil.rmtree(tmp, ignore_errors=True)
    if gh.token:
        clone_url = "https://x-access-token:%s@github.com/%s/%s.git" % (
            urllib.parse.quote(gh.token, safe=""), owner, name)
    else:
        clone_url = "https://github.com/%s/%s.git" % (owner, name)
    print("[*] clone %s for history (partial)" % label)
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    cmd = ["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout",
           "--single-branch", clone_url, tmp]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, env=env,
                              timeout=max(60, state.limits["max_minutes"] * 60 // 2))
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", "replace")
            err = err.replace(gh.token or "\0", "***")
            state.errors.append("clone %s: %s" % (label, err.strip()[:200]))
            print("[!] clone failed for %s" % label)
            return
    except (OSError, subprocess.SubprocessError) as exc:
        state.errors.append("clone %s: %s" % (label, exc))
        return
    try:
        scan_git_history(tmp, state, show=show,
                         max_commits=state.limits["max_commits"], repo=label)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
def severity_rank(sev):
    return {"high": 0, "medium": 1, "low": 2}.get(sev, 3)


def build_summary(state):
    counts = {"high": 0, "medium": 0, "low": 0}
    for f in state.findings:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    return {
        "version": VERSION,
        "elapsed_seconds": round(time.time() - state.start, 1),
        "repos": state.repos,
        "files": state.files,
        "bytes": state.bytes,
        "skipped_large": state.skipped_big,
        "findings_total": len(state.findings),
        "high": counts["high"],
        "medium": counts["medium"],
        "low": counts["low"],
        "errors": state.errors,
    }


def write_reports(target, state, lootdir, show=False, preview_limit=15):
    os.makedirs(lootdir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = os.path.join(lootdir, "gitgrep-%s-%s" % (slugify(target), stamp))
    summary = build_summary(state)
    findings = sorted(state.findings,
                      key=lambda f: (severity_rank(f["severity"]),
                                     f["repo"], f["path"], f["line"]))

    # JSON
    with open(base + ".json", "w") as fh:
        json.dump({"summary": summary, "findings": findings}, fh, indent=2)

    # CSV
    with open(base + ".csv", "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["severity", "rule", "repo", "path", "line",
                         "secret_id", "match", "context", "commit", "author", "date"])
        for f in findings:
            writer.writerow([f["severity"], f["rule"], f["repo"], f["path"],
                             f["line"], f["secret_id"], f["match"],
                             f["context"], f["commit"], f["author"], f["date"]])

    # Human report
    lines = []
    lines.append("GITGREP report")
    lines.append("=" * 60)
    lines.append("target           : %s" % target)
    lines.append("generated        : %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    lines.append("mode             : %s" % ("revealed" if show else "masked"))
    lines.append("repos scanned    : %d" % summary["repos"])
    lines.append("files scanned    : %d" % summary["files"])
    lines.append("findings         : %d (high %d / medium %d / low %d)" % (
        summary["findings_total"], summary["high"], summary["medium"], summary["low"]))
    lines.append("elapsed          : %ss" % summary["elapsed_seconds"])
    if summary["skipped_large"]:
        lines.append("skipped (large)  : %d" % summary["skipped_large"])
    lines.append("")
    if not findings:
        lines.append("No secrets found.")
    else:
        for f in findings:
            lines.append("[%s] %s" % (f["severity"].upper(), f["rule"]))
            lines.append("  repo : %s" % f["repo"])
            lines.append("  file : %s:%s" % (f["path"], f["line"]))
            if f.get("commit"):
                lines.append("  at   : %s by %s (%s)" % (
                    f["commit"][:12], f.get("author", "?"), f.get("date", "?")))
            lines.append("  value: %s" % f["match"])
            lines.append("  code : %s" % f["context"])
            lines.append("  id   : %s" % f["secret_id"])
            lines.append("")
        # Reuse detection: same secret hash in more than one place.
        groups = {}
        for f in findings:
            groups.setdefault(f["secret_id"], []).append(f)
        reused = {k: v for k, v in groups.items() if len(v) > 1}
        if reused:
            lines.append("-" * 60)
            lines.append("REUSED SECRETS (same value in multiple places)")
            for sid, items in sorted(reused.items(), key=lambda kv: -len(kv[1]))[:20]:
                lines.append("  %s  x%d  %s" % (
                    sid, len(items), ", ".join(
                        sorted({"%s:%s" % (i["path"], i["line"]) for i in items})[:4])))
            lines.append("")
    if summary["errors"]:
        lines.append("-" * 60)
        lines.append("NOTES / ERRORS")
        for err in summary["errors"][:30]:
            lines.append("  " + err)
        lines.append("")

    report_path = base + ".txt"
    with open(report_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")

    # Compact preview for the Pager screen.
    preview = []
    for f in findings[:preview_limit]:
        preview.append("%-6s %s" % (f["severity"].upper(), f["rule"]))
        preview.append("  %s" % _clip("%s:%s" % (f["path"], f["line"]), 60))
        preview.append("  %s" % f["match"])
    if not findings:
        preview.append("No secrets found.")
    if len(findings) > preview_limit:
        preview.append("... and %d more" % (len(findings) - preview_limit))
    preview_path = base + ".preview.txt"
    with open(preview_path, "w") as fh:
        fh.write("\n".join(preview) + "\n")

    # latest.* convenience copies
    for suffix in (".json", ".csv", ".txt", ".preview.txt"):
        try:
            shutil.copyfile(base + suffix, os.path.join(lootdir, "latest" + suffix))
        except (IOError, OSError):
            pass
    try:
        with open(os.path.join(lootdir, "latest.path"), "w") as fh:
            fh.write(report_path + "\n")
    except (IOError, OSError):
        pass

    return summary, report_path, preview_path


# --------------------------------------------------------------------------
# Self test
# --------------------------------------------------------------------------
# Self-test fixtures are assembled from pieces so that the repository itself
# does not contain anything that looks like a live credential (GitHub push
# protection scans source, not runtime strings).
_M36 = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"      # exactly 36
_M40 = _M36 + "s9T0"                              # exactly 40
_MIXB = "Zx9Qw8Er7Ty6Ui5Op4AsDfGhJkLzXcVbNm"
_HEX32 = "a1B2c3D4e5F6a7B8c9D0e1F2a3B4c5D6"

SELF_TESTS = [
    ("private-key", "x = '''" + "-----BEGIN " + "RSA " + "PRIVATE KEY-----" + "'''"),
    ("aws-access-key-id", "key = '" + "AKIA" + "3Q7Z2XW5N4B6Y8T2" + "'"),
    ("aws-secret-access-key", "aws_secret_access_key = '" + _M40 + "'"),
    ("github-token", "token: " + "ghp_" + _M36),
    ("github-fine-grained-pat", "github_pat_" + "a" * 82),
    ("gitlab-token", "glpat-" + "Zx9Qw8Er7Ty6Ui5Op4As"),
    ("slack-token", "xoxb-" + "987654321098" + "-" + "876543210987" + "-" + _MIXB),
    ("slack-webhook", "https://hooks.slack.com/services/" + "T8Q2W9E4R" + "/" + "B7T3Y6U1I" + "/" + "Zx9Qw8Er7Ty6Ui5Op4AsDfGh"),
    ("discord-webhook", "https://discord.com/api/webhooks/" + "987654321098765432" + "/" + _MIXB),
    ("stripe-live-key", "sk_" + "live_" + _M40[:24]),
    ("sendgrid-key", "SG." + "a" * 22 + "." + "B" * 43),
    ("google-api-key", "AIza" + "Sy" + _M36[:33]),
    ("google-oauth-client-secret", "GOCSPX-" + "aB1cD2eF3gH4iJ5kL6mN7oP8qR9s"),
    ("gcp-service-account", '{"type": "service_account", "project_id": "x"}'),
    ("azure-storage-key", "AccountKey=" + "A" * 88),
    ("telegram-bot-token", "123456789:" + "AA" + "HdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1"),
    ("npm-token", "npm_" + _M36),
    ("pypi-token", "pypi-AgEIcHlwaS5vcmc" + "A" * 60),
    ("openai-key", "sk-" + "proj-" + _M40),
    ("anthropic-key", "sk-" + "ant-api03-" + _M36),
    ("huggingface-token", "hf_" + _M36[:34]),
    ("digitalocean-token", "dop_v1_" + "a1b2c3d4e5f6" * 5 + "a1b2"),
    ("shopify-token", "shpat_" + _HEX32),
    ("postman-key", "PMAK-" + "abcdef0123456789abcdef01" + "-" + "abcdef0123456789abcdef0123456789ab"),
    ("newrelic-key", "NRAK-" + "ZQ7X9M2P4R6T8V1W3Y5B7D9F2H4"),
    ("grafana-token", "glc_" + "aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1"),
    ("vault-token", "hvs." + "aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1" * 4),
    ("age-secret-key", "AGE-SECRET-KEY-1" + ("QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L" * 2)[:58]),
    ("jwt", "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
    ("basic-auth-url", "postgres://admin:" + "Zx9Qw8Er7Ty6" + "@db.example.net/app"),
    ("facebook-access-token", "EAACEdEose0cBA" + "a1B2c3D4e5F6g7H8"),
    ("firebase-url", "https://my-project-1234.firebaseio.com"),
]

SELF_CLEAN = [
    "api_key = os.environ['API_KEY']",
    "token = get_token(user)",
    "password = input('password: ')",
    "AKIAIOSFODNN7EXAMPLE",
    "secret = 'your_secret_here'",
    "token = 'changeme'",
    "url = 'https://example.com/path'",
    "key = 'aaaaaaaaaaaa'",
    "secret_key = config['secret_key']",
]


def run_self_test(show=False):
    print("GITGREP self-test v%s" % VERSION)
    failures = 0
    for rule, sample in SELF_TESTS:
        found = rule in _rules_hit(sample, show=show)
        status = "ok" if found else "FAIL"
        if not found:
            failures += 1
        print("  [%s] %-28s %s" % (status, rule, sample[:48]))
    for sample in SELF_CLEAN:
        hit = _rules_hit(sample, show=show)
        if hit:
            failures += 1
            print("  [FAIL] false positive: %s -> %s" % (sample[:48], hit))
        else:
            print("  [ok] clean                 %s" % sample[:48])
    print("")
    if failures:
        print("SELF-TEST FAILED: %d problem(s)" % failures)
        return 1
    print("SELF-TEST PASSED")
    return 0


def _rules_hit(text, show=False):
    state = State(default_limits())
    scan_text(text, {"repo": "test", "path": "test"}, state, show=show)
    return {f["rule"] for f in state.findings}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def default_limits():
    return {
        "max_repos": 30,
        "max_files": 5000,
        "max_file_bytes": 1024 * 1024,
        "max_tarball_bytes": 150 * 1024 * 1024,
        "max_repo_kb": 120000,
        "max_findings": 5000,
        "max_minutes": 15,
        "max_gists": 50,
        "max_commits": 300,
    }


def main(argv):
    parser = argparse.ArgumentParser(
        prog="gitgrep.py",
        description="GITGREP - GitHub / git secret hunter (read-only)")
    parser.add_argument("target", nargs="?",
                        help="GitHub user, org, owner/repo, or URL")
    parser.add_argument("--local", metavar="PATH",
                        help="scan a local folder instead of GitHub")
    parser.add_argument("--history", action="store_true",
                        help="also scan git history (local folder or remote clone)")
    parser.add_argument("--gists", action="store_true", default=True,
                        help="include gists for user/org targets (default on)")
    parser.add_argument("--no-gists", dest="gists", action="store_false")
    parser.add_argument("--forks", action="store_true",
                        help="include forked repositories")
    parser.add_argument("--ref", help="branch/tag to scan (remote repo only)")
    parser.add_argument("--token", help="GitHub token (or GITHUB_TOKEN env)")
    parser.add_argument("--loot", default=DEFAULT_LOOT,
                        help="output directory (default %s)" % DEFAULT_LOOT)
    parser.add_argument("--show", action="store_true",
                        help="reveal secrets in the report (default masked)")
    parser.add_argument("--json", action="store_true",
                        help="also print the JSON summary to stdout")
    parser.add_argument("--self-test", action="store_true",
                        help="run built-in detector tests and exit")
    parser.add_argument("--max-repos", type=int)
    parser.add_argument("--max-files", type=int)
    parser.add_argument("--max-file-bytes", type=int)
    parser.add_argument("--max-repo-kb", type=int)
    parser.add_argument("--max-tarball-mb", type=int)
    parser.add_argument("--max-minutes", type=int)
    parser.add_argument("--max-commits", type=int)
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()

    limits = default_limits()
    if args.max_repos is not None:
        limits["max_repos"] = args.max_repos
    if args.max_files is not None:
        limits["max_files"] = args.max_files
    if args.max_file_bytes is not None:
        limits["max_file_bytes"] = args.max_file_bytes
    if args.max_repo_kb is not None:
        limits["max_repo_kb"] = args.max_repo_kb
    if args.max_tarball_mb is not None:
        limits["max_tarball_bytes"] = args.max_tarball_mb * 1024 * 1024
    if args.max_minutes is not None:
        limits["max_minutes"] = args.max_minutes
    if args.max_commits is not None:
        limits["max_commits"] = args.max_commits

    if not args.local and not args.target:
        parser.error("provide a GitHub target or --local PATH")

    token = args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    state = State(limits)

    if args.local:
        target = "local:" + os.path.abspath(args.local)
        scan_local(args.local, state, show=args.show)
        if args.history and not state.stop:
            scan_git_history(args.local, state, show=args.show,
                             max_commits=limits["max_commits"], repo="local")
    else:
        target = args.target
        if ssl is None:
            print("[!] python3-openssl is missing; HTTPS will fail.")
            print("    Install it with: opkg install python3-openssl")
        gh = GitHub(token=token)
        kind, *rest = parse_target(args.target)
        if kind == "repo":
            owner, name = rest
            repo_url = "%s/repos/%s/%s" % (API, urllib.parse.quote(owner),
                                           urllib.parse.quote(name))
            try:
                gh.check_quota()
                repo = gh.get_json(repo_url)
            except GitHubError as exc:
                print("[!] cannot load %s/%s: %s" % (owner, name, exc))
                return 1
            scan_remote_repo(gh, repo, state, show=args.show, ref=args.ref)
            if args.history and not state.stop:
                clone_for_history(gh, repo, state, show=args.show)
        else:
            login = rest[0]
            acc_type = resolve_login(gh, login)
            print("[*] %s is %s" % (login, acc_type))
            repos = list_repos(gh, login, acc_type, limits["max_repos"],
                               include_forks=args.forks)
            print("[*] %d repositories to scan" % len(repos))
            for repo in repos:
                if state.stop or state.out_of_time():
                    break
                scan_remote_repo(gh, repo, state, show=args.show)
                if args.history and not state.stop:
                    clone_for_history(gh, repo, state, show=args.show)
            if args.gists and not state.stop:
                scan_gists(gh, login, state, show=args.show)
        if gh.insecure_fallback:
            state.errors.append("TLS certificate verification was disabled "
                                "(no CA bundle on device)")

    summary, report_path, preview_path = write_reports(
        target, state, args.loot, show=args.show)

    print("")
    print("summary: repos=%d files=%d findings=%d high=%d medium=%d low=%d" % (
        summary["repos"], summary["files"], summary["findings_total"],
        summary["high"], summary["medium"], summary["low"]))
    print("report: %s" % report_path)
    print("preview: %s" % preview_path)
    print("loot: %s" % args.loot)
    if args.json:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\n[!] interrupted")
        sys.exit(130)
