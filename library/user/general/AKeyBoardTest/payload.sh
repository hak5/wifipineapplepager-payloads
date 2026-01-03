#!/bin/bash
#Title: keyboard test
#Description: a simple tool to bring up all the keyboards for testing
#Author: Rootjunky
#Version: 1

NUMBER=$(NUMBER_PICKER "pick a number" 1)
LOG "You Picked Number $NUMBER"
IP=$(IP_PICKER "Enter an IP" 192.168.1.1)
LOG "Your IP is $IP"
MAC=$(MAC_PICKER "Enter your MAC" 11:22:33:44:55:66)
LOG "Your MAC is $MAC"
TEXT=$(TEXT_PICKER "Enter some text" Pager)
LOG "What did you just say? $TEXT"
LOG "All keyboards layouts have been viewed"