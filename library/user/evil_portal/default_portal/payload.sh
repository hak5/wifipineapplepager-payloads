#!/bin/bash
# Name: Default Portal
# Description: Activates the Default captive portal using /root/portals/current
# Author: PentestPlaybook / 0x4B
# Version: 2.0
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
PORTALS_ROOT="/root/portals/"
PORTAL_NAME="Default"
PORTAL_DIR="${PORTALS_ROOT}/${PORTAL_NAME}"
CURRENT_LINK="${PORTALS_ROOT}/current"

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
# STEP 2: Update current portal symlink
# ====================================================================
LOG "Step 2: Switching active portal to '${PORTAL_NAME}'..."

ln -sfn "${PORTAL_DIR}" "${CURRENT_LINK}"

if [ $? -ne 0 ]; then
    LOG "ERROR: Failed to update current portal symlink"
    exit 1
fi

# Restore captiveportal symlink if missing

if [ ! -L /www/captiveportal ]; then
    LOG "WARNING: captiveportal symlink missing"
    LOG "Restoring captiveportal symlink"
    ln -sfn /pineapple/ui/modules/evilportal/assets/api /www/captiveportal
fi

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
LOG "Portal Name : ${PORTAL_NAME}"
LOG "Portal Path : ${PORTAL_DIR}"
LOG "Active Link : ${CURRENT_LINK}"
LOG "Portal URL  : http://${PORTAL_IP}/"
LOG "=================================================="
exit 0
