
#!/bin/sh
# Title: Loot Browser
# Author: RootJunky
# Description: Modern mobile-friendly read-only loot browser
# Version: 2.0

LOOT="/root/loot"
PORT="8088"
WEBROOT="/tmp/lootbrowser"
SERVER_PID=""

# --------------------------------------------------
# Detect current interface IP addresses
# --------------------------------------------------

CLIENT_IP="$(ip -4 addr show dev wlan0cli 2>/dev/null |
    awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')"

MGMT_IP="$(ip -4 addr show dev br-lan 2>/dev/null |
    awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')"

if [ -z "$CLIENT_IP" ] && [ -z "$MGMT_IP" ]; then
    LOG "ERROR: No Client or Management IPv4 address found."
    exit 1
fi

# --------------------------------------------------
# Select interface using your requested LIST_PICKER
# --------------------------------------------------

if [ -n "$CLIENT_IP" ] && [ -n "$MGMT_IP" ]; then
    ACTION=$(LIST_PICKER "Loot Browser Interface" \
        "Client - ($CLIENT_IP)" \
        "Manage - ($MGMT_IP)" \
        "Exit payload" \
        "Client - ($CLIENT_IP)") || exit 0

elif [ -n "$CLIENT_IP" ]; then
    ACTION=$(LIST_PICKER "Loot Browser Interface" \
        "Client - ($CLIENT_IP)" \
        "Exit payload" \
        "Client - ($CLIENT_IP)") || exit 0

else
    ACTION=$(LIST_PICKER "Loot Browser Interface" \
        "Manage - ($MGMT_IP)" \
        "Exit payload" \
        "Manage - ($MGMT_IP)") || exit 0
fi

case "$ACTION" in
    "Client - ($CLIENT_IP)")
        DEVICE="wlan0cli"
        IP="$CLIENT_IP"
        ;;
    "Manage - ($MGMT_IP)")
        DEVICE="br-lan"
        IP="$MGMT_IP"
        ;;
    "Exit payload")
        LOG "Loot Browser cancelled."
        exit 0
        ;;
    *)
        LOG "ERROR: Invalid interface selection: $ACTION"
        exit 1
        ;;
esac

URL="http://$IP:$PORT/cgi-bin/loot"

LOG "Selected interface: $DEVICE"
LOG "Selected IP: $IP"

# --------------------------------------------------
# Check requirements
# --------------------------------------------------

if [ ! -d "$LOOT" ]; then
    LOG "ERROR: Loot directory not found: $LOOT"
    exit 1
fi

ROOT="$(readlink -f "$LOOT" 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$LOOT"

if ! command -v uhttpd >/dev/null 2>&1; then
    LOG "Installing uhttpd..."

    if ! opkg update || ! opkg install -d mmc uhttpd; then
        LOG "ERROR: Could not install uhttpd."
        exit 1
    fi
fi

if ! command -v uhttpd >/dev/null 2>&1; then
    LOG "ERROR: uhttpd is unavailable."
    exit 1
fi

# --------------------------------------------------
# Cleanup helpers
# Only target uhttpd instances using port 8088.
# Do not stop the Pager's normal port 80 server.
# --------------------------------------------------

stop_leftover_servers() {
    for PID in $(ps w | awk -v port=":$PORT" '
        /uhttpd/ && /-p/ && index($0, port) && !/awk/ {
            print $1
        }
    '); do
        [ -n "$PID" ] || continue
        LOG "Stopping leftover Loot Browser: $PID"
        kill -TERM "$PID" 2>/dev/null
    done

    COUNT=0
    while netstat -lnt 2>/dev/null | grep -q ":$PORT " &&
          [ "$COUNT" -lt 5 ]; do
        sleep 1
        COUNT=$((COUNT + 1))
    done

    for PID in $(ps w | awk -v port=":$PORT" '
        /uhttpd/ && /-p/ && index($0, port) && !/awk/ {
            print $1
        }
    '); do
        [ -n "$PID" ] || continue
        LOG "Force-stopping remaining Loot Browser: $PID"
        kill -KILL "$PID" 2>/dev/null
    done
}

cleanup() {
    trap - EXIT INT TERM HUP

    LOG "Stopping Loot Browser..."

    if [ -n "$SERVER_PID" ]; then
        kill -TERM "$SERVER_PID" 2>/dev/null

        COUNT=0
        while kill -0 "$SERVER_PID" 2>/dev/null &&
              [ "$COUNT" -lt 5 ]; do
            sleep 1
            COUNT=$((COUNT + 1))
        done

        if kill -0 "$SERVER_PID" 2>/dev/null; then
            LOG "Forcing Loot Browser shutdown."
            kill -KILL "$SERVER_PID" 2>/dev/null
        fi

        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=""
    fi

    stop_leftover_servers

    if netstat -lnt 2>/dev/null | grep -q ":$PORT "; then
        LOG "WARNING: Port $PORT is still listening."
    else
        LOG "Confirmed: Port $PORT is closed."
    fi

    rm -rf "$WEBROOT"
    LOG "Temporary browser files removed."
}

trap cleanup EXIT
trap 'exit 0' INT TERM HUP

stop_leftover_servers

if netstat -lnt 2>/dev/null | grep -q ":$PORT "; then
    LOG "ERROR: Port $PORT is still occupied."
    exit 1
fi

# --------------------------------------------------
# Create web root
# --------------------------------------------------

rm -rf "$WEBROOT"
mkdir -p "$WEBROOT/cgi-bin" || {
    LOG "ERROR: Could not create web directory."
    exit 1
}

cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="0;url=/cgi-bin/loot">
<title>RootJunky Loot Browser</title>
</head>
<body>
<a href="/cgi-bin/loot">Open Loot Browser</a>
</body>
</html>
HTML

# --------------------------------------------------
# CGI application
# --------------------------------------------------

cat > "$WEBROOT/cgi-bin/loot" <<'CGI'
#!/bin/sh

ROOT="$(readlink -f /root/loot 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="/root/loot"

WEBROOT="/tmp/lootbrowser"

param() {
    printf '%s\n' "$QUERY_STRING" |
        tr '&' '\n' |
        sed -n "s/^$1=//p" |
        head -n 1
}

decode() {
    uhttpd -d "$1" 2>/dev/null
}

encode() {
    printf '%s' "$1" |
        sed \
            -e 's/%/%25/g' \
            -e 's/ /%20/g' \
            -e 's/&/%26/g' \
            -e 's/#/%23/g' \
            -e 's/?/%3F/g' \
            -e 's/+/%2B/g' \
            -e 's/=/%3D/g'
}

escape_html() {
    sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&#39;/g"
}

ACTION="$(param action)"
RAW_PATH="$(param path)"
REL_PATH="$(decode "$RAW_PATH")"

# Reject traversal attempts
case "$REL_PATH" in
    /*|..|../*|*/..|*/../*|./*|*/./*)
        printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nInvalid path.'
        exit 0
        ;;
esac

if [ -n "$REL_PATH" ]; then
    REQUESTED="$ROOT/$REL_PATH"
else
    REQUESTED="$ROOT"
fi

REAL_PATH="$(readlink -f "$REQUESTED" 2>/dev/null)"

case "$REAL_PATH" in
    "$ROOT"|"$ROOT"/*) ;;
    *)
        printf 'Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nPath unavailable.'
        exit 0
        ;;
esac

if [ ! -e "$REAL_PATH" ]; then
    printf 'Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nFile or folder not found.'
    exit 0
fi

if [ "$REAL_PATH" = "$ROOT" ]; then
    CURRENT_REL=""
else
    CURRENT_REL="${REAL_PATH#"$ROOT"/}"
fi

# --------------------------------------------------
# Download handler
# --------------------------------------------------

if [ "$ACTION" = "download" ]; then
    if [ -f "$REAL_PATH" ]; then
        NAME="$(basename "$REAL_PATH" | tr -d '"\r\n')"
        printf 'Content-Type: application/octet-stream\r\n'
        printf 'Content-Disposition: attachment; filename="%s"\r\n' "$NAME"
        printf 'Cache-Control: no-store\r\n\r\n'
        cat "$REAL_PATH"
    else
        printf 'Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nNot a regular file.'
    fi
    exit 0
fi

# --------------------------------------------------
# HTML header and modern design
# --------------------------------------------------

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n\r\n'

cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>RootJunky | Loot Browser</title>

<style>
:root {
    color-scheme: dark;
    --bg: #100e18;
    --panel: #191624;
    --panel2: #211c30;
    --border: #302940;
    --purple: #a78bfa;
    --purple2: #7c3aed;
    --cyan: #67e8f9;
    --text: #f4f1fb;
    --muted: #a49bb6;
    --green: #4ade80;
}

* { box-sizing: border-box; }

body {
    margin: 0;
    background:
        radial-gradient(ellipse at top, #241735 0%, var(--bg) 48%);
    color: var(--text);
    font: 15px/1.5 system-ui, -apple-system, sans-serif;
    min-height: 100vh;
}

a { color: inherit; text-decoration: none; }

button, input { font: inherit; }

button, a, input { -webkit-tap-highlight-color: transparent; }

.container {
    width: 100%;
    max-width: 860px;
    margin: auto;
    padding: 18px 15px 32px;
}

.header {
    display: flex;
    align-items: center;
    gap: 13px;
    padding: 8px 0 22px;
}

.brand-icon {
    width: 48px;
    height: 48px;
    flex-shrink: 0;
    display: grid;
    place-items: center;
    border-radius: 15px;
    background: linear-gradient(135deg, #8b5cf6, #5b21b6);
    box-shadow: 0 5px 24px #7c3aed35;
    font-size: 25px;
}

.brand {
    font-size: 17px;
    font-weight: 850;
    letter-spacing: 1.8px;
}

.subtitle {
    font-size: 11px;
    color: var(--muted);
    letter-spacing: 2px;
}

.status {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 7px 10px;
    border: 1px solid #27513c;
    border-radius: 30px;
    background: #163126;
    color: var(--green);
    font-size: 11px;
    white-space: nowrap;
}

.dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--green);
}

.hero {
    padding: 23px 20px;
    border: 1px solid #47345f;
    border-radius: 20px;
    background: linear-gradient(135deg, #302044, #1c1829 75%);
    margin-bottom: 19px;
}

.eyebrow {
    color: var(--purple);
    font-size: 11px;
    font-weight: 750;
    letter-spacing: 1.8px;
    text-transform: uppercase;
}

.hero h1 {
    margin: 7px 0 5px;
    font-size: clamp(24px, 6vw, 31px);
    line-height: 1.2;
    letter-spacing: -.8px;
}

.hero p {
    margin: 0;
    color: #c2b8d3;
    font-size: 13px;
}

.pathbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 7px;
    margin: 20px 0 14px;
    color: var(--muted);
    font-size: 13px;
    overflow-wrap: anywhere;
}

.pathbar a { color: var(--purple); }
.pathbar a:hover { color: white; }

.toolbar {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 13px;
}

.searchbox {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: 1;
    min-width: 0;
    padding: 0 13px;
    height: 48px;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 13px;
}

.searchbox span { color: var(--muted); font-size: 19px; }

.searchbox input {
    width: 100%;
    min-width: 0;
    outline: none;
    border: 0;
    background: transparent;
    color: var(--text);
    font-size: 14px;
}

.searchbox input::placeholder { color: #827991; }

.toolbutton {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    min-height: 46px;
    padding: 0 14px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--panel2);
    color: var(--text);
    font-size: 13px;
    font-weight: 650;
    cursor: pointer;
}

.toolbutton:hover { border-color: var(--purple); }

.section-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 10px;
    margin: 21px 2px 11px;
}

.section-head h2 {
    margin: 0;
    font-size: 15px;
    font-weight: 750;
}

.count {
    color: var(--muted);
    font-size: 12px;
}

.file-list {
    display: grid;
    gap: 9px;
}

.file-row {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    padding: 12px;
    border: 1px solid var(--border);
    border-radius: 15px;
    background: linear-gradient(115deg, #1d1929, #171421);
    transition: border-color .15s, transform .15s;
}

.file-row:hover {
    border-color: #67508c;
    transform: translateY(-1px);
}

.file-icon {
    width: 45px;
    height: 45px;
    flex-shrink: 0;
    display: grid;
    place-items: center;
    border-radius: 12px;
    font-size: 21px;
}

.folder-icon { background: #38294f; color: #c4b5fd; }
.text-icon { background: #173846; color: var(--cyan); }
.generic-icon { background: #26342b; color: var(--green); }

.file-info {
    flex: 1;
    min-width: 0;
}

.file-name {
    display: block;
    font-size: 14px;
    font-weight: 680;
    overflow-wrap: anywhere;
}

.file-type {
    margin-top: 3px;
    color: var(--muted);
    font-size: 11px;
}

.actions {
    display: flex;
    flex-shrink: 0;
    align-items: center;
    gap: 6px;
}

.action {
    display: inline-grid;
    place-items: center;
    min-width: 38px;
    min-height: 38px;
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: #292238;
    color: var(--purple);
    font-size: 18px;
}

.action:hover {
    background: #38294f;
    border-color: var(--purple);
}

.empty {
    padding: 34px 16px;
    border: 1px dashed #493b5b;
    border-radius: 15px;
    text-align: center;
    color: var(--muted);
}

.empty-icon { font-size: 32px; margin-bottom: 8px; }

.viewer {
    overflow: hidden;
    border: 1px solid var(--border);
    border-radius: 16px;
    background: #14111d;
}

.viewer-head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 13px;
    background: var(--panel2);
    border-bottom: 1px solid var(--border);
}

.viewer-title {
    min-width: 0;
    font-weight: 700;
    overflow-wrap: anywhere;
}

.download-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    min-height: 40px;
    padding: 0 13px;
    border-radius: 10px;
    background: linear-gradient(135deg, #8b5cf6, #6d28d9);
    color: white;
    font-weight: 700;
    font-size: 12px;
}

pre {
    margin: 0;
    padding: 17px;
    color: #d9d3e8;
    font: 12px/1.7 ui-monospace, SFMono-Regular, Consolas, monospace;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    overflow-x: auto;
    max-height: 65vh;
    overflow-y: auto;
}

.backlink {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin: 0 0 14px;
    color: var(--purple);
    font-size: 13px;
    font-weight: 650;
}

.footer {
    padding: 28px 0 0;
    text-align: center;
    color: #716981;
    font-size: 10px;
    letter-spacing: 2px;
}

[hidden] { display: none !important; }

@media (max-width: 430px) {
    .container { padding: 13px 11px 25px; }
    .hero { padding: 20px 16px; }
    .status { padding: 6px 8px; font-size: 10px; }
    .file-row { gap: 9px; padding: 10px; }
    .file-icon { width: 39px; height: 39px; }
    .action { min-width: 34px; min-height: 36px; padding: 0 7px; }
    .toolbutton { padding: 0 11px; }
}
</style>
</head>
<body>
<div class="container">

<header class="header">
    <div class="brand-icon">⌘</div>
    <div>
        <div class="brand">ROOTJUNKY</div>
        <div class="subtitle">PAGER LOOT BROWSER</div>
    </div>
    <div class="status"><span class="dot"></span> LOCAL SERVER</div>
</header>

<section class="hero">
    <div class="eyebrow">File Explorer</div>
    <h1>Your loot. Organized.</h1>
    <p>Browse captured files, inspect text, and download what you need.</p>
</section>

<div class="pathbar">
    <a href="/cgi-bin/loot">⌂ Home</a>
    <span>›</span>
    <span id="currentPath">Loot</span>
</div>
HTML

# --------------------------------------------------
# File viewer
# --------------------------------------------------

if [ "$ACTION" = "view" ]; then
    if [ ! -f "$REAL_PATH" ]; then
        printf '<div class="empty">This file cannot be viewed.</div>'
    else
        printf '<a class="backlink" href="/cgi-bin/loot?path=%s">← Back to files</a>' \
            "$(encode "${CURRENT_REL%/*}")"

        printf '<div class="viewer"><div class="viewer-head"><div class="viewer-title">▤ '
        basename "$REAL_PATH" | escape_html
        printf '</div><a class="download-button" href="/cgi-bin/loot?action=download&amp;path=%s">↓ Download</a></div><pre>' \
            "$(encode "$CURRENT_REL")"

        cat "$REAL_PATH" | escape_html

        printf '</pre></div>'
    fi

    cat <<'HTML'
<footer class="footer">ROOTJUNKY • PINEAPPLE PAGER</footer>
</div>
</body>
</html>
HTML
    exit 0
fi

# --------------------------------------------------
# Folder browser
# --------------------------------------------------

if [ ! -d "$REAL_PATH" ]; then
    printf '<div class="empty">This item is not a folder.</div>'
else
    # Build clickable breadcrumbs
    if [ -n "$CURRENT_REL" ]; then
        printf '<div class="pathbar"><a href="/cgi-bin/loot">Loot</a>'

        BUILD_PATH=""
        OLD_IFS="$IFS"
        IFS='/'

        for PART in $CURRENT_REL; do
            [ -n "$PART" ] || continue

            BUILD_PATH="${BUILD_PATH:+$BUILD_PATH/}$PART"
            printf '<span>›</span>'

            if [ "$BUILD_PATH" = "$CURRENT_REL" ]; then
                printf '<span>'
                printf '%s' "$PART" | escape_html
                printf '</span>'
            else
                printf '<a href="/cgi-bin/loot?path=%s">' \
                    "$(encode "$BUILD_PATH")"
                printf '%s' "$PART" | escape_html
                printf '</a>'
            fi
        done

        IFS="$OLD_IFS"
        printf '</div>'
    fi

    cat <<'HTML'
<div class="toolbar">
    <label class="searchbox">
        <span>⌕</span>
        <input id="fileSearch" type="search"
            placeholder="Search files and folders..."
            autocomplete="off">
    </label>
    <button class="toolbutton" type="button"
        onclick="document.getElementById('fileSearch').value='';filterFiles();">
        Clear
    </button>
</div>

<div class="section-head">
    <h2>Browse files</h2>
    <span class="count" id="fileCount"></span>
</div>

<div class="file-list" id="fileList">
HTML

    if [ -n "$CURRENT_REL" ]; then
        PARENT_REL="${CURRENT_REL%/*}"
        [ "$PARENT_REL" = "$CURRENT_REL" ] && PARENT_REL=""

        printf '<a class="file-row" href="/cgi-bin/loot?path=%s" data-name="parent folder">'
        printf '<span class="file-icon folder-icon">↰</span>'
        printf '<span class="file-info"><span class="file-name">Parent folder</span>'
        printf '<span class="file-type">Go up one level</span></span>'
        printf '<span class="action">↑</span></a>\n' \
            "$(encode "$PARENT_REL")"
    fi

    LIST="$WEBROOT/listing.$$"

    find "$REAL_PATH" -mindepth 1 -maxdepth 1 ! -type l -print |
        sort > "$LIST"

    ITEM_COUNT=0

    while IFS= read -r ITEM; do
        [ -n "$ITEM" ] || continue

        NAME="${ITEM##*/}"

        if [ -n "$CURRENT_REL" ]; then
            ITEM_REL="$CURRENT_REL/$NAME"
        else
            ITEM_REL="$NAME"
        fi

        ENCODED="$(encode "$ITEM_REL")"
        SAFE_NAME="$(printf '%s' "$NAME" | escape_html)"

        if [ -d "$ITEM" ]; then
            printf '<a class="file-row" data-name="%s" href="/cgi-bin/loot?path=%s">' \
                "$SAFE_NAME" "$ENCODED"
            printf '<span class="file-icon folder-icon">📁</span>'
            printf '<span class="file-info"><span class="file-name">%s</span>' \
                "$SAFE_NAME"
            printf '<span class="file-type">Folder · Browse contents</span></span>'
            printf '<span class="action">›</span></a>\n'

        elif [ -f "$ITEM" ]; then
            case "$NAME" in
                *.txt|*.TXT|*.log|*.LOG|*.md|*.MD|*.csv|*.CSV|*.json|*.JSON|*.conf|*.ini|*.sh|*.py|*.xml|*.yaml|*.yml|*.html|*.htm)
                    FILE_ICON="▤"
                    FILE_CLASS="text-icon"
                    FILE_TYPE="Text file · View or download"
                    ;;
                *)
                    FILE_ICON="▧"
                    FILE_CLASS="generic-icon"
                    FILE_TYPE="File · View or download"
                    ;;
            esac

            printf '<div class="file-row" data-name="%s">' "$SAFE_NAME"
            printf '<span class="file-icon %s">%s</span>' "$FILE_CLASS" "$FILE_ICON"
            printf '<span class="file-info"><a class="file-name" href="/cgi-bin/loot?action=view&amp;path=%s">%s</a>' \
                "$ENCODED" "$SAFE_NAME"
            printf '<span class="file-type">%s</span></span>' "$FILE_TYPE"
            printf '<span class="actions">'
            printf '<a class="action" title="View file" aria-label="View file" href="/cgi-bin/loot?action=view&amp;path=%s">⌕</a>' \
                "$ENCODED"
            printf '<a class="action" title="Download file" aria-label="Download file" href="/cgi-bin/loot?action=download&amp;path=%s">↓</a>' \
                "$ENCODED"
            printf '</span></div>\n'
        else
            continue
        fi

        ITEM_COUNT=$((ITEM_COUNT + 1))
    done < "$LIST"

    rm -f "$LIST"

    if [ "$ITEM_COUNT" -eq 0 ]; then
        printf '<div class="empty"><div class="empty-icon">📂</div>'
        printf '<strong>This folder is empty</strong>'
        printf '<div>There are no files to display here.</div></div>'
    fi

    cat <<'HTML'
</div>

<div class="empty" id="noResults" hidden>
    <div class="empty-icon">⌕</div>
    <strong>No matching files</strong>
    <div>Try a different search term.</div>
</div>

<script>
(function () {
    var input = document.getElementById('fileSearch');
    var list = document.getElementById('fileList');
    var count = document.getElementById('fileCount');
    var empty = document.getElementById('noResults');

    if (!input || !list || !count) return;

    var rows = Array.prototype.slice.call(
        list.querySelectorAll('.file-row')
    );

    function filterFiles() {
        var query = input.value.toLowerCase().trim();
        var visible = 0;

        rows.forEach(function (row) {
            var name = (row.getAttribute('data-name') || '')
                .toLowerCase();
            var show = name.indexOf(query) !== -1;

            row.hidden = !show;
            if (show) visible++;
        });

        count.textContent = query
            ? visible + ' matching'
            : visible + ' items';

        if (empty) empty.hidden = visible !== 0;
    }

    input.addEventListener('input', filterFiles);
    filterFiles();
})();
</script>
HTML
fi

cat <<'HTML'
<footer class="footer">ROOTJUNKY • PINEAPPLE PAGER</footer>
</div>
</body>
</html>
CGI

chmod 755 "$WEBROOT/cgi-bin/loot"

# --------------------------------------------------
# Start server on the selected IP
# --------------------------------------------------

LOG "Starting Loot Browser on $DEVICE"
LOG "Browser URL: $URL"

uhttpd -f -p "$IP:$PORT" -h "$WEBROOT" \
    -x /cgi-bin -S -D &
SERVER_PID=$!

sleep 2

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    LOG "ERROR: uhttpd failed to start."
    exit 1
fi

if ! netstat -lnt 2>/dev/null | grep -q ":$PORT "; then
    LOG "ERROR: Port $PORT is not listening."
    exit 1
fi

LOG "Loot Browser is ready."
PROMPT_QR "$URL" "Scan to browse Pager loot: $(printf '%s' "${URL#http://}" | sed 's/:8088.*/:8088/') Closing this screen will kill the Loot Browser Server"

# Close the server when the QR prompt returns.
LOG "QR prompt closed. Shutting down Loot Browser..."
exit 0

