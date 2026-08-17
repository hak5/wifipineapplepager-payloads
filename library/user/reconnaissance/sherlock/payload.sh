#!/bin/bash

# Title: Sherlock
# Description: Hunt down social media accounts by username across 80+ platforms
# Author: sinXneo
# Version: 1.6
# Category: user

LOOT_DIR="/root/loot/sherlock"
TIMEOUT=6

SITES=(
  "Twitter/X|https://twitter.com/{user}|status|200"
  "Instagram|https://www.instagram.com/{user}/|msg|Sorry, this page"
  "TikTok|https://www.tiktok.com/@{user}|msg|couldn't find this account"
  "Facebook|https://www.facebook.com/{user}|msg|Page Not Found"
  "Snapchat|https://www.snapchat.com/add/{user}|msg|Sorry, we couldn't find"
  "Pinterest|https://www.pinterest.com/{user}/|msg|isn't available"
  "Tumblr|https://{user}.tumblr.com/|msg|There's nothing here"
  "Reddit|https://www.reddit.com/user/{user}|msg|Sorry, nobody on Reddit"
  "LinkedIn|https://www.linkedin.com/in/{user}/|msg|Page not found"
  "Mastodon|https://mastodon.social/@{user}|status|200"
  "Bluesky|https://bsky.app/profile/{user}|msg|Profile not found"
  "Threads|https://www.threads.net/@{user}|msg|Page Not Found"
  "Twitch|https://www.twitch.tv/{user}|msg|Sorry. Unless you've got a time machine"
  "Kick|https://kick.com/{user}|msg|NOT_FOUND"
  "Rumble|https://rumble.com/user/{user}|msg|not found"
  "YouTube|https://www.youtube.com/@{user}|msg|404 Not Found"
  "Vimeo|https://vimeo.com/{user}|msg|Sorry, we couldn't find"
  "DailyMotion|https://www.dailymotion.com/{user}|msg|Page not found"
  "Odysee|https://odysee.com/@{user}|msg|404"
  "BitChute|https://www.bitchute.com/channel/{user}/|msg|404"
  "Steam|https://steamcommunity.com/id/{user}|msg|The specified profile could not be found"
  "PSN|https://psnprofiles.com/{user}|msg|An error occurred"
  "Roblox|https://www.roblox.com/user.aspx?username={user}|msg|Page cannot be found"
  "Chess.com|https://www.chess.com/member/{user}|msg|Oops! We Couldn't Find"
  "Lichess|https://lichess.org/@/{user}|msg|Error 404"
  "Minecraft|https://api.mojang.com/users/profiles/minecraft/{user}|msg|Couldn't find"
  "itch.io|https://{user}.itch.io/|msg|is not a user or organization"
  "GitHub|https://github.com/{user}|status|200"
  "GitLab|https://gitlab.com/{user}|msg|The page you're looking for could not be found"
  "Bitbucket|https://bitbucket.org/{user}/|msg|Page Not Found"
  "HackerNews|https://news.ycombinator.com/user?id={user}|msg|No such user"
  "DEV.to|https://dev.to/{user}|msg|not found"
  "Codepen|https://codepen.io/{user}|msg|Page Not Found"
  "Pastebin|https://pastebin.com/u/{user}|msg|We can't find this Pastebin"
  "Stack Overflow|https://stackoverflow.com/users/{user}|url|stackoverflow.com/users"
  "Keybase|https://keybase.io/{user}|msg|Not a Keybase user"
  "npm|https://www.npmjs.com/~{user}|msg|Cannot find user"
  "PyPI|https://pypi.org/user/{user}/|msg|404"
  "Dockerhub|https://hub.docker.com/u/{user}/|msg|Page Not Found"
  "HackTheBox|https://www.hackthebox.com/profile/{user}|msg|Not Found"
  "TryHackMe|https://tryhackme.com/p/{user}|msg|Not Found"
  "SoundCloud|https://soundcloud.com/{user}|msg|does not seem to exist"
  "Spotify|https://open.spotify.com/user/{user}|msg|Page not found"
  "Bandcamp|https://{user}.bandcamp.com/|msg|Sorry, that something"
  "Mixcloud|https://www.mixcloud.com/{user}/|msg|Page Not Found"
  "Last.fm|https://www.last.fm/user/{user}|msg|Sorry, this user"
  "Deviantart|https://www.deviantart.com/{user}|msg|not found"
  "ArtStation|https://www.artstation.com/{user}|msg|page does not exist"
  "Behance|https://www.behance.net/{user}|msg|Page Not Found"
  "Dribbble|https://dribbble.com/{user}|msg|Whoops, that page is gone"
  "Quora|https://www.quora.com/profile/{user}|msg|doesn't exist"
  "Medium|https://medium.com/@{user}|msg|Page not found"
  "Substack|https://{user}.substack.com|msg|404"
  "Linktree|https://linktr.ee/{user}|msg|Page not found"
  "About.me|https://about.me/{user}|msg|Page not found"
  "Gravatar|https://en.gravatar.com/{user}|msg|Sorry, we couldn't find"
  "ProductHunt|https://www.producthunt.com/@{user}|msg|Not Found"
  "Kaggle|https://www.kaggle.com/{user}|msg|Not Found"
  "Telegram|https://t.me/{user}|msg|If you have Telegram"
  "Kik|https://ws2.kik.com/user/{user}|msg|not found"
  "BugCrowd|https://bugcrowd.com/{user}|msg|Page Not Found"
  "HackerOne|https://hackerone.com/{user}|msg|Page Not Found"
  "Infosec.exchange|https://infosec.exchange/@{user}|status|200"
  "Lobste.rs|https://lobste.rs/u/{user}|msg|User not found"
  "Sourcehut|https://sr.ht/~{user}/|msg|Not Found"
  "Gitea|https://gitea.com/{user}|msg|The page you are looking for"
  "Letterboxd|https://letterboxd.com/{user}/|msg|Sorry, we can't find"
  "Goodreads|https://www.goodreads.com/{user}|msg|Page not found"
  "Untappd|https://untappd.com/user/{user}|msg|We couldn't find"
)

# ─── Input ─────────────────────────────────────────────────────────────────

USERNAME=$(TEXT_PICKER "Sherlock: enter username" "")
[[ -z "$USERNAME" ]] && { ERROR_DIALOG "No username entered."; exit 1; }
USERNAME="${USERNAME#@}"

if ! echo "$USERNAME" | grep -qE '^[a-zA-Z0-9._-]{1,50}$'; then
    ERROR_DIALOG "Invalid: letters, numbers, . - _ only"
    exit 1
fi

TOTAL=${#SITES[@]}
CONFIRMATION_DIALOG "Search '$USERNAME' across $TOTAL platforms?" || exit 0

mkdir -p "$LOOT_DIR"
LOOT_FILE="$LOOT_DIR/${USERNAME}_$(date '+%Y%m%d_%H%M%S').txt"

# ─── Search ────────────────────────────────────────────────────────────────
# No spinner — LOG streams results live to screen as each site is checked.
# Loot file is written in parallel during the loop.

{
    echo "SHERLOCK — $USERNAME — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Platforms: $TOTAL"
    echo ""
    echo "[+] FOUND:"
} > "$LOOT_FILE"

LOG "Sherlock: scanning $USERNAME across $TOTAL platforms..."
LOG "─────────────────────────────────"

FOUND=0
IDX=0

for entry in "${SITES[@]}"; do
    IFS='|' read -r display url_tmpl check_type check_val <<< "$entry"
    url="${url_tmpl/\{user\}/$USERNAME}"
    IDX=$((IDX + 1))

    LOG "[$IDX/$TOTAL] $display"

    hit=0
    case "$check_type" in
        status)
            code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 4 --max-time "$TIMEOUT" \
                -L --max-redirs 2 \
                -A "Mozilla/5.0" \
                "$url" 2>/dev/null)
            [[ "$code" == "200" ]] && hit=1
            ;;
        msg)
            body=$(curl -s --connect-timeout 4 --max-time "$TIMEOUT" \
                -L --max-redirs 2 \
                -A "Mozilla/5.0" \
                "$url" 2>/dev/null)
            if [[ -n "$body" ]] && ! echo "$body" | grep -qi "$check_val"; then
                hit=1
            fi
            ;;
        url)
            final=$(curl -s -o /dev/null -w "%{url_effective}" \
                --connect-timeout 4 --max-time "$TIMEOUT" \
                -L --max-redirs 4 \
                -A "Mozilla/5.0" \
                "$url" 2>/dev/null)
            echo "$final" | grep -qi "$check_val" && hit=1
            ;;
    esac

    if [[ $hit -eq 1 ]]; then
        LOG green "[+] FOUND: $display"
        LOG green "    $url"
        echo "  $display" >> "$LOOT_FILE"
        echo "  $url"     >> "$LOOT_FILE"
        FOUND=$((FOUND + 1))
    fi
done

# ─── Summary ───────────────────────────────────────────────────────────────

{
    echo ""
    echo "Found: $FOUND / $TOTAL"
} >> "$LOOT_FILE"

LOG "─────────────────────────────────"
LOG "Done: $FOUND found / $TOTAL checked"
LOG "Saved: $LOOT_FILE"

if [[ $FOUND -gt 0 ]]; then
    ALERT "Found $FOUND accounts for $USERNAME"
else
    ALERT "No accounts found for $USERNAME"
fi

exit 0
