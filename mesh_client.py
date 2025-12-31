#!/usr/bin/env python3
"""
Simple mesh client - send and receive packets via TCP
"""

import socket
import sys
import struct
import threading
import time
from datetime import datetime

# Constants
ROUTE_FLOOD = 0x01
TYPE_GRP_TXT = 0x05

def fletcher16(data):
    """Calculate Fletcher-16 checksum"""
    sum1 = sum2 = 0
    for byte in data:
        sum1 = (sum1 + byte) % 255
        sum2 = (sum2 + sum1) % 255
    return bytes([sum2, sum1])

def create_rs232_frame(packet):
    """Wrap packet in RS232Bridge frame"""
    magic = bytes([0xC0, 0x3E])
    length = struct.pack(">H", len(packet))
    checksum = fletcher16(packet)
    return magic + length + packet + checksum

def read_rs232_frame(sock):
    """Read RS232Bridge frame from socket"""
    # Magic
    magic = sock.recv(2)
    if len(magic) < 2 or magic[0] != 0xC0 or magic[1] != 0x3E:
        return None
    
    # Length
    length_bytes = sock.recv(2)
    if len(length_bytes) < 2:
        return None
    length = struct.unpack(">H", length_bytes)[0]
    
    # Packet
    packet = b""
    while len(packet) < length:
        chunk = sock.recv(length - len(packet))
        if not chunk:
            return None
        packet += chunk
    
    # Checksum
    checksum = sock.recv(2)
    if len(checksum) < 2:
        return None
    
    # Verify
    calc = fletcher16(packet)
    if calc != checksum:
        print(f"[!] Checksum error: {checksum.hex()} != {calc.hex()}")
        return None
    
    return packet

def display_packet(packet):
    """Display packet info"""
    if len(packet) < 3:
        return
    
    header = packet[0]
    route = header & 0x03
    ptype = (header >> 2) & 0x0F
    
    path_len = packet[1]
    payload_len = packet[2]
    
    payload_start = 3 + path_len
    payload = packet[payload_start:payload_start + payload_len]
    
    route_names = {0: "DIRECT", 1: "FLOOD", 2: "TRANSPORT"}
    type_names = {0: "TXT_MSG", 3: "ACK", 4: "ADVERT", 5: "GRP_TXT"}
    
    print(f"\n{'='*60}")
    print(f"📨 RX [{datetime.now().strftime('%H:%M:%S')}]")
    print(f"{'='*60}")
    print(f"Route: {route_names.get(route, f'0x{route:02X}')}")
    print(f"Type:  {type_names.get(ptype, f'0x{ptype:02X}')}")
    print(f"Payload: {payload[:32].hex()}{'...' if len(payload) > 32 else ''}")
    print(f"{'='*60}")

def receiver_thread(sock, running):
    """Background receiver"""
    count = 0
    while running[0]:
        try:
            packet = read_rs232_frame(sock)
            if packet is None:
                break
            count += 1
            display_packet(packet)
            print("> ", end="", flush=True)
        except:
            break
    print(f"\n[*] Receiver stopped ({count} packets)")

def send_packet(sock, packet_hex):
    """Send raw packet"""
    try:
        packet = bytes.fromhex(packet_hex.replace(" ", ""))
        frame = create_rs232_frame(packet)
        sock.sendall(frame)
        print(f"[✓] Sent {len(packet)} bytes")
        return True
    except Exception as e:
        print(f"[!] Error: {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print(f"  {sys.argv[0]} <host> [port]")
        print()
        print("Example:")
        print(f"  {sys.argv[0]} 192.168.0.100 5002")
        print()
        print("Interactive commands:")
        print("  <hex>     - Send raw packet (e.g., 15001165E1B5...)")
        print("  quit/exit - Disconnect")
        sys.exit(1)
    
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5002
    
    print(f"[*] Connecting to {host}:{port}...")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    
    try:
        sock.connect((host, port))
        print(f"[✓] Connected!")
        print(f"\nType hex packet to send, or 'quit' to exit")
        print(f"{'='*60}\n")
        
        # Start receiver
        running = [True]
        receiver = threading.Thread(target=receiver_thread, args=(sock, running), daemon=True)
        receiver.start()
        
        # Interactive loop
        while running[0]:
            try:
                cmd = input("> ").strip()
                
                if not cmd:
                    continue
                
                if cmd.lower() in ['quit', 'exit', 'q']:
                    running[0] = False
                    break
                
                # Assume hex packet
                send_packet(sock, cmd)
                
            except KeyboardInterrupt:
                print("\n[*] Interrupted")
                running[0] = False
                break
            except EOFError:
                running[0] = False
                break
    
    except ConnectionRefusedError:
        print(f"[!] Cannot connect to {host}:{port}")
        sys.exit(1)
    except Exception as e:
        print(f"[!] Error: {e}")
    finally:
        sock.close()
        print("[✓] Disconnected")

if __name__ == "__main__":
    main()
