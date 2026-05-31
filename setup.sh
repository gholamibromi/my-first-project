#!/usr/bin/env bash
#==============================================================================
#  All-in-one VPN  :  VLESS-WS / VLESS-XHTTP / VLESS-Reality / Hysteria2
#  تعاملی - روی سرور تازه Debian/Ubuntu - بدون نیاز به هیچ پیش‌نیازی
#  اجرا:  bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup.sh)
#==============================================================================
set -euo pipefail

C0='\033[0m'; C1='\033[1;36m'; C2='\033[1;32m'; C3='\033[1;33m'; C4='\033[1;31m'
log(){  printf "${C1}[*]${C0} %s\n" "$*"; }
ok(){   printf "${C2}[+]${C0} %s\n" "$*"; }
warn(){ printf "${C3}[!]${C0} %s\n" "$*"; }
die(){  printf "${C4}[x]${C0} %s\n" "$*" >&2; exit 1; }

TTY=/dev/tty
[ -r "$TTY" ] || TTY=/dev/stdin     # fallback اگر ترمینال نبود
ask(){  # ask VAR "متن" "پیش‌فرض"
  local __v="$1" __p="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then printf "${C3}%s${C0} [%s]: " "$__p" "$__d" >"$TTY"
  else printf "${C3}%s${C0}: " "$__p" >"$TTY"; fi
  read -r __a <"$TTY" || true
  [ -z "$__a" ] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}
rand(){ openssl rand -hex "${1:-8}"; }
free_port(){ fuser -k "${1}/${2:-tcp}" 2>/dev/null || true; }

# ---------- مقادیر داخلی ثابت ----------
WS_PORT=10002          # پورت داخلی Xray برای WS
XH_PORT=10001          # پورت داخلی Xray برای XHTTP
WS_PATH="wsvpn"
XH_PATH="xhvpn"
declare -A PORT_IPS

WANT_REALITY=false; WANT_WS=false; WANT_XHTTP=false; WANT_HY2=false
USE_DOMAIN=false
# ---------- 1) ریشه و نصب پایه ----------
need_root(){ [ "$(id -u)" -eq 0 ] || die "با root اجرا کن (sudo -i)"; }

install_base(){
  log "بروزرسانی سیستم و نصب پیش‌نیازها ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y curl wget openssl jq ufw socat ca-certificates fuser \
    >/dev/null 2>&1 || apt-get install -y curl wget openssl jq ufw socat ca-certificates psmisc
  ok "پیش‌نیازها نصب شد"
}

# ---------- 2) منوی حالت ----------
menu_mode(){
  printf "\n${C2}=== نوع کانفیگی که می‌خواهی بسازی ===${C0}\n" >"$TTY"
  printf "  1) بدون دامنه  (Reality)\n" >"$TTY"
  printf "  2) با دامنه    (VLESS-WS + VLESS-XHTTP + Hysteria2)\n" >"$TTY"
  printf "  3) هر دو       (همه‌ی پروتکل‌ها)\n" >"$TTY"
  ask MODE "انتخاب" "1"
  case "$MODE" in
    1) WANT_REALITY=true ;;
    2) WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    3) WANT_REALITY=true; WANT_WS=true; WANT_XHTTP=true; WANT_HY2=true; USE_DOMAIN=true ;;
    *) die "گزینه نامعتبر" ;;
  esac
}

# ---------- 3) دریافت ورودی‌ها ----------
collect_inputs(){
  SERVER_IP="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"

  if $USE_DOMAIN; then
    ask DOMAIN "دامنه برای WS/XHTTP (ابر نارنجی Cloudflare)"
    [ -n "${DOMAIN:-}" ] || die "دامنه لازم است"

    # گواهی Hysteria2
    printf "\n${C2}گواهی Hysteria2:${C0}  1) self-signed   2) Let's Encrypt\n" >"$TTY"
    ask HY2_CERT_CH "انتخاب" "1"
    if [ "$HY2_CERT_CH" = "2" ]; then
      HY2_CERT="le"
      ask HY2_DOMAIN "ساب‌دامین Hysteria2 (ابر خاکستری DNS only)"
      ask LE_EMAIL  "ایمیل برای Let's Encrypt"
    else
      HY2_CERT="self"
    fi

    ask NGINX_PORT "پورت Nginx (CDN origin - مثل 443/2053/2083/2087/2096/8443)" "2096"
    ask HY2_PORT   "پورت Hysteria2 (UDP)" "36712"
  fi

  if $WANT_REALITY; then
    ask REALITY_PORT "پورت Reality (TCP مستقیم)" "8443"
    ask SNI          "SNI/مقصد Reality (سایت واقعی)" "www.microsoft.com"
  fi

  if $WANT_WS || $WANT_XHTTP; then
    printf "\n${C2}پورت‌ها و IPهای تمیز${C0} - به این فرمت، هر خط یکی، خط خالی برای پایان:\n" >"$TTY"
    printf "  PORT_IPS[8443]=\"104.21.0.1,172.67.0.2\"\n" >"$TTY"
    while true; do
      local line; read -r line <"$TTY" || break
      [ -z "$line" ] && break
      if [[ "$line" =~ ^PORT_IPS\\\[([0-9]+)\\\]=\"?([^\"]*)\"?$ ]]; then
        PORT_IPS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      elif [[ "$line" =~ ^([0-9]+)[[:space:]:]+(.+)$ ]]; then
        PORT_IPS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      else
        warn "خط نامعتبر رد شد: $line"
      fi
    done
    [ "${#PORT_IPS[@]}" -gt 0 ] || PORT_IPS["${NGINX_PORT}"]="$DOMAIN"
  fi

  ask CONFIG_NAME "یک نام برای کانفیگ‌ها" "MyVPN"
}
# ---------- 4) نصب هسته‌ها ----------
install_cores(){
  log "نصب Xray ..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
  ok "Xray نصب شد"
  if $WANT_HY2; then
    log "نصب Hysteria2 ..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
    ok "Hysteria2 نصب شد"
  fi
  if $USE_DOMAIN; then
    log "نصب Nginx ..."
    apt-get install -y nginx >/dev/null
    systemctl stop nginx 2>/dev/null || true
    ok "Nginx نصب شد"
  fi
  if [ "${HY2_CERT:-}" = "le" ]; then apt-get install -y certbot >/dev/null; fi
}

# ---------- 5) اسرار ----------
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

# ---------- 6) گواهی‌ها ----------
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
# ---------- 7) کانفیگ Xray ----------
write_xray(){
  local ib=()
  if $WANT_REALITY; then
    free_port "$REALITY_PORT" tcp
    ib+=("$(cat <<EOF
{"tag":"reality","listen":"0.0.0.0","port":${REALITY_PORT},"protocol":"vless",
"settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
"streamSettings":{"network":"tcp","security":"reality","realitySettings":{
"show":false,"dest":"${SNI}:443","xver":0,"serverNames":["${SNI}"],
"privateKey":"${REALITY_PRIV}","shortIds":["${REALITY_SID}"]}}}
EOF
)")
  fi
  if $WANT_WS; then
    ib+=("{\"tag\":\"ws\",\"listen\":\"127.0.0.1\",\"port\":${WS_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"ws\",\"wsSettings\":{\"path\":\"/${WS_PATH}\"}}}")
  fi
  if $WANT_XHTTP; then
    ib+=("{\"tag\":\"xhttp\",\"listen\":\"127.0.0.1\",\"port\":${XH_PORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\"}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"xhttp\",\"xhttpSettings\":{\"path\":\"/${XH_PATH}\"}}}")
  fi
  local joined; joined=$(IFS=,; echo "${ib[*]}")
  mkdir -p /usr/local/etc/xray
  cat >/usr/local/etc/xray/config.json <<EOF
{"log":{"loglevel":"warning"},
"inbounds":[${joined}],
"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF
}

# ---------- 8) کانفیگ Hysteria2 ----------
write_hysteria(){
  free_port "$HY2_PORT" udp
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

# ---------- 9) کانفیگ Nginx ----------
write_nginx(){
  local LISTENS="" ; declare -A seen
  for p in "$NGINX_PORT" "${!PORT_IPS[@]}"; do
    [ -n "${seen[$p]:-}" ] && continue; seen[$p]=1
    free_port "$p" tcp
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
    location / { return 200 "ok"; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
}
# ---------- 10) فایروال ----------
setup_fw(){
  ufw allow 22/tcp >/dev/null 2>&1 || true
  $WANT_REALITY && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1 || true
  if $WANT_HY2; then ufw allow "${HY2_PORT}/udp" >/dev/null 2>&1 || true; fi
  if $USE_DOMAIN; then
    for p in "$NGINX_PORT" "${!PORT_IPS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
    [ "${HY2_CERT:-}" = "le" ] && ufw allow 80/tcp >/dev/null 2>&1 || true
  fi
  yes | ufw enable >/dev/null 2>&1 || true
}

# ---------- 11) سرویس‌ها ----------
start_all(){
  systemctl enable --now xray >/dev/null 2>&1 || true
  systemctl restart xray
  if $WANT_HY2; then systemctl enable --now hysteria-server >/dev/null 2>&1 || systemctl restart hysteria-server; fi
  if $USE_DOMAIN; then nginx -t && systemctl enable --now nginx >/dev/null 2>&1 || true; systemctl restart nginx; fi
}

# ---------- 12) لینک‌ها ----------
OUT="/root/${CONFIG_NAME:-vpn}-configs.txt"
gen_links(){
  : > "$OUT"
  echo "===== ${CONFIG_NAME} =====" >> "$OUT"
  if $WANT_REALITY; then
    echo "vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&type=tcp&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&flow=xtls-rprx-vision#${CONFIG_NAME}-Reality" >> "$OUT"
  fi
  if $WANT_HY2; then
    echo "hysteria2://${HY2_PASS}@${HY2_CONN}:${HY2_PORT}?sni=${HY2_SNI}&insecure=${HY2_INSECURE}#${CONFIG_NAME}-HY2" >> "$OUT"
  fi
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
}

summary(){
  printf "\n${C2}========== انجام شد ==========${C0}\n"
  ok "کانفیگ‌ها ذخیره شد در: ${OUT}"
  echo; cat "$OUT"; echo
  $USE_DOMAIN && warn "در Cloudflare: دامنه‌ی CDN ابر نارنجی، SSL/TLS روی Full"
  [ "${HY2_CERT:-}" = "le" ] && warn "ساب‌دامین ${HY2_DOMAIN} باید ابر خاکستری (DNS only) باشد"
}

# ---------- اجرا ----------
need_root
install_base
menu_mode
collect_inputs
install_cores
gen_secrets
setup_certs
write_xray
$WANT_HY2   && write_hysteria
$USE_DOMAIN && write_nginx
setup_fw
start_all
gen_links
summary
