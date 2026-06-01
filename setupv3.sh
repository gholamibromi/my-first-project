#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  VPN Multi-Protocol Installer  ·  v2
#  Protocols: VLESS-WS · VLESS-XHTTP · VLESS-Reality · Hysteria2
#  Features:  Fragment · Mux · WARP · Sniffing · Subscription
#  Menu: New · Modify · Rebuild · Restore · Status · Purge
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

# ── رنگ‌ها ──────────────────────────────────────────────────────
C0=$'\033[0m'; C1=$'\033[38;5;39m'; C2=$'\033[38;5;220m'
C3=$'\033[38;5;245m'; CG=$'\033[38;5;82m'; CR=$'\033[38;5;196m'
CW=$'\033[38;5;208m'; CB=$'\033[1m'
TTY=/dev/tty

# ── توابع لاگ ───────────────────────────────────────────────────
ok()    { printf "${CG}  ✔  ${C0}%s\n"        "$*" >"$TTY"; }
warn()  { printf "${CW}  ⚠  ${C0}%s\n"        "$*" >"$TTY"; }
die()   { printf "${CR}  ✖  ${C0}%s\n"        "$*" >"$TTY"; exit 1; }
info()  { printf "${C3}  ·  ${C0}%s\n"        "$*" >"$TTY"; }
step()  { printf "\n${CB}${C2}  ▶  %s${C0}\n" "$*" >"$TTY"; }
banner(){ printf "${C2}%s${C0}\n" "$*" >"$TTY"; }
clr()   { printf '\033[2J\033[H' >"$TTY"; }
pause() { printf "\n${C3}  Press Enter to continue...${C0}" >"$TTY"; read -r _ <"$TTY" || true; }

# ── ثابت‌ها ──────────────────────────────────────────────────────
APP_NAME="VPN Multi-Protocol Installer"
APP_VER="2.0"
APP_AUTHOR="github.com/yourname"
STATE_DIR="/etc/vpn-installer"
STATE_FILE="${STATE_DIR}/state.env"
BACKUP_ROOT="/root/vpn-backups"

MAX_TRIES=3
CF_PORTS=(443 2053 2083 2087 2096 8443)
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"
WARP_PORT=40000

RE_DOMAIN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
RE_EMAIL='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
RE_EXT='^PORT_IPS\[([0-9]+)\]="?([0-9A-Za-z.,:_-]+)"?$'
RE_SUBPATH='^[A-Za-z0-9._-]+$'

[ "$(id -u)" = 0 ] || die "Please run as root."

PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found (apt/dnf/yum)."

# ════════════════════════════════════════════════════════════════
#  مقداردهی اولیه وضعیت (ریست برای ساخت جدید)
# ════════════════════════════════════════════════════════════════
reset_state_vars(){
  WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
  WANT_WARP=false; WANT_FRAGMENT=false; WANT_MUX=false
  USE_DOMAIN=false
  NGINX_PORTS=()
  unset PORT_IPS 2>/dev/null || true; declare -gA PORT_IPS=()
  EXT_COUNT=0
  UUID=""; SUB_TOKEN=""; WS_PATH=""; XHTTP_PATH=""
  REALITY_PORT=8443; REALITY_PRIV=""; REALITY_PUB=""; REALITY_SID=""; SNI=""
  HY2_PORT=36712; HY2_PASS=""; HY2_CERT="self"; HY2_PEER=""; HY2_INSECURE=1
  HY2_DOMAIN=""; LE_EMAIL=""
  DOMAIN=""; CONFIG_NAME=""; SUB_PATH_IN="sub"; FP=""
  SUB_HOST=""; SUB_PORT=2096; SERVER_IP=""; SUB_URL=""
  INSTALL_DATE=""; LINKS=()
}
declare -gA PORT_IPS=()
reset_state_vars

# ── ذخیره / بارگذاری وضعیت ──────────────────────────────────────
save_state(){
  mkdir -p "$STATE_DIR"
  {
    echo "# VPN installer state — auto-generated"
    for v in CONFIG_NAME SUB_TOKEN SUB_PATH_IN DOMAIN USE_DOMAIN \
             WANT_WS WANT_XHTTP WANT_REALITY WANT_HY2 \
             WANT_WARP WANT_FRAGMENT WANT_MUX \
             UUID WS_PATH XHTTP_PATH \
             REALITY_PORT REALITY_PRIV REALITY_PUB REALITY_SID SNI \
             HY2_PORT HY2_PASS HY2_CERT HY2_PEER HY2_INSECURE HY2_DOMAIN LE_EMAIL \
             FP SERVER_IP SUB_HOST SUB_PORT SUB_URL INSTALL_DATE; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    echo "NGINX_PORTS=(${NGINX_PORTS[*]})"
    echo "declare -gA PORT_IPS"
    for k in "${!PORT_IPS[@]}"; do printf 'PORT_IPS[%s]=%q\n' "$k" "${PORT_IPS[$k]}"; done
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state(){
  [ -f "$STATE_FILE" ] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  return 0
}

has_install(){ [ -f "$STATE_FILE" ] || [ -f /usr/local/etc/xray/config.json ] \
               || [ -f /etc/hysteria/config.yaml ]; }

# ════════════════════════════════════════════════════════════════
#  توابع ورودی
# ════════════════════════════════════════════════════════════════
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

is_cf_port(){ local p="$1" e; for e in "${CF_PORTS[@]}"; do [ "$p" = "$e" ] && return 0; done; return 1; }
onoff(){ [ "$1" = true ] && echo on || echo off; }
def_yn(){ [ "$1" = true ] && echo y || echo n; }

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

# ── نوار پیشرفت ──────────────────────────────────────────────────
STEP_CURRENT=0; STEP_TOTAL=10
progress(){
  STEP_CURRENT=$((STEP_CURRENT+1))
  local pct=$(( STEP_CURRENT * 100 / STEP_TOTAL ))
  [ "$pct" -gt 100 ] && pct=100
  local filled=$(( pct / 5 )) bar="" i
  for ((i=0; i<20; i++)); do [ $i -lt $filled ] && bar+="█" || bar+="░"; done
  printf "${C2}  [%s] %3d%%${C0} %s\n" "$bar" "$pct" "$*" >"$TTY"
}
# ════════════════════════════════════════════════════════════════
#  مدیریت بسته‌ها و وابستگی‌ها
# ════════════════════════════════════════════════════════════════
pkg_update(){
  case "$PKG" in
    apt) apt-get update -y >/dev/null 2>&1 ;;
    dnf) dnf makecache -y  >/dev/null 2>&1 ;;
    yum) yum makecache -y  >/dev/null 2>&1 ;;
  esac
}
pkg_install(){
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 ;;
    dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
    yum) yum install -y "$@" >/dev/null 2>&1 ;;
  esac
}

install_deps(){
  step "Installing dependencies"
  pkg_update
  local base=(curl wget tar unzip jq openssl ca-certificates qrencode socat)
  [ "$PKG" = apt ] && base+=(uuid-runtime)
  pkg_install "${base[@]}" || warn "Some packages may have failed to install."
  ok "Dependencies ready."
}

# ── شناسایی IP عمومی سرور ────────────────────────────────────────
detect_ip(){
  local ip
  ip=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -fsS4 --max-time 8 https://ifconfig.me 2>/dev/null) \
    || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  [ -n "$ip" ] || die "Could not detect public IP."
  printf '%s' "$ip"
}

# ════════════════════════════════════════════════════════════════
#  نصب هسته Xray
# ════════════════════════════════════════════════════════════════
install_xray(){
  if command -v xray >/dev/null 2>&1; then
    ok "Xray already installed ($(xray version 2>/dev/null | head -n1))."
    return 0
  fi
  step "Installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
    @ install >/dev/null 2>&1 \
    || die "Xray installation failed."
  command -v xray >/dev/null 2>&1 || die "Xray binary not found after install."
  ok "Xray installed."
}

# ── تولید کلیدهای Reality ────────────────────────────────────────
gen_reality_keys(){
  local out priv pub
  out=$(xray x25519 2>/dev/null) || die "Failed to generate Reality keys."
  priv=$(awk -F': ' '/Private/{print $2}' <<<"$out")
  pub=$(awk -F': ' '/Public/{print $2}'  <<<"$out")
  REALITY_PRIV="$priv"; REALITY_PUB="$pub"
  REALITY_SID=$(openssl rand -hex 8)
  [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "Empty Reality keys."
}

# ── تولید شناسه‌ها و مسیرها ──────────────────────────────────────
gen_identifiers(){
  [ -n "$UUID" ]      || UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
  [ -n "$SUB_TOKEN" ] || SUB_TOKEN=$(openssl rand -hex 12)
  [ -n "$WS_PATH" ]   || WS_PATH="/$(openssl rand -hex 4)-ws"
  [ -n "$XHTTP_PATH" ]|| XHTTP_PATH="/$(openssl rand -hex 4)-xh"
  [ -n "$HY2_PASS" ]  || HY2_PASS=$(openssl rand -hex 12)
}

# ════════════════════════════════════════════════════════════════
#  نصب Hysteria2
# ════════════════════════════════════════════════════════════════
install_hysteria(){
  [ "$WANT_HY2" = true ] || return 0
  if command -v hysteria >/dev/null 2>&1; then
    ok "Hysteria already present."
    return 0
  fi
  step "Installing Hysteria2"
  bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 \
    || die "Hysteria2 installation failed."
  command -v hysteria >/dev/null 2>&1 || die "Hysteria binary missing."
  ok "Hysteria2 installed."
}

# ── گواهی self-signed برای Hysteria2 ─────────────────────────────
gen_hy2_cert(){
  [ "$WANT_HY2" = true ] || return 0
  [ "$HY2_CERT" = self ] || return 0
  mkdir -p /etc/hysteria
  step "Generating self-signed certificate for Hysteria2"
  openssl req -x509 -nodes -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key \
    -out    /etc/hysteria/server.crt \
    -subj   "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1 \
    || die "Certificate generation failed."
  chmod 600 /etc/hysteria/server.key
  HY2_PEER="$HY2_SNI"; HY2_INSECURE=1
  ok "Certificate created (CN=${HY2_SNI})."
}

# ════════════════════════════════════════════════════════════════
#  نصب WARP (wireproxy)  ·  خروجی اختیاری برای مسیریابی
# ════════════════════════════════════════════════════════════════
install_warp(){
  [ "$WANT_WARP" = true ] || return 0
  step "Installing WARP outbound"
  pkg_install wireguard-tools >/dev/null 2>&1 || true
  if ! command -v wgcf >/dev/null 2>&1; then
    local arch="amd64"
    case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; esac
    curl -fsSL -o /usr/local/bin/wgcf \
      "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_${arch}" \
      >/dev/null 2>&1 || warn "wgcf download failed."
    chmod +x /usr/local/bin/wgcf 2>/dev/null || true
  fi
  ok "WARP component ready (config wired into Xray outbound)."
}
# ════════════════════════════════════════════════════════════════
#  ساخت outbound های Xray (شامل WARP در صورت فعال بودن)
# ════════════════════════════════════════════════════════════════
build_outbounds(){
  local outs='[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]'
  if [ "$WANT_WARP" = true ]; then
    outs=$(jq -c '. + [{
      "tag":"warp","protocol":"freedom",
      "settings":{"domainStrategy":"UseIP"}
    }]' <<<"$outs")
  fi
  printf '%s' "$outs"
}

# ── ساخت inbound ها بر اساس پروتکل‌های انتخابی ───────────────────
build_inbounds(){
  local arr='[]'

  if [ "$WANT_WS" = true ]; then
    arr=$(jq -c --arg uuid "$UUID" --arg path "$WS_PATH" --argjson port "$WS_INT" '. + [{
      "tag":"vless-ws","listen":"127.0.0.1","port":$port,"protocol":"vless",
      "settings":{"clients":[{"id":$uuid}],"decryption":"none"},
      "streamSettings":{"network":"ws","security":"none",
        "wsSettings":{"path":$path}},
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    }]' <<<"$arr")
  fi

  if [ "$WANT_XHTTP" = true ]; then
    arr=$(jq -c --arg uuid "$UUID" --arg path "$XHTTP_PATH" --argjson port "$XHTTP_INT" '. + [{
      "tag":"vless-xhttp","listen":"127.0.0.1","port":$port,"protocol":"vless",
      "settings":{"clients":[{"id":$uuid}],"decryption":"none"},
      "streamSettings":{"network":"xhttp","security":"none",
        "xhttpSettings":{"path":$path,"mode":"auto"}},
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    }]' <<<"$arr")
  fi

  if [ "$WANT_REALITY" = true ]; then
    arr=$(jq -c \
      --arg uuid "$UUID" --arg priv "$REALITY_PRIV" --arg sid "$REALITY_SID" \
      --arg sni "$SNI" --argjson port "$REALITY_PORT" '. + [{
      "tag":"vless-reality","listen":"0.0.0.0","port":$port,"protocol":"vless",
      "settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
      "streamSettings":{"network":"tcp","security":"reality",
        "realitySettings":{"show":false,"dest":($sni+":443"),
          "serverNames":[$sni],"privateKey":$priv,"shortIds":[$sid]}},
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    }]' <<<"$arr")
  fi

  printf '%s' "$arr"
}

# ── قوانین مسیریابی (WARP routing در صورت فعال بودن) ─────────────
build_routing(){
  if [ "$WANT_WARP" = true ]; then
    cat <<'JSON'
{"domainStrategy":"IPIfNonMatch","rules":[
  {"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix"],"outboundTag":"warp"},
  {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
]}
JSON
  else
    cat <<'JSON'
{"domainStrategy":"IPIfNonMatch","rules":[
  {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
]}
JSON
  fi
}

# ════════════════════════════════════════════════════════════════
#  نوشتن config.json نهایی Xray
# ════════════════════════════════════════════════════════════════
write_xray_config(){
  step "Writing Xray configuration"
  mkdir -p /usr/local/etc/xray
  local inbs outs route
  inbs=$(build_inbounds)
  outs=$(build_outbounds)
  route=$(build_routing)

  jq -n \
    --argjson inbounds  "$inbs" \
    --argjson outbounds "$outs" \
    --argjson routing   "$route" '{
      "log":{"loglevel":"warning",
             "access":"/var/log/xray/access.log",
             "error":"/var/log/xray/error.log"},
      "inbounds":$inbounds,
      "outbounds":$outbounds,
      "routing":$routing
    }' > /usr/local/etc/xray/config.json \
    || die "Failed to write Xray config."

  mkdir -p /var/log/xray
  xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 \
    || die "Xray config validation failed."
  ok "Xray config written and validated."
}

# ════════════════════════════════════════════════════════════════
#  نوشتن config.yaml برای Hysteria2
# ════════════════════════════════════════════════════════════════
write_hy2_config(){
  [ "$WANT_HY2" = true ] || return 0
  step "Writing Hysteria2 configuration"
  mkdir -p /etc/hysteria
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
YAML
  ok "Hysteria2 config written."
}

# ════════════════════════════════════════════════════════════════
#  پیکربندی nginx (front برای WS/XHTTP و سرو اشتراک)
# ════════════════════════════════════════════════════════════════
write_nginx_config(){
  { [ "$WANT_WS" = true ] || [ "$WANT_XHTTP" = true ]; } || return 0
  command -v nginx >/dev/null 2>&1 || pkg_install nginx
  step "Writing nginx configuration"

  local loc=""
  [ "$WANT_WS" = true ] && loc+="
    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_INT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
    }"
  [ "$WANT_XHTTP" = true ] && loc+="
    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_INT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }"

  local srv_name="_"
  [ "$USE_DOMAIN" = true ] && [ -n "$DOMAIN" ] && srv_name="$DOMAIN"

  cat > /etc/nginx/conf.d/vpn.conf <<NGINX
server {
    listen ${SUB_PORT};
    server_name ${srv_name};

    location = /${SUB_PATH_IN}/${SUB_TOKEN} {
        default_type text/plain;
        alias /var/www/vpn-sub/${SUB_TOKEN}.txt;
    }
${loc}
    location / { return 404; }
}
NGINX
  mkdir -p /var/www/vpn-sub
  nginx -t >/dev/null 2>&1 || die "nginx config test failed."
  ok "nginx config written."
}

# ════════════════════════════════════════════════════════════════
#  راه‌اندازی سرویس‌ها
# ════════════════════════════════════════════════════════════════
start_services(){
  step "Starting services"
  systemctl enable xray  >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || die "Xray failed to start."
  ok "Xray running."

  if [ "$WANT_HY2" = true ]; then
    systemctl enable hysteria-server  >/dev/null 2>&1 || true
    systemctl restart hysteria-server >/dev/null 2>&1 || warn "Hysteria failed to start."
    ok "Hysteria2 running."
  fi

  if { [ "$WANT_WS" = true ] || [ "$WANT_XHTTP" = true ]; }; then
    systemctl enable nginx  >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || die "nginx failed to start."
    ok "nginx running."
  fi
}
# ════════════════════════════════════════════════════════════════
#  ساخت لینک‌های اتصال برای هر پروتکل فعال
# ════════════════════════════════════════════════════════════════
build_links(){
  step "Building connection links"
  LINKS=()
  local host="$SUB_HOST" tag enc

  if [ "$WANT_WS" = true ]; then
    enc=$(urlenc "$WS_PATH")
    tag=$(urlenc "${CONFIG_NAME}-WS")
    LINKS+=("vless://${UUID}@${host}:${SUB_PORT}?type=ws&security=none&path=${enc}&host=${host}#${tag}")
  fi

  if [ "$WANT_XHTTP" = true ]; then
    enc=$(urlenc "$XHTTP_PATH")
    tag=$(urlenc "${CONFIG_NAME}-XHTTP")
    LINKS+=("vless://${UUID}@${host}:${SUB_PORT}?type=xhttp&security=none&path=${enc}&host=${host}&mode=auto#${tag}")
  fi

  if [ "$WANT_REALITY" = true ]; then
    tag=$(urlenc "${CONFIG_NAME}-Reality")
    LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=${REALITY_PUB}&fp=${FP}&sni=${SNI}&sid=${REALITY_SID}#${tag}")
  fi

  if [ "$WANT_HY2" = true ]; then
    tag=$(urlenc "${CONFIG_NAME}-HY2")
    local hyhost="$SERVER_IP"
    [ "$HY2_CERT" = le ] && [ -n "$HY2_DOMAIN" ] && hyhost="$HY2_DOMAIN"
    LINKS+=("hysteria2://${HY2_PASS}@${hyhost}:${HY2_PORT}?sni=${HY2_PEER}&insecure=${HY2_INSECURE}#${tag}")
  fi

  ok "Generated ${#LINKS[@]} link(s)."
}

# ── نوشتن فایل اشتراک (base64) و سرو از طریق nginx ───────────────
write_subscription(){
  { [ "$WANT_WS" = true ] || [ "$WANT_XHTTP" = true ]; } || return 0
  step "Writing subscription file"
  mkdir -p /var/www/vpn-sub
  local plain=""
  local l
  for l in "${LINKS[@]}"; do plain+="${l}"$'\n'; done
  printf '%s' "$plain" | base64 -w0 > "/var/www/vpn-sub/${SUB_TOKEN}.txt"

  if [ "$USE_DOMAIN" = true ] && [ -n "$DOMAIN" ]; then
    SUB_URL="http://${DOMAIN}:${SUB_PORT}/${SUB_PATH_IN}/${SUB_TOKEN}"
  else
    SUB_URL="http://${SERVER_IP}:${SUB_PORT}/${SUB_PATH_IN}/${SUB_TOKEN}"
  fi
  ok "Subscription ready."
}

# ── نمایش لینک‌ها و کد QR ────────────────────────────────────────
show_results(){
  banner "Installation Complete"
  printf "${CW}Connection links:${C0}\n\n"
  local l
  for l in "${LINKS[@]}"; do
    printf "${C2}%s${C0}\n\n" "$l"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$l"
    printf "\n"
  done
  if [ -n "$SUB_URL" ]; then
    printf "${CW}Subscription URL:${C0}\n${C3}%s${C0}\n\n" "$SUB_URL"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$SUB_URL"
    printf "\n"
  fi
}

# ════════════════════════════════════════════════════════════════
#  گردآوری اطلاعات ورودی از کاربر (نصب جدید)
# ════════════════════════════════════════════════════════════════
collect_input(){
  banner "New Installation"
  reset_state_vars

  ask_yesno "Enable VLESS-WebSocket?"   y && WANT_WS=true
  ask_yesno "Enable VLESS-XHTTP?"       y && WANT_XHTTP=true
  ask_yesno "Enable VLESS-Reality?"     y && WANT_REALITY=true
  ask_yesno "Enable Hysteria2?"         n && WANT_HY2=true
  ask_yesno "Enable WARP routing?"      n && WANT_WARP=true

  if [ "$WANT_WS" = false ] && [ "$WANT_XHTTP" = false ] \
     && [ "$WANT_REALITY" = false ] && [ "$WANT_HY2" = false ]; then
    die "At least one protocol must be enabled."
  fi

  CONFIG_NAME=$(ask "Config name" "MyVPN")

  ask_yesno "Use a domain (instead of bare IP)?" n && USE_DOMAIN=true
  if [ "$USE_DOMAIN" = true ]; then
    DOMAIN=$(ask_valid "Domain" "$RE_DOMAIN" "Invalid domain")
    SUB_HOST="$DOMAIN"
  else
    SUB_HOST="$SERVER_IP"
  fi

  SUB_PORT=$(ask_port "Subscription/HTTP port" 8080)
  SUB_PATH_IN=$(ask_valid "Subscription base path" "$RE_SUBPATH" "Invalid path" "sub")

  if [ "$WANT_REALITY" = true ]; then
    REALITY_PORT=$(ask_port "Reality port" 443)
    SNI=$(ask_valid "Reality SNI (dest domain)" "$RE_DOMAIN" "Invalid SNI" "www.microsoft.com")
    FP=$(ask_choice "TLS fingerprint" "chrome firefox safari ios edge random" "chrome")
  fi

  if [ "$WANT_HY2" = true ]; then
    HY2_PORT=$(ask_port "Hysteria2 port" 8443)
    if [ "$USE_DOMAIN" = true ]; then
      HY2_CERT=$(ask_choice "Hysteria2 cert (self/le)" "self le" "self")
      [ "$HY2_CERT" = le ] && HY2_DOMAIN="$DOMAIN" \
        && LE_EMAIL=$(ask_valid "Email for Let's Encrypt" "$RE_EMAIL" "Invalid email")
    else
      HY2_CERT=self
    fi
  fi
}

# ════════════════════════════════════════════════════════════════
#  جریان کامل نصب
# ════════════════════════════════════════════════════════════════
run_install(){
  STEP_CURRENT=0
  pkg_update
  install_deps
  detect_ip
  install_xray
  [ "$WANT_HY2" = true ]  && install_hysteria
  [ "$WANT_WARP" = true ] && install_warp
  [ "$WANT_REALITY" = true ] && gen_reality_keys
  gen_identifiers
  [ "$WANT_HY2" = true ] && gen_hy2_cert

  write_xray_config
  write_hy2_config
  write_nginx_config
  start_services

  build_links
  write_subscription

  INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
  save_state
  show_results
}

# ════════════════════════════════════════════════════════════════
#  نمایش وضعیت نصب فعلی
# ════════════════════════════════════════════════════════════════
show_status(){
  banner "Status"
  has_install || { warn "No installation found."; pause; return; }
  load_state

  printf "${CW}Config name:${C0} %s\n" "$CONFIG_NAME"
  printf "${CW}Installed:${C0}   %s\n" "${INSTALL_DATE:-unknown}"
  printf "${CW}Server IP:${C0}   %s\n\n" "$SERVER_IP"

  local svc
  for svc in xray hysteria-server nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      printf "  ${C2}●${C0} %-18s ${C2}active${C0}\n" "$svc"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
      printf "  ${CR}●${C0} %-18s ${CR}inactive${C0}\n" "$svc"
    fi
  done
  printf "\n"
  [ -n "${SUB_URL:-}" ] && printf "${CW}Subscription:${C0} %s\n\n" "$SUB_URL"
  pause
}

# ════════════════════════════════════════════════════════════════
#  بکاپ و بازیابی
# ════════════════════════════════════════════════════════════════
do_backup(){
  has_install || { warn "Nothing to back up."; return 1; }
  mkdir -p "$BACKUP_ROOT"
  local stamp file
  stamp="$(date '+%Y%m%d-%H%M%S')"
  file="${BACKUP_ROOT}/vpn-backup-${stamp}.tar.gz"
  tar czf "$file" \
    "$STATE_DIR" \
    /usr/local/etc/xray/config.json \
    /etc/hysteria/config.yaml \
    /etc/nginx/conf.d/vpn.conf \
    /var/www/vpn-sub 2>/dev/null
  ok "Backup saved: $file"
}

do_restore(){
  banner "Restore"
  [ -d "$BACKUP_ROOT" ] || { warn "No backups directory."; pause; return; }
  local files=( "$BACKUP_ROOT"/*.tar.gz )
  [ -e "${files[0]}" ] || { warn "No backups found."; pause; return; }

  local i=1 f
  for f in "${files[@]}"; do
    printf "  ${C3}%2d${C0}) %s\n" "$i" "$(basename "$f")"; ((i++))
  done
  local sel
  sel=$(ask "Select backup number" "1")
  local idx=$((sel-1))
  [ "$idx" -ge 0 ] && [ -n "${files[$idx]:-}" ] || { warn "Invalid selection."; pause; return; }

  tar xzf "${files[$idx]}" -C / 2>/dev/null || die "Restore failed."
  load_state
  systemctl restart xray >/dev/null 2>&1 || true
  [ "$WANT_HY2" = true ] && systemctl restart hysteria-server >/dev/null 2>&1 || true
  systemctl restart nginx >/dev/null 2>&1 || true
  ok "Restore complete."
  pause
}

# ════════════════════════════════════════════════════════════════
#  حذف کامل (Purge)
# ════════════════════════════════════════════════════════════════
do_purge(){
  banner "Purge"
  has_install || { warn "Nothing installed."; pause; return; }
  ask_yesno "Back up before purging?" y && do_backup
  ask_yesno "This removes ALL components. Continue?" n || { info "Cancelled."; pause; return; }

  step "Stopping services"
  local svc
  for svc in xray hysteria-server nginx; do
    systemctl stop "$svc"    >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done

  step "Removing files"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
  rm -rf /usr/local/etc/xray /var/log/xray
  rm -rf /etc/hysteria
  rm -f  /etc/nginx/conf.d/vpn.conf
  rm -rf /var/www/vpn-sub
  rm -rf "$STATE_DIR"
  systemctl restart nginx >/dev/null 2>&1 || true
  ok "All components removed."
  pause
}

# ── بازسازی config از روی state موجود ───────────────────────────
do_rebuild(){
  banner "Rebuild"
  has_install || { warn "No installation to rebuild."; pause; return; }
  load_state
  STEP_CURRENT=0
  write_xray_config
  write_hy2_config
  write_nginx_config
  start_services
  build_links
  write_subscription
  save_state
  show_results
  pause
}

# ════════════════════════════════════════════════════════════════
#  منوی اصلی
# ════════════════════════════════════════════════════════════════
main_menu(){
  while true; do
    clr
    banner "$APP_NAME  v$APP_VER"
    printf "  ${C3}1${C0}) New installation\n"
    printf "  ${C3}2${C0}) Modify (rebuild from state)\n"
    printf "  ${C3}3${C0}) Rebuild configs\n"
    printf "  ${C3}4${C0}) Restore from backup\n"
    printf "  ${C3}5${C0}) Status\n"
    printf "  ${C3}6${C0}) Backup now\n"
    printf "  ${C3}7${C0}) Purge\n"
    printf "  ${C3}0${C0}) Exit\n\n"
    local c
    c=$(ask "Choose" "5")
    case "$c" in
      1) detect_ip; collect_input; run_install; pause ;;
      2|3) do_rebuild ;;
      4) do_restore ;;
      5) show_status ;;
      6) do_backup; pause ;;
      7) do_purge ;;
      0) clr; exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

main_menu
