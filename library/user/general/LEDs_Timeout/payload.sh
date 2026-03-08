#!/bin/bash
# Title: LED's_Timeout
# Description: Auto-disable LED when screen dims/turns off to save battery
# Author: Z3r0L1nk
# Version: 1.0.0

INIT_SCRIPT="/etc/init.d/leds_timeout"
BIN_SCRIPT="/usr/bin/LEDS_TIMEOUT"

install_service() {
    LED SETUP
    LOG "Installing LED's Timeout service..."

    # Create init.d service
    cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common
START=51
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/LEDS_TIMEOUT
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x "$INIT_SCRIPT"

    # Create main script
    cat > "$BIN_SCRIPT" << 'EOF'
#!/bin/bash

DIM_BRIGHTNESS=$(uci get system.@pager[0].dim_brightness 2>/dev/null || echo 6)
LCD_BRIGHTNESS="/sys/class/backlight/backlight_pwm/brightness"
LED_B="/sys/class/leds/b-button-led/brightness"

get_led_color() {
    uci get system.@pager[0].led_color 2>/dev/null || echo "cyan"
}

led_b_on() {
    echo 1 > "$LED_B" 2>/dev/null
}

led_b_off() {
    echo 0 > "$LED_B" 2>/dev/null
}

control_led() {
    local led_state="unknown"
    local last_brightness=-1
    
    DPADLED "$(get_led_color)" 2>/dev/null
    led_b_on
    led_state="on"
    
    while true; do
        if [ -f "$LCD_BRIGHTNESS" ]; then
            current_brightness=$(cat "$LCD_BRIGHTNESS" 2>/dev/null || echo 0)
            
            if [ "$current_brightness" != "$last_brightness" ]; then
                if [ $current_brightness -gt $DIM_BRIGHTNESS ]; then
                    if [ "$led_state" != "on" ]; then
                        DPADLED "$(get_led_color)" 2>/dev/null
                        led_b_on
                        led_state="on"
                    fi
                else
                    if [ "$led_state" != "off" ]; then
                        DPADLED off 2>/dev/null
                        led_b_off
                        led_state="off"
                    fi
                fi
                last_brightness=$current_brightness
            fi
        fi
        
        sleep 0.5
    done
}

control_led
EOF
    chmod +x "$BIN_SCRIPT"

    # Enable and start
    "$INIT_SCRIPT" enable
    "$INIT_SCRIPT" start

    LED FINISH
    LOG "LED's Timeout service installed and started!"
}

uninstall_service() {
    LED SETUP
    LOG "Uninstalling LED's Timeout service..."

    # Stop and disable
    if [ -f "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null
        "$INIT_SCRIPT" disable 2>/dev/null
        rm -f "$INIT_SCRIPT"
    fi

    # Remove script
    rm -f "$BIN_SCRIPT"

    # Restore LED to default
    LED_COLOR=$(uci get system.@pager[0].led_color 2>/dev/null || echo "cyan")
    DPADLED "$LED_COLOR" 2>/dev/null
    echo 1 > /sys/class/leds/b-button-led/brightness 2>/dev/null

    LED FINISH
    LOG "LED's Timeout service uninstalled!"
}

check_status() {
    if [ -f "$INIT_SCRIPT" ] && [ -f "$BIN_SCRIPT" ]; then
        if pgrep -f "LEDS_TIMEOUT" > /dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not_installed"
    fi
}

# Main UI
LED SETUP
STATUS=$(check_status)

case "$STATUS" in
    "running")
        if [ "$(CONFIRMATION_DIALOG "LED's Timeout is RUNNING. Uninstall?")" == "1" ]; then
            uninstall_service
        else
            LOG "No changes made."
        fi
        ;;
    "stopped")
        if [ "$(CONFIRMATION_DIALOG "Service stopped. YES=Start, NO=Uninstall")" == "1" ]; then
            "$INIT_SCRIPT" start
            LED FINISH
            LOG "Service started!"
        else
            uninstall_service
        fi
        ;;
    "not_installed")
        if [ "$(CONFIRMATION_DIALOG "Install LED's Timeout service?")" == "1" ]; then
            install_service
        else
            LOG "Installation cancelled."
        fi
        ;;
esac
