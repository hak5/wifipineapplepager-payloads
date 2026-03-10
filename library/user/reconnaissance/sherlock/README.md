# Sherlock

Hunt down social media accounts by username across 69 platforms — directly from your WiFi Pineapple Pager.

## Description

Inspired by the [Sherlock Project](https://github.com/sherlock-project/sherlock), this payload searches for a given username across 69 social media, gaming, development, music, and community platforms. Results stream live to the screen as each platform is checked, and all findings are saved to `/root/loot/sherlock/`.

## Platforms Covered

| Category | Platforms |
|----------|-----------|
| Social Media | Twitter/X, Instagram, TikTok, Facebook, Snapchat, Pinterest, Tumblr, Reddit, LinkedIn, Mastodon, Bluesky, Threads, Twitch, Kick, Rumble |
| Video/Stream | YouTube, Vimeo, DailyMotion, Odysee, BitChute |
| Gaming | Steam, PSN, Roblox, Chess.com, Lichess, Minecraft, itch.io |
| Dev/Tech | GitHub, GitLab, Bitbucket, HackerNews, DEV.to, Codepen, Pastebin, Stack Overflow, Keybase, npm, PyPI, Dockerhub, HackTheBox, TryHackMe |
| Music/Art | SoundCloud, Spotify, Bandcamp, Mixcloud, Last.fm, Deviantart, ArtStation, Behance, Dribbble |
| Forums | Quora, Medium, Substack, Linktree, About.me, Gravatar, ProductHunt, Kaggle |
| Messaging | Telegram, Kik |
| Security | BugCrowd, HackerOne, Infosec.exchange |
| Other | Lobste.rs, Sourcehut, Gitea, Letterboxd, Goodreads, Untappd |

## Usage

1. Navigate to **Payloads → User → Reconnaissance** on the pager
2. Select **Sherlock**
3. Enter the username to search (no `@` needed)
4. Confirm the search
5. Watch results stream live — `[+] FOUND` lines appear in green as each platform is checked
6. Dismiss the summary alert when complete
7. Results saved to `/root/loot/sherlock/<username>_<timestamp>.txt`

## Requirements

- Internet connectivity (Wi-Fi client mode or USB tether)
- `curl` (pre-installed on the pager)
- `bash` (pre-installed)

## Loot

```
/root/loot/sherlock/<username>_YYYYMMDD_HHMMSS.txt
```

Example output:
```
SHERLOCK — sinXneo — 2026-03-10 14:32:01
Platforms: 69

[+] FOUND:
  GitHub
  https://github.com/sinXneo
  Twitter/X
  https://twitter.com/sinXneo

Found: 2 / 69
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `TIMEOUT` | `6` | Per-request timeout in seconds |

## Install

```bash
scp -r sherlock/ root@<pager-ip>:/root/payloads/user/reconnaissance/
```

## Author

sinXneo
