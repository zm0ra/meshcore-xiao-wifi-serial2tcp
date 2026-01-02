# Xiao S3 WiFi TCP Bridge for MeshCore

Build system for MeshCore firmware on Xiao S3 that bridges LoRa mesh packets over WiFi TCP.

Supports two firmware roles:
- **Companion radio**: raw packet bridge over TCP (default port 5002)
- **Repeater**: raw packet bridge (default port 5002) **plus** a remote CLI console over TCP (default port 5001)

## What Is This?

- **Device**: Xiao S3 microcontroller + LoRa radio running MeshCore firmware
- **Bridge**: Converts mesh LoRa packets to WiFi TCP and vice versa
- **TCP Interface**: Connect via standard socket (`nc`, telnet, Python) - no special app needed
- **Multi-client**: Up to 4 simultaneous TCP connections supported
- **Protocol**: RS232Bridge binary format with checksums for robustness

## Features

- ✅ One-command build & upload to Xiao S3
- ✅ WiFi configuration (SSID/password)  
- ✅ Binary protocol with Fletcher-16 checksums
- ✅ Multi-client TCP server (4 simultaneous connections)
- ✅ Real-time packet inspection
- ✅ Full LoRa config (frequency, bandwidth, spreading factor, TX power)
- ✅ Serial monitor integration for debugging
- ✅ (Repeater) Remote TCP console (port 5001)

## Prerequisites

- Xiao S3 microcontroller with LoRa hat
- USB cable for firmware upload
- WiFi network (2.4GHz, open or WPA2)
- macOS/Linux with bash, `pip`, `platformio`

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/zm0ra/meshcore-xiao-wifi-serial2tcp.git
cd meshcore-xiao-wifi-serial2tcp
```

### 2. Configure WiFi & Radio

```bash
cp config.env.example config.env
nano config.env
```

Edit these essentials:
```bash
WIFI_SSID="YourNetwork"
WIFI_PASSWORD="YourPassword"
LORA_FREQ=869.618          # Your region (e.g., 915 for US)
UPLOAD_PORT="/dev/ttyUSB0" # Or /dev/cu.usbmodem* on macOS
```

### 3. Build & Upload

```bash
# Companion (default)
./build.sh --build --upload

# Repeater (enables TCP console on :5001)
./build.sh --repeater --build --upload
```

This will:
1. Clone MeshCore firmware
2. Apply TCP bridge patches
3. Configure WiFi settings
4. Build with PlatformIO
5. Upload to Xiao S3
6. Start serial monitor (watch boot logs)

When upload completes, watch serial monitor for:
```
[TCP] Raw packet server started on <ip>:5002
[CONSOLE] TCP console started on <ip>:5001
```

### 4. Connect & Test

Find device IP from serial monitor, then:

```bash
# Option A: Python interactive client (included)
python3 mesh_client.py 192.168.X.X 5002

# Option B: Simple netcat viewer
nc -v 192.168.X.X 5002

# Option C: Send raw packet with netcat
echo -ne "\xC0\x3E\x00\x05HELLO" | nc 192.168.X.X 5002

# (Repeater) TCP console
nc -v 192.168.X.X 5001
```

TCP console is line-based and accepts both CRLF and LF-only (so plain `nc` works). After connecting you should see a prompt (`> `). Try `help` / `ver` depending on your MeshCore CLI.

In Python client, use commands:
```
msg Hello from device!   # Send text on public channel
quit                     # Disconnect
```

### 5. Watch What Happens

- **Received mesh packets** appear as binary RS232Bridge frames (magic `C0 3E`)
- **Serial monitor** shows decoded packet info: route, type, SNR, RSSI
- **Multiple clients** can connect simultaneously; all receive broadcasts

## Understanding the Protocol

### TCP Data Format: RS232Bridge

Every packet is wrapped:
```
[Magic:2] [Length:2] [Payload:N] [Checksum:2] [Newline:1]
  C0 3E      00 15      ...         D9 B0        0A
```

**Magic**: Always `C0 3E` (start of frame)  
**Length**: Big-endian 16-bit, payload only  
**Payload**: Raw MeshCore packet bytes  
**Checksum**: Fletcher-16 over payload  
**Newline**: `\n` for stream parsing (optional, some clients may ignore)

### MeshCore Packet Inside

```
[Header:1] [Path:N] [Payload:N]
  0x15      00 01      ...
```

**Header** (bits): `[Version:2][Type:4][Route:2]`
- Type: 0x04=ADVERT, 0x05=GRP_TXT, 0x02=TXT_MSG, etc.
- Route: 0=DIRECT, 1=FLOOD

**Path**: Hop hashes (length in byte 1 of packet)  
**Payload**: Encrypted/compressed message data

### Example Traffic

**Device → TCP (received ADVERT):**
```
[Device RX] ADVERT from node ABC123, SNR=6dB
[TCP TX] C0 3E 00 7A [121 bytes] 1F 3C 0A
```

**TCP → Device (your text message):**
```
[User] msg Hello!
[Client builds] 15 00 1C [28-byte encrypted text...]
[Client wraps] C0 3E 00 1C [28 bytes] 2E F5 0A
[Device RX] Injected as FLOOD to mesh
[Devices nearby] Receive & decrypt your message
```

## Configuration Reference

All config.env options:

| Area | Variable | Default | Notes |
|------|----------|---------|-------|
| **WiFi** | WIFI_SSID | YourNetwork | Network name |
| | WIFI_PASSWORD | YourPassword | Network password |
| | TCP_PORT | 5002 | Bridge listen port |
| | (Repeater) CONSOLE_PORT | 5001 | TCP CLI console port (compile-time; default is 5001) |
| | WIFI_DEBUG_LOGGING | 1 | Log WiFi events to serial |
| **LoRa** | LORA_FREQ | 869.618 | Center frequency (MHz) - adjust for your region |
| | LORA_BW | 62.5 | Bandwidth (kHz) |
| | LORA_SF | 8 | Spreading factor (7-12, higher=longer range but slower) |
| | LORA_CR | 5 | Coding rate |
| | LORA_TX_POWER | 22 | TX power (dBm, max 20-27 depending on board) |
| **Upload** | UPLOAD_PORT | (auto) | USB device `/dev/ttyUSB0` or `/dev/cu.usbmodem*` |
| **Display** | DISPLAY_CLASS | SSD1306Display | I2C OLED display driver |
| **Identity** | ADVERT_NAME | XiaoS3 WiFi | Your node name on the mesh |
| **Identity** | ADVERT_LAT / ADVERT_LON | 0.0 / 0.0 | Position (if you want to broadcast location) |

## What Gets Patched

### 1. MyMesh.h
- Adds WiFi include and MAX_TCP_CLIENTS fields for the TCP bridge
- Declares RS232Bridge helpers: handleRawPacketServer, parseRS232BridgePacket, sendPacketToTcpClients, sendRS232BridgeFrameToTcp, displayReceivedPacket, logPacketSummary, dumpHexLine

### 2. MyMesh.cpp
- Mirrors all received packets (private, signed, channel, raw) to TCP with RS232Bridge framing and console summaries
- Multi-client TCP server on port 5002; broadcasts outbound frames with trailing `\n`; ignores CR/LF on input and only accepts RS232Bridge frames for injection
- USB raw RX is mirrored to TCP using RS232Bridge framing (USB/TCP symmetry)
- Logging helpers to summarize packets and hex-dump payloads

### 3. (Repeater) TCP Console
- Adds a second TCP server on port 5001 for a simple line-based console
- Executes commands via the existing MeshCore CLI handler and returns replies

## Architecture

```
┌─────────────┐         TCP:5002         ┌──────────────┐
│   Python    │◄───────────────────────►│  Xiao S3     │
│   Scripts   │    RS232Bridge frames   │  Companion   │
└─────────────┘                          └──────┬───────┘
                                                │ LoRa
                                                ▼
                                         ┌──────────────┐
                                         │ Mesh Network │
                                         └──────────────┘

(Repeater mode also exposes TCP:5001 for a CLI console.)
```

## Testing

After upload, check the serial monitor for the DHCP-assigned IP, then test with the included client:

### Interactive client (send + receive):
```bash
python3 mesh_client.py <device-ip> 5002
```

Then enter raw packet hex:
```
> 15001165E1B5A9A7C5D0A179F274D748C709D2134C
```

Notes for sending packets with `mesh_client.py`:
- The script already wraps your hex payload in the RS232Bridge frame (adds magic, length, Fletcher-16).
- You must supply a complete MeshCore packet in hex (header + path length + payload length + payload). It does **not** build or sign/hash payloads for you.
- Use real packets captured from the device or generated by your own tooling; if the mesh expects MIC/signature, provide a packet that already contains it.
- Device adds a trailing `\n` to each TCP frame; the input parser ignores `\r`/`\n` and rejects non-RS232Bridge frames. Multiple TCP clients can connect; frames are broadcast to all connected peers.
- To watch traffic live: `./build.sh --build --upload --monitor` (or `--upload --monitor` if firmware is already built) and look for the DHCP IP before connecting the client.

### Repeater console (port 5001)

```bash
nc <device-ip> 5001
```

You should see `> ` and can type CLI commands (e.g. `help`).

## Troubleshooting

### Build fails with "port in use"
Close any serial monitors or other programs using the USB port.

### Upload MD5 error
Try again, or erase flash first:
```bash
cd build/meshcore-firmware
pio run -e Xiao_S3_WIO_companion_radio_wifi --target erase --upload-port /dev/cu.usbmodem1101
```

### WiFi doesn't connect
- Check SSID/password in config.env
- Verify WiFi network is 2.4GHz (ESP32-S3 doesn't support 5GHz)
- Check serial monitor for connection status

### Can't find upload port
List available ports:
```bash
pio device list
```

Update UPLOAD_PORT in config.env.

## File Structure

```
xiao-companion-builder/
├── build.sh          # Main build script
├── config.env                  # Configuration file
├── README.md                   # This file
├── patches/
│   ├── 01-mymesh-header.patch  # MyMesh.h changes
│   └── 02-mymesh-implementation.patch  # MyMesh.cpp changes
└── build/
    └── meshcore-firmware/      # Cloned repository (auto-created)
```

## Troubleshooting

### Issue: "Failed to connect to WiFi"

**Symptoms:** Serial shows `WiFi connect failed` or `No IP assigned`

**Solutions:**
- Verify WIFI_SSID and WIFI_PASSWORD in config.env
- Ensure network is 2.4GHz (Xiao S3 doesn't support 5GHz)
- Check if network uses hidden SSID (unsupported)
- Try WPA2 network instead of open WiFi
- Reboot device: unplug USB and reconnect

### Issue: "Cannot connect to TCP port 5002"

**Symptoms:** `nc -vvnc 192.168.x.x 5002` times out; firewall blocks; no connection

**Solutions:**
- Verify device IP from serial monitor output
- Ping device first: `ping 192.168.x.x` (should respond)
- Check firewall isn't blocking port 5002 on device network
- Try connecting from same machine as device (rule out network issues)
- Increase TCP timeout: `nc -vvnc -w 5 192.168.x.x 5002`

### Issue: "Firmware upload fails - device not found"

**Symptoms:** `No device found on /dev/ttyUSB0` or `Cannot find upload port`

**Solutions:**
- Check USB cable is properly connected
- Verify USB device appears: `ls /dev/cu.* /dev/ttyUSB*` (macOS/Linux)
- Install Xiao S3 USB drivers (should be auto in modern systems)
- Try different USB port or cable
- Force DFU mode: hold BOOT button while connecting USB (should show new device)
- Specify port manually in config.env: `UPLOAD_PORT=/dev/cu.usbmodem14201`

### Issue: "TCP receives data but client crashes/syncs incorrectly"

**Symptoms:** Random binary garbage, `Traceback: struct.unpack`, frame desync errors

**Solutions:**
- Verify you're using the provided `mesh_client.py` (handles RS232Bridge format)
- Raw `nc` won't parse protocol - only for hex inspection
- Ensure device is fully booted (wait 5 seconds after power)
- Check TCP timeout isn't too short - frames arrive ~500ms intervals
- Restart client connection to resync

### Issue: "No packets appearing in TCP - device boots but silent"

**Symptoms:** TCP connects OK; gets frame from bootup log but no mesh packets arrive

**Solutions:**
- Device receives LoRa packets - if mesh is quiet, nothing broadcasts
- Check other LoRa nodes are near and transmitting
- Verify antenna is connected properly (bad connection = no RX)
- Test transmission from another MeshCore node in range
- Serial monitor should show `[INFO] Packet RX:` for each frame received

### Issue: "Send message from client but device doesn't transmit"

**Symptoms:** `mesh_client.py` sends `msg hello` but no TX on device

**Solutions:**
- Verify device has channels configured (should default to public channel 0)
- Check TX power in config.env is not 0 (should be 20-22 dBm)
- Verify device isn't in receive mode or blocked
- Try using keyboard interface in `mesh_client.py` - sometimes raw text doesn't parse
- Check device logs show `[INFO] Flood TX:` when you send

## Advanced Usage

### Rebuild without re-cloning:
```bash
./build.sh --no-clone
```

### Rebuild without re-patching:
```bash
./build.sh --no-clone --no-patch
```

### Just build (no config changes):
```bash
./build.sh --build-only
```

## Protocol Details

### RS232Bridge Frame Format
```
[Magic:2] [Length:2BE] [Packet:N] [Checksum:2]
 C0 3E     00 15        ...         D9 B0
```

TCP sends a trailing `\n` after each frame; incoming TCP data ignores `\r`/`\n`.

### MeshCore Packet Format
```
[Header:1] [PathLen:1] [PayloadLen:1] [Payload:N]
 0x15       0x00         0x11          ...
```

Header bits: `[Version:2][Type:4][Route:2]`

## License

Based on meshcore-firmware project. See repository for licensing details.
