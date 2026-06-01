#!/usr/bin/env bash
# MOJA Web Panel Installer
set -e

# Colors
C0=$'\033[0m'; C1=$'\033[36m'; C2=$'\033[1;33m'; CR=$'\033[31m'; CG=$'\033[32m'

clear
echo "${C1}=========================================="
echo "    MOJA Web Panel Setup Installer        "
echo "==========================================${C0}"
echo ""

read -p "? Enter Panel Port [default 8585]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8585}
read -p "? Enter Panel Username [default admin]: " PANEL_USER
PANEL_USER=${PANEL_USER:-admin}
read -p "? Enter Panel Password (leave empty for random): " PANEL_PASS
if [ -z "$PANEL_PASS" ]; then
    PANEL_PASS=$(openssl rand -hex 6)
    echo "${CG}[ok] Generated random password: ${C2}$PANEL_PASS${C0}"
fi

echo ""
echo "${C2}[*] Installing system dependencies...${C0}"
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip python3-venv curl vnstat jq ufw >/dev/null 2>&1

echo "${C2}[*] Opening Firewall Ports...${C0}"
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1 || true
iptables -I INPUT -p tcp --dport ${PANEL_PORT} -j ACCEPT >/dev/null 2>&1 || true

mkdir -p /opt/cr-vpn/templates
cd /opt/cr-vpn

echo "${C2}[*] Creating Python Virtual Environment...${C0}"
python3 -m venv venv
./venv/bin/pip install Flask psutil >/dev/null 2>&1

# Download the core engine (setupFINAL.sh)
echo "${C2}[*] Downloading Core Engine...${C0}"
curl -fsSL -o /opt/cr-vpn/setup.sh https://raw.githubusercontent.com/gholamibromi/my-first-project/refs/heads/main/setupFINAL.sh || true
# If the curl fails (e.g. repo not public yet), we copy it from current dir if it exists
if [ -f /root/setupFINAL.sh ]; then cp /root/setupFINAL.sh /opt/cr-vpn/setup.sh; fi
chmod +x /opt/cr-vpn/setup.sh

# Create the Python Backend
echo "${C2}[*] Generating Backend Logic...${C0}"
cat << 'EOF' > /opt/cr-vpn/app.py
import os
import subprocess
import json
from flask import Flask, request, render_template, redirect, url_for, session, jsonify
import psutil

app = Flask(__name__)
app.secret_key = os.urandom(24)

USERNAME = os.environ.get('PANEL_USER', 'admin')
PASSWORD = os.environ.get('PANEL_PASS', 'admin')
STATE_FILE = '/etc/vpn-installer/state.env'

def read_state():
    state = {}
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE, 'r') as f:
            for line in f:
                if '=' in line:
                    k, v = line.strip().split('=', 1)
                    v = v.strip('"\'')
                    if v == 'true': v = True
                    elif v == 'false': v = False
                    state[k] = v
    return state

def write_state(data):
    os.makedirs('/etc/vpn-installer', exist_ok=True)
    with open(STATE_FILE, 'w') as f:
        for k, v in data.items():
            if isinstance(v, bool):
                v = "true" if v else "false"
            f.write(f'{k}="{v}"\n')

@app.before_request
def require_login():
    allowed = ['login', 'static']
    if request.endpoint not in allowed and not session.get('logged_in'):
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('username') == USERNAME and request.form.get('password') == PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('dashboard'))
        return render_template('login.html', error='Invalid credentials')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def dashboard():
    return render_template('index.html')

@app.route('/api/state', methods=['GET', 'POST'])
def api_state():
    if request.method == 'POST':
        data = request.json
        write_state(data)
        try:
            # Execute headless build
            subprocess.Popen(['bash', '/opt/cr-vpn/setup.sh', '--headless'])
            return jsonify({'success': True, 'msg': 'Configuration saved! Server is rebuilding in the background...'})
        except Exception as e:
            return jsonify({'success': False, 'msg': str(e)})
    return jsonify(read_state())

@app.route('/api/stats')
def api_stats():
    cpu = psutil.cpu_percent()
    mem = psutil.virtual_memory()
    rx_tx = {"rx": "0 MB", "tx": "0 MB"}
    try:
        vnstat = subprocess.check_output(['vnstat', '--oneline']).decode('utf-8')
        parts = vnstat.split(';')
        if len(parts) >= 6:
            rx_tx['rx'] = parts[3]
            rx_tx['tx'] = parts[4]
    except:
        pass
    return jsonify({'cpu': cpu, 'mem': mem.percent, 'network': rx_tx})

if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 8585))
    app.run(host='0.0.0.0', port=port)
EOF

# Create the Login Template
echo "${C2}[*] Generating Frontend (Login)...${C0}"
cat << 'EOF' > /opt/cr-vpn/templates/login.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MOJA Panel Login</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background: linear-gradient(135deg, #09000a 0%, #170014 50%, #1a0005 100%); color: #fff; min-height: 100vh; display: flex; align-items: center; justify-content: center; font-family: 'Inter', sans-serif; }
        .glass { background: rgba(255,255,255,0.03); backdrop-filter: blur(15px); border: 1px solid rgba(255,255,255,0.05); border-radius: 20px; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); }
        .btn-gradient { background: linear-gradient(45deg, #8a2be2, #e50914); transition: transform 0.2s; }
        .btn-gradient:hover { transform: translateY(-2px); opacity: 0.9; }
    </style>
</head>
<body>
    <div class="glass w-full max-w-md p-8 m-4">
        <h1 class="text-3xl font-bold text-center mb-8 bg-clip-text text-transparent bg-gradient-to-r from-purple-500 to-red-500">MOJA Panel</h1>
        {% if error %}
        <div class="bg-red-500/20 border border-red-500/50 text-red-200 p-3 rounded-lg mb-6 text-center text-sm">{{ error }}</div>
        {% endif %}
        <form method="POST" class="space-y-6">
            <div>
                <label class="block text-sm font-medium text-gray-400 mb-2">Username</label>
                <input type="text" name="username" class="w-full bg-black/30 border border-gray-600 rounded-lg px-4 py-3 text-white focus:outline-none focus:border-purple-500" required>
            </div>
            <div>
                <label class="block text-sm font-medium text-gray-400 mb-2">Password</label>
                <input type="password" name="password" class="w-full bg-black/30 border border-gray-600 rounded-lg px-4 py-3 text-white focus:outline-none focus:border-purple-500" required>
            </div>
            <button type="submit" class="w-full btn-gradient text-white font-bold py-3 rounded-lg">Login</button>
        </form>
    </div>
</body>
</html>
EOF

# Create the Main Dashboard Template
echo "${C2}[*] Generating Frontend (Dashboard)...${C0}"
cat << 'EOF' > /opt/cr-vpn/templates/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MOJA Dashboard</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        body { background: #09000a; color: #fff; font-family: 'Inter', sans-serif; }
        .glass { background: rgba(255,255,255,0.03); backdrop-filter: blur(15px); border: 1px solid rgba(255,255,255,0.05); }
        .input-dark { background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.1); color: white; }
        .input-dark:focus { border-color: #8a2be2; outline: none; }
        .btn-gradient { background: linear-gradient(45deg, #8a2be2, #e50914); }
        .btn-gradient:hover { opacity: 0.9; }
        .toggle-checkbox:checked { right: 0; border-color: #8a2be2; }
        .toggle-checkbox:checked + .toggle-label { background-color: #8a2be2; }
        .toggle-checkbox { right: 0; z-index: 1; border-color: #e2e8f0; transition: all 0.3s; }
        .toggle-label { width: 3rem; height: 1.5rem; background-color: #4a5568; border-radius: 9999px; transition: all 0.3s; }
    </style>
</head>
<body>
    <div id="app" class="flex h-screen overflow-hidden">
        
        <!-- Sidebar -->
        <div class="w-64 glass flex flex-col justify-between">
            <div>
                <div class="p-6">
                    <h1 class="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-purple-500 to-red-500">MOJA</h1>
                </div>
                <nav class="mt-6">
                    <a @click="tab = 'dash'" :class="{'bg-white/10': tab=='dash'}" class="block px-6 py-3 cursor-pointer hover:bg-white/5 transition">📊 Dashboard</a>
                    <a @click="tab = 'proto'" :class="{'bg-white/10': tab=='proto'}" class="block px-6 py-3 cursor-pointer hover:bg-white/5 transition">⚡ Protocols</a>
                    <a @click="tab = 'net'" :class="{'bg-white/10': tab=='net'}" class="block px-6 py-3 cursor-pointer hover:bg-white/5 transition">🌐 Network</a>
                    <a @click="tab = 'sec'" :class="{'bg-white/10': tab=='sec'}" class="block px-6 py-3 cursor-pointer hover:bg-white/5 transition">🛡️ Security & Routing</a>
                </nav>
            </div>
            <div class="p-6">
                <a href="/logout" class="block w-full text-center py-2 rounded border border-red-500 text-red-500 hover:bg-red-500 hover:text-white transition">Logout</a>
            </div>
        </div>

        <!-- Main Content -->
        <div class="flex-1 overflow-y-auto p-8 relative">
            <!-- Toast -->
            <div v-if="toast.show" class="absolute top-4 right-8 bg-green-500/20 border border-green-500 text-green-300 px-6 py-3 rounded-lg shadow-lg transition-all z-50">
                {{ toast.msg }}
            </div>

            <!-- Dashboard Tab -->
            <div v-show="tab === 'dash'" class="space-y-6">
                <h2 class="text-3xl font-bold mb-8">Server Overview</h2>
                <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                    <div class="glass p-6 rounded-2xl">
                        <p class="text-gray-400 text-sm mb-2">CPU Usage</p>
                        <p class="text-4xl font-bold">{{ stats.cpu }}%</p>
                    </div>
                    <div class="glass p-6 rounded-2xl">
                        <p class="text-gray-400 text-sm mb-2">RAM Usage</p>
                        <p class="text-4xl font-bold">{{ stats.mem }}%</p>
                    </div>
                    <div class="glass p-6 rounded-2xl">
                        <p class="text-gray-400 text-sm mb-2">Traffic (RX / TX)</p>
                        <p class="text-2xl font-bold">{{ stats.network.rx }} / {{ stats.network.tx }}</p>
                    </div>
                </div>
            </div>

            <!-- Forms -->
            <div v-show="tab !== 'dash'" class="glass p-8 rounded-2xl max-w-3xl">
                
                <div v-show="tab === 'proto'" class="space-y-6">
                    <h2 class="text-2xl font-bold mb-6 border-b border-white/10 pb-4">Core Protocols</h2>
                    <div class="flex items-center justify-between">
                        <div><p class="font-bold">VLESS-WS</p><p class="text-sm text-gray-400">WebSocket transport (CDN friendly)</p></div>
                        <input type="checkbox" v-model="s.WANT_WS" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between">
                        <div><p class="font-bold">VLESS-XHTTP</p><p class="text-sm text-gray-400">Next-gen HTTP transport</p></div>
                        <input type="checkbox" v-model="s.WANT_XHTTP" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between">
                        <div><p class="font-bold">VLESS-Reality</p><p class="text-sm text-gray-400">Stealth direct TCP connection</p></div>
                        <input type="checkbox" v-model="s.WANT_REALITY" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between">
                        <div><p class="font-bold">Hysteria2</p><p class="text-sm text-gray-400">High-speed UDP protocol</p></div>
                        <input type="checkbox" v-model="s.WANT_HY2" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between">
                        <div><p class="font-bold">WARP Outbound</p><p class="text-sm text-gray-400">Route blocked sites (Google, OpenAI) via Cloudflare</p></div>
                        <input type="checkbox" v-model="s.WANT_WARP" class="w-6 h-6 rounded text-purple-500">
                    </div>
                </div>

                <div v-show="tab === 'net'" class="space-y-6">
                    <h2 class="text-2xl font-bold mb-6 border-b border-white/10 pb-4">Network & Domain</h2>
                    <div>
                        <label class="block text-sm font-medium mb-2">Domain (For WS/XHTTP)</label>
                        <input type="text" v-model="s.DOMAIN" class="w-full input-dark rounded-lg px-4 py-2" placeholder="vpn.example.com">
                    </div>
                    <div>
                        <label class="block text-sm font-medium mb-2">Nginx Ports (Space separated)</label>
                        <input type="text" v-model="s.NGINX_PORTS" class="w-full input-dark rounded-lg px-4 py-2" placeholder="443 2096 8443">
                    </div>
                    <div>
                        <label class="block text-sm font-medium mb-2">Subscription Token (Path)</label>
                        <input type="text" v-model="s.SUB_TOKEN" class="w-full input-dark rounded-lg px-4 py-2">
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-sm font-medium mb-2">Reality Port</label>
                            <input type="text" v-model="s.REALITY_PORT" class="w-full input-dark rounded-lg px-4 py-2">
                        </div>
                        <div>
                            <label class="block text-sm font-medium mb-2">Hysteria2 Port</label>
                            <input type="text" v-model="s.HY2_PORT" class="w-full input-dark rounded-lg px-4 py-2">
                        </div>
                    </div>
                    <div>
                        <label class="block text-sm font-medium mb-2">Config Name Prefix</label>
                        <input type="text" v-model="s.CONFIG_NAME" class="w-full input-dark rounded-lg px-4 py-2">
                    </div>
                </div>

                <div v-show="tab === 'sec'" class="space-y-6">
                    <h2 class="text-2xl font-bold mb-6 border-b border-white/10 pb-4">Security & Routing</h2>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-sm font-medium mb-2">Primary Reality SNI</label>
                            <input type="text" v-model="s.SNI" class="w-full input-dark rounded-lg px-4 py-2">
                        </div>
                        <div>
                            <label class="block text-sm font-medium mb-2">ALPN Override</label>
                            <input type="text" v-model="s.ALPN" class="w-full input-dark rounded-lg px-4 py-2" placeholder="h2,http/1.1">
                        </div>
                        <div>
                            <label class="block text-sm font-medium mb-2">TLS Minimum</label>
                            <select v-model="s.TLS_MIN" class="w-full input-dark rounded-lg px-4 py-2"><option>1.0</option><option>1.1</option><option>1.2</option><option>1.3</option></select>
                        </div>
                        <div>
                            <label class="block text-sm font-medium mb-2">TLS Maximum</label>
                            <select v-model="s.TLS_MAX" class="w-full input-dark rounded-lg px-4 py-2"><option>1.2</option><option>1.3</option></select>
                        </div>
                    </div>
                    <div class="flex items-center justify-between mt-6">
                        <div><p class="font-bold">Block QUIC Outbound</p><p class="text-sm text-gray-400">Drops UDP/443 to force clients onto TCP (Bypass ISP throttling)</p></div>
                        <input type="checkbox" v-model="s.BLOCK_QUIC" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between mt-4">
                        <div><p class="font-bold">Enable Mux</p><p class="text-sm text-gray-400">Multiplexing for VLESS</p></div>
                        <input type="checkbox" v-model="s.MUX" class="w-6 h-6 rounded text-purple-500">
                    </div>
                    <div class="flex items-center justify-between mt-4">
                        <div><p class="font-bold">Enable Fragment</p><p class="text-sm text-gray-400">Bypass SNI filtering</p></div>
                        <input type="checkbox" v-model="s.FRAGMENT" class="w-6 h-6 rounded text-purple-500">
                    </div>
                </div>

                <div class="mt-8 pt-6 border-t border-white/10 flex justify-end">
                    <button @click="saveAndBuild" class="btn-gradient px-8 py-3 rounded-lg font-bold text-white flex items-center shadow-lg shadow-purple-500/30">
                        <span v-if="saving" class="animate-spin mr-2">⚙️</span>
                        Save & Rebuild Server
                    </button>
                </div>
            </div>

        </div>
    </div>

    <script>
        const { createApp } = Vue
        createApp({
            data() {
                return {
                    tab: 'dash',
                    s: {}, // state
                    stats: { cpu: 0, mem: 0, network: { rx: '0', tx: '0' } },
                    saving: false,
                    toast: { show: false, msg: '' }
                }
            },
            mounted() {
                this.loadState();
                this.loadStats();
                setInterval(this.loadStats, 5000);
            },
            methods: {
                async loadState() {
                    const res = await fetch('/api/state');
                    this.s = await res.json();
                },
                async loadStats() {
                    if (this.tab !== 'dash') return;
                    const res = await fetch('/api/stats');
                    this.stats = await res.json();
                },
                async saveAndBuild() {
                    this.saving = true;
                    try {
                        const res = await fetch('/api/state', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(this.s)
                        });
                        const data = await res.json();
                        this.showToast(data.msg);
                    } catch (e) {
                        this.showToast('Error saving configuration');
                    }
                    this.saving = false;
                },
                showToast(msg) {
                    this.toast = { show: true, msg };
                    setTimeout(() => this.toast.show = false, 4000);
                }
            }
        }).mount('#app')
    </script>
</body>
</html>
EOF

# Create SystemD Service
echo "${C2}[*] Configuring Systemd Service...${C0}"
cat << EOF > /etc/systemd/system/cr-vpn-panel.service
[Unit]
Description=MOJA Web Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/cr-vpn
Environment="PANEL_PORT=${PANEL_PORT}"
Environment="PANEL_USER=${PANEL_USER}"
Environment="PANEL_PASS=${PANEL_PASS}"
ExecStart=/opt/cr-vpn/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Save Panel port to state for the core script reverse proxy
mkdir -p /etc/vpn-installer
echo "PANEL_PORT=\"${PANEL_PORT}\"" >> /etc/vpn-installer/state.env

systemctl daemon-reload
systemctl enable cr-vpn-panel
systemctl restart cr-vpn-panel

echo ""
echo "${CG}==========================================${C0}"
echo "${CG}✅ Panel Installation Successful!${C0}"
echo "🌐 Panel URL: http://$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'):${PANEL_PORT}"
echo "👤 Username:  ${PANEL_USER}"
echo "🔑 Password:  ${PANEL_PASS}"
echo "${CG}==========================================${C0}"
echo "${C3}Note: You can configure your entire VPN from the web interface now.${C0}"
