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

# Identity / advertising
ADVERT_NAME="XiaoS3 WiFi"
ADVERT_LAT=0.0
ADVERT_LON=0.0
ADMIN_PASSWORD="password"

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
    echo "  Xiao S3 Companion Radio Builder - WiFi + TCP Serial"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"
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
    
    # Apply each patch, but don't bail if already applied
    for patch_file in "$PATCHES_DIR"/*.patch; do
        if [ -f "$patch_file" ]; then
            log_info "Applying $(basename "$patch_file")..."
            if ! patch -p1 < "$patch_file"; then
                log_warn "Patch $(basename "$patch_file") failed (already applied?) - continuing"
            fi
        fi
    done
    
    log_success "Patches applied"
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

    # WiFi
    sed -i.bak "s|-D WIFI_SSID='\"[^\"]*\"'|-D WIFI_SSID='\"${WIFI_SSID}\"'|" "$config_file"
    sed -i.bak "s|-D WIFI_PWD='\"[^\"]*\"'|-D WIFI_PWD='\"${WIFI_PASSWORD}\"'|" "$config_file"
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

build_firmware() {
    log_info "Building firmware for ${PIO_ENV}..."
    
    cd "$REPO_DIR"
    
    # Clean previous build
    pio run -e "$PIO_ENV" --target clean
    
    # Build
    pio run -e "$PIO_ENV"
    
    log_success "Firmware built successfully"
}

upload_firmware() {
    local port
    port=$(detect_upload_port)

    if [ -z "$port" ]; then
        log_error "No upload port found. Connect the device or set UPLOAD_PORT in config.env"
        exit 1
    fi

    log_info "Uploading firmware to ${port}..."
    
    cd "$REPO_DIR"
    pio run -e "$PIO_ENV" --target upload --upload-port "$port"
    
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

show_summary() {
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    Build Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "Configuration:"
    echo -e "  WiFi SSID:    ${WIFI_SSID}"
    echo -e "  IP Address:   DHCP (check serial log for assigned IP)"
    echo -e "  TCP Port:     ${TCP_PORT}"
    echo
    echo -e "Testing:"
    echo -e "  1. Monitor: ${BLUE}pio device monitor -p ${UPLOAD_PORT:-<auto-detect>} -b 115200${NC}"
    echo -e "  2. Connect: ${BLUE}nc <device-ip> ${TCP_PORT}${NC}"
    echo -e "  3. Send:    ${BLUE}python3 send_to_channel.py \"message\" \"sender\" <device-ip>${NC}"
    echo
    echo -e "Firmware location:"
    echo -e "  ${REPO_DIR}/.pio/build/${PIO_ENV}/firmware.bin"
    echo
}

# Main script
main() {
    print_header
    
    # Parse arguments
    DO_CLONE=1
    DO_PATCH=1
    DO_CONFIGURE=1
    DO_BUILD=1
    DO_UPLOAD=0
    DO_MONITOR=0
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-clone)
                DO_CLONE=0
                shift
                ;;
            --no-patch)
                DO_PATCH=0
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
                DO_CLONE=0
                DO_PATCH=0
                DO_CONFIGURE=0
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  --no-clone     Skip repository cloning"
                echo "  --no-patch     Skip applying patches"
                echo "  --upload       Upload firmware after build"
                echo "  --monitor      Upload and start serial monitor"
                echo "  --build-only   Only build (skip clone/patch/config)"
                echo "  --help         Show this help"
                echo
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    check_dependencies
    
    [ $DO_CLONE -eq 1 ] && clone_repository
    [ $DO_PATCH -eq 1 ] && apply_patches
    [ $DO_CONFIGURE -eq 1 ] && configure_build_flags
    [ $DO_BUILD -eq 1 ] && build_firmware
    [ $DO_UPLOAD -eq 1 ] && upload_firmware
    
    show_summary
    
    [ $DO_MONITOR -eq 1 ] && monitor_serial
}

# Run
main "$@"
