# Changelog

All notable changes to Nautilus will be documented in this file.

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
