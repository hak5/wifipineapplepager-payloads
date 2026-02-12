#!/bin/bash
# ============================================================================
# WPA-SEC Configuration File
# ============================================================================
#
# This file contains your WPA-SEC API credentials and settings.
#
# IMPORTANT: Replace the placeholder with your actual API key!
#
# Get your FREE API key at: https://wpa-sec.stanev.org/?get_key
#
# ============================================================================

# =============================================================================
# API CONFIGURATION
# =============================================================================

# Your WPA-SEC API Key (REQUIRED)
# This key authenticates your uploads and links cracked passwords to your account.
# Get your key at: https://wpa-sec.stanev.org/?get_key
#
# IMPORTANT: Replace this placeholder with your actual API key!
export WPA_SEC_KEY="YOUR_API_KEY_HERE"

# =============================================================================
# BEHAVIOR SETTINGS
# =============================================================================

# Automatically upload handshakes when captured
# Set to "false" to disable auto-upload (you can still use bulk upload)
export AUTO_UPLOAD="true"

# Vibrate the Pager when upload succeeds
export VIBRATE_ON_SUCCESS="true"

# Show alert notification on successful upload
export SHOW_ALERT="true"

# =============================================================================
# NETWORK SETTINGS
# =============================================================================

# Connection timeout in seconds
export CONNECT_TIMEOUT="30"

# Maximum transfer time in seconds
export MAX_TIME="120"

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

if [ -z "$WPA_SEC_KEY" ] || [ "$WPA_SEC_KEY" = "YOUR_API_KEY_HERE" ]; then
    echo "ERROR: WPA_SEC_KEY is not configured"
    echo "Please edit config.sh and add your API key"
    echo "Get your key at: https://wpa-sec.stanev.org/?get_key"
    exit 1
fi
