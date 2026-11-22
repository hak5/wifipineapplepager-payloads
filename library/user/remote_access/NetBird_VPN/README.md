# NetBird VPN – Hak5 WiFi Pineapple Pager Payload

**Author:** SECT0101
**Version:** 1.0
**Category:** Remote-Access
**Platform:** Hak5 WiFi Pineapple Pager (OpenWrt 24.10 package feed)

---

## 📡 Overview

**NetBird VPN** installs and controls the [NetBird](https://netbird.io) WireGuard mesh VPN client on the Pager. It enrolls the Pager as a **client peer** in your NetBird network, either NetBird cloud or self-hosted.

The main use is pairing with [PagerTAK](../../general/PagerTAK). If your TAK Server is a NetBird peer, the Pager reaches it privately from any internet connection (hotspot, tether, hotel Wi-Fi) with no ports opened on the server. Point PagerTAK's server at the TAK Server's NetBird IP or NetBird DNS name.

## ✨ Features

- **Install** the official OpenWrt `netbird` package: to internal flash when there is room, otherwise to the SD card
- **Enroll** with a setup key, an optional self-hosted management URL, and a peer name
- **Connect / Disconnect**, with a **Status** screen (management, signal, NetBird IP, peers)
- **Test TAK server**: checks the TAK Server port is reachable and whether traffic routes over NetBird (`wt0`). It defaults to PagerTAK's saved server
- **Start on boot** toggle
- **Uninstall**, which also removes the peer identity

## 🔐 Security

- The **setup key is used once and never saved** by this payload. After enrollment, NetBird keeps its own peer identity in `/etc/netbird/config.json`.
- Use a **one-off or short-lived setup key**, ideally with a dedicated group, and limit what that group can reach with NetBird access policies (e.g. only the TAK Server on 8089).
- Only the management URL and peer name are stored, with `PAYLOAD_SET_CONFIG`.

## 🧰 Requirements

- Internet on the Pager (client Wi-Fi or tether) to install and connect
- About **40 MB** free on internal flash or the SD card. The NetBird binary is large.
- A NetBird account (cloud) or a self-hosted NetBird management server, plus a **setup key** from its dashboard

## ⚙️ Usage

1. Copy the folder to the Pager:
   ```
   scp -r NetBird_VPN root@172.16.52.1:/root/payloads/user/remote_access/
   ```
2. Run **Payloads > User > Remote Access > NetBird VPN**. The first run offers to install NetBird.
3. Choose **Enroll (setup key)**. Leave the management URL blank for NetBird cloud, or enter your self-hosted URL (e.g. `https://netbird.example.com:443`).
4. Check **Status** for `Management: Connected` and a NetBird IP.
5. Run **Test TAK server**.

NetBird keeps running after you leave the payload. Use **Disconnect** to stop it.

## 📝 Notes

- With the **SD-card install**, the daemon is started by this payload and does not start on boot.
- A Pager on NetBird is a plain client peer. It does not route other devices, so no firewall changes are made.
- If NetBird's own DNS is not resolving names, use the TAK Server's NetBird **IP** in PagerTAK.
- Hardware note: NetBird is a Go program and uses noticeable RAM on the Pager. Watch for slowdowns when it runs alongside heavy recon payloads.

## ⚠️ Disclaimer

Only join networks you are authorized to use.
