#!/bin/bash
# Title: Theme Switcher
# Author: h4d35x0
# Description: Browse installed themes, preview their images on screen, and activate one. Can also preview the images in a theme pull request.
# Category: general
# Version: 1.3
#
# shellcheck disable=SC2181
# Each picker result is assigned on its own line (after `local`), so `$?` is the
# picker's exit status: non-zero means the user backed out.

THEMES_DIR="/mmc/root/themes"
CACHE_THEMES_DIR="/mmc/root/pager_update_cache/UpdateThemes/themes"
TMP_PREVIEW="/tmp/h4d35x0_theme_preview"
GH_REPO="hak5/wifipineapplepager-themes"

cleanup() {
    rm -rf "$TMP_PREVIEW"
}
trap cleanup EXIT

get_fw_ver() {
    local tjson="$1/theme.json"
    if [ -f "$tjson" ]; then
        sed -n 's/.*"theme_framework_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tjson" | head -n 1
    else
        echo "?"
    fi
}

get_author() {
    local tjson="$1/theme.json"
    if [ -f "$tjson" ]; then
        sed -n 's/.*"author"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tjson" | head -n 1
    fi
}

collect_preview_pngs() {
    local tdir="$1"
    local list_file="$2"
    : > "$list_file"

    # 1. Explicit preview / screenshot PNGs in root of theme
    find "$tdir" -maxdepth 1 -type f \( -iname "*preview*.png" -o -iname "*screen*.png" -o -iname "*.png" \) 2>/dev/null | sort >> "$list_file"

    # 2. Dashboard background resolved from theme.json -> dashboard_path -> image_path
    if [ -f "$tdir/theme.json" ]; then
        local dash_comp
        dash_comp=$(sed -n 's/.*"dashboard_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tdir/theme.json" | head -n 1)
        if [ -n "$dash_comp" ] && [ -f "$tdir/$dash_comp" ]; then
            local bg_rel
            bg_rel=$(sed -n 's/.*"image_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tdir/$dash_comp" | head -n 1)
            if [ -n "$bg_rel" ] && [ -f "$tdir/$bg_rel" ]; then
                echo "$tdir/$bg_rel" >> "$list_file"
            fi
        fi
    fi

    # 3. Standard dashboard / settings / recon / boot splash backgrounds
    for candidate in \
        "$tdir/assets/dashboard/dashboard_bg.png" \
        "$tdir/assets/dashboard/wargames_bg_updated.png" \
        "$tdir/assets/dashboard/wargames_bg.png" \
        "$tdir/assets/settings_bg.png" \
        "$tdir/assets/recon/recon_list_bg.png" \
        "$tdir/assets/boot_animation/init-1.png" \
        "$tdir/assets/boot_animation/init-4.png" \
        "$tdir/assets/pager-16bit.png"; do
        [ -f "$candidate" ] && echo "$candidate" >> "$list_file"
    done

    # Deduplicate while preserving order
    awk '!seen[$0]++' "$list_file" > "${list_file}.dedup" && mv "${list_file}.dedup" "$list_file"
}

show_theme_images() {
    local tdir="$1"
    local tname="$2"
    mkdir -p "$TMP_PREVIEW"
    local img_list="$TMP_PREVIEW/imgs.txt"
    collect_preview_pngs "$tdir" "$img_list"

    local total
    total=$(wc -l < "$img_list" 2>/dev/null | tr -d ' ')
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
        PROMPT "No preview PNGs found in $tname"
        return
    fi

    local idx=1
    while IFS= read -r img; do
        [ -f "$img" ] || continue
        LOG "[$idx/$total] $tname: $(basename "$img")"
        PROMPT_IMAGE "$img"
        idx=$((idx + 1))
    done < "$img_list"
}

show_theme_info() {
    local tdir="$1"
    local tname="$2"
    local fw author desc=""
    fw=$(get_fw_ver "$tdir")
    author=$(get_author "$tdir")
    [ -z "$author" ] && author="Unknown / Community"

    local rfile
    rfile=$(find "$tdir" -maxdepth 1 -type f -iname "readme*" 2>/dev/null | head -n 1)
    if [ -n "$rfile" ]; then
        desc=$(grep -v '^#' "$rfile" | grep -v '^!\[' | tr '\r\n' '  ' | sed 's/  */ /g' | cut -c1-180)
    fi

    PROMPT "Theme: $tname | Author: $author | Framework: $fw | $desc"
}

ensure_theme_complete() {
    local tdir="$1"
    local rom_theme="/rom/lib/pager/themes/wargames"
    [ -d "$tdir" ] && [ -f "$tdir/theme.json" ] && [ -d "$rom_theme" ] || return

    # Three passes: a component copied in on one pass can reference assets that
    # only get picked up on the next.
    # Paths come from the theme's own JSON, so any path with a ".." segment is
    # skipped: it could otherwise make cp write outside the theme directory.
    local rel
    for _ in 1 2 3; do
        for rel in $(grep -o '"[^"]*\.\(json\|png\)"' "$tdir/theme.json" 2>/dev/null | tr -d '"' | sort -u); do
            case "$rel" in
                ..|../*|*/..|*/../*)
                    ;;
                components/*|assets/*)
                    if [ ! -f "$tdir/$rel" ] && [ -f "$rom_theme/$rel" ]; then
                        mkdir -p "$(dirname "$tdir/$rel")"
                        cp -f "$rom_theme/$rel" "$tdir/$rel"
                    fi
                    ;;
            esac
        done
        if [ -d "$tdir/components" ]; then
            for rel in $(find "$tdir/components" -type f -name "*.json" -exec grep -h -o '"[^"]*\.\(png\|json\)"' {} + 2>/dev/null | tr -d '"' | sort -u); do
                case "$rel" in
                    ..|../*|*/..|*/../*)
                        ;;
                    components/*|assets/*)
                        if [ ! -f "$tdir/$rel" ] && [ -f "$rom_theme/$rel" ]; then
                            mkdir -p "$(dirname "$tdir/$rel")"
                            cp -f "$rom_theme/$rel" "$tdir/$rel"
                        fi
                    ;;
                esac
            done
        fi
    done
}

apply_theme() {
    local tname="$1"
    local resp
    resp=$(CONFIRMATION_DIALOG "Activate theme '$tname' now? (restarts UI)")
    [ "$resp" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ] || return

    ensure_theme_complete "$THEMES_DIR/$tname"

    uci set "system.@pager[0].theme_name=$tname"
    uci set "system.@pager[0].theme_path=/root/themes/$tname"
    uci commit system
    rm -f /tmp/uierrors.log
    LOG green "Activating theme: $tname..."

    # Play a short, pleasant octave-4 reboot chime (C4 -> E4 -> G4), wait for it to finish, then silence the PWM buzzer
    RINGTONE "Reboot:d=16,o=4,b=160:c,e,8g,4p" >/dev/null 2>&1
    sleep 1
    echo 0 > /sys/class/leds/buzzer/brightness 2>/dev/null
    echo 0 > /sys/class/leds/buzzer/volume 2>/dev/null
    echo 0 > /sys/devices/platform/10000000.palmbus/10000600.gpio/gpiochip1/gpio/vibrator/value 2>/dev/null

    # Restart pineapplepager in a detached background subshell and keep buzzer silent during teardown.
    # Sleep in the foreground so pineapplepager is stopped before payload.sh exits (preventing a mid-restart payload_complete tone from latching the PWM buzzer).
    (
        echo 0 > /sys/class/leds/buzzer/brightness 2>/dev/null
        echo 0 > /sys/class/leds/buzzer/volume 2>/dev/null
        service pineapplepager restart >/dev/null 2>&1
        echo 0 > /sys/class/leds/buzzer/brightness 2>/dev/null
        echo 0 > /sys/class/leds/buzzer/volume 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    sleep 10
    exit 0
}

theme_action_menu() {
    local tdir="$1"
    local tname="$2"
    local is_installed="$3"
    local fw author
    fw=$(get_fw_ver "$tdir")
    author=$(get_author "$tdir")

    while true; do
        local choice
        if [ "$is_installed" = "1" ]; then
            choice=$(LIST_PICKER "$tname (fw $fw)" \
                "Preview Images on Screen" \
                "Theme Info / README" \
                "Activate This Theme" \
                "<- Back" \
                "Preview Images on Screen")
        else
            choice=$(LIST_PICKER "$tname (fw $fw)" \
                "Preview Images on Screen" \
                "Theme Info / README" \
                "Install to /root/themes" \
                "<- Back" \
                "Preview Images on Screen")
        fi
        [ $? -eq 0 ] || return

        case "$choice" in
            "Preview Images on Screen")
                show_theme_images "$tdir" "$tname"
                ;;
            "Theme Info / README")
                show_theme_info "$tdir" "$tname"
                ;;
            "Activate This Theme")
                apply_theme "$tname"
                ;;
            "Install to /root/themes")
                # Copy the theme's contents, not the directory itself, so an existing
                # $THEMES_DIR/$tname is updated in place instead of nested inside.
                if ! mkdir -p "$THEMES_DIR/$tname" || ! cp -rf "$tdir/." "$THEMES_DIR/$tname/"; then
                    ERROR_DIALOG "Install of '$tname' failed (check free space on /mmc)"
                    continue
                fi
                LOG green "Installed $tname to $THEMES_DIR/$tname"
                PROMPT "Installed '$tname'! You can now activate it."
                is_installed="1"
                tdir="$THEMES_DIR/$tname"
                ;;
            "<- Back"|*)
                return
                ;;
        esac
    done
}

browse_themes() {
    local filter_fw="$1"
    local base_dir="$2"

    while true; do
        local items=()
        local first_item=""
        for d in "$base_dir"/*; do
            [ -d "$d" ] || continue
            [ -f "$d/theme.json" ] || continue
            local name fw
            name=$(basename "$d")
            fw=$(get_fw_ver "$d")
            if [ -n "$filter_fw" ] && [ "$fw" != "$filter_fw" ]; then
                continue
            fi
            local label="$name [fw $fw]"
            items+=("$label")
            [ -z "$first_item" ] && first_item="$label"
        done

        if [ "${#items[@]}" -eq 0 ]; then
            PROMPT "No matching themes found."
            return
        fi

        items+=("<- Back")
        local sel
        sel=$(LIST_PICKER "Select Theme (${#items[@]} items)" "${items[@]}" "$first_item")
        [ $? -eq 0 ] || return
        [ "$sel" = "<- Back" ] || [ -z "$sel" ] && return

        local chosen_name="${sel% \[fw *}"
        local is_inst="1"
        [ "$base_dir" != "$THEMES_DIR" ] && [ ! -d "$THEMES_DIR/$chosen_name" ] && is_inst="0"
        theme_action_menu "$base_dir/$chosen_name" "$chosen_name" "$is_inst"
    done
}

preview_github_pr() {
    local pr
    pr=$(NUMBER_PICKER "GitHub Theme PR #?" 1)
    [ $? -eq 0 ] || return
    [ -n "$pr" ] && [ "$pr" -gt 0 ] 2>/dev/null || return

    mkdir -p "$TMP_PREVIEW/pr_$pr"
    local sp
    sp=$(START_SPINNER "Fetching PR #$pr files...")
    local api_out="$TMP_PREVIEW/pr_${pr}.json"
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$GH_REPO/pulls/$pr/files?per_page=100" -o "$api_out" 2>/dev/null; then
        STOP_SPINNER "$sp"
        ERROR_DIALOG "Could not fetch PR #$pr (check Wi-Fi client internet)"
        return
    fi

    local png_urls
    png_urls=$(grep -o '"raw_url"[[:space:]]*:[[:space:]]*"[^"]*\.png"' "$api_out" | sed 's/.*"raw_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -n 6)
    if [ -z "$png_urls" ]; then
        STOP_SPINNER "$sp"
        PROMPT "PR #$pr has no PNG files to preview."
        return
    fi

    local i=1
    for u in $png_urls; do
        curl -fsSL --connect-timeout 10 --max-time 20 "$u" -o "$TMP_PREVIEW/pr_$pr/img_${i}.png" 2>/dev/null
        i=$((i + 1))
    done
    STOP_SPINNER "$sp"

    for f in "$TMP_PREVIEW/pr_$pr"/img_*.png; do
        [ -s "$f" ] || continue
        PROMPT_IMAGE "$f"
    done

    local pull_pr="/mmc/root/payloads/user/general/PullThemePR/payload.sh"
    if [ ! -x "$pull_pr" ]; then
        PROMPT "To install PR themes, install the PullThemePR payload."
        return
    fi
    local resp
    resp=$(CONFIRMATION_DIALOG "Install theme from PR #$pr now via PullThemePR?")
    if [ "$resp" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
        "$pull_pr"
    fi
}

main_menu() {
    while true; do
        local cur_theme
        cur_theme=$(uci get system.@pager[0].theme_name 2>/dev/null || echo "wargames")
        local choice
        choice=$(LIST_PICKER "Theme Switcher (Active: $cur_theme)" \
            "Browse 2.0.0 Themes (fw 0.9)" \
            "Browse All Installed Themes" \
            "Preview Uninstalled Cache Themes" \
            "Preview GitHub PR # (Online)" \
            "Exit" \
            "Browse 2.0.0 Themes (fw 0.9)")
        [ $? -eq 0 ] || exit 0

        case "$choice" in
            "Browse 2.0.0 Themes (fw 0.9)")
                browse_themes "0.9" "$THEMES_DIR"
                ;;
            "Browse All Installed Themes")
                browse_themes "" "$THEMES_DIR"
                ;;
            "Preview Uninstalled Cache Themes")
                if [ -d "$CACHE_THEMES_DIR" ]; then
                    browse_themes "" "$CACHE_THEMES_DIR"
                else
                    PROMPT "No UpdateThemes cache directory found."
                fi
                ;;
            "Preview GitHub PR # (Online)")
                preview_github_pr
                ;;
            "Exit"|*)
                exit 0
                ;;
        esac
    done
}

main_menu
