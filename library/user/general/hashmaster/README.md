# 🎯 HashMaster

Your WiFi Pineapple Pager is great at collecting handshakes - but which ones are actually useful? HashMaster tracks everything via Pager alerts and by analyzing your .22000 hashcat files, giving you smart notifications and clear insights into what you've captured.

## 🤔 Why HashMaster?

**The Problem:**
- The Pager collects tons of handshakes, but you don't know which ones matter to you
- You get the same alerts over and over for networks you've already captured
- You can't tell if a new capture is better quality than what you already have
- Your collection becomes a confusing pile of files with no visibility

**The Solution:**
- **Get Notified When It Matters** - Only alerts for new networks, quality improvements, or new clients
- **No More Duplicate Alerts** - Remembers what you've captured and won't bug you twice
- **Understand Your Collection** - Clear breakdown of what's crackable, what's best quality, and what needs work
- **Never Miss Important Captures** - Real-time alerts when you get that perfect M2+M3 handshake

## 📦 Installation

1. Copy `hashmaster/` to `/root/payloads/user/general/`
2. Run the payload - it will offer to install the alert handler automatically
3. Configure alert preferences in `hashmaster.sh`

## ⚙️ Configuration

Edit `hashmaster.sh` to customize what you get alerted about:

```bash
DEBUG=0                      # Enable debug logging (0=off, 1=on)
ALERT_NEW_NETWORK=1          # Alert when you capture a brand new network
ALERT_QUALITY_IMPROVED=1     # Alert when you get a better version of something you have
ALERT_NEW_CLIENT=1           # Alert when a new device connects to a tracked network
ALERT_BEST_QUALITY_ONLY=0    # Only alert for the best captures (M2+M3), ignore the rest
ALERT_NON_CRACKABLE=1        # Alert even if the capture isn't crackable
MIN_QUALITY_RANK=2           # Minimum quality to care about (2=PMKID+, 4=M1M2+, 5=M2M3 only)

TRACK_CLIENTS=1              # Track which clients connect to each network (0=disable)
FILTER_RANDOMIZED_MACS=1     # Filter out randomized MAC addresses (prevents spam from phones)
```

**About Client Tracking:**
Modern smartphones (iOS/Android) randomize their MAC addresses to protect privacy - this means you'd get spammed with alerts for the "same" device appearing with different addresses. HashMaster still tracks these handshakes (they're valid captures!), but silences client-specific alerts for randomized MACs. You'll still get alerts for network quality improvements, just not "NEW CLIENT" spam.

**Why track clients at all?** In multi-PSK VLAN setups (same network name + AP, different passwords), each client connection may represent a different password variant worth capturing.

## 📊 What Gets Tracked

HashMaster knows the difference between good and bad captures:

- **Best Quality** - EAPOL M2+M3 captures (easiest to crack, highest success rate)
- **Good** - EAPOL M1+M2 or M3+M4 (still crackable, just takes longer)
- **Okay** - PMKID (works but slower to crack)
- **Needs Work** - Incomplete or invalid captures (not crackable yet)

The system remembers everything it's seen, so you'll only get alerts for genuinely new or improved captures. Even when you delete files from disk, HashMaster keeps track of what you've had.

## 👀 What You'll See

**When you run the analyzer, you get:**
- Summary of your entire collection (how many networks, which are crackable)
- Breakdown by network showing quality status: [***] Excellent, [OK] Ready, [X] Not Crackable
- Clear indicators for new networks and quality improvements
- Historical tracking (total captures over time, first seen dates)

**Alerts you'll receive (configurable):**
- "NEW CRACKABLE NETWORK" - You captured a network for the first time
- "QUALITY IMPROVED" - You got a better capture of a network you already have
- "NEW CLIENT" - A new device connected to a network you're tracking
- "NOW CRACKABLE" - A network that was incomplete is now crackable


## 💾 Database

HashMaster keeps a database at `/root/hashmaster.db` that tracks:
- Every network you've captured (network name + access point address)
- Best quality capture for each network
- When you first saw it and when you last captured it
- Which clients have connected to each network

Even if you delete handshake files from disk, the database remembers what you've seen - so you won't get duplicate alerts if you capture the same network again later.

## 🔧 Troubleshooting

**"I'm not getting alerts"**
- Check that the alert payload was installed (look for "Alert payload is installed" message)
- Verify alert settings in `hashmaster.sh` (make sure things aren't set to 0)
- Enable debug logging to see what's happening

**"How do I reset everything?"**
```bash
rm /root/hashmaster.db  # Deletes tracking history, starts fresh
```

**"I want to see what's happening under the hood"**
```bash
# Edit hashmaster.sh and set DEBUG=1
tail -f /tmp/hashmaster_debug.log  # Watch in real-time
```

## ⚡ How It Works

HashMaster tracks via **two methods**:
1. **Alert Payload** - Runs automatically on every capture, updates database in real-time. (optional install during main payload run)
2. **HashMaser Payload** - Scans .22000 hashcat files on disk, updates database, and provides detailed reports. 

Both methods update the same database. When a handshake is processed:
- New network never seen before? → Alert
- Better quality than what we have? → Alert  
- New client on a known network? → Alert
- Duplicate of existing capture? → Stay silent

Everything is tracked by the unique combination of network name (SSID) and access point address (BSSID).
