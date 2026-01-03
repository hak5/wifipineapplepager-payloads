# Hashtopolis Handshake Upload
Credit to Hunt-Z who wrote the original documentation and scripts for doing this automatically as an Alert. The documentation and script was modified by TheDadNerd to run the script manually instead of in real-time. This is useful for when you are collecting handshakes but not connected to the internet. This script also offers to delete the handshakes from the pager after they are uploaded. 

WiFi Pineapple manual upload script

Manually upload captured WPA/WPA2 handshakes from your WiFi Pineapple to a Hashtopolis distributed cracking server.

## What This Does

This script integrates your WiFi Pineapple with Hashtopolis to create a seamless handshake-to-crack workflow:

### The Flow

1. **WiFi Pineapple captures WPA handshakes** → Stored in `/root/loot/handshakes`
2. **Script validates** → Tests server connection and API authentication
3. **Uploads handshakes** → Converts each `.22000` file to base64 and uploads via API
4. **Creates cracking tasks** → Launches your preconfigured task for each new hashlist
5. **Notifies you** → Shows success messages with hashlist IDs
6. **Cleans up (on success)** → Prompts to remove files from the handshake directory after all uploads succeed

### Why This Is Useful

**Without this payload:**
- Manually download handshakes from Pineapple
- Manually convert the handshakes to base64
- Manually upload to Hashtopolis web interface
- Manually create task and assign hashlist
- Time-consuming, error-prone, requires device access

**With this payload:**
- Streamlined - capture → upload → crack
- Works remotely (Pineapple just needs internet)
- Instant cracking starts (agents begin work immediately)
- Minimal manual intervention (run once, optional cleanup prompt)
- Great for red team engagements, pentests, or building a handshake collection

## Requirements

- WiFi Pineapple with internet connectivity
- Hashtopolis server (v0.5.0+) with API access
- Active Hashtopolis agents ready to crack
- Basic knowledge of Hashcat and wordlists

## Installation

### Step 1: Set Up Hashtopolis Server

If you don't have Hashtopolis installed yet, follow the official installation guide:

**📖 Installation Guide:** https://docs.hashtopolis.org/installation_guidelines/basic_install/

### Step 2: Configure Hashtopolis

#### 2.1 Generate API Key

1. Log into your Hashtopolis web interface
2. Navigate to: **Users > API Management**
3. Click **"Create API Key"**
4. Copy the generated key (you'll need this for `config.sh`)

#### 2.2 Upload Wordlist Files

1. Go to **Files** in the Hashtopolis menu
2. Click **"+ New File"**
3. Select **File Type: Wordlist (0)**
4. Upload your favorite wordlist (e.g., `rockyou.txt`, `crackstation.txt`)
5. Optionally upload rule files (e.g., `best64.rule`, `dive.rule`)

**💡 Tip:** You can also add files from URL:
```
https://github.com/hashcat/hashcat/raw/master/rules/best64.rule
```

#### 2.3 Create Preconfigured Task

This is the template that defines how handshakes will be cracked.

1. Navigate to: **Tasks > New Preconfigured Task**
2. Fill in the basic settings:

| Field | Value | Description |
|-------|-------|-------------|
| **Name** | Pager WPA Crack | Descriptive name for your task |
| **Chunk Time** | `600` | Seconds per work chunk (default: 600) |
| **Status Timer** | `5` | Update interval in seconds |
| **Benchmark Type** | `speed` | Use "speed" for most cases |
| **Priority** | `100` | Higher = more important (0-9999) |
| **Max Agents** | `0` | 0 = unlimited agents |
| **CPU Only** | `☐` unchecked | Allow GPU cracking |
| **Small Task** | `☐` unchecked | Leave unchecked for WPA |

3. On the right side, **check the boxes** next to:
   - Your wordlist file(s)
   - Your rule file(s) (if using any)

**Note:** The attack command is automatically generated based on the files you select. You don't need to manually configure it.

4. Click **"Create Preconfigured Task"**

5. **📝 Note the Task ID** - you'll see it in the URL or task list
   - Example: `https://your-server/hashtopolis/pretasks.php?id=7` → Task ID is `7`

#### 2.4 Get Cracker Version ID

1. Navigate to: **Config > Crackers**
2. Click on **"hashcat"**
3. Find the **Version ID** for your hashcat version
   - Modern Hashtopolis comes with version 7.1.2
   - The version IDs are assigned sequentially (1, 2, 3, etc.)
   - Note the **Version ID** number (not the version string)

**Example:** If you see:
```
Version ID: 1 | Version: 7.1.2
Version ID: 2 | Version: 6.2.6
```
Use `CRACKER_VERSION_ID=1` for the latest version (7.1.2).

### Step 3: Install Script

Copy the following files to your WiFi Pineapple:
- `payload.sh` (the main script)
- `config.sh` (configuration file)

Place them in the same directory.

### Step 4: Configure the Payload

Edit `config.sh` with your settings:

```bash
# Server URL - Replace with your Hashtopolis server
export HASHTOPOLIS_URL="http://192.168.1.100/api/user.php"

# API Key - From Step 2.1
export API_KEY="abc123def456ghi789"

# Hash Type (22000 for WPA-PBKDF2-PMKID+EAPOL)
export HASH_TYPE=22000

# Preconfigured Task ID - From Step 2.3
# IMPORTANT: No quotes, must be a number
export PRETASK_ID=7

# Cracker Version ID - From Step 2.4
export CRACKER_VERSION_ID=1

# Access Group (usually 1 for default group)
export ACCESS_GROUP_ID=1

# Privacy Settings
export SECRET_HASHLIST=false
export USE_BRAIN=false
export BRAIN_FEATURES=0
```

### Step 5: Run the Script

1. Capture one or more handshakes
2. Run the payload

3. Check for success messages with hashlist IDs

4. Respond to the cleanup prompt if all uploads succeeded.
5. Verify in Hashtopolis:
   - Go to **Hashlists** - you should see a new entry with format `WPA_SSID_AP_TIMESTAMP`
   - Go to **Tasks** - a task should be running
   - Check that agents are assigned and cracking

## Configuration Reference

### Hash Type

Use hash type **22000** for WPA/WPA2 handshakes:
- `22000` = WPA-PBKDF2-PMKID+EAPOL (Hashcat 6.0+, standard)

This is the modern standard for WPA handshake cracking and is supported by all current versions of Hashtopolis (which includes Hashcat 7.1.2).

### Priority Levels

- `0` - Lowest priority (background tasks)
- `100` - Normal priority (recommended)
- `500` - High priority
- `1000+` - Critical/urgent tasks

### Hashlist Naming Convention

Uploaded hashlists are automatically named:
```
WPA_[SSID]_[AP_MAC_ADDRESS]_[UNIX_TIMESTAMP]
```

Example: `WPA_CoffeeShop_UNKNOWN_AP_1766719274`

This makes it easy to:
- Identify which network the handshake came from
- Track when it was captured
- Search and filter in Hashtopolis

**Note:** SSIDs are sanitized to `a-z`, `A-Z`, `0-9`, `_`, and `-`. The AP MAC is currently reported as `UNKNOWN_AP`.

## Troubleshooting

### Connection Errors

**Error: "Cannot connect to server"**
- Verify your Pineapple has internet connectivity
- Test the URL: `curl -X POST http://your-server/api/user.php -H "Content-Type: application/json" -d '{"section":"test","request":"connection"}'`
- Expected response: `{"section":"test","request":"connection","response":"SUCCESS"}`

**Error: "Invalid API endpoint"**
- Ensure the URL ends with `/api/user.php`
- Check for typos in the URL
- Verify Hashtopolis is installed and accessible

### Authentication Errors

**Error: "Invalid API key"**
- Verify the API key is copied correctly (no extra spaces)
- Regenerate the API key in Hashtopolis: Users > API Management
- Check that the key hasn't been deleted or expired

### Configuration Errors

**Error: "Pretask ID not configured"**
- Create a preconfigured task in Hashtopolis
- Note the task ID from the URL or task list
- Set `PRETASK_ID` in `config.sh` (without quotes, as a number)

**Error: "Task creation failed"**
- Verify the preconfigured task ID exists and is correct
- Check the Cracker Version ID is valid (Config > Crackers)
- Ensure you have permissions to run tasks
- Check that all required files (wordlists/rules) are uploaded
- Review task settings in Hashtopolis UI

### Brain Configuration Errors

**Error: "Hashcat Brain Error"**
- Brain is enabled (`USE_BRAIN=true`) but not properly configured on the server
- Either configure Brain on your Hashtopolis server (see API documentation, Hashlists section)
- Or disable Brain in `config.sh`: `USE_BRAIN=false`
- Brain requires:
  - Brain server configured in Hashtopolis settings
  - Agents with Brain support enabled
  - Network connectivity between agents and Brain server

### No Cracking Progress
- Verify agents are connected (Agents menu in Hashtopolis)
- Check agent status (should be active and assigned)
- Review agent logs for errors
- Ensure hashcat binary is properly installed on agents

## Security Considerations

### Network Security
- **Use HTTPS for production deployments** to encrypt API traffic
- Consider VPN for Pineapple ↔ Server communication
  - Pre-installed options: **Tailscale**, **WireGuard**, or **OpenVPN**
  - These provide secure tunnels without complex firewall rules
- Firewall Hashtopolis to trusted IPs only

### Hash Privacy
- Set `SECRET_HASHLIST=true` if hashes contain sensitive data
- Use access groups to restrict visibility
- Regularly audit user permissions

## Advanced Configuration

### Using Hashcat Brain

Enable distributed brain to avoid duplicate work:

```bash
export USE_BRAIN=true
export BRAIN_FEATURES=3  # Use both attack and plain brain
```

**Requirements:**
- Brain server configured in Hashtopolis (Config > Server)
- Agents with brain support enabled
- Network connectivity between agents

**⚠️ Important:** Enabling Brain without proper server configuration will cause task failures. Refer to the Hashtopolis API documentation PDF (Hashlists section) for detailed Brain setup instructions.

### Custom Chunk Sizes

Edit the preconfigured task to optimize for your hardware:

- **Fast GPUs:** Increase chunk time (e.g., `1200` seconds)
- **Slow CPUs:** Decrease chunk time (e.g., `300` seconds)
- **Heterogeneous:** Use default `600` seconds

### Multiple Preconfigured Tasks

Create different task templates for various scenarios:

1. **Quick Crack** - Common passwords, fast rules
2. **Deep Crack** - Large wordlists, extensive rules  
3. **Brute Force** - Targeted mask attacks
4. **Emergency** - High priority, all agents

Set the appropriate `PRETASK_ID` in `config.sh` based on your needs.

## API Reference

This payload uses the following Hashtopolis API calls:

- `test/connection` - Verify API endpoint is accessible
- `test/access` - Validate API key authentication
- `hashlist/createHashlist` - Upload handshake file
- `task/runPretask` - Launch cracking task from template

Full API documentation: https://docs.hashtopolis.org/

## Contributing

Found a bug or have a feature request? Contributions welcome!

## Credits

- **Hashtopolis**: https://github.com/hashtopolis/server
- **WiFi Pineapple**: https://www.hak5.org/
- **Hashcat**: https://hashcat.net/

## License

This payload follows the Hashtopolis contribution guidelines and is free for use with proper attribution.

---

**⚠️ Legal Disclaimer:** Only use this tool on networks you own or have explicit permission to test. Unauthorized access to computer networks is illegal.
