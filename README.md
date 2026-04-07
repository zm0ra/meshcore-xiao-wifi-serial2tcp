# MeshCore Xiao S3 WiFi Serial-to-TCP Builder

This repository provides a wrapper build system and patch set for building custom MeshCore firmware for the Seeed XIAO ESP32S3 with WiFi-based TCP access.

It supports two target roles:

- Companion radio: LoRa mesh packets bridged over WiFi TCP on port `5002`
- Repeater: the same TCP bridge on port `5002`, plus a remote CLI console on port `5001` and HTTP stats on port `80`
- Repeater with console mirror: optional read-only mirror of the console output on port `5003`

## Overview

The project does not replace MeshCore. Instead, it:

- clones upstream MeshCore from GitHub,
- applies a local patch stack,
- injects your WiFi, LoRa, and identity settings,
- builds the requested PlatformIO environment,
- optionally uploads the firmware to the board.

The result is a XIAO ESP32S3 firmware image that exposes MeshCore traffic over TCP using the RS232Bridge frame format.

## Hardware and Software Requirements

You need:

- a Seeed XIAO ESP32S3-based board used with MeshCore,
- the appropriate LoRa radio hardware for your target setup,
- a USB connection for flashing,
- a 2.4 GHz WiFi network,
- macOS or Linux with `bash`, `git`, and `platformio` available in `PATH`.

PlatformIO can be installed with:

```bash
python3 -m pip install --user platformio
```

## Repository Layout

```text
.
├── build.sh
├── config.env
├── config.env.example
├── mesh_client.py
├── patches/
└── build/
    └── meshcore-firmware/
```

Key files:

- `build.sh`: main wrapper for clone, patch, configure, build, upload, and monitor
- `config.env.example`: template configuration file
- `config.env`: your local configuration
- `patches/`: custom changes applied on top of upstream MeshCore
- `mesh_client.py`: simple TCP client for interacting with the bridge
- `build/meshcore-firmware/`: generated working tree cloned from upstream MeshCore

## Quick Start

### 1. Clone this repository

```bash
git clone https://github.com/zm0ra/meshcore-xiao-wifi-serial2tcp.git
cd meshcore-xiao-wifi-serial2tcp
```

### 2. Create your local configuration

```bash
cp config.env.example config.env
```

Edit `config.env` and set at least:

```bash
WIFI_SSID="YourNetworkName"
WIFI_PASSWORD="YourNetworkPassword"
LORA_FREQ=869.618
ADMIN_PASSWORD="changeme"
GUEST_PASSWORD="guest"
UPLOAD_PORT=""
```

Notes:

- `UPLOAD_PORT` can be left empty for auto-detection.
- On macOS, ports typically look like `/dev/cu.usbmodem*`.
- `ADMIN_PASSWORD` and `GUEST_PASSWORD` are required for repeater mode.

### 3. Build firmware

Companion radio:

```bash
./build.sh --build
```

Repeater:

```bash
./build.sh --repeater --build
```

Repeater with console mirror on port `5003`:

```bash
./build.sh --repeater --build --with-console-mirror
```

For ESP32 targets the wrapper also generates a merged image after a successful build:

```text
build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware-merged.bin
```

That file contains bootloader, partition table, and application merged into a single flashable image.

### 4. Upload firmware

Build and upload in one step:

```bash
./build.sh --build --upload
./build.sh --repeater --build --upload
./build.sh --repeater --build --upload --with-console-mirror
```

Upload an already built image without rebuilding:

```bash
./build.sh --upload
./build.sh --repeater --upload
```

`--upload` flashes the already built merged image and does not trigger a second firmware build.
By default it uses `esptool`/`esptool.py` from your PATH; if neither is installed, the wrapper
automatically clones the latest `esptool` from GitHub into `build/tools/esptool`, creates a local
Python virtual environment, and uses that copy for flashing.

If you are flashing manually with `esptool.py`, prefer the merged image:

```bash
esptool.py --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write_flash -z 0x0 \
    build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware-merged.bin
```

If you use `firmware.bin` instead, that is only the application image and must not be flashed alone at `0x0`.

### 5. Open the serial monitor

To upload and then immediately open the serial monitor:

```bash
./build.sh --build --upload --monitor
./build.sh --repeater --build --upload --monitor
```

If the device boots successfully, you should see log lines similar to:

```text
[TCP] Raw packet server started on <ip>:5002
[CONSOLE] TCP console started on <ip>:5001
[HTTP] Stats endpoint started on http://<ip>:80/stats
[CONSOLE] TCP mirror started on <ip>:5003
```

The mirror line appears only when built with `--with-console-mirror`.

## Flashing Notes

On ESP32, PlatformIO normally builds multiple images:

- `bootloader.bin`
- `partitions.bin`
- `firmware.bin`

The wrapper now also generates:

- `firmware-merged.bin`

Use cases:

- `firmware-merged.bin`: easiest manual flashing option, write at `0x0`
- `firmware.bin`: application only, use only when bootloader and partition table on the device already match

If you want to flash separate files manually, use the standard ESP32 layout:

```bash
esptool.py --chip esp32s3 --port /dev/ttyACM0 erase_flash

esptool.py --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write_flash -z \
    0x0 build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/bootloader.bin \
    0x8000 build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/partitions.bin \
    0xe000 ~/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin \
    0x10000 build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware.bin
```

## Firmware Modes

### Companion radio

Purpose:

- exposes the MeshCore packet stream over TCP,
- accepts RS232Bridge-framed packets back from TCP clients,
- useful for external tooling, integrations, and packet inspection.

Default network port:

- `5002`: raw bridge

### Repeater

Purpose:

- behaves as a MeshCore repeater,
- exposes the same raw TCP bridge,
- adds a remote line-based CLI console.

Default network ports:

- `5002`: raw bridge
- `5001`: interactive console
- `80`: HTTP JSON stats (`/stats`, `/stats.json`)

### Repeater with console mirror

Purpose:

- same as repeater mode,
- adds a read-only console mirror for passive observers.

Default network ports:

- `5002`: raw bridge
- `5001`: interactive console
- `5003`: read-only console mirror
- `80`: HTTP JSON stats (`/stats`, `/stats.json`)

## Build Script Behavior

The wrapper script performs these steps when `--build` is used:

1. validate `config.env`,
2. clone upstream MeshCore into `build/meshcore-firmware`,
3. apply local patches from `patches/`,
4. update `variants/xiao_s3_wio/platformio.ini` with your settings,
5. run PlatformIO clean,
6. build the selected environment,
7. optionally upload the resulting firmware,
8. optionally open the serial monitor.

Important implementation detail:

- patch `03-platformio-xiao-config.patch` is skipped for repeater builds because current upstream MeshCore already contains the companion WiFi section it used to add.

## Build Script Options

Current supported CLI options:

```text
Usage: ./build.sh [--repeater] --build [--upload] [OPTIONS]

Firmware Roles:
    (default)      Build companion radio (WiFi + LoRa bridge)
    --repeater     Build repeater (mesh relay with admin interface)

Steps:
    --build        Clone/patch/configure (unless skipped) and build firmware
    --upload       Upload previously built firmware (combine with --build to build+upload)

Options:
    --with-console-mirror  Repeater only: expose read-only console mirror on port 5003
    --no-clone     Skip repository cloning (use existing checkout)
    --no-patch     Skip applying patches
    --monitor      Upload and start serial monitor
    --build-only   Build without clone/patch/config steps
    --help         Show this help
```

Examples:

```bash
./build.sh --build
./build.sh --build --upload
./build.sh --repeater --build
./build.sh --repeater --build --upload
./build.sh --repeater --build --with-console-mirror
./build.sh --repeater --build --upload --with-console-mirror
./build.sh --build-only
./build.sh --no-clone --no-patch --build
```

## Configuration Reference

The build uses `config.env`. The most important settings are listed below.

### WiFi and TCP

| Variable | Default | Meaning |
|---|---:|---|
| `WIFI_SSID` | `YourNetworkName` | WiFi SSID |
| `WIFI_PASSWORD` | `YourNetworkPassword` | WiFi password |
| `TCP_PORT` | `5002` | Raw packet bridge port |
| `CONSOLE_PORT` | `5001` | Repeater console port |
| `HTTP_STATS_PORT` | `80` | Repeater HTTP stats endpoint port |
| `CONSOLE_MIRROR_PORT` | `5003` | Repeater console mirror port |
| `WIFI_DEBUG_LOGGING` | `1` | Enable WiFi-related serial logging |
| `MQTT_REPORTING_ENABLED` | `0` | Include MQTT reporting flag in firmware (`mqtt.enabled` in stats JSON) |

### LoRa radio

| Variable | Default | Meaning |
|---|---:|---|
| `LORA_FREQ` | `869.618` | Frequency in MHz |
| `LORA_BW` | `62.5` | Bandwidth in kHz |
| `LORA_SF` | `8` | Spreading factor |
| `LORA_CR` | `5` | Coding rate |
| `LORA_TX_POWER` | `22` | TX power |

You must set LoRa values appropriate for your region and your MeshCore network.

### Repeater access

| Variable | Default | Meaning |
|---|---:|---|
| `ADMIN_PASSWORD` | `changeme` or `password` depending on file creation path | Repeater admin password |
| `GUEST_PASSWORD` | `guest` | Repeater guest password |

### Identity and advertising

| Variable | Default | Meaning |
|---|---:|---|
| `ADVERT_NAME` | `XiaoS3 WiFi` | Advertised node name |
| `ADVERT_LAT` | `0.0` | Advertised latitude |
| `ADVERT_LON` | `0.0` | Advertised longitude |

### Build and upload

| Variable | Default | Meaning |
|---|---:|---|
| `BUILD_ROLE` | `companion` | Default role if CLI does not override it |
| `PIO_ENV` | `Xiao_S3_WIO_companion_radio_wifi` | Default PlatformIO environment |
| `UPLOAD_PORT` | empty | Explicit serial device path, if auto-detection is not enough |
| `REPO_URL` | upstream MeshCore repo | Source repository to clone |
| `REPO_BRANCH` | `main` | Upstream branch |
| `WORK_DIR` | `./build` | Working directory for the generated upstream checkout |

## Network Interfaces

### Raw TCP bridge: port 5002

This port carries RS232Bridge frames containing MeshCore packets.

Use it when you want to:

- inspect traffic,
- connect external tooling,
- feed packets into the device from a TCP client.

Example:

```bash
nc <device-ip> 5002
python3 mesh_client.py <device-ip> 5002
```

### Repeater console: port 5001

This port is available only in repeater builds.

It provides an interactive line-based console backed by the existing MeshCore CLI handler.

Example:

```bash
nc <device-ip> 5001
```

### Console mirror: port 5003

This port is available only when the firmware is built with `--with-console-mirror`.

It is intended for passive observers. It mirrors console output but does not provide an interactive CLI session.

Example:

```bash
nc <device-ip> 5003
```

### HTTP stats: port 80

This endpoint is available in repeater builds and returns JSON with:

- `radio` runtime counters and signal/airtime values,
- `mqtt` status/counters (for MQTT-enabled builds),
- `tcp` traffic/client counters.

Examples:

```bash
curl http://<device-ip>/stats
curl http://<device-ip>/stats.json
```

## RS232Bridge Protocol

The TCP bridge uses the RS232Bridge framing format.

Frame layout:

```text
[Magic:2] [Length:2] [Payload:N] [Checksum:2] [LF:1]
  C0 3E      00 15      ...         D9 B0      0A
```

Field meaning:

- `Magic`: fixed `C0 3E`
- `Length`: big-endian payload length
- `Payload`: raw MeshCore packet
- `Checksum`: Fletcher-16 over the payload
- `LF`: newline appended by the bridge for stream-friendly parsing

Input handling notes:

- incoming `\r` and `\n` are ignored by the parser,
- only valid RS232Bridge frames are accepted,
- multiple TCP clients can be connected at the same time,
- outgoing frames are broadcast to all connected bridge clients.

## Using mesh_client.py

The included `mesh_client.py` is a simple helper for talking to the raw TCP bridge.

Example:

```bash
python3 mesh_client.py <device-ip> 5002
```

Important limitations:

- it wraps your hex payload into RS232Bridge framing,
- it does not generate valid high-level MeshCore application packets for you,
- if the mesh requires a fully formed packet with signatures, MICs, or other upstream-specific encoding, you must provide a packet that is already complete.

## What the Patches Add

At a high level, the local patch set does the following:

- companion firmware: WiFi TCP bridging of MeshCore packets,
- repeater firmware: raw TCP bridge plus line-based remote console,
- optional repeater extension: read-only console mirror,
- XIAO board-specific and PlatformIO adjustments needed to build the modified firmware.

## Typical Workflows

### Build a companion image only

```bash
./build.sh --build
```

### Build and upload a repeater image

```bash
./build.sh --repeater --build --upload
```

### Build, upload, and monitor a repeater with console mirror

```bash
./build.sh --repeater --build --upload --monitor --with-console-mirror
```

### Reuse an existing upstream checkout

```bash
./build.sh --no-clone --build
```

### Reuse an existing checkout and skip patch application

```bash
./build.sh --no-clone --no-patch --build
```

### Build an already prepared working tree

```bash
./build.sh --build-only
```

## Troubleshooting

### Build was interrupted and `firmware.bin` is missing

This is the most common reason for an apparently failed build in this repository. If the terminal shows `Build interrupted` or `AbortedByUser`, the build did not finish.

Run a clean build again:

```bash
rm -rf build/meshcore-firmware
./build.sh --repeater --build --with-console-mirror
```

### WiFi does not connect

Check:

- `WIFI_SSID` and `WIFI_PASSWORD` in `config.env`,
- that the network is 2.4 GHz,
- serial output for connection errors.

### Upload port cannot be found

List serial devices:

```bash
pio device list
```

If needed, set `UPLOAD_PORT` explicitly in `config.env`.

### TCP port cannot be reached

Check:

- the device IP shown in the serial log,
- that your client is on the same network,
- that you are connecting to the correct port for the selected firmware mode,
- that the board successfully joined WiFi before you attempted the connection.

### The mirror port is missing

The repeater console mirror is not enabled automatically. You must build with:

```bash
./build.sh --repeater --build --with-console-mirror
```

or:

```bash
./build.sh --repeater --build --upload --with-console-mirror
```

## Output Files

The main build artifact is:

```text
build/meshcore-firmware/.pio/build/<environment>/firmware.bin
```

For the repeater environment used by this repository, that usually means:

```text
build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware.bin
```

## License

This repository is a build wrapper and patch set around upstream MeshCore. Refer to upstream MeshCore and included upstream license files for licensing details.
