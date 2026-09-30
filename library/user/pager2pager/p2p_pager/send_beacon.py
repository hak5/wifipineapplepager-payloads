#!/usr/bin/env python3
import socket
import struct
import time
import os
import select
import random

# args for interface, ssid, channel, interval, custom_message
import argparse


def create_beacon_frame(ssid, bssid, channel, custom_vendor_data):
    """
    Create a beacon frame with custom 221 tag
    bssid: MAC address as bytes (6 bytes)
    """

    # Radiotap header (minimal)
    radiotap = struct.pack('<BBHI',
        0,    # version
        0,    # padding
        8,    # length
        0     # present flags
    )

    # 802.11 Beacon frame header
    frame_control = struct.pack('<H', 0x80)  # Beacon frame
    duration = struct.pack('<H', 0)
    dest_addr = b'\xff\xff\xff\xff\xff\xff'  # Broadcast
    src_addr = bssid
    bssid_addr = bssid
    seq_ctrl = struct.pack('<H', 0)

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
    oui = b'\x00\x50\xf2'  # Example OUI (Microsoft)
    oui_type = b'\x04'     # Example type
    vendor_payload = oui + oui_type + custom_vendor_data
    # length field is a single byte; truncate if necessary
    if len(vendor_payload) > 255:
        vendor_payload = vendor_payload[:255]
    vendor_tag = struct.pack('BB', 221, len(vendor_payload)) + vendor_payload

    # Assemble frame
    beacon = (radiotap + frame_control + duration + dest_addr + src_addr +
              bssid_addr + seq_ctrl + timestamp + beacon_interval + capability +
              ssid_tag + rates_tag + ds_tag + vendor_tag)

    return beacon

def send_beacon(interface='wlan1mon', ssid='TestAP', channel=6, interval=0.1, custom_message=None, uptime=0):
    """Send beacon frames on monitor mode interface"""

    # Basic pre-run checks
    #if os.name != 'posix':
    #    raise RuntimeError('This script requires Linux with AF_PACKET support (run on the Pineapple or Linux).')

    # Create raw socket
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
        sock.bind((interface, 0))
    except PermissionError:
        raise PermissionError('Root privileges are required to open raw sockets.')

    # Tune socket send buffer to reduce drops for high-rate sending
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
    except Exception:
        pass

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
    if len(message_bytes) + 4 > 255:
        # 3-byte OUI + 1-byte type + message
        message_bytes = message_bytes[:255-4]

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
            # sleep a tiny bit to yield CPU until next send
            wait = next_send - time.perf_counter()
            if wait > 0:
                # use select-based short sleep for better responsiveness
                select.select([], [], [], min(wait, 0.01))
        
        print(f"Stopped sending beacons at {time.ctime()}")
    except KeyboardInterrupt:
        print("\nStopped")
    finally:
        sock.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Send custom beacon frames")
    parser.add_argument('--interface', type=str, default='wlan1mon', help='Monitor mode interface')
    parser.add_argument('--ssid', type=str, default='MyNetwork', help='SSID to broadcast')
    parser.add_argument('--channel', type=int, default=6, help='Channel to use')
    parser.add_argument('--interval', type=float, default=0.102400, help='Beacon interval in seconds')
    parser.add_argument('--custom_message', type=str, default="Hello from custom beacon!", help='Custom message for vendor-specific tag')
    parser.add_argument('--uptime', type=int, default=0, help='Duration to send beacons (0 for infinite)')
    


    args = parser.parse_args()

    send_beacon(
        interface=args.interface,
        ssid=args.ssid,
        channel=args.channel,
        interval=args.interval,  # Standard beacon interval (100 TUs)
        custom_message=args.custom_message,
        uptime=args.uptime
    )
