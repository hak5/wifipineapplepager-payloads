# Changelog

All notable changes to Nautilus will be documented in this file.

## [1.8.5] - 2026-02-05

### Fixed

- **Ringtone Install from Merged/PRs**: Fixed "Install Locally" button for ringtones - now properly accepts `wifipineapplepager-ringtones` repo URLs and installs `.rtttl` files to `/root/ringtones/`
- **PR Ringtone Validation**: Fixed PR file validation that was rejecting ringtone PRs with "No .rtttl files found" error
- **PR Cache by Resource Type**: PR file cache now includes resource type in key, preventing stale cache when switching between Payloads/Themes/Ringtones tabs
- **Theme PR Support**: Added proper file filtering and name extraction for theme PRs (`theme.json`)
- **Install Connection Timeout**: Added heartbeat messages during Git operations and payload downloads to prevent browser EventSource timeout ("Install connection lost" error)
- **Orphaned Git Processes**: Git processes and background tasks are now properly killed when install fails or is cancelled
- **uhttpd Timeout Fix**: Added TCP socket timeout (`-t 300`) and CGI script timeout (`-T 300`) to uhttpd in both `nautilus.init` and `payload.sh` to support large payload installs (>60s)

## [1.8.4] - 2026-02-05

### Added

- **Loot Browser**: New resource type for browsing `/root/loot/` files
  - Live scanning - no refresh needed, files load instantly when switching to Loot tab
  - Download individual files or all loot as ZIP archive **(Broken for now)**
  - View file contents directly in console
  - Delete loot files
  - Full subdirectory path shown as categories
- **Live Resource Scanning**: Payloads, Themes, and Ringtones now scan locally in real-time (like Loot), eliminating the need for manual refreshes and preventing stale file lists after installation or deletion.

### Fixed

**Thank you A.I. Gemini/Claude for the help with the theme installation and performance issues.**
- **Theme Install from Merged**: Fixed "Locally Install" button for themes from Merged tab - now properly accepts `wifipineapplepager-themes` repo URLs and installs to `/root/themes/`
- **Theme Installation Performance**: Switched theme installation to use **Git Sparse Checkout** (downloading only specific files) instead of full repo tarballs, fixing OOM freezes.
- **Theme Deletion**: Fixed "Delete" action for local themes not working (now correctly identifies and removes the theme directory)

## [1.8.3] - 2026-01-30

### Added

- **Play Ringtone**: Button changes to "Play Ringtone" for ringtones resource type
- **Ringtone Execution**: Executes `RINGTONE <path>` command for `.rtttl` files from Local, Merged, and PRs

## [1.8.2] - 2026-01-30

### Fixed

- **Themes/Ringtones MERGED Tab**: Fixed GitHub repo structure detection (`themes/<name>/theme.json` and `ringtones/<name>.rtttl`)
- **Dynamic Branch Selection**: Added per-resource branch config for GitHub API calls
- **404 Error Handling**: Improved error message when GitHub repo doesn't exist

## [1.8.1] - 2026-01-30

### Fixed

- **Disabled Alerts/Payloads**: Items with `DISABLED.` prefix now appear in Local tab with visual indication (grayed out with "DISABLED" badge)

## [1.8.0] - 2026-01-30

### Added

- **Themes Support**: New resource type for browsing and managing pager themes
  - Scans `/root/themes/` for local themes (looks for `theme.json`)
  - Fetches from `hak5/wifipineapplepager-themes` GitHub repo for Merged/PRs
  - Parses theme metadata (name, description, author) from `theme.json`
- **Ringtones Support**: New resource type for browsing RTTTL ringtones
  - Scans `/root/ringtones/` for local `.rtttl` files
  - Fetches from `hak5/wifipineapplepager-ringtones` GitHub repo for Merged/PRs
  - Extracts ringtone name from RTTTL format
- **Dynamic Repository Selection**: Each resource type now fetches from its own GitHub repository
- **Per-resource Caching**: Separate localStorage cache for each resource type's Merged and PR data

### Changed

- `build_cache.sh`: Added `scan_themes()` and `scan_ringtones()` functions for new resource types
- `api.sh`: Updated path validation to allow `/root/themes/` and `/root/ringtones/`
- `index.html`: Added Themes and Ringtones tabs in resource selector row
- Resource paths updated: `RESOURCE_REPOS` and `RESOURCE_PATHS` now include themes and ringtones

## [1.7.1] - 2026-01-30

### Added

- **Origin Proxy (`proxy.py`)**: Python TCP proxy on port 8890 that rewrites WebSocket `Origin` header to bypass Cross-Origin restrictions when connecting to the Pineapple API (port 1471).
- **Auth Token Passthrough**: `api.sh` now proxies login to port 1471 and returns auth token, allowing Nautilus to set the required cookie.
- **Python 3 Requirement**: Nautilus now requires Python 3 to run. Payloads will prompt to install python3 if not found.

### Fixed

- **Error Overlay**: Fixed "Lost connection" message appearing on top of working pager. Switched from `hidden` attribute to `display: none/flex` for consistent visibility control.
- **Layout Gaps**: Fixed sliced-image table layout gaps by resetting padding/font-size on cells.
- **Pager Scaling**: Fixed pager scaling to use `transform: scale()` instead of `width` property, preserving aspect ratio and preventing layout shifts.

## [1.7.0] - 2026-01-30

### Added

- **Virtual Pager Integration**: Integrated the Virtual Pager UI into Nautilus.
  - Adds a "Toggle Pager" button in the shell header.
  - Displays the live pager screen above the terminal.
  - Supports virtual button inputs (D-pad, A, B).
- **Responsive Pager Dashboard**: The Virtual Pager automatically scales to fit available width while maintaining pixel-perfect layout.

### Fixed

- **Pager Connection**: Fixed WebSocket connection logic to use the browser's hostname and explicit port 1471, ensuring connection to the main Pineapple API instead of the payload's local uhttpd instance.


## [1.6.1] - 2025-01-29

### Added

- **Resizable Panels**: Drag-to-resize handles between all major UI sections
  - Sidebar ↔ Main area (200-500px)
  - Detail panel ↔ Console/Shell area (250-600px)
  - Console panel ↔ Shell panel (min 200px)
- **Persistent Layout**: Panel sizes saved to localStorage, restored on reload
- **Visual Feedback**: Resize handles highlight on hover and during drag

## [1.6.0] - 2025-01-29

### Added

- **Resource Type Selector**: New top-level navigation to switch between Payloads, Alerts, and Recon
  - Payloads: User payloads from `/root/payloads/user/`
  - Alerts: Alert handlers from `/root/payloads/alerts/`
  - Recon: Recon modules from `/root/payloads/recon/`
- **Multi-resource cache**: Cache builder now scans all three resource directories
- **Dynamic GitHub paths**: Merged tab fetches from corresponding GitHub paths (`library/user`, `library/alerts`, `library/recon`)
- **Separate cache per resource type**: Each resource type has its own localStorage cache for GitHub data

### Changed

- `build_cache.sh`: Now outputs nested JSON structure with all resource types
- `index.html`: Updated UI with resource selector row and dynamic labels
- Local/Merged/PRs tabs now respect the selected resource type

### Technical Details

- New cache structure: `{"payloads":{...},"alerts":{...},"recon":{...}}`
- Backward compatible with old flat cache format
- Resource paths: `RESOURCE_PATHS={payloads:'library/user',alerts:'library/alerts',recon:'library/recon'}`
