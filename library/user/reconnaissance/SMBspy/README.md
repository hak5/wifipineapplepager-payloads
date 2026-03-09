SMB Spy 🕵️‍♂️
👤 Author
Hackazillarex
Version: 1.0


SMB Spy, a companion to the Responder Payload, is a lightweight Bash-based SMB discovery utility designed for internal network enumeration during security assessments. It automatically identifies hosts with SMB (port 445) exposed on a local network and logs actionable next-step commands for follow‑up enumeration.

Built for speed, clarity, and clean loot collection.

You’ll be prompted to select a network interface:

    1 — wlan0cli

    2 — eth1 (USB Ethernet)

The script will:

    Bring the interface up (if needed)

    Request a DHCP lease (for eth1)

    Detect the local IPv4 CIDR

    Scan the network for SMB services

    Log discovered hosts and suggestions

📂 Output / Loot

All output is saved under:

/root/loot/smb_discovery/

Files include:

    smb_hosts_<timestamp>.txt — Parsed results and notes

    nmap_raw_<timestamp>.txt — Full raw nmap output

Example findings:

SMB OPEN: 192.168.1.42
  MAC: 00:11:22:33:44:55
  Vendor: Dell Inc.

🧭 Next-Step Suggestions

For each discovered SMB host, SMB Spy automatically suggests common enumeration commands, such as:

smbclient -L //<ip> -U user
smbmap -H <ip> -u user -p pass
crackmapexec smb <ip>

These are not executed automatically — they’re provided as guidance only.
⚠️ Notes & Limitations

    SMB Spy performs discovery only — no exploitation

    Port scanning is limited to TCP 445

    MAC/vendor data depends on network visibility and ARP resolution

    Intended for authorized testing environments only

📜 Disclaimer

This tool is intended for educational purposes and authorized security testing only.
You are responsible for ensuring you have permission to scan and assess any network or system.

