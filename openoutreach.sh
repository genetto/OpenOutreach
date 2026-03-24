#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/core.func)

# =============================================================================
# OpenOutreach LXC Installer
# https://github.com/genetto/OpenOutreach
# =============================================================================

APP="OpenOutreach"
var_tags="community-script"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"

header_info() {
  clear
  cat <<"EOF"
   ____                   ____        __                     __  
  / __ \____  ___  ____  / __ \__  __/ /_________  ____ ____/ /_ 
 / / / / __ \/ _ \/ __ \/ / / / / / / __/ ___/ _ \/ __ `/ __  / 
/ /_/ / /_/ /  __/ / / / /_/ / /_/ / /_/ /  /  __/ /_/ / /_/ /  
\____/ .___/\___/_/ /_/\____/\__,_/\__/_/   \___/\__,_/\__,_/   
    /_/                                                            
EOF
}

header_info
echo -e "${BL}This will create a new LXC for ${APP}.${CL}"
echo -e "  - Debian 12 | ${var_cpu} vCPU | ${var_ram} MB RAM | ${var_disk} GB Disk"
echo ""

# Confirm
if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} LXC" \
  --yesno "Create a new ${APP} LXC?" 10 58; then
  msg_error "Aborted."
  exit 0
fi

# Collect optional .env values upfront
REPLY=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} Setup" \
  --inputbox "LLM API Key (leave blank to configure later):" 10 58 \
  3>&1 1>&2 2>&3) || true
LLM_API_KEY="${REPLY:-}"

REPLY=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "${APP} Setup" \
  --inputbox "LLM Model (e.g. gpt-4o, claude-sonnet-4-20250514):" 10 58 "gpt-4o" \
  3>&1 1>&2 2>&3) || true
AI_MODEL="${REPLY:-gpt-4o}"

# Create LXC via community-scripts helper
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/build.func)
build_container

# Run install script inside the new container
msg_info "Installing ${APP} inside container ${CTID}"
pct exec "${CTID}" -- bash -c "
  export LLM_API_KEY='${LLM_API_KEY}'
  export AI_MODEL='${AI_MODEL}'
  bash <(curl -fsSL https://raw.githubusercontent.com/genetto/OpenOutreach/refs/heads/master/openoutreach-install.sh)
"

msg_ok "${APP} installed in LXC ${CTID}"

# Print summary
IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')
header_info
echo -e "${GN}${APP} is ready.${CL}\n"
echo -e "  Django Admin:  ${BL}http://${IP}/admin/${CL}"
echo -e "  VNC (browser): ${BL}${IP}:5900${CL}"
echo -e "  Service:       ${BL}systemctl status openoutreach${CL}"
echo ""
echo -e "  Edit /opt/openoutreach/.env to add your API key if you skipped it."
echo ""
