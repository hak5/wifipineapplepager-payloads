#!/bin/bash
# Name: Default Portal
# Description: Deactivates current portal and activates the Default captive portal
# Author: PentestPlaybook
# Version: 1.0
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
PORTAL_DIR="/root/portals/Default"

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
# STEP 1: Verify Default Portal Exists
# ====================================================================
LOG "Step 1: Verifying Default portal exists..."

if [ ! -d "${PORTAL_DIR}" ]; then
    LOG "ERROR: Default portal not found at ${PORTAL_DIR}"
    LOG "Please run the 'Install Evil Portal' payload first"
    exit 1
fi

if [ ! -f "${PORTAL_DIR}/index.php" ]; then
    LOG "ERROR: Default portal is missing index.php"
    exit 1
fi

LOG "SUCCESS: Default portal found"

# ====================================================================
# STEP 2: Activate Portal via Symlinks
# ====================================================================
LOG "Step 2: Activating Default portal via symlinks..."

# Clear /www
rm -rf /www/*

# Create symlinks for PHP files
ln -sf "${PORTAL_DIR}/index.php" /www/index.php
ln -sf "${PORTAL_DIR}/MyPortal.php" /www/MyPortal.php
ln -sf "${PORTAL_DIR}/helper.php" /www/helper.php

# Create symlinks for captive portal detection
ln -sf "${PORTAL_DIR}/generate_204.html" /www/generate_204
ln -sf "${PORTAL_DIR}/hotspot-detect.html" /www/hotspot-detect.html

# Restore captiveportal symlink
ln -sf /pineapple/ui/modules/evilportal/assets/api /www/captiveportal

LOG "SUCCESS: Portal activated via symlinks"

# ====================================================================
# STEP 3: Restart nginx
# ====================================================================
LOG "Step 3: Restarting nginx..."

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
LOG "Step 4: Verifying installation..."

if curl -s http://${PORTAL_IP}/ | grep -q "Evil Portal"; then
    LOG "SUCCESS: Default portal is responding"
else
    LOG "WARNING: Portal may not be responding correctly"
fi

LOG "=================================================="
LOG "Default Portal Activated!"
LOG "=================================================="
LOG "Portal URL: http://${PORTAL_IP}/"
LOG "Portal files: ${PORTAL_DIR}/"
LOG "Active via symlinks in: /www/"
LOG "=================================================="
exit 0
