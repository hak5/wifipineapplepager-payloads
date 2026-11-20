# SmartRogue-AI Technical Specifications
## Project Overview
SmartRogue-AI is an advanced, adaptive Rogue Access Point and Dynamic Captive Portal payload designed specifically for the WiFi Pineapple Pager. Unlike static attacks, it passively analyzes 802.11 management frames and probe requests to fingerprint client operating systems in real-time and serve tailored captive portal interfaces.

---

## 1. Configuration Management (`config.yaml`)

The system uses a centralized YAML configuration to maintain operational flexibility without modifying the core logic.

### YAML Schema
```yaml
system:
  interface: "wlan0"          # Wireless interface for monitoring/AP
  monitor_interface: "wlan0mon" 
  log_level: "INFO"           # DEBUG, INFO, WARNING, ERROR
  timeout: 30                 # Client tracking timeout in seconds

captive_portal:
  dns_server: "192.168.1.1"
  dhcp_range: "192.168.1.10-192.168.1.100"
  port: 80
  templates_dir: "/etc/smartrogue/templates"
  default_template: "generic"

exfiltration:
  webhook_url: "https://api.example.com/webhook"
  api_key: "YOUR_SECRET_KEY"
  upload_interval: 60         # Seconds between batch uploads

fingerprinting:
  enabled: true
  sensitivity: "high"         # low, medium, high
  whitelist_ouis: ["00:11:22:33:44:55"]
```

---

## 2. OS Fingerprinting Logic (`core/fingerprint.py`)

The module analyzes IEEE 802.11 Information Elements (IEs) found in Probe Requests and Association Requests.

### Fingerprinting Matrix

| Target OS | Key IEEE Elements / Heuristics | Analysis Logic |
| :--- | :--- | :--- |
| **iOS** | $\text{IE} = 1$ (SSID), $\text{IE} = 45$ (Vendor Specific) | Check for Apple-specific OUI (00:05:02, 00:0A:27) and specific HT capabilities (802.11n/ac) patterns typical of iPhone/iPad. |
| **Android** | $\text{IE} = 1$, $\text{IE} = 127$ (Vendor Specific) | Look for Google/Android specific tags in vendor IEs. Analyze supported rates (Basic Rates) which often differ from iOS. |
| **Windows** | $\text{IE} = 45$, $\text{IE} = 127$ | Analyze "Supported Rates" and "Extended Supported Rates" combined with Microsoft OUIs. Windows often requests specific WPA2/3 capabilities in probe requests. |
| **macOS** | $\text{IE} = 45$ (Apple OUI) | Similar to iOS but with different HT/VHT capabilities and probe interval timing characteristics. |

### Logic Flow
1. **Packet Capture**: Sniff 802.11 management frames.
2. **OUI Lookup**: Extract MAC address and check the first 3 bytes against the vendor database.
3. **IE Parsing**: Iterate through the Information Elements.
4. **Score Calculation**: Assign weights to detected elements. If a threshold is met for a specific OS, that OS is flagged.
5. **Result Return**: Return a string identifier (e.g., `"ios"`, `"android"`, `"windows"`, `"macos"`, `"generic"`).

---

## 3. Engine Architecture (`core/engine.py`)

The engine employs a multi-threaded architecture to handle simultaneous sniffing, analysis, and serving.

### Thread Architecture
- **Main Thread**: Initializes interfaces, loads `config.yaml`, and orchestrates the lifecycle of worker threads.
- **Sniffer Thread (Passive)**:
    - Uses `scapy` or `tshark` to monitor the airwaves.
    - Filters for Probe Requests and Association Requests.
    - Pushes raw packets into a `Queue`.
- **Analysis Thread (Fingerprinting)**:
    - Consumes packets from the `Queue`.
    - Calls `fingerprint.py` to determine OS.
    - Maps the client MAC to the detected OS in a shared `ClientState` dictionary.
- **Portal Thread (Active)**:
    - Monitors the `ClientState` dictionary.
    - When a client attempts to connect or browse, it dynamically selects the template based on the detected OS.
    - Serves the tailored HTML/CSS interface.
- **Exfiltration Thread**:
    - Periodically flushes collected data (MAC, OS, Captive Portal inputs) to the configured webhook.

---

## 4. Bootstrap Process (`payload.sh`)

The shell script ensures the environment is primed for the Python core.

### Flow of `payload.sh`
1. **Privilege Check**: Verify if the script is running as `root`. Exit if not.
2. **Dependency Check**: Check for `python3`, `scapy`, `pyyaml`, and `hostapd`.
3. **Interface Setup**:
    - Kill interfering processes: `airmon-ng check kill`.
    - Put wireless interface into monitor mode: `airmon-ng start wlan0`.
4. **Network Configuration**:
    - Setup a basic DHCP server (dnsmasq) to provide IPs to victims.
    - Configure the fake AP (hostapd) if active mode is enabled.
5. **Core Execution**:
    - Run the Python engine: `python3 -I core/engine.py`.
6. **Cleanup (on exit)**:
    - Return interface to managed mode.
    - Kill DHCP/DNS processes.
