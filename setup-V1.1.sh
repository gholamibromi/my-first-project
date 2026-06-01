#!/usr/bin/env bash
# نصب چندپروتکلی: VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
# + Sniffing + WARP outbound + Routing + Multi-address subscription
# UI انگلیسی، کامنت‌ها فارسی. ورودی از /dev/tty خوانده می‌شود.
set -euo pipefail

# ---------- رنگ‌ها و TTY ----------
C0=$'\033[0m'; C1=$'\033[36m'; C2=$'\033[1;33m'; CR=$'\033[31m'; CG=$'\033[32m'
TTY=/dev/tty

ok(){   printf "${CG}[ok]${C0} %s\n"   "$*" >"$TTY"; }
warn(){ printf "${C2}[warn]${C0} %s\n" "$*" >"$TTY"; }
die(){  printf "${CR}[err]${C0} %s\n"  "$*" >"$TTY"; exit 1; }

MAX_TRIES=3

RE_DOMAIN='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'
RE_EMAIL='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
RE_EXT='^PORT_IPS\[([0-9]+)\]="?([0-9A-Za-z.,:_-]+)"?$'
RE_SUBPATH='^[A-Za-z0-9._-]+$'

CF_PORTS=(443 2053 2083 2087 2096 8443)

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
    __ans="${!__var}"
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
    __ans="${!__var}"
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
  [ "$EX_CH" = "2" ] && { ok "Aborted. Nothing changed."; exit 0; }

  backup_existing
  cleanup_existing
}

backup_existing(){
  local ts bdir
  ts="$(date +%Y%m%d-%H%M%S)"; bdir="/root/vpn-backup-${ts}"
  mkdir -p "$bdir"
  cp -a /usr/local/etc/xray/config.json "$bdir/" 2>/dev/null || true
  cp -a /etc/nginx/conf.d               "$bdir/nginx-conf.d" 2>/dev/null || true
  cp -a /etc/hysteria/config.yaml       "$bdir/" 2>/dev/null || true
  cp -a /var/www/sub                    "$bdir/sub" 2>/dev/null || true
  ok "Old configs backed up to: ${bdir}"
}

cleanup_existing(){
  # توقف و غیرفعال‌سازی همه سرویس‌های مرتبط
  local svc
  for svc in xray nginx hysteria-server hysteria; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  # حذف کامل کانفیگ و سکرت‌های Xray
  rm -rf /usr/local/etc/xray 2>/dev/null || true

  # حذف فایل‌های Nginx ساخته‌شده توسط اسکریپت
  rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  # هر فایل conf.d که به بک‌اند داخلی یا مسیر ساب ما اشاره دارد
  local f
  for f in /etc/nginx/conf.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE '127\.0\.0\.1:(10001|10002)|/var/www/sub' "$f" 2>/dev/null; then
      rm -f "$f"
      warn "Removed leftover nginx file: $f"
    fi
  done

  # حذف فایل‌های وب و گواهی self-signed مربوط به Xray
  rm -rf /var/www/sub 2>/dev/null || true
  rm -f  /var/www/html/index.html 2>/dev/null || true
  rm -rf /etc/ssl/xray 2>/dev/null || true

  # حذف Hysteria2 — گواهی Let's Encrypt در /etc/letsencrypt دست‌نخورده می‌ماند
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
# ---------- ثابت‌ها ----------
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"
WARP_PORT=40000

# ---------- وضعیت‌ها ----------
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
WANT_WARP=false
USE_DOMAIN=false
NGINX_PORTS=()
declare -A PORT_IPS
EXT_COUNT=0
SUB_TOKEN=""
LINKS=()
[ "$(id -u)" = 0 ] || die "Please run as root."

PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found."

tune_kernel(){
  # افزایش بافر UDP برای QUIC/Hysteria2 — رفع کندی و بخشی از مشکل -1 ping
  cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
EOF
  # فعال‌سازی BBR در صورت پشتیبانی کرنل
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
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
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
  # ثبت و اتصال WARP در حالت proxy روی 127.0.0.1:40000
  warp-cli --accept-tos registration new 2>/dev/null \
    || warp-cli --accept-tos register 2>/dev/null || true
  warp-cli --accept-tos mode proxy 2>/dev/null \
    || warp-cli set-mode proxy 2>/dev/null || true
  warp-cli --accept-tos connect 2>/dev/null \
    || warp-cli connect 2>/dev/null || true
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
      apt-get install -y curl openssl jq nginx certbot ufw ca-certificates gnupg
      ;;
    dnf|yum)
      $PKG install -y curl openssl jq nginx certbot ufw ca-certificates || true
      ;;
  esac

  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  if $WANT_HY2 && ! command -v hysteria >/dev/null 2>&1; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi
  $WANT_WARP && install_warp
  $WANT_HY2  && tune_kernel
  ok "Dependencies installed."
}
menu_mode(){
  printf "\n${C2}=== Select protocols ===${C0}\n" >"$TTY"
  printf "  1) All (WS + XHTTP + Reality + Hysteria2)\n" >"$TTY"
  printf "  2) CDN only (WS + XHTTP)\n" >"$TTY"
  printf "  3) Reality only\n" >"$TTY"
  printf "  4) Hysteria2 only\n" >"$TTY"
  printf "  5) Custom\n" >"$TTY"
  ask_choice MODE "Choice" "1" 1 2 3 4 5
  case "$MODE" in
    1) WANT_WS=true; WANT_XHTTP=true; WANT_REALITY=true; WANT_HY2=true ;;
    2) WANT_WS=true; WANT_XHTTP=true ;;
    3) WANT_REALITY=true ;;
    4) WANT_HY2=true ;;
    5)
      local a
      ask_yesno a "Enable VLESS-WS?"    "y"; [ "$a" = y ] && WANT_WS=true
      ask_yesno a "Enable VLESS-XHTTP?" "y"; [ "$a" = y ] && WANT_XHTTP=true
      ask_yesno a "Enable Reality?"     "y"; [ "$a" = y ] && WANT_REALITY=true
      ask_yesno a "Enable Hysteria2?"   "y"; [ "$a" = y ] && WANT_HY2=true
      ;;
  esac
  if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; fi
  $WANT_WS || $WANT_XHTTP || $WANT_REALITY || $WANT_HY2 || die "Nothing selected."

  local w
  ask_yesno w "Enable WARP outbound for blocked sites (Google/OpenAI/Spotify/Netflix...)?" "y"
  [ "$w" = y ] && WANT_WARP=true
}

# ---------- منوی عددی uTLS ----------
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
  ask_choice FP_NUM "Choice" "1" 1 2 3 4 5 6 7 8
  case "$FP_NUM" in
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
  local p def dup x
  while true; do
    if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then def="2096"; else def=""; fi
    ask p "Nginx port (Enter to finish)" "$def"
    if [ -z "$p" ]; then
      if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then warn "At least one port is required."; continue; fi
      break
    fi
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then warn "Not a number. Try again."; continue; fi
    if ! is_cf_port "$p"; then warn "$p is not a Cloudflare HTTPS port. Allowed: ${CF_PORTS[*]}"; continue; fi
    dup=false
    for x in "${NGINX_PORTS[@]}"; do [ "$x" = "$p" ] && dup=true && break; done
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
  printf "  Port MUST be one assigned to Nginx: ${NGINX_PORTS[*]}\n" >"$TTY"
  printf "  Finish with an empty line. Leave empty to skip.\n" >"$TTY"
  local line port ips found p
  while true; do
    printf "${C1}> ${C0}" >"$TTY"
    read -r line <"$TTY" || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && break
    if [[ "$line" =~ $RE_EXT ]]; then
      port="${BASH_REMATCH[1]}"; ips="${BASH_REMATCH[2]}"
      found=false
      for p in "${NGINX_PORTS[@]}"; do [ "$port" = "$p" ] && found=true && break; done
      if ! $found; then warn "Port ${port} is NOT in Nginx list (${NGINX_PORTS[*]}). Ignored."; continue; fi
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
  ask_choice PORT_MODE "Choice" "1" 1 2

  if [ "$PORT_MODE" = "2" ]; then
    $USE_DOMAIN   && collect_nginx_ports
    $WANT_HY2     && ask_port HY2_PORT "Hysteria2 port (UDP)" "36712"
    $WANT_REALITY && ask_port REALITY_PORT "Reality port (direct TCP)" "8443"
  else
    $USE_DOMAIN && NGINX_PORTS=(2096)
  fi

  if $USE_DOMAIN; then
    ask_valid DOMAIN "Domain for WS/XHTTP (Cloudflare orange-cloud)" "$RE_DOMAIN"
  fi

  if $WANT_HY2; then
    printf "\n${C2}Hysteria2 certificate:${C0} 1) self-signed  2) Let's Encrypt\n" >"$TTY"
    ask_choice HY2_CERT_CH "Choice" "1" 1 2
    if [ "$HY2_CERT_CH" = "2" ]; then
      HY2_CERT="le"
      ask_valid HY2_DOMAIN "Hysteria2 subdomain (grey-cloud / DNS only)" "$RE_DOMAIN"
      ask_valid LE_EMAIL   "Email for Let's Encrypt" "$RE_EMAIL"
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
      ask_yesno SURE "No proxies entered. Connect directly to ${DOMAIN} on port ${NGINX_PORTS[0]}?" "y"
      if [ "$SURE" = "y" ]; then
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
    if [ -n "$SUB_PATH_IN" ]; then
      if [[ "$SUB_PATH_IN" =~ $RE_SUBPATH ]]; then
        SUB_TOKEN="$SUB_PATH_IN"; ok "Subscription path set to: ${SUB_TOKEN}"
      else
        warn "Invalid path (no slash). Using random."
        SUB_TOKEN="$(openssl rand -hex 16)"
      fi
    fi
  fi
}

gen_secrets(){
  UUID="$(xray uuid)"
  WS_PATH="/$(openssl rand -hex 4)-ws"
  XHTTP_PATH="/$(openssl rand -hex 4)-xh"
  SUB_TOKEN="${SUB_TOKEN:-$(openssl rand -hex 16)}"
  HY2_PASS="$(openssl rand -hex 12)"

  if $WANT_REALITY; then
    local keys
    keys="$(xray x25519)"
    REALITY_PRIV="$(echo "$keys" | grep -i 'private' | awk '{print $NF}')"
    REALITY_PUB="$(echo "$keys"  | grep -i 'public'  | awk '{print $NF}')"
    REALITY_SID="$(openssl rand -hex 8)"
  fi
  ok "Secrets generated."
}
write_xray(){
  local inbounds=() joined
  mkdir -p /usr/local/etc/xray

  # بلوک Sniffing مشترک همه inboundها
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
    inbounds+=("$(cat <<EOF
{
  "listen":"0.0.0.0","port":${REALITY_PORT},"protocol":"vless","tag":"in-reality",
  "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{"network":"tcp","security":"reality",
    "realitySettings":{"show":false,"dest":"${SNI}:443","xver":0,
      "serverNames":["${SNI}"],"privateKey":"${REALITY_PRIV}","shortIds":["${REALITY_SID}"]}},
  ${SNIFF}
}
EOF
)")
  fi

  joined="$(IFS=,; echo "${inbounds[*]}")"

  # ---------- outbounds ----------
  local OUTBOUNDS WARP_RULE=""
  if $WANT_WARP; then
    OUTBOUNDS='[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"},{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":'"${WARP_PORT}"'}]}}]'
    WARP_RULE='{"type":"field","outboundTag":"warp","domain":["geosite:google","geosite:openai","geosite:netflix","geosite:spotify","domain:claude.ai","domain:anthropic.com","domain:chatgpt.com"]},'
  else
    OUTBOUNDS='[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]'
  fi

  # ---------- routing: block torrent + block private + direct داخلی ----------
  local ROUTING
  ROUTING=$(cat <<EOF
{
  "domainStrategy":"IPIfNonMatch",
  "rules":[
    ${WARP_RULE}
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"},
    {"type":"field","outboundTag":"block","ip":["geoip:private"]},
    {"type":"field","outboundTag":"direct","domain":["geosite:category-ir"]},
    {"type":"field","outboundTag":"direct","ip":["geoip:ir"]}
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
  ok "Xray config written (sniffing + routing$([ "$WANT_WARP" = true ] && echo ' + WARP'))."
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

  local listens="" p
  for p in "${NGINX_PORTS[@]}"; do
    listens+="    listen ${p} ssl;"$'\n'
    listens+="    listen [::]:${p} ssl;"$'\n'
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

  cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
${listens}    server_name ${DOMAIN};

    ssl_certificate     /etc/ssl/xray/cert.pem;
    ssl_certificate_key /etc/ssl/xray/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

${ws_block}
${xh_block}

    location = /sub/${SUB_TOKEN} {
        default_type text/plain;
        alias /var/www/sub/${SUB_TOKEN}.txt;
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

  local cert_path key_path
  if [ "$HY2_CERT" = "le" ]; then
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -d "$HY2_DOMAIN" \
      --non-interactive --agree-tos -m "$LE_EMAIL" || die "Let's Encrypt failed."
    cert_path="/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
    key_path="/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
  else
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

  # سرویس رسمی با کاربر غیرروت اجرا می‌شود و privkey لتس‌انکریپت را نمی‌خواند؛ روت اجرا می‌کنیم
  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOF
[Service]
User=root
Group=root
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
EOF
  systemctl daemon-reload

  # تست صحت کانفیگ قبل از استارت
  hysteria server -c /etc/hysteria/config.yaml --disable-update-check check >"$TTY" 2>&1 \
    || warn "Hysteria2 config check reported issues (continuing)."
  ok "Hysteria2 config written (QUIC tuned$([ "$WANT_WARP" = true ] && echo ' + WARP'))."
}
gen_links(){
  local port ip
  # چند آدرس در ساب: هر IP در هر پورت یک لینک مستقل می‌سازد (افزونگی در برابر فیلتر)
  if $WANT_WS || $WANT_XHTTP; then
    for port in "${!PORT_IPS[@]}"; do
      IFS=',' read -ra _ips <<< "${PORT_IPS[$port]}"
      for ip in "${_ips[@]}"; do
        [ -z "$ip" ] && continue
        $WANT_WS && LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=${FP}&type=ws&host=${DOMAIN}&path=${WS_PATH}#${CONFIG_NAME}-WS-${ip}-${port}")
        $WANT_XHTTP && LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=${FP}&type=xhttp&host=${DOMAIN}&path=${XHTTP_PATH}&mode=auto#${CONFIG_NAME}-XHTTP-${ip}-${port}")
      done
    done
  fi

  $WANT_REALITY && LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision&type=tcp#${CONFIG_NAME}-Reality")

  if $WANT_HY2; then
    local h_host h_sni h_ins
    if [ "$HY2_CERT" = "le" ]; then
      h_host="$HY2_DOMAIN"; h_sni="$HY2_DOMAIN"; h_ins=0
    else
      h_host="$SERVER_IP"; h_sni="$HY2_SNI"; h_ins=1
    fi
    LINKS+=("hysteria2://${HY2_PASS}@${h_host}:${HY2_PORT}/?sni=${h_sni}&insecure=${h_ins}#${CONFIG_NAME}-HY2")
  fi
}

gen_subscription(){
  $USE_DOMAIN || return 0
  mkdir -p /var/www/sub
  printf '%s\n' "${LINKS[@]}" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt"
  SUB_URL="https://${DOMAIN}:${NGINX_PORTS[0]}/sub/${SUB_TOKEN}"
  ok "Subscription file created."
}

open_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  if $USE_DOMAIN; then
    local p; for p in "${NGINX_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
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
      # تأیید گوش‌دادن روی UDP
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
  printf "\n${C2}================ DONE ================${C0}\n" >"$TTY"
  local l
  for l in "${LINKS[@]}"; do printf "%s\n\n" "$l" >"$TTY"; done
  if $USE_DOMAIN; then
    printf "${CG}Nginx ports:${C0} %s\n" "${NGINX_PORTS[*]}" >"$TTY"
    printf "${CG}Subscription URL:${C0}\n%s\n" "${SUB_URL}" >"$TTY"
    printf "${C2}Note:${C0} Cloudflare SSL 'Full', orange-cloud, port in 443/2053/2083/2087/2096/8443.\n" >"$TTY"
  fi
  if $WANT_HY2; then
    printf "${C2}HY2 tip:${C0} '-1 ping' is often just the client's TCP/ICMP test;\n" >"$TTY"
    printf "         use 'Real Delay / Test URL'. If it truly fails, open UDP/${HY2_PORT}\n" >"$TTY"
    printf "         in your CLOUD PROVIDER firewall (not just ufw).\n" >"$TTY"
  fi
  $WANT_WARP && printf "${CG}WARP:${C0} active for Google/OpenAI/Netflix/Spotify/Claude.\n" >"$TTY"
  printf "${C2}=====================================${C0}\n" >"$TTY"
}

main(){
  preflight_check
  menu_mode
  collect_inputs
  install_deps
  gen_secrets
  write_xray
  write_nginx
  write_hysteria
  gen_links
  gen_subscription
  open_firewall
  start_services
  print_summary
}

main "$@"
