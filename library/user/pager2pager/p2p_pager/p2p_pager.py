#!/usr/bin/env python3
import argparse
import asyncio
import socket
import struct
import time
import os
import random


UNPACK_H = struct.Struct('<H').unpack
UNPACK_Q = struct.Struct('<Q').unpack

# The full implementation of the p2p pager system

# locations of important files
CONFIG_DIR = os.path.expanduser("~/.p2p_pager")
NETWORKS_CONFIG_FILE = os.path.join(CONFIG_DIR, "networks.conf")
CONFIG_FILE = os.path.join(CONFIG_DIR, "p2p_pager.conf")
SEEN_MESSAGES_FILE = os.path.join("/var", "seen_messages.db")

message_queue = asyncio.Queue()
seen_messages = {}



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

# Load networks configuration
def load_networks():
    """
    Load network configurations from a file and parse them into a dictionary.
    
    Reads a configuration file (NETWORKS_CONFIG_FILE) where each line contains
    comma-separated values: SSID followed by optional key=value pairs for overrides.
    
    Returns:
        dict: A dictionary mapping network SSIDs (str) to their configuration overrides (dict).
              Override values are converted to float if the key is "decay_time", 
              otherwise kept as strings.
              Returns an empty dictionary if the configuration file does not exist.
    
    Example:
        If NETWORKS_CONFIG_FILE contains:
            MyNetwork,decay_time=5.5,channel=6
            HomeWiFi,decay_time=10.0
        
        Returns:
            {
                "MyNetwork": {"decay_time": 5.5, "channel": "6"},
                "HomeWiFi": {"decay_time": 10.0}
            }
    """
    networks = {}
    if os.path.isfile(NETWORKS_CONFIG_FILE):
        with open(NETWORKS_CONFIG_FILE, 'r') as f:
            for line in f:
                parts = line.strip().split(',')
                ssid = parts[0]
                overrides = {}
                for part in parts[1:]:
                    k, v = part.split('=')
                    if k in ["decay_time"]:
                        overrides[k] = float(v)
                    else:
                        overrides[k] = v
                networks[ssid] = overrides
    return networks

# Constants
BEACON_INTERVAL = 0.102  # seconds between beacons
REBROADCAST_DURATION = 10  # seconds to rebroadcast messages after starting
DECAY_TIME = 300  # seconds before a message is considered "new" again
VENDOR_IE_TAG = 221  # Vendor Specific IE tag
MAX_MESSAGE_LENGTH = 200  # Max length of message to send
INTERFACE = "wlan1mon"  # Monitor mode interface
SSID_PREFIX = "P2PAGER"  # SSID prefix for networks

DEST_ADDR = b'\xff\xff\xff\xff\xff\xff'  # Broadcast address
RADIOTAP = struct.pack('<BBHI',
    0,    # version
    0,    # padding
    8,    # length
    0     # present flags
)
FRAME_CONTROL = struct.pack('<H', 0x80)  # Beacon frame
DURATION = struct.pack('<H', 0)
SEQ_CTRL = struct.pack('<H', 0)
OUI = b'\x00\x50\xf2'  # Example OUI (Microsoft)
OUI_TYPE = b'\x04'     # Example type
PARTIAL_VENDOR_PAYLOAD = OUI + OUI_TYPE  # without message data

def parse_beacon_frame(packet, target_ssid=None, target_channel=None):
    """
    Parse a beacon frame from a wireless packet.
    This function extracts information from an 802.11 beacon frame, including SSID,
    channel, BSSID, and vendor-specific tags. It uses memoryview for efficient
    zero-copy slicing of packet data.
    Args:
        packet (bytes): The raw packet data containing a radiotap header followed
            by an 802.11 frame.
        target_ssid (str, optional): Filter to match a specific SSID. If provided,
            the function returns None if the beacon's SSID doesn't match.
            Defaults to None.
        target_channel (int, optional): Filter to match a specific channel number.
            If provided, the function returns None if the beacon's channel doesn't
            match. Defaults to None.
    Returns:
        tuple: A 4-tuple containing:
            - ssid (str): The network SSID decoded from the beacon frame.
            - channel (int): The channel number extracted from the DS Parameter Set tag.
            - bssid (bytes): The 6-byte Basic Service Set Identifier (MAC address).
            - vendor_tags (dict): A dictionary mapping vendor OUI strings
              (format: "xx:xx:xx:xx") to their vendor-specific data (bytes).
        None: If the packet is invalid, too short, not a beacon frame, or doesn't
            match the provided filters.
    Raises:
        No exceptions are raised; errors are caught and None is returned.
    Notes:
        - The function expects packet data with a radiotap header at the beginning.
        - Beacon frames have frame type 0 (management) and subtype 8.
        - SSID is decoded as UTF-8 with errors ignored.
        - The function performs early filtering to avoid unnecessary parsing.
    """
    try:
        # Use memoryview for zero-copy slicing
        mv = memoryview(packet)
        
        # Skip radiotap header (length is at bytes 2-3)
        radiotap_len = UNPACK_H(mv[2:4])[0]
        
        # Minimum frame check
        if len(mv) < radiotap_len + 36:
            return None
        
        # 802.11 frame starts after radiotap
        frame_start = radiotap_len
        
        # Check if it's a beacon frame (type/subtype in frame control)
        frame_control = UNPACK_H(mv[frame_start:frame_start + 2])[0]
        frame_type = (frame_control >> 2) & 0x3
        frame_subtype = (frame_control >> 4) & 0xF
        
        # Beacon: type=0 (management), subtype=8
        if frame_type != 0 or frame_subtype != 8:
            return None
        
        # BSSID is at offset 16 from frame start
        bssid_offset = frame_start + 16
        bssid = bytes(mv[bssid_offset:bssid_offset + 6])
        
        # Tagged parameters start at offset 36 from frame start
        tagged_params_start = frame_start + 36
        
        # Parse tagged parameters with early filtering
        ssid = None
        channel = None
        vendor_tags = {}
        ssid_found = False
        channel_found = False
        
        offset = tagged_params_start
        frame_end = len(mv)
        
        # Fast scan for SSID and channel first (early exit if filters don't match)
        while offset + 2 <= frame_end:
            tag_number = mv[offset]
            tag_length = mv[offset + 1]
            
            if offset + 2 + tag_length > frame_end:
                break
            
            if tag_number == 0 and not ssid_found:  # SSID
                ssid = bytes(mv[offset + 2:offset + 2 + tag_length]).decode('utf-8', errors='ignore')
                ssid_found = True
                # Early exit if SSID doesn't match filter
                if target_ssid and ssid != target_ssid:
                    return None
            elif tag_number == 3 and not channel_found:  # DS Parameter Set
                if tag_length >= 1:
                    channel = mv[offset + 2]
                    channel_found = True
                    # Early exit if channel doesn't match filter
                    if target_channel and channel != target_channel:
                        return None
            elif tag_number == 221:  # Vendor-specific
                if tag_length >= 4:
                    # Only parse vendor tags if we passed filters
                    if (target_ssid is None or ssid_found) and (target_channel is None or channel_found):
                        tag_data = bytes(mv[offset + 2:offset + 2 + tag_length])
                        oui = tag_data[0:3]
                        oui_type = tag_data[3]
                        vendor_data = tag_data[4:]
                        
                        # Cache OUI string formatting
                        key = f"{oui[0]:02x}:{oui[1]:02x}:{oui[2]:02x}:{oui_type:02x}"
                        vendor_tags[key] = vendor_data
            
            offset += 2 + tag_length
            
            # Early exit if both filters checked and we have vendor tags
            if target_ssid and target_channel and ssid_found and channel_found:
                if not vendor_tags:
                    # Continue to look for vendor tags
                    pass
        
        return (ssid, channel, bssid, vendor_tags)
    
    except Exception as e:
        return None

def create_beacon_frame(ssid, bssid, channel, custom_vendor_data):
    # 802.11 Beacon frame header
    src_addr = bssid
    bssid_addr = bssid

    # Fixed parameters (beacon frame body)
    # Zero timestamp to avoid rebuilding frame on every send (many receivers ignore it)
    timestamp = struct.pack('<Q', 0)
    beacon_interval = struct.pack('<H', 100)  # 100 TUs
    capability = struct.pack('<H', 0x0421)  # ESS + Privacy

    # Tagged parameters
    # SSID tag (0)
    ssid_tag = struct.pack('BB', 0, len(ssid)) + ssid.encode()

    # Supported rates tag (1)
    rates = b'\x82\x84\x8b\x96\x0c\x12\x18\x24'
    rates_tag = struct.pack('BB', 1, len(rates)) + rates

    # DS Parameter Set (channel) tag (3)
    ds_tag = struct.pack('BBB', 3, 1, channel)

    # Custom vendor-specific tag (221)
    # Format: tag_number (1) | length (1) | OUI (3) | OUI type (1) | vendor data
    vendor_payload = PARTIAL_VENDOR_PAYLOAD + custom_vendor_data
    # length field is a single byte; truncate if necessary
    if len(vendor_payload) > 255:
        vendor_payload = vendor_payload[:255]
    vendor_tag = struct.pack('BB', 221, len(vendor_payload)) + vendor_payload

    # Assemble frame
    beacon = (RADIOTAP + FRAME_CONTROL + DURATION + DEST_ADDR + src_addr +
              bssid_addr + SEQ_CTRL + timestamp + beacon_interval + capability +
              ssid_tag + rates_tag + ds_tag + vendor_tag)

    return beacon

async def receive_messages(sock, decay_time, message_prefix, decay_prefix):
    """
    Receive beacon frames from a socket and process embedded messages with decay logic.
    Listens for WiFi beacon frames, extracts SSID and vendor tag data, and manages
    message rebroadcasting with time-based decay. Messages matching the specified prefix
    are rebroadcast after a decay period has elapsed. Decay prefix messages trigger
    removal of previously seen messages.
    Args:
        sock (socket.socket): Raw socket configured for receiving beacon frames in monitor mode.
        decay_time (float): Time in seconds before a message can be rebroadcast again.
        message_prefix (str): Prefix string to identify rebroadcastable messages in vendor tags.
        decay_prefix (str): Prefix string to identify decay/removal messages in vendor tags.
    Returns:
        None: Runs indefinitely in a blocking loop.
    Globals:
        seen_messages (dict): Tracks message IDs and their last seen timestamps for decay logic.
        networks (dict): Dictionary of known networks indexed by SSID.
        ssid_prefix (str): Optional prefix filter for SSID matching.
        INTERFACE (str): Network interface for rebroadcasting messages.
        BEACON_INTERVAL (int): Interval for beacon transmission.
        REBROADCAST_DURATION (int): Duration to rebroadcast messages.
    Raises:
        Implicitly handles socket errors and malformed packet parsing.
    Side Effects:
        - Updates seen_messages tracking dictionary
        - Prints messages to console for new, rebroadcast, and decay events
        - Executes asynchronous rebroadcast operations via asyncio
    """
    global seen_messages, networks, message_queue
    """Receive beacon frames and extract messages then starts a rebroadcast if new asynchronously"""
    
    # Set receive buffer size
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2**21)  # 2MB buffer
    except Exception:
        pass
    
    # Use asyncio event loop for non-blocking socket reads
    loop = asyncio.get_running_loop()
    while True:
        packet = await loop.sock_recv(sock, 4096)
        parsed = parse_beacon_frame(packet)
        if parsed is None:
            continue
        ssid, channel, bssid, vendor_tags = parsed

        if len(ssid_prefix) > 0 and not ssid.startswith(ssid_prefix):
            continue
        if ssid[len(ssid_prefix):] if ssid.startswith(ssid_prefix) else ssid not in networks:
            continue
        for key, data in vendor_tags.items():
            message = data.decode('utf-8', errors='ignore')
            current_time = time.time()

            if message.startswith(message_prefix):
                full_message = message[len(message_prefix):]
                message_id = f"{full_message}:{ssid}"
                detailed_message = f"{full_message}:{ssid}:{channel}"

                if message_id in seen_messages:
                    last_seen = seen_messages[message_id]
                    if current_time - last_seen > decay_time:
                        # Decay time passed, rebroadcast
                        seen_messages[message_id] = current_time
                        print(f"Rebroadcasting message: {full_message} from SSID: {ssid}")

                        # Add to message queue for processing
                        asyncio.create_task(message_queue.put(detailed_message))
                    else:
                        # Recently seen, ignore but update timestamp
                        seen_messages[message_id] = current_time
                else:
                    # New message, rebroadcast
                    seen_messages[message_id] = current_time
                    print(f"New message received: {full_message} from SSID: {ssid}")
                    # Add to message queue for processing
                    asyncio.create_task(message_queue.put(detailed_message))

            elif message.startswith(decay_prefix):
                decay_message = message[len(decay_prefix):]
                decay_id = f"{decay_message}:{ssid}"
                if decay_id in seen_messages:
                    del seen_messages[decay_id]
                    print(f"Decay message received, removing: {decay_message} from SSID: {ssid}")


async def handle_queue():
    while True:
        message = await message_queue.get()
        # Process the message (broadcast, alert, etc.)
        asyncio.create_task(send_alert(message))
        # Extract ssid and channel from detailed message
        parts = message.split(':', 2)
        if len(parts) == 3:
            full_message, ssid, channel = parts[0], parts[1], int(parts[2])
            await broadcast_message(INTERFACE, ssid, channel, BEACON_INTERVAL, REBROADCAST_DURATION, custom_message=full_message)
        else:
            print(f"Invalid message format: {message}")
        
        message_queue.task_done()

# Listen on a local port for new messages to send, and add them to the queue at the start and add them to seen messages to avoid rebroadcasting them immediately
async def listen_for_new_messages(port):
    global seen_messages, message_queue
    server = await asyncio.start_server(lambda r, w: handle_new_message(r, w), 'localhost', port)
    print(f"Listening for new messages on port {port}...")
    # the server will run indefinitely until the program is stopped
    # the data received from clients will include the message to send and the SSID to send it on, separated by a comma and optionally a decay time in seconds to override the default decay time for this message
    async with server:
        await server.serve_forever()

async def handle_new_message(reader, writer):
    global seen_messages, networks, channel, max_message_length, ssid_prefix, decay_time, message_queue
    data = await reader.read(1024)
    message = data.decode('utf-8').strip()
    parts = message.split(',', 2)
    if len(parts) < 2:
        print(f"Invalid message format: {message}")
        return
    ssid, custom_message = parts[0], parts[1]
    ssid = f"{ssid_prefix}{ssid}" if ssid_prefix else ssid
    decay_time = networks.get(ssid, {}).get("decay_time", decay_time)
    channel = networks.get(ssid, {}).get("channel", channel)
    # Add to seen messages with decay time
    seen_messages[f"{custom_message}:{ssid}"] = time.time() + decay_time
    # Add to message queue for processing with detailed message format
    asyncio.create_task(message_queue.put(f"{custom_message}:{ssid}:{channel}"))

# Async broadcast function
async def broadcast_message(interface, message_prefix, channel, interval, uptime, custom_message=None, network=None):
    """
    Asynchronously broadcast beacon frames with custom vendor data at specified intervals.
    This function creates and sends IEEE 802.11 beacon frames over a specified wireless
    interface. The beacons contain custom vendor data (tag 221) and are transmitted at
    regular intervals for a specified duration.
    Args:
        interface (str): Network interface name (e.g., 'wlan0') to send beacons on.
        message_prefix (str): Prefix to be added to the custom message.
        channel (int): WiFi channel number (1-14 for 2.4GHz, 36+ for 5GHz) to transmit on.
        interval (float): Time in seconds between consecutive beacon transmissions.
        uptime (float): Duration in seconds to send beacons. If <= 0, beacons are sent indefinitely.
        custom_message (str, optional): Custom message to include in vendor data tag 221.
            Defaults to None, which uses a standard message. Maximum length is 251 bytes
            (255 - 4 bytes for OUI and type).
        network (str): On what network to send the message, used for custom configurations. Defaults to None.
    Raises:
        OSError: If socket creation, binding, or sending fails.
        Exception: Various socket operation exceptions are caught and silently ignored.
    Returns:
        None
    Note:
        - Requires root/administrator privileges to create raw sockets.
        - Uses non-blocking sockets for responsive interval control.
        - BSSID (MAC address) is randomized per execution to avoid conflicts.
        - Employs high-precision timing (perf_counter) to minimize interval drift.
        - Socket buffer is set to 262144 bytes; failures are silently ignored.
    """
    """Send beacon frames with custom vendor data at specified intervals for a duration"""
    # Create raw socket
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    sock.bind((interface, 0))

    # Set send buffer size
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
    except Exception:
        pass
    
    # Combine message prefix with network to the ssid for broadcasting
    ssid = f"{message_prefix}{network}" if network else message_prefix

    # Non-blocking socket for faster loop control
    sock.setblocking(False)

    # BSSID (MAC address) - allow some randomness to avoid conflicts
    base_bssid = b'\x02\xca\xfe\xba\xbe\x00'
    bssid = bytearray(base_bssid)
    bssid[-1] = random.randrange(0, 256)
    bssid = bytes(bssid)

    # Custom vendor data for tag 221
    message = "Hello, this is a custom beacon frame!"
    message_bytes = custom_message.encode('utf-8') if custom_message else message.encode('utf-8')

    # Validate vendor data length (221 tag uses 1-byte length)
    if len(message_bytes) + 4 > max_message_length:
        # 3-byte OUI + 1-byte type + message
        message_bytes = message_bytes[:max_message_length-4]

    beacon_frame = create_beacon_frame(ssid, bssid, channel, message_bytes)
    mv = memoryview(beacon_frame)

    print(f"Sending beacons on {interface} (SSID: {ssid}, Channel: {channel}, interval={interval}s)")

    # High precision timing loop to maintain interval with low drift
    next_send = time.perf_counter()
    
    # Calculate end time if uptime is specified
    end_time = None
    if uptime > 0:
        end_time = next_send + uptime
        print(f"Started sending beacons at {time.ctime()}, will stop after {uptime} seconds at {time.ctime(end_time)}")
    try:
        while True:
            # Check for uptime expiration
            if end_time and time.perf_counter() >= end_time:
                break
            
            now = time.perf_counter()
            if now >= next_send:
                try:
                    # send may raise BlockingIOError if kernel buffer is full
                    sock.send(mv)
                except (BlockingIOError, InterruptedError):
                    pass
                # schedule next send
                next_send += interval
            else:
                # Sleep a bit to avoid busy waiting
                await asyncio.sleep(min(interval, next_send - now))
    finally:
        sock.close()
        print(f"Stopped sending beacons on {interface} (SSID: {ssid}) at {time.ctime()}")

# Send alert command to system
async def send_alert(message):
    # Uses the "ALERT" command to send a message to the system (e.g., for Pineapple Pager)
    os.system(f"ALERT '{message}'")



async def main():
    global seen_messages, networks, ssid_prefix, channel, decay_time, max_message_length, debug_mode
    # Load configuration
    config = load_config()
    decay_time = config["decay_time"]
    beacon_interval = config["beacon_interval"]
    beacon_uptime = config["beacon_uptime"]
    ssid_prefix = config["ssid_prefix"]
    channel = config["channel"]
    max_message_length = config["max_message_length"]
    message_prefix = config["message_prefix"]
    decay_prefix = config["decay_prefix"]
    
    debug_mode = False
    parser = argparse.ArgumentParser(description="P2P Pager System")
    parser.add_argument('--debug', action='store_true', help='Enable debug mode')
    args = parser.parse_args()

    if args.debug:
        debug_mode = True
        print("Debug mode enabled. Verbose output will be shown.")
    
    
    

    # Load networks
    networks = load_networks()

    # Socket setup
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    sock.bind((INTERFACE, 0))
    sock.setblocking(0)

    # Start server to listen for new messages to send
    task1 = asyncio.create_task(listen_for_new_messages(89999))
    # Start message queue handler
    task2 = asyncio.create_task(handle_queue())
    # Start receiving messages (runs forever)
    
    print("P2P Pager system started. Listening for messages...")
    await receive_messages(sock, decay_time, message_prefix, decay_prefix)


if __name__ == '__main__':
    asyncio.run(main())
    