# Security and Legal Disclaimer

## ⚠️ LEGAL WARNING

**This tool is for educational and authorized testing purposes only.**

### Applicable Laws

Unauthorized access to or interference with wireless networks is illegal in most jurisdictions:

- **United States**: 
  - Computer Fraud and Abuse Act (CFAA) - 18 U.S.C. § 1030
  - Communications Act - 47 U.S.C. § 303
  - Violators face fines up to $250,000 and imprisonment up to 10 years

- **European Union**: 
  - Directive 2013/40/EU (Network and Information Systems attacks)
  - Telecom regulations (frequency jamming/interference)
  - GDPR violations if broadcasting affects personal data

- **United Kingdom**: 
  - Computer Misuse Act 1990
  - Wireless Telegraphy Act 2006
  - Regulatory of Investigatory Powers Act 2000

- **Canada**: 
  - Criminal Code (unauthorized access)
  - Radiocommunication Act (spectrum interference)

- **Australia**: 
  - Criminal Code (computer offense provisions)
  - Radiocommunications Act 1992

### When Use Is Authorized

This tool may only be used when:

1. ✅ You own the wireless infrastructure being tested
2. ✅ You have explicit written permission from the network owner
3. ✅ Testing is conducted within a controlled, isolated environment
4. ✅ You are a certified security professional conducting authorized penetration testing
5. ✅ Use is part of an academic/research program with proper institutional oversight
6. ✅ All applicable local telecommunications regulations are followed

**If any of the above cannot be confirmed, DO NOT use this tool.**

---

## Ethical Guidelines

This tool should never be used to:

- 🚫 Disrupt legitimate wireless networks or services
- 🚫 Interfere with emergency communication systems
- 🚫 Prevent others from accessing networks they own or are authorized to use
- 🚫 Perform "pranks" or demonstrations without consent
- 🚫 Conduct attacks for entertainment or to "prove a point"
- 🚫 Circumvent security measures on systems you don't own
- 🚫 Create or broadcast spoofed networks to trick users
- 🚫 Interfere with IoT devices, industrial control systems, or critical infrastructure

### Responsible Disclosure

If you discover wireless security vulnerabilities using this tool:

1. Do not broadcast the vulnerability or create public exploits
2. Document the issue with clear technical details
3. Contact the affected organization through proper channels
4. Allow reasonable time for patching (typically 90 days minimum)
5. Coordinate with vendors if multiple organizations are affected
6. Follow responsible disclosure practices (e.g., HackerOne, Bugcrowd guidelines)

---

## Technical Security Considerations

### Radio Frequency (RF) Safety

⚠️ **FCC Part 15 Compliance** (US):
- This device may generate RF signals that could interfere with licensed spectrum
- Operation must not cause harmful interference
- Users must accept any interference that may be received
- Device operation is restricted to authorized channels and power levels

⚠️ **Health Considerations**:
- Prolonged RF exposure near a transmitting wireless adapter can exceed safety limits
- Maintain safe distance from the wireless interface during operation
- Do not point antennas directly at people

### System Security

The Bash setup script (`src/payload.sh`) performs privileged operations:

- **Root access required** for monitor mode and packet injection
- **Package installation** (apt-get) — verify you trust the package sources
- **Background process launch** — verify logging directory permissions
- **Interface configuration** — may conflict with system network management

**Best Practices:**
- Run in isolated lab environment only
- Use dedicated test hardware
- Verify all scripts before execution
- Review dependencies and installed packages
- Monitor system logs for unauthorized access: `sudo tail -f /var/log/auth.log`

### Network Isolation

**Critical**: Ensure your test environment is:

- 🔒 Disconnected from production networks
- 🔒 Disconnected from the internet (or behind strict firewall rules)
- 🔒 Using isolated wireless spectrum (no interference with external networks)
- 🔒 In an RF-shielded enclosure if possible (Faraday cage)
- 🔒 Not accessible to unauthorized personnel

### Python Dependencies

The tool requires **Scapy** library which has security implications:

- Scapy is a powerful packet manipulation library with no built-in safety checks
- It can be used to craft malicious packets beyond beacon bombs
- Ensure Scapy is installed from official sources: `pip install scapy`
- Verify package integrity: `pip show scapy` and check version/location

**Never pipe installation directly from the internet:**
```bash
# ❌ UNSAFE
curl https://example.com/install.sh | sudo bash

# ✅ SAFE
# Review script first
sudo bash install.sh
```

---

## Operational Security (OpSec)

### Before Testing

- [ ] Verify legal authorization in writing
- [ ] Confirm scope of testing (which networks, frequency ranges, duration)
- [ ] Identify point of contact at organization for incident reporting
- [ ] Set up isolated network environment
- [ ] Document equipment used and baseline configurations
- [ ] Establish emergency stop procedure (kill switch)
- [ ] Notify IT security teams of scheduled testing window

### During Testing

- [ ] Keep detailed logs of all activities: `tail -f /tmp/wifi_bomb.log`
- [ ] Monitor system resources to prevent DoS of your own equipment
- [ ] Watch for unexpected behaviors or crashes
- [ ] Have network monitoring active to detect impact: `sudo tcpdump -i any`
- [ ] Never test during critical business hours without written approval
- [ ] Have administrator on standby for immediate shutdown if needed

### After Testing

- [ ] Stop all processes: `killall python3` or `Ctrl+C`
- [ ] Restore wireless interfaces to normal mode: `sudo airmon-ng stop wlan0mon`
- [ ] Clean up temporary files: `rm /tmp/wifi_bomb.log`
- [ ] Document findings in test report
- [ ] Securely archive logs and evidence
- [ ] Delete test files from test systems

---

## Liability and Disclaimer

**DISCLAIMER:**

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED. THE AUTHORS AND CONTRIBUTORS ASSUME NO LIABILITY FOR:

- Unauthorized use or misuse of this tool
- Legal consequences of using this tool illegally
- Damage to computer systems, networks, or data
- Interference with wireless communications
- Personal injury or harm caused by RF exposure
- Loss of business, revenue, or data
- Any direct, indirect, incidental, or consequential damages

**BY USING THIS TOOL, YOU AGREE:**

1. You have legal authorization to use it
2. You understand the legal risks and accept full responsibility
3. You will use it only for authorized purposes
4. You will comply with all applicable laws and regulations
5. You will not hold the authors liable for any consequences
6. You understand the potential for harm to wireless systems and infrastructure

---

## Reporting Security Issues

If you discover a vulnerability in this tool itself:

1. **Do NOT** create a public GitHub issue
2. Email security details to: [repository owner email]
3. Include:
   - Detailed description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if available)
4. Allow 30 days for response before public disclosure

---

## Resources and References

### Legal Resources
- [FCC Regulations - Part 15](https://www.fcc.gov/media/7497/fcc-15-01-r.pdf)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [OWASP Security Guidelines](https://owasp.org/)
- [HackerOne Disclosure Guidelines](https://www.hackerone.com/disclosure-guidelines)

### Technical Resources
- [Scapy Documentation](https://scapy.readthedocs.io/)
- [802.11 Standards](https://en.wikipedia.org/wiki/IEEE_802.11)
- [Airmon-ng Documentation](https://www.kali.org/tools/aircrack-ng/)
- [RF Safety Guidelines](https://www.fcc.gov/general/radio-frequency-radiation-safety)

### Educational Resources
- [SANS Penetration Testing](https://www.sans.org/)
- [CEH (Certified Ethical Hacker)](https://www.eccouncil.org/certifications/certified-ethical-hacker-ceh/)
- [PWK/OSCP](https://www.offsec.com/courses/pen-200/)

---

## Summary

**Use this tool responsibly.**

- Understand the legal implications in your jurisdiction
- Obtain explicit written authorization before testing
- Follow ethical penetration testing practices
- Maintain detailed records of all activities
- Report vulnerabilities responsibly
- Never test systems without consent

**The security of wireless networks is everyone's responsibility.**

---

*Last updated: September 2, 2026*
*For questions or concerns, contact the repository maintainers.*