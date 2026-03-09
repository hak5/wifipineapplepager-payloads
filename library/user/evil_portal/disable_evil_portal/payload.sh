#!/bin/bash
# Name: Disable Evil Portal
# Description: Disables the Evil Portal service
# Author: PentestPlaybook
# Version: 1.0
# Category: Wireless

/etc/init.d/evilportal disable
ALERT "Evil Portal disabled."
