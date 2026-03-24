#!/bin/bash

echo "Service started" > /tmp/p2p_pager.log
echo "$(/usr/bin/python3 /usr/bin/p2p_pager 2>&1)" >> /tmp/p2p_pager.log
