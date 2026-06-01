#!/usr/bin/env bash
# =====================================================================
#  اسکریپت مدیریت و نصب VPN چند پروتکلی (نسخه منویی)
#  پروتکل‌ها: VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
#  امکانات: Fragment / Mux / WARP / Subscription / Backup-Restore
# =====================================================================

set -euo pipefail

# ----------------------------- رنگ‌ها -----------------------------
C0=$'\033[0m'
C1=$'\033[38;5;39m'     # prompt
C2=$'\033[38;5;220m'    # title
C3=$'\033[38;5;245m'    # info
CG=$'\033[38;5;82m'     # ok
CR=$'\033[38;5;196m'    # error
CW=$'\033[38;5;208m'    # warn
CB=$'\033[1m'
TTY=/dev/tty

# ----------------------------- لاگ -----------------------------
ok()    { printf "${CG}✔${C0} %s\n" "$*" >"$TTY"; }
warn()  { printf "${CW}⚠${C0} %s\n" "$*" >"$TTY"; }
die()   { printf "${CR}✖${C0} %s\n" "$*" >"$TTY"; exit 1; }
info()  { printf "${C3}•${C0} %s\n" "$*" >"$TTY"; }
title() { printf "\n${CB}${C2}%s${C0}\n" "$*" >"$TTY"; }
cls()   { clear >/dev/null 2>&1 || printf "\033c" >"$TTY"; }
pause(){ printf "\n${C3}Press Enter to continue...${C0}" >"$TTY"; read -r _ <"$TTY" || true; }

# ----------------------------- پیش‌نیاز -----------------------------
[ "$(id -u)" = "0" ] || die "Please run as root."

PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found (apt/dnf/yum)."

# ----------------------------- ثابت‌ها -----------------------------
MAX_TRIES=3
CF_PORTS=(443 2053 2083 2087 2096 8443)
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"
WARP_PORT=40000

RE_DOMAIN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
RE_EMAIL='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
RE_SUBPATH='^[A-Za-z0-9._-]+$'

STATE_DIR="/etc/vpn-manager"
STATE_FILE="${STATE_DIR}/state.sh"
BACKUP_DIR="${STATE_DIR}/backups"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# ----------------------------- وضعیت پیش‌فرض -----------------------------
WANT_WS=true
WANT_XHTTP=true
WANT_REALITY=false
WANT_HY2=false
WANT_WARP=false
WANT_FRAGMENT=true
WANT_MUX=true
USE_DOMAIN=true

CONFIG_NAME="MyVPN"
DOMAIN=""
SUB_PATH="sub"
SUB_TOKEN=""
SERVER_IP=""
FP="chrome"

REALITY_PORT=8443
SNI="www.cloudflare.com"

HY2_PORT=36712
HY2_CERT="self"
HY2_DOMAIN=""
LE_EMAIL=""
HY2_PASS=""
HY2_PEER="$HY2_SNI"
HY2_INSECURE=1

UUID=""
WS_PATH=""
XHTTP_PATH=""
REALITY_PRIV=""
REALITY_PUB=""
REALITY_SID=""

NGINX_PORTS=(2096)
declare -A PORT_IPS
LINKS=()

LAST_BUILD_AT=""
INSTALLER_NAME="VPN Multi-Protocol Manager"
AUTHOR_NAME="YourName"

# ----------------------------- توابع ورودی -----------------------------
ask(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans=""
  if [ -n "$__default" ]; then
    printf "${C1}❯${C0} %s ${C3}[%s]${C0}: " "$__prompt" "$__default" >"$TTY"
  else
    printf "${C1}❯${C0} %s: " "$__prompt" >"$TTY"
  fi
  read -r __ans <"$TTY" || true
  [ -z "$__ans" ] && __ans="$__default"
  printf -v "$__var" '%s' "$__ans"
}

ask_yesno(){
  local __var="$1" __prompt="$2" __default="${3:-y}" __ans="" __try=0
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
  local __valid=("$@") __ans="" __try=0 v
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
    warn "Invalid format."
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

is_true(){ [ "${1:-false}" = "true" ]; }

is_cf_port(){
  local p="$1" e
  for e in "${CF_PORTS[@]}"; do [ "$p" = "$e" ] && return 0; done
  return 1
}

# ----------------------------- ذخیره/بارگذاری وضعیت -----------------------------
save_state(){
  mkdir -p "$STATE_DIR"
  {
    echo "#!/usr/bin/env bash"
    echo "WANT_WS=$WANT_WS"
    echo "WANT_XHTTP=$WANT_XHTTP"
    echo "WANT_REALITY=$WANT_REALITY"
    echo "WANT_HY2=$WANT_HY2"
    echo "WANT_WARP=$WANT_WARP"
    echo "WANT_FRAGMENT=$WANT_FRAGMENT"
    echo "WANT_MUX=$WANT_MUX"
    echo "USE_DOMAIN=$USE_DOMAIN"
    echo "CONFIG_NAME='${CONFIG_NAME}'"
    echo "DOMAIN='${DOMAIN}'"
    echo "SUB_PATH='${SUB_PATH}'"
    echo "SUB_TOKEN='${SUB_TOKEN}'"
    echo "SERVER_IP='${SERVER_IP}'"
    echo "FP='${FP}'"
    echo "REALITY_PORT=${REALITY_PORT}"
    echo "SNI='${SNI}'"
    echo "HY2_PORT=${HY2_PORT}"
    echo "HY2_CERT='${HY2_CERT}'"
    echo "HY2_DOMAIN='${HY2_DOMAIN}'"
    echo "LE_EMAIL='${LE_EMAIL}'"
    echo "HY2_PASS='${HY2_PASS}'"
    echo "HY2_PEER='${HY2_PEER}'"
    echo "HY2_INSECURE=${HY2_INSECURE}"
    echo "UUID='${UUID}'"
    echo "WS_PATH='${WS_PATH}'"
    echo "XHTTP_PATH='${XHTTP_PATH}'"
    echo "REALITY_PRIV='${REALITY_PRIV}'"
    echo "REALITY_PUB='${REALITY_PUB}'"
    echo "REALITY_SID='${REALITY_SID}'"
    echo "LAST_BUILD_AT='${LAST_BUILD_AT}'"
    declare -p NGINX_PORTS 2>/dev/null || true
    declare -p PORT_IPS 2>/dev/null || true
  } > "$STATE_FILE"
}

load_state(){
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

# ----------------------------- بکاپ -----------------------------
backup_existing(){
  local custom="$1" ts bdir
  ts="$(date +%Y%m%d-%H%M%S)"
  [ -z "$custom" ] && custom="auto"
  bdir="${BACKUP_DIR}/${custom}-${ts}"
  mkdir -p "$bdir"

  cp -a "$STATE_FILE" "$bdir/state.sh" 2>/dev/null || true
  cp -a /usr/local/etc/xray/config.json "$bdir/" 2>/dev/null || true
  cp -a /etc/nginx/conf.d/xray.conf "$bdir/" 2>/dev/null || true
  cp -a /etc/hysteria/config.yaml "$bdir/" 2>/dev/null || true
  cp -a /var/www/sub "$bdir/sub" 2>/dev/null || true
  cp -a /etc/ssl/xray "$bdir/ssl-xray" 2>/dev/null || true

  ok "Backup saved: $bdir"
}

restore_backup(){
  cls
  title "Restore Backups"

  local items=()
  while IFS= read -r d; do items+=("$d"); done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  [ "${#items[@]}" -gt 0 ] || { warn "No backups found."; pause; return; }

  local i=1
  for d in "${items[@]}"; do
    printf "%2d) %s\n" "$i" "$(basename "$d")" >"$TTY"
    i=$((i+1))
  done
  echo >"$TTY"
  ask idx "Choose backup number"
  [[ "$idx" =~ ^[0-9]+$ ]] || { warn "Invalid number."; pause; return; }
  [ "$idx" -ge 1 ] && [ "$idx" -le "${#items[@]}" ] || { warn "Out of range."; pause; return; }

  local src="${items[$((idx-1))]}"
  [ -d "$src" ] || die "Backup path not found."

  mkdir -p /usr/local/etc/xray /etc/nginx/conf.d /etc/hysteria /var/www
  [ -f "$src/state.sh" ] && cp -f "$src/state.sh" "$STATE_FILE"
  [ -f "$src/config.json" ] && cp -f "$src/config.json" /usr/local/etc/xray/config.json
  [ -f "$src/xray.conf" ] && cp -f "$src/xray.conf" /etc/nginx/conf.d/xray.conf
  [ -f "$src/config.yaml" ] && cp -f "$src/config.yaml" /etc/hysteria/config.yaml
  [ -d "$src/sub" ] && { rm -rf /var/www/sub; cp -a "$src/sub" /var/www/sub; }

  systemctl restart xray 2>/dev/null || true
  systemctl restart nginx 2>/dev/null || true
  systemctl restart hysteria-server 2>/dev/null || true
  ok "Backup restored."
  pause
}

# ----------------------------- پاکسازی نرم/کامل -----------------------------
soft_cleanup(){
  title "Soft Cleanup"
  # فقط فایل‌هایی حذف می‌شوند که روی بازسازی کانفیگ اثر می‌گذارند
  systemctl stop xray nginx hysteria-server 2>/dev/null || true

  rm -f /usr/local/etc/xray/config.json 2>/dev/null || true
  rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
  rm -f /etc/hysteria/config.yaml 2>/dev/null || true
  rm -rf /var/www/sub 2>/dev/null || true
  rm -rf /etc/ssl/xray 2>/dev/null || true

  ok "Soft cleanup finished (core packages are preserved)."
}

full_remove(){
  cls
  title "Full Remove"
  ask_yesno ans "Remove ALL installed artifacts by this script?" "n"
  [ "$ans" = "y" ] || { warn "Canceled."; pause; return; }

  systemctl stop xray nginx hysteria-server warp-svc 2>/dev/null || true
  systemctl disable xray nginx hysteria-server warp-svc 2>/dev/null || true

  rm -rf /usr/local/etc/xray /etc/hysteria /etc/ssl/xray /var/www/sub 2>/dev/null || true
  rm -f /etc/nginx/conf.d/xray.conf /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null || true
  rm -rf "$STATE_DIR" 2>/dev/null || true

  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli disconnect 2>/dev/null || true
    warp-cli registration delete 2>/dev/null || true
  fi

  if command -v ufw >/dev/null 2>&1; then
    local p
    for p in "${CF_PORTS[@]}" 8443 36712; do
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
    done
  fi

  ok "Full remove completed."
  pause
}

existing_detected(){
  [ -f /usr/local/etc/xray/config.json ] || \
  [ -f /etc/nginx/conf.d/xray.conf ] || \
  [ -f /etc/hysteria/config.yaml ] || \
  [ -d /var/www/sub ]
}

# ----------------------------- آماده‌سازی سیستم -----------------------------
server_init(){
  title "Server Initialization"
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y \
        curl wget openssl jq nginx certbot ufw \
        ca-certificates gnupg lsb-release \
        fail2ban unzip net-tools qrencode \
        htop iotop iftop vnstat chrony tzdata
      ;;
    dnf|yum)
      $PKG install -y \
        curl wget openssl jq nginx certbot ufw \
        ca-certificates gnupg \
        fail2ban unzip net-tools qrencode \
        htop chrony tzdata
      ;;
  esac

  timedatectl set-timezone UTC 2>/dev/null || true
  systemctl enable chrony 2>/dev/null || systemctl enable chronyd 2>/dev/null || true
  systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true

  if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow 22/tcp >/dev/null 2>&1 || true
  fi
  ok "Server ready."
}

install_xray(){
  title "Install Xray"
  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
      || die "Xray install failed."
  fi
  ok "Xray installed."
}

install_hysteria(){
  is_true "$WANT_HY2" || return 0
  title "Install Hysteria2"
  command -v hysteria >/dev/null 2>&1 || bash -c "$(curl -fsSL https://get.hy2.sh/)" >/dev/null 2>&1 || die "HY2 install failed."
  ok "Hysteria2 installed."
}

install_warp(){
  is_true "$WANT_WARP" || return 0
  title "Install WARP"
  if ! command -v warp-cli >/dev/null 2>&1; then
    if [ "$PKG" = "apt" ]; then
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y cloudflare-warp >/dev/null 2>&1 || { warn "WARP install failed, disabling WARP."; WANT_WARP=false; return 0; }
    else
      warn "WARP auto-install supported on apt only. Disabling."
      WANT_WARP=false
      return 0
    fi
  fi

  warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null 2>&1
  warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1
  warp-cli --accept-tos connect >/dev/null 2>&1 || true

  ok "WARP configured on 127.0.0.1:${WARP_PORT}"
}

# ----------------------------- جمع‌آوری ورودی -----------------------------
menu_fingerprint(){
  cls
  title "Fingerprint Menu"
  echo "1) chrome (recommended)" >"$TTY"
  echo "2) firefox" >"$TTY"
  echo "3) safari" >"$TTY"
  echo "4) ios" >"$TTY"
  echo "5) android" >"$TTY"
  echo "6) edge" >"$TTY"
  echo "7) random" >"$TTY"
  echo "8) randomized" >"$TTY"
  ask_choice fpnum "Your choice" "1" 1 2 3 4 5 6 7 8
  case "$fpnum" in
    1) FP="chrome" ;;
    2) FP="firefox" ;;
    3) FP="safari" ;;
    4) FP="ios" ;;
    5) FP="android" ;;
    6) FP="edge" ;;
    7) FP="random" ;;
    8) FP="randomized" ;;
  esac
}

collect_nginx_ports(){
  NGINX_PORTS=()
  cls
  title "Nginx Ports (Cloudflare HTTPS)"
  info "Allowed: ${CF_PORTS[*]}"
  info "Enter one by one, empty to finish."

  local p def dup x
  while true; do
    def=""; [ "${#NGINX_PORTS[@]}" -eq 0 ] && def="2096"
    ask p "Port" "$def"
    [ -z "$p" ] && { [ "${#NGINX_PORTS[@]}" -gt 0 ] && break || { warn "At least one port required."; continue; }; }
    [[ "$p" =~ ^[0-9]+$ ]] || { warn "Not a number."; continue; }
    is_cf_port "$p" || { warn "Not a Cloudflare HTTPS port."; continue; }
    dup=false
    for x in "${NGINX_PORTS[@]}"; do [ "$x" = "$p" ] && dup=true; done
    is_true "$dup" && { warn "Duplicate."; continue; }
    NGINX_PORTS+=("$p")
    ok "Added: $p"
  done
}

collect_external_proxies(){
  PORT_IPS=()
  cls
  title "Clean IP Mapping"
  info 'Format example: 2096=104.19.184.210,104.27.53.171'
  info 'Port must be in Nginx ports list. Empty to finish.'

  local line port ips found p
  while true; do
    ask line "Entry"
    [ -z "$line" ] && break
    line="${line// /}"
    if [[ "$line" =~ ^([0-9]+)=(.+)$ ]]; then
      port="${BASH_REMATCH[1]}"
      ips="${BASH_REMATCH[2]}"
      found=false
      for p in "${NGINX_PORTS[@]}"; do [ "$p" = "$port" ] && found=true; done
      is_true "$found" || { warn "Port not in nginx list."; continue; }
      PORT_IPS["$port"]="$ips"
      ok "Mapped $port -> $ips"
    else
      warn "Invalid format."
    fi
  done
}

quick_mode(){
  cls
  title "Quick Mode"

  WANT_WS=true
  WANT_XHTTP=true
  WANT_REALITY=false
  WANT_HY2=false
  WANT_WARP=false
  WANT_FRAGMENT=true
  WANT_MUX=true
  USE_DOMAIN=true
  FP="chrome"
  NGINX_PORTS=(2096)
  PORT_IPS=()

  ask_valid DOMAIN "Domain (Cloudflare)" "$RE_DOMAIN"
  ask_valid SUB_PATH "Subscription path segment" "$RE_SUBPATH" "sub"
  ask CONFIG_NAME "Config name" "MyVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"
}

simple_manual_mode(){
  cls
  title "Simple Manual Mode"

  ask_valid DOMAIN "Domain (Cloudflare)" "$RE_DOMAIN"
  ask CONFIG_NAME "Config name" "MyVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"
  ask_valid SUB_PATH "Subscription path segment" "$RE_SUBPATH" "sub"

  local a
  ask_yesno a "Enable VLESS-WS?" "y";      WANT_WS=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable VLESS-XHTTP?" "y";   WANT_XHTTP=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable Reality?" "y";       WANT_REALITY=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable Hysteria2?" "n";     WANT_HY2=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable WARP outbound?" "n"; WANT_WARP=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable Fragment?" "y";      WANT_FRAGMENT=$([ "$a" = y ] && echo true || echo false)
  ask_yesno a "Enable Mux?" "y";           WANT_MUX=$([ "$a" = y ] && echo true || echo false)

  collect_nginx_ports
  collect_external_proxies
  menu_fingerprint

  if is_true "$WANT_REALITY"; then
    ask_port REALITY_PORT "Reality port" "8443"
    ask_valid SNI "Reality SNI" "$RE_DOMAIN" "www.cloudflare.com"
  fi

  if is_true "$WANT_HY2"; then
    ask_port HY2_PORT "Hysteria2 UDP port" "36712"
    ask_choice hc "HY2 cert type (1=self, 2=letsencrypt)" "1" 1 2
    if [ "$hc" = "2" ]; then
      HY2_CERT="le"
      ask_valid HY2_DOMAIN "HY2 domain" "$RE_DOMAIN"
      ask_valid LE_EMAIL "Let's Encrypt email" "$RE_EMAIL"
    else
      HY2_CERT="self"
    fi
  fi
}

advanced_manual_mode(){
  while true; do
    cls
    title "Advanced Manual Mode"

    echo "1) Protocols" >"$TTY"
    echo "2) Domain / Name / Subscription Path" >"$TTY"
    echo "3) Nginx Ports + Clean IPs" >"$TTY"
    echo "4) Reality Settings" >"$TTY"
    echo "5) Hysteria2 Settings" >"$TTY"
    echo "6) Extra (Fingerprint/Fragment/Mux/WARP)" >"$TTY"
    echo "7) Start Build" >"$TTY"
    echo "8) Back" >"$TTY"
    echo >"$TTY"

    ask_choice c "Choose" "7" 1 2 3 4 5 6 7 8
    case "$c" in
      1)
        local a
        ask_yesno a "Enable VLESS-WS?" "y";      WANT_WS=$([ "$a" = y ] && echo true || echo false)
        ask_yesno a "Enable VLESS-XHTTP?" "y";   WANT_XHTTP=$([ "$a" = y ] && echo true || echo false)
        ask_yesno a "Enable Reality?" "y";       WANT_REALITY=$([ "$a" = y ] && echo true || echo false)
        ask_yesno a "Enable Hysteria2?" "n";     WANT_HY2=$([ "$a" = y ] && echo true || echo false)
        ;;
      2)
        ask_valid DOMAIN "Domain" "$RE_DOMAIN"
        ask CONFIG_NAME "Config name" "$CONFIG_NAME"
        CONFIG_NAME="${CONFIG_NAME// /_}"
        ask_valid SUB_PATH "Subscription path segment" "$RE_SUBPATH" "$SUB_PATH"
        ;;
      3) collect_nginx_ports; collect_external_proxies ;;
      4)
        ask_port REALITY_PORT "Reality port" "$REALITY_PORT"
        ask_valid SNI "Reality SNI" "$RE_DOMAIN" "$SNI"
        ;;
      5)
        ask_port HY2_PORT "HY2 UDP port" "$HY2_PORT"
        ask_choice hc "HY2 cert type (1=self, 2=letsencrypt)" "1" 1 2
        if [ "$hc" = "2" ]; then
          HY2_CERT="le"
          ask_valid HY2_DOMAIN "HY2 domain" "$RE_DOMAIN" "${HY2_DOMAIN:-}"
          ask_valid LE_EMAIL "Let's Encrypt email" "$RE_EMAIL" "${LE_EMAIL:-}"
        else
          HY2_CERT="self"
        fi
        ;;
      6)
        menu_fingerprint
        local a
        ask_yesno a "Enable Fragment?" "y"; WANT_FRAGMENT=$([ "$a" = y ] && echo true || echo false)
        ask_yesno a "Enable Mux?" "y";      WANT_MUX=$([ "$a" = y ] && echo true || echo false)
        ask_yesno a "Enable WARP?" "n";     WANT_WARP=$([ "$a" = y ] && echo true || echo false)
        ;;
      7)
        validate_required_or_back
        return
        ;;
      8) return ;;
    esac
  done
}

validate_required_or_back(){
  is_true "$WANT_WS" || is_true "$WANT_XHTTP" || is_true "$WANT_REALITY" || is_true "$WANT_HY2" || {
    warn "At least one protocol must be enabled."
    pause
    advanced_manual_mode
    return
  }

  if ( is_true "$WANT_WS" || is_true "$WANT_XHTTP" ); then
    [ -n "${DOMAIN:-}" ] || { warn "Domain is required for WS/XHTTP."; pause; advanced_manual_mode; return; }
    [ "${#NGINX_PORTS[@]}" -gt 0 ] || { warn "At least one nginx port is required."; pause; advanced_manual_mode; return; }
  fi

  if is_true "$WANT_REALITY"; then
    [ -n "${SNI:-}" ] || { warn "Reality SNI is required."; pause; advanced_manual_mode; return; }
  fi
}

# ----------------------------- تولید اسرار -----------------------------
gen_secrets_if_needed(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  [ -n "$SERVER_IP" ] || die "Could not detect server IP."

  [ -n "${UUID:-}" ] || UUID="$(cat /proc/sys/kernel/random/uuid)"
  [ -n "${WS_PATH:-}" ] || WS_PATH="/$(openssl rand -hex 6)"
  [ -n "${XHTTP_PATH:-}" ] || XHTTP_PATH="/$(openssl rand -hex 6)"
  [ -n "${SUB_TOKEN:-}" ] || SUB_TOKEN="$(openssl rand -hex 16)"
  [ -n "${HY2_PASS:-}" ] || HY2_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)"

  if is_true "$WANT_REALITY" && { [ -z "${REALITY_PRIV:-}" ] || [ -z "${REALITY_PUB:-}" ] || [ -z "${REALITY_SID:-}" ]; }; then
    local kp
    kp="$(xray x25519)"
    REALITY_PRIV="$(echo "$kp" | awk -F': *' '/[Pp]rivate/{print $2}' | tr -d '[:space:]')"
    REALITY_PUB="$(echo "$kp"  | awk -F': *' '/[Pp]ublic/{print $2}' | tr -d '[:space:]')"
    REALITY_SID="$(openssl rand -hex 8)"
  fi
}

# ----------------------------- نوشتن کانفیگ‌ها -----------------------------
write_xray_config(){
  title "Write Xray Config"
  mkdir -p /usr/local/etc/xray

  local sniff='"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}'
  local IN=() OUT=() RULES=()

  if is_true "$WANT_WS"; then
    IN+=("{\"listen\":\"127.0.0.1\",\"port\":${WS_INT},\"protocol\":\"vless\",\"tag\":\"ws-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"${WS_PATH}\"}},${sniff}}")
  fi

  if is_true "$WANT_XHTTP"; then
    IN+=("{\"listen\":\"127.0.0.1\",\"port\":${XHTTP_INT},\"protocol\":\"vless\",\"tag\":\"xhttp-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"${XHTTP_PATH}\",\"mode\":\"auto\"}},${sniff}}")
  fi

  if is_true "$WANT_REALITY"; then
    IN+=("{\"listen\":\"0.0.0.0\",\"port\":${REALITY_PORT},\"protocol\":\"vless\",\"tag\":\"reality-in\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"${SNI}:443\",\"xver\":0,\"serverNames\":[\"${SNI}\"],\"privateKey\":\"${REALITY_PRIV}\",\"shortIds\":[\"${REALITY_SID}\"]}},${sniff}}")
  fi

  OUT+=('{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}')
  OUT+=('{"tag":"block","protocol":"blackhole","settings":{}}')
  if is_true "$WANT_WARP"; then
    OUT+=("{\"tag\":\"warp\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"127.0.0.1\",\"port\":${WARP_PORT}}]}}")
  fi

  RULES+=('{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}')
  RULES+=('{"type":"field","ip":["geoip:private"],"outboundTag":"block"}')
  if is_true "$WANT_WARP"; then
    RULES+=('{"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix","geosite:spotify","domain:claude.ai","domain:anthropic.com","domain:chatgpt.com"],"outboundTag":"warp"}')
  fi

  local in_json out_json rule_json
  in_json="$(IFS=,; echo "${IN[*]}")"
  out_json="$(IFS=,; echo "${OUT[*]}")"
  rule_json="$(IFS=,; echo "${RULES[*]}")"

  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[${in_json}],
  "outbounds":[${out_json}],
  "routing":{"domainStrategy":"IpIfNonMatch","rules":[${rule_json}]}
}
JSON

  jq empty /usr/local/etc/xray/config.json >/dev/null 2>&1 || die "Invalid xray JSON."
  ok "Xray config written."
}

write_nginx(){
  ( is_true "$WANT_WS" || is_true "$WANT_XHTTP" ) || return 0
  title "Write Nginx Config"

  mkdir -p /var/www/html /var/www/sub /etc/ssl/xray
  [ -f /var/www/html/index.html ] || echo "<h1>It works</h1>" > /var/www/html/index.html

  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/ssl/xray/self.key -out /etc/ssl/xray/self.crt \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1

  local listens="" p
  for p in "${NGINX_PORTS[@]}"; do
    listens+="    listen ${p} ssl;\n    listen [::]:${p} ssl;\n"
  done

  local locs=""
  if is_true "$WANT_WS"; then
    locs+="
    location ${WS_PATH} {
        if (\$http_upgrade != \"websocket\") { return 404; }
        proxy_pass http://127.0.0.1:${WS_INT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
"
  fi

  if is_true "$WANT_XHTTP"; then
    locs+="
    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_INT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
    }
"
  fi

  cat > /etc/nginx/conf.d/xray.conf <<NG
server {
$(printf "%b" "$listens")    server_name ${DOMAIN};
    ssl_certificate     /etc/ssl/xray/self.crt;
    ssl_certificate_key /etc/ssl/xray/self.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/html;
    index index.html;

    location / { try_files \$uri \$uri/ =404; }

    location /sub/${SUB_TOKEN} {
        default_type text/plain;
        alias /var/www/sub/${SUB_TOKEN}.txt;
    }
${locs}
}
NG

  nginx -t >/dev/null 2>&1 || die "Nginx test failed."
  ok "Nginx config written."
}

write_hysteria(){
  is_true "$WANT_HY2" || return 0
  title "Write Hysteria2 Config"
  mkdir -p /etc/hysteria

  if [ "$HY2_CERT" = "le" ]; then
    systemctl stop nginx >/dev/null 2>&1 || true
    certbot certonly --standalone --non-interactive --agree-tos \
      -m "${LE_EMAIL}" -d "${HY2_DOMAIN}" >/dev/null 2>&1 || {
      warn "Let's Encrypt failed. Falling back to self-signed."
      HY2_CERT="self"
    }
    systemctl start nginx >/dev/null 2>&1 || true
  fi

  local tls_block
  if [ "$HY2_CERT" = "le" ] && [ -f "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem" ]; then
    tls_block="tls:
  cert: /etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
    HY2_PEER="${HY2_DOMAIN}"
    HY2_INSECURE=0
  else
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
      -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1
    tls_block="tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key"
    HY2_PEER="${HY2_SNI}"
    HY2_INSECURE=1
  fi

  cat > /etc/hysteria/config.yaml <<YAML
listen: :${HY2_PORT}

${tls_block}

auth:
  type: password
  password: ${HY2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true
YAML

  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat >/etc/systemd/system/hysteria-server.service.d/override.conf <<OVR
[Service]
User=root
Group=root
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
OVR
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Hysteria2 config written."
}

# ----------------------------- لینک‌ها و ساب -----------------------------
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
  LINKS=()
  local fp="${FP:-chrome}" enc_ws enc_xh
  enc_ws="$(urlenc "${WS_PATH}")"
  enc_xh="$(urlenc "${XHTTP_PATH}")"

  if is_true "$WANT_WS" || is_true "$WANT_XHTTP"; then
    local p ips arr addr tag
    for p in "${NGINX_PORTS[@]}"; do
      ips="${PORT_IPS[$p]:-}"
      if [ -n "$ips" ]; then IFS=',' read -r -a arr <<<"$ips"; else arr=("$DOMAIN"); fi
      for addr in "${arr[@]}"; do
        if is_true "$WANT_WS"; then
          tag="${CONFIG_NAME}-WS-${p}-${addr}"
          LINKS+=("vless://${UUID}@${addr}:${p}?encryption=none&security=tls&sni=${DOMAIN}&fp=${fp}&type=ws&host=${DOMAIN}&path=${enc_ws}#$(urlenc "$tag")")
        fi
        if is_true "$WANT_XHTTP"; then
          tag="${CONFIG_NAME}-XHTTP-${p}-${addr}"
          LINKS+=("vless://${UUID}@${addr}:${p}?encryption=none&security=tls&sni=${DOMAIN}&fp=${fp}&type=xhttp&host=${DOMAIN}&path=${enc_xh}&mode=auto#$(urlenc "$tag")")
        fi
      done
    done
  fi

  if is_true "$WANT_REALITY"; then
    LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=${fp}&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision&type=tcp#$(urlenc "${CONFIG_NAME}-Reality")")
  fi

  if is_true "$WANT_HY2"; then
    LINKS+=("hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${HY2_PEER}&insecure=${HY2_INSECURE}#$(urlenc "${CONFIG_NAME}-HY2")")
  fi

  [ "${#LINKS[@]}" -gt 0 ] || die "No links generated."
  ok "Generated ${#LINKS[@]} links."
}

build_subscription(){
  ( is_true "$WANT_WS" || is_true "$WANT_XHTTP" ) || return 0
  mkdir -p /var/www/sub
  local raw
  raw="$(printf '%s\n' "${LINKS[@]}")"
  printf '%s' "$raw" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt" 2>/dev/null || \
    printf '%s' "$raw" | base64 | tr -d '\n' > "/var/www/sub/${SUB_TOKEN}.txt"
}

setup_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  local p
  for p in "${NGINX_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
  is_true "$WANT_REALITY" && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  is_true "$WANT_HY2" && ufw allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true
  [ "$HY2_CERT" = "le" ] && ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

start_services(){
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || die "Xray failed."

  if is_true "$WANT_WS" || is_true "$WANT_XHTTP"; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || die "Nginx failed."
  fi

  if is_true "$WANT_HY2"; then
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    systemctl restart hysteria-server >/dev/null 2>&1 || die "Hysteria failed."
  fi
}

final_output(){
  cls
  title "Build Completed"

  local l
  for l in "${LINKS[@]}"; do
    printf "${CG}%s${C0}\n\n" "$l" >"$TTY"
  done

  if is_true "$WANT_WS" || is_true "$WANT_XHTTP"; then
    local suburl="https://${DOMAIN}:${NGINX_PORTS[0]}/sub/${SUB_TOKEN}"
    echo "Subscription URL:" >"$TTY"
    printf "${C1}%s${C0}\n\n" "$suburl" >"$TTY"
  fi

  is_true "$WANT_REALITY" && echo "Reality: ${SERVER_IP}:${REALITY_PORT}" >"$TTY"
  is_true "$WANT_HY2" && echo "Hysteria2: UDP ${HY2_PORT}" >"$TTY"
  echo >"$TTY"
  ok "Done."
}

# ----------------------------- جریان ساخت -----------------------------
build_apply_pipeline(){
  server_init
  install_xray
  install_hysteria
  install_warp
  gen_secrets_if_needed
  write_xray_config
  write_nginx
  write_hysteria
  build_links
  build_subscription
  setup_firewall
  start_services
  LAST_BUILD_AT="$(date '+%Y-%m-%d %H:%M:%S UTC')"
  save_state
  final_output
  pause
}

# ----------------------------- New / Edit / Rebuild -----------------------------
new_build_flow(){
  cls
  title "New Build"

  if existing_detected; then
    warn "Existing installation detected."
    ask_yesno bq "Create backup before continue?" "y"
    if [ "$bq" = "y" ]; then
      ask bname "Backup name (optional)" ""
      backup_existing "$bname"
    fi
  fi

  soft_cleanup

  echo "1) Quick Mode" >"$TTY"
  echo "2) Simple Manual" >"$TTY"
  echo "3) Advanced Manual" >"$TTY"
  ask_choice m "Choose mode" "1" 1 2 3

  # در ساخت جدید اسرار ریست می‌شوند
  UUID=""; WS_PATH=""; XHTTP_PATH=""; REALITY_PRIV=""; REALITY_PUB=""; REALITY_SID=""
  HY2_PASS=""
  SUB_TOKEN="$(openssl rand -hex 16)"

  case "$m" in
    1) quick_mode ;;
    2) simple_manual_mode ;;
    3) advanced_manual_mode ;;
  esac

  build_apply_pipeline
}

edit_current_flow(){
  cls
  title "Edit Current (Keep Name + Subscription Link)"
  load_state

  [ -n "${CONFIG_NAME:-}" ] || { warn "No previous state found. Use New Build first."; pause; return; }

  local keep_name="$CONFIG_NAME"
  local keep_sub_path="$SUB_PATH"
  local keep_sub_token="$SUB_TOKEN"

  advanced_manual_mode

  CONFIG_NAME="$keep_name"
  SUB_PATH="$keep_sub_path"
  SUB_TOKEN="$keep_sub_token"

  # برای حفظ لینک/اسم، فقط اسرار اصلی را حفظ می‌کنیم مگر کاربر خواسته پروتکل جدید اضافه کند
  gen_secrets_if_needed
  build_apply_pipeline
}

rebuild_flow(){
  cls
  title "Rebuild Configs"
  load_state
  [ -f "$STATE_FILE" ] || { warn "No saved state found."; pause; return; }

  # همان تنظیمات فعلی، همان نام و ساب
  soft_cleanup
  build_apply_pipeline
}

# ----------------------------- وضعیت -----------------------------
status_flow(){
  cls
  load_state
  title "Status"

  echo "Installer: $INSTALLER_NAME" >"$TTY"
  echo "Author   : $AUTHOR_NAME" >"$TTY"
  echo "Config   : ${CONFIG_NAME:-N/A}" >"$TTY"
  echo "Domain   : ${DOMAIN:-N/A}" >"$TTY"
  echo "LastBuild: ${LAST_BUILD_AT:-N/A}" >"$TTY"
  echo >"$TTY"

  echo "Services:" >"$TTY"
  echo "  xray      : $(systemctl is-active xray 2>/dev/null || echo unknown)" >"$TTY"
  echo "  nginx     : $(systemctl is-active nginx 2>/dev/null || echo unknown)" >"$TTY"
  echo "  hysteria2 : $(systemctl is-active hysteria-server 2>/dev/null || echo unknown)" >"$TTY"
  echo >"$TTY"

  if command -v vnstat >/dev/null 2>&1; then
    echo "Traffic (vnstat oneline):" >"$TTY"
    vnstat --oneline b 2>/dev/null >"$TTY" || true
  else
    echo "Traffic: vnstat not installed." >"$TTY"
  fi

  pause
}

# ----------------------------- منوی اصلی -----------------------------
main_menu(){
  while true; do
    cls
    echo -e "${CB}${C2}╔════════════════════════════════════════════════════╗${C0}" >"$TTY"
    echo -e "${CB}${C2}║              Welcome to VPN Manager               ║${C0}" >"$TTY"
    echo -e "${CB}${C2}╚════════════════════════════════════════════════════╝${C0}" >"$TTY"
    echo -e "${C3}Name: ${INSTALLER_NAME} | Author: ${AUTHOR_NAME}${C0}\n" >"$TTY"

    echo "1) New Build" >"$TTY"
    echo "2) Edit Current" >"$TTY"
    echo "3) Rebuild Configs" >"$TTY"
    echo "4) Restore Backup" >"$TTY"
    echo "5) Status" >"$TTY"
    echo "6) Full Remove" >"$TTY"
    echo "7) Exit" >"$TTY"
    echo >"$TTY"

    ask_choice ch "Select option" "1" 1 2 3 4 5 6 7
    case "$ch" in
      1) new_build_flow ;;
      2) edit_current_flow ;;
      3) rebuild_flow ;;
      4) restore_backup ;;
      5) status_flow ;;
      6) full_remove ;;
      7) exit 0 ;;
    esac
  done
}

# ----------------------------- اجرا -----------------------------
load_state
main_menu
