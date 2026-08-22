#!/usr/bin/env python3
import socket
import struct
import argparse
import os
import sys

# Pre-compile struct formats for performance
UNPACK_H = struct.Struct('<H').unpack
UNPACK_Q = struct.Struct('<Q').unpack


def parse_beacon_frame(packet, target_ssid=None, target_channel=None):
    """
    Parse beacon frame and extract SSID and vendor-specific tags
    Early filtering by SSID/channel for better performance
    Returns: (ssid, channel, bssid, vendor_data_dict) or None if not a beacon
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


def receive_beacons(interface='wlan1mon', target_ssid=None, target_channel=None, timeout=None, one_shot=False, verbose=False):
    """
    Capture beacon frames and extract custom vendor tag 221 data
    
    Args:
        interface: Monitor mode interface
        target_ssid: Filter by SSID
        target_channel: Filter by channel
        timeout: Timeout in seconds
        one_shot: Exit after first matching beacon (for bash integration)
        verbose: Print detailed output (for debugging)
    """
    
    # Basic pre-run checks
    if os.name != 'posix':
        print('Error: This script requires Linux with AF_PACKET support', file=sys.stderr)
        sys.exit(1)
    
    # Create raw socket for sniffing
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
        sock.bind((interface, 0))
    except PermissionError:
        print('Error: Root privileges are required to capture packets.', file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f'Error: Failed to bind to {interface}. Is it in monitor mode? {e}', file=sys.stderr)
        sys.exit(3)
    
    # Set receive buffer size
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2**21)  # 2MB buffer
    except Exception:
        pass
    
    # Set timeout if specified
    if timeout:
        sock.settimeout(timeout)
    
    if verbose:
        print(f"Listening for beacons on {interface}", file=sys.stderr)
        if target_ssid:
            print(f"  Filtering by SSID: {target_ssid}", file=sys.stderr)
        if target_channel:
            print(f"  Filtering by channel: {target_channel}", file=sys.stderr)
        if one_shot:
            print(f"  One-shot mode: will exit after first beacon", file=sys.stderr)
        print("Press Ctrl+C to stop\n", file=sys.stderr)
    
    seen_networks = set()
    
    try:
        while True:
            try:
                packet = sock.recv(4096)
            except socket.timeout:
                if verbose:
                    print("Timeout reached, no matching beacons found.", file=sys.stderr)
                sys.exit(4)
            
            result = parse_beacon_frame(packet)
            if result is None:
                continue
            
            ssid, channel, bssid, vendor_tags = result
            
            # Apply filters
            if target_ssid and ssid != target_ssid:
                continue
            if target_channel and channel != target_channel:
                continue
            
            # Create unique identifier for this network
            bssid_str = ':'.join(f'{b:02x}' for b in bssid)
            network_id = f"{ssid}_{bssid_str}"
            
            # Skip if we've already seen this network (unless it has new vendor data)
            if network_id in seen_networks and not vendor_tags:
                continue
            
            seen_networks.add(network_id)
            
            if verbose:
                # Display beacon information for debugging
                print(f"{'='*70}", file=sys.stderr)
                print(f"SSID: {ssid or '(hidden)'}", file=sys.stderr)
                print(f"BSSID: {bssid_str}", file=sys.stderr)
                print(f"Channel: {channel if channel else 'unknown'}", file=sys.stderr)
            
            # Output vendor tag data to stdout for bash script capture
            if vendor_tags:
                for oui_key, data in vendor_tags.items():
                    # Try to decode as UTF-8 text
                    try:
                        text = data.decode('utf-8')
                        # Output: OUI_KEY|UTF8_DATA
                        print(f"{oui_key}|{text}")
                        if one_shot:
                            sock.close()
                            sys.exit(0)
                    except UnicodeDecodeError:
                        if verbose:
                            print(f"  Could not decode vendor data as UTF-8 for {oui_key}", file=sys.stderr)
                        # Output hex version
                        print(f"{oui_key}|{data.hex()}")
                        if one_shot:
                            sock.close()
                            sys.exit(0)
                    
                    if verbose:
                        print(f"  OUI+Type: {oui_key}", file=sys.stderr)
                        print(f"  Length: {len(data)} bytes", file=sys.stderr)
                        if len(data) <= 64:
                            print(f"  Raw hex: {' '.join(f'{b:02x}' for b in data)}", file=sys.stderr)
                        print(f"{'='*70}\n", file=sys.stderr)
            elif verbose:
                print(f"No vendor-specific tags found", file=sys.stderr)
                print(f"{'='*70}\n", file=sys.stderr)
    
    except KeyboardInterrupt:
        if verbose:
            print("\nStopped", file=sys.stderr)
        sys.exit(5)
    finally:
        sock.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="Capture beacon frames and extract custom vendor tag 221 data",
        epilog="Example: sudo python3 receive_beacon.py --interface wlan1mon --ssid MyNetwork --channel 6 --one-shot"
    )
    
    parser.add_argument('--interface', type=str, default='wlan1mon', 
                        help='Monitor mode interface (default: wlan1mon)')
    parser.add_argument('--ssid', type=str, default=None, 
                        help='Filter by specific SSID (optional)')
    parser.add_argument('--channel', type=int, default=None, 
                        help='Filter by specific channel (optional)')
    parser.add_argument('--timeout', type=int, default=None, 
                        help='Timeout in seconds (0 for infinite, default: infinite)')
    parser.add_argument('--one-shot', action='store_true', 
                        help='Exit after first matching beacon (ideal for bash scripts)')
    parser.add_argument('--verbose', action='store_true', 
                        help='Print debug output to stderr')
    
    args = parser.parse_args()
    
    receive_beacons(
        interface=args.interface,
        target_ssid=args.ssid,
        target_channel=args.channel,
        timeout=args.timeout if args.timeout and args.timeout > 0 else None,
        one_shot=args.one_shot,
        verbose=args.verbose
    )
