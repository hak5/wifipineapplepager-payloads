# Pull PR AIO

Downloads and overwrites Payloads, Themes, or Ringtones from a specific GitHub Pull Request.

## Description

An All-In-One payload that combines the functionality of:
- **Pull Payload PR** - Downloads payloads from `hak5/wifipineapplepager-payloads`
- **Pull Theme PR** - Downloads themes from `hak5/wifipineapplepager-themes`
- **Pull Ringtone PR** - Downloads ringtones from `hak5/wifipineapplepager-ringtones`

## Usage

1. Run the payload
2. Select the type of PR to pull: **Payload**, **Theme**, or **Ringtone**
3. Enter the Pull Request number
4. Confirm the PR details
5. Choose whether to review each file or overwrite all

## Features

- Single payload for all three PR types
- Fetches PR info and file list from GitHub API
- Pagination support for large PRs
- Optional file-by-file review or batch overwrite/skip
- Handles disabled payloads and alerts

## Requirements

- `curl` or `wget` (auto-installed if missing)
- `unzip` (auto-installed if missing)

## Credits

- Original payloads by Austin (git@austin.dev)
- Pagination fix by Hackazillarex
- Combined AIO by z3r0l1nk
