## Public_IP_Subnetter_Getter

**Author:** THENRGLABS
**Version:** 1.0
**Category:** Exfiltration Tool
---

### Overview

**Public_IP_Subnetter_Getter** is an all-in-one reconnaissance and exfiltration tool for network discovery and detailed scanning. The tool gathers essential information about the local network, detects the public IP address, performs ARP discovery, and scans for open ports and vulnerabilities. The script is designed to be used with minimal interaction and allows for both stealthy and aggressive scans, depending on the user's preference.

---

### Key Features

* **Public IP Detection:** Identifies the public-facing IP of the machine using multiple fail-safe services.
* **ARP Discovery (Optional):** Performs an ARP-based discovery to find live hosts on the local network (optional, can be skipped for a faster scan).
* **Nmap Scanning:** Performs both basic ping sweeps and detailed Nmap scans to discover active devices, open ports, and services.
* **CVE Enumeration:** Detects known vulnerabilities on open ports using Nmap scripts to identify high-risk services (e.g., SMB, FTP, SSH).
* **Risk Assessment:** Provides a summary of the discovered hosts and vulnerabilities, with risk levels associated with each detected CVE.
* **Customizable Scan Depth:** Offers users a choice between a fast scan (top 100 ports) and a full port scan for deeper analysis.
* **Looting & Logging:** Saves detailed logs of each scan phase and exports findings to a structured loot directory (`/root/loot/Smart_scanner`).

---

### Functionality Breakdown

1. **Public IP Detection**

   * The script starts by attempting to determine the machine's public IP address.
   * It uses several external services (such as `ipify`, `ifconfig.me`, `checkip.amazonaws.com`) to retrieve the public IP.
   * If the public IP is detected, it is saved into a file in the loot directory (`/root/loot/Smart_scanner/public_ip_TIMESTAMP.txt`).

   **Why this is useful:** The public IP address is a crucial piece of information for identifying the external network and can be used for network analysis or penetration testing.

2. **ARP Discovery**

   * An optional ARP scan is run to discover live hosts in the local subnet (using the `-PR` Nmap flag).
   * If ARP discovery is skipped, a basic Nmap ping sweep (`-sn`) is performed instead.
   * The discovered live hosts are logged into a file (`/root/loot/Smart_scanner/arp_discovery_TIMESTAMP.txt`).

   **Why this is useful:** ARP discovery is useful for enumerating devices on the local network, even those that might be hiding behind firewalls or NAT.

3. **Nmap Scanning**

   * The script allows users to choose between running a fast Nmap scan (top 100 ports) or a full port scan (`-p-`).
   * After the ARP discovery or ping sweep, the script proceeds to scan for open ports on the discovered hosts.
   * The results are saved in a file (`/root/loot/Smart_scanner/open_ports_TIMESTAMP.txt`).

   **Why this is useful:** Nmap is the go-to tool for port scanning and allows an attacker to gather crucial information about what services and ports are open on discovered hosts.

4. **CVE Enumeration**

   * The script can optionally run a CVE (Common Vulnerabilities and Exposures) enumeration on the discovered open ports.
   * It uses Nmap scripts (`--script vuln`) to identify vulnerabilities like outdated software versions, misconfigurations, or insecure services.
   * CVE details are saved in a file (`/root/loot/Smart_scanner/cve_enum_TIMESTAMP.txt`).

   **Why this is useful:** Identifying vulnerabilities is essential for exploiting weaknesses in the network. CVE enumeration helps prioritize which services pose the greatest risk.

5. **Risk Assessment**

   * The script analyzes open ports and known CVEs and categorizes them by risk levels.
   * Ports such as FTP, SSH, Telnet, HTTP, and SMB are flagged as potential high-risk services.
   * This analysis provides users with a high-level overview of the network's security posture.

   **Why this is useful:** Quickly identifying high-risk services allows an attacker to target weak points for further exploitation.

6. **Looting and Logging**

   * All the discovered information (IP addresses, open ports, CVEs) is logged into files in a loot directory.
   * The loot directory structure is designed to organize findings neatly and chronologically.
   * All logs are timestamped for easy reference and export.

   **Why this is useful:** Structured loot makes it easier to review findings and export them for further analysis or reporting.

### Interaction

The script will prompt the user for input at several stages:

1. **Public IP Detection**: The script will display the public IP address and ask if you want to proceed.
2. **ARP Discovery**: You will be asked whether to perform an ARP discovery on the local subnet. If denied, a ping sweep is performed instead.
3. **Nmap Scan**: You will be prompted to choose between a fast or full Nmap scan.
4. **CVE Enumeration**: After port scanning, the script will ask whether to run CVE enumeration on the discovered services.
5. **Final Summary**: The script outputs a summary of the scan results, including detected services, CVEs, and associated risks.

---

### Loot Directory Structure

The results of each phase of the scan will be saved in the following directory structure:

```
/root/loot/Smart_scanner/
├── public_ip_TIMESTAMP.txt       # Public IP of the machine
├── arp_discovery_TIMESTAMP.txt  # ARP discovery results
├── open_ports_TIMESTAMP.txt     # Open port scan results
├── cve_enum_TIMESTAMP.txt       # CVE enumeration results
└── live_hosts_TIMESTAMP.txt     # List of live hosts discovered via ARP/ping
```

### Disclaimer

This tool is for educational purposes only. **IP_Subnetter_Getter** should not be used for unauthorized access to any network or system. Always ensure you have explicit permission before using any recon or penetration testing tools on a network.

---

### Contributing

Feel free to contribute improvements to the script or documentation. Fork the repository, create a branch, and submit a pull request with any changes or additions you make.

---

### License

Distributed under the MIT License. See `LICENSE` for more information.

---

Let me know if you’d like me to help you make any changes or if there’s more information you want to add!
