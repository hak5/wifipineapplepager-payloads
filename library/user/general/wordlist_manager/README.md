# Wordlist Manager

**Type:** User Payload
**Category:** General
**Author:** sinX
**Version:** 1.0

## Description

Utility payload for downloading, managing, and organizing password wordlists for use with password cracking payloads. Automatically downloads common wordlists from public repositories and organizes them in the correct directory structure.

## Features

- **Automatic Downloads**: Fetch common wordlists from public repositories
- **Wordlist Statistics**: View size and entry count for each wordlist
- **Organization**: Automatically organizes wordlists in `/root/wordlists/`
- **Connectivity Check**: Verifies internet connection before downloading

## Requirements

- Internet connectivity (via WiFi or USB tethering)
- `wget` or `curl` (usually pre-installed)
- Sufficient storage space (depends on wordlist sizes)

## Installation

1. Copy this directory to `/root/payloads/user/general/wordlist_manager/`
2. Ensure the script is executable:
   ```bash
   chmod +x /root/payloads/user/general/wordlist_manager/payload.sh
   ```

## Configuration

Edit the configuration section at the top of `payload.sh`:

```bash
WORDLIST_DIR="/root/wordlists"
TEMP_DIR="/tmp/wordlists"
```

## Usage

### From Pager Dashboard

1. Navigate to **Payloads** > **User Payloads** > **General**
2. Select **Wordlist Manager**
3. Press button to launch
4. Confirm download when prompted
5. Wait for downloads to complete

### Manual Execution

```bash
cd /root/payloads/user/general/wordlist_manager/
./payload.sh
```

## Downloaded Wordlists

The payload automatically downloads these wordlists:

### common-passwords.txt
- **Size**: ~1,000 passwords
- **Source**: SecLists repository
- **Use Case**: Quick testing, common passwords
- **Crack Time**: 1-2 minutes

### rockyou-top10k.txt
- **Size**: ~10,000 passwords
- **Source**: SecLists repository
- **Use Case**: Most common passwords from rockyou leak
- **Crack Time**: 5-15 minutes

## Manual Wordlist Installation

### Via SCP (Recommended)

From your computer:
```bash
scp /path/to/wordlist.txt root@172.16.42.1:/root/wordlists/
```

### Via USB Mass Storage

1. Enable USB storage mode on Pager
2. Copy wordlist files to `/wordlists/` directory
3. Disable USB storage mode

### Via Web Interface

Some Pager firmware versions support file upload through web UI:
1. Navigate to Pager web interface
2. Go to Advanced > File Manager
3. Upload wordlist to `/root/wordlists/`

## Recommended External Wordlists

### Small (< 1 MB)
- **darkc0de.lst** - 1.5 million passwords
- **john.txt** - Default John the Ripper wordlist

### Medium (1-100 MB)
- **rockyou.txt** (top 100k) - Most common 100k passwords
- **crackstation-human-only.txt** - Human-memorable passwords

### Large (> 100 MB)
- **rockyou.txt** (full) - 14.3 million passwords, 133 MB
  - **Warning**: May be too large for Pager storage/memory
  - Consider using on external system and syncing smaller subsets

### Specialized
- **wifi-default-passwords.txt** - Default router passwords
- **probable-v2-wpa-top1m.txt** - WiFi-specific wordlist

## Storage Management

### Check Available Space

```bash
df -h /root
```

### Remove Old Wordlists

```bash
rm /root/wordlists/old-wordlist.txt
```

### Compress Large Wordlists

```bash
gzip /root/wordlists/rockyou.txt
# Creates rockyou.txt.gz (much smaller)
# Decompress when needed: gunzip rockyou.txt.gz
```

## Wordlist Sources

### SecLists (Public Repository)
- **URL**: https://github.com/danielmiessler/SecLists
- **Category**: Passwords > Common-Credentials
- **License**: MIT
- **Contents**: Curated common password lists

### Weakpass.com
- **URL**: https://weakpass.com/
- **Contents**: Large password databases
- **Note**: Very large files, may not fit on Pager

### Custom Wordlists

Create targeted wordlists based on your testing scenario:

```bash
# Common patterns for a specific target
cat > /root/wordlists/target-custom.txt << EOF
CompanyName2024
CompanyName2025
CompanyName123
CompanyName!
Welcome123
Summer2024
Password1!
EOF
```

## Viewing Wordlist Contents

### Count Entries
```bash
wc -l /root/wordlists/rockyou.txt
```

### View First 10 Passwords
```bash
head -10 /root/wordlists/rockyou.txt
```

### Search for Specific Pattern
```bash
grep -i "password" /root/wordlists/rockyou.txt
```

## Troubleshooting

### "No internet connection"
- Verify Pager is connected to internet
- Check WiFi or USB tethering
- Test: `ping 8.8.8.8`

### "Failed to download"
- Check if source URL is accessible
- Verify `wget` is installed: `which wget`
- Try manual download with `wget -O file.txt URL`

### "No space left on device"
- Check available space: `df -h`
- Remove old files or unused wordlists
- Use smaller wordlists or external storage

### Downloads are slow
- Use USB tethering instead of WiFi if possible
- Download on computer and transfer via SCP
- Consider pre-loading wordlists before field work

## Best Practices

1. **Download Before Field Work**: Don't rely on internet in the field
2. **Start Small**: Test with small wordlists first
3. **Organize by Size**: Keep small, medium, and large wordlists separate
4. **Regular Updates**: Refresh wordlists periodically
5. **Backup**: Keep copies of wordlists on external storage

## Integration with Other Payloads

This payload is designed to work with:

- **Auto Handshake Cracker** (alerts/handshake_captured/auto_crack)
- **Interactive Handshake Cracker** (user/exfiltration/handshake_cracker)

After running Wordlist Manager, other cracking payloads will automatically detect and use the downloaded wordlists.

## Security & Legal Notice

Password wordlists should only be used for **authorized security testing**. Ensure you have explicit written permission before testing any networks you do not own.

## Future Enhancements

Planned features for future versions:
- Interactive wordlist selection
- Wordlist merging and deduplication
- Custom wordlist generation
- Wordlist quality analysis
