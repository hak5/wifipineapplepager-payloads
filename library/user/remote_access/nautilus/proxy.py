import socket
import select
import threading
import sys
import os

# Configuration
# Nautilus runs on 8888. We proxy Pager traffic on 8890 -> 1471
LOCAL_PORT = 8890
REMOTE_HOST = '127.0.0.1'
REMOTE_PORT = 1471

def handle_client(client_sock):
    remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        remote_sock.connect((REMOTE_HOST, REMOTE_PORT))
    except Exception as e:
        sys.stderr.write(f"Failed to connect to backend: {e}\n")
        client_sock.close()
        return

    # Use a flag to track if we are in the header phase
    headers_processed = False
    
    sockets = [client_sock, remote_sock]
    
    # Simple buffer for header processing
    header_buffer = b""
    
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [])
            
            if client_sock in readable:
                data = client_sock.recv(4096)
                if not data: break
                
                if not headers_processed:
                    header_buffer += data
                    if b"\r\n\r\n" in header_buffer:
                        # Headers complete
                        parts = header_buffer.split(b"\r\n\r\n", 1)
                        header_part = parts[0]
                        body_part = parts[1] if len(parts) > 1 else b""
                        
                        # Rewrite Headers
                        try:
                            headers_str = header_part.decode('utf-8', errors='ignore')
                            lines = headers_str.split('\r\n')
                            new_lines = []
                            for line in lines:
                                if line.lower().startswith('origin:'):
                                    # Spoof the Origin to match the destination
                                    new_lines.append(f"Origin: http://{REMOTE_HOST}:{REMOTE_PORT}")
                                elif line.lower().startswith('host:'):
                                    new_lines.append(f"Host: {REMOTE_HOST}:{REMOTE_PORT}")
                                else:
                                    new_lines.append(line)
                            
                            new_header_data = ('\r\n'.join(new_lines)).encode('utf-8') + b"\r\n\r\n"
                            
                            remote_sock.sendall(new_header_data)
                            if body_part:
                                remote_sock.sendall(body_part)
                            
                            headers_processed = True
                        except Exception as e:
                            sys.stderr.write(f"Header parsing error: {e}\n")
                            # Fallback: just send raw if parse fails
                            remote_sock.sendall(header_buffer)
                            headers_processed = True
                else:
                    # Normal forwarding
                    remote_sock.sendall(data)
                    
            if remote_sock in readable:
                data = remote_sock.recv(4096)
                if not data: break
                client_sock.sendall(data)
    except Exception as e:
        pass
                 
    client_sock.close()
    remote_sock.close()

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('0.0.0.0', LOCAL_PORT))
    except Exception as e:
         sys.stderr.write(f"Failed to bind port {LOCAL_PORT}: {e}\n")
         return

    server.listen(5)
    print(f"Proxy listening on {LOCAL_PORT}")
    
    while True:
        try:
            client, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(client,))
            t.daemon = True
            t.start()
        except:
            break

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
