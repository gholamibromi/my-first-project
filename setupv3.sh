#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  VPN Multi-Protocol Installer
#  Author: CR-VPN
#  Protocols: VLESS-WS · VLESS-XHTTP · VLESS-Reality · Hysteria2
#  Features:  Fragment · Mux · WARP · Sniffing · Subscription
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors & UI ──────────────────────────────────────────────────
C0=$'\033[0m'        # reset
C1=$'\033[38;5;39m'  # light blue
C2=$'\033[38;5;220m' # yellow
C3=$'\033[38;5;245m' # gray
CG=$'\033[38;5;82m'  # green
CR=$'\033[38;5;196m' # red
CW=$'\033[38;5;208m' # orange
CC=$'\033[38;5;51m'  # cyan
CB=$'\033[1m'        # bold
TTY=/dev/tty

# ── Globals ──────────────────────────────────────────────────────
MAX_TRIES=3
CF_PORTS=(443 2053 2083 2087 2096 8443)
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"
WARP_PORT=40000
STATE_FILE="/etc/vpn-installer/state.env"

RE_DOMAIN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
RE_EMAIL='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
RE_EXT='^PORT_IPS\\\[([0-9]+)\\\]="?([0-9A-Za-z.,:_-]+)"?$'
RE_SUBPATH='^[A-Za-z0-9._-]+$'

# ── State Variables ──────────────────────────────────────────────
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
WANT_WARP=false; WANT_FRAGMENT=false; WANT_MUX=false
USE_DOMAIN=false
NGINX_PORTS=()
declare -A PORT_IPS
EXT_COUNT=0
SUB_TOKEN=""
LINKS=()
HY2_CERT="self"
DOMAIN=""
REALITY_PORT="8443"
SNI="www.cloudflare.com"
HY2_PORT="36712"
HY2_DOMAIN=""
LE_EMAIL=""
CONFIG_NAME="MyVPN"
SUB_PATH_IN="sub"
FP="chrome"
SERVER_IP=""

# Secrets
UUID=""; WS_PATH=""; XHTTP_PATH=""; HY2_PASS=""
REALITY_PRIV=""; REALITY_PUB=""; REALITY_SID=""

# Check root
[ "$(id -u)" = 0 ] || { echo "Please run as root."; exit 1; }

PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
elif command -v yum >/dev/null 2>&1; then PKG=yum
fi

# ── UI Functions ─────────────────────────────────────────────────
clear_screen() { printf "\033c" >"$TTY"; }

ok()    { printf "${CG}  ✔  ${C0}%s\n" "$*" >"$TTY"; }
warn()  { printf "${CW}  ⚠  ${C0}%s\n" "$*" >"$TTY"; }
die()   { printf "${CR}  ✖  ${C0}%s\n" "$*" >"$TTY"; exit 1; }
info()  { printf "${C3}  ·  ${C0}%s\n" "$*" >"$TTY"; }
step()  { printf "\n${CB}${C2}  ▶  %s${C0}\n" "$*" >"$TTY"; }
banner(){ printf "${C2}%s${C0}\n" "$*" >"$TTY"; }

press_enter() {
  printf "\n${C3}Press Enter to continue...${C0}" >"$TTY"
  read -r <"$TTY" || true
}

welcome_screen() {
  clear_screen
  printf "\n" >"$TTY"
  printf "${CC}  ██╗   ██╗██████╗ ███╗   ██╗    ██╗███╗   ██╗███████╗████████╗███████╗██╗     ██╗     ${C0}\n" >"$TTY"
  printf "${CC}  ██║   ██║██╔══██╗████╗  ██║    ██║████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║     ██║     ${C0}\n" >"$TTY"
  printf "${CC}  ██║   ██║██████╔╝██╔██╗ ██║    ██║██╔██╗ ██║███████╗   ██║   █████╗  ██║     ██║     ${C0}\n" >"$TTY"
  printf "${CC}  ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║    ██║██║╚██╗██║╚════██║   ██║   ██╔══╝  ██║     ██║     ${C0}\n" >"$TTY"
  printf "${CC}   ╚████╔╝ ██║     ██║ ╚████║    ██║██║ ╚████║███████║   ██║   ███████╗███████╗███████╗${C0}\n" >"$TTY"
  printf "${CC}    ╚═══╝  ╚═╝     ╚═╝  ╚═══╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚══════╝╚══════╝╚══════╝${C0}\n" >"$TTY"
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════════════════════════════════════════╗"
  banner "  ║                        VPN Multi-Protocol Installer                          ║"
  banner "  ║                              Author: CR-VPN                                  ║"
  banner "  ║                  Supported: VLESS, Hysteria2, WARP, Nginx                    ║"
  banner "  ╚══════════════════════════════════════════════════════════════════════════════╝"
  printf "\n" >"$TTY"
}

# ── State Management ─────────────────────────────────────────────
save_state() {
  mkdir -p /etc/vpn-installer
  cat > "$STATE_FILE" <<EOF
WANT_WS=$WANT_WS
WANT_XHTTP=$WANT_XHTTP
WANT_REALITY=$WANT_REALITY
WANT_HY2=$WANT_HY2
WANT_WARP=$WANT_WARP
WANT_FRAGMENT=$WANT_FRAGMENT
WANT_MUX=$WANT_MUX
USE_DOMAIN=$USE_DOMAIN
DOMAIN="${DOMAIN:-}"
NGINX_PORTS="${NGINX_PORTS[*]:-}"
FP="${FP:-chrome}"
REALITY_PORT="${REALITY_PORT:-8443}"
SNI="${SNI:-www.cloudflare.com}"
HY2_PORT="${HY2_PORT:-36712}"
HY2_CERT="${HY2_CERT:-self}"
HY2_DOMAIN="${HY2_DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
CONFIG_NAME="${CONFIG_NAME:-MyVPN}"
SUB_PATH_IN="${SUB_PATH_IN:-sub}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
SUB_TOKEN="${SUB_TOKEN:-}"
HY2_PASS="${HY2_PASS:-}"
REALITY_PRIV="${REALITY_PRIV:-}"
REALITY_PUB="${REALITY_PUB:-}"
REALITY_SID="${REALITY_SID:-}"
SERVER_IP="${SERVER_IP:-}"
EOF
  local p
  for p in "${NGINX_PORTS[@]:-}"; do
    echo "PORT_IPS_${p}=\"${PORT_IPS[$p]:-}\"" >> "$STATE_FILE"
  done
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  if [ -n "${NGINX_PORTS:-}" ]; then
    NGINX_PORTS=($NGINX_PORTS)
    local p varname
    for p in "${NGINX_PORTS[@]}"; do
      varname="PORT_IPS_${p}"
      PORT_IPS[$p]="${!varname:-}"
    done
  fi
  return 0
}

# ── Input Helpers ────────────────────────────────────────────────
ask(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans=""
  if [ -n "$__default" ]; then
    printf "${C1}  ❯ ${C0}%s ${C3}[%s]${C0}: " "$__prompt" "$__default" >"$TTY"
  else
    printf "${C1}  ❯ ${C0}%s: " "$__prompt" >"$TTY"
  fi
  read -r __ans <"$TTY" || true
  [ -z "$__ans" ] && __ans="$__default"
  printf -v "$__var" '%s' "$__ans"
}

ask_yesno(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt (y/n)" "$__default"
    __ans="${!__var}"; __ans="${__ans,,}"
    case "$__ans" in
      y|yes) printf -v "$__var" 'y'; return 0 ;;
      n|no)  printf -v "$__var" 'n'; return 0 ;;
      *) warn "Please answer y or n." ;;
    esac
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

ask_choice(){
  local __var="$1" __prompt="$2" __default="$3"; shift 3
  local __valid=("$@") __ans="" v __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var}"
    for v in "${__valid[@]}"; do [ "$__ans" = "$v" ] && return 0; done
    warn "Invalid choice. Allowed: ${__valid[*]}"
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

ask_valid(){
  local __var="$1" __prompt="$2" __regex="$3" __default="${4:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var}"
    if [ -n "$__ans" ] && [[ "$__ans" =~ $__regex ]]; then return 0; fi
    warn "Invalid format, please try again."
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

ask_port(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var}"
    if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le 65535 ]; then return 0; fi
    warn "Invalid port (1-65535)."
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

is_cf_port(){
  local p="$1" e
  for e in "${CF_PORTS[@]}"; do [ "$p" = "$e" ] && return 0; done
  return 1
}

# ── Progress Bar ─────────────────────────────────────────────────
STEP_CURRENT=0
STEP_TOTAL=8

progress(){
  STEP_CURRENT=$((STEP_CURRENT+1))
  if [ $STEP_CURRENT -gt $STEP_TOTAL ]; then STEP_CURRENT=$STEP_TOTAL; fi
  local pct=$(( STEP_CURRENT * 100 / STEP_TOTAL ))
  local filled=$(( pct / 5 ))
  local bar=""
  local i
  for ((i=0; i<20; i++)); do
    if [ $i -lt $filled ]; then bar+="█"; else bar+="░"; fi
  done
  printf "\r${C2}  [%s] %3d%%${C0} %s" "$bar" "$pct" "$*" >"$TTY"
  printf "\n" >"$TTY"
}

# ════════════════════════════════════════════════════════════════
#  Installation Modes & Logic
# ════════════════════════════════════════════════════════════════

# ── Check Existing ──────────────────────────────────────────────
check_existing_install(){
  local existing=false
  [ -f /usr/local/etc/xray/config.json ] && existing=true
  [ -f /etc/hysteria/config.yaml ]       && existing=true

  if $existing; then
    printf "\n" >"$TTY"
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║   ⚠  Existing Installation Detected      ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "\n" >"$TTY"
    warn "Setting up a new config will overwrite existing configs."
    local ans
    ask_yesno ans "Do you want to create a backup before continuing?" "y"
    if [ "$ans" = "y" ]; then
      local bname
      ask bname "Enter backup name (leave empty for auto-generated)" ""
      backup_system "$bname"
    fi
    light_cleanup
  fi
}

light_cleanup() {
  info "Cleaning up old configurations..."
  systemctl stop xray hysteria-server hysteria nginx warp-svc 2>/dev/null || true
  rm -f /usr/local/etc/xray/config.json 2>/dev/null || true
  rm -f /etc/hysteria/config.yaml 2>/dev/null || true
  rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
  rm -rf /var/www/sub 2>/dev/null || true
  # Keeping binaries and other structural components for faster reinstall
}

# ── Server Init ─────────────────────────────────────────────────
server_init(){
  step "Server Initialization"
  [ -n "$PKG" ] || die "No supported package manager found (apt/dnf/yum)."
  info "Updating system packages..."
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y curl wget openssl jq nginx certbot ufw ca-certificates gnupg lsb-release fail2ban unzip net-tools qrencode htop iotop iftop vnstat chrony tzdata >/dev/null 2>&1 || true
      ;;
    dnf|yum)
      $PKG install -y curl wget openssl jq nginx certbot ufw ca-certificates gnupg fail2ban unzip net-tools qrencode htop chrony tzdata epel-release >/dev/null 2>&1 || true
      $PKG install -y vnstat >/dev/null 2>&1 || true
      ;;
  esac

  timedatectl set-timezone UTC 2>/dev/null || true
  systemctl enable chrony 2>/dev/null || systemctl enable chronyd 2>/dev/null || true
  systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true

  local mem_kb; mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  if [ "$mem_kb" -lt 1048576 ] && [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null
    chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile; echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  systemctl enable vnstat 2>/dev/null || true
  systemctl start vnstat 2>/dev/null || true

  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  [ -n "$SERVER_IP" ] || die "Could not detect server public IP."
  ok "Server ready."
}

# ── New Installation Modes ──────────────────────────────────────
new_install_menu(){
  clear_screen
  check_existing_install
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║         New Installation Mode            ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "  ${C2}1)${C0} Fast Mode         ${C3}(Auto-config Reality & Hysteria2)${C0}\n" >"$TTY"
  printf "  ${C2}2)${C0} Simple Manual     ${C3}(Step-by-step wizard)${C0}\n" >"$TTY"
  printf "  ${C2}3)${C0} Advanced Manual   ${C3}(Dynamic menu for all settings)${C0}\n" >"$TTY"
  printf "  ${C2}0)${C0} Back to Main Menu\n\n" >"$TTY"
  
  local mode
  ask_choice mode "Select Mode" "1" 1 2 3 0
  
  case "$mode" in
    1) mode_fast ;;
    2) mode_simple ;;
    3) mode_advanced ;;
    0) return ;;
  esac
}

mode_fast(){
  info "Running Fast Mode..."
  # Defaults for fast mode
  WANT_REALITY=true; WANT_HY2=true
  WANT_WS=false; WANT_XHTTP=false; USE_DOMAIN=false
  WANT_WARP=false; WANT_FRAGMENT=false; WANT_MUX=false
  REALITY_PORT=8443; SNI="www.cloudflare.com"
  HY2_PORT=36712; HY2_CERT="self"; FP="chrome"
  
  ask SUB_PATH_IN "Enter Subscription path segment" "sub"
  ask CONFIG_NAME "Enter VPN Config Name" "FastVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"
  
  execute_build
}

mode_simple(){
  info "Running Simple Wizard..."
  printf "\n" >"$TTY"
  printf "  ${C2}1)${C0} All       — WS + XHTTP + Reality + Hysteria2\n" >"$TTY"
  printf "  ${C2}2)${C0} CDN only  — VLESS-WS + VLESS-XHTTP\n" >"$TTY"
  printf "  ${C2}3)${C0} Reality   — Direct TCP\n" >"$TTY"
  printf "  ${C2}4)${C0} Hysteria2 — QUIC/UDP\n" >"$TTY"
  
  local p_mode
  ask_choice p_mode "Protocol Mode" "1" 1 2 3 4
  WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
  case "$p_mode" in
    1) WANT_WS=true; WANT_XHTTP=true; WANT_REALITY=true; WANT_HY2=true ;;
    2) WANT_WS=true; WANT_XHTTP=true ;;
    3) WANT_REALITY=true ;;
    4) WANT_HY2=true ;;
  esac
  
  if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; else USE_DOMAIN=false; fi
  
  local a
  ask_yesno a "Enable Fragment?" "y"; [ "$a" = y ] && WANT_FRAGMENT=true || WANT_FRAGMENT=false
  if $USE_DOMAIN; then
    ask_yesno a "Enable Mux?" "y"; [ "$a" = y ] && WANT_MUX=true || WANT_MUX=false
  fi
  ask_yesno a "Enable WARP outbound?" "y"; [ "$a" = y ] && WANT_WARP=true || WANT_WARP=false
  
  if $USE_DOMAIN; then
    ask_valid DOMAIN "Domain for WS/XHTTP" "$RE_DOMAIN"
    NGINX_PORTS=(2096)
  fi
  
  ask CONFIG_NAME "Config name" "MyVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"
  ask SUB_PATH_IN "Subscription path segment" "sub"
  
  execute_build
}

mode_advanced(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Advanced Settings             ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C3}Protocols:${C0}\n" >"$TTY"
    printf "  ${C2}1)${C0} VLESS-WS      : ${CG}%s${C0}\n" "$($WANT_WS && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}2)${C0} VLESS-XHTTP   : ${CG}%s${C0}\n" "$($WANT_XHTTP && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}3)${C0} VLESS-Reality : ${CG}%s${C0}\n" "$($WANT_REALITY && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}4)${C0} Hysteria2     : ${CG}%s${C0}\n" "$($WANT_HY2 && echo ON || echo OFF)" >"$TTY"
    
    printf "\n  ${C3}Features:${C0}\n" >"$TTY"
    printf "  ${C2}5)${C0} WARP Outbound : ${CG}%s${C0}\n" "$($WANT_WARP && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}6)${C0} Fragment      : ${CG}%s${C0}\n" "$($WANT_FRAGMENT && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}7)${C0} Mux           : ${CG}%s${C0}\n" "$($WANT_MUX && echo ON || echo OFF)" >"$TTY"
    
    printf "\n  ${C3}General Info:${C0}\n" >"$TTY"
    printf "  ${C2}8)${C0} Domain        : ${CC}%s${C0}\n" "${DOMAIN:-[Not Set]}" >"$TTY"
    printf "  ${C2}9)${C0} Config Name   : ${CC}%s${C0}\n" "${CONFIG_NAME}" >"$TTY"
    printf "  ${C2}10)${C0} Sub Path      : ${CC}%s${C0}\n" "${SUB_PATH_IN}" >"$TTY"
    
    printf "\n  ${CG}0) Start Build${C0}\n" >"$TTY"
    printf "  ${CR}99) Cancel${C0}\n" >"$TTY"
    
    local opt
    ask opt "Select an option" ""
    case "$opt" in
      1) $WANT_WS && WANT_WS=false || WANT_WS=true ;;
      2) $WANT_XHTTP && WANT_XHTTP=false || WANT_XHTTP=true ;;
      3) $WANT_REALITY && WANT_REALITY=false || WANT_REALITY=true ;;
      4) $WANT_HY2 && WANT_HY2=false || WANT_HY2=true ;;
      5) $WANT_WARP && WANT_WARP=false || WANT_WARP=true ;;
      6) $WANT_FRAGMENT && WANT_FRAGMENT=false || WANT_FRAGMENT=true ;;
      7) $WANT_MUX && WANT_MUX=false || WANT_MUX=true ;;
      8) ask_valid DOMAIN "Enter Domain" "$RE_DOMAIN" "${DOMAIN}" ;;
      9) ask CONFIG_NAME "Enter Config Name" "${CONFIG_NAME}"; CONFIG_NAME="${CONFIG_NAME// /_}" ;;
      10) ask_valid SUB_PATH_IN "Enter Subscription Path" "$RE_SUBPATH" "${SUB_PATH_IN}" ;;
      0) 
        if ! $WANT_WS && ! $WANT_XHTTP && ! $WANT_REALITY && ! $WANT_HY2; then
          warn "At least one protocol must be selected!"; press_enter; continue
        fi
        if { $WANT_WS || $WANT_XHTTP; } && [ -z "$DOMAIN" ]; then
          warn "Domain is required for WS/XHTTP!"; press_enter; continue
        fi
        if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; else USE_DOMAIN=false; fi
        [ "${#NGINX_PORTS[@]}" -eq 0 ] && NGINX_PORTS=(2096)
        execute_build
        return
        ;;
      99) return ;;
      *) warn "Invalid option"; press_enter ;;
    esac
  done
}

# ── Execution Pipeline ──────────────────────────────────────────
execute_build(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║           Building Configurations        ║"
  banner "  ╚══════════════════════════════════════════╝"
  STEP_CURRENT=0
  
  server_init
  install_xray
  install_hysteria
  install_warp
  
  if [ -z "$UUID" ]; then gen_secrets; fi
  
  write_xray_config
  write_nginx
  write_hysteria
  build_links
  build_subscription
  
  setup_firewall
  start_services
  
  save_state
  final_output
  press_enter
}

# ── Sub-components for Execution ────────────────────────────────
install_xray(){
  progress "Installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || die "Xray installation failed."
}

install_hysteria(){
  $WANT_HY2 || return 0
  progress "Installing Hysteria2"
  bash -c "$(curl -fsSL https://get.hy2.sh/)" >/dev/null 2>&1 || die "Hysteria2 installation failed."
}

install_warp(){
  $WANT_WARP || return 0
  progress "Installing WARP (Proxy mode)"
  if ! command -v warp-cli >/dev/null 2>&1; then
    if [ "$PKG" = "apt" ]; then
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1; apt-get install -y cloudflare-warp >/dev/null 2>&1 || WANT_WARP=false
    else
      WANT_WARP=false
    fi
  fi
  if $WANT_WARP; then
    warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
  fi
}

gen_secrets(){
  progress "Generating Secrets"
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  WS_PATH="/$(openssl rand -hex 6)"
  XHTTP_PATH="/$(openssl rand -hex 6)"
  SUB_TOKEN="$(openssl rand -hex 16)"
  HY2_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)"
  if $WANT_REALITY; then
    local kp; kp="$(xray x25519)"
    REALITY_PRIV="$(echo "$kp" | awk -F': *' '/[Pp]rivate/{print $2}' | tr -d '[:space:]')"
    REALITY_PUB="$(echo "$kp"  | awk -F': *' '/[Pp]ublic/{print $2}'  | tr -d '[:space:]')"
    REALITY_SID="$(openssl rand -hex 8)"
  fi
}

write_xray_config(){
  progress "Writing Xray Configuration"
  mkdir -p /usr/local/etc/xray
  local sniff='"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}'
  local IN=() OUT=() RULES=()

  $WANT_WS && IN+=("{\"listen\":\"127.0.0.1\",\"port\":${WS_INT},\"protocol\":\"vless\",\"tag\":\"ws-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"${WS_PATH}\"}},${sniff}}")
  $WANT_XHTTP && IN+=("{\"listen\":\"127.0.0.1\",\"port\":${XHTTP_INT},\"protocol\":\"vless\",\"tag\":\"xhttp-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"${XHTTP_PATH}\",\"mode\":\"auto\"}},${sniff}}")
  $WANT_REALITY && IN+=("{\"listen\":\"0.0.0.0\",\"port\":${REALITY_PORT},\"protocol\":\"vless\",\"tag\":\"reality-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"${SNI}:443\",\"xver\":0,\"serverNames\":[\"${SNI}\"],\"privateKey\":\"${REALITY_PRIV}\",\"shortIds\":[\"${REALITY_SID}\"]}},${sniff}}")

  OUT+=('{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}')
  OUT+=('{"tag":"block","protocol":"blackhole","settings":{}}')
  $WANT_WARP && OUT+=("{\"tag\":\"warp\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":${WARP_PORT}}]}}")

  RULES+=('{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}')
  RULES+=('{"type":"field","ip":["geoip:private"],"outboundTag":"block"}')
  $WANT_WARP && RULES+=('{"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix","geosite:spotify","domain:claude.ai","domain:anthropic.com","domain:chatgpt.com"],"outboundTag":"warp"}')
  RULES+=('{"type":"field","domain":["geosite:category-ir"],"outboundTag":"direct"}')
  RULES+=('{"type":"field","ip":["geoip:ir"],"outboundTag":"direct"}')

  local in_json; in_json="$(IFS=,; echo "${IN[*]}")"
  local out_json; out_json="$(IFS=,; echo "${OUT[*]}")"
  local rule_json; rule_json="$(IFS=,; echo "${RULES[*]}")"

  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[${in_json}],
  "outbounds":[${out_json}],
  "routing":{"domainStrategy":"IpIfNonMatch","rules":[${rule_json}]}
}
JSON
}

write_nginx(){
  $USE_DOMAIN || return 0
  progress "Writing Nginx Configuration"
  mkdir -p /var/www/html /var/www/sub /etc/ssl/xray
  [ -f /var/www/html/index.html ] || echo "<h1>It works</h1>" > /var/www/html/index.html

  if [ ! -f /etc/ssl/xray/self.key ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout /etc/ssl/xray/self.key -out /etc/ssl/xray/self.crt -subj "/CN=${DOMAIN}" >/dev/null 2>&1 || true
  fi

  local listens="" p
  for p in "${NGINX_PORTS[@]}"; do
    listens+="    listen ${p} ssl; listen [::]:${p} ssl;"
  done

  local locs=""
  if $WANT_WS; then
    locs+="
    location ${WS_PATH} {
        if (\$http_upgrade != \"websocket\") { return 404; }
        proxy_pass http://127.0.0.1:${WS_INT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }"
  fi
  if $WANT_XHTTP; then
    locs+="
    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_INT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
    }"
  fi

  cat > /etc/nginx/conf.d/xray.conf <<NGINX
server {
${listens}
    server_name ${DOMAIN};
    ssl_certificate     /etc/ssl/xray/self.crt;
    ssl_certificate_key /etc/ssl/xray/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    location /${SUB_PATH_IN}/${SUB_TOKEN} {
        default_type text/plain;
        alias /var/www/sub/${SUB_TOKEN}.txt;
    }
${locs}
}
NGINX
}

write_hysteria(){
  $WANT_HY2 || return 0
  progress "Writing Hysteria2 Configuration"
  mkdir -p /etc/hysteria

  HY2_CERT="self"
  if [ ! -f /etc/hysteria/server.key ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1 || true
  fi
  
  local acl_block=""
  if $WANT_WARP; then
    acl_block="
outbounds:
  - name: direct
    type: direct
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_PORT}
acl:
  inline:
    - warp(geosite:google)
    - warp(geosite:openai)
    - warp(geosite:netflix)
    - direct(all)"
  fi

  cat > /etc/hysteria/config.yaml <<YAML
listen: :${HY2_PORT}
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: ${HY2_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
${acl_block}
YAML
  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<OVR
[Service]
User=root
Group=root
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
OVR
  systemctl daemon-reload >/dev/null 2>&1 || true
}

urlenc(){
  local s="$1" o="" c i
  for ((i=0;i<${#s};i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) o+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; o+="$c" ;;
    esac
  done
  printf '%s' "$o"
}

build_links(){
  progress "Building Links"
  LINKS=()
  local fp="${FP:-chrome}" enc_ws enc_xh
  enc_ws="$(urlenc "${WS_PATH}")"
  enc_xh="$(urlenc "${XHTTP_PATH}")"

  if $WANT_WS || $WANT_XHTTP; then
    local p ips arr addr tag
    for p in "${NGINX_PORTS[@]:-}"; do
      ips="${PORT_IPS[$p]:-}"
      if [ -n "$ips" ]; then IFS=',' read -ra arr <<<"$ips"; else arr=("$DOMAIN"); fi
      for addr in "${arr[@]}"; do
        if $WANT_WS; then
          tag="${CONFIG_NAME}-WS-${p}-${addr}"
          LINKS+=("vless://${UUID}@${addr}:${p}?encryption=none&security=tls&sni=${DOMAIN}&fp=${fp}&type=ws&host=${DOMAIN}&path=${enc_ws}#$(urlenc "$tag")")
        fi
        if $WANT_XHTTP; then
          tag="${CONFIG_NAME}-XHTTP-${p}-${addr}"
          LINKS+=("vless://${UUID}@${addr}:${p}?encryption=none&security=tls&sni=${DOMAIN}&fp=${fp}&type=xhttp&host=${DOMAIN}&path=${enc_xh}&mode=auto#$(urlenc "$tag")")
        fi
      done
    done
  fi

  if $WANT_REALITY; then
    LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=${fp}&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision&type=tcp#$(urlenc "${CONFIG_NAME}-Reality")")
  fi

  if $WANT_HY2; then
    LINKS+=("hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${HY2_SNI}&insecure=1#$(urlenc "${CONFIG_NAME}-HY2")")
  fi
}

build_subscription(){
  $USE_DOMAIN || return 0
  progress "Building Subscription"
  mkdir -p /var/www/sub
  local raw; raw="$(printf '%s\n' "${LINKS[@]}")"
  printf '%s' "$raw" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt" 2>/dev/null || printf '%s' "$raw" | base64 | tr -d '\n' > "/var/www/sub/${SUB_TOKEN}.txt"
}

setup_firewall(){
  progress "Configuring Firewall"
  command -v ufw >/dev/null 2>&1 || return 0
  local p
  for p in "${NGINX_PORTS[@]:-}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
  $WANT_REALITY && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  $WANT_HY2     && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

start_services(){
  progress "Restarting Services"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || true
  if $USE_DOMAIN; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true
  fi
  if $WANT_HY2; then
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    systemctl restart hysteria-server >/dev/null 2>&1 || true
  fi
}

final_output(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║          Installation Complete           ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n  ${CB}Share links:${C0}\n\n" >"$TTY"
  local l
  for l in "${LINKS[@]}"; do
    printf "${CG}%s${C0}\n\n" "$l" >"$TTY"
  done
  if $USE_DOMAIN; then
    printf "  ${CB}Subscription URL:${C0}\n  ${C1}https://${DOMAIN}:${NGINX_PORTS[0]}/${SUB_PATH_IN}/${SUB_TOKEN}${C0}\n\n" >"$TTY"
  fi
}

# ── Modify Config Menu ──────────────────────────────────────────
modify_config_menu(){
  if ! load_state; then
    warn "No existing configuration found to modify."
    press_enter
    return
  fi
  mode_advanced
}

# ── Rebuild Config ──────────────────────────────────────────────
rebuild_config(){
  if ! load_state; then
    warn "No state found to rebuild."
    press_enter
    return
  fi
  execute_build
}

# ── Backup & Restore ────────────────────────────────────────────
backup_system(){
  local custom_name="${1:-}"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local bdir="/root/vpn-backup-${ts}"
  [ -n "$custom_name" ] && bdir="/root/vpn-backup-${custom_name}-${ts}"
  
  mkdir -p "$bdir"
  cp -a /usr/local/etc/xray/config.json "$bdir/" 2>/dev/null || true
  cp -a /etc/nginx/conf.d               "$bdir/nginx-conf.d" 2>/dev/null || true
  cp -a /etc/hysteria/config.yaml       "$bdir/"          2>/dev/null || true
  cp -a /var/www/sub                    "$bdir/sub"        2>/dev/null || true
  cp -a /etc/ssl/xray                   "$bdir/ssl-xray"   2>/dev/null || true
  cp -a "$STATE_FILE"                   "$bdir/" 2>/dev/null || true
  
  ok "Backup saved to: $bdir"
}

restore_menu(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║            Restore Backup                ║"
  banner "  ╚══════════════════════════════════════════╝"
  
  local backups=($(ls -1d /root/vpn-backup-* 2>/dev/null || true))
  if [ ${#backups[@]} -eq 0 ]; then
    warn "No backups found in /root/"
    press_enter
    return
  fi
  
  local i=1
  for b in "${backups[@]}"; do
    printf "  ${C2}%d)${C0} %s\n" "$i" "$(basename "$b")" >"$TTY"
    i=$((i+1))
  done
  printf "  ${CR}0)${C0} Cancel\n\n" >"$TTY"
  
  local sel
  ask sel "Select backup to restore" "0"
  if [ "$sel" -eq 0 ]; then return; fi
  if [ "$sel" -ge 1 ] && [ "$sel" -le "${#backups[@]}" ]; then
    local chosen="${backups[$((sel-1))]}"
    info "Restoring from $chosen ..."
    systemctl stop xray hysteria-server nginx 2>/dev/null || true
    
    cp -a "$chosen/config.json" /usr/local/etc/xray/ 2>/dev/null || true
    cp -a "$chosen/nginx-conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
    cp -a "$chosen/config.yaml" /etc/hysteria/ 2>/dev/null || true
    cp -a "$chosen/sub/"* /var/www/sub/ 2>/dev/null || true
    cp -a "$chosen/ssl-xray/"* /etc/ssl/xray/ 2>/dev/null || true
    cp -a "$chosen/state.env" "$STATE_FILE" 2>/dev/null || true
    
    systemctl restart xray hysteria-server nginx 2>/dev/null || true
    ok "Restore complete."
    press_enter
  else
    warn "Invalid selection."
    press_enter
  fi
}

# ── Status ──────────────────────────────────────────────────────
show_status(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║              System Status               ║"
  banner "  ╚══════════════════════════════════════════╝"
  
  printf "\n${CB}  --- Network Usage ---${C0}\n" >"$TTY"
  if command -v vnstat >/dev/null 2>&1; then
    vnstat || echo "vnstat data not yet available."
  else
    echo "vnstat not installed."
  fi
  
  printf "\n${CB}  --- Service Uptime ---${C0}\n" >"$TTY"
  systemctl status xray | grep Active || true
  systemctl status hysteria-server | grep Active || true
  systemctl status nginx | grep Active || true
  
  press_enter
}

# ── Complete Removal ────────────────────────────────────────────
full_removal(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║          Complete Removal                ║"
  banner "  ╚══════════════════════════════════════════╝"
  warn "This will remove Xray, Hysteria, WARP, configs, logs, and backups!"
  local ans
  ask_yesno ans "Are you absolutely sure?" "n"
  if [ "$ans" = "y" ]; then
    info "Stopping services..."
    systemctl stop xray hysteria-server hysteria warp-svc nginx 2>/dev/null || true
    systemctl disable xray hysteria-server hysteria warp-svc nginx 2>/dev/null || true
    
    info "Deleting files..."
    rm -rf /usr/local/etc/xray /etc/hysteria /etc/vpn-installer /var/www/sub /etc/ssl/xray
    rm -f /etc/nginx/conf.d/xray.conf
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria*
    rm -rf /root/vpn-backup-*
    
    if command -v warp-cli >/dev/null 2>&1; then
      warp-cli disconnect 2>/dev/null || true
      warp-cli registration delete 2>/dev/null || true
    fi
    
    systemctl daemon-reload
    ok "Complete removal finished."
    exit 0
  fi
}

# ── Main Menu ───────────────────────────────────────────────────
main_menu(){
  while true; do
    welcome_screen
    printf "  ${C2}1)${C0} New Installation\n" >"$TTY"
    printf "  ${C2}2)${C0} Modify Current Configuration\n" >"$TTY"
    printf "  ${C2}3)${C0} Rebuild Configurations\n" >"$TTY"
    printf "  ${C2}4)${C0} Restore Backup\n" >"$TTY"
    printf "  ${C2}5)${C0} Status (Data & Uptime)\n" >"$TTY"
    printf "  ${C2}6)${C0} Complete Removal\n" >"$TTY"
    printf "  ${CR}7)${C0} Exit\n\n" >"$TTY"
    
    local opt
    ask opt "Please select an option" ""
    case "$opt" in
      1) new_install_menu ;;
      2) modify_config_menu ;;
      3) rebuild_config ;;
      4) restore_menu ;;
      5) show_status ;;
      6) full_removal ;;
      7) clear_screen; ok "Goodbye!"; exit 0 ;;
      *) warn "Invalid option"; press_enter ;;
    esac
  done
}

main(){
  main_menu
}

main "$@"
