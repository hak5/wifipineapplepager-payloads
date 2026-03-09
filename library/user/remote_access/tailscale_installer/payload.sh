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
TAILSCALE_VERSION=""

# Installation paths
INSTALL_DIR="/mmc/tailscale/bin"
SYMLINK_DIR="/usr/sbin"
INIT_SCRIPT="/etc/init.d/tailscaled"
CONFIG_DIR="/etc/tailscale"
STATE_DIR="/root/.tailscale"
TMP_DIR="/root/tailscale_install"

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
    TAILSCALE_VERSION=$(get_latest_version)

    if [ -z "$TAILSCALE_VERSION" ]; then
        ERROR_DIALOG "Could not determine version"
        LOG red "ERROR: Failed to detect Tailscale version"
        exit 1
    fi

    LOG "Will install Tailscale version: $TAILSCALE_VERSION"

    # Use /mmc only to reduce RAM pressure
    if [ ! -d "/root" ] || [ ! -w "/root" ]; then
        ERROR_DIALOG "/root not available"
        LOG red "ERROR: /root is not present or not writable; cannot proceed without /root"
        exit 1
    fi

    LOG "Creating temporary directory..."
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || exit 1

    local filename="tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}.tgz"
    local url="${TAILSCALE_BASE_URL}/${filename}"

    LOG "Downloading Tailscale ${TAILSCALE_VERSION} for ${TAILSCALE_ARCH}..."
    LOG "URL: $url"
    local spinner_id=$(START_SPINNER "Downloading")

    if ! nice -n -5 wget -q "$url" -O "$filename"; then
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

    local extract_dir_name="tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}"
    LOG "Extracting binaries into $TMP_DIR..."
    LOG "Running: tar -xzf $filename -C $TMP_DIR ${extract_dir_name}/tailscale ${extract_dir_name}/tailscaled"

    # Avoid piping tar output through LOG on low-powered devices; it can block and freeze.
    # Capture output to a temp log file and only dump it on error.
    local tar_log="$TMP_DIR/tar_extract.log"
    if ! nice -n -5 tar -xzf "$filename" -C "$TMP_DIR" \
        "${extract_dir_name}/tailscale" \
        "${extract_dir_name}/tailscaled" >"$tar_log" 2>&1; then
        ERROR_DIALOG "Extraction failed"
        LOG red "ERROR: Failed to extract $filename"
        LOG "tar output:"
        while read line; do LOG "$line"; done < "$tar_log"
        LOG "Checking file type:"
        file "$filename" 2>&1 | while read line; do LOG "$line"; done
        cleanup
        exit 1
    fi

    LOG green "Extraction complete"
}

install_binaries() {
    LOG "Installing Tailscale binaries..."

    # Binaries were extracted under $TMP_DIR/tailscale_<version>_<arch>
    local extract_dir="$TMP_DIR/tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}"
    if [ ! -d "$extract_dir" ]; then
        ERROR_DIALOG "Extracted files not found"
        LOG red "ERROR: Expected extracted directory missing: $extract_dir"
        LOG "Available directories:"
        find "$TMP_DIR" -type d 2>&1 | while read line; do LOG "$line"; done
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

    mkdir -p "$INSTALL_DIR"
    # Verify install directory is writable by creating a temp file
    local install_test="$INSTALL_DIR/.tailscale_write_test"
    if ! touch "$install_test" 2>/dev/null; then
        ERROR_DIALOG "Install directory not writable"
        LOG red "ERROR: $INSTALL_DIR is not writable"
        cleanup
        exit 1
    fi
    rm -f "$install_test" 2>/dev/null

    LOG "Both binaries found, copying into $INSTALL_DIR..."
    LOG "Copying from: $extract_dir"
    LOG "Source directory listing:"
    ls -l "$extract_dir" 2>&1 | while read line; do LOG "$line"; done
    if ! cp -f "$extract_dir/tailscale" "$INSTALL_DIR/tailscale"; then
        ERROR_DIALOG "Failed to copy tailscale binary"
        LOG red "ERROR: Failed to copy $extract_dir/tailscale to $INSTALL_DIR/"
        cleanup
        exit 1
    fi
    if ! cp -f "$extract_dir/tailscaled" "$INSTALL_DIR/tailscaled"; then
        ERROR_DIALOG "Failed to copy tailscaled binary"
        LOG red "ERROR: Failed to copy $extract_dir/tailscaled to $INSTALL_DIR/"
        cleanup
        exit 1
    fi
    LOG green "✓ Both binaries copied successfully"

    # Set permissions
    LOG "Setting executable permissions..."
    chmod +x "$INSTALL_DIR/tailscale"
    chmod +x "$INSTALL_DIR/tailscaled"

    # Create/update symlinks in /usr/sbin
    if [ ! -w "$SYMLINK_DIR" ]; then
        ERROR_DIALOG "Symlink directory not writable"
        LOG red "ERROR: $SYMLINK_DIR is not writable"
        cleanup
        exit 1
    fi
    ln -sf "$INSTALL_DIR/tailscale" "$SYMLINK_DIR/tailscale"
    ln -sf "$INSTALL_DIR/tailscaled" "$SYMLINK_DIR/tailscaled"

    LOG green "Binaries installed successfully"

    # Cleanup extracted directory within TMP_DIR
    rm -f "$extract_dir/tailscale" "$extract_dir/tailscaled" 2>/dev/null
    rmdir "$extract_dir" 2>/dev/null
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
