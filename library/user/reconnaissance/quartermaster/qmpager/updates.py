"""Whether a newer Pager payload is out, from the Quartermaster-Pager releases on GitHub."""

import re

from quartermaster import updates_check as u

from . import PAGER_VERSION

RELEASES = "https://api.github.com/repos/valleytechsolutions/Quartermaster-Pager/releases?per_page=50"


def released(releases):
    versions = []
    for release in releases if isinstance(releases, list) else ():
        if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
            continue
        tag = release.get("tag_name")
        if isinstance(tag, str) and re.fullmatch(r"v\d+(?:\.\d+)+", tag):
            versions.append(tag[1:])
    return max(versions, key=u.version_key, default=None)


def check_pager(current=PAGER_VERSION, opener=u.fetch):
    reached, found = u._ask(opener, RELEASES, current, released)
    if not reached:
        return u.OFFLINE, None, u.OFFLINE_TEXT
    if found is None:
        return u.LATEST, u.plain(current), "Your Pager payload (%s) is the newest." % u.plain(current)
    if u.newer(found, current):
        return u.GITHUB, found, "%s is ready. Get it from Hak5's payload library or the Quartermaster-Pager page." % found
    return u.LATEST, u.plain(current), "Your Pager payload (%s) is up to date." % u.plain(current)
