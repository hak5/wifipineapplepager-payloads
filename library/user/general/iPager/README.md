<div align="center">

# iPager

**Real-time, two-way iMessage relay for the WiFi Pineapple Pager**
*A pager should get messages and let you respond. So I built it.*

</div>

---

## What Is This

iPager turns a Hak5 WiFi Pineapple Pager into a live iMessage terminal. It reads Apple's local message database on macOS and relays incoming text to the Pager over SSH in real time and lets you compose and send replies directly from the Pager's keypad, routed back through Messages.app on the Mac.

No exploit. No jailbreak. No elevated privileges beyond standard Full Disk Access. No third-party services. No Apple server traffic. Just a pager that sends and receives messages.

Purchased at DEF CON 34 and built into a working two-way payload within a week.

---

## The Finding

Apple markets iMessage as end-to-end encrypted, and it is, in transit. What isn't advertised: the full local iMessage history is stored in a plaintext SQLite database at a static, predictable path on every Mac in the Continuity ecosystem:

```
~/Library/Messages/chat.db
```

No encryption at rest, no access notifications, no anomaly detection; protected only by a Full Disk Access permission that dozens of legitimate apps already hold on a typical endpoint. iPager is the proof of concept: the first two-way iMessage relay payload in the Hak5 Pager library.

---

## Architecture

```
MacBook (sensor + sender)
  ~/Library/Messages/chat.db
        │  read (poll)
        ▼
  iPager.py
    ├── polls chat.db every 3s
    ├── decodes text / attributedBody (NSKeyedArchiver)
    ├── relays incoming text over SSH → /tmp/pager_msg, /tmp/msg_new
    └── listens for outgoing compose requests from the Pager
        │
        ▼  SSH (bidirectional)
WiFi Pineapple Pager
  payload.sh
    ├── watches /tmp/msg_new → CLEAR → SHOW → LOG
    └── double-tap UP → opens compose mode
          ├── recipient from auto-built contact list (LIST_PICKER)
          ├── or manual phone/email entry
          └── message sent back to Mac → osascript → Messages.app
```

---

## Features

**Receiving**
- Live relay: sent and received message text, updated every 3s
- Full macOS compatibility: Monterey through Sequoia, every `chat.db` schema
- Dual decoder: plaintext `text` column and NSKeyedArchiver `attributedBody` (Ventura+)
- Tapback filtering: reaction noise stripped from output
- State persistence: survives restarts, no replay flooding on relaunch

**Sending (new)**
- Compose directly from the Pager: double-tap **UP** opens compose mode
- Recipient list auto-built from incoming message senders, selectable via on-device `LIST_PICKER`
- Manual phone number / email entry for new recipients not yet in the list
- Replies are relayed back to the Mac over SSH and sent through `osascript` → Messages.app: genuinely sent as you, from your own Mac, not spoofed
- Single-instance locking on both Mac and Pager sides prevents duplicate relays or double-sends

**General**
- Zero dependencies: stdlib only, Python 3.9+

---

## Requirements

**Mac side**
- macOS Monterey or later, Python 3.9+
- Terminal granted Full Disk Access (`System Settings → Privacy & Security → Full Disk Access`)
- Messages.app signed in and active (required for sending replies)
- SSH key auth configured to the Pager (one-time)

**Pager side**
- WiFi Pineapple Pager with `payload.sh` installed
- SSH server active (default)

---

## Setup

```bash
# 1. Grant Terminal Full Disk Access
#    System Settings → Privacy & Security → Full Disk Access → add Terminal

# 2. One-time SSH key setup
bash setup_ssh.sh

# 3. Verify connection (should print OK, no password prompt)
ssh -i ~/.ssh/pager_rsa root@172.16.52.1 'echo OK'

# 4. Install payload on Pager
scp -i ~/.ssh/pager_rsa payload.sh \
    root@172.16.52.1:/root/payloads/user/notifications/iPager/payload.sh

# 5. On the Pager dashboard: Payloads → user → notifications → iPager → Run

# 6. Start the relay (handles both receive and send)
python3 iPager.py
```

**Configuration**: top of `iPager.py`:

```python
PAGER_HOST    = "172.16.52.1"
PAGER_USER    = "root"
PAGER_SSH_KEY = "~/.ssh/pager_rsa"
POLL_INTERVAL = 3     # seconds
MAX_MSG_LEN   = 72    # truncation length
```

---

## Usage

```bash
python3 iPager.py           # run relay (receive + send)
python3 iPager.py --test    # test DB access, print recent messages, no SSH
python3 iPager.py --reset   # clear saved state
```

**On the Pager:**
- Incoming messages display automatically as they arrive
- Double-tap **UP** to open compose mode
- Pick a recipient from the contact list, or enter a number/email manually
- Type your message and confirm to send; it goes out through your Mac's Messages.app

---

## Files

| File | Side | Purpose |
|---|---|---|
| `iPager.py` | Mac | Core relay daemon: receive + send |
| `payload.sh` | Pager | Display, compose UI, and vibrate payload |
| `setup_ssh.sh` | Mac | One-time SSH key setup |

---

## How the Decoder Works

`chat.db` stores message content two ways depending on macOS version:

| Era | Column | Format |
|---|---|---|
| Pre-Ventura | `text` | Plain UTF-8 string |
| Ventura+ | `attributedBody` | NSKeyedArchiver binary plist |

iPager handles both with a three-strategy decoder: NSKeyedArchiver plist parsing (`plistlib`, `NS.string` key), a latin-1 typedstream scan for legacy format, and a UTF-8 fallback. No configuration required.

---

## Security Research Context

iPager demonstrates a trust-model gap in Apple's Continuity architecture: iMessage encryption protects content in transit, but once delivered, content sits in plaintext on the Mac endpoint with no at-rest encryption or access monitoring. The database path and schema have been stable since iMessage launched on macOS, and this affects any Mac with an authenticated Apple ID. The two-way send path reuses the same trust Messages.app already has via `osascript`; it doesn't bypass or escalate anything.

## Defensive Guidance

**Individuals**
- Enable FileVault (encrypts the full disk, including `chat.db`)
- Audit Full Disk Access grants and remove anything that doesn't need them

**Enterprise**
- File system audit rules on `~/Library/Messages/`
- Monitor for unexpected processes accessing `chat.db`
- Enforce FileVault via MDM; review FDA grants on managed endpoints

---

## Legal

Intended for authorized security research, red team operations, and use on devices/accounts you own or have explicit permission to monitor. Unauthorized interception of communications is illegal under ECPA and equivalent statutes internationally. Use responsibly.

---

<div align="center">

**Author:** $p!ll_bl00d - independent security researcher & creative technologist/artist
LinkedIn: [raycervantes](https://linkedin.com/in/raycervantes) · GitHub: [bleednoevil](https://github.com/bleednoevil)

*A pager should get messages and let you respond. So I built it.*

</div>
