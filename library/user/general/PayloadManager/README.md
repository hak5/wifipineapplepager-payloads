# Payload Manager

A comprehensive payload management tool for the WiFi Pineapple Pager. Browse, install, update, enable, and disable payloads directly from your device without needing a computer.

## Features

- **Browse & Compare** - View all available payloads from the GitHub repository organized by category, with real-time status indicators showing what's installed, outdated, or new
- **Check for Updates** - Get a summary of available updates with the choice of interactive review or batch update mode
- **Install/Uninstall** - Add new payloads from the repository or remove existing ones from your device
- **Enable/Disable** - Temporarily disable payloads without deleting them - useful for troubleshooting or freeing up menu space

## Menu Options

| Option             | Description                                                              | Network  |
|--------------------|--------------------------------------------------------------------------|----------|
| Browse & Compare   | Navigate payloads by category, view details and metadata, install or update | Required |
| Check for Updates  | Summary of available updates with batch or interactive update mode       | Required |
| Manage Installed   | List all enabled payloads, disable or uninstall them                     | Offline  |
| Manage Disabled    | List all disabled payloads, re-enable or uninstall them                  | Offline  |

## Status Indicators

When browsing payloads, status icons indicate their current state:

| Icon    | Meaning                                              |
|---------|------------------------------------------------------|
| `[NEW]` | Available on GitHub but not installed locally        |
| `[OK]`  | Installed and matches the latest GitHub version      |
| `[UPD]` | Installed but a newer version is available           |
| `[DIS]` | Installed but currently disabled                     |
| `[LOC]` | Exists locally but not found in the GitHub repository |

## Update Workflow

When checking for updates, you'll see a summary of how many payloads are up to date, how many updates are available, and how many new payloads exist. From there you can choose:

1. **Interactive Mode** - Review each new/updated payload one by one and decide whether to install or skip
2. **Batch Mode** - Automatically install all new payloads and apply all updates at once
3. **Skip** - Cancel and return to the main menu

After updates complete, you'll see a summary of what was installed, updated, or skipped.

## How Disable Works

Disabling a payload renames `payload.sh` to `payload.sh.disabled`. This hides the payload from the pager's discovery mechanism since it looks for files named `payload.sh`. The payload directory and all its files remain intact, so you can re-enable it at any time by simply renaming the file back.

This is useful when you want to:

- Temporarily remove a payload from your menu without losing it
- Troubleshoot issues by disabling payloads one at a time
- Keep payloads installed but not cluttering your payload list

## Self-Update Protection

If the Payload Manager itself has an update available, the update is queued and applied when you exit the manager. This prevents issues that could occur from overwriting a running script.

## Requirements

- Network connection for browsing, installing, and updating payloads
- `wget` and `unzip` packages (automatically installed if missing)

## Source Repository

Payloads are pulled from the official [Hak5 WiFi Pineapple Pager Payloads](https://github.com/hak5/wifipineapplepager-payloads) repository.
