#!/bin/bash
# Name: Stop Evil Portal
# Description: Stops the Evil Portal service
# Author: PentestPlaybook
# Version: 1.0
# Category: Wireless

/etc/init.d/evilportal stop
ALERT "Evil Portal stopped."
