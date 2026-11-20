# ============================================================
# Flock Lab Simulator - Pen Test Payload
# For Arduino Nano ESP32 (ESP32-S3) + MicroPython v1.27.0
# ============================================================
#
# CREDITS & SOURCES:
#
#   Ryan O'Horo (@ryanohoro)
#     - Flock Safety Falcon camera teardown & RF analysis
#     - Identified Lite-On chipset OUIs, WiFi SSID naming
#       schemes, Penguin battery BLE signatures, and
#       XUNTONG (0x09C8) manufacturer ID
#     - https://www.ryanohoro.com/post/spotting-flock-safety-s-falcon-cameras
#
#   ColonelPanic (colonelpanic.tech)
#     - Flock-You detection firmware & OUI-SPY hardware
#     - Crowdsourced MAC prefix database, BLE device name
#       pattern matching, and detection methodology
#     - https://github.com/colonelpanichacks/flock-you
#     - https://github.com/colonelpanichacks/oui-spy
#
#   Will Greenberg (@wgreenberg)
#     - BLE manufacturer company ID detection (0x09C8 XUNTONG)
#     - Sourced from his flock-you fork
#
#   0xD34D
#     - flock-spoof: ESP32 spoofing reference for Flock Safety,
#       Penguin, Pigvision, and Raven device profiles
#     - https://github.com/0xD34D/flock-spoof
#
#   DeFlock / FoggedLens (deflock.me)
#     - Crowdsourced ALPR location data and detection
#       methodologies; MAC prefix datasets
#
#   GainSec
#     - Raven BLE service UUID dataset for SoundThinking/
#       ShotSpotter acoustic surveillance device detection
#
#   EFF (Electronic Frontier Foundation)
#     - "How to Defeat Flock" research and analysis
#     - https://www.eff.org/deeplinks/2024/04/defeat-flock
#
# LICENSE: For authorized security research and educational
#          purposes only. Ensure compliance with all applicable
#          laws in your jurisdiction.
# ============================================================

import bluetooth
import struct
import time
import network
import random
from machine import Pin

# --- Arduino Nano ESP32 onboard RGB LED ---
# Common anode: LOW = ON, HIGH = OFF
# Red=GPIO46, Green=GPIO0, Blue=GPIO45
led_r = Pin(46, Pin.OUT)
led_g = Pin(0, Pin.OUT)
led_b = Pin(45, Pin.OUT)

led_r.value(1)
led_g.value(1)
led_b.value(1)

def set_led(r, g, b):
    led_r.value(0 if r else 1)
    led_g.value(0 if g else 1)
    led_b.value(0 if b else 1)

# --- LED colors matching Flock-You v9.15 detector key ---
COLORS = {
    "battery":   (1, 1, 0),  # Yellow  = R+G
    "penguin":   (0, 1, 0),  # Green   = G
    "pigvision": (1, 0, 1),  # Magenta = R+B
    "flock":     (0, 1, 1),  # Cyan    = G+B
}

# --- Device profiles ---
# (tag, ble_name_prefix, ssid_prefix, oui)
# OUIs: Lite-On Technology, confirmed from Falcon camera QR
# codes, Penguin battery packet captures, and deflock.me datasets
PROFILES = [
    ("battery",   "FS Ext Battery-", "FS_PROD_",   b'\x00\x0c\xbf'),
    ("penguin",   "Penguin-",        "PENGUIN_",    b'\x00\x1e\xc0'),
    ("pigvision", "Pigvision-",      "PIGVISION_",  b'\x74\x4c\xa1'),
    ("flock",     "flock-",          "flock-",      b'\xe0\x7e\x67'),
    ("battery",   "FS Ext Battery-", "FS_PROD_",    b'\x9c\x2f\x9d'),
    ("penguin",   "Penguin-",        "PENGUIN_",    b'\xd8\xa0\xd8'),
    ("flock",     "flock-",          "flock-",      b'\xac\xe0\x10'),
]

ble = bluetooth.BLE()
ap = network.WLAN(network.AP_IF)

def get_payload(name):
    """Build BLE adv data: Flags + Name + XUNTONG mfr ID (max 31 bytes)"""
    nb = name.encode()
    max_n = 31 - 10  # 3 flags + 2 name hdr + 5 mfr block
    if len(nb) > max_n:
        nb = nb[:max_n]
    adv = b'\x02\x01\x06'
    adv += struct.pack('B', len(nb) + 1) + b'\x09' + nb
    adv += b'\x04\xff\xc8\x09\x01'  # XUNTONG 0x09C8 manufacturer specific
    return adv

def rotate():
    p = random.choice(PROFILES)
    tag, npfx, spfx, oui = p[0], p[1], p[2], p[3]

    raw = bytes([random.getrandbits(8) for _ in range(3)])
    hx = ''.join(['%02x' % x for x in raw]).upper()

    mac = oui + raw
    nm = npfx + hx[:4]
    ssid = spfx + hx

    # LED matches detector color key
    c = COLORS.get(tag, (0, 0, 0))
    set_led(c[0], c[1], c[2])

    # Reset radios
    try:
        ble.gap_advertise(None)
    except:
        pass
    ble.active(False)
    ap.active(False)
    time.sleep_ms(200)

    # WiFi AP - sets base MAC on ESP32-S3
    ap.active(True)
    try:
        ap.config(mac=mac, essid=ssid)
    except:
        ap.config(essid=ssid)
    time.sleep_ms(200)

    # BLE - random static addr mode for MAC override
    ble.active(True)
    time.sleep_ms(200)
    try:
        ble.config(addr_mode=1, gap_name=nm)
    except:
        try:
            ble.config(gap_name=nm)
        except:
            pass

    # Advertise at 318.75ms interval (non-connectable)
    ble.gap_advertise(318750, adv_data=get_payload(nm), connectable=False)

    mac_str = ':'.join(['%02x' % x for x in mac])
    print("[" + tag.upper() + "] " + mac_str + " | " + nm + " | " + ssid)

# --- Main ---
print("Flock Lab Simulator - Identity Rotation + LED")
print("Credits: O'Horo, ColonelPanic, Greenberg, 0xD34D, DeFlock, GainSec, EFF")
set_led(1, 1, 1)  # White = boot
time.sleep(1)
set_led(0, 0, 0)

while True:
    rotate()
    time.sleep(20)
