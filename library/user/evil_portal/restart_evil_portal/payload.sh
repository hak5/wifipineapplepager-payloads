#!/bin/bash
# Name: Restart Evil Portal
# Description: Restarts the Evil Portal service
# Author: PentestPlaybook
# Version: 1.0
# Category: Wireless

/etc/init.d/evilportal restart
ALERT "Evil Portal restarted"
