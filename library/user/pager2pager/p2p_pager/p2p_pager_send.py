#!/usr/bin/env python3







# New version which interfaces with the main p2p pager system using a local socket to send messages to be broadcast in beacon frames. This allows for better integration with the message management system, including seen message tracking and decay handling.
import os


CONFIG_DIR = os.path.expanduser("~/.p2p_pager")
NETWORKS_CONFIG_FILE = os.path.join(CONFIG_DIR, "networks.conf")
CONFIG_FILE = os.path.join(CONFIG_DIR, "p2p_pager.conf")

# Load configuration
def load_config():
    """
    Load configuration settings for the P2P pager system from a file or use defaults.
    
    Reads configuration from CONFIG_FILE if it exists, otherwise uses default values.
    Each line in the config file should be in the format: key=value
    
    Configuration keys and their default values:
    - decay_time (float): Time in seconds before a message decays (default: 300)
    - beacon_interval (float): Interval in seconds between beacons (default: 102)
    - beacon_uptime (int): Duration in seconds a beacon is active (default: 10)
    - ssid_prefix (str): Prefix for SSID naming (default: "P2PAGER")
    - channel (int): WiFi channel to use (default: 6)
    - max_message_length (int): Maximum length of messages in characters (default: 50)
    - message_prefix (str): Prefix for message identification (default: "MSG:")
    - decay_prefix (str): Prefix for decay messages (default: "DECAY:")
    
    Returns:
        dict: Configuration dictionary with all settings. Values are converted to appropriate
              types (float, int, or str) based on the key name.
    """
    config = {
        "decay_time":300,
        "beacon_interval":102,
        "beacon_uptime":10,
        "ssid_prefix":"P2PAGER",
        "channel":6,
        "max_message_length":50,
        "message_prefix":"MSG:",
        "decay_prefix":"DECAY:"
    }
    if os.path.isfile(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            for line in f:
                key, value = line.strip().split('=')
                if key in config:
                    if key in ["beacon_interval", "broadcast_duration", "decay_time"]:
                        config[key] = float(value)
                    elif key == "max_message_length":
                        config[key] = int(value)
                    else:
                        config[key] = value
    return config



PORT = 89999
IP = "127.0.0.1"
import socket


def send_message_to_beacon(network:str, message:str, channel=None, decay_time=None):
    """Send a message to the beacon sender via local socket"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((IP, PORT))
        # Send message in format: network,message,channel:<channel>,decay_time:<decay_time>
        payload = f"{network},{message},channel:{channel if channel else ''},decay_time:{decay_time if decay_time else ''}"
        send_log(f"Sending message to beacon sender: {payload}")
        s.sendall(payload.encode('utf-8'))
        return_message = s.recv(1024)  # Wait for acknowledgment (not used currently)
        send_log(f"Received response from beacon sender: {return_message.decode('utf-8')}")
        s.close()

# Send log message to system
async def send_log(message):
    # Uses the "LOG" command to send a message to the system (e.g., for Pineapple Pager)
    os.system(f"LOG '{message}'")

def main():
    # argparse for command line usage
    global seen_messages, networks, ssid_prefix, channel, decay_time
    
    import argparse
    config = load_config()
    decay_time = config["decay_time"]
    beacon_interval = config["beacon_interval"]
    beacon_uptime = config["beacon_uptime"]
    ssid_prefix = config["ssid_prefix"]
    channel = config["channel"]
    max_message_length = config["max_message_length"]
    message_prefix = config["message_prefix"]
    decay_prefix = config["decay_prefix"]
    
    parser = argparse.ArgumentParser(description="Send a message to the P2P pager beacon sender")
    parser.add_argument('--network', type=str, default=None, help='Network SSID to use (without prefix)')
    parser.add_argument('--message', type=str, required=True, help='Message to send in beacon')
    parser.add_argument('--channel', type=int, default=None, help='WiFi channel to use for beacon (optional)')
    parser.add_argument('--decay_time', type=float, default=None, help='Custom decay time in seconds for this message (optional)')
    args = parser.parse_args()
    send_message_to_beacon(args.network, args.message, args.channel, args.decay_time)
    









# Old version of p2p_pager_send.py that sends custom messages in beacon frames using vendor-specific tag 221
#import select
#import socket
#import struct
#import time
#import os
#import random
#
## Sends beacon frames with custom messages using p2p pager system
#import argparse
#
#
## locations of important files
#CONFIG_DIR = os.path.expanduser("~/.p2p_pager")
#NETWORKS_CONFIG_FILE = os.path.join(CONFIG_DIR, "networks.conf")
#CONFIG_FILE = os.path.join(CONFIG_DIR, "p2p_pager.conf")
#SEEN_MESSAGES_FILE = os.path.join("/var", "seen_messages.db")
#
## Constants
#BEACON_INTERVAL = 0.102  # seconds between beacons
#REBROADCAST_DURATION = 10  # seconds to rebroadcast messages after starting
#DECAY_TIME = 300  # seconds before a message is considered "new" again
#VENDOR_IE_TAG = 221  # Vendor Specific IE tag
#MAX_MESSAGE_LENGTH = 200  # Max length of message to send
#INTERFACE = "wlan1mon"  # Monitor mode interface
#SSID_PREFIX = "P2PAGER"  # SSID prefix for networks
#
#DEST_ADDR = b'\xff\xff\xff\xff\xff\xff'  # Broadcast address
#RADIOTAP = struct.pack('<BBHI',
#    0,    # version
#    0,    # padding
#    8,    # length
#    0     # present flags
#)
#FRAME_CONTROL = struct.pack('<H', 0x80)  # Beacon frame
#DURATION = struct.pack('<H', 0)
#SEQ_CTRL = struct.pack('<H', 0)
#OUI = b'\x00\x50\xf2'  # Example OUI (Microsoft)
#OUI_TYPE = b'\x04'     # Example type
#PARTIAL_VENDOR_PAYLOAD = OUI + OUI_TYPE  # without message data
#
#
## Load configuration
#def load_config():
#    """
#    Load configuration settings for the P2P pager system from a file or use defaults.
#    
#    Reads configuration from CONFIG_FILE if it exists, otherwise uses default values.
#    Each line in the config file should be in the format: key=value
#    
#    Configuration keys and their default values:
#    - decay_time (float): Time in seconds before a message decays (default: 300)
#    - beacon_interval (float): Interval in seconds between beacons (default: 102)
#    - beacon_uptime (int): Duration in seconds a beacon is active (default: 10)
#    - ssid_prefix (str): Prefix for SSID naming (default: "P2PAGER")
#    - channel (int): WiFi channel to use (default: 6)
#    - max_message_length (int): Maximum length of messages in characters (default: 50)
#    - message_prefix (str): Prefix for message identification (default: "MSG:")
#    - decay_prefix (str): Prefix for decay messages (default: "DECAY:")
#    
#    Returns:
#        dict: Configuration dictionary with all settings. Values are converted to appropriate
#              types (float, int, or str) based on the key name.
#    """
#    config = {
#        "decay_time":300,
#        "beacon_interval":102,
#        "beacon_uptime":10,
#        "ssid_prefix":"P2PAGER",
#        "channel":6,
#        "max_message_length":50,
#        "message_prefix":"MSG:",
#        "decay_prefix":"DECAY:"
#    }
#    if os.path.isfile(CONFIG_FILE):
#        with open(CONFIG_FILE, 'r') as f:
#            for line in f:
#                key, value = line.strip().split('=')
#                if key in config:
#                    if key in ["beacon_interval", "rebroadcast_duration", "decay_time"]:
#                        config[key] = float(value)
#                    elif key == "max_message_length":
#                        config[key] = int(value)
#                    else:
#                        config[key] = value
#    return config
#
#def create_beacon_frame(ssid, bssid, channel, custom_vendor_data):
#    # 802.11 Beacon frame header
#    src_addr = bssid
#    bssid_addr = bssid
#
#    # Fixed parameters (beacon frame body)
#    # Zero timestamp to avoid rebuilding frame on every send (many receivers ignore it)
#    timestamp = struct.pack('<Q', 0)
#    beacon_interval = struct.pack('<H', 100)  # 100 TUs
#    capability = struct.pack('<H', 0x0421)  # ESS + Privacy
#
#    # Tagged parameters
#    # SSID tag (0)
#    ssid_tag = struct.pack('BB', 0, len(ssid)) + ssid.encode()
#
#    # Supported rates tag (1)
#    rates = b'\x82\x84\x8b\x96\x0c\x12\x18\x24'
#    rates_tag = struct.pack('BB', 1, len(rates)) + rates
#
#    # DS Parameter Set (channel) tag (3)
#    ds_tag = struct.pack('BBB', 3, 1, channel)
#
#    # Custom vendor-specific tag (221)
#    # Format: tag_number (1) | length (1) | OUI (3) | OUI type (1) | vendor data
#    vendor_payload = PARTIAL_VENDOR_PAYLOAD + custom_vendor_data
#    # length field is a single byte; truncate if necessary
#    if len(vendor_payload) > 255:
#        vendor_payload = vendor_payload[:255]
#    vendor_tag = struct.pack('BB', 221, len(vendor_payload)) + vendor_payload
#
#    # Assemble frame
#    beacon = (RADIOTAP + FRAME_CONTROL + DURATION + DEST_ADDR + src_addr +
#              bssid_addr + SEQ_CTRL + timestamp + beacon_interval + capability +
#              ssid_tag + rates_tag + ds_tag + vendor_tag)
#
#    return beacon
#
#    """
#    Asynchronously broadcast beacon frames with custom vendor data at specified intervals.
#    This function creates and sends IEEE 802.11 beacon frames over a specified wireless
#    interface. The beacons contain custom vendor data (tag 221) and are transmitted at
#    regular intervals for a specified duration.
#    Args:
#        interface (str): Network interface name (e.g., 'wlan0') to send beacons on.
#        ssid (str): Service Set Identifier (network name) to broadcast in beacon frames.
#        channel (int): WiFi channel number (1-14 for 2.4GHz, 36+ for 5GHz) to transmit on.
#        interval (float): Time in seconds between consecutive beacon transmissions.
#        uptime (float): Duration in seconds to send beacons. If <= 0, beacons are sent indefinitely.
#        custom_message (str, optional): Custom message to include in vendor data tag 221.
#            Defaults to None, which uses a standard message. Maximum length is 251 bytes
#            (255 - 4 bytes for OUI and type).
#        network (dict, optional): Network configuration dictionary. Currently unused but
#            reserved for future extensions. Defaults to None.
#    Raises:
#        OSError: If socket creation, binding, or sending fails.
#        Exception: Various socket operation exceptions are caught and silently ignored.
#    Returns:
#        None
#    Note:
#        - Requires root/administrator privileges to create raw sockets.
#        - Uses non-blocking sockets for responsive interval control.
#        - BSSID (MAC address) is randomized per execution to avoid conflicts.
#        - Employs high-precision timing (perf_counter) to minimize interval drift.
#        - Socket buffer is set to 262144 bytes; failures are silently ignored.
#    """
#    """Send beacon frames with custom vendor data at specified intervals for a duration"""
#    # Create raw socket
#    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
#    sock.bind((interface, 0))
#
#    # Set send buffer size
#    try:
#        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
#    except Exception:
#        pass
#
#    # Non-blocking socket for faster loop control
#    sock.setblocking(False)
#
#    # BSSID (MAC address) - allow some randomness to avoid conflicts
#    base_bssid = b'\x02\xca\xfe\xba\xbe\x00'
#    bssid = bytearray(base_bssid)
#    bssid[-1] = random.randrange(0, 256)
#    bssid = bytes(bssid)
#
#    # Custom vendor data for tag 221
#    message = "Hello, this is a custom beacon frame!"
#    message_bytes = custom_message.encode('utf-8') if custom_message else message.encode('utf-8')
#
#    # Validate vendor data length (221 tag uses 1-byte length)
#    if len(message_bytes) + 4 > 255:
#        # 3-byte OUI + 1-byte type + message
#        message_bytes = message_bytes[:255-4]
#
#    beacon_frame = create_beacon_frame(ssid, bssid, channel, message_bytes)
#    mv = memoryview(beacon_frame)
#
#    print(f"Sending beacons on {interface} (SSID: {ssid}, Channel: {channel}, interval={interval}s)")
#
#    # High precision timing loop to maintain interval with low drift
#    next_send = time.perf_counter()
#    
#    # Calculate end time if uptime is specified
#    end_time = None
#    if uptime > 0:
#        end_time = next_send + uptime
#        print(f"Started sending beacons at {time.ctime()}, will stop after {uptime} seconds at {time.ctime(end_time)}")
#    try:
#        while True:
#            # Check for uptime expiration
#            if end_time and time.perf_counter() >= end_time:
#                break
#            
#            now = time.perf_counter()
#            if now >= next_send:
#                try:
#                    # send may raise BlockingIOError if kernel buffer is full
#                    sock.send(mv)
#                except (BlockingIOError, InterruptedError):
#                    pass
#                # schedule next send
#                next_send += interval
#            else:
#                # Sleep a bit to avoid busy waiting
#                time.sleep(max(0, next_send - now))
#    finally:
#        sock.close()
#        print(f"Stopped sending beacons on {interface} (SSID: {ssid}) at {time.ctime()}")
#
#def send_beacon(interface='wlan1mon', ssid='TestAP', channel=6, interval=0.1, custom_message=None, uptime=0):
#    """Send beacon frames on monitor mode interface"""
#
#    # Basic pre-run checks
#    #if os.name != 'posix':
#    #    raise RuntimeError('This script requires Linux with AF_PACKET support (run on the Pineapple or Linux).')
#
#    # Create raw socket
#    try:
#        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
#        sock.bind((interface, 0))
#    except PermissionError:
#        raise PermissionError('Root privileges are required to open raw sockets.')
#
#    # Tune socket send buffer to reduce drops for high-rate sending
#    try:
#        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
#    except Exception:
#        pass
#
#    # Non-blocking socket for faster loop control
#    sock.setblocking(False)
#
#    # BSSID (MAC address) - allow some randomness to avoid conflicts
#    base_bssid = b'\x02\xca\xfe\xba\xbe\x00'
#    bssid = bytearray(base_bssid)
#    bssid[-1] = random.randrange(0, 256)
#    bssid = bytes(bssid)
#
#    # Custom vendor data for tag 221
#    message = "Hello, this is a custom beacon frame!"
#    message_bytes = custom_message.encode('utf-8') if custom_message else message.encode('utf-8')
#
#    # Validate vendor data length (221 tag uses 1-byte length)
#    if len(message_bytes) + 4 > 255:
#        # 3-byte OUI + 1-byte type + message
#        message_bytes = message_bytes[:255-4]
#
#    beacon_frame = create_beacon_frame(ssid, bssid, channel, message_bytes)
#    mv = memoryview(beacon_frame)
#
#    print(f"Sending beacons on {interface} (SSID: {ssid}, Channel: {channel}, interval={interval}s)")
#
#    # High precision timing loop to maintain interval with low drift
#    next_send = time.perf_counter()
#    
#    # Calculate end time if uptime is specified
#    end_time = None
#    if uptime > 0:
#        end_time = next_send + uptime
#        print(f"Started sending beacons at {time.ctime()}, will stop after {uptime} seconds at {time.ctime(end_time)}")
#    try:
#        while True:
#            # Check for uptime expiration
#            if end_time and time.perf_counter() >= end_time:
#                break
#            
#            now = time.perf_counter()
#            if now >= next_send:
#                try:
#                    # send may raise BlockingIOError if kernel buffer is full
#                    sock.send(mv)
#                except (BlockingIOError, InterruptedError):
#                    pass
#                # schedule next send
#                next_send += interval
#            # sleep a tiny bit to yield CPU until next send
#            wait = next_send - time.perf_counter()
#            if wait > 0:
#                # use select-based short sleep for better responsiveness
#                select.select([], [], [], min(wait, 0.01))
#        
#        print(f"Stopped sending beacons at {time.ctime()}")
#    except KeyboardInterrupt:
#        print("\nStopped")
#    finally:
#        sock.close()
#
#
#def main():
#    # Load configuration, parse arguments, and send beacon frames
#    config = load_config(CONFIG_FILE)
#    
#    config = load_config()
#    decay_time = config["decay_time"]
#    beacon_interval = config["beacon_interval"]
#    beacon_uptime = config["beacon_uptime"]
#    ssid_prefix = config["ssid_prefix"]
#    channel = config["channel"]
#    max_message_length = config["max_message_length"]
#    message_prefix = config["message_prefix"]
#    decay_prefix = config["decay_prefix"]
#    
#    argparser = argparse.ArgumentParser(description="Send message via P2P pager beacons")
#    argparser.add_argument('--interface', type=str, default=INTERFACE, help='Monitor mode interface')
#    argparser.add_argument('--network', type=str, default=None, help='Network SSID to use')
#    argparser.add_argument('--custom_message', type=str, default=None, help='Custom message to send')
#    args = argparser.parse_args()
#    
#    send_beacon(
#        interface=args.interface,
#        ssid=ssid_prefix+args.network if args.network else ssid_prefix,
#        channel=channel,
#        interval=beacon_interval,  # Standard beacon interval (100 TUs)
#        uptime=beacon_uptime,
#        custom_message=args.custom_message if args.custom_message and len(args.custom_message) <= max_message_length and message_prefix in args.custom_message else None
#    )