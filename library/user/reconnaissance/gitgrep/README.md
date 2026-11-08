# GITGREP - GitHub Secret Hunter

Read-only secret hunter for the WiFi Pineapple Pager. Finds credentials that
were committed to git by mistake - on GitHub users, organisations, single
repositories, and local folders or local git history.

> Scan only repositories you own or are authorised to assess. GITGREP is
> read-only: it never writes to GitHub, never authenticates to a service with
> a key it finds, and masks every secret in the report by default.

## What it does

- **GitHub user / organisation** - enumerates public repos, downloads each
  default branch as a tarball (streamed straight into the scanner, so a large
  repo never has to fit in RAM), plus gists.
- **Single repository** - same tarball scan for one `owner/repo`, with an
  optional git history sweep that clones the repo with a partial clone and
  scans added lines in commit history.
- **Local folder** - walks a directory on the Pager and scans it.
- **Local git history** - runs `git log -p` on a local repository and scans
  added lines only (fast), attributing each finding to the commit, author and
  date that introduced it.
- **Deduplication** - the same secret found in the working tree and in an old
  commit is reported once; a secret repeated across files is still listed per
  file.
- **Reuse detection** - secrets that appear in more than one place are grouped
  at the end of the report (a strong sign of a leaked, rotated key).

### Detectors (35+)

AWS access/secret keys, GitHub PATs (classic + fine-grained), GitLab, Slack
tokens and webhooks, Discord webhooks, Stripe live/test, SendGrid, Mailgun,
Mailchimp, Google API keys, Google OAuth client secrets, GCP service accounts,
Azure storage keys, Twilio SIDs, Telegram bot tokens, npm, PyPI, OpenAI,
Anthropic, HuggingFace, DigitalOcean, Shopify, Postman, New Relic, Grafana,
Vault, age secret keys, JWTs, basic-auth URLs, PEM private keys, Firebase
URLs - plus a high-entropy generic assignment rule with placeholder filtering
so `your_api_key_here` and friends are ignored.

## Requirements

- WiFi Pineapple Pager, firmware **2.0.0-stable** or newer
- `python3-light` (the payload offers to install it)
- `curl` for GitHub scans (the engine drives curl for HTTPS, so no extra
  Python packages are needed)
- `git` + `git-http` for the optional history mode
- A GitHub personal access token is optional but strongly recommended:
  the unauthenticated API limit is 60 requests/hour. A token is stored in
  `/root/loot/gitgrep/.token` (mode 600).

## Installation

```text
/root/payloads/user/reconnaissance/gitgrep/
/mmc/root/payloads/user/reconnaissance/gitgrep/
```

Files:

```text
gitgrep/
  payload.sh    Pager UI
  gitgrep.py    scan engine
  README.md     this file
```

## Usage

1. Run **GITGREP** from the payload menu and accept the authorisation notice.
2. Pick a mode:
   - **Scan GitHub user/org** - name only, e.g. `octocat`
   - **Scan one repository** - `owner/repo` (history sweep optional)
   - **Scan a local folder**
   - **Scan local git history**
3. Pick a depth: Quick (5 repos / 3 min), Standard (30 / 15) or
   Deep (100 / 45).
4. When the scan finishes, the screen shows the counts by severity and you can
   page the top masked findings. The full report is in loot.
5. **Token / settings** lets you save or clear a GitHub token.

### Loot

`/root/loot/gitgrep/`:

| File | Contents |
| --- | --- |
| `gitgrep-<target>-<ts>.txt` | human-readable report (masked) |
| `gitgrep-<target>-<ts>.json` | full findings with hashes |
| `gitgrep-<target>-<ts>.csv` | findings for spreadsheet import |
| `gitgrep-<target>-<ts>.preview.txt` | short on-screen summary |
| `latest.*` | copy of the most recent run |
| `.token` | saved GitHub token (mode 600), if set |

The same secret may appear under several paths; the report groups these under
"REUSED SECRETS". Each finding carries a `secret_id` - the first 12 hex chars
of the SHA-1 of the raw value - so you can tell reuse apart without the secret
ever being printed.

## Command-line use

```sh
cd /root/payloads/user/reconnaissance/gitgrep

python3 gitgrep.py octocat                       # user/org (+ gists)
python3 gitgrep.py owner/repo --history          # repo + commit history
python3 gitgrep.py --local /root/repo --history  # local + history
python3 gitgrep.py octocat --show                # reveal values (careful)
python3 gitgrep.py octocat --json --loot /root/loot/gitgrep
python3 gitgrep.py --self-test                   # built-in detector tests
```

## Notes and limits

- Scanning is **read-only**. GITGREP never writes, forks, stars or issues
  against GitHub, and never tests a discovered key against its service.
- Tarball mode scans the default branch head. History mode uses a partial
  clone (`--filter=blob:none`) and `git log -p` so large repositories stay
  workable.
- Binary files, archives, images, lockfiles and `node_modules`-style
  directories are skipped.
- Unauthenticated scans are limited to 60 GitHub API requests/hour and will
  stop cleanly when the quota is exhausted.

## Uninstall

```sh
rm -rf /root/payloads/user/reconnaissance/gitgrep
rm -rf /root/loot/gitgrep
```

## Version

1.1.0 - HTTP moved from urllib to curl (the Pager's python3-light ships no
urllib), so GitHub scans now only need `python3-light` + `curl`.
1.0.0 - initial release for Pager firmware 2.0.0-stable.

## Legal

For authorised security assessment and education only. Not affiliated with
Hak5, GitHub or any detected service. Users are solely responsible for
compliance with platform terms and applicable law.
