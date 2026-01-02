#!/usr/bin/env python3
"""
Simple mesh client - send and receive packets via TCP
"""

import base64
import hashlib
import random
import socket
import struct
import sys
import threading
import time
from datetime import datetime

from Crypto.Cipher import AES
from Crypto.Hash import HMAC, SHA256

# Constants
ROUTE_FLOOD = 0x01
TYPE_GRP_TXT = 0x05

# Public channel PSK (base64)
PUBLIC_GROUP_PSK = "izOH6cXN6mrJ5e26oRXNcg=="

# Sizes used by MeshCore crypto
PATH_HASH_SIZE = 1
CIPHER_MAC_SIZE = 2
CIPHER_KEY_SIZE = 16
PUB_KEY_SIZE = 32

def fletcher16(data):
    """Calculate Fletcher-16 checksum"""
    sum1 = sum2 = 0
    for byte in data:
        sum1 = (sum1 + byte) % 255
        sum2 = (sum2 + sum1) % 255
    return bytes([sum2, sum1])


def get_public_channel_secret():
    """Decode base64 PSK to raw secret."""
    return base64.b64decode(PUBLIC_GROUP_PSK)


def get_public_channel_hash(secret):
    """Calculate channel hash (SHA256 first byte)."""
    sha = hashlib.sha256()
    sha.update(secret)
    return sha.digest()[0]


def pad_to_block_size(data, block_size=16):
    """Zero-pad to block size."""
    padding_len = (block_size - (len(data) % block_size)) % block_size
    if len(data) % block_size != 0:
        padding_len = block_size - (len(data) % block_size)
    return data + bytes(padding_len)


def encrypt_aes128(secret, plaintext):
    """AES-128 ECB with zero padding (matches MeshCore utils)."""
    key = secret[:CIPHER_KEY_SIZE]
    cipher = AES.new(key, AES.MODE_ECB)
    padded = pad_to_block_size(plaintext, 16)
    return cipher.encrypt(padded)


def encrypt_then_mac(secret, plaintext):
    """MeshCore encryptThenMAC: AES-128 + HMAC-SHA256 (2-byte MAC)."""
    encrypted = encrypt_aes128(secret, plaintext)
    mac = HMAC.new(secret[:PUB_KEY_SIZE], encrypted, SHA256).digest()[:CIPHER_MAC_SIZE]
    return mac + encrypted


def create_group_message_data(timestamp, sender_name, message):
    """Assemble GRP_TXT payload before encryption."""
    data = bytearray()
    data.extend(struct.pack('<I', timestamp))
    data.append(0x00)  # txt_type = plain text
    formatted = f"{sender_name}: {message}".encode("utf-8")
    data.extend(formatted)
    return bytes(data)


def create_group_text_packet(sender_name, message):
    """Build full MeshCore packet for public channel GRP_TXT."""
    secret = get_public_channel_secret()
    channel_hash = get_public_channel_hash(secret)

    timestamp = int(time.time())
    data = create_group_message_data(timestamp, sender_name, message)

    encrypted = encrypt_then_mac(secret, data)

    payload = bytearray()
    payload.append(channel_hash)
    payload.extend(encrypted)

    header = (TYPE_GRP_TXT << 2) | ROUTE_FLOOD  # 0x15

    packet = bytearray()
    packet.append(header)
    packet.append(0x00)  # path_len = 0
    packet.extend(payload)
    return bytes(packet)

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
    
    # Skip newline delimiter (device sends \n after checksum)
    newline = sock.recv(1)
    if newline and newline != b'\n':
        print(f"[!] Warning: expected newline, got {newline.hex()}")
    
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


def send_group_text(sock, message, sender_name):
    """Construct and send GRP_TXT packet via RS232 bridge."""
    packet = create_group_text_packet(sender_name, message)
    frame = create_rs232_frame(packet)
    sock.sendall(frame)
    print(f"[✓] Sent text as '{sender_name}' ({len(packet)}B packet)")

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
        print(f"  {sys.argv[0]} <host> [port] [sender]")
        print()
        print("Example:")
        print(f"  {sys.argv[0]} 192.168.0.100 5002 Alice")
        print()
        print("Interactive commands:")
        print("  <hex>        - Send raw packet (e.g., 15001165E1B5...)")
        print("  msg <text>   - Build+send public GRP_TXT as sender")
        print("  name <nick>  - Change sender name for msg")
        print("  quit/exit    - Disconnect")
        sys.exit(1)
    
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5002
    sender_name = sys.argv[3] if len(sys.argv) > 3 else f"Bot{random.randint(1, 999)}"
    
    print(f"[*] Connecting to {host}:{port}...")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    
    try:
        sock.connect((host, port))
        print(f"[✓] Connected!")
        print(f"[*] Sender: {sender_name}")
        print(f"\nType hex packet to send, or 'msg <text>' to auto-build public packet, or 'quit' to exit")
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
                
                lower = cmd.lower()

                if lower.startswith(("msg ", "/msg ", "text ", "/text ")):
                    text = cmd.split(" ", 1)[1].strip() if " " in cmd else ""
                    if text:
                        send_group_text(sock, text, sender_name)
                    else:
                        print("[!] No text provided")
                    continue

                if lower.startswith(("name ", "/name ")):
                    new_name = cmd.split(" ", 1)[1].strip()
                    if new_name:
                        sender_name = new_name
                        print(f"[*] Sender changed to {sender_name}")
                    else:
                        print("[!] No name provided")
                    continue

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
