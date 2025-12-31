# Xiao S3 Companion Radio Builder

Automated build system for MeshCore companion radio firmware with WiFi + TCP serial bridge.

## Features

- ✅ Automatic repository cloning
- ✅ Code patching (bidirectional TCP bridge)
- ✅ WiFi configuration (SSID/password)
- ✅ Automated build with PlatformIO
- ✅ One-command firmware upload
- ✅ Serial monitor integration

## Quick Start

### 1. Edit Configuration

```bash
cd xiao-companion-builder
cp config.env.example config.env
nano config.env
```

Set your WiFi credentials (DHCP only):
```bash
WIFI_SSID="YourNetwork"
WIFI_PASSWORD="YourPassword"
TCP_PORT=5002
WIFI_DEBUG_LOGGING=1

# LoRa radio
LORA_FREQ=869.618
LORA_BW=62.5
LORA_SF=8
LORA_CR=5
LORA_TX_POWER=22

# Other flags are listed below (memory/display/debug/identity)
UPLOAD_PORT=""  # Leave empty for auto-detect
```

### 2. Configure Radio Settings (Optional)

The firmware uses default MeshCore radio presets. To customize:

Edit `src/Identity.cpp` in the cloned repo after first build:
```cpp
// Default: UK narrow preset (869.618 MHz, 62.5kHz BW, SF8)
// To change: modify RadioConfig in Identity initialization
```

Or modify patches to inject your preferred region/preset.

### 2.1. Configurable Build Flags (config.env)

| Area | Variable | Default | Notes |
|------|----------|---------|-------|
| WiFi | WIFI_SSID / WIFI_PASSWORD | YourNetwork / YourPassword | WiFi credentials |
| WiFi | TCP_PORT | 5002 | TCP raw bridge port |
| WiFi | WIFI_DEBUG_LOGGING | 1 | Enable WiFi debug on Serial |
| LoRa | LORA_FREQ / LORA_BW / LORA_SF / LORA_CR | 869.618 / 62.5 / 8 / 5 | Radio preset |
| LoRa | LORA_TX_POWER | 22 | TX power (dBm) |
| Memory | MAX_CONTACTS / MAX_GROUP_CHANNELS | 350 / 40 | Limits |
| Memory | OFFLINE_QUEUE_SIZE / MAX_UNREAD_MSGS / MAX_BLOBRECS | 256 / 32 / 100 | Queues/buffers |
| Display | DISPLAY_CLASS | SSD1306Display | Display driver |
| Display | AUTO_OFF_MILLIS | 15000 | Screen auto-off (ms) |
| Display | UI_RECENT_LIST_SIZE | 4 | Recent items list |
| Debug | MESH_PACKET_LOGGING / MESH_DEBUG | 1 / 1 | Mesh debug switches |
| Debug | BRIDGE_DEBUG / BLE_DEBUG_LOGGING | 0 / 0 | Additional debug |
| Identity | ADVERT_NAME | XiaoS3 WiFi | Mesh advert name |
| Identity | ADVERT_LAT / ADVERT_LON | 0.0 / 0.0 | Coordinates |
| Identity | ADMIN_PASSWORD | password | Admin password |

### 3. Build Firmware

```bash
./build_companion.sh
```

This will:
- Clone meshcore-firmware repository
- Apply TCP serial patches
- Configure WiFi settings
- Build firmware

### 3. Upload to Device

```bash
./build_companion.sh --upload
```

Or build + upload + monitor:
```bash
./build_companion.sh --monitor
```

## Usage Options

```bash
./build_companion.sh [OPTIONS]

Options:
  --no-clone     Skip repository cloning (use existing)
  --no-patch     Skip applying patches
  --upload       Upload firmware after build
  --monitor      Upload and start serial monitor
  --build-only   Only build (skip clone/patch/config)
  --help         Show help
```

## What Gets Patched

### 1. MyMesh.h
- Adds `sendPacketToTcpClients()` declaration
- Adds `displayReceivedPacket()` declaration

### 2. MyMesh.cpp
- **onChannelMessageRecv()** - forwards group messages to TCP
- **onRawDataRecv()** - forwards raw packets to TCP
- **handleRawPacketServer()** - displays received packets
- **sendPacketToTcpClients()** - sends mesh packets via TCP (RS232Bridge)
- **displayReceivedPacket()** - pretty-prints packet details

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

## Configuration Reference

Pełna lista konfigurowalnych flag jest w tabeli „Configurable Build Flags (config.env)” powyżej.

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
├── build_companion.sh          # Main build script
├── config.env                  # Configuration file
├── README.md                   # This file
├── patches/
│   ├── 01-mymesh-header.patch  # MyMesh.h changes
│   └── 02-mymesh-implementation.patch  # MyMesh.cpp changes
└── build/
    └── meshcore-firmware/      # Cloned repository (auto-created)
```

## Advanced Usage

### Rebuild without re-cloning:
```bash
./build_companion.sh --no-clone
```

### Rebuild without re-patching:
```bash
./build_companion.sh --no-clone --no-patch
```

### Just build (no config changes):
```bash
./build_companion.sh --build-only
```

## Protocol Details

### RS232Bridge Frame Format
```
[Magic:2] [Length:2BE] [Packet:N] [Checksum:2]
 C0 3E     00 15        ...         D9 B0
```

### MeshCore Packet Format
```
[Header:1] [PathLen:1] [PayloadLen:1] [Payload:N]
 0x15       0x00         0x11          ...
```

Header bits: `[Version:2][Type:4][Route:2]`

## License

Based on meshcore-firmware project. See repository for licensing details.
