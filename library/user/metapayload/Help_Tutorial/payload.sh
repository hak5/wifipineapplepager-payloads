#!/bin/bash
# Title: Help & Tutorial
# Description: Interactive tutorial for MetaPayload framework usage
# Author: MetaPayload
# Version: 1.0

LOG yellow "/\/\ MetaPayload Framework"

# Welcome screen
PROMPT "Welcome to MetaPayload!\n\nThis tutorial will guide you through the key features of the MetaPayload framework.\n\nPress any button to continue..."

# Backgrounding tasks
PROMPT "BACKGROUNDING TASKS\n\nPress LEFT while a payload is running to background it.\n\nThis creates a View_Task payload to monitor progress or stop it. You will receive a notification when it completes."

# Variables - Global
PROMPT "GLOBAL VARIABLES\n\nSet from main menu via Set_{VARNAME} payloads, or during run time.\n\nShared across all payloads.\n\nStored in metapayload/.env\n\nExample: TARGET_IP, TARGET_SUBNET"

# Variables - Local
PROMPT "LOCAL VARIABLES\n\nSaved per-payload.\n\nYou will be prompted to use defaults or change values during execution. If changed, you can optionally save them for next time."

# Task management
PROMPT "TASK MANAGEMENT\n\nView running tasks via View_{taskid} payloads (auto-generated).\n\nYou can export task logs to loot or Discord for later review. \n\nClear all tasks with Task_Clear_All payload."

# Discord Export
PROMPT "DISCORD EXPORT\n\nWhile exporting task logs, you can send them directly to a Discord channel.\n\nSet METAPAYLOAD_DISCORD_WEBHOOK_URL in /root/.metapayload"

# Final screen
PROMPT "Now, run Generate Payloads!!\n\nThe tutorial is complete. For more details, see README.md\n\nHappy hacking!"

LOG "Help tutorial completed."
LOG cyan "Don't forget to run 'Generate_Payloads' to create your payloads!  Many payloads await you!"
