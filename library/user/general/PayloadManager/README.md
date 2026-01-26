# Payload Manager

A comprehensive payload management tool for the WiFi Pineapple Pager. Browse, install, update, enable, and disable payloads directly from your device without needing a computer.

## Features

- **Browse & Compare** - View all available payloads from the GitHub repository organized by category, with real-time status indicators showing what's installed, outdated, or new
- **Check for Updates** - Get a summary of available updates with the choice of interactive review or batch update mode
- **Install/Uninstall** - Add new payloads from the repository or remove existing ones from your device
- **Enable/Disable** - Temporarily disable payloads without deleting them - useful for troubleshooting or freeing up menu space
- **Persistent Settings** - Configure default behaviors that persist across firmware upgrades

## First Run Setup

On first launch, Payload Manager walks you through initial configuration:

1. **Update Mode** - Choose how updates are handled (ask each time, always interactive, or always batch)
2. **Repository** - Use the official Hak5 repository or specify a custom fork
3. **Display Options** - Whether to show local-only payloads in browse view

These settings are saved persistently and can be changed later from the Settings menu.

## Menu Options

| Option            | Description                                                    |
|-------------------|----------------------------------------------------------------|
| Browse & Compare  | Navigate payloads by category, view details, install or update |
| Check for Updates | Summary of available updates with batch or interactive mode    |
| Manage Installed  | List all enabled payloads, disable or uninstall them           |
| Manage Disabled   | List all disabled payloads, re-enable or uninstall them        |
| Settings          | Configure update behavior, repository, and display options     |

## Status Indicators

When browsing payloads, status icons indicate their current state:

| Icon    | Meaning                                               |
|---------|-------------------------------------------------------|
| `[NEW]` | Available on GitHub but not installed locally         |
| `[OK]`  | Installed and matches the latest GitHub version       |
| `[UPD]` | Installed but a newer version is available            |
| `[DIS]` | Installed but currently disabled                      |
| `[LOC]` | Exists locally but not found in the GitHub repository |

## Settings

Access settings from the main menu to configure:

| Setting            | Description                                              |
|--------------------|----------------------------------------------------------|
| Update mode        | `ask` (prompt each time), `interactive`, or `batch`      |
| Repository         | Use official Hak5 repo or specify a custom `user/repo`   |
| Branch             | Which branch to pull from (default: `master`)            |
| Show local payloads | Whether to display `[LOC]` payloads when browsing       |

Settings persist across reboots and firmware upgrades using the Pager's config system.

## Update Workflow

When checking for updates, you'll see a summary of how many payloads are up to date, how many updates are available, and how many new payloads exist.

Based on your **Update mode** setting:

- **Ask** (default) - Prompts whether to review individually or update all
- **Interactive** - Automatically enters interactive mode to review each payload
- **Batch** - Automatically installs all new payloads and applies all updates

After updates complete, you'll see a summary of what was installed, updated, or skipped.

## How Disable Works

Disabling a payload renames `payload.sh` to `payload.sh.disabled`. This hides the payload from the pager's discovery mechanism since it looks for files named `payload.sh`. The payload directory and all its files remain intact, so you can re-enable it at any time.

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

By default, payloads are pulled from the official Hak5 repository:
<https://github.com/hak5/wifipineapplepager-payloads>

You can configure a custom repository in Settings to use your own fork or a community repository.
