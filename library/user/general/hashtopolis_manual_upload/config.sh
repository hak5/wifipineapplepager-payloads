#!/bin/bash
# =============================================================================
# Hashtopolis Pager Configuration File
# =============================================================================
# This file contains all the configuration for the Hashtopolis upload payload.
# Edit these values to match your Hashtopolis server setup.
# =============================================================================

# =============================================================================
# SERVER CONNECTION SETTINGS
# =============================================================================

# Hashtopolis Server URL
# This should point to your Hashtopolis API endpoint
# Example: http://192.168.1.100:8080/api/user.php
# Example: https://hashtopolis.example.com/api/user.php
export HASHTOPOLIS_URL="http://example.com/api/user.php"

# API Access Key
# Generate this in Hashtopolis: Users > API Management > Create API Key
# IMPORTANT: Replace this with your actual API key!
export API_KEY="YOUR_API_KEY_HERE"

# =============================================================================
# HASHLIST SETTINGS
# =============================================================================

# Hash Type for WPA/WPA2 Handshakes
# 22000 = WPA-PBKDF2-PMKID+EAPOL (Hashcat 6.0+, standard for modern systems)
# See: https://hashcat.net/wiki/doku.php?id=example_hashes
export HASH_TYPE=22000

# Access Group ID
# Set which access group this hashlist belongs to
# Default group is usually 1
# Check in Hashtopolis: Config > Access Groups
export ACCESS_GROUP_ID=1

# Secret Hashlist
# true  = Hide hash contents from other users
# false = Allow viewing (recommended for team environments)
export SECRET_HASHLIST=false

# Hashcat Brain Settings
# Brain helps avoid duplicate work across multiple cracking sessions
# IMPORTANT: Only enable if Brain is configured on your Hashtopolis server!
# Enabling Brain without proper server configuration will cause task failures.
# Refer to Hashtopolis API documentation (Section: Hashlists) for Brain setup.
export USE_BRAIN=false
export BRAIN_FEATURES=0

# =============================================================================
# TASK SETTINGS
# =============================================================================

# Preconfigured Task ID
# This is the ID of the preconfigured task you created in Hashtopolis
# Find this in: Tasks > Preconfigured Tasks > View your task
# The ID appears in the URL or task list
# Example: https://your-server/hashtopolis/pretasks.php?id=7 → ID is 7
# IMPORTANT: Do not use quotes - must be a number
export PRETASK_ID=1

# Cracker Version ID
# Find this in: Config > Crackers > hashcat
# Usually the latest/highest version ID is recommended
# Check which versions are available in your Hashtopolis instance
# Common values: 1, 2, 3, etc. (higher = newer)
export CRACKER_VERSION_ID=1

# =============================================================================
# CONFIGURATION STORAGE HELPER
# =============================================================================
# Call push_payload_config from the payload when you want to persist settings.

push_payload_config() {
    : "${PAYLOAD_NAME:=hashtopolis_manual_upload}"

    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" hashtopolisurl "$HASHTOPOLIS_URL"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" apikey "$API_KEY"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" hashtype "$HASH_TYPE"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" accessgroupid "$ACCESS_GROUP_ID"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" secrethashlist "$SECRET_HASHLIST"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" usebrain "$USE_BRAIN"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" brainfeatures "$BRAIN_FEATURES"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" pretaskid "$PRETASK_ID"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" crackerversionid "$CRACKER_VERSION_ID"
}
