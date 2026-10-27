# WiFi Pineapple Pager Payload Library

Officially forked collection of community-developed payloads for the WiFi Pineapple Pager.

> Note: This repository is community-maintained and may contain payloads that require review before use.

## About

This repository collects payloads (DuckyScript and Bash) and helper scripts intended to run on the Hak5 WiFi Pineapple Pager. Payloads are contributed by the community — authors are responsible for their content and functionality.

## Library layout

- library/
  - user/      — User-contributed payloads
  - alerts/    — Alert-based payloads (handshake, device detected, etc.)
  - wifi-bomb-payload/ — Beacon-bombing and AP-simulation payloads

Each payload directory should include:
- `payload.sh` or `payload.txt` — main payload script
- `README.md` — usage and configuration instructions
- any supporting files required to run the payload

## Payload format and guidelines

- DuckyScript payload files: `payload.txt`
- Bash payload files: `payload.sh` (include a `#!/bin/bash` header)
- Include metadata at the top of each payload (Title, Description, Author, Version, Category)
- Use placeholders for secrets (URLs, API keys, credentials) — do not include private data
- Do not rely on this repository as a CDN for staged payloads. Provide instructions for hosting staged files separately.

Example DuckyScript header:

```
# Title: Example payload
# Description: Short description
# Author: Your Name
# Version: 1.0
# Category: Example
```

Example bash header:

```bash
#!/bin/bash
# Title: Example Bash Payload
# Description: Demonstrates bash payload structure
# Author: Your Name
# Version: 1.0
```

## Contributing

Contributions are welcome via pull requests. When submitting a payload:
- Put each payload in its own directory with a clear name (use `-` or `_`, avoid spaces)
- Include a README.md describing usage, configuration, and dependencies
- Ensure payloads are non-destructive and intended only for authorized testing

## Legal and Disclaimer

These payloads are provided for educational and authorized security testing purposes only. Users must ensure compliance with all local laws and obtain explicit permission before testing networks or devices.

The authors and repository maintainers are not responsible for misuse.

## License

See LICENSE file in the repository (or include a license in your pull request). If no license is present, treat the content as "all rights reserved" by the original author.

## Contact / Resources

- WiFi Pineapple Docs: https://docs.hak5.org/
- DuckyScript reference: https://docs.hak5.org/hc/en-us/articles/16949632408340-DuckyScript-3-0-Command-Reference

