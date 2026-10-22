#!/usr/bin/env python3
"""
Pagergotchi launcher - Pwnagotchi port for WiFi Pineapple Pager
Uses native C display library and hcxdumptool for WiFi operations
"""

import sys
import os

# Payload directory (standard Pager installation path)
PAYLOAD_DIR = '/root/payloads/user/reconnaissance/pagergotchi'

# Add payload directory to path so imports work
sys.path.insert(0, PAYLOAD_DIR)
sys.path.insert(0, os.path.join(PAYLOAD_DIR, 'lib'))

# Change to payload directory
os.chdir(PAYLOAD_DIR)

# Now import and run
from pwnagotchi_port.main import main

if __name__ == '__main__':
    sys.exit(main())
