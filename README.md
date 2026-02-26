# Xiao S3 WiFi TCP Bridge for MeshCore

Wrapper build system for MeshCore on Xiao ESP32-S3 that adds a LoRa ↔ WiFi/TCP bridge and repeater mode with remote console access.

The project is ready for both “build + upload” deployments and automation (e.g., Raspberry Pi host / CI runner).

## What you get

- Unified `build.sh` flow: clone → patch → configure flags → build → upload → monitor.
- Two firmware roles:
  - **Companion**: packet bridge over TCP.
  - **Repeater**: bridge + remote admin console.
- Stabilny transport binarny RS232Bridge (`C0 3E`, długość, Fletcher-16).
- Multi-client TCP support (`MAX_TCP_CLIENTS=4`).

## Practical usage

### Tryb 1: Companion (bridge LoRa ↔ TCP)

1. Configure `config.env`.
2. Uruchom:

```bash
./build.sh --build --upload
```

3. Read the IP from UART logs.
4. Connect your client to `5002` and receive/send RS232Bridge frames.

### Tryb 2: Repeater (bridge + zdalna konsola)

1. Configure `config.env` (including admin/guest passwords).
2. Uruchom:

```bash
./build.sh --repeater --build --upload
```

3. Use these ports:
   - `5002` – raw packets,
  - `5001` – clean CLI (text commands),
  - `5003` – optional CLI mirror (USB console mirrored over TCP; only with `--with-console-mirror`, useful for MQTT with https://analyzer.letsmesh.net/observer/onboard).

### Most common operational scenarios

- **First clean deployment**

```bash
./build.sh --clean --repeater --build --upload --monitor
```

- **Fast code iteration without re-cloning**

```bash
./build.sh --repeater --build --no-clone
```

- **Upload previously built firmware**

```bash
./build.sh --repeater --upload
```

- **Build artifacts only (no upload)**

```bash
./build.sh --repeater --build
```

- **Build without patching (upstream debug)**

```bash
./build.sh --repeater --build --no-patch
```

## Wymagania

- Xiao ESP32-S3 + radio LoRa,
- USB do flashowania,
- sieć WiFi 2.4 GHz,
- macOS/Linux + `git` + `platformio` (`pio`).

## Szybki start

### 1) Klon repo i konfiguracja

```bash
git clone https://github.com/zm0ra/meshcore-xiao-wifi-serial2tcp.git
cd meshcore-xiao-wifi-serial2tcp
cp config.env.example config.env
nano config.env
```

Minimum do ustawienia:

```bash
WIFI_SSID="YourNetwork"
WIFI_PASSWORD="YourPassword"
LORA_FREQ=869.618
UPLOAD_PORT="/dev/cu.usbmodemXXXX"   # optional, auto-detect works when empty
```

### 2) Build i upload

```bash
# Companion
./build.sh --build --upload

# Repeater
./build.sh --repeater --build --upload
```

After boot, look for these log lines:

```text
[TCP] Raw packet server started on <ip>:5002
[CONSOLE] TCP console started on <ip>:5001
[CONSOLE] TCP mirror started on <ip>:5003
```

### 3) Test połączeń

```bash
# Raw packets
nc -vz <device-ip> 5002

# Clean CLI
nc -vz <device-ip> 5001

# Mirror CLI (repeater, only with --with-console-mirror)
nc -vz <device-ip> 5003
```

## Opcje `build.sh`

```text
Usage: ./build.sh [--repeater] --build [--upload] [OPTIONS]
```

Key options:

- `--repeater` – switch role to repeater (`PIO_ENV=Xiao_S3_WIO_repeater`).
- `--build` – full build pipeline.
- `--upload` – upload existing firmware (or build+upload with `--build`).
- `--monitor` – start `pio device monitor` after upload.
- `--clean` – remove working directory (`WORK_DIR`).
- `--no-clone` – skip upstream repo cloning.
- `--no-patch` – skip patch application.
- `--with-console-mirror` – enable legacy USB console mirror on `5003` (repeater).
- `--build-only` – build only, without clone/patch/config.

Przykłady:

```bash
./build.sh --clean --build
./build.sh --repeater --build --upload --monitor
./build.sh --build --no-clone --no-patch
./build.sh --upload
```

## Ports and operating modes

| Tryb | Port | Opis |
|------|------|------|
| Companion + Repeater | `5002` | Raw bridge (RS232Bridge) |
| Repeater | `5001` | Clean CLI console (text commands) |
| Repeater | `5003` | Optional console mirror (USB console echo over TCP; only with `--with-console-mirror`, useful for MQTT with https://analyzer.letsmesh.net/observer/onboard) |

## Konfiguracja (`config.env`)

Key variables:

- **WiFi / TCP**: `WIFI_SSID`, `WIFI_PASSWORD`, `TCP_PORT`, `CONSOLE_PORT`, `WIFI_DEBUG_LOGGING`
- **LoRa**: `LORA_FREQ`, `LORA_BW`, `LORA_SF`, `LORA_CR`, `LORA_TX_POWER`
- **Identity**: `ADVERT_NAME`, `ADVERT_LAT`, `ADVERT_LON`, `ADMIN_PASSWORD`, `GUEST_PASSWORD`
- **Debug**: `MESH_PACKET_LOGGING`, `MESH_DEBUG`, `BRIDGE_DEBUG`, `BLE_DEBUG_LOGGING`
- **Build orchestration**: `USE_UPSTREAM_BUILD`, `EXTRA_BUILD_FLAGS`, `FIRMWARE_VERSION`
- **Infra**: `UPLOAD_PORT`, `REPO_URL`, `REPO_BRANCH`, `WORK_DIR`, `PIO_ENV`

`config.env.example` contains the full set and default values.

## Protokół TCP (RS232Bridge)

Każda ramka:

```text
[Magic:2] [Length:2] [Payload:N] [Checksum:2] [Newline:1]
  C0 3E      00 15      ...         D9 B0        0A
```

- `Magic`: zawsze `C0 3E`
- `Length`: big-endian, długość `Payload`
- `Checksum`: Fletcher-16 po `Payload`
- TCP input ignores `\r/\n`, TCP output appends `\n` after each frame

## What gets patched

W katalogu `patches/`:

- `01-mymesh-header.patch`
- `02-mymesh-implementation.patch`
- `03-platformio-xiao-config.patch` *(legacy, skipped by default by the script)*
- `04-platformio-base.patch`
- `05-xiao-board-led.patch`
- `06-simple-repeater-platformio.patch`
- `07-simple-repeater-wifi-tcp.patch`
- `07b-simple-repeater-wifi-tcp-header.patch`
- `08-add-wifi-macros-defaults.patch`
- `09-simple-repeater-tcp-console-header.patch`
- `09b-simple-repeater-tcp-console.patch`

## Typical developer workflow

```bash
# full clean build
./build.sh --clean --repeater --build

# upload already-built firmware only
./build.sh --repeater --upload

# monitor logs
./build.sh --repeater --upload --monitor
```

Artifacts:

- `build/meshcore-firmware/.pio/build/<PIO_ENV>/firmware.bin`
- `build/meshcore-firmware/.pio/build/<PIO_ENV>/firmware-merged.bin` (if generated by the upstream merge step)

## Troubleshooting (quick)

### 1) `DuplicateSectionError` in `variants/xiao_s3_wio/platformio.ini`

- Symptom: duplicate section, e.g. `env:Xiao_S3_WIO_companion_radio_wifi`.
- Script behavior: automatic deduplication of `[env:*]` sections + skip of legacy patch `03`.
- Manual fix: `./build.sh --clean --build`.

### 2) `pio -t upload` fails in `merge-bin.py` (`projenv`)

- This is a known upstream hook issue.
- Workaround: flash `firmware-merged.bin` directly with `esptool`.

Przykład:

```bash
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX --baud 921600 write-flash 0x0 \
  build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware-merged.bin
```

### 3) No WiFi connection

- check `WIFI_SSID` / `WIFI_PASSWORD`,
- tylko 2.4 GHz,
- check UART logs (`pio device monitor -b 115200`).

### 4) Missing USB port for upload

```bash
pio device list
```

Set `UPLOAD_PORT` in `config.env` if auto-detect does not find the device.

## Struktura projektu

```text
meshcore-xiao-wifi-serial2tcp/
├── build.sh
├── config.env.example
├── patches/
├── mesh_client.py
└── build/                  # tworzone automatycznie
    └── meshcore-firmware/
```

## Licencja

This project is based on upstream `MeshCore` and follows its licensing terms.
