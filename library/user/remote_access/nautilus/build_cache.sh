#!/bin/sh

CACHE_FILE="/tmp/nautilus_cache.json"
TMP="/tmp/nautilus_cache.$$.tmp"

# Resource types and their paths
RESOURCE_TYPES="payloads alerts recon themes ringtones"
PAYLOAD_ROOTS="/root/payloads/user /root/payloads/alerts /root/payloads/recon /root/themes /root/ringtones"

# Function to scan payloads (payload.sh files)
scan_payloads() {
    local root="$1"
    
    [ ! -d "$root" ] && { echo "{}"; return; }
    
    find "$root" -path "*/.git" -prune -o \
         -path "*/nautilus/*" -prune -o \
         -name "payload.sh" -print 2>/dev/null | \
    awk '
    BEGIN { ORS="" }
    {
        file = $0
        n = split(file, parts, "/")
        if (n < 3) next
        category = parts[n-2]
        pname = parts[n-1]

        if (pname == "PLACEHOLDER" || pname == "nautilus") next

        # Check if disabled (category or pname starts with DISABLED.)
        disabled = "false"
        displayName = pname
        if (category ~ /^DISABLED\./) {
            disabled = "true"
            sub(/^DISABLED\./, "", category)
        }
        if (pname ~ /^DISABLED\./) {
            disabled = "true"
            sub(/^DISABLED\./, "", displayName)
        }

        title = ""; desc = ""; author = ""
        linenum = 0
        while ((getline line < file) > 0 && linenum < 20) {
            linenum++
            if (line ~ /^# *Title:/) {
                sub(/^# *Title: */, "", line)
                title = line
            } else if (line ~ /^# *Description:/) {
                sub(/^# *Description: */, "", line)
                desc = line
            } else if (line ~ /^# *Author:/) {
                sub(/^# *Author: */, "", line)
                author = line
            }
            if (title && desc && author) break
        }
        close(file)

        if (title == "") title = displayName

        gsub(/[\t\r\n]/, " ", title); gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)
        gsub(/[\t\r\n]/, " ", desc); gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc)
        gsub(/[\t\r\n]/, " ", author); gsub(/\\/, "\\\\", author); gsub(/"/, "\\\"", author)

        entry = "{\"name\":\"" title "\",\"desc\":\"" desc "\",\"author\":\"" author "\",\"path\":\"" file "\",\"disabled\":" disabled "}"
        if (category in cats) {
            cats[category] = cats[category] "," entry
        } else {
            cats[category] = entry
            catorder[++catcount] = category
        }
    }
    END {
        printf "{"
        for (i = 1; i <= catcount; i++) {
            if (i > 1) printf ","
            printf "\"%s\":[%s]", catorder[i], cats[catorder[i]]
        }
        printf "}"
    }
    '
}

# Function to scan themes (theme.json files in subdirectories)
scan_themes() {
    local root="$1"
    
    [ ! -d "$root" ] && { echo "{}"; return; }
    
    find "$root" -maxdepth 2 -name "theme.json" -print 2>/dev/null | \
    awk '
    BEGIN { ORS="" }
    {
        file = $0
        n = split(file, parts, "/")
        if (n < 2) next
        tname = parts[n-1]

        if (tname ~ /^DISABLED\./) next

        title = tname; desc = ""; author = ""
        # Try to parse theme.json for metadata
        while ((getline line < file) > 0) {
            if (line ~ /"name"[ ]*:/) {
                gsub(/.*"name"[ ]*:[ ]*"/, "", line)
                gsub(/".*/, "", line)
                if (line != "") title = line
            } else if (line ~ /"description"[ ]*:/) {
                gsub(/.*"description"[ ]*:[ ]*"/, "", line)
                gsub(/".*/, "", line)
                desc = line
            } else if (line ~ /"author"[ ]*:/) {
                gsub(/.*"author"[ ]*:[ ]*"/, "", line)
                gsub(/".*/, "", line)
                author = line
            }
        }
        close(file)

        gsub(/[\t\r\n]/, " ", title); gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)
        gsub(/[\t\r\n]/, " ", desc); gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc)
        gsub(/[\t\r\n]/, " ", author); gsub(/\\/, "\\\\", author); gsub(/"/, "\\\"", author)

        # Use "themes" as category since themes are flat
        category = "themes"
        dirpath = file
        sub(/\/theme\.json$/, "", dirpath)
        entry = "{\"name\":\"" title "\",\"desc\":\"" desc "\",\"author\":\"" author "\",\"path\":\"" dirpath "\"}"
        if (category in cats) {
            cats[category] = cats[category] "," entry
        } else {
            cats[category] = entry
            catorder[++catcount] = category
        }
    }
    END {
        printf "{"
        for (i = 1; i <= catcount; i++) {
            if (i > 1) printf ","
            printf "\"%s\":[%s]", catorder[i], cats[catorder[i]]
        }
        printf "}"
    }
    '
}

# Function to scan ringtones (.rtttl files)
scan_ringtones() {
    local root="$1"
    
    [ ! -d "$root" ] && { echo "{}"; return; }
    
    find "$root" -maxdepth 1 -name "*.rtttl" -print 2>/dev/null | \
    awk '
    BEGIN { ORS="" }
    {
        file = $0
        n = split(file, parts, "/")
        fname = parts[n]
        # Remove .rtttl extension for name
        tname = fname
        sub(/\.rtttl$/, "", tname)

        if (tname ~ /^DISABLED\./) next

        # RTTTL format: name:d=duration,o=octave,b=bpm:notes
        # First field before colon is the name
        title = tname; desc = ""
        if ((getline line < file) > 0) {
            # Extract name from RTTTL (before first colon)
            idx = index(line, ":")
            if (idx > 0) {
                title = substr(line, 1, idx-1)
            }
        }
        close(file)

        gsub(/[\t\r\n]/, " ", title); gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)

        # Use "ringtones" as category
        category = "ringtones"
        entry = "{\"name\":\"" title "\",\"desc\":\"\",\"author\":\"\",\"path\":\"" file "\"}"
        if (category in cats) {
            cats[category] = cats[category] "," entry
        } else {
            cats[category] = entry
            catorder[++catcount] = category
        }
    }
    END {
        printf "{"
        for (i = 1; i <= catcount; i++) {
            if (i > 1) printf ","
            printf "\"%s\":[%s]", catorder[i], cats[catorder[i]]
        }
        printf "}"
    }
    '
}

# Build combined cache with all resource types
{
    echo -n '{"payloads":'
    scan_payloads "/root/payloads/user"
    echo -n ',"alerts":'
    scan_payloads "/root/payloads/alerts"
    echo -n ',"recon":'
    scan_payloads "/root/payloads/recon"
    echo -n ',"themes":'
    scan_themes "/root/themes"
    echo -n ',"ringtones":'
    scan_ringtones "/root/ringtones"
    echo -n '}'
} > "$TMP"

mv "$TMP" "$CACHE_FILE"

