#!/usr/bin/env bash
# نصب چندپروتکلی: VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
# UI انگلیسی، کامنت‌ها فارسی. ورودی از /dev/tty خوانده می‌شود.
set -euo pipefail

# ---------- رنگ‌ها و TTY ----------
C0=$'\033[0m'; C1=$'\033[36m'; C2=$'\033[1;33m'; CR=$'\033[31m'; CG=$'\033[32m'
TTY=/dev/tty

ok(){   printf "${CG}[ok]${C0} %s\n" "$*" >"$TTY"; }
warn(){ printf "${C2}[warn]${C0} %s\n" "$*" >"$TTY"; }
die(){  printf "${CR}[err]${C0} %s\n" "$*" >"$TTY"; exit 1; }

# تابع پرسش: نام متغیر، متن، مقدار پیش‌فرض
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
# پرسش بله/خیر با اعتبارسنجی؛ تا جواب معتبر نده دوباره می‌پرسد
ask_yesno(){
  local __var="$1" __prompt="$2" __default="${3:-}" __ans=""
  while true; do
    ask "$__var" "$__prompt (y/n)" "$__default"
    __ans="${!__var}"; __ans="${__ans,,}"
    case "$__ans" in
      y|yes) printf -v "$__var" 'y'; return 0 ;;
      n|no)  printf -v "$__var" 'n'; return 0 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# پرسش انتخاب از بین گزینه‌های مجاز؛ ورودی نامعتبر را رد می‌کند
ask_choice(){
  local __var="$1" __prompt="$2" __default="$3"; shift 3
  local __valid=("$@") __ans="" v
  while true; do
    ask "$__var" "$__prompt" "$__default"
    __ans="${!__var}"
    for v in "${__valid[@]}"; do
      [ "$__ans" = "$v" ] && return 0
    done
    warn "Invalid choice. Allowed: ${__valid[*]}"
  done
}

# ---------- ثابت‌ها ----------
WS_INT=10001          # پورت داخلی WebSocket
XHTTP_INT=10002       # پورت داخلی XHTTP
HY2_SNI="www.bing.com"

# ---------- وضعیت‌ها ----------
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
USE_DOMAIN=false
declare -A PORT_IPS
LINKS=()

# ---------- بررسی روت ----------
[ "$(id -u)" = 0 ] || die "Please run as root."

# ---------- تشخیص پکیج‌منیجر ----------
PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found."

install_deps(){
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y curl openssl jq nginx certbot ufw ca-certificates
      ;;
    dnf|yum)
      $PKG install -y curl openssl jq nginx certbot ufw ca-certificates || true
      ;;
  esac
  # نصب Xray از مخزن رسمی
  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  # نصب Hysteria2 فقط در صورت نیاز
  if $WANT_HY2 && ! command -v hysteria >/dev/null 2>&1; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi
  ok "Dependencies installed."
}

# ---------- منوی انتخاب پروتکل ----------
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
}

# ---------- جمع‌آوری اکسترنال پروکسی (تک‌خطی) ----------
collect_external_proxies(){
  EXT_COUNT=0
  printf "\n${C2}External (CDN clean) proxies${C0}\n" >"$TTY"
  printf "  Paste lines in this exact format, then an empty line to finish:\n" >"$TTY"
  printf '    PORT_IPS[443]="104.19.184.210,104.27.53.171,104.21.127.190"\n' >"$TTY"
  printf '    PORT_IPS[2053]="104.19.184.210,104.27.53.171"\n' >"$TTY"
  printf "  Press Enter on an empty line to skip.\n" >"$TTY"
  local line port ips
  while true; do
    printf "${C1}> ${C0}" >"$TTY"
    read -r line <"$TTY" || break
    line="$(printf '%s' "$line" | tr -d ' ')"
    [ -z "$line" ] && break
    if [[ "$line" =~ ^PORT_IPS\[([0-9]+)\]=\"?([0-9a-zA-Z.,:_-]+)\"?$ ]]; then
      port="${BASH_REMATCH[1]}"; ips="${BASH_REMATCH[2]}"
      PORT_IPS["$port"]="$ips"
      EXT_COUNT=$((EXT_COUNT+1))
      ok "Added: port ${port} -> ${ips}"
    else
      warn "Invalid format, ignored: ${line}"
    fi
  done
}

# ---------- جمع‌آوری همه ورودی‌ها ----------
collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"

  # مقادیر پیش‌فرض پورت‌ها
  NGINX_PORT=2096
  HY2_PORT=36712
  REALITY_PORT=8443

  printf "\n${C2}=== Ports ===${C0}\n" >"$TTY"
  printf "  1) Use defaults (Nginx 2096, Hysteria2 36712, Reality 8443)\n" >"$TTY"
  printf "  2) Customize ports\n" >"$TTY"
  ask PORT_MODE "Choice" "1"

  if [ "$PORT_MODE" = "2" ]; then
    if $USE_DOMAIN; then
      ask NGINX_PORT "Nginx port (CDN origin: 443/2053/2083/2087/2096/8443)" "2096"
    fi
    if $WANT_HY2;     then ask HY2_PORT "Hysteria2 port (UDP)" "36712"; fi
    if $WANT_REALITY; then ask REALITY_PORT "Reality port (direct TCP)" "8443"; fi
  fi

  # دامنه فقط برای WS/XHTTP الزامی است
  if $USE_DOMAIN; then
    ask DOMAIN "Domain for WS/XHTTP (Cloudflare orange-cloud)"
    [ -n "${DOMAIN:-}" ] || die "Domain is required for WS/XHTTP."
  fi

  # گواهی Hysteria2
  if $WANT_HY2; then
    printf "\n${C2}Hysteria2 certificate:${C0} 1) self-signed  2) Let's Encrypt\n" >"$TTY"
    ask_choice HY2_CERT_CH "Choice" "1" 1 2
    if [ "$HY2_CERT_CH" = "2" ]; then
      HY2_CERT="le"
      ask HY2_DOMAIN "Hysteria2 subdomain (grey-cloud / DNS only)"
      ask LE_EMAIL   "Email for Let's Encrypt"
      [ -n "${HY2_DOMAIN:-}" ] || die "Hysteria2 domain required for Let's Encrypt."
    else
      HY2_CERT="self"
    fi
  fi

  # SNI فقط برای Reality
  if $WANT_REALITY; then
    ask SNI "SNI/destination for Reality (a real website)" "www.microsoft.com"
  fi

  # اکسترنال پروکسی‌ها با سینتکس تک‌خطی
    if $WANT_WS || $WANT_XHTTP; then
    while true; do
      collect_external_proxies
      if [ "${EXT_COUNT:-0}" -gt 0 ]; then break; fi
      ask_yesno SURE "No proxies entered. Connect directly to your own domain (${DOMAIN}) on port ${NGINX_PORT}?" "y"
      if [ "$SURE" = "y" ]; then
        PORT_IPS["$NGINX_PORT"]="$DOMAIN"
        warn "Using domain ${DOMAIN} directly on port ${NGINX_PORT}."
        break
      fi
      warn "Let's try entering proxies again."
    done
  fi
fi

  ask CONFIG_NAME "A name for your configs" "MyVPN"
}

# ---------- تولید کلید/شناسه‌ها ----------
gen_secrets(){
  UUID="$(xray uuid)"
  WS_PATH="/$(openssl rand -hex 4)-ws"
  XHTTP_PATH="/$(openssl rand -hex 4)-xh"
  SUB_TOKEN="$(openssl rand -hex 16)"
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
# ---------- ساخت کانفیگ Xray ----------
write_xray(){
  local inbounds=() joined
  mkdir -p /usr/local/etc/xray

  if $WANT_WS; then
    inbounds+=("$(cat <<EOF
{
  "listen": "127.0.0.1",
  "port": ${WS_INT},
  "protocol": "vless",
  "settings": { "clients": [ { "id": "${UUID}" } ], "decryption": "none" },
  "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
}
EOF
)")
  fi

  if $WANT_XHTTP; then
    inbounds+=("$(cat <<EOF
{
  "listen": "127.0.0.1",
  "port": ${XHTTP_INT},
  "protocol": "vless",
  "settings": { "clients": [ { "id": "${UUID}" } ], "decryption": "none" },
  "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "${XHTTP_PATH}" } }
}
EOF
)")
  fi

  if $WANT_REALITY; then
    inbounds+=("$(cat <<EOF
{
  "listen": "0.0.0.0",
  "port": ${REALITY_PORT},
  "protocol": "vless",
  "settings": {
    "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "${SNI}:443",
      "xver": 0,
      "serverNames": [ "${SNI}" ],
      "privateKey": "${REALITY_PRIV}",
      "shortIds": [ "${REALITY_SID}" ]
    }
  }
}
EOF
)")
  fi

  joined="$(IFS=,; echo "${inbounds[*]}")"
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ ${joined} ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF

  xray -test -config /usr/local/etc/xray/config.json >"$TTY" 2>&1 || die "Xray config test failed."
  ok "Xray config written."
}

# ---------- ساخت کانفیگ Nginx ----------
write_nginx(){
  $USE_DOMAIN || return 0
  mkdir -p /etc/ssl/xray /var/www/html /var/www/sub

  # گواهی self-signed برای Nginx (سازگار با Cloudflare Full)
  if [ ! -f /etc/ssl/xray/cert.pem ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/ssl/xray/key.pem -out /etc/ssl/xray/cert.pem \
      -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  fi

  # صفحه پوششی ساده
  echo "<html><body><h1>It works.</h1></body></html>" > /var/www/html/index.html

  # حذف سایت پیش‌فرض دبیان در صورت وجود
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  local ws_block="" xh_block=""
  if $WANT_WS; then
    ws_block=$(cat <<EOF
    location ${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:${WS_INT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
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
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }
EOF
)
  fi

  cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen ${NGINX_PORT} ssl;
    listen [::]:${NGINX_PORT} ssl;
    server_name ${DOMAIN};

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

# ---------- ساخت کانفیگ Hysteria2 ----------
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

  cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${cert_path}
  key: ${key_path}

auth:
  type: password
  password: ${HY2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true
EOF
  ok "Hysteria2 config written."
}

# ---------- تولید لینک‌ها ----------
gen_links(){
  local enc_ws enc_xh port ips ip
  enc_ws="$(printf '%s' "${WS_PATH:-}"   | sed 's:/:%2F:g')"
  enc_xh="$(printf '%s' "${XHTTP_PATH:-}" | sed 's:/:%2F:g')"

  if { $WANT_WS || $WANT_XHTTP; } && [ "${#PORT_IPS[@]}" -gt 0 ]; then
    for port in "${!PORT_IPS[@]}"; do
      IFS=',' read -ra _ips <<< "${PORT_IPS[$port]}"
      for ip in "${_ips[@]}"; do
        [ -z "$ip" ] && continue
        if $WANT_WS; then
          LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_ws}#${CONFIG_NAME}-WS-${ip}")
        fi
        if $WANT_XHTTP; then
          LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=xhttp&host=${DOMAIN}&path=${enc_xh}#${CONFIG_NAME}-XHTTP-${ip}")
        fi
      done
    done
  fi

  if $WANT_REALITY; then
    LINKS+=("vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision&type=tcp#${CONFIG_NAME}-Reality")
  fi

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

# ---------- ساخت لینک اشتراک (Base64) ----------
gen_subscription(){
  $USE_DOMAIN || return 0
  mkdir -p /var/www/sub
  printf '%s\n' "${LINKS[@]}" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt"
  SUB_URL="https://${DOMAIN}:${NGINX_PORT}/sub/${SUB_TOKEN}"
  ok "Subscription file created."
}

# ---------- فایروال ----------
open_firewall(){
  command -v ufw >/dev/null 2>&1 || return 0
  $USE_DOMAIN     && ufw allow "${NGINX_PORT}/tcp"   >/dev/null 2>&1 || true
  $WANT_REALITY   && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  $WANT_HY2       && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1 || true
  [ "${HY2_CERT:-}" = "le" ] && ufw allow 80/tcp     >/dev/null 2>&1 || true
}

# ---------- راه‌اندازی سرویس‌ها ----------
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
  fi
  ok "Services started."
}

# ---------- خروجی نهایی ----------
print_summary(){
  printf "\n${C2}================ DONE ================${C0}\n" >"$TTY"
  local l
  for l in "${LINKS[@]}"; do
    printf "%s\n\n" "$l" >"$TTY"
  done
  if $USE_DOMAIN; then
    printf "${CG}Subscription URL:${C0}\n%s\n" "${SUB_URL}" >"$TTY"
  fi
  printf "${C2}=====================================${C0}\n" >"$TTY"
}

# ---------- جریان اصلی ----------
main(){
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
