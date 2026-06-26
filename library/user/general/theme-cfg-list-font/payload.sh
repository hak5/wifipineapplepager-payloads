#!/bin/bash
# Title: Theme Config - List Font Size
# Author: cncartist
# Description: Changes files relating to the list picker font size to be smaller, can return back to default.  Theme needs to be reloaded after changing to apply.
# Category: general
# Version: 1.0
# 
# ============================================
# Acknowledgements: 
# ============================================+ 
# Zombie UFO Theme - Author: Zombie Joe - (theme + support)
# 
#  -- Menu Display / Smaller Font Size for List Picker:
#  -- -- -- changed text_size to small and max_chars to 38/40
#  -- -- -- "text_size": "small"  &  "max_chars": 38  &  "max_chars": 40
#  -- -- -- updated theme in /mmc/root/themes/THEME/components/templates
#  -- -- -- -- - option_dialog_string.json  ( "max_chars": 38 )
#  -- -- -- -- - option_dialog_string_selected.json  ( "max_chars": 40 )
# 
updated=0
themeFileExists=0
themepath=$(uci get system.@pager[0].theme_path)
# LOG "$themepath"
# Syntax: ${variable/pattern/replacement}
themename=${themepath/\/root\/themes\//}
# /root/themes/Zombie_UFO
# LOG "$themename"
DEST_PATH="${themepath}/components/templates/option_dialog_string.json"
if [ -f "$DEST_PATH" ]; then
	themeFileExists=1
fi

LOG blue "================================================="
LOG      "======== Theme Config - List Font Size =========="
LOG blue "================================================="
LOG      "====== Changes Current Theme List Font Size ====="
LOG      "======= Choices: Small or Default (medium) ======"
LOG blue "================================================="
if [[ "$themeFileExists" -eq 1 ]] ; then
	if grep -q "\"text_size\": \"small\"" "$DEST_PATH"; then
		LOG cyan "Current Font Size: Small"
	elif grep -q "\"text_size\": \"medium\"" "$DEST_PATH"; then
		LOG cyan "Current Font Size: Medium"
	elif grep -q "\"text_size\": \"large\"" "$DEST_PATH"; then
		LOG cyan "Current Font Size: Large"
	fi
fi
LOG "Press OK to continue..."
LOG " "
WAIT_FOR_BUTTON_PRESS A
sleep 0.25
if [[ "$themeFileExists" -eq 1 ]] ; then
	resp=$(CONFIRMATION_DIALOG "Do you want to Change your Current Theme (${themename}) List Font Size?

	You can choose Small or Default Font Size.")
	if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
		LOG "Selecting Theme Font Size..."
		LOG " "
		resp=$(CONFIRMATION_DIALOG "Do you want to Change Theme (${themename}) List Font Size to Small, allowing more text to be shown?")
		if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
			LOG "Selecting Small Theme Font Size..."
			LOG " "
			DEST_PATH="${themepath}/components/templates/option_dialog_string.json"
			if [ -f "$DEST_PATH" ]; then
				LOG "Updating theme file 1..."
				#   "text_size": "small",
				#   "max_chars": 38,
				sed -i 's/"text_size": "medium",/"text_size": "small",/' "$DEST_PATH"
				sed -i 's/"text_size": "large",/"text_size": "small",/' "$DEST_PATH"
				sed -i 's/"max_chars": *[0-9]*,/"max_chars": 38,/' "$DEST_PATH"
				updated=1
			else
				LOG red "Theme file does not exist! $DEST_PATH"
			fi
			DEST_PATH="${themepath}/components/templates/option_dialog_string_selected.json"
			if [ -f "$DEST_PATH" ]; then
				LOG "Updating theme file 2..."
				#   "text_size": "small",
				#   "max_chars": 40,
				sed -i 's/"text_size": "medium",/"text_size": "small",/' "$DEST_PATH"
				sed -i 's/"text_size": "large",/"text_size": "small",/' "$DEST_PATH"
				sed -i 's/"max_chars": *[0-9]*,/"max_chars": 40,/' "$DEST_PATH"
				updated=1
			else
				LOG red "Theme file does not exist! $DEST_PATH"
			fi
			if [[ "$updated" -eq 1 ]] ; then
				LOG green "Small Theme (${themename}) Font Size Change Complete!"
				LOG blue "================================================="
				LOG red  "============ THEME RELOAD REQUIRED! ============="
				LOG blue "================================================="
				LOG "Please reload your theme for the changes to take effect!"
				LOG blue "================================================="
				sleep 1				
				resp=$(CONFIRMATION_DIALOG "Do you want to Reload your Current Theme (${themename}) Now?

				This will restart the Pagers UI.")
				if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
					# Do you want to reload now?
					LOG "Reloading UI..."
					LOG "Please wait..."
					LOG " "
					service pineapplepager restart
				fi
			else
				LOG red "Theme update error!"
			fi
			LOG "Press OK to continue..."
			LOG " "
			WAIT_FOR_BUTTON_PRESS A
		else 
			LOG "Skipped Small Theme List Font Size..."
			LOG " "
			resp=$(CONFIRMATION_DIALOG "Do you want to Return Theme (${themename}) List Font Size to Default?")
			if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
				LOG "Selecting Default Theme Font Size..."
				LOG " "
				DEST_PATH="${themepath}/components/templates/option_dialog_string.json"
				if [ -f "$DEST_PATH" ]; then
					LOG "Updating theme file 1..."
					#   "text_size": "small",
					#   "max_chars": 23,
					sed -i 's/"text_size": "large",/"text_size": "medium",/' "$DEST_PATH"
					sed -i 's/"text_size": "small",/"text_size": "medium",/' "$DEST_PATH"
					sed -i 's/"max_chars": *[0-9]*,/"max_chars": 23,/' "$DEST_PATH"
					updated=1
				else
					LOG red "Theme file does not exist! $DEST_PATH"
				fi
				DEST_PATH="${themepath}/components/templates/option_dialog_string_selected.json"
				if [ -f "$DEST_PATH" ]; then
					LOG "Updating theme file 2..."
					#   "text_size": "small",
					#   "max_chars": 25,
					sed -i 's/"text_size": "large",/"text_size": "medium",/' "$DEST_PATH"
					sed -i 's/"text_size": "small",/"text_size": "medium",/' "$DEST_PATH"
					sed -i 's/"max_chars": *[0-9]*,/"max_chars": 25,/' "$DEST_PATH"
					updated=1
				else
					LOG red "Theme file does not exist! $DEST_PATH"
				fi
				if [[ "$updated" -eq 1 ]] ; then
					LOG green "Default Theme (${themename}) Font Size Change Complete!"
					LOG blue "================================================="
					LOG red  "============ THEME RELOAD REQUIRED! ============="
					LOG blue "================================================="
					LOG "Please reload your theme for the changes to take effect!"
					LOG blue "================================================="
					sleep 1				
					resp=$(CONFIRMATION_DIALOG "Do you want to Reload your Current Theme (${themename}) Now?

					This will restart the Pagers UI.")
					if [[ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]] ; then
						# Do you want to reload now?
						LOG "Reloading UI..."
						LOG "Please wait..."
						LOG " "
						service pineapplepager restart
					fi
				else
					LOG red "Theme update error!"
				fi
				LOG "Press OK to continue..."
				LOG " "
				WAIT_FOR_BUTTON_PRESS A
			else 
				LOG "Skipped Default Theme List Font Size..."
				LOG " "
			fi
		fi
	else 
		LOG "Skipped changing Theme List Font Size..."
		LOG " "
	fi
else 
	LOG red "Theme file does not exist for Current Theme! (${themename})"
	LOG " "
	LOG red "$DEST_PATH"
	LOG " "
fi
LOG "Finished, exiting..."
LOG " "

exit 0
