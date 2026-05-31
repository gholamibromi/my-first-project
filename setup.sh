#!/usr/bin/env bash
#==============================================================================
#  All-in-one VPN : VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
#  مخصوص اجرای مستقیم:  bash <(curl -fsSL .../setup.sh)
#  ورودی‌های تعاملی از /dev/tty خوانده می‌شوند تا با pipe/curl هم کار کند
#==============================================================================
set -euo pipefail

# ---------- رنگ‌ها و لاگ ----------
C0='\033[0m'; C1='\033[1;36m'; C2='\033[1;32m'; C3='\033[1;33m'; C4='\033[1;31m'
log(){  printf "${C1}[*]${C0} %s\n" "$*"; }
ok(){   printf "${C2}[+]${C0} %s\n" "$*"; }
warn(){ printf "${C3}[!]${C0} %s\n" "$*"; }
die(){  printf "${C4}[x]${C0} %s\n" "$*" >&2; exit 1; }

# ---------- ورودی تعاملی: همیشه از ترمینال واقعی ----------
# این بخش حیاتی است: با bash <(curl ...) ورودی باید از /dev/tty بیاید
if [ -e /dev/tty ] && (exec </dev/tty) 2>/dev/null; then TTY=/dev/tty
else die "No terminal available. Run interactively, not in a pipe without tty."; fi

ask(){  # ask VAR "prompt" "default"
  local __v="$1" __p="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then printf "${C3}%s${C0} [%s]: " "$__p" "$__d" >"$TTY"
  else printf "${C3}%s${C0}: " "$__p" >"$TTY"; fi
  read -r __a <"$TTY" || true
  [ -z "$__a" ] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}
rand(){ openssl rand -hex "${1:-8}"; }

# ---------- پرچم‌ها ----------
WANT_REALITY=false; WANT_WS=false; WANT_XHTTP=false; WANT_HY2=false
USE_DOMAIN=false

# ---------- پورت‌های داخلی Xray (localhost) ----------
WS_PORT=10002; XH_PORT=10001; WS_PATH="wsvpn"; XH_PATH="xhvpn"
declare -A PORT_IPS USED_TCP USED_UDP

claim_tcp(){ local p="$1" who="$2"
  [ -n "${USED_TCP[$p]:-}" ] && die "TCP port $p conflict: '${USED_TCP[$p]}' vs '$who'."
  USED_TCP[$p]="$who"; }
claim_udp(){ local p="$1" who="$2"
  [ -n "${USED_UDP[$p]:-}" ] && die "UDP port $p conflict: '${USED_UDP[$p]}' vs '$who'."
  USED_UDP[$p]="$who"; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "Please run as root (sudo -i)."; }

install_base(){
  log "Installing prerequisites ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl wget openssl jq ufw socat ca-certificates psmisc iproute2 >/dev/null
  ok "Prerequisites installed."
}

menu_mode(){
  printf "\n${C2}=== What do you want to build? ===${C0}\n" >"$TTY"
  printf "  1) No domain   (VLESS-Reality only)\n" >"$TTY"
  printf "  2) With domain (VLESS-WS + VLESS-XHTTP + Hysteria2)\n" >"$TTY"
  printf "  3) Both        (all protocols)\n" >"$TTY"
  ask MODE "Choose" "1"
  case "$MODE" in
    1) WANT_REALITY=true ;;
    2) WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    3) WANT_REALITY=true; WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    *) die "Invalid option." ;;
  esac
}

collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"

  if $WANT_REALITY; then
    ask REALITY_PORT "Reality port (direct TCP)" "8443"
    ask SNI          "Reality SNI / Target site" "www.microsoft.com"
    claim_tcp "$REALITY_PORT" "Reality"
  fi

  if $USE_DOMAIN; then
    ask DOMAIN "Domain (Cloudflare Orange-Cloud)"
    [ -n "${DOMAIN:-}" ] || die "Domain is required."

    printf "\n${C2}Hysteria2 Certificate:${C0}  1) self-signed   2) Let's Encrypt\n" >"$TTY"
    ask HY2_CERT_CH "Choose" "1"
    if [ "$HY2_CERT_CH" = "2" ]; then
      HY2_CERT="le"; ask HY2_DOMAIN "Hysteria2 Subdomain (Grey-Cloud/DNS-only)"; ask LE_EMAIL "Email for Let's Encrypt"
    else
      HY2_CERT="self"
    fi

    ask HY2_PORT "Hysteria2 port (UDP)" "36712"
    claim_udp "$HY2_PORT" "Hysteria2"

    printf "\n${C2}CDN Ports & Clean IPs:${C0} Format: PORT IPS (empty line to finish)\n" >"$TTY"
    printf "Example: 2096 104.21.0.1,172.67.0.2\n" >"$TTY"
    while true; do
      local line; read -r line <"$TTY" || break
      [ -z "$line" ] && break
      local p ips; p=$(echo "$line" | awk '{print $1}'); ips=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
      { [ -z "$p" ] || [ -z "$ips" ]; } && { warn "Invalid line: $line"; continue; }
      claim_tcp "$p" "Nginx-CDN"; PORT_IPS["$p"]="$ips"
    done
    if [ "${#PORT_IPS[@]}" -eq 0 ]; then claim_tcp "443" "Nginx-CDN"; PORT_IPS["443"]="$DOMAIN"; fi
  fi
  ask CONFIG_NAME "Config identifier (suffix)" "MyVPN"
}

install_cores(){
  log "Installing Xray core ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  ok "Xray installed."
  if $WANT_HY2; then
    log "Installing Hysteria2 ..."; bash <(curl -fsSL https://get.hy2.sh/) >/dev/null; ok "Hysteria2 installed."
  fi
  if $USE_DOMAIN; then log "Installing Nginx ..."; apt-get install -y nginx >/dev/null; ok "Nginx installed."; fi
  if [ "${HY2_CERT:-}" = "le" ]; then apt-get install -y certbot >/dev/null; fi
}

cleanup_old(){
  log "Cleaning old configs to prevent conflicts ..."
  systemctl stop nginx xray hysteria-server 2>/dev/null || true
  if $USE_DOMAIN; then
    grep -rl "$DOMAIN" /etc/nginx/ 2>/dev/null | xargs -r rm -f || true
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  fi
}

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
      systemctl stop nginx 2>/dev/null || true
      certbot certonly --standalone --non-interactive --agree-tos -m "$LE_EMAIL" -d "$HY2_DOMAIN"
      cp "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem" /etc/hysteria/server.crt
      cp "/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"   /etc/hysteria/server.key
      HY2_CRT="/etc/hysteria/server.crt"; HY2_KEY="/etc/hysteria/server.key"
      HY2_SNI="$HY2_DOMAIN"; HY2_CONN="$HY2_DOMAIN"; HY2_INSECURE=0
    else
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -days 3650 -subj "/CN=${DOMAIN:-bing.com}" >/dev/null 2>&1
      HY2_CRT="/etc/hysteria/cert.pem"; HY2_KEY="/etc/hysteria/key.pem"
      HY2_SNI="${DOMAIN:-bing.com}"; HY2_CONN="$SERVER_IP"; HY2_INSECURE=1
    fi
    chown -R nobody:nogroup /etc/hysteria
  fi
}

write_xray(){
  local ib=()
  $WANT_REALITY && ib+=("{\"tag\":\"reality\",\"listen\":\"0.0.0.0\",\"port\":${REALITY_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"${SNI}:443\",\"xver\":0,\"serverNames\":[\"${SNI}\"],\"privateKey\":\"${REALITY_PRIV}\",\"shortIds\":[\"${REALITY_SID}\"]}}}")
  $WANT_WS && ib+=("{\"tag\":\"ws\",\"listen\":\"127.0.0.1\",\"port\":${WS_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/${WS_PATH}\"}}}")
  $WANT_XHTTP && ib+=("{\"tag\":\"xhttp\",\"listen\":\"127.0.0.1\",\"port\":${XH_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\",\"xhttpSettings\":{\"path\":\"/${XH_PATH}\"}}}")
  local joined; joined=$(IFS=,; echo "${ib[*]}")
  mkdir -p /usr/local/etc/xray
  cat >/usr/local/etc/xray/config.json <<EOF
{"log":{"loglevel":"warning"},"inbounds":[${joined}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF
}

write_hysteria(){
  cat >/etc/hysteria/config.yaml <<EOF
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
EOF
}

write_nginx(){
  local LISTENS=""
  for p in "${!PORT_IPS[@]}"; do
    LISTENS+="    listen ${p} ssl;"$'\n'
    LISTENS+="    listen [::]:${p} ssl;"$'\n'
  done
  cat >/etc/nginx/conf.d/vpn.conf <<EOF
server {
${LISTENS}    server_name ${DOMAIN};
    ssl_certificate     /etc/ssl/cdn/cert.pem;
    ssl_certificate_key /etc/ssl/cdn/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
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
        proxy_buffering off;
        proxy_request_buffering off;
    }
    location / { return 200 "OK"; }
}
EOF
}

start_services(){
  log "Configuring firewall and starting services ..."
  ufw allow 22/tcp >/dev/null 2>&1 || true
  for p in "${!USED_TCP[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
  for p in "${!USED_UDP[@]}"; do ufw allow "${p}/udp" >/dev/null 2>&1 || true; done
  yes | ufw enable >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true; systemctl restart xray
  $WANT_HY2 && { systemctl enable hysteria-server >/dev/null 2>&1 || true; systemctl restart hysteria-server; }
  if $USE_DOMAIN; then nginx -t && { systemctl enable nginx >/dev/null 2>&1 || true; systemctl restart nginx; }; fi
  ok "All services started."
}

gen_links(){
  OUT="/root/${CONFIG_NAME}-configs.txt"; : > "$OUT"
  echo "===== ${CONFIG_NAME} Links =====" >> "$OUT"
  $WANT_REALITY && echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&type=tcp&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision#${CONFIG_NAME}-Reality" >> "$OUT"
  $WANT_HY2 && echo "hysteria2://${HY2_PASS}@${HY2_CONN}:${HY2_PORT}?sni=${HY2_SNI}&insecure=${HY2_INSECURE}#${CONFIG_NAME}-HY2" >> "$OUT"
  if $WANT_WS || $WANT_XHTTP; then
    for port in "${!PORT_IPS[@]}"; do
      IFS=',' read -ra ips <<< "${PORT_IPS[$port]}"
      for ip in "${ips[@]}"; do
        ip="$(echo "$ip" | tr -d ' ')"; [ -z "$ip" ] && continue
        $WANT_WS && echo "vless://${UUID}@${ip}:${port}?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=%2F${WS_PATH}#${CONFIG_NAME}-WS-${ip}" >> "$OUT"
        $WANT_XHTTP && echo "vless://${UUID}@${ip}:${port}?encryption=none&security=tls&type=xhttp&host=${DOMAIN}&sni=${DOMAIN}&path=%2F${XH_PATH}&mode=auto#${CONFIG_NAME}-XH-${ip}" >> "$OUT"
      done
    done
  fi
  printf "\n${C2}========== DONE ==========${C0}\n"
  cat "$OUT"
  ok "Configs saved to: $OUT"
}

# ---------- Main ----------
need_root
install_base
menu_mode
collect_inputs
cleanup_old
install_cores
gen_secrets
setup_certs
write_xray
$WANT_HY2 && write_hysteria
$USE_DOMAIN && write_nginx
start_services
gen_links
