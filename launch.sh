#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# VideoCar workshop launcher -- check/install PlatformIO, then build, flash,
# and monitor any of the four keyestudio ESP32-CAM sketches under firmware/.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_ROOT="$SCRIPT_DIR/firmware"

# --- colors -----------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_DIM='\033[2m'
  C_CYAN='\033[36m'; C_AMBER='\033[33m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_BOLD='\033[1m'
else
  C_RESET=''; C_DIM=''; C_CYAN=''; C_AMBER=''; C_RED=''; C_GREEN=''; C_BOLD=''
fi

ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
warn()  { echo -e "${C_AMBER}[!!]${C_RESET} $1"; }
err()   { echo -e "${C_RED}[XX]${C_RESET} $1"; }
info()  { echo -e "${C_CYAN}[--]${C_RESET} $1"; }

banner() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "  ┌──────────────────────────────────────────────┐"
  echo "  │   🚗  VIDEOCAR WORKSHOP -- PLATFORMIO LAUNCH   │"
  echo "  └──────────────────────────────────────────────┘"
  echo -e "${C_RESET}"
}

pause() { read -rp "$(echo -e "${C_DIM}Press Enter to continue...${C_RESET}")" _; }

# --- app discovery ------------------------------------------------------------
# Any firmware/<name>/platformio.ini is a selectable app. Sorted so the
# numeric prefixes (1_blink, 2_breathing_light, ...) come out in order.
APP_NAMES=()
APP_DIRS=()

discover_apps() {
  APP_NAMES=(); APP_DIRS=()
  while IFS= read -r ini; do
    local dir; dir="$(dirname "$ini")"
    APP_DIRS+=("$dir")
    APP_NAMES+=("$(basename "$dir")")
  done < <(find "$FIRMWARE_ROOT" -mindepth 2 -maxdepth 2 -name platformio.ini | sort)
}

APP_DIR=""
APP_NAME=""

select_app() {
  discover_apps
  if [ ${#APP_NAMES[@]} -eq 0 ]; then
    err "No PlatformIO projects found under $FIRMWARE_ROOT"
    APP_DIR=""; APP_NAME=""
    return 1
  fi
  echo
  info "Available apps:"
  local i
  for i in "${!APP_NAMES[@]}"; do
    echo "  $((i+1))) ${APP_NAMES[$i]}"
  done
  echo
  read -rp "Choose an app [1-${#APP_NAMES[@]}]: " sel || { echo; info "Bye."; exit 0; }
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#APP_NAMES[@]} ]; then
    APP_DIR="${APP_DIRS[$((sel-1))]}"
    APP_NAME="${APP_NAMES[$((sel-1))]}"
    ok "Selected: $APP_NAME"
  else
    warn "Unrecognized choice, keeping current selection ($APP_NAME)."
  fi
  pause
}

require_app() {
  if [ -z "$APP_DIR" ]; then
    warn "No app selected yet -- pick one first."
    select_app
  fi
  [ -n "$APP_DIR" ]
}

# --- pio discovery -----------------------------------------------------------
PIO_BIN=""

find_pio() {
  if command -v pio >/dev/null 2>&1; then
    PIO_BIN="$(command -v pio)"
    return 0
  fi
  if [ -x "$HOME/.platformio/penv/bin/pio" ]; then
    PIO_BIN="$HOME/.platformio/penv/bin/pio"
    return 0
  fi
  PIO_BIN=""
  return 1
}

pio_run() {
  if ! find_pio; then
    err "PlatformIO not found. Use option 2 (Install PlatformIO) first."
    return 1
  fi
  "$PIO_BIN" "$@"
}

# --- menu actions -------------------------------------------------------------

check_install() {
  echo
  info "Checking for prerequisites..."

  if command -v python3 >/dev/null 2>&1; then
    ok "python3 found: $(python3 --version 2>&1)"
  else
    err "python3 not found -- required to install/run PlatformIO."
  fi

  if command -v pip3 >/dev/null 2>&1; then
    ok "pip3 found"
  else
    warn "pip3 not found (only needed for the pip install method)."
  fi

  if find_pio; then
    ok "PlatformIO found at: $PIO_BIN"
    "$PIO_BIN" --version
  else
    warn "PlatformIO not found. Use option 2 to install it."
  fi

  echo
  discover_apps
  if [ ${#APP_NAMES[@]} -gt 0 ]; then
    ok "Found ${#APP_NAMES[@]} firmware project(s) under $FIRMWARE_ROOT:"
    local n; for n in "${APP_NAMES[@]}"; do echo "     - $n"; done
  else
    err "No PlatformIO projects found under $FIRMWARE_ROOT"
  fi
  pause
}

install_pio() {
  echo
  info "Installing PlatformIO Core..."
  echo "  1) pip install (fast, needs python3 + pip3)"
  echo "  2) official installer script (self-contained virtualenv)"
  echo "  b) back"
  read -rp "Choose an option: " choice
  case "$choice" in
    1)
      if ! command -v pip3 >/dev/null 2>&1; then
        err "pip3 not found. Install Python 3 + pip first, or use option 2."
      else
        pip3 install -U platformio && ok "Installed. You may need to restart your shell or add pip's bin dir to PATH."
      fi
      ;;
    2)
      if ! command -v python3 >/dev/null 2>&1; then
        err "python3 not found. Install Python 3 first."
      else
        curl -fsSL -o /tmp/get-platformio.py \
          https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py \
          && python3 /tmp/get-platformio.py \
          && ok "Installed to ~/.platformio. Add ~/.platformio/penv/bin to your PATH."
      fi
      ;;
    b|B) return ;;
    *) warn "Unrecognized option." ;;
  esac
  pause
}

build_firmware() {
  require_app || return
  echo
  info "Building $APP_NAME (pio run)..."
  pio_run run -d "$APP_DIR" && ok "Build succeeded." || err "Build failed -- see output above."
  pause
}

clean_firmware() {
  require_app || return
  echo
  info "Cleaning build artifacts for $APP_NAME..."
  pio_run run -t clean -d "$APP_DIR" && ok "Cleaned."
  pause
}

list_ports() {
  echo
  info "Detected serial devices:"
  pio_run device list
  pause
}

pick_port() {
  # Prints nothing on failure/no-selection; sets $SELECTED_PORT
  SELECTED_PORT=""
  echo
  info "Available serial ports:"
  pio_run device list
  echo
  read -rp "Enter the port to use (e.g. /dev/ttyUSB0 or COM5), or leave blank for auto-detect: " SELECTED_PORT
}

flash_firmware() {
  require_app || return
  echo
  warn "ESP32-CAM (AI-Thinker) boards flashed via a plain FTDI adapter usually"
  warn "have no auto-reset circuit. If the upload hangs at 'Connecting....':"
  warn "  1) Hold the IO0/BOOT button"
  warn "  2) Tap RESET"
  warn "  3) Release IO0 once you see 'Connecting....' actively retrying"
  if [ "$APP_NAME" = "3_motor" ]; then
    warn "3_motor drives forward/back/left/right immediately on boot/reset --"
    warn "make sure the car has room to move before flashing or resetting it."
  fi
  echo
  pick_port
  echo
  info "Flashing $APP_NAME..."
  if [ -n "$SELECTED_PORT" ]; then
    pio_run run -t upload --upload-port "$SELECTED_PORT" -d "$APP_DIR" && ok "Flash succeeded." || err "Flash failed -- see output above."
  else
    pio_run run -t upload -d "$APP_DIR" && ok "Flash succeeded." || err "Flash failed -- see output above."
  fi
  pause
}

monitor_serial() {
  echo
  pick_port
  echo
  info "Opening serial monitor at 115200 baud. Press Ctrl+C to exit."
  if [ -n "$SELECTED_PORT" ]; then
    pio_run device monitor -b 115200 -p "$SELECTED_PORT"
  else
    pio_run device monitor -b 115200
  fi
}

build_flash_monitor() {
  require_app || return
  build_firmware
  flash_firmware
  read -rp "Open serial monitor now? [y/N] " yn
  case "$yn" in
    y|Y) monitor_serial ;;
    *) ;;
  esac
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    if [ -n "$APP_NAME" ]; then
      echo -e "  App: ${C_AMBER}$APP_NAME${C_RESET}  ($APP_DIR)"
    else
      echo -e "  App: ${C_RED}none selected${C_RESET}"
    fi
    if find_pio; then
      echo -e "  PlatformIO: ${C_GREEN}found${C_RESET} ($PIO_BIN)"
    else
      echo -e "  PlatformIO: ${C_RED}not found${C_RESET}"
    fi
    echo
    echo "  0) Select app"
    echo "  1) Check installation"
    echo "  2) Install PlatformIO"
    echo "  3) Build firmware"
    echo "  4) Flash firmware"
    echo "  5) Build + Flash + Monitor"
    echo "  6) Serial monitor"
    echo "  7) List serial ports"
    echo "  8) Clean build"
    echo "  q) Quit"
    echo
    read -rp "Choose an option: " opt || { echo; info "Bye."; exit 0; }
    case "$opt" in
      0) select_app ;;
      1) check_install ;;
      2) install_pio ;;
      3) build_firmware ;;
      4) flash_firmware ;;
      5) build_flash_monitor ;;
      6) monitor_serial ;;
      7) list_ports ;;
      8) clean_firmware ;;
      q|Q) echo; info "Bye."; exit 0 ;;
      *) warn "Unrecognized option." ; sleep 1 ;;
    esac
  done
}

# Prompt for an app up front so options 3-8 have something to act on immediately.
select_app
main_menu
