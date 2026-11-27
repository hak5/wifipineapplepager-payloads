#!/bin/bash
# Title: Example Auth Captured Alert
# Description: Alert human readable summary
# Author: Hak5Darren
# Version: 1.0

ALERT "$_ALERT_AUTH_SUMMARY"

# Additional variables include:
# $_ALERT                         "pineapple_auth_captured"
# $_ALERT_AUTH_SUMMARY            human-readable summary of the auth
# $_ALERT_AUTH_TYPE               mschapv2 | eap-ttls/chap | eap-ttls/mschapv2
# $_ALERT_AUTH_USERNAME           (when known) captured user name
# $_ALERT_AUTH_CHALLENGE_IDENTITY (when known) captured challenge id
