# Xiao S3 WiFi TCP Bridge for MeshCore

Wrapper build system dla MeshCore na Xiao ESP32-S3, który dodaje most LoRa ↔ WiFi/TCP oraz tryb repeatera z konsolą zdalną.

Projekt jest gotowy pod wdrożenia „build + upload” i pod automatyzację (np. host na Raspberry Pi / CI runner).

## Co to daje

- Jednolite `build.sh` do: clone → patch → konfiguracja flag → build → upload → monitor.
- Dwa role firmware:
  - **Companion**: bridge pakietów na TCP.
  - **Repeater**: bridge + zdalna konsola administracyjna.
- Stabilny transport binarny RS232Bridge (`C0 3E`, długość, Fletcher-16).
- Obsługa wielu klientów TCP równolegle (`MAX_TCP_CLIENTS=4`).

## Jak tego używać w praktyce

### Tryb 1: Companion (bridge LoRa ↔ TCP)

1. Skonfiguruj `config.env`.
2. Uruchom:

```bash
./build.sh --build --upload
```

3. Odczytaj IP z logu UART.
4. Podłącz klienta do `5002` i odbieraj/wysyłaj ramki RS232Bridge.

### Tryb 2: Repeater (bridge + zdalna konsola)

1. Skonfiguruj `config.env` (w tym hasła admin/guest).
2. Uruchom:

```bash
./build.sh --repeater --build --upload
```

3. Używaj portów:
   - `5002` – raw packets,
   - `5001` – clean CLI (komendy tekstowe),
   - `5003` – mirror CLI (odbicie konsoli USB).

### Najczęstsze scenariusze operacyjne

- **Pierwsze wdrożenie na czysto**

```bash
./build.sh --clean --repeater --build --upload --monitor
```

- **Szybka iteracja kodu bez ponownego klonowania**

```bash
./build.sh --repeater --build --no-clone
```

- **Upload wcześniej zbudowanego firmware**

```bash
./build.sh --repeater --upload
```

- **Sam build artefaktów (bez uploadu)**

```bash
./build.sh --repeater --build
```

- **Build bez patchowania (debug upstreamu)**

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
WIFI_SSID="TwojaSiec"
WIFI_PASSWORD="TwojeHaslo"
LORA_FREQ=869.618
UPLOAD_PORT="/dev/cu.usbmodemXXXX"   # opcjonalnie, auto-detect działa gdy puste
```

### 2) Build i upload

```bash
# Companion
./build.sh --build --upload

# Repeater
./build.sh --repeater --build --upload
```

Po starcie firmware szukaj w logu:

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

# Mirror CLI (repeater)
nc -vz <device-ip> 5003
```

## Opcje `build.sh`

```text
Usage: ./build.sh [--repeater] --build [--upload] [OPTIONS]
```

Najważniejsze opcje:

- `--repeater` – przełącza rolę na repeater (`PIO_ENV=Xiao_S3_WIO_repeater`).
- `--build` – pełny pipeline build.
- `--upload` – upload istniejącego firmware (lub z `--build` build+upload).
- `--monitor` – po uploadzie startuje `pio device monitor`.
- `--clean` – kasuje katalog roboczy (`WORK_DIR`).
- `--no-clone` – bez klonowania upstream repo.
- `--no-patch` – bez nakładania patchy.
- `--build-only` – sam build, bez clone/patch/config.

Przykłady:

```bash
./build.sh --clean --build
./build.sh --repeater --build --upload --monitor
./build.sh --build --no-clone --no-patch
./build.sh --upload
```

## Porty i tryby pracy

| Tryb | Port | Opis |
|------|------|------|
| Companion + Repeater | `5002` | Raw bridge (RS232Bridge) |
| Repeater | `5001` | Clean CLI console (komendy tekstowe) |
| Repeater | `5003` | Console mirror (echo konsoli USB po TCP) |

## Konfiguracja (`config.env`)

Kluczowe zmienne:

- **WiFi / TCP**: `WIFI_SSID`, `WIFI_PASSWORD`, `TCP_PORT`, `CONSOLE_PORT`, `WIFI_DEBUG_LOGGING`
- **LoRa**: `LORA_FREQ`, `LORA_BW`, `LORA_SF`, `LORA_CR`, `LORA_TX_POWER`
- **Identity**: `ADVERT_NAME`, `ADVERT_LAT`, `ADVERT_LON`, `ADMIN_PASSWORD`, `GUEST_PASSWORD`
- **Debug**: `MESH_PACKET_LOGGING`, `MESH_DEBUG`, `BRIDGE_DEBUG`, `BLE_DEBUG_LOGGING`
- **Build orchestration**: `USE_UPSTREAM_BUILD`, `EXTRA_BUILD_FLAGS`, `FIRMWARE_VERSION`
- **Infra**: `UPLOAD_PORT`, `REPO_URL`, `REPO_BRANCH`, `WORK_DIR`, `PIO_ENV`

`config.env.example` zawiera pełny zestaw i domyślne wartości.

## Protokół TCP (RS232Bridge)

Każda ramka:

```text
[Magic:2] [Length:2] [Payload:N] [Checksum:2] [Newline:1]
  C0 3E      00 15      ...         D9 B0        0A
```

- `Magic`: zawsze `C0 3E`
- `Length`: big-endian, długość `Payload`
- `Checksum`: Fletcher-16 po `Payload`
- wejście TCP ignoruje `\r/\n`, wyjście dodaje `\n` po ramce

## Co jest patchowane

W katalogu `patches/`:

- `01-mymesh-header.patch`
- `02-mymesh-implementation.patch`
- `03-platformio-xiao-config.patch` *(legacy, domyślnie pomijany przez skrypt)*
- `04-platformio-base.patch`
- `05-xiao-board-led.patch`
- `06-simple-repeater-platformio.patch`
- `07-simple-repeater-wifi-tcp.patch`
- `07b-simple-repeater-wifi-tcp-header.patch`
- `08-add-wifi-macros-defaults.patch`
- `09-simple-repeater-tcp-console-header.patch`
- `09b-simple-repeater-tcp-console.patch`

## Typowy workflow developerski

```bash
# pełny świeży build
./build.sh --clean --repeater --build

# sam upload już zbudowanego firmware
./build.sh --repeater --upload

# monitor logów
./build.sh --repeater --upload --monitor
```

Artefakty:

- `build/meshcore-firmware/.pio/build/<PIO_ENV>/firmware.bin`
- `build/meshcore-firmware/.pio/build/<PIO_ENV>/firmware-merged.bin` (jeśli wygenerowany przez upstream merge step)

## Troubleshooting (skrót)

### 1) `DuplicateSectionError` w `variants/xiao_s3_wio/platformio.ini`

- Objaw: duplikat np. `env:Xiao_S3_WIO_companion_radio_wifi`.
- Co robi skrypt: automatyczna deduplikacja sekcji `[env:*]` + skip legacy patcha `03`.
- Co zrobić ręcznie: `./build.sh --clean --build`.

### 2) Upload przez `pio -t upload` wywala się na `merge-bin.py` (`projenv`)

- To znany problem hooka upstream.
- Obejście: flash `firmware-merged.bin` bezpośrednio przez `esptool`.

Przykład:

```bash
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX --baud 921600 write-flash 0x0 \
  build/meshcore-firmware/.pio/build/Xiao_S3_WIO_repeater/firmware-merged.bin
```

### 3) Brak połączenia z WiFi

- sprawdź `WIFI_SSID` / `WIFI_PASSWORD`,
- tylko 2.4 GHz,
- sprawdź log UART (`pio device monitor -b 115200`).

### 4) Brak portu USB do uploadu

```bash
pio device list
```

Ustaw `UPLOAD_PORT` w `config.env`, jeśli auto-detect nie trafi.

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

Projekt bazuje na upstream `MeshCore` i jego licencjonowaniu.
