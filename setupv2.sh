#!/usr/bin/env bash
# نصب چندپروتکلی: VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
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
# اصلاح باگ: قبلاً سه بک‌اسلش بود و با PORT_IPS[...] هرگز مطابقت نمی‌کرد
RE_EXT='^PORT_IPS\[([0-9]+)\]="?([0-9A-Za-z.,:_-]+)"?$'
# مسیر ساب: فقط یک سگمنت معتبر، بدون اسلش
RE_SUBPATH='^[A-Za-z0-9._-]+$'

# پورت‌های HTTPS رسمی که Cloudflare پروکسی می‌کند
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

# ---------- ثابت‌ها ----------
WS_INT=10001
XHTTP_INT=10002
HY2_SNI="www.bing.com"

# ---------- وضعیت‌ها ----------
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
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
  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  if $WANT_HY2 && ! command -v hysteria >/dev/null 2>&1; then
    bash <(curl -fsSL https://get.hy2.sh/)
  fi
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
}

# جمع‌آوری چند پورت برای Nginx (فقط پورت‌های مجاز Cloudflare)
collect_nginx_ports(){
  NGINX_PORTS=()
  printf "\n${C2}Nginx port(s) — Cloudflare HTTPS only: ${CF_PORTS[*]}${C0}\n" >"$TTY"
  printf "  Enter one port at a time. Press Enter on empty line to finish.\n" >"$TTY"
  local p def dup x
  while true; do
    # پورت اول پیش‌فرض 2096؛ بعد از آن خالی یعنی پایان
    if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then def="2096"; else def=""; fi
    ask p "Nginx port (Enter to finish)" "$def"
    if [ -z "$p" ]; then
      if [ "${#NGINX_PORTS[@]}" -eq 0 ]; then
        warn "At least one port is required."
        continue
      fi
      break
    fi
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then
      warn "Not a number. Try again."
      continue
    fi
    if ! is_cf_port "$p"; then
      warn "$p is not a Cloudflare HTTPS port. Allowed: ${CF_PORTS[*]}"
      continue
    fi
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
  printf "\n${C2}External (CDN clean) proxies${C0}\n" >"$TTY"
  printf "  Paste lines in this EXACT format, one per line:\n" >"$TTY"
  printf '    PORT_IPS[2096]="104.19.184.210,104.27.53.171"\n' >"$TTY"
  printf "  Port MUST be one assigned to Nginx: ${NGINX_PORTS[*]}\n" >"$TTY"
  printf "  IPs should be clean Cloudflare edge IPs.\n" >"$TTY"
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
      if ! $found; then
        warn "Port ${port} is NOT in Nginx list (${NGINX_PORTS[*]}). Ignored."
        continue
      fi
      PORT_IPS["$port"]="$ips"
      EXT_COUNT=$((EXT_COUNT+1))
      ok "Added: port ${port} -> ${ips}"
    else
      warn "Invalid format, ignored: ${line}"
    fi
  done
}

collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"
  HY2_PORT=36712
  REALITY_PORT=8443

  printf "\n${C2}=== Ports ===${C0}\n" >"$TTY"
  printf "  1) Use defaults (Nginx 2096, Hysteria2 36712, Reality 8443)\n" >"$TTY"
  printf "  2) Customize ports\n" >"$TTY"
  ask_choice PORT_MODE "Choice" "1" 1 2

  if [ "$PORT_MODE" = "2" ]; then
    $USE_DOMAIN     && collect_nginx_ports
    $WANT_HY2       && ask_port HY2_PORT "Hysteria2 port (UDP)" "36712"
    $WANT_REALITY   && ask_port REALITY_PORT "Reality port (direct TCP)" "8443"
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

  if $WANT_REALITY; then
    ask_valid SNI "SNI/destination for Reality (a real website)" "$RE_DOMAIN" "www.microsoft.com"
  fi

  # external proxy: پورت‌های Nginx الان قطعی شده‌اند
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

  # مسیر ساب: خالی=رندوم، در غیر این صورت اعتبارسنجی سگمنت
  if $USE_DOMAIN; then
    ask SUB_PATH_IN "Subscription path (Enter for random)" ""
    if [ -n "$SUB_PATH_IN" ]; then
      if [[ "$SUB_PATH_IN" =~ $RE_SUBPATH ]]; then
        SUB_TOKEN="$SUB_PATH_IN"
        ok "Subscription path set to: ${SUB_TOKEN}"
      else
        warn "Invalid path (allowed: letters, digits, . _ - ; no slash). Using random."
        SUB_TOKEN="$(openssl rand -hex 16)"
      fi
    fi
  fi
}
gen_secrets(){
  UUID="$(xray uuid)"
  WS_PATH="/$(openssl rand -hex 4)-ws"
  XHTTP_PATH="/$(openssl rand -hex 4)-xh"
  # اگر کاربر مسیر ساب را تعیین کرده، حفظ شود؛ وگرنه رندوم
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
  "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto" } }
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

# ---------- ساخت کانفیگ Nginx (چند پورت) ----------
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

  # ساخت خطوط listen برای تمام پورت‌های انتخابی
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

  # سرویس رسمی Hysteria2 با کاربر غیرروت اجرا می‌شود و privkey لتس‌انکریپت را
  # نمی‌تواند بخواند؛ با override آن را روت اجرا می‌کنیم.
  mkdir -p /etc/systemd/system/hysteria-server.service.d
  cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOF
[Service]
User=root
Group=root
EOF
  systemctl daemon-reload
  ok "Hysteria2 config written."
}

# ---------- تولید لینک‌ها ----------
gen_links(){
  local port ip
  # PORT_IPS فقط شامل پورت‌های معتبر Nginx است (اعتبارسنجی متقابل انجام شده)
  if $WANT_WS || $WANT_XHTTP; then
    for port in "${!PORT_IPS[@]}"; do
      IFS=',' read -ra _ips <<< "${PORT_IPS[$port]}"
      for ip in "${_ips[@]}"; do
        [ -z "$ip" ] && continue
        if $WANT_WS; then
          LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${WS_PATH}#${CONFIG_NAME}-WS-${ip}-${port}")
        fi
        if $WANT_XHTTP; then
          LINKS+=("vless://${UUID}@${ip}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=xhttp&host=${DOMAIN}&path=${XHTTP_PATH}&mode=auto#${CONFIG_NAME}-XHTTP-${ip}-${port}")
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
  $WANT_REALITY   && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  $WANT_HY2       && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1 || true
  [ "${HY2_CERT:-}" = "le" ] && ufw allow 80/tcp     >/dev/null 2>&1 || true
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
    sleep 1
    systemctl is-active --quiet hysteria-server \
      || warn "Hysteria2 service is not active. Check: journalctl -u hysteria-server -n 30"
  fi
  ok "Services started."
}

print_summary(){
  printf "\n${C2}================ DONE ================${C0}\n" >"$TTY"
  local l
  for l in "${LINKS[@]}"; do
    printf "%s\n\n" "$l" >"$TTY"
  done
  if $USE_DOMAIN; then
    printf "${CG}Nginx ports:${C0} %s\n" "${NGINX_PORTS[*]}" >"$TTY"
    printf "${CG}Subscription URL:${C0}\n%s\n" "${SUB_URL}" >"$TTY"
    printf "${C2}Note:${C0} Cloudflare SSL mode 'Full', domain proxied (orange),\n" >"$TTY"
    printf "      and port one of 443/2053/2083/2087/2096/8443.\n" >"$TTY"
  fi
  printf "${C2}=====================================${C0}\n" >"$TTY"
}

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
