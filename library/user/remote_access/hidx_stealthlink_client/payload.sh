
#!/bin/bash
# Title: HIDX Stealthlink
# Author: spencershepard (GRIMM)
# Description: Starts the HIDX Stealthlink client service, which auto connects to O.MG devices configured with Stealthlink
# Version: 1.0

# See the README for instructions on setting up Stealthlink.

# Check for required packages
REQUIRED_PACKAGES=(python3 tmux)
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! opkg list-installed | grep -q "^$pkg "; then
        LOG "$pkg is not installed. Prompting user to confirm installation..."
        resp=$(CONFIRMATION_DIALOG "$pkg is required. Install it?")
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
                LOG "User confirmed $pkg installation. Proceeding..."
                ;;
            $DUCKYSCRIPT_USER_DENIED)
                LOG "User denied $pkg installation. Exiting."
                exit 1
                ;;
            *)
                LOG "Unknown response: $resp. Exiting."
                exit 1
                ;;
        esac
        LOG "Installing $pkg..."
        opkg update
        opkg install $pkg || {
            ERROR_DIALOG "Failed to install $pkg. Exiting."
            exit 1
        }
        LOG "$pkg installed successfully."
    else
        LOG "$pkg is already installed."
    fi
done

# Start the HIDX Stealthlink Client in a named tmux session
SESSION="hidx"
if tmux has-session -t "$SESSION" 2>/dev/null; then
    LOG yellow "Stealthlink client is already running in tmux session '$SESSION'.\n\nTo attach (SSH): tmux a -t $SESSION\nTo stop: kill the tmux session (tmux kill-session -t $SESSION)\n\nLogs are in /root/loot/"
    exit 0
fi

LOG "Starting HIDX Stealthlink Client in tmux session '$SESSION'..."
tmux new-session -d -s "$SESSION" 'python3 ./stealthlink-client-pager.py 0.0.0.0 1234'
if tmux has-session -t "$SESSION" 2>/dev/null; then
    LOG green "Stealthlink client started!\n\nTo attach (SSH): tmux a -t $SESSION\nTo stop: kill the tmux session (tmux kill-session -t $SESSION)\n\nLogs are in /root/loot/"
else
    ERROR_DIALOG "Failed to start Stealthlink client in tmux session."
    exit 1
fi
