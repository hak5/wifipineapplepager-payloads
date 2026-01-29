#!/bin/sh

CACHE_FILE="/tmp/nautilus_cache.json"
TMP="/tmp/nautilus_cache.$$.tmp"

# Resource types and their paths
RESOURCE_TYPES="payloads alerts recon"
PAYLOAD_ROOTS="/root/payloads/user /root/payloads/alerts /root/payloads/recon"

# Function to scan a directory and output JSON for that resource type
scan_resource() {
    local root="$1"
    local resource_type="$2"
    
    [ ! -d "$root" ] && { echo "{}"; return; }
    
    find "$root" -path "*/DISABLED.*" -prune -o \
         -path "*/.git" -prune -o \
         -path "*/nautilus/*" -prune -o \
         -name "payload.sh" -print 2>/dev/null | \
    awk -v restype="$resource_type" '
    BEGIN { ORS="" }
    {
        file = $0
        n = split(file, parts, "/")
        if (n < 3) next
        category = parts[n-2]
        pname = parts[n-1]

        if (pname ~ /^DISABLED\./ || pname == "PLACEHOLDER" || pname == "nautilus") next

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

        if (title == "") title = pname

        gsub(/[\t\r\n]/, " ", title); gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)
        gsub(/[\t\r\n]/, " ", desc); gsub(/\\/, "\\\\", desc); gsub(/"/, "\\\"", desc)
        gsub(/[\t\r\n]/, " ", author); gsub(/\\/, "\\\\", author); gsub(/"/, "\\\"", author)

        entry = "{\"name\":\"" title "\",\"desc\":\"" desc "\",\"author\":\"" author "\",\"path\":\"" file "\"}"
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
    scan_resource "/root/payloads/user" "payloads"
    echo -n ',"alerts":'
    scan_resource "/root/payloads/alerts" "alerts"
    echo -n ',"recon":'
    scan_resource "/root/payloads/recon" "recon"
    echo -n '}'
} > "$TMP"

mv "$TMP" "$CACHE_FILE"

