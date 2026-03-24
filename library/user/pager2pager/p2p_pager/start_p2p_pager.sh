#!/bin/bash

echo "Service started" > /tmp/p2p_pager.log
/usr/bin/python3 /usr/bin/p2p_pager >> /tmp/p2p_pager.log 2>&1
