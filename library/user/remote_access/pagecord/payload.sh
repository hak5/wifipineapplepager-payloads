#!/bin/bash
#
# Title: PageCord
# Description: Control your poager through discord!
# Author: beigeworm
# Version: 1.0
# Firmware: Developed for firmware version 1.0.4


# -------- directory variables ----------
DCCONTROL_DIR="/root/payloads/user/remote_access/pagecord"
DCCONTROL_LOOT_DIR="/root/loot/dc_control"
SESSION_DIR="$DCCONTROL_LOOT_DIR/session_$(date +%Y%m%d_%H%M%S)"
ENV_FILE="$DCCONTROL_DIR/.env"
PIDFILE="$DCCONTROL_DIR/logs/dc_control.pid"
LOGFILE="$DCCONTROL_DIR/logs/dc_control.log"


# -------- splash screen ---------
LOG ""
LOG blue "+===========================+"
LOG blue "| ------- PageCord -------- |"
LOG blue "| - Discord Pager Control - |"
LOG blue "+========== v1.3 ===========+"
LOG ""
LOG yellow "| Control Your Pager Through Discord! |"
LOG ""



# ----------- setup ----------------
LOG blue "1 : Starting Setup..."

if [ ! -d "$DCCONTROL_DIR/logs" ] ; then
    mkdir -p "$DCCONTROL_DIR/logs"
    LOG green "Created logs directory"
else
    rm -rf "$DCCONTROL_DIR/logs"
    mkdir -p "$DCCONTROL_DIR/logs"
    LOG green "Logs cleared"
fi

if [[ ! -f "$ENV_FILE" ]]; then
    LOG yellow "Missing env file!"
    LOG blue "Creating .env..."

    cat > "$ENV_FILE" <<'EOF'
token="TOKEN_HERE"
chan="CHANNEL_ID_HERE"
pass="password"
EOF

    chmod 600 "$ENV_FILE"
    LOG green ".env created"
fi

# ---------- Load variables -------------
set -a
source "$ENV_FILE"
set +a


LOG blue "2 : Checking ENV file..."
if [[ ${#token} -lt 70 ]]; then

    resp=$(CONFIRMATION_DIALOG "Add Bot Credentials on pager?")
    case $? in
        $DUCKYSCRIPT_REJECTED)
            LOG "Dialog rejected"
            exit 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LOG "An error occurred"
            exit 1
            ;;
    esac

    case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        token=$(TEXT_PICKER "Enter Bot Token" "$token")

        # Update token in env file
        if grep -q '^token=' "$ENV_FILE"; then
            sed -i "s|^token=.*|token=\"$token\"|" "$ENV_FILE"
        else
            echo "token=\"$token\"" >> "$ENV_FILE"
        fi

        LOG green "Bot token saved to $ENV_FILE"


        chan=$(TEXT_PICKER "Enter Channel ID" "$chan")

        # Update channel id in env file
        if grep -q '^chan=' "$ENV_FILE"; then
            sed -i "s|^chan=.*|chan=\"$chan=\"|" "$ENV_FILE"
        else
            echo "chan=\"$chan\"" >> "$ENV_FILE"
        fi

        LOG green "Channel ID saved to $ENV_FILE"

        chan=$(TEXT_PICKER "Enter Channel ID" "$chan")

        # Update password in env file
        if grep -q '^pass=' "$ENV_FILE"; then
            sed -i "s|^pass=.*|pass=\"$pass=\"|" "$ENV_FILE"
        else
            echo "pass=\"$pass\"" >> "$ENV_FILE"
        fi

        LOG green "Password saved to $ENV_FILE"

        ;;

    $DUCKYSCRIPT_USER_DENIED)
        LOG red "Please edit $ENV_FILE"
        LOG red "Add your Discord bot credentials before running again."
        exit 1
        ;;
    *)
        LOG "Unknown response: $resp"
        exit 1
        ;;
    esac

else 
LOG green "ENV file check passed"
fi




# --------- define functions ------------

LOG blue "3 : Setting up Discord functions..."

send_to_discord() {
curl -s -X POST -H "Authorization: Bot $token" -H "Content-Type: application/json" -d "$json_payload" "https://discord.com/api/v10/channels/$chan/messages" >/dev/null
}

generate_random_letters() {
    local letters="0123456789"
    local password=""
    for i in {1..6}; do
        random_index=$((RANDOM % ${#letters}))
        password+=${letters:$random_index:1}
    done
    echo "$password"
    sleep 1
}


Background_Session() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    LOG yellow "Already running in background (pid $(cat "$PIDFILE"))"
    return
  fi

  LOG green "Starting background session..."
  (
    exec </dev/null
    exec >/tmp/payload.log 2>&1
    "$0" --bg
  ) &

  bg_pid=$!
  echo "$bg_pid" > "$PIDFILE"
  LOG blue "Background session started (pid $bg_pid)"
  echo "Background session started (pid $bg_pid)"
  exit 0
}

Authenticate() {

    if [[ "$command_result" == *"$password"* ]]; then
        recent_message=$(curl -s -H "Authorization: Bot $token" "https://discord.com/api/v10/channels/$chan/messages?limit=1")
        auth_user_id=$(echo "$recent_message" | grep -o '"author":{"id":"[^"]*' | grep -o '[^"]*$')
        LOG green "User Authenticated : $auth_user_id"

        if [ "$password" == "password" ]; then
            LOG yellow "Change default password!"
        fi

        authenticated=1
        cwd=$(pwd)
        json_payload="{
          \"content\": \"\",
          \"embeds\": [
            {
              \"title\": \":pager:   **PageCord Session Connected!**   :pager:\",
              \"description\": \"-# ---- Control Your WiFi Pineapple Pager Through Discord! ---- \n\n*You can use regular Linux and Duckyscript commands. Large outputs are split into 2000 character chunks to avoid Discord limits. Only the authenticated userID can interact with this session* \n\n **Additional Commands** \n- **options**  - Show the additional commands list\n- **pause**    - Pause this session (re-authenticate to resume)\n- **background**  - Restart the payload in the background\n- **close**    - Close this session permanently\n- **sysinfo**    - Show basic system information and public IP address\n- **download**   - Send a file to Discord [download path/to/file.txt]\n- **upload**     - Upload file to Pager [attach to 'upload' command]\n- **readme**     - Show a readme file [readme path/to/README.md]\n- **payloads**     - List all user payloads along with their descriptions\n\nCurrent Directory :\`$cwd >\`\",
              \"color\": 65280
            }
          ]
        }"        
        send_to_discord
        LOG green "Discord Session Connected"
    elif [ "$authenticated" = "1" ]; then
        LOG yellow "User Not Authenticated!"
        json_payload="{\"content\": \":octagonal_sign:   **User Not Authenticated!**  :octagonal_sign:\"}"
        send_to_discord
    else
        json_payload="{\"content\": \":octagonal_sign:   **Incorrect password!**  Please try again...  :octagonal_sign:\"}"
        send_to_discord
        LOG red "Session Code Incorrect!"
    fi
}

Option_List() {
        json_payload="{
          \"content\": \"\",
          \"embeds\": [
            {
              \"title\": \":link: **Options List** :link:\",
              \"description\": \"- **options**  - Show the additional commands list\n- **pause**    - Pause this session (re-authenticate to resume)\n- **background**  - Restart the payload in the background\n- **close**    - Close this session permanently\n- **sysinfo**    - Show basic system information and public IP address\n- **download**   - Send a file to Discord [download path/to/file.txt]\n- **upload**     - Upload file to Pager [attach to 'upload' command]\n- **readme**     - Show a readme file [readme path/to/README.md]\n- **payloads**     - List all user payloads along with their descriptions\n\n*You can also use regular Linux and Duckyscript commands. Large outputs are split into 2000 character chunks to avoid Discord limits. Only the authenticated userID can interact with this session* \",
              \"color\": 16777215
            }
          ]
        }"        
        send_to_discord
}

get_recent_message() {
    recent_message=$(curl -s -H "Authorization: Bot $token" "https://discord.com/api/v10/channels/$chan/messages?limit=1")
    user_id=$(echo "$recent_message" | grep -o '"author":{"id":"[^"]*' | grep -o '[^"]*$')
    bot_check=$(echo "$recent_message" | grep -o '"bot":true')
    if [ -n "$user_id" ] && [ -z "$bot_check" ]; then
        recent_message=$(echo "$recent_message" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -n 1)
        echo "$recent_message"
    else
        echo ""
    fi
}

sanitize_json() {
    sanitized_result="${1//\"/\\\"}"
    sanitized_result="${sanitized_result//\\/\\\\}"
    sanitized_result="${sanitized_result//\\n/\\\\n}"
    sanitized_result="${sanitized_result//\\ / }"
    echo "$sanitized_result"
}

get_linux_info() {
    os_info=$(uname -a)
    kernel_version=$(uname -r)
    uptime=$(uptime -p)
    cpu_info=$(cat /proc/cpuinfo | grep "model name" | head -n 1 | cut -d ":" -f 2 | sed 's/^[ \t]*//')
    mem_info=$(free -h | grep "Mem" | awk '{print "Total: " $2, " Used: " $3}')
    disk_info=$(df -h --total | grep "total" | awk '{print "Total disk space: " $2, " Used: " $3}')
    public_ip=$(curl -s https://api.ipify.org)
    
    linux_info="OS Info: $os_info\nKernel Version: $kernel_version\nUptime: $uptime\nCPU: $cpu_info\nMemory: $mem_info\nDisk: $disk_info\nPublic IP: $public_ip"
    echo "$linux_info"
}

send_file_to_discord() {
    local file_path="$1"
    local token="$token"
    local chan="$chan"
    
    if [ -z "$file_path" ]; then
        echo "Error: File path not provided."
        return 1
    fi
    
    if [ ! -f "$file_path" ]; then
        echo "Error: File does not exist at $file_path."
        return 1
    fi
    
    local file_name=$(basename "$file_path")

    curl -X POST -H "Authorization: Bot $token" -F "file=@$file_path;filename=$file_name" "https://discord.com/api/v10/channels/$chan/messages" >/dev/null
}

download_attachment() {

    recent_message=$(curl -s -H "Authorization: Bot $token" "https://discord.com/api/v10/channels/$chan/messages?limit=1")
    user_id=$(echo "$recent_message" | grep -o '"author":{"id":"[^"]*' | grep -o '[^"]*$')
    bot_check=$(echo "$recent_message" | grep -o '"bot":true')
    if [ -n "$user_id" ] && [ -z "$bot_check" ]; then
        echo ""
    else
        echo ""
    fi

    attachment_url=$(echo "$recent_message" | grep -oE 'https://cdn\.discordapp\.com/attachments/[^"]+')
    if [ -n "$attachment_url" ]; then
        echo "Received 'download' command with attachment URL: $attachment_url"
        
        # Extract the filename from the URL
        file_name=$(basename "$attachment_url")

        # Download the file using curl
        curl -O -J -L "$attachment_url"
        
        # Check if the download was successful
        if [ $? -eq 0 ]; then
            echo "File downloaded successfully: $file_name"
        else
            echo "Error downloading file from URL: $attachment_url"
        fi
    else
        echo "No attachment found or invalid command for download."
    fi
}

execute_command() {
    command_result=$(eval "$1" 2>&1)
    recent_message=$(curl -s -H "Authorization: Bot $token" "https://discord.com/api/v10/channels/$chan/messages?limit=1")
    current_user_id=$(echo "$recent_message" | grep -o '"author":{"id":"[^"]*' | grep -o '[^"]*$')
    if [ "$authenticated" -eq 1 ] && [ "$current_user_id" = "$auth_user_id" ]; then
        command="$1"
        command_args="${command#* }"

        if [ "$1" == "close" ]; then
            LOG "Closing Session..."
            echo "Received 'close' command. Exiting Session..."
            json_payload="{
              \"content\": \"\",
              \"embeds\": [
                {
                  \"title\": \":octagonal_sign:   **Session Closed**   :octagonal_sign:\",
                  \"description\": \"**This session has ended..**\",
                  \"color\": 16711680
                }
              ]
            }"        
            send_to_discord
            Sleep 1
            LOG red "Session Closed!"
            exit 0
        fi

        if [ "$1" == "pause" ]; then
            LOG "Pause Command Received"
            echo "Received 'pause' command. Pausing Session..."
            authenticated=0
            json_payload="{
              \"content\": \"\",
              \"embeds\": [
                {
                  \"title\": \":pause_button:   **Session Paused**  :pause_button:\",
                  \"description\": \"Enter Session Code to Reconnect\",
                  \"color\": 16776960
                }
              ]
            }" 
            send_to_discord
	    LOG ""
	    LOG yellow "Session Waiting..."
            return
        fi

        if [ "$1" == "upload" ]; then
            LOG "Upload Command Received"
            echo "Received 'Upload' command."
            command="$1"
            download_attachment
            json_payload="{\"content\": \":white_check_mark:   **File Uploaded to Pager**   :white_check_mark:\"}"
            send_to_discord
            return
        fi

        if [ "$1" == "options" ]; then
            LOG "Options Command Received"
            echo "Received 'Options' command."
            Option_List
            return
        fi

        if [ "$1" == "background" ]; then
            LOG "Background Command Received"
            echo "Received 'Background' command."
            Background_Session
            return
        fi

        if [[ "$command" == "download"* && -n "$command_args" ]]; then
            LOG "Download Command Received"
            echo "Received 'download' command with file path: $command_args"
            send_file_to_discord "$command_args"
            json_payload="{\"content\": \":white_check_mark:   **File Downloaded from Pager**   :white_check_mark:\"}"
            send_to_discord
            return
        fi


        if [ "$1" == "sysinfo" ]; then
            LOG "Sysinfo Command Received"
            echo "Received 'sysinfo' command. Retrieving system information..."
            case "$(uname -s)" in
                Linux*)  sys_info=$(get_linux_info);;
                *)       sys_info="Unsupported OS" ;;
            esac
            json_payload="{\"content\": \"\`\`\`$sys_info\`\`\`\"}"
            send_to_discord
            return
        fi


        if [[ "$command" == "payloads"* ]]; then
            LOG "Payloads List Command Received"
        
            payload_root="/mmc/root/payloads/user"
            tmp_out="$(mktemp)"
        
            _trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
        
        
            {
                echo "# Payloads List"
                echo
        
                if [[ ! -d "$payload_root" ]]; then
                    echo "[ERROR] Directory not found: $payload_root"
                else
                    shopt -s nullglob
        
                    for category_path in "$payload_root"/*; do
                        [[ -d "$category_path" ]] || continue
                        category_name="$(basename "$category_path")"
        
                        echo "\`\`\`============= $category_name =============\`\`\`"
                        found_any=0
                        idx=0
        
                        for payload_dir in "$category_path"/*; do
                            [[ -d "$payload_dir" ]] || continue
                            payload_name="$(basename "$payload_dir")"
                            payload_file="$payload_dir/payload.sh"
                            [[ -f "$payload_file" ]] || continue
                            found_any=1
                            idx=$((idx+1))
                            title="$(grep -m1 -E '^[[:space:]]*#[[:space:]]*Title:' "$payload_file" | sed -E 's/^[[:space:]]*#[[:space:]]*Title:[[:space:]]*//')"
                            desc="$(grep -m1 -E '^[[:space:]]*#[[:space:]]*Description:' "$payload_file" | sed -E 's/^[[:space:]]*#[[:space:]]*Description:[[:space:]]*//')"
                            title="$(printf "%s" "$title" | _trim)"
                            desc="$(printf "%s" "$desc" | _trim)"
                            if [[ -z "$title" ]]; then
                                title="$payload_name"
                            fi
                            if [[ -z "$desc" ]]; then
                                desc="No Description Found"
                            fi
                            echo "\`$idx\` **$title** — $desc"
                        done
                        if [[ $found_any -eq 0 ]]; then
                            echo "No Payloads Found"
                        fi
                        echo
                    done
                    shopt -u nullglob
                fi
            } > "$tmp_out"
        
            accumulated_lines=""
            while IFS= read -r line; do
                if [ $((${#accumulated_lines} + ${#line} + 1)) -gt 1900 ]; then
                    json_payload=$(jq -n --arg content "$accumulated_lines" '{content: $content}')
                    send_to_discord
                    accumulated_lines="$line"
                    sleep 1
                else
                    if [[ -z "$accumulated_lines" ]]; then
                        accumulated_lines="$line"
                    else
                        accumulated_lines+=$'\n'"$line"
                    fi
                fi
            done < "$tmp_out"
            if [ -n "$accumulated_lines" ]; then
                json_payload=$(jq -n --arg content "$accumulated_lines" '{content: $content}')
                send_to_discord
            fi
            rm -f "$tmp_out"
            return
        fi


        if [[ "$command" == "readme"* && -n "$command_args" ]]; then
            LOG "Readme Command Received"
            readme_result=$(cat -- "$command_args" 2>&1)
            if [ -n "$readme_result" ]; then
                temp_file=$(mktemp)
                echo "$readme_result" > "$temp_file"
                accumulated_lines=""
                while IFS= read -r line; do
                    if [ $((${#accumulated_lines} + ${#line})) -gt 1900 ]; then
                        json_payload=$(jq -n --arg content "$accumulated_lines" '{content: $content}')
                        send_to_discord
                        accumulated_lines="$line"
                        sleep 1
                    else
                        accumulated_lines+=$'\n'"$line"
                    fi
                done < "$temp_file"
    
                if [ -n "$accumulated_lines" ]; then
                    json_payload=$(jq -n --arg content "$accumulated_lines" '{content: $content}')
                    send_to_discord
                fi
                rm "$temp_file"
            fi
            return
        else
            error_message=$(echo "$readme_result" | tr -d '\n' | sed 's/"/\\"/g')
            json_payload="{\"content\": \"$readme_result\"}"
            send_to_discord          
        fi        
        
        if [ $? -eq 0 ]; then
            if [ -n "$command_result" ]; then
                LOG "Shell Command Received"
                temp_file=$(mktemp)
                echo "$command_result" > "$temp_file"
                accumulated_lines=""
                while IFS= read -r line; do
                    sanitized_line=$(sanitize_json "$line")
                    if [ $((${#accumulated_lines} + ${#sanitized_line})) -gt 1900 ]; then
                        json_payload="{\"content\": \"\`\`\`$accumulated_lines\`\`\`\"}"
                        send_to_discord
                        accumulated_lines="$sanitized_line"
                        sleep 1
                    else
                        accumulated_lines="$accumulated_lines\n$sanitized_line"
                    fi
                done < "$temp_file"
    
                if [ -n "$accumulated_lines" ]; then
                    json_payload="{\"content\": \"\`\`\`$accumulated_lines\`\`\`\"}"
                    send_to_discord
                fi
                rm "$temp_file"
            else
                cwd=$(pwd)
	        json_payload="{
	          \"content\": \"\",
	          \"embeds\": [
	            {
	              \"title\": \":white_check_mark:   **Command Executed**   :white_check_mark:\",
	              \"description\": \"Current Directory :\`$cwd >\`\",
	              \"color\": 65280
	            }
	          ]
	        }"
                send_to_discord
            fi
            return
        else
            error_message=$(echo "$command_result" | tr -d '\n' | sed 's/"/\\"/g')
            json_payload="{\"content\": \"$command_result\"}"
            send_to_discord
        fi
    else
        Authenticate
    fi
}

Main_Loop() {
while true; do
    recent_message=$(get_recent_message)
    if [[ ! -z $recent_message && $recent_message != $(cat $last_command_file 2>/dev/null) ]]; then
        if [[ "$recent_message" =~ ^cd\  ]]; then
            cd_command=$(echo "$recent_message" | awk '{print $2}')
            cd "$cd_command"
            execute_command "pwd"
        else
            execute_command "$recent_message"
        fi
        echo "$recent_message" > $last_command_file
    fi
    sleep 1
done
}


LOG blue "4 : Starting Connection..."

authenticated=0
auth_user_id=""
current_user_id=""
last_command_file=$(mktemp)

json_payload="{
  \"content\": \"\",
  \"embeds\": [
    {
      \"title\": \":hourglass: Session Waiting :hourglass:\",
      \"description\": \"**Enter Your Password Below**\",
      \"color\": 16776960
    }
  ]
}"


RUN_MODE="fg"
if [ "${1:-}" = "--bg" ]; then
  RUN_MODE="bg"
fi


if [ "$RUN_MODE" = "bg" ]; then

json_payload="{
  \"content\": \"\",
  \"embeds\": [
    {
      \"title\": \":hourglass: Session Waiting :hourglass:\",
      \"description\": \"**Enter Your Password Below** \n-# You can change this in \`.env\` in your /pagecord directory \",
      \"color\": 16776960
    }
  ]
}"

    ALERT "+===========================+ \n| ------- PageCord -------- | \n| - Discord Pager Control - | \n+========== v1.3 ===========+ \n\n-==- Background Mode -==- \n---------- Started ----------"
    password="$pass"

else

    bgresp=$(CONFIRMATION_DIALOG "Run Pagecord in backgound?")
    case $? in
        $DUCKYSCRIPT_REJECTED)
            LOG "Dialog rejected"
            exit 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LOG "An error occurred"
            exit 1
            ;;
    esac
    case "$bgresp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            LOG green "Background Session Starting.."
            echo "Background Session Starting.."
            Background_Session
            return
            ;;
    
        $DUCKYSCRIPT_USER_DENIED)
            LOG green "Background prompt rejected."
            ;;
        *)
        LOG "Unknown response: $bgresp"
        exit 1
        ;;
    esac
    
    json_payload="{
      \"content\": \"\",
      \"embeds\": [
        {
          \"title\": \":hourglass: Session Waiting :hourglass:\",
          \"description\": \"**Enter Your Session Code** \n-# Displayed on your WiFi Pineapple Pager\",
          \"color\": 16776960
        }
      ]
    }"

    random_letters=$(generate_random_letters)
    password="${password}${random_letters}"
    LOG ""
    LOG green "-==- Foreground Mode -==-"
    LOG ""
    LOG cyan "+=======================+"
    LOG cyan "| SESSION CODE : $password |"
    LOG cyan "+=======================+"

fi


# Send Discord message and get status
HTTP_STATUS=$(curl -s -o /tmp/pagecord_response.json -w "%{http_code}" -X POST -H "Authorization: Bot $token" -H "Content-Type: application/json" -d "$json_payload" "https://discord.com/api/v10/channels/$chan/messages")
if [[ $? -ne 0 ]]; then
    LOG red "curl command failed to execute."
    exit 1
fi
if [[ "$HTTP_STATUS" -ne 200 && "$HTTP_STATUS" -ne 201 ]]; then
    LOG red "Discord connection failed (HTTP $HTTP_STATUS)"
    LOG yellow "Are your bot credentials correct?"
    LOG yellow "Is Client Mode ON and connected?"
    cat /tmp/pagecord_response.json
    exit 1
fi

LOG ""
LOG green "Setup Complete"
LOG yellow "Session Waiting..."

# ----------- Start main loop -----------
Main_Loop
