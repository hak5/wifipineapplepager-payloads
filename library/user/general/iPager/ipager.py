#!/usr/bin/env python3
# Title: iPager
# Description: Two Way Pager/Apple iMessage <-> Hak5 WiFi Pineapple Pager Relay
# Author: $p!ll_bl00d
# Version: 1.0
# Category: General/Notifications
#
# REQUIREMENTS: Mac running ipager.py on macOS on same network, SSH key auth configured
#
# DESCRIPTION:
#   Receives iMessage notifications, relays them to a Pineapple Pager over SSH,
#   and accepts replies typed on the pager's onboard keyboard (send-to list,
#   including a manual phone/email entry) to send back out as iMessages via
#   Messages.app (osascript).
#
# SETUP:
#   1. Configure SSH key auth from Mac -> Pager
#   2. Run this on macOS (Mac mini/MacBook) on the same network as the Pager
#   3. Grant Terminal/iTerm "Full Disk Access" in System Settings so it can
#      read ~/Library/Messages/chat.db
#   4. Install the matching payload.sh on the Pager - see its own header for
#      the on-device half of this (compose UI, button mapping, contact list).
#
# NOTES:
#   - Refuses to run a second copy of itself at once (~/.ipager.lock, PID
#     checked on startup)
#   - The outbox reply format is "IDX|message" for an existing numbered
#     contact, or "NEW:<phone-or-email>|message" for one typed manually on
#     the Pager; the latter also gets registered as a normal contact for
#     next time.

import os, sys, json, time, subprocess, sqlite3, re, unicodedata
from datetime import datetime

#############################################################################
# --- CONFIGURE
#############################################################################

PAGER_HOST     = "172.16.52.1"
PAGER_USER     = "root"
PAGER_SSH_KEY  = os.path.expanduser("~/.ssh/pager_rsa")
POLL_INTERVAL  = 3
MAX_MSG_LEN    = 72
DB             = os.path.expanduser("~/Library/Messages/chat.db")
STATE_FILE     = os.path.expanduser("~/.ipager_state")
CONTACTS_FILE  = os.path.expanduser("~/.ipager_contacts.json")

#############################################################################
# --- SQLITE (native module - fixes the multiline/pipe/emoji corruption bugs)
#############################################################################

def get_db_connection():
    # Read-only URI open so we never fight Messages.app for a write lock.
    uri = f"file:{DB}?mode=ro"
    return sqlite3.connect(uri, uri=True, timeout=5)


def fetch_new_messages(conn, last_date):
    cur = conn.execute(
        """
        SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me, h.id
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.date > ?
        ORDER BY m.date ASC
        """,
        (last_date,),
    )
    return cur.fetchall()


def fetch_last_n_messages(conn, n):
    cur = conn.execute(
        """
        SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me, h.id
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        ORDER BY m.date DESC
        LIMIT ?
        """,
        (n,),
    )
    return cur.fetchall()


def get_attachments(conn, message_rowid):
    cur = conn.execute(
        """
        SELECT a.filename, a.mime_type, a.transfer_name
        FROM message_attachment_join maj
        JOIN attachment a ON maj.attachment_id = a.ROWID
        WHERE maj.message_id = ?
        """,
        (message_rowid,),
    )
    return cur.fetchall()

#############################################################################
# --- attributedBody fallback (best-effort NSAttributedString text extraction)
#############################################################################

def extract_text_from_attributed_body(blob):
    """Best-effort pull of the plain string out of a typedstream-archived
    NSAttributedString. Not a full typedstream parser - just enough to
    recover the literal text Apple stores after the 'NSString' marker for
    the common case (short messages, emoji-only messages, tapbacks)."""
    if not blob:
        return None
    try:
        idx = blob.find(b"NSString")
        if idx == -1:
            return None
        idx += len(b"NSString")
        end = min(idx + 12, len(blob))
        i = idx
        length, pos = None, None
        while i < end:
            b = blob[i]
            if b == 0x81 and i + 3 <= len(blob):
                length = int.from_bytes(blob[i + 1:i + 3], "little")
                pos = i + 3
                break
            elif 0 < b < 0x80:
                cand_start = i + 1
                if cand_start + b <= len(blob):
                    try:
                        candidate = blob[cand_start:cand_start + b].decode("utf-8")
                        if any(ch.isalnum() or ch.isspace() for ch in candidate) or len(candidate) <= 8:
                            length, pos = b, cand_start
                            break
                    except UnicodeDecodeError:
                        pass
                i += 1
            else:
                i += 1
        if length is None or pos is None:
            return None
        raw = blob[pos:pos + length]
        text = raw.decode("utf-8", errors="ignore").strip()
        return text or None
    except Exception:
        return None

#############################################################################
# --- emoji -> description
#############################################################################

EMOJI_PATTERN = re.compile(
    "["
    "\U0001F300-\U0001FAFF"
    "\U00002600-\U000027BF"
    "\U00002300-\U000023FF"
    "\U00002B00-\U00002BFF"
    "\U0001F000-\U0001F0FF"
    "]",
    flags=re.UNICODE,
)
SKIP_CODEPOINTS = {0xFE0F, 0x200D}  # variation selector-16, zero-width joiner
REGIONAL_A = 0x1F1E6
REGIONAL_Z = 0x1F1FF


def describe_emoji(ch):
    try:
        return unicodedata.name(ch).title()
    except ValueError:
        return "Emoji"


def humanize_text(text):
    """Replace emoji (and flag pairs) with bracketed plain-text descriptions
    so the Pager never renders/receives a blank glyph it can't display."""
    if not text:
        return text
    out = []
    chars = list(text)
    i = 0
    while i < len(chars):
        ch = chars[i]
        cp = ord(ch)
        if cp in SKIP_CODEPOINTS:
            i += 1
            continue
        if (
            REGIONAL_A <= cp <= REGIONAL_Z
            and i + 1 < len(chars)
            and REGIONAL_A <= ord(chars[i + 1]) <= REGIONAL_Z
        ):
            l1 = chr(cp - REGIONAL_A + ord("A"))
            l2 = chr(ord(chars[i + 1]) - REGIONAL_A + ord("A"))
            out.append(f"[Flag:{l1}{l2}]")
            i += 2
            continue
        if EMOJI_PATTERN.match(ch):
            out.append(f"[{describe_emoji(ch)}]")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)

#############################################################################
# --- attachment descriptions (numbered, never blank)
#############################################################################

def describe_attachments(conn, message_rowid, counter_state):
    rows = get_attachments(conn, message_rowid)
    parts = []
    for filename, mime_type, transfer_name in rows:
        counter_state["n"] += 1
        num = counter_state["n"]
        name = transfer_name or (os.path.basename(filename) if filename else None) or "file"
        kind = "FILE"
        if mime_type:
            if mime_type.startswith("image"):
                kind = "IMG"
            elif mime_type.startswith("video"):
                kind = "VID"
            elif mime_type.startswith("audio"):
                kind = "AUD"
        parts.append(f"[{kind}#{num} {name}]")
    return " ".join(parts)

#############################################################################
# --- formatting / chunking (fixes long-message dropouts)
#############################################################################

def fmt_sender(sender):
    if not sender:
        return "MSG"
    if sender.startswith("+"):
        return sender[-4:]
    if "@" in sender:
        return sender.split("@")[0][:10]
    return sender[:10]


def fmt_ts(apple_ns):
    unix = apple_ns / 1_000_000_000 + 978307200
    return datetime.fromtimestamp(unix).strftime("%H:%M:%S")


def build_payload_lines(contact_idx, name, body):
    """Always returns at least one non-blank line. Splits long bodies into
    multiple numbered lines instead of truncating/dropping them."""
    if not body:
        body = "[No content]"
    prefix = f"[{contact_idx}] {name}: "
    avail = max(10, MAX_MSG_LEN - len(prefix))
    if len(body) <= avail:
        return [f"{prefix}{body}"]
    reserve_for_tag = 8  # room for "(12/12) "
    chunk_size = max(10, avail - reserve_for_tag)
    raw_chunks = [body[i:i + chunk_size] for i in range(0, len(body), chunk_size)]
    total = len(raw_chunks)
    return [f"{prefix}({i + 1}/{total}) {c}" for i, c in enumerate(raw_chunks)]

#############################################################################
# --- SSH relay (Mac -> Pager: notifications)
#############################################################################

def relay(message):
    safe = message.replace("'", "'\\''")
    try:
        r = subprocess.run(
            [
                "ssh", "-i", PAGER_SSH_KEY,
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=4",
                f"{PAGER_USER}@{PAGER_HOST}",
                f"printf '%s' '{safe}' > /tmp/pager_msg && touch /tmp/msg_new",
            ],
            timeout=7,
            capture_output=True,
        )
        return r.returncode == 0
    except subprocess.TimeoutExpired:
        print("    [!] SSH timeout")
        return False
    except Exception as e:
        print(f"    [!] SSH: {e}")
        return False


def check_outbox():
    """Poll the Pager for a reply the user typed on the onboard keyboard.
    Expects the Pager side to write 'INDEX|message text' to
    /tmp/pager_outbox and touch /tmp/outbox_new, then clears both files.
    This is the file contract your pager-side keyboard payload needs to
    implement - the actual button/keyboard read is firmware-specific and
    isn't included here."""
    try:
        r = subprocess.run(
            [
                "ssh", "-i", PAGER_SSH_KEY,
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=4",
                f"{PAGER_USER}@{PAGER_HOST}",
                "if [ -f /tmp/outbox_new ]; then cat /tmp/pager_outbox; "
                "rm -f /tmp/pager_outbox /tmp/outbox_new; fi",
            ],
            timeout=7,
            capture_output=True,
            text=True,
        )
        out = r.stdout.strip()
        return out or None
    except Exception as e:
        print(f"    [!] outbox check: {e}")
        return None

#############################################################################
# --- outgoing iMessage (Pager -> Mac -> sender), via Messages.app
#############################################################################

def send_imessage(recipient, text):
    text_escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    recipient_escaped = recipient.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
    tell application "Messages"
        set targetService to 1st service whose service type = iMessage
        set targetBuddy to buddy "{recipient_escaped}" of targetService
        send "{text_escaped}" to targetBuddy
    end tell
    '''
    try:
        r = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=10
        )
        return r.returncode == 0, r.stderr.strip()
    except Exception as e:
        return False, str(e)

#############################################################################
# --- contact index (stable numbering so replies know who to send to)
#############################################################################

def load_contacts():
    try:
        if os.path.exists(CONTACTS_FILE):
            with open(CONTACTS_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def save_contacts(contacts):
    try:
        with open(CONTACTS_FILE, "w") as f:
            json.dump(contacts, f)
    except Exception:
        pass


def get_or_assign_index(handle, contacts):
    if not handle:
        handle = "unknown"
    if handle in contacts:
        return contacts[handle]
    next_idx = (max(contacts.values()) + 1) if contacts else 1
    contacts[handle] = next_idx
    save_contacts(contacts)
    return next_idx


def resolve_handle(idx, contacts):
    for handle, i in contacts.items():
        if i == idx:
            return handle
    return None

#############################################################################
# --- state
#############################################################################

def load_state():
    default = {"last_date": 0, "attach_counter": 0}
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE) as f:
                data = json.load(f)
                default.update(data)
    except Exception:
        pass
    return default


def save_state(state):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception:
        pass

#############################################################################
# --- message body assembly
#############################################################################

def build_full_body(conn, rowid, text, attributed_body, counter_state):
    text_val = text if text and text.strip() else extract_text_from_attributed_body(attributed_body)
    text_val = humanize_text(text_val) if text_val else None
    attach_desc = describe_attachments(conn, rowid, counter_state)
    if text_val and attach_desc:
        return f"{text_val} {attach_desc}"
    if attach_desc:
        return attach_desc
    if text_val:
        return text_val
    return "[No content]"

#############################################################################
# --- MODES
#############################################################################

def run_test():
    print("[*] TEST - last 10 messages (all directions)\n")
    conn = get_db_connection()
    try:
        rows = fetch_last_n_messages(conn, 10)
        counter_state = {"n": 0}
        contacts = load_contacts()
        for rowid, date, text, attributed_body, is_from_me, sender in reversed(rows):
            body = build_full_body(conn, rowid, text, attributed_body, counter_state)
            direction = "OUT" if is_from_me else " IN"
            ts = fmt_ts(date) if date else "??:??:??"
            name = fmt_sender(sender)
            print(f"  [{ts}] [{direction}] {name}: {body}")
    finally:
        conn.close()
    print("\n[OK] If incoming messages show above, relay is ready")
    print("    Run: python3 iPager.py")


def run_reset():
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
    print("[OK] State cleared")


def run_send(idx_str, message):
    contacts = load_contacts()
    try:
        idx = int(idx_str)
    except ValueError:
        print(f"[!] Not a valid contact number: {idx_str}")
        return
    handle = resolve_handle(idx, contacts)
    if not handle:
        print(f"[!] No contact assigned to #{idx} yet (they need to message you first)")
        return
    ok, err = send_imessage(handle, message)
    print(f"[{'OK' if ok else '!'}] send to #{idx} ({handle}): {'sent' if ok else err}")


LOCK_FILE = os.path.expanduser("~/.ipager.lock")


def acquire_lock():
    """Refuse to start a second relay loop - running two at once is what
    causes tripled messages/alerts and sent-three-times replies, since each
    instance independently detects and relays the same events."""
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE) as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)  # raises if that PID isn't actually running
            print(f"[!] iPager already running (PID {old_pid}).")
            print(f"    Kill it first: kill {old_pid}")
            sys.exit(1)
        except (ValueError, ProcessLookupError, OSError):
            pass  # stale lock file from a crash - safe to take over
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))


def release_lock():
    try:
        if os.path.exists(LOCK_FILE):
            with open(LOCK_FILE) as f:
                pid = int(f.read().strip())
            if pid == os.getpid():
                os.remove(LOCK_FILE)
    except Exception:
        pass


def run_relay():
    acquire_lock()
    try:
        _run_relay()
    finally:
        release_lock()


def _run_relay():
    print("+-----------------------------------+")
    print("|             iPager                |")
    print("|                                   |")
    print("|  iMessage <-> Pager Relay v1.0    |")
    print("+-----------------------------------+")
    print(f"  Pager : {PAGER_USER}@{PAGER_HOST}\n")

    state = load_state()
    contacts = load_contacts()

    if state["last_date"] == 0:
        conn = get_db_connection()
        try:
            cur = conn.execute("SELECT MAX(date) FROM message")
            row = cur.fetchone()
            state["last_date"] = row[0] if row and row[0] else 0
        finally:
            conn.close()
        save_state(state)
        print(f"[*] Seeded: {fmt_ts(state['last_date']) if state['last_date'] else 'no messages found'}")
    else:
        print(f"[*] Resuming from {fmt_ts(state['last_date'])}")

    print("[*] Watching...\n")

    while True:
        try:
            conn = get_db_connection()
            try:
                rows = fetch_new_messages(conn, state["last_date"])
                counter_state = {"n": state["attach_counter"]}

                for rowid, date, text, attributed_body, is_from_me, sender in rows:
                    if date and date > state["last_date"]:
                        state["last_date"] = date

                    if is_from_me:
                        # Don't page yourself for messages you sent from your own devices.
                        continue

                    body = build_full_body(conn, rowid, text, attributed_body, counter_state)
                    idx = get_or_assign_index(sender, contacts)
                    name = fmt_sender(sender)

                    for line in build_payload_lines(idx, name, body):
                        print(f"[{fmt_ts(date)}] {line}")
                        ok = relay(line)
                        print(f"       -> {'relayed OK' if ok else 'FAILED'}")
                        time.sleep(0.35)

                state["attach_counter"] = counter_state["n"]
                save_state(state)
            finally:
                conn.close()

            # Check for a reply typed on the Pager's onboard keyboard.
            reply = check_outbox()
            if reply and "|" in reply:
                target_str, msg_text = reply.split("|", 1)
                target_str, msg_text = target_str.strip(), msg_text.strip()

                if target_str.startswith("NEW:"):
                    # Manually-entered recipient typed on the pager - not an
                    # existing numbered contact.
                    handle = target_str[4:].strip()
                    if handle and msg_text:
                        ok, err = send_imessage(handle, msg_text)
                        # Register them going forward so they get a normal
                        # contact number for next time.
                        idx = get_or_assign_index(handle, contacts)
                        print(f"[*] Reply to new recipient {handle} (#{idx}): {'sent' if ok else 'FAILED - ' + err}")
                        relay(f"[{idx}] {'sent OK' if ok else 'send FAILED'}")
                    else:
                        print(f"[!] Bad manual reply payload from pager: {reply!r}")
                        relay("[!] bad manual recipient")
                else:
                    handle = resolve_handle(int(target_str), contacts) if target_str.isdigit() else None
                    if handle and msg_text:
                        ok, err = send_imessage(handle, msg_text)
                        print(f"[*] Reply to #{target_str} ({handle}): {'sent' if ok else 'FAILED - ' + err}")
                        relay(f"[{target_str}] {'sent OK' if ok else 'send FAILED'}")
                    else:
                        print(f"[!] Bad reply payload from pager: {reply!r}")
                        relay(f"[!] unknown contact #{target_str}")

        except KeyboardInterrupt:
            print("\n[*] Stopped.")
            break
        except Exception as e:
            print(f"[!] {e}")

        time.sleep(POLL_INTERVAL)

#############################################################################
# --- ENTRYPOINT
#############################################################################

if __name__ == "__main__":
    if "--test" in sys.argv:
        run_test()
    elif "--reset" in sys.argv:
        run_reset()
    elif "--send" in sys.argv:
        i = sys.argv.index("--send")
        if len(sys.argv) < i + 3:
            print("Usage: python3 iPager.py --send <contact#> <message text>")
        else:
            run_send(sys.argv[i + 1], " ".join(sys.argv[i + 2:]))
    else:
        run_relay()
