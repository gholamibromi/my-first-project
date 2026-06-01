#!/usr/bin/env bash
# نصب چندپروتکلی: VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
# + Sniffing + WARP outbound + Routing + Multi-address subscription
# UI انگلیسی، کامنت‌ها فارسی. ورودی از /dev/tty خوانده می‌شود.
set -uo pipefail

# ---------- رنگ‌ها و TTY ----------
C0=$'\033[0m'; C1=$'\033[36m'; C2=$'\033[1;33m'; C3=$'\033[1;35m'; CR=$'\033[31m'; CG=$'\033[32m'
CC=$'\033[38;5;51m'
TTY=/dev/tty

clear_screen() { printf "\033c" >"$TTY"; }
ok(){   printf "${CG}[ok]${C0} %s\n"   "$*" >"$TTY"; }
warn(){ printf "${C2}[warn]${C0} %s\n" "$*" >"$TTY"; }
die(){  printf "${CR}[err]${C0} %s\n"  "$*" >"$TTY"; exit 1; }
info()  { printf "  ·  %s\n" "$*" >"$TTY"; }
banner(){ printf "${C2}%s${C0}\n" "$*" >"$TTY"; }
press_enter() {
  if [ "${HEADLESS:-false}" = "true" ]; then return 0; fi
  printf "\nPress Enter to continue..." >"$TTY"
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
  banner "  ║                              Author: MOJA                                  ║"
  banner "  ║                  Supported: VLESS, Hysteria2, WARP, Nginx                    ║"
  banner "  ╚══════════════════════════════════════════════════════════════════════════════╝"
  printf "  ${CR}⚠️ هشدار آموزشی: این پروژه صرفاً جهت مقاصد تحصیلی، تحقیقاتی و دور زدن تحریم‌های ناعادلانه توسعه یافته است.${C0}\n\n" >"$TTY"
}

MAX_TRIES=3

RE_DOMAIN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
RE_EMAIL='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
RE_EXT='^PORT_IPS\[([0-9]+)\]="?([0-9A-Za-z.,:_-]+)"?$'
RE_SUBPATH='^[A-Za-z0-9._-]+$'

CF_PORTS=(443 2053 2083 2087 2096 8443)
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"
WARP_PORT=40000
STATE_FILE="/etc/vpn-installer/state.env"

# ---------- وضعیت‌ها ----------
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
WANT_WARP=false
USE_DOMAIN=false
NGINX_PORTS=()
declare -A PORT_IPS
EXT_COUNT=0
SUB_TOKEN=""
LINKS=()
DOMAIN=""
REALITY_PORT="8443"
SNI="www.microsoft.com"
REALITY_SNIS=""
HY2_PORT="36712"
HY2_CERT="self"
HY2_DOMAIN=""
LE_EMAIL=""
CONFIG_NAME="MyVPN"
SUB_PATH_IN=""
FP="chrome"
SERVER_IP=""

UUID=""; WS_PATH=""; XHTTP_PATH=""; HY2_PASS=""
REALITY_PRIV=""; REALITY_PUB=""; REALITY_SID=""

TLS_MIN="1.2"
TLS_MAX="1.3"
ALPN="h2,http/1.1"
BLOCK_QUIC=false
IP_PREF="auto"
MUX=false
FRAGMENT=false

[ "$(id -u)" = 0 ] || die "Please run as root."

PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found."

# ── State Management ─────────────────────────────────────────────
save_state() {
  mkdir -p /etc/vpn-installer
  cat > "$STATE_FILE" <<EOF
WANT_WS=$WANT_WS
WANT_XHTTP=$WANT_XHTTP
WANT_REALITY=$WANT_REALITY
WANT_HY2=$WANT_HY2
WANT_WARP=$WANT_WARP
USE_DOMAIN=$USE_DOMAIN
DOMAIN="${DOMAIN:-}"
NGINX_PORTS="${NGINX_PORTS[*]:-}"
FP="${FP:-chrome}"
REALITY_PORT="${REALITY_PORT:-8443}"
SNI="${SNI:-www.microsoft.com}"
REALITY_SNIS="${REALITY_SNIS:-}"
HY2_PORT="${HY2_PORT:-36712}"
HY2_CERT="${HY2_CERT:-self}"
HY2_DOMAIN="${HY2_DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
CONFIG_NAME="${CONFIG_NAME:-MyVPN}"
SUB_PATH_IN="${SUB_PATH_IN:-}"
UUID="${UUID:-}"
WS_PATH="${WS_PATH:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
SUB_TOKEN="${SUB_TOKEN:-}"
HY2_PASS="${HY2_PASS:-}"
REALITY_PRIV="${REALITY_PRIV:-}"
REALITY_PUB="${REALITY_PUB:-}"
REALITY_SID="${REALITY_SID:-}"
SERVER_IP="${SERVER_IP:-}"
TLS_MIN="${TLS_MIN:-1.2}"
TLS_MAX="${TLS_MAX:-1.3}"
ALPN="${ALPN:-h2,http/1.1}"
BLOCK_QUIC=$BLOCK_QUIC
IP_PREF="${IP_PREF:-auto}"
MUX=$MUX
FRAGMENT=$FRAGMENT
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

# ── Helpers ──────────────────────────────────────────────────────
ask(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans=""
  if [ -n "$__default" ]; then
    printf "${C1}? ${C0}%s [%s]: " "$__prompt" "$__default" >"$TTY"
  else
    printf "${C1}? ${C0}%s: " "$__prompt" >"$TTY"
  fi
  read -r __ans <"$TTY" || true
  [ -z "$__ans" ] && __ans="$__default"
  printf -v "$__var" '%s' "$__ans"
}

ask_yesno(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt (y/n)" "$__default"
    __ans="${!__var:-}"; __ans="${__ans,,}"
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
    __ans="${!__var:-}"
    for v in "${__valid[@]}"; do
      [ "$__ans" = "$v" ] && return 0
    done
    warn "Invalid choice. Allowed: ${__valid[*]}"
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

ask_valid(){
  local __var="$1" __prompt="$2" __regex="$3" __default="${4:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var:-}"
    if [ -n "$__ans" ] && [[ "$__ans" =~ $__regex ]]; then
      return 0
    fi
    warn "Invalid format, please try again."
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

ask_port(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans="" __try=0
  while [ "$__try" -lt "$MAX_TRIES" ]; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var:-}"
    if [[ "$__ans" =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le 65535 ]; then
      return 0
    fi
    warn "Invalid port (must be 1-65535)."
    __try=$((__try+1))
  done
  die "Too many invalid attempts."
}

is_cf_port(){
  local p="$1" e
  for e in "${CF_PORTS[@]}"; do [ "$p" = "$e" ] && return 0; done
  return 1
}

# ---------- تشخیص نصب قبلی + بکاپ + پاک‌سازی عمیق ----------
preflight_check(){
  local existing=false
  [ -f /usr/local/etc/xray/config.json ] && existing=true
  [ -f /etc/nginx/conf.d/xray.conf ]     && existing=true
  [ -f /etc/hysteria/config.yaml ]       && existing=true
  $existing || return 0

  warn "An existing installation was detected on this server."
  [ -f /usr/local/etc/xray/config.json ] && printf "    - /usr/local/etc/xray/config.json\n" >"$TTY"
  [ -f /etc/nginx/conf.d/xray.conf ]     && printf "    - /etc/nginx/conf.d/xray.conf\n" >"$TTY"
  [ -f /etc/hysteria/config.yaml ]       && printf "    - /etc/hysteria/config.yaml\n" >"$TTY"

  printf "\n${C2}What do you want to do?${C0}\n" >"$TTY"
  printf "  1) Backup + deep-clean old install, then reinstall (old links stop working)\n" >"$TTY"
  printf "  2) Abort and keep everything as-is\n" >"$TTY"
  ask_choice EX_CH "Choice" "2" 1 2
  [ "${EX_CH:-}" = "2" ] && { ok "Aborted. Nothing changed."; return 1; }

  local bname=""
  ask bname "Enter backup name (leave empty for auto-generated)" ""
  backup_existing "$bname"
  cleanup_existing
  return 0
}

backup_existing(){
  local custom_name="${1:-}"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local bdir="/root/vpn-backup-${ts}"
  [ -n "$custom_name" ] && bdir="/root/vpn-backup-${custom_name}-${ts}"

  mkdir -p "$bdir"
  cp -a /usr/local/etc/xray/config.json "$bdir/" 2>/dev/null || true
  cp -a /etc/nginx/conf.d               "$bdir/nginx-conf.d" 2>/dev/null || true
  cp -a /etc/hysteria/config.yaml       "$bdir/" 2>/dev/null || true
  cp -a /var/www/sub                    "$bdir/sub" 2>/dev/null || true
  cp -a "$STATE_FILE"                   "$bdir/" 2>/dev/null || true
  ok "Old configs backed up to: ${bdir}"
}

cleanup_existing(){
  local svc
  killall -9 xray hysteria hysteria-server 2>/dev/null || true
  for svc in xray nginx hysteria-server hysteria warp-svc; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  rm -rf /usr/local/etc/xray 2>/dev/null || true
  rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  local f
  for f in /etc/nginx/conf.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE '127\.0\.0\.1:(10001|10002)|/var/www/sub' "$f" 2>/dev/null; then
      rm -f "$f"
      warn "Removed leftover nginx file: $f"
    fi
  done

  rm -rf /var/www/sub 2>/dev/null || true
  rm -f  /var/www/html/index.html 2>/dev/null || true
  rm -rf /etc/ssl/xray 2>/dev/null || true
  rm -f  /etc/hysteria/config.yaml 2>/dev/null || true
  rm -f  /etc/hysteria/cert.pem /etc/hysteria/key.pem 2>/dev/null || true
  rm -rf /etc/systemd/system/hysteria-server.service.d 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true

  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 \
      && ok "Remaining Nginx config is valid." \
      || warn "Nginx has other sites or empty config; install step will fix it."
  fi
  ok "Deep cleanup done."
}

# ── Installation Modes ───────────────────────────────────────────
new_install_menu(){
  clear_screen
  preflight_check || return
  
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║         New Installation Mode            ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "  ${C2}1)${C0} Fast Mode         ${C3}(Auto-config Reality & Hysteria2)${C0}\n" >"$TTY"
  printf "  ${C2}2)${C0} Simple Manual     ${C3}(Step-by-step wizard)${C0}\n" >"$TTY"
  printf "  ${C2}3)${C0} Advanced Panel    ${C3}(Full control over all settings)${C0}\n" >"$TTY"
  printf "  ${C2}0)${C0} Cancel\n\n" >"$TTY"
  
  local mode=""
  ask_choice mode "Select Mode" "1" 1 2 3 0
  
  case "${mode:-}" in
    1) mode_fast ;;
    2) mode_simple ;;
    3) mode_advanced ;;
    0) return ;;
  esac
}

mode_fast(){
  info "Running Fast Mode..."
  WANT_REALITY=true; WANT_HY2=true
  WANT_WS=false; WANT_XHTTP=false; USE_DOMAIN=false
  WANT_WARP=false
  REALITY_PORT=8443; SNI="www.microsoft.com"
  HY2_PORT=36712; HY2_CERT="self"; FP="chrome"
  
  ask SUB_PATH_IN "Enter Subscription path segment" "sub"
  ask CONFIG_NAME "Enter VPN Config Name" "FastVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"
  if [ -n "${SUB_PATH_IN:-}" ]; then
    SUB_TOKEN="$SUB_PATH_IN"
  else
    SUB_TOKEN="$(openssl rand -hex 16)"
  fi
  
  execute_build
}

mode_simple(){
  info "Running Simple Wizard..."
  menu_mode
  collect_inputs
  execute_build
}

# ── Advanced Menus ───────────────────────────────────────────────
mode_advanced(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Advanced Panel                ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C2}1)${C0} Core Protocols      ${C3}(WS, XHTTP, Reality, HY2, WARP)${C0}\n" >"$TTY"
    printf "  ${C2}2)${C0} Network & Domain    ${C3}(Domain, Ports, Sub Path)${C0}\n" >"$TTY"
    printf "  ${C2}3)${C0} Identity & Secrets  ${C3}(UUID, Keys, Password)${C0}\n" >"$TTY"
    printf "  ${C2}4)${C0} TLS & Reality Tweaks${C3}(SNI, ALPN, Mux, Fragment)${C0}\n" >"$TTY"
    printf "  ${C2}5)${C0} Routing & Rules     ${C3}(Block QUIC, IPv4/IPv6)${C0}\n" >"$TTY"
    printf "\n  ${CG}0) Start Build${C0}\n" >"$TTY"
    printf "  ${CR}99) Cancel${C0}\n\n" >"$TTY"
    
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) adv_core ;;
      2) adv_network ;;
      3) adv_identity ;;
      4) adv_tls ;;
      5) adv_routing ;;
      0) 
        if ! $WANT_WS && ! $WANT_XHTTP && ! $WANT_REALITY && ! $WANT_HY2; then
          warn "At least one protocol must be selected!"; press_enter; continue
        fi
        if { $WANT_WS || $WANT_XHTTP; } && [ -z "${DOMAIN:-}" ]; then
          warn "Domain is required for WS/XHTTP!"; press_enter; continue
        fi
        if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; else USE_DOMAIN=false; fi
        [ "${#NGINX_PORTS[@]}" -eq 0 ] && NGINX_PORTS=(2096)
        
        if [ -n "${SUB_PATH_IN:-}" ]; then SUB_TOKEN="$SUB_PATH_IN"; else SUB_TOKEN="$(openssl rand -hex 16)"; fi
        execute_build
        return
        ;;
      99) return ;;
      *) warn "Invalid option"; press_enter ;;
    esac
  done
}

adv_core(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Core Protocols                ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C2}1)${C0} VLESS-WS      : ${CG}%s${C0}\n" "$($WANT_WS && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}2)${C0} VLESS-XHTTP   : ${CG}%s${C0}\n" "$($WANT_XHTTP && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}3)${C0} VLESS-Reality : ${CG}%s${C0}\n" "$($WANT_REALITY && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}4)${C0} Hysteria2     : ${CG}%s${C0}\n" "$($WANT_HY2 && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}5)${C0} WARP Outbound : ${CG}%s${C0}\n" "$($WANT_WARP && echo ON || echo OFF)" >"$TTY"
    printf "\n  ${CR}0) Back${C0}\n\n" >"$TTY"
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) $WANT_WS && WANT_WS=false || WANT_WS=true ;;
      2) $WANT_XHTTP && WANT_XHTTP=false || WANT_XHTTP=true ;;
      3) $WANT_REALITY && WANT_REALITY=false || WANT_REALITY=true ;;
      4) $WANT_HY2 && WANT_HY2=false || WANT_HY2=true ;;
      5) $WANT_WARP && WANT_WARP=false || WANT_WARP=true ;;
      0) return ;;
    esac
  done
}

adv_network(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Network & Domain              ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C2}1)${C0} Domain        : ${CC}%s${C0}\n" "${DOMAIN:-[Not Set]}" >"$TTY"
    printf "  ${C2}2)${C0} Nginx Ports   : ${CC}%s${C0}\n" "${NGINX_PORTS[*]:-[Not Set]}" >"$TTY"
    printf "  ${C2}3)${C0} Sub Path      : ${CC}%s${C0}\n" "${SUB_PATH_IN:-}" >"$TTY"
    printf "  ${C2}4)${C0} Config Name   : ${CC}%s${C0}\n" "${CONFIG_NAME:-}" >"$TTY"
    printf "  ${C2}5)${C0} Fingerprint   : ${CC}%s${C0}\n" "${FP:-}" >"$TTY"
    printf "  ${C2}6)${C0} Reality Port  : ${CC}%s${C0}\n" "${REALITY_PORT:-}" >"$TTY"
    printf "  ${C2}7)${C0} HY2 Port      : ${CC}%s${C0}\n" "${HY2_PORT:-}" >"$TTY"
    printf "  ${C2}8)${C0} External Proxy IPs (For Sub)\n" >"$TTY"
    printf "\n  ${CR}0) Back${C0}\n\n" >"$TTY"
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) ask_valid DOMAIN "Enter Domain" "$RE_DOMAIN" "${DOMAIN:-}" ;;
      2) collect_nginx_ports ;;
      3) ask_valid SUB_PATH_IN "Enter Subscription Path" "$RE_SUBPATH" "${SUB_PATH_IN:-}" ;;
      4) ask CONFIG_NAME "Enter Config Name" "${CONFIG_NAME:-}"; CONFIG_NAME="${CONFIG_NAME// /_}" ;;
      5) menu_fingerprint ;;
      6) ask_port REALITY_PORT "Reality Port" "${REALITY_PORT:-}" ;;
      7) ask_port HY2_PORT "HY2 Port" "${HY2_PORT:-}" ;;
      8) collect_external_proxies ;;
      0) return ;;
    esac
  done
}

adv_identity(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Identity & Secrets            ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C3}Note: Set these manually to migrate servers without updating clients!${C0}\n" >"$TTY"
    printf "  ${C2}1)${C0} UUID          : ${CC}%s${C0}\n" "${UUID:-[Auto-generated]}" >"$TTY"
    printf "  ${C2}2)${C0} Reality Priv  : ${CC}%s${C0}\n" "${REALITY_PRIV:-[Auto-generated]}" >"$TTY"
    printf "  ${C2}3)${C0} Reality ShortId: ${CC}%s${C0}\n" "${REALITY_SID:-[Auto-generated]}" >"$TTY"
    printf "  ${C2}4)${C0} HY2 Password  : ${CC}%s${C0}\n" "${HY2_PASS:-[Auto-generated]}" >"$TTY"
    printf "  ${C2}5)${C0} WS Path       : ${CC}%s${C0}\n" "${WS_PATH:-[Auto-generated]}" >"$TTY"
    printf "  ${C2}6)${C0} XHTTP Path    : ${CC}%s${C0}\n" "${XHTTP_PATH:-[Auto-generated]}" >"$TTY"
    printf "\n  ${CR}0) Back${C0}\n\n" >"$TTY"
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) ask UUID "Enter Custom UUID" "${UUID:-}" ;;
      2) ask REALITY_PRIV "Enter Reality Private Key" "${REALITY_PRIV:-}" ;;
      3) ask REALITY_SID "Enter Reality ShortId (e.g. 16 chars hex)" "${REALITY_SID:-}" ;;
      4) ask HY2_PASS "Enter HY2 Password" "${HY2_PASS:-}" ;;
      5) ask WS_PATH "Enter WS Path (must start with /)" "${WS_PATH:-}" ;;
      6) ask XHTTP_PATH "Enter XHTTP Path (must start with /)" "${XHTTP_PATH:-}" ;;
      0) return ;;
    esac
  done
}

adv_tls(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║          TLS & Reality Tweaks            ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C2}1)${C0} Reality Primary SNI : ${CC}%s${C0}\n" "${SNI:-[Not Set]}" >"$TTY"
    printf "  ${C2}2)${C0} Reality Extra SNIs  : ${CC}%s${C0}\n" "${REALITY_SNIS:-[None]}" >"$TTY"
    printf "  ${C2}3)${C0} Nginx TLS Range     : ${CC}%s to %s${C0}\n" "${TLS_MIN:-1.2}" "${TLS_MAX:-1.3}" >"$TTY"
    printf "  ${C2}4)${C0} ALPN Override       : ${CC}%s${C0}\n" "${ALPN:-}" >"$TTY"
    printf "  ${C2}5)${C0} Mux (Clientside)    : ${CG}%s${C0}\n" "$($MUX && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}6)${C0} Fragment (Clients)  : ${CG}%s${C0}\n" "$($FRAGMENT && echo ON || echo OFF)" >"$TTY"
    printf "\n  ${CR}0) Back${C0}\n\n" >"$TTY"
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) ask_valid SNI "Primary SNI" "$RE_DOMAIN" "${SNI:-}" ;;
      2) ask REALITY_SNIS "Extra SNIs (comma-separated, e.g. www.yahoo.com,apple.com)" "${REALITY_SNIS:-}" ;;
      3) 
        ask_choice TLS_MIN "TLS Minimum (1.0/1.1/1.2/1.3)" "1.2" "1.0" "1.1" "1.2" "1.3"
        ask_choice TLS_MAX "TLS Maximum (1.0/1.1/1.2/1.3)" "1.3" "1.0" "1.1" "1.2" "1.3"
        ;;
      4) 
        printf "\n  ${C3}Select ALPN:${C0}\n" >"$TTY"
        printf "  1) h2,http/1.1\n  2) h3,h2,http/1.1\n  3) h3,h2\n  4) h3,http/1.1\n  5) h3\n  6) h2\n  7) http/1.1\n" >"$TTY"
        local a_opt=""
        ask_choice a_opt "Choice" "1" 1 2 3 4 5 6 7
        case "$a_opt" in
          1) ALPN="h2,http/1.1" ;;
          2) ALPN="h3,h2,http/1.1" ;;
          3) ALPN="h3,h2" ;;
          4) ALPN="h3,http/1.1" ;;
          5) ALPN="h3" ;;
          6) ALPN="h2" ;;
          7) ALPN="http/1.1" ;;
        esac
        ;;
      5) $MUX && MUX=false || MUX=true ;;
      6) $FRAGMENT && FRAGMENT=false || FRAGMENT=true ;;
      0) return ;;
    esac
  done
}

adv_routing(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║            Routing & Rules               ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C3}Note: Iranian domains/IPs are always blocked to prevent IP leak to GFW.${C0}\n" >"$TTY"
    printf "  ${C2}1)${C0} Block QUIC Outbound (Drops UDP/443 to force TCP) : ${CG}%s${C0}\n" "$($BLOCK_QUIC && echo ON || echo OFF)" >"$TTY"
    printf "  ${C2}2)${C0} IP Preference (auto / ipv4 / ipv6)               : ${CC}%s${C0}\n" "${IP_PREF:-auto}" >"$TTY"
    printf "\n  ${CR}0) Back${C0}\n\n" >"$TTY"
    local opt=""
    ask opt "Select an option" ""
    case "${opt:-}" in
      1) $BLOCK_QUIC && BLOCK_QUIC=false || BLOCK_QUIC=true ;;
      2) ask_choice IP_PREF "IP Preference" "auto" "auto" "ipv4" "ipv6" ;;
      0) return ;;
    esac
  done
}


# ── Base Functions from Original Script ────────────────────────
tune_kernel(){
  cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
EOF
  if modprobe tcp_bbr 2>/dev/null && \
     sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  fi
  sysctl --system >/dev/null 2>&1 || true
  ok "Kernel/UDP buffers tuned (QUIC-friendly)."
}

install_warp(){
  if command -v warp-cli >/dev/null 2>&1; then
    ok "WARP already installed."
  else
    case "$PKG" in
      apt)
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
          | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(source /etc/os-release 2>/dev/null || true; echo "${VERSION_CODENAME:-}") main" \
          > /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -y
        apt-get install -y cloudflare-warp || { warn "WARP install failed; disabling WARP."; WANT_WARP=false; return 0; }
        ;;
      dnf|yum)
        $PKG install -y cloudflare-warp 2>/dev/null || {
          warn "WARP package not available on this distro; disabling WARP."
          WANT_WARP=false; return 0
        }
        ;;
    esac
  fi
  warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
  
  local m_ok=false
  warp-cli --accept-tos mode proxy 2>/dev/null && m_ok=true
  if ! $m_ok; then warp-cli set-mode proxy 2>/dev/null && m_ok=true; fi
  if ! $m_ok; then warp-cli mode proxy 2>/dev/null && m_ok=true; fi
  
  if ! $m_ok; then
    warn "Failed to set WARP to Proxy mode! Disabling WARP to prevent server lockout."
    WANT_WARP=false
    return 0
  fi
  
  warp-cli --accept-tos proxy port "$WARP_PORT" 2>/dev/null || warp-cli set-proxy-port "$WARP_PORT" 2>/dev/null || true
  warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
  sleep 3
  if warp-cli status 2>/dev/null | grep -qi connected; then
    ok "WARP connected (SOCKS5 on 127.0.0.1:${WARP_PORT})."
  else
    warn "WARP not confirmed connected. Check: warp-cli status"
  fi
}

install_deps(){
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y curl openssl jq nginx certbot ufw ca-certificates gnupg vnstat
      ;;
    dnf|yum)
      $PKG install -y curl openssl jq nginx certbot ufw ca-certificates vnstat || true
      ;;
  esac

  if ! command -v xray >/dev/null 2>&1 || [ ! -f /etc/systemd/system/xray.service ]; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  if $WANT_HY2 && { ! command -v hysteria >/dev/null 2>&1 || [ ! -f /etc/systemd/system/hysteria-server.service ]; }; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi
  $WANT_WARP && install_warp
  $WANT_HY2  && tune_kernel
  systemctl enable vnstat 2>/dev/null || true
  systemctl start vnstat 2>/dev/null || true
  ok "Dependencies installed."
}

menu_mode(){
  printf "\n${C2}=== Select protocols ===${C0}\n" >"$TTY"
  printf "  1) All (WS + XHTTP + Reality + Hysteria2)\n" >"$TTY"
  printf "  2) CDN only (WS + XHTTP)\n" >"$TTY"
  printf "  3) Reality only\n" >"$TTY"
  printf "  4) Hysteria2 only\n" >"$TTY"
  printf "  5) Custom\n" >"$TTY"
  local MODE=""
  ask_choice MODE "Choice" "1" 1 2 3 4 5
  case "${MODE:-}" in
    1) WANT_WS=true; WANT_XHTTP=true; WANT_REALITY=true; WANT_HY2=true ;;
    2) WANT_WS=true; WANT_XHTTP=true ;;
    3) WANT_REALITY=true ;;
    4) WANT_HY2=true ;;
    5)
      local a=""
      ask_yesno a "Enable VLESS-WS?"    "y"; [ "${a:-}" = y ] && WANT_WS=true
      ask_yesno a "Enable VLESS-XHTTP?" "y"; [ "${a:-}" = y ] && WANT_XHTTP=true
      ask_yesno a "Enable Reality?"     "y"; [ "${a:-}" = y ] && WANT_REALITY=true
      ask_yesno a "Enable Hysteria2?"   "y"; [ "${a:-}" = y ] && WANT_HY2=true
      ;;
  esac
  if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; fi
  $WANT_WS || $WANT_XHTTP || $WANT_REALITY || $WANT_HY2 || die "Nothing selected."

  local w=""
  ask_yesno w "Enable WARP outbound for blocked sites (Google/OpenAI/Spotify/Netflix...)?" "y"
  [ "${w:-}" = y ] && WANT_WARP=true
}

menu_fingerprint(){
  printf "\n${C2}=== uTLS Fingerprint ===${C0}\n" >"$TTY"
  printf "  1) chrome      (recommended)\n" >"$TTY"
  printf "  2) firefox\n" >"$TTY"
  printf "  3) safari\n" >"$TTY"
  printf "  4) ios\n" >"$TTY"
  printf "  5) android\n" >"$TTY"
  printf "  6) edge\n" >"$TTY"
  printf "  7) random\n" >"$TTY"
  printf "  8) randomized\n" >"$TTY"
  local FP_NUM=""
  ask_choice FP_NUM "Choice" "1" 1 2 3 4 5 6 7 8
  case "${FP_NUM:-}" in
    1) FP="chrome"     ;;
    2) FP="firefox"    ;;
    3) FP="safari"     ;;
    4) FP="ios"        ;;
    5) FP="android"    ;;
    6) FP="edge"       ;;
    7) FP="random"     ;;
    8) FP="randomized" ;;
  esac
  ok "Fingerprint: ${FP}"
}

collect_nginx_ports(){
  NGINX_PORTS=()
  printf "\n${C2}Nginx port(s) — Cloudflare HTTPS only: ${CF_PORTS[*]}${C0}\n" >"$TTY"
  printf "  Enter one port at a time. Press Enter on empty line to finish.\n" >"$TTY"
  local p="" def="" dup=false x=""
  while true; do
    if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then def="2096"; else def=""; fi
    ask p "Nginx port (Enter to finish)" "$def"
    if [ -z "${p:-}" ]; then
      if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then warn "At least one port is required."; continue; fi
      break
    fi
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then warn "Not a number. Try again."; continue; fi
    if ! is_cf_port "$p"; then warn "$p is not a Cloudflare HTTPS port. Allowed: ${CF_PORTS[*]}"; continue; fi
    dup=false
    for x in "${NGINX_PORTS[@]:-}"; do [ "$x" = "$p" ] && dup=true && break; done
    if $dup; then warn "Port $p already added."; continue; fi
    NGINX_PORTS+=("$p")
    ok "Port $p added.  (current: ${NGINX_PORTS[*]})"
  done
  ok "Nginx will listen on: ${NGINX_PORTS[*]}"
}

collect_external_proxies(){
  EXT_COUNT=0
  printf "\n${C2}External (CDN clean) proxies — multiple addresses = redundancy in sub${C0}\n" >"$TTY"
  printf "  Paste lines in this EXACT format, one per line:\n" >"$TTY"
  printf '    PORT_IPS[2096]="104.19.184.210,104.27.53.171"\n' >"$TTY"
  printf "  Port MUST be one assigned to Nginx: ${NGINX_PORTS[*]:-}\n" >"$TTY"
  printf "  Finish with an empty line. Leave empty to skip.\n" >"$TTY"
  local line="" port="" ips="" found=false p=""
  while true; do
    printf "${C1}> ${C0}" >"$TTY"
    read -r line <"$TTY" || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "${line:-}" ] && break
    if [[ "$line" =~ $RE_EXT ]]; then
      port="${BASH_REMATCH[1]}"; ips="${BASH_REMATCH[2]}"
      found=false
      for p in "${NGINX_PORTS[@]:-}"; do [ "$port" = "$p" ] && found=true && break; done
      if ! $found; then warn "Port ${port} is NOT in Nginx list (${NGINX_PORTS[*]:-}). Ignored."; continue; fi
      PORT_IPS["$port"]="$ips"
      EXT_COUNT=$((EXT_COUNT+1))
      ok "Added: port ${port} -> ${ips}"
    else
      warn "Invalid format, ignored: ${line}"
    fi
  done
}

collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  HY2_PORT=36712
  REALITY_PORT=8443

  printf "\n${C2}=== Ports ===${C0}\n" >"$TTY"
  printf "  1) Use defaults (Nginx 2096, Hysteria2 36712, Reality 8443)\n" >"$TTY"
  printf "  2) Customize ports\n" >"$TTY"
  local PORT_MODE=""
  ask_choice PORT_MODE "Choice" "1" 1 2

  if [ "${PORT_MODE:-}" = "2" ]; then
    $USE_DOMAIN   && collect_nginx_ports
    $WANT_HY2     && ask_port HY2_PORT "Hysteria2 port (UDP)" "36712"
    $WANT_REALITY && ask_port REALITY_PORT "Reality port (direct TCP)" "8443"
  else
    $USE_DOMAIN && NGINX_PORTS=(2096)
  fi

  if $USE_DOMAIN; then
    ask_valid DOMAIN "Domain for WS/XHTTP (Cloudflare orange-cloud)" "$RE_DOMAIN" "${DOMAIN:-}"
  fi

  if $WANT_HY2; then
    printf "\n${C2}Hysteria2 certificate:${C0} 1) self-signed  2) Let's Encrypt\n" >"$TTY"
    local HY2_CERT_CH=""
    ask_choice HY2_CERT_CH "Choice" "1" 1 2
    if [ "${HY2_CERT_CH:-}" = "2" ]; then
      HY2_CERT="le"
      ask_valid HY2_DOMAIN "Hysteria2 subdomain (grey-cloud / DNS only)" "$RE_DOMAIN" "${HY2_DOMAIN:-}"
      ask_valid LE_EMAIL   "Email for Let's Encrypt" "$RE_EMAIL" "${LE_EMAIL:-}"
    else
      HY2_CERT="self"
    fi
  fi

  menu_fingerprint

  if $WANT_REALITY; then
    ask_valid SNI "SNI/destination for Reality (a real website)" "$RE_DOMAIN" "www.microsoft.com"
  fi

  if $WANT_WS || $WANT_XHTTP; then
    while true; do
      collect_external_proxies
      if [ "${EXT_COUNT:-0}" -gt 0 ]; then break; fi
      local SURE=""
      ask_yesno SURE "No proxies entered. Connect directly to ${DOMAIN} on port ${NGINX_PORTS[0]}?" "y"
      if [ "${SURE:-}" = "y" ]; then
        PORT_IPS["${NGINX_PORTS[0]}"]="$DOMAIN"
        EXT_COUNT=1
        warn "Using domain ${DOMAIN} directly on port ${NGINX_PORTS[0]}."
        break
      fi
      warn "Let's try entering proxies again."
    done
  fi

  ask CONFIG_NAME "A name for your configs" "MyVPN"

  if $USE_DOMAIN; then
    ask SUB_PATH_IN "Subscription path (Enter for random)" ""
    if [ -n "${SUB_PATH_IN:-}" ]; then
      if [[ "$SUB_PATH_IN" =~ $RE_SUBPATH ]]; then
        SUB_TOKEN="$SUB_PATH_IN"; ok "Subscription path set to: ${SUB_TOKEN}"
      else
        warn "Invalid path (no slash). Using random."
        SUB_TOKEN="$(openssl rand -hex 16)"
      fi
    else
        SUB_TOKEN="$(openssl rand -hex 16)"
    fi
  fi
}

gen_secrets(){
  if [ -z "${UUID:-}" ]; then UUID="$(xray uuid)"; fi
  if [ -z "${WS_PATH:-}" ]; then WS_PATH="/$(openssl rand -hex 4)-ws"; fi
  if [ -z "${XHTTP_PATH:-}" ]; then XHTTP_PATH="/$(openssl rand -hex 4)-xh"; fi
  if [ -z "${SUB_TOKEN:-}" ]; then SUB_TOKEN="$(openssl rand -hex 16)"; fi
  if [ -z "${HY2_PASS:-}" ]; then HY2_PASS="$(openssl rand -hex 12)"; fi

  if $WANT_REALITY; then
    if [ -z "${REALITY_PRIV:-}" ] || [ -z "${REALITY_PUB:-}" ]; then
      local keys
      keys="$(xray x25519)"
      REALITY_PRIV="$(echo "$keys" | grep -i 'private' | awk '{print $NF}')"
      REALITY_PUB="$(echo "$keys"  | grep -i 'public'  | awk '{print $NF}')"
    fi
    if [ -z "${REALITY_SID:-}" ]; then REALITY_SID="$(openssl rand -hex 8)"; fi
  fi
  ok "Secrets generated/loaded."
}

write_xray(){
  local inbounds=() joined
  mkdir -p /usr/local/etc/xray

  local SNIFF='"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}'

  if $WANT_WS; then
    inbounds+=("$(cat <<EOF
{
  "listen":"127.0.0.1","port":${WS_INT},"protocol":"vless","tag":"in-ws",
  "settings":{"clients":[{"id":"${UUID}"}],"decryption":"none"},
  "streamSettings":{"network":"ws","wsSettings":{"path":"${WS_PATH}"}},
  ${SNIFF}
}
EOF
)")
  fi

  if $WANT_XHTTP; then
    inbounds+=("$(cat <<EOF
{
  "listen":"127.0.0.1","port":${XHTTP_INT},"protocol":"vless","tag":"in-xh",
  "settings":{"clients":[{"id":"${UUID}"}],"decryption":"none"},
  "streamSettings":{"network":"xhttp","xhttpSettings":{"path":"${XHTTP_PATH}","mode":"auto"}},
  ${SNIFF}
}
EOF
)")
  fi

  if $WANT_REALITY; then
    local snis_json="\"${SNI}\""
    if [ -n "${REALITY_SNIS:-}" ]; then
      local IFS=','
      for s in ${REALITY_SNIS}; do
        s="$(echo "$s" | tr -d ' ')"
        [ -n "$s" ] && snis_json+=",\"$s\""
      done
    fi

    inbounds+=("$(cat <<EOF
{
  "listen":"0.0.0.0","port":${REALITY_PORT},"protocol":"vless","tag":"in-reality",
  "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{"network":"tcp","security":"reality",
    "realitySettings":{"show":false,"dest":"${SNI}:443","xver":0,
      "serverNames":[${snis_json}],"privateKey":"${REALITY_PRIV}","shortIds":["${REALITY_SID}"]}},
  ${SNIFF}
}
EOF
)")
  fi

  joined="$(IFS=,; echo "${inbounds[*]}")"

  # ---------- outbounds ----------
  local OUTBOUNDS WARP_RULE="" BLOCK_QUIC_RULE=""
  
  local ip_strat="AsIs"
  if [ "${IP_PREF:-}" = "ipv4" ]; then ip_strat="UseIPv4"; fi
  if [ "${IP_PREF:-}" = "ipv6" ]; then ip_strat="UseIPv6"; fi

  if $WANT_WARP; then
    OUTBOUNDS='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"'"${ip_strat}"'"}},{"protocol":"blackhole","tag":"block"},{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":'"${WARP_PORT}"'}]}}]'
    WARP_RULE='{"type":"field","outboundTag":"warp","domain":["geosite:google","geosite:openai","geosite:netflix","geosite:spotify","domain:claude.ai","domain:anthropic.com","domain:chatgpt.com"]},'
  else
    OUTBOUNDS='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"'"${ip_strat}"'"}},{"protocol":"blackhole","tag":"block"}]'
  fi

  if $BLOCK_QUIC; then
    BLOCK_QUIC_RULE='{"type":"field","network":"udp","port":443,"outboundTag":"block"},'
  fi

  # ---------- routing: block torrent + block private + block داخلی ----------
  local ROUTING
  ROUTING=$(cat <<EOF
{
  "domainStrategy":"IPIfNonMatch",
  "rules":[
    ${WARP_RULE}
    ${BLOCK_QUIC_RULE}
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","outboundTag":"block","ip":["geoip:private"]},
    {"type":"field","outboundTag":"block","domain":["geosite:category-ir"]},
    {"type":"field","outboundTag":"block","ip":["geoip:ir"]}
  ]
}
EOF
)

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[ ${joined} ],
  "outbounds":${OUTBOUNDS},
  "routing":${ROUTING}
}
EOF

  xray -test -config /usr/local/etc/xray/config.json >"$TTY" 2>&1 || die "Xray config test failed."
  ok "Xray config written."
}

write_nginx(){
  $USE_DOMAIN || return 0
  mkdir -p /etc/ssl/xray /var/www/html /var/www/sub

  if [ ! -f /etc/ssl/xray/cert.pem ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/ssl/xray/key.pem -out /etc/ssl/xray/cert.pem \
      -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  fi

  echo "<html><body><h1>It works.</h1></body></html>" > /var/www/html/index.html
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  local listens="" p=""
  for p in "${NGINX_PORTS[@]:-}"; do
    listens+="    listen ${p} ssl http2;"$'\n'
    listens+="    listen [::]:${p} ssl http2;"$'\n'
  done

  local ws_block="" xh_block=""
  if $WANT_WS; then
    ws_block=$(cat <<EOF
    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_INT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
)
  fi
  if $WANT_XHTTP; then
    xh_block=$(cat <<EOF
    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_INT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 0;
    }
EOF
)
  fi

  local protos=()
  local all_p=("1.0" "1.1" "1.2" "1.3")
  local in_range=false p_ver
  for p_ver in "${all_p[@]}"; do
    if [ "$p_ver" = "${TLS_MIN:-1.2}" ]; then in_range=true; fi
    if $in_range; then
      [ "$p_ver" = "1.0" ] && protos+=("TLSv1")
      [ "$p_ver" = "1.1" ] && protos+=("TLSv1.1")
      [ "$p_ver" = "1.2" ] && protos+=("TLSv1.2")
      [ "$p_ver" = "1.3" ] && protos+=("TLSv1.3")
    fi
    if [ "$p_ver" = "${TLS_MAX:-1.3}" ]; then break; fi
  done
  [ ${#protos[@]} -eq 0 ] && protos=("TLSv1.2" "TLSv1.3")
  local tls_str="${protos[*]}"

  cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
${listens}    server_name ${DOMAIN};

    ssl_certificate     /etc/ssl/xray/cert.pem;
    ssl_certificate_key /etc/ssl/xray/key.pem;
    ssl_protocols ${tls_str};

${ws_block}
${xh_block}

    location = /sub/${SUB_TOKEN} {
        if (\$http_user_agent ~* "mozilla|chrome|safari|edge|applewebkit") {
            rewrite ^ /sub/${SUB_TOKEN}_html last;
        }
        default_type text/plain;
        alias /var/www/sub/${SUB_TOKEN}.txt;
    }

    location = /sub/${SUB_TOKEN}_html {
        default_type text/html;
        alias /var/www/sub/${SUB_TOKEN}.html;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

  nginx -t >"$TTY" 2>&1 || die "Nginx config test failed."
  ok "Nginx config written."
}

write_hysteria(){
  $WANT_HY2 || return 0
  mkdir -p /etc/hysteria

  local cert_path="" key_path=""
  if [ "${HY2_CERT:-}" = "le" ]; then
    systemctl stop nginx 2>/dev/null || true
    if certbot certonly --standalone -d "$HY2_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL"; then
      cert_path="/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
      key_path="/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
    else
      warn "Let's Encrypt failed! (Port 80 blocked or domain not resolving). Falling back to Self-Signed."
      HY2_CERT="self"
    fi
  fi
  
  if [ "${HY2_CERT:-}" = "self" ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
      -days 3650 -subj "/CN=${HY2_SNI}" >/dev/null 2>&1
    cert_path="/etc/hysteria/cert.pem"
    key_path="/etc/hysteria/key.pem"
  fi

  # بخش WARP برای HY2 (اختیاری) از طریق ACL + outbound socks5
  local warp_block=""
  if $WANT_WARP; then
    warp_block=$(cat <<EOF

outbounds:
  - name: direct
    type: direct
  - name: warp
    type: socks5
    socks5:
      addr: 127.0.0.1:${WARP_PORT}

acl:
  inline:
    - warp(suffix:google.com)
    - warp(suffix:googlevideo.com)
    - warp(suffix:gstatic.com)
    - warp(suffix:openai.com)
    - warp(suffix:chatgpt.com)
    - warp(suffix:claude.ai)
    - warp(suffix:anthropic.com)
    - warp(suffix:spotify.com)
    - warp(suffix:netflix.com)
    - direct(all)
EOF
)
  fi

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${cert_path}
  key: ${key_path}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

auth:
  type: password
  password: ${HY2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true
  listenHTTP: ""
  listenHTTPS: ""
${warp_block}
EOF

  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOF
[Service]
User=root
Group=root
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
EOF
  systemctl daemon-reload

  hysteria server -c /etc/hysteria/config.yaml --disable-update-check check >"$TTY" 2>&1 \
    || warn "Hysteria2 config check reported issues (continuing)."
  ok "Hysteria2 config written (QUIC tuned$([ "$WANT_WARP" = true ] && echo ' + WARP'))."
}

gen_links(){
  local port="" ip=""
  LINKS=()
  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  
  local xtra=""
  $MUX && xtra+="&mux=concurrency:8"
  $FRAGMENT && xtra+="&fragment=10-20,10-20,tlshello"
  
  local ws_idx=1 xh_idx=1
  if $WANT_WS || $WANT_XHTTP; then
    for port in "${!PORT_IPS[@]}"; do
      IFS=',' read -ra _ips <<< "${PORT_IPS[$port]}"
      for ip in "${_ips[@]:-}"; do
        [ -z "${ip:-}" ] && continue
        if $WANT_WS; then
            LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=${FP}&type=ws&host=${DOMAIN}&path=${WS_PATH}&alpn=${ALPN}${xtra}#${CONFIG_NAME}-WS-$(printf "%02d" $ws_idx)")
            ws_idx=$((ws_idx+1))
        fi
        if $WANT_XHTTP; then
            LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=${FP}&type=xhttp&host=${DOMAIN}&path=${XHTTP_PATH}&mode=auto&alpn=${ALPN}${xtra}#${CONFIG_NAME}-XHTTP-$(printf "%02d" $xh_idx)")
            xh_idx=$((xh_idx+1))
        fi
      done
    done
  fi

  $WANT_REALITY && LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision&type=tcp${xtra}#${CONFIG_NAME}-Reality")

  if $WANT_HY2; then
    local h_host="" h_sni="" h_ins=""
    if [ "${HY2_CERT:-}" = "le" ]; then
      h_host="$HY2_DOMAIN"; h_sni="$HY2_DOMAIN"; h_ins=0
    else
      h_host="$SERVER_IP"; h_sni="$HY2_SNI"; h_ins=1
    fi
    LINKS+=("hysteria2://${HY2_PASS}@${h_host}:${HY2_PORT}/?sni=${h_sni}&insecure=${h_ins}#${CONFIG_NAME}-HY2")
  fi
}

gen_subscription(){
  $USE_DOMAIN || return 0
  mkdir -p /var/www/sub /etc/vpn-installer
  printf '%s\n' "${LINKS[@]:-}" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt" 2>/dev/null || printf '%s\n' "${LINKS[@]:-}" | base64 | tr -d '\n' > "/var/www/sub/${SUB_TOKEN}.txt"
  SUB_URL="https://${DOMAIN}:${NGINX_PORTS[0]}/sub/${SUB_TOKEN}"

  local html_configs=""
  local l=""
  for l in "${LINKS[@]:-}"; do
    html_configs+="<div class='cfg-item'>${l}</div>"
  done

  cat > "/var/www/sub/${SUB_TOKEN}.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VPN Dashboard - ${CONFIG_NAME}</title>
<style>
  :root { --p: #8a2be2; --r: #e50914; --bg: #09000a; }
  body { margin:0; font-family:'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, var(--bg) 0%, #170014 50%, #1a0005 100%); color: #fff; min-height: 100vh; display: flex; justify-content: center; align-items: center; padding: 20px;}
  .glass { background: rgba(255,255,255,0.03); backdrop-filter: blur(15px); border: 1px solid rgba(255,255,255,0.05); border-radius: 20px; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); }
  .container { width: 100%; max-width: 650px; padding: 30px; }
  h1 { text-align: center; background: -webkit-linear-gradient(45deg, var(--p), var(--r)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 30px; font-size: 2.2em; }
  .stat-box { display: flex; justify-content: space-between; padding: 20px; border-radius: 15px; margin-bottom: 30px; background: rgba(0,0,0,0.4); border-left: 4px solid var(--p); }
  .stat { display: flex; flex-direction: column; text-align: center; width: 30%; }
  .stat span { font-size: 0.8rem; color: #aaa; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 5px; }
  .stat strong { font-size: 1.1rem; font-weight: 600; color: #e0e0e0; }
  .btn { display: block; width: 100%; padding: 16px; border-radius: 12px; border: none; font-size: 1.1rem; font-weight: bold; cursor: pointer; text-align: center; text-decoration: none; margin-bottom: 15px; transition: all 0.3s ease; box-sizing: border-box; }
  .btn-hiddify { background: linear-gradient(45deg, #1e90ff, #8a2be2); color: white; box-shadow: 0 4px 15px rgba(138, 43, 226, 0.4); }
  .btn-v2ray { background: linear-gradient(45deg, #ff4500, #e50914); color: white; box-shadow: 0 4px 15px rgba(229, 9, 20, 0.4); }
  .btn:hover { opacity: 0.9; transform: translateY(-3px); box-shadow: 0 6px 20px rgba(255,255,255,0.1); }
  .cfg-list { margin-top: 30px; max-height: 400px; overflow-y: auto; padding-right: 10px; }
  .cfg-list::-webkit-scrollbar { width: 6px; }
  .cfg-list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.2); border-radius: 3px; }
  .cfg-item { background: rgba(255,255,255,0.03); padding: 15px; border-radius: 10px; margin-bottom: 12px; font-family: monospace; word-break: break-all; font-size: 0.85rem; border-left: 3px solid var(--r); color: #ccc; }
  .footer { text-align: center; margin-top: 30px; font-size: 0.85rem; color: #666; }
</style>
</head>
<body>
<div class="glass container">
  <h1>${CONFIG_NAME} Panel</h1>
  
  <div class="stat-box">
    <div class="stat"><span>Traffic TX</span><strong>0 MB</strong></div>
    <div class="stat"><span>Traffic RX</span><strong>0 MB</strong></div>
    <div class="stat"><span>Total Usage</span><strong>0 MB</strong></div>
  </div>
  
  <h3>Quick Import</h3>
  <a href="hiddify://install-sub?url=${SUB_URL}&name=${CONFIG_NAME}" class="btn btn-hiddify">🚀 Import to Hiddify</a>
  <button onclick="navigator.clipboard.writeText('${SUB_URL}'); alert('Subscription Link Copied!');" class="btn btn-v2ray">📋 Copy Subscription Link</button>
  
  <h3>Nodes (${#LINKS[@]})</h3>
  <div class="cfg-list">
    ${html_configs}
  </div>
  
  <div class="footer">Created by MOJA | Generated: $(date "+%Y-%m-%d %H:%M")</div>
</div>
</body>
</html>
EOF

  cat > /etc/vpn-installer/update_html.sh <<'CRONEOF'
#!/usr/bin/env bash
source /etc/vpn-installer/state.env
[ -z "$DOMAIN" ] && exit 0
rx="0 MB"; tx="0 MB"; total="0 MB"
if command -v vnstat >/dev/null 2>&1; then
  vout=$(vnstat --oneline 2>/dev/null || true)
  if [ -n "$vout" ]; then
      rx=$(echo "$vout" | cut -d';' -f4); tx=$(echo "$vout" | cut -d';' -f5); total=$(echo "$vout" | cut -d';' -f6)
  fi
fi
sed -i -E "s|<span>Traffic TX</span><strong>.*</strong>|<span>Traffic TX</span><strong>$tx</strong>|" /var/www/sub/${SUB_TOKEN}.html
sed -i -E "s|<span>Traffic RX</span><strong>.*</strong>|<span>Traffic RX</span><strong>$rx</strong>|" /var/www/sub/${SUB_TOKEN}.html
sed -i -E "s|<span>Total Usage</span><strong>.*</strong>|<span>Total Usage</span><strong>$total</strong>|" /var/www/sub/${SUB_TOKEN}.html
sed -i -E "s|Generated: .*<|Generated: $(date "+%Y-%m-%d %H:%M")<|" /var/www/sub/${SUB_TOKEN}.html
CRONEOF
  chmod +x /etc/vpn-installer/update_html.sh
  /etc/vpn-installer/update_html.sh
  (crontab -l 2>/dev/null | grep -v "/etc/vpn-installer/update_html.sh"; echo "*/10 * * * * /etc/vpn-installer/update_html.sh") | crontab -

  ok "Subscription file & Dashboard UI created."
}

open_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  if $USE_DOMAIN; then
    local p=""; for p in "${NGINX_PORTS[@]:-}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
  fi
  $WANT_REALITY && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  $WANT_HY2     && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1 || true
  [ "${HY2_CERT:-}" = "le" ] && ufw allow 80/tcp   >/dev/null 2>&1 || true
}

start_services(){
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  if $USE_DOMAIN; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
  fi
  if $WANT_HY2; then
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
      if command -v ss >/dev/null 2>&1 && ss -lun 2>/dev/null | grep -q ":${HY2_PORT} "; then
        ok "Hysteria2 is listening on UDP/${HY2_PORT}."
      else
        warn "Hysteria2 active but UDP/${HY2_PORT} not seen in ss. Check provider firewall."
      fi
    else
      warn "Hysteria2 not active. Check: journalctl -u hysteria-server -n 40 --no-pager"
    fi
  fi
  ok "Services started."
}

print_summary(){
  clear_screen
  printf "\n${C2}================ DONE ================${C0}\n" >"$TTY"
  local l=""
  for l in "${LINKS[@]:-}"; do printf "%s\n\n" "$l" >"$TTY"; done
  if $USE_DOMAIN; then
    printf "${CG}Nginx ports:${C0} %s\n" "${NGINX_PORTS[*]:-}" >"$TTY"
    printf "${CG}Subscription URL:${C0}\n%s\n" "${SUB_URL:-}" >"$TTY"
    printf "${C2}Note:${C0} Cloudflare SSL 'Full', orange-cloud, port in 443/2053/2083/2087/2096/8443.\n" >"$TTY"
  fi
  if $WANT_HY2; then
    printf "${C2}HY2 tip:${C0} '-1 ping' is often just the client's TCP/ICMP test;\n" >"$TTY"
    printf "         use 'Real Delay / Test URL'. If it truly fails, open UDP/${HY2_PORT}\n" >"$TTY"
  fi
  $WANT_WARP && printf "${CG}WARP:${C0} active for Google/OpenAI/Netflix/Spotify/Claude.\n" >"$TTY"
  printf "\n${CR}>>> CRITICAL <<<${C0}\n" >"$TTY"
  printf "Ensure the following ports are OPEN in your Cloud Provider's Panel (AWS, DigitalOcean, etc.):\n" >"$TTY"
  $USE_DOMAIN && printf " - Nginx: ${NGINX_PORTS[*]:-} (TCP)\n" >"$TTY"
  $WANT_REALITY && printf " - Reality: ${REALITY_PORT} (TCP)\n" >"$TTY"
  $WANT_HY2 && printf " - Hysteria2: ${HY2_PORT} (UDP)\n" >"$TTY"
  printf "${C2}=====================================${C0}\n" >"$TTY"
}

execute_build(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║           Building Configurations        ║"
  banner "  ╚══════════════════════════════════════════╝"
  install_deps
  gen_secrets
  write_xray
  write_nginx
  write_hysteria
  gen_links
  gen_subscription
  open_firewall
  start_services
  save_state
  print_summary
  press_enter
}

modify_config_menu(){
  if ! load_state; then
    warn "No existing configuration found to modify."
    press_enter
    return
  fi
  mode_advanced
}

rebuild_config(){
  if ! load_state; then
    warn "No state found to rebuild."
    press_enter
    return
  fi
  execute_build
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
  
  local i=1 b=""
  for b in "${backups[@]:-}"; do
    printf "  ${C2}%d)${C0} %s\n" "$i" "$(basename "$b")" >"$TTY"
    i=$((i+1))
  done
  printf "  ${CR}0)${C0} Cancel\n\n" >"$TTY"
  
  local sel=""
  ask sel "Select backup to restore" "0"
  if [ "${sel:-0}" -eq 0 ]; then return; fi
  if [ "$sel" -ge 1 ] && [ "$sel" -le "${#backups[@]}" ]; then
    local chosen="${backups[$((sel-1))]}"
    info "Restoring from $chosen ..."
    killall -9 xray hysteria hysteria-server 2>/dev/null || true
    systemctl stop xray hysteria-server nginx 2>/dev/null || true
    
    cp -a "$chosen/config.json" /usr/local/etc/xray/ 2>/dev/null || true
    cp -a "$chosen/nginx-conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
    cp -a "$chosen/config.yaml" /etc/hysteria/ 2>/dev/null || true
    cp -a "$chosen/sub/"* /var/www/sub/ 2>/dev/null || true
    cp -a "$chosen/state.env" "$STATE_FILE" 2>/dev/null || true
    
    systemctl restart xray hysteria-server nginx 2>/dev/null || true
    ok "Restore complete."
    press_enter
  else
    warn "Invalid selection."
    press_enter
  fi
}

show_status(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║              System Status               ║"
  banner "  ╚══════════════════════════════════════════╝"
  
  printf "\n${C2}  --- Network Usage ---${C0}\n" >"$TTY"
  if command -v vnstat >/dev/null 2>&1; then
    vnstat || echo "vnstat data not yet available."
  else
    echo "vnstat not installed."
  fi
  
  printf "\n${C2}  --- Service Uptime ---${C0}\n" >"$TTY"
  systemctl status xray | grep Active || true
  systemctl status hysteria-server | grep Active || true
  systemctl status nginx | grep Active || true
  
  press_enter
}

full_removal(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║          Complete Removal                ║"
  banner "  ╚══════════════════════════════════════════╝"
  warn "This will remove Xray, Hysteria, WARP, configs, logs, and backups!"
  local ans=""
  ask_yesno ans "Are you absolutely sure?" "n"
  if [ "${ans:-}" = "y" ]; then
    info "Stopping services..."
    killall -9 xray hysteria hysteria-server 2>/dev/null || true
    systemctl stop xray hysteria-server hysteria warp-svc nginx 2>/dev/null || true
    systemctl disable xray hysteria-server hysteria warp-svc nginx 2>/dev/null || true
    
    info "Deleting files..."
    killall -9 xray hysteria hysteria-server 2>/dev/null || true
    rm -rf /usr/local/etc/xray /etc/hysteria /etc/vpn-installer /var/www/sub /etc/ssl/xray
    rm -f /etc/nginx/conf.d/xray.conf
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria*
    rm -f /usr/local/bin/xray /usr/local/bin/hysteria
    rm -rf /root/vpn-backup-*
    
    if command -v warp-cli >/dev/null 2>&1; then
      warp-cli disconnect 2>/dev/null || true
      warp-cli registration delete 2>/dev/null || true
    fi
    
    systemctl daemon-reload
    (crontab -l 2>/dev/null | grep -v "/etc/vpn-installer/update_html.sh") | crontab -
    ok "Complete removal finished."
    exit 0
  fi
}

migration_menu(){
  while true; do
    clear_screen
    banner "  ╔══════════════════════════════════════════╗"
    banner "  ║          Export/Import Migration         ║"
    banner "  ╚══════════════════════════════════════════╝"
    printf "  ${C2}1)${C0} Export Current Configuration\n" >"$TTY"
    printf "  ${C2}2)${C0} Import Configuration\n" >"$TTY"
    printf "  ${CR}0)${C0} Back\n\n" >"$TTY"
    
    local opt=""
    ask opt "Please select an option" ""
    case "${opt:-}" in
      1) export_config ;;
      2) import_config ;;
      0) return ;;
    esac
  done
}

export_config(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║            Export Configuration          ║"
  banner "  ╚══════════════════════════════════════════╝"
  if ! load_state; then warn "No config found to export."; press_enter; return; fi
  
  local txt="DOMAIN=\"$DOMAIN\"
NGINX_PORTS=\"${NGINX_PORTS[*]:-}\"
REALITY_PORT=\"$REALITY_PORT\"
HY2_PORT=\"$HY2_PORT\"
SUB_TOKEN=\"$SUB_TOKEN\"
UUID=\"$UUID\"
REALITY_PRIV=\"$REALITY_PRIV\"
REALITY_PUB=\"$REALITY_PUB\"
REALITY_SID=\"$REALITY_SID\"
HY2_PASS=\"$HY2_PASS\"
WS_PATH=\"$WS_PATH\"
XHTTP_PATH=\"$XHTTP_PATH\"
SNI=\"$SNI\"
REALITY_SNIS=\"$REALITY_SNIS\"
CONFIG_NAME=\"$CONFIG_NAME\"
TLS_MIN=\"$TLS_MIN\"
TLS_MAX=\"$TLS_MAX\"
ALPN=\"$ALPN\"
BLOCK_QUIC=$BLOCK_QUIC
IP_PREF=\"$IP_PREF\"
MUX=$MUX
FRAGMENT=$FRAGMENT
WANT_WS=$WANT_WS
WANT_XHTTP=$WANT_XHTTP
WANT_REALITY=$WANT_REALITY
WANT_HY2=$WANT_HY2
WANT_WARP=$WANT_WARP"

  local p
  for p in "${NGINX_PORTS[@]:-}"; do
     txt+=$'\n'"PORT_IPS_${p}=\"${PORT_IPS[$p]:-}\""
  done

  local b64
  b64=$(printf "%s" "$txt" | base64 -w0)
  printf "\n${C2}Copy the following string completely:${C0}\n\n" >"$TTY"
  printf "${CC}MOJA://%s${C0}\n\n" "$b64" >"$TTY"
  press_enter
}

import_config(){
  clear_screen
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║            Import Configuration          ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "  ${C3}Paste your MOJA:// string below:${C0}\n" >"$TTY"
  local str=""
  ask str "> " ""
  if [[ "$str" != MOJA://* ]]; then
    warn "Invalid format! Must start with MOJA://"
    press_enter
    return
  fi
  local b64="${str#MOJA://}"
  local txt
  txt=$(printf "%s" "$b64" | base64 -d 2>/dev/null || true)
  if ! echo "$txt" | grep -q "DOMAIN"; then
    warn "Corrupted or invalid config string."
    press_enter
    return
  fi
  
  eval "$txt"
  if [ -n "$DOMAIN" ]; then USE_DOMAIN=true; else USE_DOMAIN=false; fi
  
  local p varname
  if [ -n "${NGINX_PORTS:-}" ]; then
    NGINX_PORTS=($NGINX_PORTS)
    for p in "${NGINX_PORTS[@]}"; do
      varname="PORT_IPS_${p}"
      PORT_IPS[$p]="${!varname:-}"
    done
  fi

  save_state
  ok "Configuration Imported successfully!"
  printf "Do you want to rebuild the server now with these settings? (y/n)\n" >"$TTY"
  local ans=""
  ask ans ">" "y"
  if [ "$ans" = "y" ]; then
    execute_build
  fi
}

main_menu(){
  while true; do
    welcome_screen
    printf "  ${C2}1)${C0} New Installation\n" >"$TTY"
    printf "  ${C2}2)${C0} Modify Current Configuration\n" >"$TTY"
    printf "  ${C2}3)${C0} Rebuild Configurations\n" >"$TTY"
    printf "  ${C2}4)${C0} Restore Backup\n" >"$TTY"
    printf "  ${C2}5)${C0} Status (Data & Uptime)\n" >"$TTY"
    printf "  ${C2}6)${C0} Export/Import Migration\n" >"$TTY"
    printf "  ${C2}7)${C0} Complete Removal\n" >"$TTY"
    printf "  ${CR}8)${C0} Exit\n\n" >"$TTY"
    
    local opt=""
    ask opt "Please select an option" ""
    case "${opt:-}" in
      1) new_install_menu ;;
      2) modify_config_menu ;;
      3) rebuild_config ;;
      4) restore_menu ;;
      5) show_status ;;
      6) migration_menu ;;
      7) full_removal ;;
      8) clear_screen; ok "Goodbye!"; exit 0 ;;
      *) warn "Invalid option"; press_enter ;;
    esac
  done
}

main(){
  if [ "${1:-}" = "--headless" ]; then
    export HEADLESS=true
    load_state || true
    execute_build
    exit 0
  fi
  main_menu
}

main "$@"
