from scapy.all import Dot11, Dot11Elt

# Common OUI prefixes for OS detection
# These are simplified lists for the core implementation
APPLE_OUIs = [
    "00:03:93", "00:05:02", "00:0a:27", "00:0d:93", "00:10:fa", "00:16:cb",
    "00:17:f2", "00:1b:63", "00:1c:b3", "00:1e:52", "00:21:e9", "00:22:6b",
    "00:23:12", "00:23:32", "00:23:6c", "00:24:36", "00:25:00", "00:25:4b",
    "00:26:08", "00:26:aa", "00:26:bb", "00:27:32", "00:28:c4", "00:2a:2c"
]

GOOGLE_OUIs = [
    "00:1a:11", "3c:5a:b4", "48:44:3a", "50:56:4d", "60:83:36", "a4:1d:5a"
]

MICROSOFT_OUIs = [
    "00:03:ff", "00:0a:5b", "00:0b:6d", "00:13:d1", "00:15:6d", "00:16:32",
    "00:1c:20", "00:1d:60", "00:20:42", "00:22:fa", "00:24:6b", "00:25:90"
]

def detect_os(packet):
    """
    Analyzes 802.11 Information Elements (IEs) and OUIs to detect the operating system.

    Args:
        packet: A scapy packet object (expected to be Dot11 or contain Dot11 layers).

    Returns:
        A string: "ios", "android", "windows", "macos", or "generic".
    """
    if not packet.haslayer(Dot11):
        return "generic"

    # Extract MAC address (OUI is the first 3 bytes)
    try:
        addr = packet.addr2 if hasattr(packet, 'addr2') else None
        if not addr:
            return "generic"

        # Standardize MAC format to uppercase with colons and lowercase OUI
        oui = ":".join(addr.split(":")[:3]).lower()
    except Exception:
        oui = None

    # 1. Check for Android-specific markers
    if oui in GOOGLE_OUIs:
        return "android"

    # 2. Check for Apple devices (iOS and macOS)
    if oui in APPLE_OUIs:
        # Heuristic: iOS devices are more common in probe requests with specific parameters.
        return "ios" if "probe" in str(packet).lower() else "macos"

    # 3. Check for Windows
    if oui in MICROSOFT_OUIs:
        return "windows"

    # 4. Deep IE analysis for Android tags
    if packet.haslayer(Dot11Elt):
        try:
            raw_bytes = bytes(packet)
            for g_oui in GOOGLE_OUIs:
                g_bytes = bytes.fromhex(g_oui.replace(":", ""))
                if g_bytes in raw_bytes:
                    return "android"
        except Exception:
            pass

    return "generic"
