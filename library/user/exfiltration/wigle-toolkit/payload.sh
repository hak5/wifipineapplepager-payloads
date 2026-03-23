#!/bin/bash
# Title: WiGLE Toolkit
# Description: Login, logout and upload loot to WiGLE
# Author: mik
# Version: 1.1
# Category: Exfiltration

LOG blue    "WiGLE Toolkit started
            What do you want to do today?"
LOG yellow  "- Press RIGHT to login
            - Press LEFT to logout
            - Press UP to upload your loot
            - Press any other key to abort"
resp=$(WAIT_FOR_INPUT)
case ${resp} in
	"RIGHT")
        LOG blue "Asking user for WiGLE credentials..."
        user=$(TEXT_PICKER "User:" "")
        case $? in
            ${DUCKYSCRIPT_CANCELLED})
                LOG red "User cancelled"
                exit 1
                ;;
            ${DUCKYSCRIPT_REJECTED})
                LOG red "Dialog rejected"
                exit 1
                ;;
            ${DUCKYSCRIPT_ERROR})
                LOG red "An error occurred"
                exit 1
                ;;
        esac
        pass=$(TEXT_PICKER "Password:" "")
        case $? in
            ${DUCKYSCRIPT_CANCELLED})
                LOG red "User cancelled"
                exit 1
                ;;
            ${DUCKYSCRIPT_REJECTED})
                LOG red "Dialog rejected"
                exit 1
                ;;
            ${DUCKYSCRIPT_ERROR})
                LOG red "An error occurred"
                exit 1
                ;;
        esac
        id=$(START_SPINNER "Fetching...") # Only one word, because of bug in 1.0.4
        resp=$(WIGLE_LOGIN ${user} ${pass})
        case $? in
            0)
                STOP_SPINNER ${id}
                LOG green   "${resp}
                            Complete!"
        	    ;;
            *)
                STOP_SPINNER ${id}
                LOG red     "Something went wrong:
                            ${resp}"
        	    exit 1
        	    ;;
        esac
        ;;
	"LEFT")
        LOG blue "Logging out..."
        resp=$(WIGLE_LOGOUT)
        case $? in
            0)
                LOG green "${resp}"
        	    ;;
            *)
                LOG red "Something went wrong:
                        ${resp}"
        	    exit 1
        	    ;;
        esac
        ;;
    "UP")
        LOG blue "WiGLE upload wizard started"
        if [[ -z $(PAYLOAD_GET_CONFIG wigle token) ]] || [[ -z $(PAYLOAD_GET_CONFIG wigle authname) ]]; then
            LOG red "WiGLE authname or token not found,
                    please login first"
            exit 1
        fi
        LOG blue "Please choose what to do with the loot after uploading:"
        LOG yellow "- Press LEFT to delete
                    - Press UP to archive
                    - Press DOWN to leave them as they are
                    - Press any other key to abort"
        resp=$(WAIT_FOR_INPUT)
        case ${resp} in
        	"UP")
                LOG blue "Your files will be moved to archive folder after upload"
                opt="--archive"
                ;;
        	"DOWN")
                opt=""
                ;;
        	"LEFT")
                opt="--remove"
                LOG red "Your files will be DELETED after upload
                         Press A if OK"
                resp=$(WAIT_FOR_INPUT)
                if [[ ${resp} != "A" ]]; then
                    LOG red "User cancelled"
                    exit 1
                fi
                ;;
        	*) 
        		LOG red "User cancelled"
        		exit 1
        		;;
        esac
        PAYLOAD_SET_CONFIG wigle apiname $(PAYLOAD_GET_CONFIG wigle authname) # Workaround for WIGLE_UPLOAD bug in 1.0.4
        for file in /root/loot/wigle/*.csv
        do
            [[ -e "${file}" ]] || break
            if [[ ${opt} = "" ]]; then
                resp=$(WIGLE_UPLOAD "${file}")
            else
                resp=$(WIGLE_UPLOAD "${opt}" "${file}")
            fi
            case $? in
                0)
                    LOG green "${resp}"
                    ;;
                *)
                    LOG red "${resp}"
                    exit 1
                    ;;
            esac
        done
        ;;
    *) 
        LOG red "User cancelled"
        exit 1
        ;;
esac
