#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/build.func)

# =============================================================================
# OpenOutreach LXC Installer
# https://github.com/genetto/OpenOutreach
# =============================================================================

APP="OpenOutreach"
var_tags="openoutreach"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

# Standard community-scripts wizard — sets CTID, hostname, network, storage etc.
start

# Collect OpenOutreach-specific config after CTID is assigned
LLM_API_KEY=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} Setup" \
  --inputbox "LLM API Key (leave blank to configure later in /opt/openoutreach/.env):" 10 70 \
  3>&1 1>&2 2>&3) || true

AI_MODEL=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} Setup" \
  --inputbox "LLM Model (e.g. gpt-4o, claude-sonnet-4-20250514):" 10 70 "gpt-4o" \
  3>&1 1>&2 2>&3) || true
AI_MODEL="${AI_MODEL:-gpt-4o}"

# Create the LXC container
build_container

# Run OpenOutreach install script inside the container
msg_info "Installing ${APP} inside container ${CTID}"
pct exec "${CTID}" -- bash -c "
  export LLM_API_KEY='${LLM_API_KEY}'
  export AI_MODEL='${AI_MODEL}'
  bash <(curl -fsSL https://raw.githubusercontent.com/genetto/OpenOutreach/refs/heads/master/openoutreach-install.sh)
"
msg_ok "${APP} installed"

# Print summary
IP=$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${GN}${APP} is ready!${CL}"
echo ""
echo -e "  Django Admin:  ${BL}http://${IP}/admin/${CL}"
echo -e "  VNC (browser): ${BL}${IP}:5900${CL}"
echo -e "  Service:       ${BL}systemctl status openoutreach${CL}"
echo ""
echo -e "  To set your API key later: ${BL}nano /opt/openoutreach/.env${CL}"
echo ""
