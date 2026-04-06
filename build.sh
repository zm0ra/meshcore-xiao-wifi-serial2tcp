#!/bin/bash
#
# Xiao S3 Companion Radio WiFi + TCP Serial Builder
# Automates: clone, patch, configure, build, upload
#

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
PATCHES_DIR="${SCRIPT_DIR}/patches"
DEFAULT_WORK_DIR="${SCRIPT_DIR}/build"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[!] Configuration file not found: ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}[*] Creating default config.env...${NC}"
    cat > "$CONFIG_FILE" << 'EOF'
# WiFi credentials (DHCP only)
WIFI_SSID="YourNetwork"
WIFI_PASSWORD="YourPassword"
TCP_PORT=5002
CONSOLE_PORT=5001
WIFI_DEBUG_LOGGING=1

# LoRa radio flags
LORA_FREQ=869.618
LORA_BW=62.5
LORA_SF=8
LORA_CR=5
LORA_TX_POWER=22

# Memory / queues / contacts
MAX_CONTACTS=350
MAX_GROUP_CHANNELS=40
OFFLINE_QUEUE_SIZE=256
MAX_UNREAD_MSGS=32
MAX_BLOBRECS=100

# Display
DISPLAY_CLASS=SSD1306Display
AUTO_OFF_MILLIS=15000
UI_RECENT_LIST_SIZE=4

# Debug (0=off,1=on)
MESH_PACKET_LOGGING=1
MESH_DEBUG=1
BRIDGE_DEBUG=0
BLE_DEBUG_LOGGING=0

# Build orchestration
USE_UPSTREAM_BUILD=1
FIRMWARE_VERSION="dev"
EXTRA_BUILD_FLAGS=""
ENABLE_CONSOLE_MIRROR_PATCH=0

# Identity / advertising
ADVERT_NAME="XiaoS3 WiFi"
ADVERT_LAT=0.0
ADVERT_LON=0.0
ADMIN_PASSWORD="password"
GUEST_PASSWORD="${GUEST_PASSWORD:-guest}"

# Build role (companion or repeater)
BUILD_ROLE="companion"

# Upload port (leave empty to auto-detect)
UPLOAD_PORT=""

# PlatformIO environment
PIO_ENV="Xiao_S3_WIO_companion_radio_wifi"

# Git repository
REPO_URL="https://github.com/ripplebiz/MeshCore"
REPO_BRANCH="main"

# Optional: override build directory (default: ./build)
# WORK_DIR="/absolute/path/to/workdir"
EOF
    echo -e "${GREEN}[✓] Created config.env - please edit it and run again${NC}"
    exit 0
fi

source "$CONFIG_FILE"

# Defaults for configurable build flags
WIFI_SSID="${WIFI_SSID:-YourNetwork}"
WIFI_PASSWORD="${WIFI_PASSWORD:-YourPassword}"
TCP_PORT=${TCP_PORT:-5002}
CONSOLE_PORT=${CONSOLE_PORT:-5001}
WIFI_DEBUG_LOGGING=${WIFI_DEBUG_LOGGING:-1}

LORA_FREQ=${LORA_FREQ:-869.618}
LORA_BW=${LORA_BW:-62.5}
LORA_SF=${LORA_SF:-8}
LORA_CR=${LORA_CR:-5}
LORA_TX_POWER=${LORA_TX_POWER:-22}

MAX_CONTACTS=${MAX_CONTACTS:-350}
MAX_GROUP_CHANNELS=${MAX_GROUP_CHANNELS:-40}
OFFLINE_QUEUE_SIZE=${OFFLINE_QUEUE_SIZE:-256}
MAX_UNREAD_MSGS=${MAX_UNREAD_MSGS:-32}
MAX_BLOBRECS=${MAX_BLOBRECS:-100}

DISPLAY_CLASS="${DISPLAY_CLASS:-SSD1306Display}"
AUTO_OFF_MILLIS=${AUTO_OFF_MILLIS:-15000}
UI_RECENT_LIST_SIZE=${UI_RECENT_LIST_SIZE:-4}

MESH_PACKET_LOGGING=${MESH_PACKET_LOGGING:-1}
MESH_DEBUG=${MESH_DEBUG:-1}
BRIDGE_DEBUG=${BRIDGE_DEBUG:-0}
BLE_DEBUG_LOGGING=${BLE_DEBUG_LOGGING:-0}

USE_UPSTREAM_BUILD=${USE_UPSTREAM_BUILD:-1}
FIRMWARE_VERSION="${FIRMWARE_VERSION:-dev}"
EXTRA_BUILD_FLAGS="${EXTRA_BUILD_FLAGS:-}"
ENABLE_CONSOLE_MIRROR_PATCH=${ENABLE_CONSOLE_MIRROR_PATCH:-0}

ADVERT_NAME="${ADVERT_NAME:-XiaoS3 WiFi}"
ADVERT_LAT=${ADVERT_LAT:-0.0}
ADVERT_LON=${ADVERT_LON:-0.0}
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password}"

# Allow overriding work directory via env or config
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
REPO_DIR="${REPO_DIR:-${WORK_DIR}/meshcore-firmware}"

# Functions
log_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

enforce_repeater_profile() {
    if [ "${BUILD_ROLE}" != "repeater" ]; then
        return
    fi

    # Keep behaviour aligned with normal repeater, while forcing packet logging
    # needed for MQTT ingestion from serial console.
    MESH_PACKET_LOGGING=1
    log_info "Repeater profile active: forcing MESH_PACKET_LOGGING=1"
}

validate_config() {
    log_info "Validating configuration for role: ${BUILD_ROLE}..."
    
    local missing=0
    
    if [ -z "$WIFI_SSID" ]; then
        log_error "WIFI_SSID is required"
        missing=1
    fi
    if [ -z "$WIFI_PASSWORD" ]; then
        log_error "WIFI_PASSWORD is required"
        missing=1
    fi
    
    if [ "$BUILD_ROLE" = "repeater" ]; then
        if [ -z "$ADMIN_PASSWORD" ]; then
            log_error "ADMIN_PASSWORD is required for repeater"
            missing=1
        fi
        if [ -z "$GUEST_PASSWORD" ]; then
            log_error "GUEST_PASSWORD is required for repeater"
            missing=1
        fi
        if [ -z "$ADVERT_NAME" ]; then
            log_error "ADVERT_NAME is required for repeater"
            missing=1
        fi
    fi
    
    if [ $missing -eq 1 ]; then
        log_error "Configuration incomplete. Edit config.env and try again."
        exit 1
    fi
    
    log_success "Configuration valid"
}

detect_upload_port() {
    # If UPLOAD_PORT is set and exists, use it
    if [ -n "$UPLOAD_PORT" ] && [ -e "$UPLOAD_PORT" ]; then
        echo "$UPLOAD_PORT"
        return
    fi

    # Try to auto-detect USB serial device (prefer usbmodem*, exclude debug-console)
    local port
    port=$(pio device list | grep -Eo '/dev/cu\.usbmodem[^ ]+' | head -n1)

    if [ -n "$port" ]; then
        echo "$port"
        return
    fi

    # Fallback: any cu device except debug-console
    port=$(pio device list | grep -Eo '/dev/cu\.[^ ]+' | grep -v debug-console | head -n1)

    if [ -n "$port" ]; then
        echo "$port"
        return
    fi

    # Last fallback: empty
    echo ""
}

print_header() {
    echo -e "${BLUE}"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Xiao S3 MeshCore Builder - Companion / Repeater"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

print_usage() {
        cat << 'EOF'
Usage:
    ./build.sh [ROLE] [ACTIONS] [OPTIONS]

ROLE (choose one):
    (default)      Companion firmware
    --repeater     Repeater firmware (sets PIO env: Xiao_S3_WIO_repeater)

ACTIONS:
    --build        Build firmware (clone/patch/configure/build unless skipped)
    --upload       Upload existing firmware artifact
    --monitor      Upload then open serial monitor (implies --upload)

BUILD FLOW OPTIONS:
    --clean        Remove WORK_DIR before running
    --no-clone     Skip clone/update step (use existing repo in WORK_DIR)
    --no-patch     Skip patch step
    --build-only   Build only (equivalent to: --build --no-clone --no-patch)
    --with-console-mirror
                  Enable optional repeater console mirror patches (TCP 5003)
    --help         Show this help

PORTS BY CONFIGURATION:
    Companion:
            TCP_PORT (default 5002)      Serial@TCP endpoint for integrations/clients
            CONSOLE_PORT (default 5001)  Companion console/control TCP endpoint

    Repeater:
            TCP_PORT (default 5002)      Serial@TCP endpoint (raw packet stream)
            CONSOLE_PORT (default 5001)  Repeater configuration/admin console
            Mirror 5003                  USB console mirror exposed via TCP (only with --with-console-mirror; useful for MQTT with https://analyzer.letsmesh.net/observer/onboard)

EXPOSURE DIFFERENCES (Companion vs Repeater):
        Companion:
            - 5002: serial@tcp (main endpoint for tools)
            - 5001: companion console/control
            - 5003: unused

        Repeater:
            - 5002: serial@tcp (raw packets)
            - 5001: repeater configuration/admin console
            - 5003: optional USB console mirror over TCP (legacy, only when patch is enabled; useful for MQTT with https://analyzer.letsmesh.net/observer/onboard)

CONFIG SOURCE:
    Values are read from config.env (WiFi, LoRa, ports, credentials, debug flags).

ESP32 BUILD OUTPUTS:
    firmware.bin         Application image only
    firmware-merged.bin  Full flash image for manual flashing at 0x0

EXAMPLES:
    ./build.sh --clean --build
    ./build.sh --build --upload
    ./build.sh --repeater --build --upload
    ./build.sh --repeater --build --with-console-mirror
    ./build.sh --upload
EOF
}

compose_platformio_build_flags() {
    local flags="${PLATFORMIO_BUILD_FLAGS:-}"

    flags="${flags} -D WIFI_SSID='\"${WIFI_SSID}\"'"
    flags="${flags} -D WIFI_PASSWORD='\"${WIFI_PASSWORD}\"'"
    flags="${flags} -D WIFI_PWD='\"${WIFI_PASSWORD}\"'"
    flags="${flags} -D TCP_PORT=${TCP_PORT}"
    flags="${flags} -D CONSOLE_PORT=${CONSOLE_PORT}"
    flags="${flags} -D WIFI_DEBUG_LOGGING=${WIFI_DEBUG_LOGGING}"

    flags="${flags} -D LORA_FREQ=${LORA_FREQ}"
    flags="${flags} -D LORA_BW=${LORA_BW}"
    flags="${flags} -D LORA_SF=${LORA_SF}"
    flags="${flags} -D LORA_CR=${LORA_CR}"
    flags="${flags} -D LORA_TX_POWER=${LORA_TX_POWER}"

    flags="${flags} -D MAX_CONTACTS=${MAX_CONTACTS}"
    flags="${flags} -D MAX_GROUP_CHANNELS=${MAX_GROUP_CHANNELS}"
    flags="${flags} -D OFFLINE_QUEUE_SIZE=${OFFLINE_QUEUE_SIZE}"
    flags="${flags} -D MAX_UNREAD_MSGS=${MAX_UNREAD_MSGS}"
    flags="${flags} -D MAX_BLOBRECS=${MAX_BLOBRECS}"
    flags="${flags} -D AUTO_OFF_MILLIS=${AUTO_OFF_MILLIS}"
    flags="${flags} -D UI_RECENT_LIST_SIZE=${UI_RECENT_LIST_SIZE}"

    flags="${flags} -D MESH_PACKET_LOGGING=${MESH_PACKET_LOGGING}"
    flags="${flags} -D MESH_DEBUG=${MESH_DEBUG}"
    flags="${flags} -D BRIDGE_DEBUG=${BRIDGE_DEBUG}"
    flags="${flags} -D BLE_DEBUG_LOGGING=${BLE_DEBUG_LOGGING}"

    flags="${flags} -D ADVERT_NAME='\"${ADVERT_NAME}\"'"
    flags="${flags} -D ADVERT_LAT=${ADVERT_LAT}"
    flags="${flags} -D ADVERT_LON=${ADVERT_LON}"
    flags="${flags} -D ADMIN_PASSWORD='\"${ADMIN_PASSWORD}\"'"
    flags="${flags} -D GUEST_PASSWORD='\"${GUEST_PASSWORD}\"'"

    if [ -n "${EXTRA_BUILD_FLAGS}" ]; then
        flags="${flags} ${EXTRA_BUILD_FLAGS}"
    fi

    echo "${flags}"
}

compose_firmware_metadata_flags() {
    local commit_hash
    local build_date
    local version_string

    commit_hash="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    build_date="$(date '+%d-%b-%Y')"
    version_string="${FIRMWARE_VERSION}-${commit_hash}"

    echo "-D FIRMWARE_BUILD_DATE='\"${build_date}\"' -D FIRMWARE_VERSION='\"${version_string}\"'"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

sync_firmware_metadata_headers() {
    local build_date
    local firmware_version
    local esc_build_date
    local esc_firmware_version
    local header
    local headers

    build_date="$(date '+%d %b %Y')"
    firmware_version="${FIRMWARE_VERSION}"
    esc_build_date="$(escape_sed_replacement "$build_date")"
    esc_firmware_version="$(escape_sed_replacement "$firmware_version")"

    headers=(
        "${REPO_DIR}/examples/simple_repeater/MyMesh.h"
        "${REPO_DIR}/examples/companion_radio/MyMesh.h"
        "${REPO_DIR}/examples/simple_room_server/MyMesh.h"
        "${REPO_DIR}/examples/simple_sensor/SensorMesh.h"
    )

    for header in "${headers[@]}"; do
        if [ ! -f "$header" ]; then
            continue
        fi

        sed -i.bak -E "s|^([[:space:]]*#define[[:space:]]+FIRMWARE_BUILD_DATE[[:space:]]+).*$|\\1\"${esc_build_date}\"|" "$header"
        sed -i.bak -E "s|^([[:space:]]*#define[[:space:]]+FIRMWARE_VERSION[[:space:]]+).*$|\\1\"${esc_firmware_version}\"|" "$header"
        rm -f "${header}.bak"
    done
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing=0
    
    if ! command -v git &> /dev/null; then
        log_error "git not found"
        missing=1
    fi
    
    if ! command -v pio &> /dev/null; then
        log_error "platformio not found - install: pip install platformio"
        missing=1
    fi
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi
    
    log_success "All dependencies found"
}

clone_repository() {
    log_info "Cloning meshcore-firmware repository..."
    
    if [ -d "$REPO_DIR" ]; then
        log_warn "Repository already exists at ${REPO_DIR}"
        read -p "Remove and re-clone? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$REPO_DIR"
        else
            log_info "Using existing repository"
            cd "$REPO_DIR"
            git pull origin "$REPO_BRANCH" || true
            return
        fi
    fi
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
    
    log_success "Repository cloned"
}

apply_patches() {
    log_info "Applying code patches..."
    
    cd "$REPO_DIR"
    
    # Apply each patch in non-interactive mode; skip already-applied/reversed patches.
    for patch_file in "$PATCHES_DIR"/*.patch; do
        if [ -f "$patch_file" ]; then
            local patch_name
            patch_name="$(basename "$patch_file")"

            # Legacy/overlapping patches on recent MeshCore.
            # 03 duplicates env:Xiao_S3_WIO_companion_radio_wifi in variants/xiao_s3_wio/platformio.ini.
            # 09/09b can duplicate repeater console declarations depending on upstream state.
            if [ "$patch_name" = "03-platformio-xiao-config.patch" ]; then
                log_info "Skipping ${patch_name} (legacy/optional patch for current upstream)"
                continue
            fi

            if [ "$patch_name" = "09-simple-repeater-tcp-console-header.patch" ] || \
               [ "$patch_name" = "09b-simple-repeater-tcp-console.patch" ]; then
                if [ "${ENABLE_CONSOLE_MIRROR_PATCH}" != "1" ]; then
                    log_info "Skipping ${patch_name} (console mirror patch disabled; set ENABLE_CONSOLE_MIRROR_PATCH=1 or pass --with-console-mirror)"
                    continue
                fi
            fi

            log_info "Applying ${patch_name}..."
            if patch -p1 --forward --batch < "$patch_file"; then
                :
            else
                log_warn "Patch ${patch_name} skipped (already applied or not applicable)"
            fi
        fi
    done
    
    log_success "Patches applied"
}

sanitize_variant_platformio_ini() {
    local config_file="${REPO_DIR}/variants/xiao_s3_wio/platformio.ini"

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    local tmp_file
    tmp_file="${config_file}.dedup"

    set +e
    awk '
        function hdr_name(line,  raw) {
            raw = line
            sub(/^\[/, "", raw)
            sub(/\]$/, "", raw)
            return raw
        }
        /^\[.*\]$/ {
            name = hdr_name($0)
            if (seen[name]++) {
                skip = 1
                changed = 1
                next
            }
            skip = 0
            print
            next
        }
        {
            if (!skip) print
        }
        END {
            if (changed) {
                exit 42
            }
        }
    ' "$config_file" > "$tmp_file"
    local awk_status=$?
    set -e

    if [ $awk_status -eq 42 ]; then
        mv "$tmp_file" "$config_file"
        log_warn "Removed duplicate [env:*] sections from variants/xiao_s3_wio/platformio.ini"
    elif [ $awk_status -eq 0 ]; then
        rm -f "$tmp_file"
    else
        rm -f "$tmp_file"
        log_error "Failed to sanitize variants/xiao_s3_wio/platformio.ini"
        exit 1
    fi
}

navigate_to_firmware_source() {
    log_info "Preparing firmware source for role: ${BUILD_ROLE}..."
    cd "$REPO_DIR"
    
    # Apply patches for both companion and repeater
    apply_patches
    sanitize_variant_platformio_ini
    
    if [ "$BUILD_ROLE" = "repeater" ]; then
        if [ ! -d "examples/simple_repeater" ]; then
            log_error "Repeater firmware not found at examples/simple_repeater"
            exit 1
        fi
        cd "examples/simple_repeater"
        log_success "Ready to build repeater from examples/simple_repeater"
    else
        log_success "Ready to build companion"
    fi
}

ensure_repeater_env_build_flags() {
    local config_file="$1"

    # Only relevant if the env exists
    if ! grep -q '^\[env:Xiao_S3_WIO_repeater\]$' "$config_file"; then
        return 0
    fi

    # If the repeater env already contains WiFi flags, do nothing
    if awk '
        BEGIN { in_env=0 }
        /^\[env:Xiao_S3_WIO_repeater\]$/ { in_env=1; next }
        in_env && /^\[/ { in_env=0 }
        in_env && /-D[[:space:]]+WIFI_SSID=/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$config_file"; then
        return 0
    fi

    log_info "Injecting missing repeater WiFi/LORA build_flags into variants/xiao_s3_wio/platformio.ini..."

    local tmp_file
    tmp_file="${config_file}.tmp"

    awk '
        BEGIN { in_env=0; inserted=0 }
        /^\[env:Xiao_S3_WIO_repeater\]$/ { in_env=1 }
        in_env && /^\[/ && $0 !~ /^\[env:Xiao_S3_WIO_repeater\]$/ { in_env=0 }
        { print }
        in_env && !inserted && $0 ~ /^[[:space:]]*\$\{Xiao_S3_WIO\.build_flags\}[[:space:]]*$/ {
            print "  -D WIFI_SSID=\x27\"YourNetwork\"\x27"
            print "  -D WIFI_PWD=\x27\"YourPassword\"\x27"
            print "  -D WIFI_PASSWORD=\x27\"YourPassword\"\x27"
            print "  -D TCP_PORT=5002"
            print "  -D WIFI_DEBUG_LOGGING=1"
            print "  -D GUEST_PASSWORD=\x27\"guest\"\x27"
            print "  -D LORA_FREQ=869.618"
            print "  -D LORA_BW=62.5"
            print "  -D LORA_SF=8"
            print "  -D LORA_CR=5"
            inserted=1
        }
    ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
}

configure_build_flags() {
    log_info "Configuring build flags (platformio.ini)..."

    local config_file="${REPO_DIR}/variants/xiao_s3_wio/platformio.ini"

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: ${config_file}"
        exit 1
    fi

    # Backup original once
    if [ ! -f "${config_file}.orig" ]; then
        cp "$config_file" "${config_file}.orig"
    fi

    # Ensure the repeater env contains the flags we later substitute via sed.
    ensure_repeater_env_build_flags "$config_file"
    sync_firmware_metadata_headers

    # WiFi
    sed -i.bak "s|-D WIFI_SSID='\"[^\"]*\"'|-D WIFI_SSID='\"${WIFI_SSID}\"'|" "$config_file"
    sed -i.bak "s|-D WIFI_PWD='\"[^\"]*\"'|-D WIFI_PWD='\"${WIFI_PASSWORD}\"'|" "$config_file"
    sed -i.bak "s|-D WIFI_PASSWORD='\"[^\"]*\"'|-D WIFI_PASSWORD='\"${WIFI_PASSWORD}\"'|" "$config_file"
    sed -i.bak "s|-D TCP_PORT=[^ ]*|-D TCP_PORT=${TCP_PORT}|" "$config_file"
    sed -i.bak "s|-D WIFI_DEBUG_LOGGING=[^ ]*|-D WIFI_DEBUG_LOGGING=${WIFI_DEBUG_LOGGING}|" "$config_file"

    # LoRa
    sed -i.bak "s|-D LORA_FREQ=[^ ]*|-D LORA_FREQ=${LORA_FREQ}|" "$config_file"
    sed -i.bak "s|-D LORA_BW=[^ ]*|-D LORA_BW=${LORA_BW}|" "$config_file"
    sed -i.bak "s|-D LORA_SF=[^ ]*|-D LORA_SF=${LORA_SF}|" "$config_file"
    sed -i.bak "s|-D LORA_CR=[^ ]*|-D LORA_CR=${LORA_CR}|" "$config_file"
    sed -i.bak "s|-D LORA_TX_POWER=[^ ]*|-D LORA_TX_POWER=${LORA_TX_POWER}|" "$config_file"

    # Memory / queues / contacts
    sed -i.bak "s|-D MAX_CONTACTS=[^ ]*|-D MAX_CONTACTS=${MAX_CONTACTS}|" "$config_file"
    sed -i.bak "s|-D MAX_GROUP_CHANNELS=[^ ]*|-D MAX_GROUP_CHANNELS=${MAX_GROUP_CHANNELS}|" "$config_file"
    sed -i.bak "s|-D OFFLINE_QUEUE_SIZE=[^ ]*|-D OFFLINE_QUEUE_SIZE=${OFFLINE_QUEUE_SIZE}|" "$config_file"
    sed -i.bak "s|-D MAX_UNREAD_MSGS=[^ ]*|-D MAX_UNREAD_MSGS=${MAX_UNREAD_MSGS}|" "$config_file"
    sed -i.bak "s|-D MAX_BLOBRECS=[^ ]*|-D MAX_BLOBRECS=${MAX_BLOBRECS}|" "$config_file"

    # Display
    sed -i.bak "s|-D DISPLAY_CLASS=[^ ]*|-D DISPLAY_CLASS=${DISPLAY_CLASS}|" "$config_file"
    sed -i.bak "s|-D AUTO_OFF_MILLIS=[^ ]*|-D AUTO_OFF_MILLIS=${AUTO_OFF_MILLIS}|" "$config_file"
    sed -i.bak "s|-D UI_RECENT_LIST_SIZE=[^ ]*|-D UI_RECENT_LIST_SIZE=${UI_RECENT_LIST_SIZE}|" "$config_file"

    # Debug
    sed -i.bak "s|-D MESH_PACKET_LOGGING=[^ ]*|-D MESH_PACKET_LOGGING=${MESH_PACKET_LOGGING}|" "$config_file"
    sed -i.bak "s|-D MESH_DEBUG=[^ ]*|-D MESH_DEBUG=${MESH_DEBUG}|" "$config_file"
    sed -i.bak "s|-D BRIDGE_DEBUG=[^ ]*|-D BRIDGE_DEBUG=${BRIDGE_DEBUG}|" "$config_file"
    sed -i.bak "s|-D BLE_DEBUG_LOGGING=[^ ]*|-D BLE_DEBUG_LOGGING=${BLE_DEBUG_LOGGING}|" "$config_file"

    # Identity
    sed -i.bak "s|-D ADVERT_NAME='\"[^\"]*\"'|-D ADVERT_NAME='\"${ADVERT_NAME}\"'|" "$config_file"
    sed -i.bak "s|-D ADVERT_LAT=[^ ]*|-D ADVERT_LAT=${ADVERT_LAT}|" "$config_file"
    sed -i.bak "s|-D ADVERT_LON=[^ ]*|-D ADVERT_LON=${ADVERT_LON}|" "$config_file"
    sed -i.bak "s|-D ADMIN_PASSWORD='\"[^\"]*\"'|-D ADMIN_PASSWORD='\"${ADMIN_PASSWORD}\"'|" "$config_file"

    # Remove temp backup
    rm -f "${config_file}.bak"

    log_success "Build flags configured"
    log_info "  WiFi SSID: ${WIFI_SSID}"
    log_info "  TCP Port:  ${TCP_PORT}"
    log_info "  LoRa:      ${LORA_FREQ} MHz BW ${LORA_BW} SF${LORA_SF} CR${LORA_CR} TX ${LORA_TX_POWER} dBm"
}
configure_repeater_build_flags() {
    log_info "Configuring build flags for repeater (platformio.ini)..."
    local config_file="${REPO_DIR}/examples/simple_repeater/platformio.ini"
    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: ${config_file}"
        exit 1
    fi
    if [ ! -f "${config_file}.orig" ]; then
        cp "$config_file" "${config_file}.orig"
    fi
    sed -i.bak "s|-D WIFI_SSID=\"[^\"]*\"|-D WIFI_SSID=\"${WIFI_SSID}\"|" "$config_file"
    sed -i.bak "s|-D WIFI_PWD=\"[^\"]*\"|-D WIFI_PWD=\"${WIFI_PASSWORD}\"|" "$config_file"
    sed -i.bak "s|-D TCP_PORT=[^ ]*|-D TCP_PORT=${TCP_PORT}|" "$config_file"
    sed -i.bak "s|-D ADMIN_PASSWORD=\"[^\"]*\"|-D ADMIN_PASSWORD=\"${ADMIN_PASSWORD}\"|" "$config_file"
    sed -i.bak "s|-D GUEST_PASSWORD=\"[^\"]*\"|-D GUEST_PASSWORD=\"${GUEST_PASSWORD}\"|" "$config_file"
    sed -i.bak "s|-D ADVERT_NAME=\"[^\"]*\"|-D ADVERT_NAME=\"${ADVERT_NAME}\"|" "$config_file"
    sed -i.bak "s|-D ADVERT_LAT=[^ ]*|-D ADVERT_LAT=${ADVERT_LAT}|" "$config_file"
    sed -i.bak "s|-D ADVERT_LON=[^ ]*|-D ADVERT_LON=${ADVERT_LON}|" "$config_file"
    sed -i.bak "s|-D LORA_FREQ=[^ ]*|-D LORA_FREQ=${LORA_FREQ}|" "$config_file"
    sed -i.bak "s|-D LORA_BW=[^ ]*|-D LORA_BW=${LORA_BW}|" "$config_file"
    sed -i.bak "s|-D LORA_SF=[^ ]*|-D LORA_SF=${LORA_SF}|" "$config_file"
    sed -i.bak "s|-D LORA_CR=[^ ]*|-D LORA_CR=${LORA_CR}|" "$config_file"
    sed -i.bak "s|-D LORA_TX_POWER=[^ ]*|-D LORA_TX_POWER=${LORA_TX_POWER}|" "$config_file"
    rm -f "${config_file}.bak"
    log_success "Build flags configured for repeater"
    log_info "  WiFi SSID: ${WIFI_SSID}"
    log_info "  Admin Password: ***"
    log_info "  Node Name: ${ADVERT_NAME}"
    log_info "  LoRa: ${LORA_FREQ} MHz BW ${LORA_BW} SF${LORA_SF} CR${LORA_CR} TX ${LORA_TX_POWER} dBm"
}

build_firmware() {
    log_info "Building firmware for ${PIO_ENV}..."
    
    cd "$REPO_DIR"

    if [[ "$PIO_ENV" == *repeater* ]]; then
        pio pkg install -e "$PIO_ENV" --library "densaugeo/base64 @ ~1.4.0" >/dev/null 2>&1 || true
    fi

    local effective_platformio_build_flags
    local metadata_build_flags
    local final_platformio_build_flags
    effective_platformio_build_flags="$(compose_platformio_build_flags)"
    metadata_build_flags="$(compose_firmware_metadata_flags)"
    final_platformio_build_flags="${effective_platformio_build_flags} ${metadata_build_flags}"

    log_info "PLATFORMIO_BUILD_FLAGS include WiFi/LoRa/Debug/Identity overrides from config.env"

    if [ "${USE_UPSTREAM_BUILD}" = "1" ]; then
        if [ ! -x "${REPO_DIR}/build.sh" ]; then
            log_error "Upstream build script not found/executable: ${REPO_DIR}/build.sh"
            exit 1
        fi

        log_info "Delegating firmware build to upstream MeshCore build.sh"
        FIRMWARE_VERSION="${FIRMWARE_VERSION}" \
        PLATFORMIO_BUILD_FLAGS="${final_platformio_build_flags}" \
            bash "${REPO_DIR}/build.sh" build-firmware "${PIO_ENV}"

        local firmware_path
        firmware_path="${REPO_DIR}/.pio/build/${PIO_ENV}/firmware.bin"
        if [ ! -f "$firmware_path" ]; then
            log_error "Upstream build finished without firmware artifact: ${firmware_path}"
            exit 1
        fi

        generate_merged_firmware

        log_success "Firmware built successfully (upstream build.sh)"
        return
    fi
    
    # Clean previous build
    PLATFORMIO_BUILD_FLAGS="${final_platformio_build_flags}" pio run -e "$PIO_ENV" --target clean
    
    # Build
    PLATFORMIO_BUILD_FLAGS="${final_platformio_build_flags}" pio run -e "$PIO_ENV"

    generate_merged_firmware
    
    log_success "Firmware built successfully"
}

generate_merged_firmware() {
    local build_dir
    local firmware_path
    local merged_path

    build_dir="${REPO_DIR}/.pio/build/${PIO_ENV}"
    firmware_path="${build_dir}/firmware.bin"
    merged_path="${build_dir}/firmware-merged.bin"

    if [ ! -f "$firmware_path" ]; then
        log_warn "Skipping merged image generation because firmware.bin is missing"
        return
    fi

    log_info "Generating merged flash image for ${PIO_ENV}..."
    cd "$REPO_DIR"

    if ! pio run -e "$PIO_ENV" -t mergebin >/dev/null; then
        log_warn "Merged image target failed; use bootloader.bin + partitions.bin + firmware.bin for manual flashing"
        return
    fi

    if [ -f "$merged_path" ]; then
        log_success "Merged flash image ready: ${merged_path}"
    else
        log_warn "Merged image target completed but ${merged_path} was not created"
    fi
}

upload_firmware() {
    local port
    local build_dir
    local firmware_path
    local merged_path
    port=$(detect_upload_port)

    if [ -z "$port" ]; then
        log_error "No upload port found. Connect the device or set UPLOAD_PORT in config.env"
        exit 1
    fi

    log_info "Uploading firmware to ${port}..."

    build_dir="${REPO_DIR}/.pio/build/${PIO_ENV}"
    firmware_path="${build_dir}/firmware.bin"
    merged_path="${build_dir}/firmware-merged.bin"

    if [ ! -f "$firmware_path" ]; then
        log_error "Firmware artifact missing: ${firmware_path}. Run with --build first."
        exit 1
    fi

    if [ ! -f "$merged_path" ]; then
        log_warn "Merged image missing, generating it now..."
        generate_merged_firmware
    fi

    if [ ! -f "$merged_path" ]; then
        log_error "Merged image is still missing: ${merged_path}"
        exit 1
    fi

    if command -v esptool.py >/dev/null 2>&1; then
        log_info "Flashing merged image with esptool (no rebuild)..."
        esptool.py --chip esp32s3 --port "$port" --baud 460800 write_flash -z 0x0 "$merged_path"
    else
        log_warn "esptool.py not found; falling back to PlatformIO upload (may rebuild)"
        cd "$REPO_DIR"
        pio run -e "$PIO_ENV" -t upload --upload-port "$port"
    fi
    
    log_success "Firmware uploaded successfully"
}

monitor_serial() {
    local port
    port=$(detect_upload_port)

    if [ -z "$port" ]; then
        log_error "No serial port found. Connect the device or set UPLOAD_PORT in config.env"
        exit 1
    fi

    log_info "Starting serial monitor on ${port}..."
    log_warn "Press Ctrl+C to exit monitor"
    sleep 1
    
    cd "$REPO_DIR"
    pio device monitor -p "$port" -b 115200
}

clean_workspace() {
    log_info "Cleaning workspace: ${WORK_DIR}"

    if [ -z "$WORK_DIR" ] || [ "$WORK_DIR" = "/" ]; then
        log_error "Refusing to clean unsafe WORK_DIR value: '${WORK_DIR}'"
        exit 1
    fi

    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        log_success "Workspace cleaned"
    else
        log_info "Workspace directory does not exist, nothing to clean"
    fi
}

show_summary() {
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  Operation Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "Configuration:"
    echo -e "  Role:         ${BUILD_ROLE}"
    echo -e "  WiFi SSID:    ${WIFI_SSID}"
    echo -e "  IP Address:   DHCP (check serial log for assigned IP)"
    if [ "${BUILD_ROLE}" = "repeater" ]; then
        echo -e "  TCP Port:     ${TCP_PORT} (serial@tcp / raw packet stream)"
        echo -e "  Console Port: ${CONSOLE_PORT} (repeater configuration/admin console)"
        echo -e "  Mirror 5003:  $([ "${ENABLE_CONSOLE_MIRROR_PATCH}" = "1" ] && echo enabled || echo disabled) (USB console mirror over TCP, useful for MQTT with https://analyzer.letsmesh.net/observer/onboard)"
    else
        echo -e "  TCP Port:     ${TCP_PORT} (serial@tcp endpoint)"
        echo -e "  Console Port: ${CONSOLE_PORT} (companion console/control)"
        echo -e "  Mirror 5003:  disabled (not used in companion)"
    fi
    echo -e "  Build mode:   $([ "${USE_UPSTREAM_BUILD}" = "1" ] && echo upstream || echo direct pio)"
    echo -e "  PIO flags:    WiFi/LoRa/Debug/Identity from config.env ${EXTRA_BUILD_FLAGS}"
    echo
    echo -e "Testing:"
    echo -e "  1. Monitor: ${BLUE}pio device monitor -p ${UPLOAD_PORT:-<auto-detect>} -b 115200${NC}"
    echo -e "  2. Connect: ${BLUE}nc <device-ip> ${TCP_PORT}${NC}"
    echo -e "  3. Send:    ${BLUE}python3 send_to_channel.py \"message\" \"sender\" <device-ip>${NC}"
    echo
    echo -e "Firmware location:"
    echo -e "  ${REPO_DIR}/.pio/build/${PIO_ENV}/firmware.bin"
    if [ -f "${REPO_DIR}/.pio/build/${PIO_ENV}/firmware-merged.bin" ]; then
        echo -e "  ${REPO_DIR}/.pio/build/${PIO_ENV}/firmware-merged.bin (flash at 0x0)"
    fi
    if [ $DO_BUILD -eq 1 ] && [ $DO_UPLOAD -eq 0 ] && [ -f "${REPO_DIR}/.pio/build/${PIO_ENV}/firmware-merged.bin" ]; then
        echo
        echo -e "Manual flashing:"
        echo -e "  Built without --upload. For manual ESP32 flashing, prefer ${BLUE}${REPO_DIR}/.pio/build/${PIO_ENV}/firmware-merged.bin${NC} at ${BLUE}0x0${NC}."
    fi
    echo
}

# Main script
main() {
    print_header
    
    # Parse arguments
    DO_CLONE=-1
    DO_PATCH=-1
    DO_CONFIGURE=-1
    DO_CLEAN=0
    DO_BUILD=0
    DO_UPLOAD=0
    DO_MONITOR=0
    
    if [[ $# -eq 0 ]]; then
        print_usage
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repeater)
                BUILD_ROLE="repeater"
                PIO_ENV="Xiao_S3_WIO_repeater"
                shift
                ;;
            --build)
                DO_BUILD=1
                shift
                ;;
            --clean)
                DO_CLEAN=1
                shift
                ;;
            --no-clone)
                DO_CLONE=0
                shift
                ;;
            --no-patch)
                DO_PATCH=0
                shift
                ;;
            --with-console-mirror)
                ENABLE_CONSOLE_MIRROR_PATCH=1
                shift
                ;;
            --upload)
                DO_UPLOAD=1
                shift
                ;;
            --monitor)
                DO_MONITOR=1
                DO_UPLOAD=1
                shift
                ;;
            --build-only)
                DO_BUILD=1
                DO_CLONE=0
                DO_PATCH=0
                DO_CONFIGURE=0
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    enforce_repeater_profile
    
    if [ $DO_BUILD -eq 1 ]; then
        [ $DO_CLONE -eq -1 ] && DO_CLONE=1
        [ $DO_PATCH -eq -1 ] && DO_PATCH=1
        [ $DO_CONFIGURE -eq -1 ] && DO_CONFIGURE=1
    else
        [ $DO_CLONE -eq -1 ] && DO_CLONE=0
        [ $DO_PATCH -eq -1 ] && DO_PATCH=0
        [ $DO_CONFIGURE -eq -1 ] && DO_CONFIGURE=0
    fi

    if [ $DO_UPLOAD -eq 1 ] && [ $DO_BUILD -eq 0 ]; then
        local firmware_path="${REPO_DIR}/.pio/build/${PIO_ENV}/firmware.bin"
        if [ -f "$firmware_path" ]; then
            log_info "Upload requested and firmware exists -> skip clone/patch/build"
            DO_CLONE=0
            DO_PATCH=0
            DO_CONFIGURE=0
            DO_BUILD=0
        else
            log_error "Upload requested but firmware is missing. Run with --build first or combine --build --upload."
            exit 1
        fi
    fi

    if [ $DO_CLEAN -eq 1 ] && [ $DO_UPLOAD -eq 1 ] && [ $DO_BUILD -eq 0 ]; then
        log_error "Cannot use --clean with --upload unless --build is also set"
        exit 1
    fi

    check_dependencies
    
    # Only validate config if doing something
    if [ $DO_CLONE -eq 1 ] || [ $DO_PATCH -eq 1 ] || [ $DO_BUILD -eq 1 ]; then
        validate_config
    fi

    [ $DO_CLEAN -eq 1 ] && clean_workspace
    
    [ $DO_CLONE -eq 1 ] && clone_repository
    [ $DO_PATCH -eq 1 ] && navigate_to_firmware_source
    if [ $DO_CONFIGURE -eq 1 ]; then
        configure_build_flags
    fi
    [ $DO_BUILD -eq 1 ] && build_firmware
    [ $DO_UPLOAD -eq 1 ] && upload_firmware
    
    show_summary
    
    if [ $DO_MONITOR -eq 1 ]; then
        monitor_serial
    fi
}

# Run
main "$@"
