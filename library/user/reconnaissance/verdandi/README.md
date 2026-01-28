# VERDANDI - Probe Fingerprint Engine

**Version 2.0.1** | *Named after Verdandi - the Norn who sees the present, the TRUE identity*

```
                              .......::.:....
                        ..::------------------::..
                      .:-=======================-::.
                    .:---====================-----::.
                  .:::::::-----=-----=--=---:::::::...
                ....:::::----====-=--====--------:::...
                ...::------::---=========--::::::--::.
                ....:::........:.:::::::..........:::.
                 .....      ........::..      ...   ..
                 . .            ..::....       ...
                              ...::.   ...
                   ..         .::.      ...          .
                  .:..     ......        .....      ....
               ... .:...........      .    .   .....::.
               ........  ..   ...       .....  ..........
                             .....      .....   ...
                              ...... .......
                           ...::.........:::.
                          ....... ....:......
                          ....     .  ....

 ██▒   █▓  ▓█████   ██▀███    ▓█████▄     ▄▄▄      ███▄    █   ▓█████▄   ██▓
▓██░   █▒  ▓█   ▀  ▓██ ▒ ██▒  ▒██▀ ██▌   ▒████▄    ██ ▀█   █   ▒██▀ ██▌ ▓██▒
 ▓██  █▒░  ▒███    ▓██ ░▄█ ▒  ░██   █▌   ▒██  ▀█▄ ▓██  ▀█ ██▒  ░██   █▌ ▒██▒
  ▒██ █░░  ▒▓█  ▄  ▒██▀▀█▄    ░▓█▄   ▌   ░██▄▄▄▄██▓██▒  ▐▌██▒  ░▓█▄   ▌ ░██░
   ▒▀█░    ░▒████▒ ░██▓ ▒██▒  ░▒████▓     ▓█   ▓██▒▒██░   ▓██░  ░▒████▓ ░██░
   ░ ▐░    ░░ ▒░ ░ ░ ▒▓ ░▒▓░   ▒▒▓  ▒     ▒▒   ▓▒█░░ ▒░   ▒ ▒    ▒▒▓  ▒  ░▓
   ░ ░░     ░ ░  ░   ░▒ ░ ▒░   ░ ▒  ▒      ▒   ▒▒ ░░ ░░   ░ ▒░   ░ ▒  ▒   ▒ ░
     ░░       ░       ░░   ░    ░ ░  ░      ░   ▒     ░   ░ ░    ░ ░  ░   ▒ ░
      ░       ░  ░     ░          ░           ░ ░         ░        ░      ░

                       VERDANDI
               SEES THE TRUE IDENTITY
```

---

## Overview

VERDANDI defeats MAC address randomization by extracting and fingerprinting the **Information Elements (IEs)** embedded in WiFi probe requests. While devices can change their MAC address, they CANNOT change their radio capabilities without breaking WiFi functionality. VERDANDI exploits this to track the TRUE device identity.

**v2.0 Enhancement:** Now includes **RSSI tracking** to distinguish between different people carrying the same phone model (the "cohort problem").

---

## The Problem: MAC Randomization

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    MAC RANDOMIZATION                            │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │    Target's Phone                                               │
    │    ┌─────────────┐                                              │
    │    │             │                                              │
    │    │      $      │──────►  WiFi MAC changes constantly          │
    │    │             │                                              │
    │    └─────────────┘                                              │
    │                                                                 │
    │    Time 0:00    ──►   AA:BB:CC:11:22:33  (random)               │
    │    Time 0:05    ──►   DD:EE:FF:44:55:66  (random)               │
    │    Time 0:10    ──►   12:34:56:78:9A:BC  (random)               │
    │    Time 0:15    ──►   FE:DC:BA:98:76:54  (random)               │
    │                                                                 │
    │    Traditional MAC tracking: DEFEATED                           │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

**Current Pager payloads capture MAC addresses** - but randomized MACs render this useless. ProbeHound, live_probe, TRIG_MAC all fail against MAC randomization because they track the MASK, not the DEVICE.

---

## The Solution: Multi-Layer Fingerprinting

```
    ┌─────────────────────────────────────────────────────────────────┐
    │            VERDANDI v2.0 FINGERPRINT LAYERS                     │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │    Every probe request contains Information Elements (IEs):     │
    │                                                                 │
    │    ┌─────────────────────────────────────────────────────────┐ │
    │    │  802.11 Probe Request Frame                             │ │
    │    ├─────────────────────────────────────────────────────────┤ │
    │    │  Frame Control    │  2 bytes                            │ │
    │    │  Duration         │  2 bytes                            │ │
    │    │  DA (Broadcast)   │  6 bytes                            │ │
    │    │  SA (Source MAC)  │  6 bytes  ◄── RANDOMIZED            │ │
    │    │  BSSID            │  6 bytes                            │ │
    │    │  Sequence Control │  2 bytes                            │ │
    │    ├─────────────────────────────────────────────────────────┤ │
    │    │  TAGGED PARAMETERS (Information Elements):              │ │
    │    │                                                         │ │
    │    │  ┌─────────────────────────────────────────────────┐   │ │
    │    │  │ LAYER 1: Radio Capabilities                     │   │ │
    │    │  ├─────────────────────────────────────────────────┤   │ │
    │    │  │ Tag 1:   Supported Rates (1-54 Mbps)            │   │ │
    │    │  │ Tag 45:  HT Capabilities (802.11n)              │   │ │
    │    │  │ Tag 191: VHT Capabilities (802.11ac)            │   │ │
    │    │  │ Tag 255: HE Capabilities (802.11ax/WiFi 6)      │   │ │
    │    │  └─────────────────────────────────────────────────┘   │ │
    │    │                                                         │ │
    │    │  ┌─────────────────────────────────────────────────┐   │ │
    │    │  │ LAYER 2: OS/Driver Signature                    │   │ │
    │    │  ├─────────────────────────────────────────────────┤   │ │
    │    │  │ Tag 127: Extended Capabilities (OS features)    │   │ │
    │    │  │ Tag 221: Vendor Specific (Apple, Microsoft)     │   │ │
    │    │  │ IE ORDER: Tag sequence (driver-specific)        │   │ │
    │    │  └─────────────────────────────────────────────────┘   │ │
    │    │                                                         │ │
    │    │  ┌─────────────────────────────────────────────────┐   │ │
    │    │  │ LAYER 3: Distance Differentiation (NEW in v2)   │   │ │
    │    │  ├─────────────────────────────────────────────────┤   │ │
    │    │  │ RSSI: Signal strength (-30dBm to -90dBm)        │   │ │
    │    │  │ Distinguishes same-model devices by distance    │   │ │
    │    │  └─────────────────────────────────────────────────┘   │ │
    │    │                                                         │ │
    │    └─────────────────────────────────────────────────────────┘ │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## The Cohort Problem (Solved in v2.0)

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                  THE COHORT PROBLEM                             │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   Same phone model + Same OS = IDENTICAL fingerprint            │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │                                                          │  │
    │   │   Person A: iPhone 15 Pro                                │  │
    │   │   Fingerprint: a1b2c3d4e5f67890                          │  │
    │   │                                                          │  │
    │   │   Person B: iPhone 15 Pro (same model!)                  │  │
    │   │   Fingerprint: a1b2c3d4e5f67890  ◄── SAME!               │  │
    │   │                                                          │  │
    │   │   v1.0 Problem: Cannot distinguish Person A from B       │  │
    │   │                                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ═══════════════════════════════════════════════════════════  │
    │                        v2.0 SOLUTION                            │
    │   ═══════════════════════════════════════════════════════════  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │                                                          │  │
    │   │   Person A: iPhone 15 Pro                                │  │
    │   │   Fingerprint: a1b2c3d4e5f67890                          │  │
    │   │   RSSI Range: -35dBm to -38dBm  ◄── CLOSE (3 meters)     │  │
    │   │                                                          │  │
    │   │   Person B: iPhone 15 Pro                                │  │
    │   │   Fingerprint: a1b2c3d4e5f67890                          │  │
    │   │   RSSI Range: -65dBm to -70dBm  ◄── FAR (15 meters)      │  │
    │   │                                                          │  │
    │   │   v2.0 Solution: RSSI differentiates by DISTANCE         │  │
    │   │                                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   Same fingerprint + Different RSSI = Different people         │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Fingerprint Components (v2.0 Enhanced)

```
    ┌─────────────────────────────────────────────────────────────────┐
    │              VERDANDI v2.0 FINGERPRINT ENGINE                   │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  TAG ORDER (IE Sequence Hash)                 NEW!       │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  Different WiFi drivers send IEs in different orders:   │  │
    │   │                                                          │  │
    │   │  Apple iOS:      01 → 32 → 2d → bf → 7f → dd → ff       │  │
    │   │  Android/Qcom:   01 → 2d → 7f → bf → dd → 32 → ff       │  │
    │   │  Intel Windows:  01 → 2d → 32 → 7f → bf → dd            │  │
    │   │                                                          │  │
    │   │  Order hash: ORD:01-2d-bf-7f-dd-ff                       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  HT CAPABILITIES (Tag 45 / 0x2d)              802.11n   │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  26 bytes of device-specific radio configuration:       │  │
    │   │                                                          │  │
    │   │  ┌─────────────────────────────────────────────────┐    │  │
    │   │  │ Bytes 0-1:  HT Capability Info                  │    │  │
    │   │  │   - LDPC Coding                                 │    │  │
    │   │  │   - 20/40 MHz Channel Width                     │    │  │
    │   │  │   - SM Power Save                               │    │  │
    │   │  │   - Greenfield support                          │    │  │
    │   │  │   - Short GI for 20/40 MHz                      │    │  │
    │   │  ├─────────────────────────────────────────────────┤    │  │
    │   │  │ Byte 2:     A-MPDU Parameters                   │    │  │
    │   │  │   - Max A-MPDU Length Exponent                  │    │  │
    │   │  │   - Min MPDU Start Spacing                      │    │  │
    │   │  ├─────────────────────────────────────────────────┤    │  │
    │   │  │ Bytes 3-18: Supported MCS Set (16 bytes)        │    │  │
    │   │  │   - RX/TX MCS bitmask                           │    │  │
    │   │  │   - Highest data rate supported                 │    │  │
    │   │  └─────────────────────────────────────────────────┘    │  │
    │   │                                                          │  │
    │   │  Example: HT:ab12cd34ef56789000000000000000000000000000  │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  VHT CAPABILITIES (Tag 191 / 0xbf)            802.11ac  │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  12 bytes for 802.11ac (WiFi 5) devices:                │  │
    │   │                                                          │  │
    │   │  ┌─────────────────────────────────────────────────┐    │  │
    │   │  │ Bytes 0-3:  VHT Capability Info                 │    │  │
    │   │  │   - Max MPDU Length                             │    │  │
    │   │  │   - 80/160 MHz Support                          │    │  │
    │   │  │   - Short GI for 80/160 MHz                     │    │  │
    │   │  │   - SU/MU Beamformer/Beamformee                 │    │  │
    │   │  ├─────────────────────────────────────────────────┤    │  │
    │   │  │ Bytes 4-11: Supported VHT-MCS Set               │    │  │
    │   │  │   - RX/TX VHT-MCS Map                           │    │  │
    │   │  │   - Highest VHT Data Rate                       │    │  │
    │   │  └─────────────────────────────────────────────────┘    │  │
    │   │                                                          │  │
    │   │  Example: VHT:a1b2c3d4e5f60000e5f60020                   │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  HE CAPABILITIES (Tag 255/Ext 35)   802.11ax  NEW!      │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  WiFi 6 devices include HE (High Efficiency) caps:      │  │
    │   │                                                          │  │
    │   │  ┌─────────────────────────────────────────────────┐    │  │
    │   │  │ Extension ID 35 (0x23) indicates HE Capabilities │    │  │
    │   │  │   - BSS Color                                    │    │  │
    │   │  │   - OFDMA support                                │    │  │
    │   │  │   - 1024-QAM support                             │    │  │
    │   │  │   - TWT (Target Wake Time)                       │    │  │
    │   │  │   - MU-MIMO configuration                        │    │  │
    │   │  └─────────────────────────────────────────────────┘    │  │
    │   │                                                          │  │
    │   │  Example: HE:01a2b30400000008fc                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  EXTENDED CAPABILITIES (Tag 127 / 0x7f)       NEW!      │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  OS-level feature flags (varies by OS version):         │  │
    │   │                                                          │  │
    │   │  ┌─────────────────────────────────────────────────┐    │  │
    │   │  │ Variable length (8-11 bytes typically):          │    │  │
    │   │  │   - BSS Transition (802.11v)                     │    │  │
    │   │  │   - WNM Sleep Mode                               │    │  │
    │   │  │   - TIM Broadcast                                │    │  │
    │   │  │   - Interworking (Hotspot 2.0)                   │    │  │
    │   │  │   - QoS Map                                      │    │  │
    │   │  └─────────────────────────────────────────────────┘    │  │
    │   │                                                          │  │
    │   │  Different iOS/Android versions = Different ext caps    │  │
    │   │  Example: EXT:0500080200000040                           │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  VENDOR SPECIFIC (Tag 221 / 0xdd)             NEW!      │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  Manufacturer OUIs reveal device brand:                 │  │
    │   │                                                          │  │
    │   │  ┌─────────────────────────────────────────────────┐    │  │
    │   │  │ Common Vendor OUIs:                              │    │  │
    │   │  │   00:17:f2  - Apple                              │    │  │
    │   │  │   00:50:f2  - Microsoft (WPS)                    │    │  │
    │   │  │   00:10:18  - Broadcom                           │    │  │
    │   │  │   00:0c:e7  - MediaTek                           │    │  │
    │   │  │   8c:fd:f0  - Qualcomm                           │    │  │
    │   │  └─────────────────────────────────────────────────┘    │  │
    │   │                                                          │  │
    │   │  Example: VEN:0017f2,0050f2                              │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  SUPPORTED RATES (Tag 1 / 0x01)                         │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  Basic transmission rates the radio supports:           │  │
    │   │                                                          │  │
    │   │  Legacy: 1, 2, 5.5, 11 Mbps (802.11b)                   │  │
    │   │  OFDM:   6, 9, 12, 18, 24, 36, 48, 54 Mbps (802.11a/g)  │  │
    │   │                                                          │  │
    │   │  Example: SR:8c129824b048606c                            │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## How VERDANDI Works

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    VERDANDI v2.0 WORKFLOW                       │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   STEP 1: CHANNEL HOPPING + PROBE CAPTURE                       │
    │   ═══════════════════════════════════════                       │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  2.4 GHz: Channel 1 ──► 6 ──► 11 ──► (repeat)           │  │
    │   │  5 GHz:   Channel 36 ──► 40 ──► 44 ──► 48 ──►           │  │
    │   │                   149 ──► 153 ──► 157 ──► 161           │  │
    │   │                                                          │  │
    │   │  Hops every 300ms to maximize probe capture              │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  tcpdump -i wlan1mon -e -xx -s 1024                      │  │
    │   │  type mgt subtype probe-req                              │  │
    │   │                                                          │  │
    │   │  Captures:                                               │  │
    │   │  ├── Link-layer header (MAC, RSSI)     ◄── -e flag       │  │
    │   │  ├── Full hex dump of frame            ◄── -xx flag      │  │
    │   │  └── 1024 bytes (enough for all IEs)   ◄── -s flag       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 2: PARSE EACH PROBE REQUEST                              │
    │   ════════════════════════════════                              │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  From each probe, extract:                               │  │
    │   │                                                          │  │
    │   │  MAC Address ─────► aa:bb:cc:dd:ee:ff                    │  │
    │   │  SSID ────────────► TargetNetwork (or broadcast)         │  │
    │   │  RSSI ────────────► -43dBm                               │  │
    │   │  Hex Frame ───────► 0000 3800 2f40 40a0 2008 ...         │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 3: EXTRACT INFORMATION ELEMENTS FROM HEX                 │
    │   ═════════════════════════════════════════════                 │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  Search hex for tag patterns:                            │  │
    │   │                                                          │  │
    │   │  Tag 45 (HT):   2d 1a [26 bytes] ────► Extract           │  │
    │   │  Tag 191 (VHT): bf 0c [12 bytes] ────► Extract           │  │
    │   │  Tag 255 (HE):  ff XX 23 [data]  ────► Extract           │  │
    │   │  Tag 127 (Ext): 7f 0X [8-11 bytes] ──► Extract           │  │
    │   │  Tag 221 (Ven): dd XX [OUI+data] ────► Extract OUIs      │  │
    │   │  Tag 1 (Rates): 01 0X [4-8 bytes] ───► Extract           │  │
    │   │                                                          │  │
    │   │  Record POSITION of each tag for ORDER fingerprint       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 4: BUILD FINGERPRINT STRING                              │
    │   ════════════════════════════════                              │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │                                                          │  │
    │   │   ORD:01-2d-bf-7f-dd-ff|                    (tag order)  │  │
    │   │   HT:abcdef1234567890...|                   (HT caps)    │  │
    │   │   VHT:a1b2c3d4e5f60000...|                  (VHT caps)   │  │
    │   │   HE:01a2b30400000008fc|                    (HE caps)    │  │
    │   │   EXT:0500080200000040|                     (Ext caps)   │  │
    │   │   SR:8c129824b048606c|                      (Rates)      │  │
    │   │   VEN:0017f2,8cfdf0|                        (Vendors)    │  │
    │   │   LEN:400                                   (Frame len)  │  │
    │   │                         │                                │  │
    │   │                         ▼                                │  │
    │   │                   ┌──────────┐                           │  │
    │   │                   │   MD5    │                           │  │
    │   │                   └────┬─────┘                           │  │
    │   │                        │                                 │  │
    │   │                        ▼                                 │  │
    │   │           Fingerprint: a1b2c3d4e5f67890                  │  │
    │   │                                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 5: MAP FINGERPRINTS + TRACK RSSI                         │
    │   ═════════════════════════════════════                         │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │                                                          │  │
    │   │   Fingerprint: a1b2c3d4e5f67890                          │  │
    │   │   ├── MAC: 1a:2b:3c:4d:5e:01  RSSI: -43dBm               │  │
    │   │   ├── MAC: 2b:3c:4d:5e:6f:02  RSSI: -41dBm               │  │
    │   │   ├── MAC: 3c:4d:5e:6f:70:03  RSSI: -42dBm               │  │
    │   │   ├── MAC: 4d:5e:6f:70:81:04  RSSI: -44dBm               │  │
    │   │   ├── MAC: 5e:6f:70:81:92:05  RSSI: -40dBm               │  │
    │   │   └── MAC: 6f:70:81:92:a3:06  RSSI: -43dBm               │  │
    │   │                                                          │  │
    │   │   SSID: TargetNetwork                                    │  │
    │   │   Signal Range: -40dBm to -44dBm (consistent = 1 device) │  │
    │   │                                                          │  │
    │   │   >>> SAME DEVICE - 6 MACs tracked, consistent RSSI <<<  │  │
    │   │                                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Why This Cannot Be Evaded

```
    ┌─────────────────────────────────────────────────────────────────┐
    │               WHY FINGERPRINTING WORKS                          │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   The Information Elements describe HARDWARE CAPABILITIES:      │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  Fingerprint determined by:                              │  │
    │   │  ├── WiFi chipset (Broadcom, Qualcomm, Intel, MediaTek)  │  │
    │   │  ├── Antenna configuration (1x1, 2x2, 3x3, 4x4)          │  │
    │   │  ├── Driver implementation (vendor-specific order)       │  │
    │   │  ├── Firmware version (capability flags)                 │  │
    │   │  └── OS version (extended capabilities)                  │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   If a device LIES about its capabilities:                      │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  ✗ Claims 40MHz but only supports 20MHz = Cannot connect │  │
    │   │  ✗ Claims MCS 7 but only does MCS 3 = Connection fails   │  │
    │   │  ✗ Claims VHT but has no 802.11ac = AP rejects           │  │
    │   │  ✗ Claims HE but no WiFi 6 radio = Association fails     │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   The IEs MUST be truthful for WiFi to function.               │
    │   This is why fingerprinting defeats randomization.            │
    │                                                                 │
    │   ═══════════════════════════════════════════════════════════  │
    │                                                                 │
    │   EVEN IF fingerprints match (cohort problem):                  │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  RSSI provides distance differentiation                  │  │
    │   │                                                          │  │
    │   │  Device A: -35dBm (close)  ─┐                            │  │
    │   │                              ├── Different people        │  │
    │   │  Device B: -70dBm (far)   ──┘                            │  │
    │   │                                                          │  │
    │   │  Consistent RSSI range = Same device moving around       │  │
    │   │  Wildly different RSSI = Different devices, same model   │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Example Output

```
    ┌─────────────────────────────────────────────────────────────────┐
    │        VERDANDI v2.0 - PROBE FINGERPRINT REPORT                 │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   SUMMARY                                                       │
    │   =======                                                       │
    │   Total MAC Addresses Observed: 47                              │
    │   Unique Device Fingerprints:   12                              │
    │                                                                 │
    │   *** RANDOMIZATION DETECTED ***                                │
    │   Multiple MACs mapping to same fingerprint = same device       │
    │                                                                 │
    │   ═══════════════════════════════════════════════════════════   │
    │                     DEVICE FINGERPRINTS                         │
    │   ═══════════════════════════════════════════════════════════   │
    │                                                                 │
    │   === Fingerprint: a1b2c3d4e5f67890 ===                         │
    │   Networks Probed: CoffeeShop_WiFi, HomeNetwork                 │
    │   Signal Strength: -43dBm                                       │
    │   MAC Addresses (1):                                            │
    │     1a:2b:3c:4d:5e:6f [RAND]                                    │
    │                                                                 │
    │   === Fingerprint: b2c3d4e5f6789012 ===                         │
    │   >>> SAME DEVICE - 6 MACs DETECTED <<<                         │
    │   Networks Probed: (broadcast only - privacy mode)              │
    │   Signal Range: -42dBm to -39dBm                                │
    │   MAC Addresses (6):                                            │
    │     2a:3b:4c:5d:6e:7f [RAND]                                    │
    │     3a:4b:5c:6d:7e:8f [RAND]                                    │
    │     4a:5b:6c:7d:8e:9f [RAND]                                    │
    │     5a:6b:7c:8d:9e:af [RAND]                                    │
    │     6a:7b:8c:9d:ae:bf [RAND]                                    │
    │     7a:8b:9c:ad:be:cf [RAND]                                    │
    │                                                                 │
    │   === Fingerprint: c3d4e5f678901234 ===                         │
    │   >>> SAME DEVICE - 3 MACs DETECTED <<<                         │
    │   Networks Probed: CorpGuest, Marriott_WiFi                     │
    │   Signal Range: -65dBm to -58dBm                                │
    │   MAC Addresses (3):                                            │
    │     8a:9b:ac:bd:ce:df [RAND]                                    │
    │     9a:ab:bc:cd:de:ef [RAND]                                    │
    │     aa:bb:cc:dd:ee:ff [RAND]                                    │
    │                                                                 │
    │   === Fingerprint: d4e5f67890123456 ===                         │
    │   Networks Probed: (broadcast only - privacy mode)              │
    │   Signal Range: -55dBm to -54dBm                                │
    │   MAC Addresses (1):                                            │
    │     00:11:22:33:44:55   ◄── NOT randomized (real MAC)           │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Comparison: HUGINN vs VERDANDI

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                  HUGINN vs VERDANDI                             │
    ├──────────────────────────┬──────────────────────────────────────┤
    │         HUGINN           │           VERDANDI                   │
    ├──────────────────────────┼──────────────────────────────────────┤
    │ Correlates WiFi + BLE    │ Fingerprints WiFi probe IEs          │
    │ Needs both radios active │ Works with WiFi only                 │
    │ Vendor + Time matching   │ Hardware capability matching         │
    │ Identifies device type   │ Tracks individual device             │
    │ Cross-band correlation   │ Same-band fingerprinting             │
    │ 35% minimum confidence   │ Deterministic hash matching          │
    ├──────────────────────────┴──────────────────────────────────────┤
    │                                                                 │
    │   USE TOGETHER: HUGINN identifies WHO (vendor, BLE name)        │
    │                 VERDANDI tracks WHICH device over time          │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  HUGINN sees: "Apple iPhone, BLE: John's iPhone"        │  │
    │   │  VERDANDI sees: Fingerprint a1b2c3d4e5f67890            │  │
    │   │                 with 6 MAC rotations                     │  │
    │   │                 probing for "TargetNetwork"              │  │
    │   │                 at -43dBm (close by)                     │  │
    │   │                                                          │  │
    │   │  Combined: Track "John's iPhone" persistently            │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Chain Integration

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                 FENRIR ATTACK CHAIN                             │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   [1] HUGINN ─────► WiFi+BLE identity correlation               │
    │         │           "Apple device, BLE name visible"            │
    │         ▼                                                       │
    │   [7] VERDANDI ──► Fingerprint, defeat MAC randomization        │
    │         │           "Same device seen with 6 different MACs"    │
    │         │           "Probing for: HomeWiFi, WorkNet, Starbucks" │
    │         ▼                                                       │
    │   [2] FENRIS ────► Deauth the fingerprinted device              │
    │         │           "Target same device even after MAC change"  │
    │         ▼                                                       │
    │   [3] SKOLL ─────► Lure with SSIDs from probe history           │
    │         │           "Broadcast 'HomeWiFi' - target auto-joins"  │
    │         │                                                       │
    │         ├─────────► [4] LOKI (credential harvest)               │
    │         │                 "Phishing portal captures creds"      │
    │         │                                                       │
    │         └─────────► [5] HATI (PMKID capture)                    │
    │                           "Grab WPA hash for offline crack"     │
    │                                                                 │
    │   VERDANDI enables persistent targeting even when the device    │
    │   changes its MAC address between attack stages.                │
    │                                                                 │
    │   ═══════════════════════════════════════════════════════════   │
    │                                                                 │
    │   INTELLIGENCE FLOW:                                            │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  VERDANDI captures probe: "Device probing for HomeWiFi" │  │
    │   │              │                                           │  │
    │   │              ▼                                           │  │
    │   │  SKOLL broadcasts: "HomeWiFi" Evil Twin                  │  │
    │   │              │                                           │  │
    │   │              ▼                                           │  │
    │   │  Device connects (MAC changed, but VERDANDI knows it's   │  │
    │   │  the same device by fingerprint)                         │  │
    │   │              │                                           │  │
    │   │              ▼                                           │  │
    │   │  LOKI serves phishing portal                             │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Use Cases

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                      USE CASES                                  │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   1. PERSISTENT TARGET TRACKING                                 │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Track a specific device throughout an engagement    │   │
    │      │  even as it rotates MAC addresses every few minutes. │   │
    │      │  Know when target arrives, leaves, returns.          │   │
    │      │                                                       │   │
    │      │  v2.0: RSSI tracking shows if target is approaching  │   │
    │      │        or leaving the area (-40dBm → -60dBm = leaving)│   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   2. TRUE DEVICE CENSUS                                         │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Get TRUE count of devices in an area.               │   │
    │      │  47 MACs might be only 8 actual devices.             │   │
    │      │  Essential for capacity planning assessments.        │   │
    │      │                                                       │   │
    │      │  v2.0: RSSI ranges help identify stationary devices  │   │
    │      │        vs. moving devices                             │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   3. SSID INTELLIGENCE                                          │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Devices probe for networks they've connected to:    │   │
    │      │  - Home network names                                │   │
    │      │  - Work networks ("CorpGuest", "CompanyName-5G")     │   │
    │      │  - Hotels, airports, coffee shops                    │   │
    │      │                                                       │   │
    │      │  Reveals: Where target lives, works, travels         │   │
    │      │  Use for: Evil Twin SSID selection                   │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   4. RED TEAM OPERATIONS                                        │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Identify when the same device reconnects after a    │   │
    │      │  deauth attack, even with a new MAC.                 │   │
    │      │  Maintain attack continuity across sessions.         │   │
    │      │                                                       │   │
    │      │  Track target through entire kill chain:             │   │
    │      │  Recon → Deauth → Evil Twin → Credential Harvest     │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   5. PRIVACY RESEARCH                                           │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Demonstrate that MAC randomization alone does not   │   │
    │      │  provide meaningful privacy protection.              │   │
    │      │  Academic papers, awareness presentations.           │   │
    │      │                                                       │   │
    │      │  Show: 14 observed MACs = only 8 real devices        │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   6. SURVEILLANCE DETECTION                                     │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Detect if the same device keeps appearing near you. │   │
    │      │  Different MAC each time, but same fingerprint.      │   │
    │      │  Identify potential tail/surveillance.               │   │
    │      │                                                       │   │
    │      │  v2.0: If same fingerprint appears at consistent     │   │
    │      │        RSSI wherever you go = being followed         │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## LED Indicators

```
    ┌──────────────┬──────────────────────────────┐
    │    Color     │          Meaning             │
    ├──────────────┼──────────────────────────────┤
    │  Cyan        │  Capturing probes            │
    │  Amber       │  Processing / fingerprinting │
    │  Green       │  Complete                    │
    │  Red Flash   │  Error                       │
    └──────────────┴──────────────────────────────┘
```

---

## Requirements

- WiFi Pineapple Pager with:
  - wlan1mon (monitor mode interface)
  - tcpdump (standard on Pager)

No additional packages required.

---

## Output Files

```
/root/loot/verdandi/
├── verdandi_report_YYYYMMDD_HHMMSS.txt   # Full fingerprint report
├── fingerprints_YYYYMMDD_HHMMSS.txt      # Fingerprint → MAC mapping
├── mac_to_fp_YYYYMMDD_HHMMSS.txt         # MAC → Fingerprint + RSSI
├── fp_ssids_YYYYMMDD_HHMMSS.txt          # Fingerprint → SSIDs probed
└── fp_rssi_YYYYMMDD_HHMMSS.txt           # Fingerprint → RSSI ranges
```

---

## Technical References

- IEEE 802.11-2020: HT Capabilities Element (Section 9.4.2.56)
- IEEE 802.11ac-2013: VHT Capabilities Element (Section 8.4.2.160)
- IEEE 802.11ax-2021: HE Capabilities Element (Section 9.4.2.248)
- Martin, J., et al. "A Study of MAC Address Randomization in Mobile Devices and When it Fails" (2017)
- Vanhoef, M. "Why MAC Address Randomization is not Enough" (2016)
- Cunche, M. "I know your MAC Address: Targeted tracking of individual using Wi-Fi" (2014)

---

## Author

**HaleHound**

---

## Version History

- **2.0.1** (2026-01-25) - BusyBox compatibility fix
  - Fixed RSSI extraction for BusyBox `tr` command
  - Changed `tr -d '-dBm'` to `sed 's/-//;s/dBm//'`

- **2.0.0** (2026-01-25) - Major overhaul
  - Added RSSI tracking (solves cohort problem)
  - Added IE tag ORDER fingerprinting (driver signature)
  - Added Extended Capabilities (Tag 127) extraction
  - Added Vendor Specific (Tag 221) OUI extraction
  - Added HE Capabilities (Tag 255/Ext 35) for WiFi 6
  - Added SSID extraction from probe requests
  - Added channel hopping (2.4GHz + 5GHz)
  - Improved fingerprint uniqueness

- **1.1.0** (2026-01-25) - SSID extraction
  - Added SSID extraction from probe requests
  - Shows what networks each fingerprint is looking for

- **1.0.0** (2026-01-25) - Initial release
  - Probe request IE extraction
  - HT/VHT Capabilities fingerprinting
  - Supported Rates fingerprinting
  - MAC randomization detection
  - Device tracking across MAC changes
