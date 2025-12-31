# Tailscale Installer Troubleshooting Guide

## Viewing Logs

### Method 1: Pager UI Logs
The Pager UI displays logs in real-time when running a payload. All `LOG` commands output to this interface.

### Method 2: System Logs (SSH)
SSH into your device and use `logread` to view system logs:

```bash
# View all recent logs
logread | tail -n 100

# Filter for Tailscale-related logs
logread | grep -i tailscale

# Follow logs in real-time
logread -f
```

### Method 3: Payload Output Files
Some payloads may write to temporary files in `/tmp/`:

```bash
# Check for temporary files
ls -la /tmp/tailscale*

# View temporary directory contents
ls -la /tmp/tailscale_install/
```

## Common Installation Errors

### Error: "Extraction failed"

**Symptoms:**
- Installation stops after "Download complete"
- Error message: "Extraction failed"

**Possible Causes:**
1. Downloaded file is corrupted
2. Not enough space in `/tmp/`
3. tar command not available or broken
4. Downloaded file is not a valid gzip archive

**Diagnostic Steps:**
```bash
# Check available space
df -h /tmp

# Verify the downloaded file
cd /tmp/tailscale_install/
ls -lh
file tailscale_*.tgz

# Try manual extraction
tar -xzf tailscale_*.tgz
```

**Solutions:**
- Free up space: `rm -rf /tmp/*` (be careful!)
- Re-run the installer (may have been a download issue)
- Check internet connectivity: `ping 8.8.8.8`

---

### Error: "Extracted files not found"

**Symptoms:**
- Extraction completes but installation fails
- Error message: "Extracted files not found"

**Possible Causes:**
1. Archive structure is different than expected
2. Extraction created files in unexpected location
3. Archive is empty or corrupted

**Diagnostic Steps:**
```bash
# Check what was extracted
cd /tmp/tailscale_install/
ls -la

# Look for any directories
find . -type d

# Look for binaries
find . -name "tailscale*" -type f
```

**Solutions:**
- Check the enhanced logs to see the actual directory structure
- The installer now logs the contents of the temp directory
- Look for the actual location of the binaries in the logs

---

### Error: "Failed to copy tailscale binary"

**Symptoms:**
- Binaries found but copy operation fails
- Error message: "Failed to copy tailscale binary"

**Possible Causes:**
1. `/usr/sbin/` is read-only or full
2. Permission denied
3. Existing files are in use

**Diagnostic Steps:**
```bash
# Check /usr/sbin permissions
ls -ld /usr/sbin

# Check available space
df -h /usr

# Check if files already exist
ls -la /usr/sbin/tailscale*

# Check if processes are using the files
lsof | grep tailscale
```

**Solutions:**
```bash
# Stop existing Tailscale service
/etc/init.d/tailscaled stop 2>/dev/null

# Remove old binaries
rm -f /usr/sbin/tailscale /usr/sbin/tailscaled

# Re-run installer
```

---

### Error: "Could not determine version"

**Symptoms:**
- Installation fails immediately
- Error message: "Could not determine version"

**Possible Causes:**
1. No internet connectivity
2. Tailscale repository is unreachable
3. Repository format has changed

**Diagnostic Steps:**
```bash
# Test internet connectivity
ping -c 3 8.8.8.8
ping -c 3 pkgs.tailscale.com

# Test repository access
wget -qO- https://pkgs.tailscale.com/stable/ | head -n 20

# Check DNS resolution
nslookup pkgs.tailscale.com
```

**Solutions:**
- Check network connectivity
- The installer will fall back to version 1.76.1 if detection fails
- Check the logs to see which fallback was used

---

### Error: "Download failed"

**Symptoms:**
- Version detected but download fails
- Error message: "Download failed. Check network connection."

**Possible Causes:**
1. No internet connectivity
2. Incorrect URL
3. File doesn't exist for mipsle architecture
4. Network timeout

**Diagnostic Steps:**
```bash
# Check the logged download URL
# Then try manually:
wget https://pkgs.tailscale.com/stable/tailscale_X.Y.Z_mipsle.tgz

# Check available files
wget -qO- https://pkgs.tailscale.com/stable/ | grep mipsle
```

**Solutions:**
- Verify internet connectivity
- Check if the version exists for mipsle architecture
- Try a different network
- Wait and retry (may be temporary network issue)

---

## Installation Process Debug Checklist

The enhanced installer now logs detailed information at each step:

1. ✅ **Version Detection**
   - Logs the detected version
   - Shows the download URL
   - Falls back to known version if needed

2. ✅ **Download**
   - Shows download progress
   - Verifies file exists after download
   - Logs file size

3. ✅ **Extraction**
   - Shows extraction command
   - Lists files after extraction
   - Verifies archive integrity

4. ✅ **Binary Installation**
   - Lists temp directory contents
   - Shows extracted directory path
   - Lists extracted directory contents
   - Verifies binaries exist before copying
   - Shows copy operations
   - Verifies installed files

5. ✅ **Service Creation**
   - Shows init script creation
   - Verifies script permissions

## Getting Help

If you're still experiencing issues:

1. **Collect Logs:**
   ```bash
   # Save full logs
   logread > /tmp/tailscale_install_logs.txt
   
   # Save directory contents
   ls -laR /tmp/tailscale_install/ > /tmp/directory_listing.txt
   ```

2. **Check System Info:**
   ```bash
   # Architecture
   uname -m
   
   # Available space
   df -h
   
   # Memory
   free -m
   ```

3. **Share Information:**
   - Error message from Pager UI
   - Relevant log entries
   - System information
   - Steps to reproduce

## Manual Installation

If the automated installer continues to fail, you can install manually:

```bash
# Download manually
cd /tmp
wget https://pkgs.tailscale.com/stable/tailscale_1.76.1_mipsle.tgz

# Extract
tar -xzf tailscale_1.76.1_mipsle.tgz

# Find the binaries
find . -name "tailscale" -type f
find . -name "tailscaled" -type f

# Copy to /usr/sbin (adjust path based on find results)
cp ./tailscale_*/tailscale /usr/sbin/
cp ./tailscale_*/tailscaled /usr/sbin/
chmod +x /usr/sbin/tailscale*

# Verify
/usr/sbin/tailscale version
```

Then run the configure.sh script separately:
```bash
cd /payloads/library/user/remote_access/tailscale_installer/
./configure.sh
```

