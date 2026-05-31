#!/usr/bin/env bash
#==============================================================================
#  All-in-one VPN : VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
#  Fresh Debian/Ubuntu server. Run:
#    bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup.sh)
#==============================================================================
set -euo pipefail

C0='\033[0m'; C1='\033[1;36m'; C2='\033[1;32m'; C3='\033[1;33m'; C4='\033[1;31m'
log(){  printf "${C1}[*]${C0} %s\n" "$*"; }
ok(){   printf "${C2}[+]${C0} %s\n" "$*"; }
warn(){ printf "${C3}[!]${C0} %s\n" "$*"; }
die(){  printf "${C4}[x]${C0} %s\n" "$*" >&2; exit 1; }

TTY=/dev/tty
[ -r "$TTY" ] || TTY=/dev/stdin
ask(){  # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then printf "${C3}%s${C0} [%s]: " "$__p" "$__d" >"$TTY"
  else printf "${C3}%s${C0}: " "$__p" >"$TTY"; fi
  read -r __a <"$TTY" || true
  [ -z "$__a" ] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}
rand(){ openssl rand -hex "${1:-8}"; }
free_port(){ command -v fuser >/dev/null 2>&1 && fuser -k "${1}/${2:-tcp}" 2>/dev/null || true; }

# ---------- internal fixed values ----------
WS_PORT=10002; XH_PORT=10001
WS_PATH="wsvpn"; XH_PATH="xhvpn"
declare -A PORT_IPS

# ---------- initialize ALL vars (required by set -u) ----------
MODE=""
WANT_REALITY=false; WANT_WS=false; WANT_XHTTP=false; WANT_HY2=false; USE_DOMAIN=false
DOMAIN=""; HY2_DOMAIN=""; LE_EMAIL=""
HY2_CERT="self"; HY2_CERT_CH="1"
NGINX_PORT="2096"; HY2_PORT="36712"; REALITY_PORT="8443"
SNI="www.microsoft.com"; CONFIG_NAME="MyVPN"
UUID=""; REALITY_PRIV=""; REALITY_PUB=""; REALITY_SID=""; HY2_PASS=""
HY2_CRT=""; HY2_KEY=""; HY2_SNI=""; HY2_CONN=""; HY2_INSECURE=1
SERVER_IP=""; OUT=""

need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i)"; }

install_base(){
  log "Updating system and installing prerequisites ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget openssl jq ufw socat ca-certificates psmisc lsof
  ok "Prerequisites installed"
}

# ---------- mode menu ----------
menu_mode(){
  printf "\n${C2}=== Which config do you want to build? ===${C0}\n" >"$TTY"
  printf "  1) Reality only (no domain)\n" >"$TTY"
  printf "  2) Domain based (VLESS-WS + VLESS-XHTTP + Hysteria2)\n" >"$TTY"
  printf "  3) All protocols\n" >"$TTY"
  ask MODE "Select" "1"
  case "$MODE" in
    1) WANT_REALITY=true ;;
    2) WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    3) WANT_REALITY=true; WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    *) die "Invalid option" ;;
  esac
}

# ---------- collect inputs ----------
collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

  if $USE_DOMAIN; then
    ask DOMAIN "Domain for WS/XHTTP (Cloudflare orange-cloud / proxied)"
    [ -n "$DOMAIN" ] || die "Domain is required"

    printf "\n${C2}Hysteria2 certificate:${C0} 1) self-signed  2) Let's Encrypt\n" >"$TTY"
    ask HY2_CERT_CH "Select" "1"
    if [ "$HY2_CERT_CH" = "2" ]; then
      HY2_CERT="le"
      ask HY2_DOMAIN "Hysteria2 subdomain (Cloudflare grey-cloud / DNS only)"
      [ -n "$HY2_DOMAIN" ] || die "HY2 subdomain is required for Let's Encrypt"
      ask LE_EMAIL "Email for Let's Encrypt"
    else
      HY2_CERT="self"
    fi

    ask NGINX_PORT "Nginx CDN-origin port (443/2053/2083/2087/2096/8443)" "2096"
    ask HY2_PORT   "Hysteria2 port (UDP)" "36712"
  fi

  if $WANT_REALITY; then
    ask REALITY_PORT "Reality port (direct TCP)" "8443"
    ask SNI          "Reality SNI / dest (a real website)" "www.microsoft.com"
  fi

  if $WANT_WS || $WANT_XHTTP; then
    printf "\n${C2}Clean IPs per port.${C0} Format: PORT IP1,IP2  (empty line to finish)\n" >"$TTY"
    printf "  Example: 8443 104.21.0.1,172.67.0.2\n" >"$TTY"
    local line port ips
    while true; do
      read -r line <"$TTY" || break
      [ -z "$line" ] && break
      port="$(awk '{print $1}' <<<"$line")"
      ips="$(awk '{print $2}' <<<"$line")"
      if [[ "$port" =~ ^[0-9]+$ ]] && [ -n "$ips" ]; then
        PORT_IPS["$port"]="$ips"
      else
        warn "Invalid line skipped: $line"
      fi
    done
    [ "${#PORT_IPS[@]}" -gt 0 ] || PORT_IPS["$NGINX_PORT"]="$DOMAIN"
  fi

  ask CONFIG_NAME "A name for the configs" "MyVPN"
}

# ---------- validate ports ----------
validate_ports(){
  if $USE_DOMAIN; then
    for p in "$NGINX_PORT" "${!PORT_IPS[@]}"; do
      [ "$p" = "22" ] && die "Port 22 is reserved for SSH"
      if $WANT_REALITY && [ "$p" = "$REALITY_PORT" ]; then
        die "Reality port ($REALITY_PORT) conflicts with an Nginx/CDN port"
      fi
    done
  fi
}

# ---------- install cores ----------
install_cores(){
  systemctl stop xray 2>/dev/null || true
  systemctl stop hysteria-server 2>/dev/null || true
  log "Installing Xray ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  ok "Xray installed"
  if $WANT_HY2; then
    log "Installing Hysteria2 ..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
    ok "Hysteria2 installed"
  fi
  if $USE_DOMAIN; then
    log "Installing Nginx ..."
    apt-get install -y nginx >/dev/null
    systemctl stop nginx 2>/dev/null || true
    ok "Nginx installed"
  fi
  [ "$HY2_CERT" = "le" ] && apt-get install -y certbot >/dev/null || true
}

# ---------- secrets ----------
gen_secrets(){
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  if $WANT_REALITY; then
    local kp; kp="$(xray x25519)"
    REALITY_PRIV="$(echo "$kp" | grep -i private | awk '{print $NF}')"
    REALITY_PUB="$(echo "$kp"  | grep -i public  | awk '{print $NF}')"
    REALITY_SID="$(rand 8)"
  fi
  $WANT_HY2 && HY2_PASS="$(rand 16)"
}

# ---------- certificates ----------
setup_certs(){
  if $USE_DOMAIN; then
    mkdir -p /etc/ssl/cdn
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/ssl/cdn/key.pem -out /etc/ssl/cdn/cert.pem \
      -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  fi
  if $WANT_HY2; then
    mkdir -p /etc/hysteria
    if [ "$HY2_CERT" = "le" ]; then
      free_port 80 tcp
      certbot certonly --standalone --non-interactive --agree-tos \
        -m "$LE_EMAIL" -d "$HY2_DOMAIN"
      HY2_CRT="/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
      HY2_KEY="/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
      HY2_SNI="$HY2_DOMAIN"; HY2_CONN="$HY2_DOMAIN"; HY2_INSECURE=0
    else
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -days 3650 -subj "/CN=${DOMAIN:-bing.com}" >/dev/null 2>&1
      HY2_CRT="/etc/hysteria/cert.pem"; HY2_KEY="/etc/hysteria/key.pem"
      HY2_SNI="${DOMAIN:-bing.com}"; HY2_CONN="$SERVER_IP"; HY2_INSECURE=1
    fi
  fi
}
# ---------- Xray config ----------
write_xray(){
  log "Writing Xray config ..."
  mkdir -p /usr/local/etc/xray
  local inbounds=""

  if $WANT_REALITY; then
    free_port "$REALITY_PORT" tcp
    inbounds+=$(cat <<JSON
    {
      "tag":"reality","listen":"0.0.0.0","port":${REALITY_PORT},"protocol":"vless",
      "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "streamSettings":{"network":"tcp","security":"reality",
        "realitySettings":{"show":false,"dest":"${SNI}:443","xver":0,
          "serverNames":["${SNI}"],"privateKey":"${REALITY_PRIV}","shortIds":["${REALITY_SID}"]}}
    },
JSON
)
  fi
  if $WANT_WS; then
    inbounds+=$(cat <<JSON
    {
      "tag":"ws","listen":"127.0.0.1","port":${WS_PORT},"protocol":"vless",
      "settings":{"clients":[{"id":"${UUID}"}],"decryption":"none"},
      "streamSettings":{"network":"ws","security":"none",
        "wsSettings":{"path":"/${WS_PATH}"}}
    },
JSON
)
  fi
  if $WANT_XHTTP; then
    inbounds+=$(cat <<JSON
    {
      "tag":"xhttp","listen":"127.0.0.1","port":${XH_PORT},"protocol":"vless",
      "settings":{"clients":[{"id":"${UUID}"}],"decryption":"none"},
      "streamSettings":{"network":"xhttp","security":"none",
        "xhttpSettings":{"path":"/${XH_PATH}"}}
    },
JSON
)
  fi
  inbounds="${inbounds%,}"

  cat >/usr/local/etc/xray/config.json <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[
${inbounds}
  ],
  "outbounds":[{"protocol":"freedom","tag":"direct"}]
}
JSON
  ok "Xray config written"
}

# ---------- Hysteria2 config ----------
write_hysteria(){
  $WANT_HY2 || return 0
  log "Writing Hysteria2 config ..."
  free_port "$HY2_PORT" udp
  cat >/etc/hysteria/config.yaml <<YAML
listen: :${HY2_PORT}
tls:
  cert: ${HY2_CRT}
  key: ${HY2_KEY}
auth:
  type: password
  password: ${HY2_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
YAML
  ok "Hysteria2 config written"
}

# ---------- Nginx config (with conflict cleanup) ----------
write_nginx(){
  $USE_DOMAIN || return 0
  log "Writing Nginx config ..."

  # remove ALL previous configs to avoid 'conflicting server name'
  rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true
  rm -f /etc/nginx/sites-available/* 2>/dev/null || true
  rm -f /etc/nginx/conf.d/*.conf 2>/dev/null || true

  # build listen directives, deduplicated
  declare -A SEEN
  local listens=""
  for p in "$NGINX_PORT" "${!PORT_IPS[@]}"; do
    [ -n "${SEEN[$p]:-}" ] && continue
    SEEN[$p]=1
    free_port "$p" tcp
    listens+="    listen ${p} ssl;
    listen [::]:${p} ssl;
"
  done

  cat >/etc/nginx/conf.d/vpn.conf <<NGINX
server {
${listens}    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/ssl/cdn/cert.pem;
    ssl_certificate_key /etc/ssl/cdn/key.pem;

    location /${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /${XH_PATH} {
        proxy_pass http://127.0.0.1:${XH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location / { return 200 "ok"; }
}
NGINX

  nginx -t >/dev/null 2>&1 || die "Nginx config test failed (run: nginx -t)"
  ok "Nginx config written"
}
# ---------- Firewall (ufw) ----------
setup_firewall(){
  log "Configuring firewall (ufw) ..."
  command -v ufw >/dev/null 2>&1 || { warn "ufw not found, skipping"; return 0; }

  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming  >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1

  ufw allow 22/tcp >/dev/null 2>&1            # SSH

  if $USE_DOMAIN; then
    declare -A FW_SEEN
    for p in "$NGINX_PORT" "${!PORT_IPS[@]}"; do
      [ -n "${FW_SEEN[$p]:-}" ] && continue
      FW_SEEN[$p]=1
      ufw allow "${p}/tcp" >/dev/null 2>&1    # Nginx / CDN
    done
  fi

  $WANT_REALITY && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1
  $WANT_HY2      && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1

  ufw --force enable >/dev/null 2>&1
  ok "Firewall rules applied"
}

# ---------- Start services ----------
start_services(){
  log "Starting services ..."
  systemctl daemon-reload

  systemctl enable --now xray >/dev/null 2>&1
  systemctl restart xray
  systemctl is-active --quiet xray || die "xray failed to start (journalctl -u xray)"
  ok "xray running"

  if $USE_DOMAIN; then
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl restart nginx
    systemctl is-active --quiet nginx || die "nginx failed to start (journalctl -u nginx)"
    ok "nginx running"
  fi

  if $WANT_HY2; then
    systemctl enable --now hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server
    systemctl is-active --quiet hysteria-server || die "hysteria failed to start"
    ok "hysteria running"
  fi
}

# ---------- Output share links ----------
print_links(){
  echo
  echo "=================== CONNECTION INFO ==================="
  echo "UUID : ${UUID}"
  $USE_DOMAIN && echo "Domain : ${DOMAIN}"
  echo "Server IP : ${SERVER_IP}"
  echo "-------------------------------------------------------"

  if $WANT_REALITY; then
    echo
    echo "[ VLESS Reality ]"
    echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp&flow=xtls-rprx-vision#Reality"
  fi

  if $WANT_WS; then
    echo
    echo "[ VLESS WS + TLS (via CDN) ]"
    echo "vless://${UUID}@${DOMAIN}:${NGINX_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=%2F${WS_PATH}#WS-TLS"
  fi

  if $WANT_XHTTP; then
    echo
    echo "[ VLESS XHTTP + TLS ]"
    echo "vless://${UUID}@${DOMAIN}:${NGINX_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=xhttp&host=${DOMAIN}&path=%2F${XH_PATH}#XHTTP"
  fi

  if $WANT_HY2; then
    echo
    echo "[ Hysteria2 ]"
    echo "hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${DOMAIN:-$SERVER_IP}#Hysteria2"
  fi

  echo
  echo "======================================================="
}

# ---------- Main ----------
main(){
  base_install      # نصب پکیج‌های پایه (psmisc, lsof, curl, ...)
  cleanup_old       # حذف کانفیگ‌های قدیمی و توقف سرویس‌ها
  ask_inputs        # دریافت ورودی‌ها (انگلیسی)
  validate_ports    # جلوگیری از تداخل پورت‌ها
  gen_secrets       # ساخت UUID / کلیدهای Reality / پسورد Hysteria
  install_xray
  $WANT_HY2 && install_hysteria
  write_xray
  write_hysteria
  $USE_DOMAIN && issue_cert
  write_nginx
  setup_firewall
  start_services
  print_links
  ok "All done."
}

main "$@"
