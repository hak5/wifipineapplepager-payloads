# 🐛 Network Worm — WiFi Pineapple Pager

**Created by:** Hackazillarex
**Version:** 1.0
**Platform:** WiFi Pineapple Pager

## 📖 What Is This?

Network Worm is a network testing script made for the WiFi Pineapple Pager. It helps you discover devices connected to a network, check whether they allow SSH access, and save the results in log files.

The goal is to automate parts of network testing that would otherwise take time to do manually.

⚠️ **Warning: This tool is intended for authorized testing only.** Only use it on your own devices or networks you have explicit permission to test. Never use it to access someone else's systems without permission.

## ✨ Features

* 🔍 **Network Scanning** — Looks for devices connected to the selected network.
* 🔑 **SSH Access Checks** — Tests a set of configured login credentials.
* 💻 **Operating System Detection** — Attempts to identify whether a device is running Linux or Windows.
* 📡 **WiFi Support** — Can use the Pager's `wlan0cli` interface.
* 🔌 **Ethernet Support** — Can use `eth1` with a compatible USB Ethernet adapter.
* 📝 **Automatic Logs** — Saves scan results and error messages for later review.
* ⚙️ **Interactive Setup** — Lets you choose network settings through the Pager's interface.
* 📊 **Run Summary** — Reports how many hosts were found and where the results were saved.

## 🧰 What You Need

Before using the script, make sure you have:

* A WiFi Pineapple Pager.
* Access to a network you're authorized to test.
* Nmap for finding devices on the network.
* SSH client tools for checking remote access.
* `sshpass` for automated login testing.
* A compatible USB Ethernet adapter if you want to use Ethernet mode.

The script attempts to install `sshpass` automatically if it is missing. Other tools and the Pager's built-in scripting functions must also be available.

## 📡 Network Options

| Interface  | What it does                            |
| ---------- | --------------------------------------- |
| `wlan0cli` | Uses the wireless network connection.   |
| `eth1`     | Uses a compatible USB Ethernet adapter. |

When Ethernet mode is selected, the script checks for the adapter and attempts to obtain network settings automatically.

## ⚙️ Default Settings

| Setting             | Default                   |
| ------------------- | ------------------------- |
| Listener IP         | `10.0.0.222`              |
| Listener port       | `4444`                    |
| Ethernet adapter ID | `0bda:8152`               |
| Results folder      | `/root/loot/network_worm` |

The script asks you to configure the listener address and port when it runs. These settings alone do not guarantee that a listener is running or reachable.

## 🚀 How It Works

Here's a simple breakdown of what happens when the script runs:

1. **Checks its tools** — Makes sure required software is available.
2. **Chooses a connection** — Selects WiFi or Ethernet.
3. **Checks the network** — Finds the local network and its gateway.
4. **Looks for devices** — Scans the network for responding hosts.
5. **Checks SSH access** — Tests the configured credentials against discovered devices.
6. **Identifies systems** — Attempts to determine which operating system a device uses.
7. **Saves the results** — Writes information to local log files.
8. **Shows a summary** — Reports the results of the run.

The supplied script also contains code for deploying remote command-execution payloads. These functions can make changes to other systems, so they should only be evaluated in an isolated lab with explicit authorization.

## 📁 Where Are the Results Saved?

Everything is saved in:

```text
/root/loot/network_worm/
```

| File                      | What it contains                                               |
| ------------------------- | -------------------------------------------------------------- |
| `worm_<timestamp>.txt`    | The main report from the run.                                  |
| `compromised_hosts.log`   | Devices where the tested login credentials were accepted.      |
| `error.log`               | Errors encountered during selected steps.                      |
| `cleanup_<timestamp>.txt` | A record of generated cleanup commands.                        |
| `win_shell_<host>.ps1`    | A PowerShell file generated for Windows-related functionality. |

**Keep these files private.** They may contain usernames, passwords, network addresses, and other sensitive information.

## 🛠️ Troubleshooting

**The script cannot install `sshpass`.**

Check your internet connection, package sources, and device firmware.

**The Ethernet adapter is not detected.**

Check the USB connection and confirm that the adapter is compatible.

**No devices are found.**

Make sure you selected the correct network interface and that the devices are reachable. Some networks block scanning traffic.

**SSH checks are failing.**

Confirm that SSH is enabled on the test devices and that you're using authorized test credentials.

**The results seem incomplete.**

Some devices may not respond to network scans, and not every command is guaranteed to succeed. Check the logs for errors.

## 🔒 Responsible Use

Please keep these points in mind:

* Only test networks and devices you are authorized to assess.
* Use a dedicated lab network whenever possible.
* Never use real or sensitive passwords for testing.
* Review what the script does before running it.
* Protect collected logs and remove sensitive test data when appropriate.
* Verify that any changes made during testing have been properly reversed.

## ⚠️ Disclaimer

This project is provided for educational purposes and authorized security testing.

The author is not responsible for unauthorized use, damage, data loss, or other consequences resulting from misuse. You are responsible for ensuring that your activities comply with applicable laws and permissions.



