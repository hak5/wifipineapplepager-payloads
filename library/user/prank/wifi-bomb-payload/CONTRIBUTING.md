# Contributing to Wi-Fi Beacon Bomb

Thank you for your interest in improving this project.

This repository is intended for educational, defensive, and authorized security testing use only. Contributions should preserve that purpose and avoid enabling misuse or harmful disruption of real networks.

## Code of Conduct

- Be respectful, constructive, and collaborative.
- Keep discussions focused on technical quality, safety, and project goals.
- Do not propose or encourage unauthorized attacks, credential theft, or network disruption.
- Assume good intent and prioritize security-conscious improvements.

## Scope of Contributions

We welcome contributions that improve:

- code clarity and maintainability
- safety checks and validation
- documentation and examples
- usability for authorized wireless testing environments
- compatibility with supported Linux/macOS setups

We do not accept changes that:

- target unrelated or malicious network activity
- remove the safety disclaimer or ethical guardrails
- add hidden behavior that increases abuse potential
- bypass the project’s educational and authorized testing intent

## Project Goals

This project demonstrates how beacon frames can be generated and broadcast in a controlled environment for educational purposes. Contributions should keep the code readable, explicit, and safe for legitimate wireless testing scenarios.

## Before You Start

1. Fork the repository.
2. Create a feature branch with a clear name, for example:
   - `fix/interface-config`
   - `docs/contributor-guide`
   - `feat/ssid-randomization`
3. Keep changes focused and avoid unrelated edits.

## Development Workflow

### Local setup

Use a Python environment with Scapy installed:

```bash
python -m pip install scapy
```

Then validate the script syntax:

```bash
python -m py_compile core/core.py
```

### Running the project

The script currently targets a wireless interface such as `wlan0mon` and sends beacon frames in a continuous loop.

Before running it:

- use an interface that is explicitly authorized for testing
- ensure you have permission to test on the target environment
- confirm the network is yours or explicitly approved for testing

## Pull Request Guidelines

When opening a pull request, please:

- keep the patch small and easy to review
- explain the motivation and expected behavior
- list any testing performed
- mention any environment assumptions or prerequisites
- avoid unrelated formatting-only changes

A good PR description typically includes:

- summary of the change
- reason for the change
- testing steps or validation results
- any caveats or follow-up work

## Issue Reporting

Open an issue if you find:

- a bug or crash
- a compatibility issue
- missing documentation
- an improvement opportunity
- an unsafe or unclear design decision

Please include:

- a clear description of the problem
- steps to reproduce it
- expected vs. actual behavior
- relevant environment details, such as OS and interface name

## Safety and Ethics

By contributing, you agree to uphold the project’s responsible-use standards:

- operate only in authorized environments
- avoid disruptive or malicious activity
- prioritize defensive, educational, and testing use cases
- document limitations and responsibilities clearly

If a contribution could reasonably be used for unauthorized or harmful network interference, it should not be merged.

## Final Note

We appreciate thoughtful, security-aware contributions that improve clarity, safety, and reliability. Keep the project educational, transparent, and respectful of the boundaries of legitimate testing.
