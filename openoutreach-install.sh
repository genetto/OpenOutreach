#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OpenOutreach Install Script (runs inside LXC)
# https://github.com/genetto/OpenOutreach
# =============================================================================

APP="OpenOutreach"
REPO="https://github.com/genetto/OpenOutreach.git"
INSTALL_DIR="/opt/openoutreach"
SERVICE_USER="openoutreach"
PYTHON=".venv/bin/python"

# Colors (fallback if not sourced from core.func)
BL='\033[0;34m' GN='\033[0;32m' RD='\033[0;31m' YW='\033[0;33m' CL='\033[0m'
msg_info()  { echo -e "${BL}[INFO]${CL} $*"; }
msg_ok()    { echo -e "${GN}[OK]${CL}   $*"; }
msg_error() { echo -e "${RD}[ERR]${CL}  $*"; exit 1; }
msg_warn()  { echo -e "${YW}[WARN]${CL} $*"; }

# =============================================================================
# 1. System packages
# =============================================================================
msg_info "Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq
msg_ok "System packages updated"

msg_info "Installing dependencies"
apt-get install -y -qq \
  git curl wget gnupg ca-certificates \
  python3 python3-pip python3-venv \
  nginx \
  xvfb x11vnc \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libgbm1 libasound2 libpango-1.0-0 libpangocairo-1.0-0 \
  fonts-liberation libappindicator3-1 libx11-xcb1
msg_ok "Dependencies installed"

# =============================================================================
# 2. Service user
# =============================================================================
msg_info "Creating service user: ${SERVICE_USER}"
if ! id "${SERVICE_USER}" &>/dev/null; then
  useradd --system --shell /bin/bash --home "${INSTALL_DIR}" --create-home "${SERVICE_USER}"
fi
msg_ok "Service user ready"

# =============================================================================
# 3. Clone repository
# =============================================================================
msg_info "Cloning ${APP} from GitHub"
if [ -d "${INSTALL_DIR}/.git" ]; then
  msg_warn "Directory exists — pulling latest instead"
  git -C "${INSTALL_DIR}" pull --ff-only
else
  git clone --depth=1 "${REPO}" "${INSTALL_DIR}"
fi
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
msg_ok "Repository cloned to ${INSTALL_DIR}"

# =============================================================================
# 4. Python virtual environment & dependencies
# =============================================================================
msg_info "Creating Python venv and installing requirements"
cd "${INSTALL_DIR}"
sudo -u "${SERVICE_USER}" python3 -m venv .venv
sudo -u "${SERVICE_USER}" .venv/bin/pip install --quiet --upgrade pip
sudo -u "${SERVICE_USER}" .venv/bin/pip install --quiet -r requirements/prod.txt
msg_ok "Python dependencies installed"

# =============================================================================
# 5. Playwright browsers
# =============================================================================
msg_info "Installing Playwright browsers (Chromium)"
sudo -u "${SERVICE_USER}" .venv/bin/python -m playwright install chromium
sudo -u "${SERVICE_USER}" .venv/bin/python -m playwright install-deps chromium || true
msg_ok "Playwright Chromium installed"

# =============================================================================
# 6. .env file
# =============================================================================
msg_info "Writing .env file"
cat > "${INSTALL_DIR}/.env" <<EOF
LLM_API_KEY=${LLM_API_KEY:-changeme}
AI_MODEL=${AI_MODEL:-gpt-4o}
DJANGO_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=*
DISPLAY=:99
EOF
chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/.env"
msg_ok ".env file written"

# =============================================================================
# 7. Database migrations + CRM bootstrap
# =============================================================================
msg_info "Running database migrations"
cd "${INSTALL_DIR}"
sudo -u "${SERVICE_USER}" "${PYTHON}" manage.py migrate --noinput
msg_ok "Migrations complete"

msg_info "Bootstrapping CRM"
sudo -u "${SERVICE_USER}" "${PYTHON}" manage.py bootstrap_crm 2>/dev/null || \
  msg_warn "bootstrap_crm command not found — skipping (run manually if needed)"
msg_ok "CRM bootstrap done"

# =============================================================================
# 8. Nginx — proxy Django Admin on port 80
# =============================================================================
msg_info "Configuring Nginx"
cat > /etc/nginx/sites-available/openoutreach <<'EOF'
server {
    listen 80;
    server_name _;

    location /static/ {
        alias /opt/openoutreach/staticfiles/;
    }

    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/openoutreach /etc/nginx/sites-enabled/openoutreach
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
msg_ok "Nginx configured"

# Collect static files
cd "${INSTALL_DIR}"
sudo -u "${SERVICE_USER}" "${PYTHON}" manage.py collectstatic --noinput --clear -v 0 2>/dev/null || true

# =============================================================================
# 9. VNC — virtual display on :99, VNC on port 5900
# =============================================================================
msg_info "Configuring virtual display + VNC"
cat > /etc/systemd/system/openoutreach-xvfb.service <<EOF
[Unit]
Description=OpenOutreach Virtual Display (Xvfb)
Before=openoutreach.service openoutreach-vnc.service
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x900x24 -nolisten tcp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/openoutreach-vnc.service <<EOF
[Unit]
Description=OpenOutreach VNC Server (x11vnc)
After=openoutreach-xvfb.service
Requires=openoutreach-xvfb.service

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=/usr/bin/x11vnc -display :99 -forever -nopw -shared -rfbport 5900
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
msg_ok "VNC services configured"

# =============================================================================
# 10. Systemd service — OpenOutreach daemon
# =============================================================================
msg_info "Creating systemd service for OpenOutreach daemon"
cat > /etc/systemd/system/openoutreach.service <<EOF
[Unit]
Description=OpenOutreach Daemon
After=network.target openoutreach-xvfb.service
Requires=openoutreach-xvfb.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/${PYTHON} manage.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openoutreach-xvfb openoutreach-vnc openoutreach
systemctl start openoutreach-xvfb openoutreach-vnc openoutreach
msg_ok "OpenOutreach daemon started"

# =============================================================================
# Done
# =============================================================================
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GN}Installation complete.${CL}"
echo -e "  Django Admin:  http://${IP}/admin/"
echo -e "  VNC:           ${IP}:5900"
echo -e "  Logs:          journalctl -u openoutreach -f"
echo -e "  Config:        ${INSTALL_DIR}/.env"
echo ""
if [ "${LLM_API_KEY:-changeme}" = "changeme" ]; then
  echo -e "${YW}[!] Remember to set LLM_API_KEY in ${INSTALL_DIR}/.env${CL}"
  echo -e "    Then: systemctl restart openoutreach"
  echo ""
fi
