# Pager quack

**Author:** spywill
**Version:** 2.0
**Platform:** Hak5 WiFi Pineapple Pager
**Language:** Bash

Pager quack is a Hak5 WiFi Pineapple Pager payload for communicating with a **Hak5 KeyCroc** over SSH.

It allows you to:

* Send individual `QUACK` commands to a KeyCroc
* Create and run saved Ducky/QUACK payloads
* Automatically discover the KeyCroc using `croc.lan` or `croc`
* Save the KeyCroc IPv4 address for future connections
* Save and reuse the KeyCroc password
* Read previously captured keystroke logs
* Monitor the KeyCroc keystroke log live
* Automatically create the required payload and keystroke directories
* Automatically create a default test payload
* Install `sshpass` when it is missing

> **Note:** This payload is intended for use with KeyCroc devices and systems that you own or are explicitly authorized to test.

---

## Features

### 🦆 Send QUACK Commands

The **Quack Command** option allows you to enter a single QUACK command directly from the Pager.

Example:

```text
QUACK STRING hello world
```

The command is sent to the KeyCroc over SSH.

---

### 📄 Ducky Payloads

Pager quack can load `.txt` payload files from:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/
```

Each `.txt` file is displayed in the payload selection menu.

For example:

```text
DuckyPayloads/
├── QUACK.txt
├── Test.txt
├── Demo.txt
└── Example.txt
```

Selecting a payload sends its contents to the KeyCroc.

### Example payload

```text
#---> Default Ducky Payload
QUACK STRING "test 1"
QUACK ENTER
QUACK DELAY 2000
QUACK STRING "test 2"
QUACK ENTER
QUACK DELAY 2000
QUACK STRING "working"
QUACK ENTER
```

---

## ⌨️ Keystroke Menu

The **Keystroke Menu** provides two options:

```text
KEYSTROKE MENU

Previous_keystrokes
Live_keystrokes
Exit
Main_menu
```

### Previous Keystrokes

The payload connects to the KeyCroc and searches for:

```text
croc_char.log
```

It collects information about the log files, including:

* File location
* Number of characters
* Log contents

The collected information is saved locally on the Pager.

Output is stored at:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/KeyCroc_Keystrokes/KeyCroc_Keystrokes.txt
```

---

### Live Keystrokes

The live keystroke option uses SSH and `tail -f` to monitor:

```text
/root/loot/croc_char.log
```

New characters are displayed on the Pager as they appear in the log.

Press **A** to stop the live monitoring session and return to the menu.

---

# 📁 Directory Structure

Pager quack uses the following directory structure:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/
│
├── croc_IP.txt
├── croc_passwd.txt
│
├── DuckyPayloads/
│   ├── QUACK.txt
│   └── *.txt
│
└── KeyCroc_Keystrokes/
    └── KeyCroc_Keystrokes.txt
```

If the required directories do not exist, Pager quack automatically creates them.

---

# ⚙️ Configuration

The main paths are defined at the beginning of the payload:

```bash
DUCKY_PAYLOAD="/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads"

PASS_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_passwd.txt"

CROC_IP_FILE="/mmc/root/payloads/user/remote_access/Pager_quack/croc_IP.txt"

SAVE_KEYSTROKE="/mmc/root/payloads/user/remote_access/Pager_quack/KeyCroc_Keystrokes"

REMOTE_FILE="/root/loot/croc_char.log"
```

### KeyCroc remote log

The payload expects the KeyCroc keystroke log to be located at:

```text
/root/loot/croc_char.log
```

If your KeyCroc uses a different location, change:

```bash
REMOTE_FILE="/root/loot/croc_char.log"
```

---

# 🔑 sshpass

Pager quack requires `sshpass` to authenticate to the KeyCroc automatically.

The payload checks whether `sshpass` is already installed.

If it is missing, the payload:

1. Checks for an Internet connection.
2. Asks for permission to install `sshpass`.
3. Runs `opkg update`.
4. Installs `sshpass` to the Pager's MMC storage.
5. Verifies that the package was installed.

The payload uses:

```text
/mmc/usr/bin/sshpass
```

instead of relying on `sshpass` being in the default PATH.

---

# 🌐 Network Requirements

The Pager and KeyCroc need to be able to communicate with each other.

They can be connected through:

### Same Local Network

```text
Pager
  │
  ├── Wi-Fi/LAN
  │
  └── KeyCroc
```

### Pager Open Access Point

The KeyCroc can alternatively connect directly to the Pager's open AP.

```text
        Pager
     Open Access Point
           │
           │ Wi-Fi
           │
        KeyCroc
```

The payload attempts to find the KeyCroc automatically.

It first tries:

```text
croc.lan
```

and then:

```text
croc
```

IPv4-only ping resolution is used.

---

# 📡 KeyCroc Discovery

Pager quack attempts to resolve the KeyCroc using:

```bash
ping -4 -c 1 -W 5 croc.lan
```

If that fails, it tries:

```bash
ping -4 -c 1 -W 5 croc
```

If neither name resolves, the payload checks for a previously saved IP address:

```text
croc_IP.txt
```

If no usable address is available, an IP picker is displayed:

```text
Enter keycroc IP
```

The selected IP address is then saved for future use.

---

# 🔐 Password Storage

The KeyCroc password is stored in:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/croc_passwd.txt
```

If the password file does not exist, the payload uses:

```text
hak5croc
```

as the default value in the password prompt.

The password can then be changed through the Pager interface.

> **Security:** The password is stored as plain text on the Pager. Protect the Pager and payload directory appropriately.

---

# 🖥️ Main Menu

When Pager quack starts, the main menu contains:

```text
MAIN MENU

Quack_Command
Ducky_Payload
keystrokes
Exit
```

### Quack_Command

Enter and send a single QUACK command.

### Ducky_Payload

Select and execute a saved `.txt` payload.

### keystrokes

Open the keystroke menu:

```text
Previous_keystrokes
Live_keystrokes
Exit
Main_menu
```

### Exit

Exit the payload.

---

# 🚀 Installation

Copy the payload into your Pager payload directory.

Example:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/
```

The directory should contain the main payload and can contain the following directories:

```text
Pager_quack/
├── DuckyPayloads/
└── KeyCroc_Keystrokes/
```

The payload will create missing directories automatically.

---

# 📝 Creating Your Own Payload

Create a `.txt` file inside:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/
```

For example:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/MyPayload.txt
```

Add your QUACK commands:

```text
QUACK STRING "Hello from Pager"
QUACK ENTER
QUACK DELAY 1000
QUACK STRING "Pager quack is working"
QUACK ENTER
```

Start Pager quack and select:

```text
Ducky_Payload
```

Your payload will appear in the selection menu.

---

# 🔄 Workflow

The general connection workflow is:

```text
Start Pager quack
       │
       ▼
Check required directories
       │
       ▼
Check sshpass
       │
       ▼
Find KeyCroc
       │
       ├── croc.lan
       │
       ├── croc
       │
       └── Saved/manual IPv4
       │
       ▼
Check KeyCroc connectivity
       │
       ▼
Enter/load password
       │
       ▼
MAIN MENU
       │
       ├── Quack Command
       │
       ├── Ducky Payload
       │
       ├── Keystrokes
       │     ├── Previous
       │     └── Live
       │
       └── Exit
```

---

# 🛠️ Requirements

### Hardware

* Hak5 WiFi Pineapple Pager
* Hak5 KeyCroc

### Pager software

* Bash
* `ssh`
* `sshpass`
* `ping`
* `nc`
* `sed`
* `grep`
* `head`
* `cat`
* `find`
* `strings`
* `tail`

### Network

The Pager must be able to reach the KeyCroc over IPv4.

---

# ⚠️ Security Considerations

Pager quack uses SSH authentication with:

```bash
sshpass -p "$croc_passwd"
```

The payload also uses:

```text
-o StrictHostKeyChecking=no
```

This allows the payload to connect without requiring manual SSH host-key confirmation.

For this reason, use the payload only on systems and networks where you have authorization.

The saved password is also stored in plain text:

```text
croc_passwd.txt
```

Consider protecting access to the Pager and the payload directory.

---

# 🐛 Troubleshooting

## KeyCroc cannot be found

Verify that the KeyCroc is connected to the same network as the Pager.

Try manually checking:

```bash
ping -4 croc.lan
```

or:

```bash
ping -4 croc
```

If hostname resolution does not work, Pager quack will allow you to enter the IPv4 address manually.

---

## KeyCroc is unreachable

Check the saved IP:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/croc_IP.txt
```

Make sure the address belongs to the KeyCroc.

---

## sshpass is not installed

Pager quack automatically offers to install it when an Internet connection is available.

You can also check:

```bash
opkg list-installed | grep sshpass
```

---

## No payloads appear

Make sure your payload files end in:

```text
.txt
```

and are located in:

```text
/mmc/root/payloads/user/remote_access/Pager_quack/DuckyPayloads/
```

For example:

```text
DuckyPayloads/Test.txt
```

---

## Previous keystrokes are empty

The payload searches the KeyCroc filesystem for:

```text
croc_char.log
```

The KeyCroc must have an existing log file containing data.

---

## Live keystrokes do not display

The live monitor expects:

```text
/root/loot/croc_char.log
```

on the KeyCroc.

Make sure the file exists and is actively being updated.

---

# 📜 Version

## v2.0

Current version: **2.0**

### Included

* KeyCroc hostname discovery
* IPv4-only discovery
* Saved KeyCroc IP
* Saved KeyCroc password
* Automatic `sshpass` installation
* Single QUACK command support
* Ducky payload menu
* Automatic payload directory creation
* Default test payload
* Previous keystroke collection
* Live keystroke monitoring
* Pager button controls
* Main menu navigation

---

# ⚖️ Disclaimer

This project is provided for authorized security testing, research, development, and educational purposes.

Only use Pager quack with KeyCroc devices, computers, networks, and data that you own or have explicit permission to test.

The author is not responsible for unauthorized use or misuse of this payload.
