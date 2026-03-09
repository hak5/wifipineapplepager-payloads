# Pull Theme PR

Downloads and installs themes from a specific GitHub Pull Request in the WiFi Pineapple Pager themes repository.

## Description

This payload allows you to test themes from Pull Requests before they are merged into the main repository. It downloads the PR archive, extracts changed files from the `themes/` directory, and installs them to your Pager's themes directory (`/mmc/root/themes`).

## Requirements

- Internet connection (to access GitHub API and download PR archives)
- Required packages are automatically checked and installed if missing:
  - `curl` or `wget` (if neither exists, `curl` will be installed)
  - `git`
  - `unzip`

## Usage

1. Run the payload from the Pager interface
2. Enter the Pull Request number when prompted
3. Review the PR information (title, author) and confirm
4. Choose whether to review each file individually or skip review
5. If reviewing files, approve or skip each changed file
6. Wait for the download and installation to complete
7. Review the summary of new and updated files

## Configuration

The following variables can be modified at the top of `payload.sh`:

- `GH_ORG`: GitHub organization (default: `hak5`)
- `GH_REPO`: Repository name (default: `wifipineapplepager-themes`)
- `TARGET_DIR`: Installation directory (default: `/mmc/root/themes`)
- `TEMP_DIR`: Temporary extraction directory (default: `/tmp/pager_pr_update`)
