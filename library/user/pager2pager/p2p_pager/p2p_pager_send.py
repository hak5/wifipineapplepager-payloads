#!/usr/bin/env python3







# New version which interfaces with the main p2p pager system using a local socket to send messages to be broadcast in beacon frames. This allows for better integration with the message management system, including seen message tracking and decay handling.
import os


CONFIG_DIR = os.path.expanduser("/root/.p2p_pager")
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



PORT = 8999
IP = "127.0.0.1"
import socket


def send_message_to_beacon(network:str, message:str, channel=None, decay_time=None):
    """Send a message to the beacon sender via local socket"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((IP, PORT))
        # Send message in format: network,message,channel:<channel>,decay_time:<decay_time>
        payload = f"{network},{message},channel:{channel if channel else ''},decay_time:{decay_time if decay_time else ''}"
        #send_log(f"Sending message to beacon sender: {payload}")
        s.sendall(payload.encode('utf-8'))
        return_message = s.recv(1024)  # Wait for acknowledgment (not used currently)
        #send_log(f"Received response from beacon sender: {return_message.decode('utf-8')}")
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
    


if __name__ == "__main__":
    main()