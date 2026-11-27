"""Upload keys for WiGLE, WDGWars and Wardrift, kept in a file only the user can read."""

import base64
import binascii
import json
import os
from pathlib import Path
import re

PATH = Path(os.environ.get("QUARTERMASTER_ACCOUNTS",
                           str(Path.home() / ".config" / "quartermaster" / "accounts.json")))

# (field, label, where to find it)
FIELDS = [
    ("wigle_name", "WiGLE API name", "wigle.net, Account page, Show My Token"),
    ("wigle_token", "WiGLE API token", "wigle.net, Account page, Show My Token"),
    ("wdgwars_key", "WDGWars API key", "wdgwars.pl, Profile, Generate API key"),
    ("wardrift_key", "Wardrift API key", "wardrift.net, Dashboard, API Keys"),
]
SERVICES = {"wigle": ("wigle_name", "wigle_token"), "wdgwars": ("wdgwars_key",), "wardrift": ("wardrift_key",)}
SERVICE_NAMES = {"wigle": "WiGLE", "wdgwars": "WDGWars", "wardrift": "Wardrift"}
MAX_LENGTH = 200


def clean(value):
    """Keys are pasted from web pages: drop spaces, line breaks and anything unprintable."""
    return "".join(ch for ch in str(value or "") if "!" <= ch <= "~")[:MAX_LENGTH]


def split_encoded(value):
    """WiGLE also shows one "Encoded for use" string: base64 of name:token. Returns (name, token) or None."""
    text = clean(value)
    if text.lower().startswith("basic"):
        text = text[5:]
    try:
        decoded = base64.b64decode(text, validate=True).decode("ascii")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    name, colon, token = decoded.partition(":")
    if colon and re.fullmatch(r"[!-9;-~]{8,}", name) and re.fullmatch(r"[!-~]{8,}", token):
        return name, token
    return None


def load(path=None):
    try:
        data = json.loads(Path(path or PATH).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    return {field: clean(data.get(field)) for field, _, _ in FIELDS}


def save(accounts, path=None):
    path = Path(path or PATH)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name("." + path.name)
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump({field: clean(accounts.get(field)) for field, _, _ in FIELDS}, out, indent=1)
        out.write("\n")
    os.replace(tmp, path)


def update(changes, path=None):
    """Merge new values into the stored keys. A pasted WiGLE "Encoded for use" string fills both fields."""
    accounts = load(path)
    for field, value in changes.items():
        if field == "wigle_encoded":
            pair = split_encoded(value)
            if pair:
                accounts["wigle_name"], accounts["wigle_token"] = pair
        elif field in accounts:
            accounts[field] = clean(value)
    pair = split_encoded(accounts["wigle_name"]) if not accounts["wigle_token"] else None
    if pair:
        accounts["wigle_name"], accounts["wigle_token"] = pair
    save(accounts, path)
    return accounts


def configured(accounts, service):
    return all(accounts.get(field) for field in SERVICES[service])


def ready(accounts):
    return [service for service in SERVICES if configured(accounts, service)]


def wigle_basic(accounts):
    pair = "%s:%s" % (accounts["wigle_name"], accounts["wigle_token"])
    return base64.b64encode(pair.encode("ascii")).decode("ascii")


def masked(value):
    """Enough to recognise a key without showing it."""
    if not value:
        return ""
    return "••••" + value[-4:] if len(value) > 8 else "••••"


def stamp(path=None):
    """Changes whenever the keys are saved, so a rejected key is retried after an edit."""
    try:
        return Path(path or PATH).stat().st_mtime_ns
    except OSError:
        return 0
