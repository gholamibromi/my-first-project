#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  VPN Multi-Protocol Installer
#  Protocols: VLESS-WS · VLESS-XHTTP · VLESS-Reality · Hysteria2
#  Features:  Fragment · Mux · WARP · Sniffing · Subscription
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── رنگ‌ها ──────────────────────────────────────────────────────
C0=$'\033[0m'        # reset
C1=$'\033[38;5;39m'  # آبی روشن — prompt
C2=$'\033[38;5;220m' # زرد — عنوان
C3=$'\033[38;5;245m' # خاکستری — توضیح
CG=$'\033[38;5;82m'  # سبز — موفق
CR=$'\033[38;5;196m' # قرمز — خطا
CW=$'\033[38;5;208m' # نارنجی — هشدار
CB=$'\033[1m'        # bold
TTY=/dev/tty

# ── توابع لاگ ───────────────────────────────────────────────────
ok()    { printf "${CG}  ✔  ${C0}%s\n"        "$*" >"$TTY"; }
warn()  { printf "${CW}  ⚠  ${C0}%s\n"        "$*" >"$TTY"; }
die()   { printf "${CR}  ✖  ${C0}%s\n"        "$*" >"$TTY"; exit 1; }
info()  { printf "${C3}  ·  ${C0}%s\n"        "$*" >"$TTY"; }
step()  { printf "\n${CB}${C2}  ▶  %s${C0}\n" "$*" >"$TTY"; }
banner(){ printf "${C2}%s${C0}\n""$*" >"$TTY"; }

# ── ثابت‌ها ──────────────────────────────────────────────────────
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

# ── وضعیت‌ها ─────────────────────────────────────────────────────
WANT_WS=false; WANT_XHTTP=false; WANT_REALITY=false; WANT_HY2=false
WANT_WARP=false; WANT_FRAGMENT=false; WANT_MUX=false
USE_DOMAIN=false
NGINX_PORTS=()
declare -A PORT_IPS
EXT_COUNT=0
SUB_TOKEN=""
LINKS=()
HY2_CERT="self"

[ "$(id -u)" = 0 ] || die "Please run as root."

PKG=""
command -v apt-get >/dev/null 2>&1 && PKG=apt
command -v dnf     >/dev/null 2>&1 && PKG=dnf
command -v yum     >/dev/null 2>&1 && [ -z "$PKG" ] && PKG=yum
[ -n "$PKG" ] || die "No supported package manager found (apt/dnf/yum)."

# ── توابع ورودی ──────────────────────────────────────────────────
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

# ── نوار پیشرفت ──────────────────────────────────────────────────
STEP_CURRENT=0
STEP_TOTAL=8

progress(){
  STEP_CURRENT=$((STEP_CURRENT+1))
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
#  آماده‌سازی سرور جدید
# ════════════════════════════════════════════════════════════════
server_init(){
  step "Server Initialization"
  printf "${C3}  Updating system packages — this may take a few minutes...${C0}\n" >"$TTY"

  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get upgrade -y -o Dpkg::Options::="--force-confdef" \
                         -o Dpkg::Options::="--force-confold"
      apt-get autoremove -y
      apt-get install -y \
        curl wget openssl jq nginx certbot ufw \
        ca-certificates gnupg lsb-release \
        fail2ban unzip net-tools qrencode \
        htop iotop iftop vnstat \
        chrony tzdata
      ;;
    dnf|yum)
      $PKG update -y
      $PKG install -y \
        curl wget openssl jq nginx certbot ufw \
        ca-certificates gnupg \
        fail2ban unzip net-tools qrencode \
        htop chrony tzdata
      ;;
  esac

  # ── تنظیم timezone ──────────────────────────────────────────
  timedatectl set-timezone UTC 2>/dev/null || true
  systemctl enable chrony  2>/dev/null || systemctl enable chronyd 2>/dev/null || true
  systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
  ok "Timezone set to UTC, NTP synced."

  # ── swap (اگر کمتر از 1GB RAM) ──────────────────────────────
  local mem_kb
  mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  if [ "$mem_kb" -lt 1048576 ] && [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "1GB swap created (low-RAM server)."
  fi

  # ── fail2ban ────────────────────────────────────────────────
  if command -v fail2ban-server >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    ok "fail2ban configured (SSH brute-force protection)."
  fi

  # ── hardening پایه SSH ──────────────────────────────────────
  if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                       /etc/ssh/sshd_config 2>/dev/null || true
    systemctl reload sshd 2>/dev/null || true
    ok "SSH hardened (key-only root, max 3 auth tries)."
  fi

  # ── UFW پایه ────────────────────────────────────────────────
  if command -v ufw >/dev/null 2>&1; then
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming  >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ok "UFW reset: deny-in / allow-out / SSH open."
  fi

  ok "Server initialization complete."
}

# ════════════════════════════════════════════════════════════════
#  تشخیص نصب قبلی + بکاپ + پاک‌سازی عمیق
# ════════════════════════════════════════════════════════════════
preflight_check(){
  local existing=false found_files=()

  [ -f /usr/local/etc/xray/config.json ]    && existing=true && found_files+=("Xray config")
  [ -f /etc/nginx/conf.d/xray.conf ]        && existing=true && found_files+=("Nginx VPN config")
  [ -f /etc/hysteria/config.yaml ]          && existing=true && found_files+=("Hysteria2 config")
  [ -d /var/www/sub ]                       && existing=true && found_files+=("Subscription files")
  systemctl is-active --quiet xray 2>/dev/null && existing=true && found_files+=("Xray service (running)")

  $existing || return 0

  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║   ⚠  Existing Installation Detected      ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n" >"$TTY"
  printf "${CW}  Found:${C0}\n" >"$TTY"
  local f; for f in "${found_files[@]}"; do printf "    ${C3}•${C0} %s\n" "$f" >"$TTY"; done
  printf "\n" >"$TTY"

  printf "  ${CB}Options:${C0}\n" >"$TTY"
  printf "  ${C2}1)${C0} Backup + deep-clean, then reinstall ${C3}(old links will stop working)${C0}\n" >"$TTY"
  printf "  ${C2}2)${C0} Abort — keep everything as-is\n" >"$TTY"
  printf "\n" >"$TTY"
  ask_choice EX_CH "Your choice" "2" 1 2
  [ "$EX_CH" = "2" ] && { ok "Aborted. Nothing changed."; exit 0; }

  backup_existing
  cleanup_existing
}

backup_existing(){
  local ts bdir
  ts="$(date +%Y%m%d-%H%M%S)"
  bdir="/root/vpn-backup-${ts}"
  mkdir -p "$bdir"

  cp -a /usr/local/etc/xray/config.json "$bdir/"2>/dev/null || true
  cp -a /etc/nginx/conf.d               "$bdir/nginx-conf.d" 2>/dev/null || true
  cp -a /etc/hysteria/config.yaml       "$bdir/"          2>/dev/null || true
  cp -a /var/www/sub                    "$bdir/sub"        2>/dev/null || true
  cp -a /etc/ssl/xray                   "$bdir/ssl-xray"   2>/dev/null || true

  ok "Backup saved → ${bdir}"
}

cleanup_existing(){
  step "Deep Cleanup"

  # ── توقف و غیرفعال‌سازی همه سرویس‌ها ───────────────────────
  local svc
  for svc in xray nginx hysteria-server hysteria warp-svc; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  # ── حذف Xray ────────────────────────────────────────────────
  rm -rf /usr/local/etc/xray 2>/dev/null || true
  rm -f  /etc/systemd/system/xray.service 2>/dev/null || true
  rm -f  /etc/systemd/system/xray@.service 2>/dev/null || true

  # ── حذف Nginx configs مربوط به VPN ──────────────────────────
  rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  local f
  for f in /etc/nginx/conf.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE '127\.0\.0\.1:(10001|10002)|/var/www/sub' "$f" 2>/dev/null; then
      rm -f "$f"
      warn "Removed leftover nginx config: $f"
    fi
  done

  # ── حذف فایل‌های وب و گواهی ─────────────────────────────────
  rm -rf /var/www/sub 2>/dev/null || true
  rm -f  /var/www/html/index.html 2>/dev/null || true
  rm -rf /etc/ssl/xray 2>/dev/null || true

  # ── حذف Hysteria2 ────────────────────────────────────────────
  rm -f  /etc/hysteria/config.yaml 2>/dev/null || true
  rm -f  /etc/hysteria/cert.pem /etc/hysteria/key.pem 2>/dev/null || true
  rm -rf /etc/systemd/system/hysteria-server.service.d 2>/dev/null || true

  # ── حذف WARP ─────────────────────────────────────────────────
  if command -v warp-cli >/dev/null 2>&1; then
    warp-cli disconnect 2>/dev/null || true
    warp-cli registration delete 2>/dev/null || truefi
  rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true

  # ── حذف cron jobs مربوط به VPN ──────────────────────────────
  crontab -l 2>/dev/null | grep -v 'hysteria\|xray\|vpn-backup' | crontab - 2>/dev/null || true

  # ── بستن پورت‌های قدیمی در UFW ──────────────────────────────
  if command -v ufw >/dev/null 2>&1; then
    local p
    for p in "${CF_PORTS[@]}" 36712 8443; do
      ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
    done
  fi

  systemctl daemon-reload 2>/dev/null || true

  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 \
      && ok "Remaining Nginx config is valid." \
      || warn "Nginx has other configs; install step will handle it."
  fi

  ok "Deep cleanup complete."
}
# ════════════════════════════════════════════════════════════════
#  منوی انتخاب پروتکل
# ════════════════════════════════════════════════════════════════
menu_mode(){
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║         Protocol Selection               ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n" >"$TTY"
  printf "  ${C2}1)${C0} ${CB}All${C0}       — WS + XHTTP + Reality + Hysteria2\n" >"$TTY"
  printf "  ${C2}2)${C0} CDN only  — VLESS-WS + VLESS-XHTTP ${C3}(behind Cloudflare)${C0}\n" >"$TTY"
  printf "  ${C2}3)${C0} Reality   — Direct TCP, no CDN needed\n" >"$TTY"
  printf "  ${C2}4)${C0} Hysteria2 — QUIC/UDP, fastest protocol\n" >"$TTY"
  printf "  ${C2}5)${C0} Custom    — Pick protocols manually\n" >"$TTY"
  printf "\n" >"$TTY"
  ask_choice MODE "Your choice" "1" 1 2 3 4 5

  case "$MODE" in
    1) WANT_WS=true; WANT_XHTTP=true; WANT_REALITY=true; WANT_HY2=true ;;
    2) WANT_WS=true; WANT_XHTTP=true ;;
    3) WANT_REALITY=true ;;
    4) WANT_HY2=true ;;
    5)
      local a
      printf "\n" >"$TTY"
      ask_yesno a "Enable VLESS-WS (CDN WebSocket)?"  "y"; [ "$a" = y ] && WANT_WS=true
      ask_yesno a "Enable VLESS-XHTTP (CDN HTTP/2)?"  "y"; [ "$a" = y ] && WANT_XHTTP=true
      ask_yesno a "Enable Reality (direct, no CDN)?"  "y"; [ "$a" = y ] && WANT_REALITY=true
      ask_yesno a "Enable Hysteria2 (QUIC/UDP)?"      "y"; [ "$a" = y ] && WANT_HY2=true
      ;;
  esac

  $WANT_WS || $WANT_XHTTP || $WANT_REALITY || $WANT_HY2 || die "Nothing selected."
  if $WANT_WS || $WANT_XHTTP; then USE_DOMAIN=true; fi

  printf "\n" >"$TTY"
  # ── Fragment ────────────────────────────────────────────────
  if $WANT_WS || $WANT_XHTTP || $WANT_REALITY; then
    local fr
    ask_yesno fr "Enable Fragment (helps bypass DPI/SNI blocking)?" "y"
    [ "$fr" = y ] && WANT_FRAGMENT=true
  fi

  # ── Mux ─────────────────────────────────────────────────────
  if $WANT_WS || $WANT_XHTTP; then
    local mx
    ask_yesno mx "Enable Mux (multiplexing — fewer TLS handshakes)?" "y"
    [ "$mx" = y ] && WANT_MUX=true
  fi

  # ── WARP ────────────────────────────────────────────────────
  printf "\n" >"$TTY"
  local w
  ask_yesno w "Enable WARP outbound (Google / OpenAI / Netflix / Spotify)?" "y"
  [ "$w" = y ] && WANT_WARP=true
}

# ════════════════════════════════════════════════════════════════
#  منوی uTLS Fingerprint
# ════════════════════════════════════════════════════════════════
menu_fingerprint(){
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║         uTLS Fingerprint                 ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n" >"$TTY"
  printf "  ${C2}1)${C0} chrome     ${CG}← recommended${C0}\n" >"$TTY"
  printf "  ${C2}2)${C0} firefox\n" >"$TTY"
  printf "  ${C2}3)${C0} safari\n" >"$TTY"
  printf "  ${C2}4)${C0} ios\n" >"$TTY"
  printf "  ${C2}5)${C0} android\n" >"$TTY"
  printf "  ${C2}6)${C0} edge\n" >"$TTY"
  printf "  ${C2}7)${C0} random\n" >"$TTY"
  printf "  ${C2}8)${C0} randomized\n" >"$TTY"
  printf "\n" >"$TTY"
  ask_choice FP_NUM "Your choice" "1" 1 2 3 4 5 6 7 8
  case "$FP_NUM" in
    1) FP="chrome"     ;; 2) FP="firefox"    ;; 3) FP="safari"     ;;
    4) FP="ios"        ;; 5) FP="android"    ;; 6) FP="edge"       ;;
    7) FP="random"     ;; 8) FP="randomized" ;;
  esac
  ok "Fingerprint: ${FP}"
}

# ════════════════════════════════════════════════════════════════
#  جمع‌آوری پورت‌های Nginx (فقط پورت‌های HTTPS کلودفلر)
# ════════════════════════════════════════════════════════════════
collect_nginx_ports(){
  NGINX_PORTS=()
  printf "\n${C3}  Cloudflare HTTPS ports: ${CF_PORTS[*]}${C0}\n" >"$TTY"
  printf "  ${C3}Enter one port per line. Empty line to finish.${C0}\n\n" >"$TTY"
  local p def dup x
  while true; do
    def=""; [ "${#NGINX_PORTS[@]}" -eq 0 ] && def="2096"
    ask p "Nginx port (Enter to finish)" "$def"
    if [ -z "$p" ]; then
      [ "${#NGINX_PORTS[@]}" -eq 0 ] && { warn "At least one port required."; continue; }
      break
    fi
    [[ "$p" =~ ^[0-9]+$ ]] || { warn "Not a number."; continue; }
    is_cf_port "$p" || { warn "$p is not a Cloudflare port. Allowed: ${CF_PORTS[*]}"; continue; }
    dup=false
    for x in "${NGINX_PORTS[@]}"; do [ "$x" = "$p" ] && dup=true && break; done
    $dup && { warn "Port $p already added."; continue; }
    NGINX_PORTS+=("$p")
    ok "Added port $p  →  current list: [${NGINX_PORTS[*]}]"
  done
}

# ════════════════════════════════════════════════════════════════
#  جمع‌آوری IP های تمیز CDN
#  فرمت دقیق:  PORT_IPS[2096]="104.19.184.210,104.27.53.171"
# ════════════════════════════════════════════════════════════════
collect_external_proxies(){
  EXT_COUNT=0
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║       CDN Clean-IP Configuration         ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n" >"$TTY"
  printf "  ${C3}Format (one per line):${C0}\n" >"$TTY"
  printf "  ${C1}PORT_IPS[2096]=\"104.19.184.210,104.27.53.171\"${C0}\n" >"$TTY"
  printf "  ${C3}Port must be one of: ${NGINX_PORTS[*]}${C0}\n" >"$TTY"
  printf "  ${C3}Empty line to finish. Leave all blank to use the domain directly.${C0}\n\n" >"$TTY"

  local line port ips found p
  while true; do
    printf "  ${C1}❯ ${C0}" >"$TTY"
    read -r line <"$TTY" || break
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && break
    if [[ "$line" =~ $RE_EXT ]]; then
      port="${BASH_REMATCH[1]}"; ips="${BASH_REMATCH[2]}"
      found=false
      for p in "${NGINX_PORTS[@]}"; do [ "$port" = "$p" ] && found=true && break; done
      if ! $found; then warn "Port ${port} not in Nginx list. Ignored."; continue; fi
      PORT_IPS["$port"]="$ips"
      EXT_COUNT=$((EXT_COUNT+1))
      ok "Port ${port} → ${ips}"
    else
      warn "Invalid format, ignored: ${line}"
    fi
  done
}

# ════════════════════════════════════════════════════════════════
#  جمع‌آوری همه ورودی‌ها
# ════════════════════════════════════════════════════════════════
collect_inputs(){
  step "Configuration Inputs"

  SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null \
            || curl -fsSL https://ifconfig.me 2>/dev/null \
            || hostname -I | awk '{print $1}')"
  [ -n "$SERVER_IP" ] || die "Could not detect server public IP."
  ok "Server IP: ${SERVER_IP}"

  HY2_PORT=36712
  REALITY_PORT=8443

  # ── دامنه برای WS/XHTTP ─────────────────────────────────────
  if $USE_DOMAIN; then
    ask_valid DOMAIN "Domain for WS/XHTTP (points to Cloudflare)" "$RE_DOMAIN"
  fi

  # ── پورت‌ها + IP های CDN + fingerprint ──────────────────────
  if $WANT_WS || $WANT_XHTTP; then
    collect_nginx_ports
    collect_external_proxies
    menu_fingerprint
  fi

  # ── Reality ─────────────────────────────────────────────────
  if $WANT_REALITY; then
    ask_port  REALITY_PORT "Reality port (direct TCP)" "8443"
    ask_valid SNI "Reality SNI (a real TLS site)" "$RE_DOMAIN" "www.cloudflare.com"
    [ -z "${FP:-}" ] && menu_fingerprint
  fi

  # ── Hysteria2 ───────────────────────────────────────────────
  if $WANT_HY2; then
    ask_port HY2_PORT "Hysteria2 port (UDP)" "36712"
    printf "\n" >"$TTY"
    printf "  ${CB}Hysteria2 TLS certificate:${C0}\n" >"$TTY"
    printf "  ${C2}1)${C0} Self-signed   ${C3}(fast; client must allow insecure)${C0}\n" >"$TTY"
    printf "  ${C2}2)${C0} Let's Encrypt ${C3}(needs a domain + open port 80)${C0}\n" >"$TTY"
    printf "\n" >"$TTY"
    ask_choice HY2_CH "Your choice" "1" 1 2
    if [ "$HY2_CH" = "2" ]; then
      HY2_CERT="le"
      ask_valid HY2_DOMAIN "Hysteria2 domain (A record → this server)" "$RE_DOMAIN"
      ask_valid LE_EMAIL   "Email for Let's Encrypt" "$RE_EMAIL"
    else
      HY2_CERT="self"
    fi
  fi

  # ── نام کانفیگ و مسیر اشتراک ────────────────────────────────
  printf "\n" >"$TTY"
  ask CONFIG_NAME "Config name (shown in client)" "MyVPN"
  CONFIG_NAME="${CONFIG_NAME// /_}"

  if $USE_DOMAIN; then
    ask_valid SUB_PATH_IN "Subscription path segment" "$RE_SUBPATH" "sub"
  fi

  ok "All inputs collected."
}

# ════════════════════════════════════════════════════════════════
#  خلاصه و تأیید نهایی قبل از نصب
# ════════════════════════════════════════════════════════════════
confirm_summary(){
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║         Configuration Summary            ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n" >"$TTY"

  local protos=()
  $WANT_WS      && protos+=("VLESS-WS")
  $WANT_XHTTP   && protos+=("VLESS-XHTTP")
  $WANT_REALITY && protos+=("VLESS-Reality")
  $WANT_HY2     && protos+=("Hysteria2")

  printf "  ${C3}Server IP    :${C0} %s\n" "$SERVER_IP"      >"$TTY"
  printf "  ${C3}Protocols    :${C0} %s\n" "${protos[*]}"    >"$TTY"
  $USE_DOMAIN   && printf "  ${C3}Domain       :${C0} %s\n" "$DOMAIN"             >"$TTY"
  $USE_DOMAIN   && printf "  ${C3}Nginx ports  :${C0} %s\n" "${NGINX_PORTS[*]}"   >"$TTY"
  $USE_DOMAIN   && printf "  ${C3}CDN entries  :${C0} %s\n" "$EXT_COUNT"          >"$TTY"
  { $WANT_WS || $WANT_XHTTP || $WANT_REALITY; } && \
    printf "  ${C3}Fingerprint  :${C0} %s\n" "${FP:-chrome}" >"$TTY"
  $WANT_REALITY && printf "  ${C3}Reality      :${C0} %s:%s (SNI %s)\n" "$SERVER_IP" "$REALITY_PORT" "$SNI" >"$TTY"
  $WANT_HY2     && printf "  ${C3}Hysteria2    :${C0} UDP %s (%s cert)\n" "$HY2_PORT" "$HY2_CERT" >"$TTY"
  printf "  ${C3}Fragment     :${C0} %s\n" "$($WANT_FRAGMENT && echo on || echo off)" >"$TTY"
  printf "  ${C3}Mux          :${C0} %s\n" "$($WANT_MUX      && echo on || echo off)" >"$TTY"
  printf "  ${C3}WARP         :${C0} %s\n" "$($WANT_WARP     && echo on || echo off)" >"$TTY"
  printf "\n" >"$TTY"

  local go
  ask_yesno go "Proceed with installation?" "y"
  [ "$go" = y ] || { ok "Cancelled by user. Nothing changed."; exit 0; }
}
# ════════════════════════════════════════════════════════════════
#  نصب Xray-core
# ════════════════════════════════════════════════════════════════
install_xray(){
  progress "Installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
    || die "Xray installation failed."
  command -v xray >/dev/null 2>&1 || die "Xray binary not found after install."
  ok "Xray-core installed ($(xray version 2>/dev/null | head -1))"
}

# ════════════════════════════════════════════════════════════════
#  نصب Hysteria2
# ════════════════════════════════════════════════════════════════
install_hysteria(){
  $WANT_HY2 || return 0
  info "Installing Hysteria2 ..."
  bash -c "$(curl -fsSL https://get.hy2.sh/)" >/dev/null 2>&1 \
    || die "Hysteria2 installation failed."
  ok "Hysteria2 installed."
}

# ════════════════════════════════════════════════════════════════
#  نصب Cloudflare WARP در حالت proxy روی 127.0.0.1:40000
# ════════════════════════════════════════════════════════════════
install_warp(){
  $WANT_WARP || return 0
  info "Installing Cloudflare WARP (proxy mode :${WARP_PORT}) ..."
  if ! command -v warp-cli >/dev/null 2>&1; then
    if [ "$PKG" = "apt" ]; then
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y cloudflare-warp >/dev/null 2>&1 \
        || { warn "WARP package failed; disabling WARP."; WANT_WARP=false; return 0; }
    else
      warn "WARP auto-install only supported on apt systems; disabling WARP."
      WANT_WARP=false; return 0
    fi
  fi
  warp-cli --accept-tos registration new >/dev/null 2>&1 \
    || warp-cli --accept-tos register >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy        >/dev/null 2>&1
  warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1
  warp-cli --accept-tos connect           >/dev/null 2>&1
  sleep 3
  if curl -fsSL --socks5 "127.0.0.1:${WARP_PORT}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
    ok "WARP proxy active on 127.0.0.1:${WARP_PORT}"
  else
    warn "WARP proxy not confirmed; routing will still point to it."
  fi
}

# ════════════════════════════════════════════════════════════════
#  تولید اسرار
# ════════════════════════════════════════════════════════════════
gen_secrets(){
  step "Generating secrets"
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
    [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "Reality keypair generation failed."
  fi
  ok "Secrets generated."
}

# ════════════════════════════════════════════════════════════════
#  نوشتن کانفیگ Xray
# ════════════════════════════════════════════════════════════════
write_xray_config(){
  progress "Writing Xray config"
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

  jq empty /usr/local/etc/xray/config.json >/dev/null 2>&1 || die "Generated Xray config is invalid JSON."
  ok "Xray config written."
}
# ════════════════════════════════════════════════════════════════
#  Nginx (TLS، web root، proxy برای WS/XHTTP، مسیر subscription)
# ════════════════════════════════════════════════════════════════
write_nginx(){
  $USE_DOMAIN || return 0
  progress "Configuring Nginx"
  mkdir -p /var/www/html /var/www/sub /etc/ssl/xray
  [ -f /var/www/html/index.html ] || echo "<h1>It works</h1>" > /var/www/html/index.html

  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/ssl/xray/self.key -out /etc/ssl/xray/self.crt \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1

  local listens="" p
  for p in "${NGINX_PORTS[@]}"; do
    listens+="    listen ${p} ssl;
    listen [::]:${p} ssl;
"
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
    }
"
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
    }
"
  fi

  cat > /etc/nginx/conf.d/xray.conf <<NGINX
server {
${listens}    server_name ${DOMAIN};
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
${locs}}
NGINX

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t >/dev/null 2>&1 || die "Nginx config test failed."
  ok "Nginx configured on ports: ${NGINX_PORTS[*]}"
}

# ════════════════════════════════════════════════════════════════
#  Hysteria2
# ════════════════════════════════════════════════════════════════
write_hysteria(){
  $WANT_HY2 || return 0
  progress "Configuring Hysteria2"
  mkdir -p /etc/hysteria

  if [ "$HY2_CERT" = "le" ]; then
    systemctl stop nginx >/dev/null 2>&1 || true
    certbot certonly --standalone --non-interactive --agree-tos \
      -m "${LE_EMAIL}" -d "${HY2_DOMAIN}" >/dev/null 2>&1 \
      || { warn "Let's Encrypt failed; falling back to self-signed."; HY2_CERT="self"; }
    systemctl start nginx >/dev/null 2>&1 || true
  fi

  local tls_block
  if [ "$HY2_CERT" = "le" ] && [ -f "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem" ]; then
    tls_block="tls:
  cert: /etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem"
    HY2_PEER="${HY2_DOMAIN}"; HY2_INSECURE=0
  else
    HY2_CERT="self"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
      -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1
    tls_block="tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key"
    HY2_PEER="${HY2_SNI}"; HY2_INSECURE=1
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
    - warp(geosite:spotify)
    - warp(suffix:claude.ai)
    - warp(suffix:anthropic.com)
    - warp(suffix:chatgpt.com)
    - direct(all)"
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
  ok "Hysteria2 configured (${HY2_CERT} cert, UDP ${HY2_PORT})."
}

# ════════════════════════════════════════════════════════════════
#  URL-encode کمکی
# ════════════════════════════════════════════════════════════════
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

# ════════════════════════════════════════════════════════════════
#  ساخت لینک‌های اشتراک‌گذاری
# ════════════════════════════════════════════════════════════════
build_links(){
  progress "Building share links"
  LINKS=()
  local fp="${FP:-chrome}" enc_ws enc_xh
  enc_ws="$(urlenc "${WS_PATH}")"
  enc_xh="$(urlenc "${XHTTP_PATH}")"

  if $WANT_WS || $WANT_XHTTP; then
    local p ips arr addr tag
    for p in "${NGINX_PORTS[@]}"; do
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
    LINKS+=("hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${HY2_PEER}&insecure=${HY2_INSECURE}#$(urlenc "${CONFIG_NAME}-HY2")")
  fi

  [ "${#LINKS[@]}" -gt 0 ] || die "No links generated."
  ok "Generated ${#LINKS[@]} link(s)."
}

# ════════════════════════════════════════════════════════════════
#  ساخت فایل اشتراک base64
# ════════════════════════════════════════════════════════════════
build_subscription(){
  $USE_DOMAIN || return 0
  progress "Building subscription"
  mkdir -p /var/www/sub
  local raw; raw="$(printf '%s\n' "${LINKS[@]}")"
  printf '%s' "$raw" | base64 -w0 > "/var/www/sub/${SUB_TOKEN}.txt" 2>/dev/null \
    || printf '%s' "$raw" | base64 | tr -d '\n' > "/var/www/sub/${SUB_TOKEN}.txt"
  SUB_URL="https://${DOMAIN}:${NGINX_PORTS[0]}/sub/${SUB_TOKEN}"
  ok "Subscription ready."
}
# ════════════════════════════════════════════════════════════════
#  فایروال
# ════════════════════════════════════════════════════════════════
setup_firewall(){
  progress "Configuring firewall"
  command -v ufw >/dev/null 2>&1 || { warn "ufw not present; skipping firewall."; return 0; }
  local p
  for p in "${NGINX_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
  $WANT_REALITY && ufw allow "${REALITY_PORT}/tcp" >/dev/null 2>&1
  $WANT_HY2     && ufw allow "${HY2_PORT}/udp"     >/dev/null 2>&1
  [ "${HY2_CERT:-self}" = "le" ] && ufw allow 80/tcp >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  ok "Firewall rules applied."
}

# ════════════════════════════════════════════════════════════════
#  اجرای سرویس‌ها + بررسی سلامت
# ════════════════════════════════════════════════════════════════
start_services(){
  progress "Starting services"
  systemctl enable xray  >/dev/null 2>&1
  systemctl restart xray >/dev/null 2>&1
  sleep 1
  systemctl is-active --quiet xray || die "Xray failed to start. Check: journalctl -u xray -n 50"

  if $USE_DOMAIN; then
    systemctl enable nginx  >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1
    systemctl is-active --quiet nginx || die "Nginx failed to start. Check: journalctl -u nginx -n 50"
  fi

  if $WANT_HY2; then
    systemctl enable hysteria-server  >/dev/null 2>&1
    systemctl restart hysteria-server >/dev/null 2>&1
    sleep 1
    systemctl is-active --quiet hysteria-server || die "Hysteria2 failed. Check: journalctl -u hysteria-server -n 50"
    ss -ulnp 2>/dev/null | grep -q ":${HY2_PORT} " || warn "Hysteria2 not yet listening on UDP ${HY2_PORT}."
  fi
  ok "All services running."
}

# ════════════════════════════════════════════════════════════════
#  خروجی نهایی
# ════════════════════════════════════════════════════════════════
final_output(){
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║          Installation Complete           ║"
  banner "  ╚══════════════════════════════════════════╝"
  printf "\n  ${CB}Share links:${C0}\n\n" >"$TTY"

  local l
  for l in "${LINKS[@]}"; do
    printf "${CG}%s${C0}\n\n" "$l" >"$TTY"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$l" >"$TTY" 2>/dev/null || true
      printf "\n" >"$TTY"
    fi
  done

  if $USE_DOMAIN; then
    printf "  ${CB}Subscription URL:${C0}\n  ${C1}%s${C0}\n\n" "$SUB_URL" >"$TTY"
    printf "  ${C3}Nginx ports : ${C0}%s\n" "${NGINX_PORTS[*]}" >"$TTY"
  fi
  $WANT_REALITY && printf "  ${C3}Reality     : ${C0}%s:%s\n" "$SERVER_IP" "$REALITY_PORT" >"$TTY"
  $WANT_HY2     && printf "  ${C3}Hysteria2   : ${C0}UDP %s (%s)\n" "$HY2_PORT" "$HY2_CERT" >"$TTY"
  printf "\n" >"$TTY"

  banner "  ── Notes ───────────────────────────────────"
  if $USE_DOMAIN; then
    printf "  ${CW}•${C0} Cloudflare: set SSL mode to ${CB}Full${C0}, enable the ${CW}orange cloud${C0}.\n" >"$TTY"
    printf "  ${CW}•${C0} Only proxy these HTTPS ports via CF: ${CB}%s${C0}\n" "${CF_PORTS[*]}" >"$TTY"
  fi
  if $WANT_HY2; then
    printf "  ${CW}•${C0} Hysteria2 shows ${CB}-1 ping${C0} in some clients — that is usually only the\n" >"$TTY"
    printf "      client's ICMP test. Check ${CB}real delay / test URL${C0} instead.\n" >"$TTY"
  fi
  $WANT_WARP && printf "  ${CW}•${C0} WARP routes Google / OpenAI / Netflix / Spotify / Claude outbound.\n" >"$TTY"
  if $WANT_FRAGMENT || $WANT_MUX; then
    printf "  ${CW}•${C0} Enable ${CB}Fragment${C0}/${CB}Mux${C0} in your client (v2rayN/NG, Nekobox, sing-box)\n" >"$TTY"
    printf "      — these are client-side options applied to the imported configs.\n" >"$TTY"
  fi
  printf "  ${CW}•${C0} Manage: ${C1}systemctl status xray nginx hysteria-server${C0}\n\n" >"$TTY"
  ok "Done. Enjoy."
}

# ════════════════════════════════════════════════════════════════
#  جریان اصلی
# ════════════════════════════════════════════════════════════════
main(){
  printf "\n" >"$TTY"
  banner "  ╔══════════════════════════════════════════╗"
  banner "  ║       VPN Multi-Protocol Installer       ║"
  banner "  ╚══════════════════════════════════════════╝"

  preflight_check          # تشخیص نصب قبلی + بکاپ/پاکسازی
  menu_mode                # انتخاب پروتکل‌ها + Fragment/Mux/WARP
  collect_inputs           # دامنه، پورت‌ها، IPها، گواهی‌ها، نام
  confirm_summary          # خلاصه + تأیید نهایی

  server_init              # آماده‌سازی سرور تازه (apt update/upgrade …)
  install_xray
  install_hysteria
  install_warp
  gen_secrets

  write_xray_config
  write_nginx
  write_hysteria
  build_links
  build_subscription

  setup_firewall
  start_services
  final_output
}

main "$@"
