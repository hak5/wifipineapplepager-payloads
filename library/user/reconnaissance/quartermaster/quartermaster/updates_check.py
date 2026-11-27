"""Asks the CardputerZero store, then GitHub, whether a newer Quartermaster is out. Nothing is downloaded."""

import json
import re
import urllib.error
import urllib.request

from . import __version__

REGISTRY = "https://cardputerzero.github.io/generated/registry.json"
RELEASES = "https://api.github.com/repos/valleytechsolutions/Quartermaster/releases/latest"
PI_RELEASES = "https://api.github.com/repos/valleytechsolutions/Quartermaster/releases?per_page=100"
PACKAGE = "quartermaster"
SHARE_CODE = "WARD"
TITLE = "Quartermaster"
TIMEOUT = 6.0
LARGEST = 4 << 20

LATEST, STORE, GITHUB, OFFLINE, UNKNOWN = "latest", "store", "github", "offline", "unknown"
OFFLINE_TEXT = "Could not check. Is Wi-Fi connected?"
UNKNOWN_TEXT = "Could not check. Try again later."
_VERSION = re.compile(r"(?:(\d+):)?[vV]?(\d+(?:\.\d+)*)(?:-(\d+(?:\.\d+)*))?")


def version_key(text):
    """Debian's order for plain dotted numbers with an optional epoch and revision, or None for anything else."""
    match = _VERSION.fullmatch(text.strip()) if isinstance(text, str) else None
    if match is None:
        return None
    upstream = tuple(int(part) for part in match.group(2).split("."))
    revision = tuple(int(part) for part in (match.group(3) or "0").split("."))
    return int(match.group(1) or 0), upstream, revision


def newer(found, current):
    found_key, current_key = version_key(found), version_key(current)
    return found_key is not None and current_key is not None and found_key > current_key


def plain(text):
    """A version as it is shown: without a "v" in front."""
    return str(text).strip().lstrip("vV")


def _package(app):
    download = app.get("download") if isinstance(app.get("download"), dict) else {}
    names = [app.get("package"), app.get("deb_package"), download.get("package")]
    return [name.strip().lower() for name in names if isinstance(name, str)]


def store_version(data):
    """The version of Quartermaster in the store's registry, or None when it is not listed there."""
    apps = data.get("apps") if isinstance(data, dict) else data
    if not isinstance(apps, list):
        return None
    apps = [app for app in apps if isinstance(app, dict)]

    def same(app):
        if PACKAGE in _package(app):
            return True
        return any(isinstance(app.get(key), str) and app[key].strip().lower() == value.lower()
                   for key, value in (("id", PACKAGE), ("uuid", PACKAGE), ("share_code", SHARE_CODE),
                                      ("title", TITLE)))
    for app in sorted(apps, key=lambda app: PACKAGE not in _package(app)):
        if same(app) and version_key(app.get("version")) is not None:
            return plain(app["version"])
    return None


def github_version(data):
    tag = data.get("tag_name") if isinstance(data, dict) else None
    return plain(tag) if version_key(tag) is not None else None


def fetch(url, current=__version__, timeout=TIMEOUT):
    request = urllib.request.Request(url, headers={"User-Agent": "Quartermaster/%s" % current,
                                                   "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(LARGEST + 1)


def _ask(opener, url, current, read):
    """(reached, version): reached is False when the request never got an answer."""
    try:
        body = opener(url, current)
    except urllib.error.HTTPError:
        return True, None
    except (OSError, ValueError):
        return False, None
    if not isinstance(body, bytes) or len(body) > LARGEST:
        return True, None
    try:
        return True, read(json.loads(body.decode("utf-8")))
    except (ValueError, UnicodeDecodeError, AttributeError, TypeError):
        return True, None


def check(current=__version__, opener=fetch):
    """(state, version, words for the screen). opener(url, current) returns the body of the answer."""
    reached, listed = _ask(opener, REGISTRY, current, store_version)
    if listed is not None and newer(listed, current):
        return STORE, listed, "%s is ready. Open the AppStore and press 7 to update it." % listed
    github_reached, released = _ask(opener, RELEASES, current, github_version)
    if released is not None and newer(released, current):
        return GITHUB, released, "%s is on GitHub. It reaches the AppStore after review." % released
    if listed is None and released is None:
        if not reached and not github_reached:
            return OFFLINE, None, OFFLINE_TEXT
        return UNKNOWN, None, UNKNOWN_TEXT
    return LATEST, plain(current), "You have the latest version (%s)." % plain(current)


def check_pi(current=__version__, opener=fetch):
    """Find the newest published pi-v tag with its version-matched Pi installer."""
    def pi_version(releases):
        versions = []
        for release in releases if isinstance(releases, list) else ():
            if not isinstance(release, dict) or release.get("draft"):
                continue
            tag = release.get("tag_name")
            if not isinstance(tag, str) or not re.fullmatch(r"pi-v\d+(?:\.\d+)+", tag):
                continue
            version = tag[4:]
            filename = "quartermaster-pi_%s_all.deb" % version
            assets = release.get("assets")
            if isinstance(assets, list) and any(isinstance(a, dict) and a.get("name") == filename for a in assets):
                versions.append(version)
        return max(versions, key=version_key, default=None)

    reached, released = _ask(opener, PI_RELEASES, current, pi_version)
    if not reached:
        return OFFLINE, None, OFFLINE_TEXT
    if released is None:
        return UNKNOWN, None, "Could not find a Raspberry Pi release with an installer."
    if newer(released, current):
        return GITHUB, released, "%s is ready. Install the Pi package from GitHub." % released
    return LATEST, plain(current), "Your Pi version (%s) is up to date." % plain(current)
