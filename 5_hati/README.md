# HATI - Moon Hunter

**Clientless WPA PMKID Attack - The wolf that hunts in darkness**

```
 _  _   _ _____ ___
| || | /_\_   _|_ _|
| __ |/ _ \| |  | |
|_||_/_/ \_\_| |___|

    HATI v1.4.4 - Moon Hunter
```

*Named after Hati Hróðvitnisson - the wolf that chases the moon in Norse mythology. Brother of Sköll who chases the sun.*

## What It Does

Captures PMKIDs from WPA/WPA2 access points without needing any clients to be connected. This is the fastest way to obtain crackable WiFi hashes.

## How PMKID Works

1. The PMKID is embedded in the AP's first EAPOL message during association
2. hcxdumptool actively requests this from the AP
3. No client handshake capture needed - works on empty networks
4. Output is directly crackable with hashcat (-m 22000)

## Requirements

- `hcxdumptool` - Packet capture tool
- `hcxpcapngtool` - PCAP to hashcat converter

The payload will offer to install these if not present.

## Usage

1. Run the payload
2. Choose mode:
   - **Scan ALL** - Hunt PMKIDs from all nearby APs
   - **Targeted** - Select specific AP from recon list
3. Set duration (10-300 seconds)
4. Watch the hunt - audio/haptic feedback on captures
5. Press A to stop early if needed

## Output

Files saved to `/root/loot/hati/`:
- `hati_TIMESTAMP.pcapng` - Raw capture
- `hati_TIMESTAMP.22000` - Hashcat-ready hashes
- `essid_TIMESTAMP.txt` - Network names

## Cracking

```bash
hashcat -m 22000 hati_*.22000 wordlist.txt
```

## Success Rate

Not all APs support PMKID. Modern APs with updated firmware may not respond. Try:
- Longer capture duration
- Multiple targets
- Move closer to AP

## Author

HaleHound

## Version

**1.4.4** (2026-01-15)
- Fixed UI text: B button now says "Exit" (matches actual behavior)
- Fixed scan_targets hanging issue
- Fixed CONFIRMATION_DIALOG handling
- Fixed B button exit behavior
- BPF filtering for targeted mode (hcxdumptool 6.3.4 compatible)
- Field tested and verified working
