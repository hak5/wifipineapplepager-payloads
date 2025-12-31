#!/bin/bash
# Title: Tailscale Installer
# Description: Install and configure Tailscale
# Author: JAKONL
# Version: 1.0
#
# This payload installs Tailscale VPN on the Pager, enabling secure remote access
# from anywhere. Supports both interactive authentication and auth key setup.
#
# LED State Descriptions:
# Cyan Blink - Downloading Tailscale
# Amber Blink - Installing binaries
# Green Solid - Installation successful
# Red Blink - Installation failed

LOG "=== Tailscale Installer ==="
LOG "Starting installation process..."
LOG ""
LOG "System Architecture: $(uname -m)"
LOG ""
LOG "📋 Detailed logs are available via:"
LOG "   - Pager UI: Check the payload logs"
LOG "   - SSH: logread | grep -i tailscale"
LOG "   - SSH: logread | tail -n 100"
LOG ""

# ============================================
# CONFIGURATION
# ============================================

# Tailscale architecture and repository
# Auto-detect architecture, fallback to mipsle
DEVICE_ARCH=$(uname -m)
case "$DEVICE_ARCH" in
    mips|mipsel)
        TAILSCALE_ARCH="mipsle"
        ;;
    *)
        # Default to mipsle for WiFi Pineapple
        TAILSCALE_ARCH="mipsle"
        ;;
esac

TAILSCALE_BASE_URL="https://pkgs.tailscale.com/stable"

# Installation paths
INSTALL_DIR="/usr/sbin"
INIT_SCRIPT="/etc/init.d/tailscaled"
CONFIG_DIR="/etc/tailscale"
STATE_DIR="/root/.tailscale"
TMP_DIR="/tmp/tailscale_install"

# Configuration file
CONFIG_FILE="$CONFIG_DIR/config"

# ============================================
# HELPER FUNCTIONS
# ============================================

cleanup() {
    LOG "Cleaning up temporary files..."
    rm -rf "$TMP_DIR"
}

check_installed() {
    if [ -f "$INSTALL_DIR/tailscale" ] && [ -f "$INSTALL_DIR/tailscaled" ]; then
        return 0
    fi
    return 1
}

get_latest_version() {
    LOG "Detecting latest Tailscale version..."

    # Try to get the latest version from the stable repository
    # The repository lists files, we'll parse for the latest mipsle package
    local version_list=$(wget -qO- "${TAILSCALE_BASE_URL}/" 2>/dev/null | \
        grep -o "tailscale_[0-9.]*_${TAILSCALE_ARCH}.tgz" | \
        grep -o "[0-9.]*" | \
        sort -V | \
        tail -n 1)

    if [ -z "$version_list" ]; then
        # Fallback: try to get version from the latest stable track
        LOG "Trying alternative version detection..."
        version_list=$(wget -qO- "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null | \
            grep -o '"Version":"[^"]*"' | \
            head -n 1 | \
            cut -d'"' -f4)
    fi

    if [ -z "$version_list" ]; then
        # Final fallback: use a known stable version
        LOG yellow "Could not detect latest version, using fallback"
        echo "1.92.3"
        return
    fi

    LOG "Latest version detected: $version_list"
    echo "$version_list"
}

# ============================================
# DOWNLOAD AND INSTALL
# ============================================

download_tailscale() {
    # Get the latest version
    local version=$(get_latest_version)

    if [ -z "$version" ]; then
        ERROR_DIALOG "Could not determine version"
        LOG red "ERROR: Failed to detect Tailscale version"
        exit 1
    fi

    LOG "Will install Tailscale version: $version"

    LOG "Creating temporary directory..."
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || exit 1

    local filename="tailscale_${version}_${TAILSCALE_ARCH}.tgz"
    local url="${TAILSCALE_BASE_URL}/${filename}"

    LOG "Downloading Tailscale ${version} for ${TAILSCALE_ARCH}..."
    LOG "URL: $url"
    local spinner_id=$(START_SPINNER "Downloading")

    if ! wget -q "$url" -O "$filename"; then
        STOP_SPINNER $spinner_id
        ERROR_DIALOG "Download failed. Check network connection."
        LOG red "ERROR: Failed to download from $url"
        cleanup
        exit 1
    fi

    STOP_SPINNER $spinner_id
    LOG green "Download complete"

    # Verify download
    LOG "Verifying downloaded file..."
    if [ ! -f "$filename" ]; then
        ERROR_DIALOG "Downloaded file not found"
        LOG red "ERROR: $filename does not exist after download"
        cleanup
        exit 1
    fi

    local filesize=$(ls -lh "$filename" | awk '{print $5}')
    LOG "Downloaded file size: $filesize"

    LOG "Extracting archive..."
    LOG "Running: tar -xzf $filename"

    if ! tar -xzf "$filename" 2>&1 | while read line; do LOG "$line"; done; then
        ERROR_DIALOG "Extraction failed"
        LOG red "ERROR: Failed to extract $filename"
        LOG "Checking file type:"
        file "$filename" 2>&1 | while read line; do LOG "$line"; done
        cleanup
        exit 1
    fi

    LOG green "Extraction complete"
}

install_binaries() {
    LOG "Installing Tailscale binaries..."

    # Find the extracted directory (exclude .tgz files, only find directories)
    LOG "Searching for extracted directory..."

    # Try multiple patterns to find the extracted directory
    local extract_dir=""

    # First try: Look for any subdirectory (most reliable)
    extract_dir=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | grep -v "\.tgz" | head -n 1)

    # Second try: Look specifically for tailscale_* directories
    if [ -z "$extract_dir" ]; then
        extract_dir=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name "tailscale_*" | head -n 1)
    fi

    # Third try: Look in any subdirectory for the binaries
    if [ -z "$extract_dir" ]; then
        LOG yellow "No obvious directory found, searching for binaries..."
        local binary_path=$(find "$TMP_DIR" -name "tailscale" -type f ! -name "*.tgz" | head -n 1)
        if [ -n "$binary_path" ]; then
            extract_dir=$(dirname "$binary_path")
            LOG "Found binaries in: $extract_dir"
        fi
    fi

    if [ -z "$extract_dir" ]; then
        ERROR_DIALOG "Extracted files not found"
        LOG red "ERROR: Could not find extracted directory in $TMP_DIR"
        LOG "Available directories:"
        find "$TMP_DIR" -type d 2>&1 | while read line; do LOG "$line"; done
        LOG "Available files:"
        find "$TMP_DIR" -type f 2>&1 | while read line; do LOG "$line"; done
        cleanup
        exit 1
    fi

    LOG green "Found extracted directory: $extract_dir"

    # Check if binaries exist in extracted directory
    if [ ! -f "$extract_dir/tailscale" ]; then
        ERROR_DIALOG "tailscale binary not found"
        LOG red "ERROR: $extract_dir/tailscale does not exist"
        cleanup
        exit 1
    fi

    if [ ! -f "$extract_dir/tailscaled" ]; then
        ERROR_DIALOG "tailscaled binary not found"
        LOG red "ERROR: $extract_dir/tailscaled does not exist"
        cleanup
        exit 1
    fi

    LOG "Both binaries found, copying to $INSTALL_DIR..."

    # Show file sizes (using ls since stat is not available on Pager)
    local tailscale_size_human=$(ls -lh "$extract_dir/tailscale" | awk '{print $5}')
    local tailscaled_size_human=$(ls -lh "$extract_dir/tailscaled" | awk '{print $5}')
    local tailscale_size_bytes=$(ls -l "$extract_dir/tailscale" | awk '{print $5}')
    local tailscaled_size_bytes=$(ls -l "$extract_dir/tailscaled" | awk '{print $5}')

    # Calculate total size for combined progress
    local total_size_bytes=$((tailscale_size_bytes + tailscaled_size_bytes))
    local total_size_mb=$((total_size_bytes / 1048576))

    LOG "tailscale binary size: $tailscale_size_human"
    LOG "tailscaled binary size: $tailscaled_size_human"
    LOG "Total size to copy: ${total_size_mb}MB"
    LOG yellow "Note: Moving binaries from TMP to Persistent takes ~10 minutes due to storage contraints..."
    LOG ""
    LOG "Copying binaries with combined progress..."
    LOG "Progress updates every 10 seconds..."

    # Copy tailscale binary in background
    cp "$extract_dir/tailscale" "$INSTALL_DIR/tailscale" &
    local cp_pid=$!

    # Monitor progress for both binaries combined
    local wait_count=0
    local copying_first=true

    while true; do
        sleep 10
        wait_count=$((wait_count + 5))

        # Calculate current total copied (both files)
        local tailscale_current=0
        local tailscaled_current=0

        if [ -f "$INSTALL_DIR/tailscale" ]; then
            tailscale_current=$(ls -l "$INSTALL_DIR/tailscale" 2>/dev/null | awk '{print $5}')
            [ -z "$tailscale_current" ] && tailscale_current=0
        fi

        if [ -f "$INSTALL_DIR/tailscaled" ]; then
            tailscaled_current=$(ls -l "$INSTALL_DIR/tailscaled" 2>/dev/null | awk '{print $5}')
            [ -z "$tailscaled_current" ] && tailscaled_current=0
        fi

        local total_current=$((tailscale_current + tailscaled_current))
        local total_current_mb=$((total_current / 1048576))

        # Calculate overall percentage
        if [ "$total_size_bytes" -gt 0 ]; then
            local percent=$((total_current * 100 / total_size_bytes))
            LOG "  Overall Progress: ${percent}% (${total_current_mb}MB / ${total_size_mb}MB) - ${wait_count}s elapsed"
        else
            LOG "  Copying... ${wait_count}s elapsed"
        fi

        # Check if first copy is done, start second copy
        if [ "$copying_first" = true ] && ! kill -0 $cp_pid 2>/dev/null; then
            # First copy finished, check if successful
            wait $cp_pid
            local cp_result=$?

            if [ $cp_result -ne 0 ]; then
                ERROR_DIALOG "Failed to copy tailscale binary"
                LOG red "ERROR: Failed to copy $extract_dir/tailscale to $INSTALL_DIR/"
                LOG "Checking permissions on $INSTALL_DIR:"
                ls -ld "$INSTALL_DIR" 2>&1 | while read line; do LOG "$line"; done
                cleanup
                exit 1
            fi

            LOG "  tailscale binary copied, continuing with tailscaled..."

            # Start second copy
            cp "$extract_dir/tailscaled" "$INSTALL_DIR/tailscaled" &
            cp_pid=$!
            copying_first=false
        fi

        # Check if second copy is done
        if [ "$copying_first" = false ] && ! kill -0 $cp_pid 2>/dev/null; then
            # Second copy finished
            wait $cp_pid
            local cp_result=$?

            if [ $cp_result -ne 0 ]; then
                ERROR_DIALOG "Failed to copy tailscaled binary"
                LOG red "ERROR: Failed to copy $extract_dir/tailscaled to $INSTALL_DIR/"
                cleanup
                exit 1
            fi

            # Both copies complete
            break
        fi
    done

    LOG ""
    LOG green "✓ Both binaries copied successfully (${wait_count}s total)"
    LOG ""

    # Set permissions
    LOG "Setting executable permissions..."
    chmod +x "$INSTALL_DIR/tailscale"
    chmod +x "$INSTALL_DIR/tailscaled"

    LOG green "Binaries installed successfully"
}

create_directories() {
    LOG "Creating configuration directories..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$STATE_DIR"
    LOG "Directories created"
}

create_init_script() {
    LOG "Creating init.d script..."
    
    cat > "$INIT_SCRIPT" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/tailscaled --state=/root/.tailscale/tailscaled.state --statedir=/root/.tailscale/ --socket=/var/run/tailscale/tailscaled.sock
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    /usr/sbin/tailscale down
}
INITEOF

    chmod +x "$INIT_SCRIPT"
    LOG "Init script created"
}

# ============================================
# MAIN INSTALLATION
# ============================================

main_install() {
    LOG "=== Tailscale Installation Started ==="
    
    # Check if already installed
    if check_installed; then
        resp=$(CONFIRMATION_DIALOG "Tailscale already installed. Reinstall?")
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "Installation cancelled"
                exit 0
                ;;
        esac
        
        case "$resp" in
            $DUCKYSCRIPT_USER_DENIED)
                LOG "User chose not to reinstall"
                exit 0
                ;;
        esac
    fi
    
    # Download and extract
    download_tailscale
    
    # Install binaries
    install_binaries
    
    # Create directories
    create_directories
    
    # Create init script
    create_init_script
    
    # Cleanup
    cleanup
    
    LOG "=== Installation Complete ==="
    LOG ""
    LOG green "✓ Tailscale binaries installed"
    LOG green "✓ Init script created"
    LOG green "✓ Directories configured"
    LOG ""
    LOG yellow "⚠ NEXT STEP REQUIRED:"
    LOG "Run the 'Tailscale Configure' payload to complete setup"
    LOG ""
    LOG "Navigate to:"
    LOG "  User Payloads → Remote Access → Tailscale Configure"
    LOG ""

    ALERT "Install complete! Run Tailscale Configure next"

    # Prompt user to continue
    PROMPT "Installation successful! Please run 'Tailscale Configure' payload next to complete setup."
}

# Execute installation
main_install
