#!/usr/bin/env bash
#==============================================================================
# MariaDB → Backblaze B2 | One-line Installer (non-interactive)
# Usage: curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/install.sh | sudo bash
#
# Installer này chỉ tải file + cài dependencies, KHÔNG hỏi input.
# Sau khi cài xong, chạy `sudo mybackup --setup` để cấu hình interactive.
#==============================================================================
set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main"
INSTALL_DIR="/opt/backup-mariadb-b2"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()    { echo -e "${GREEN}  ✔${NC}  $1"; }
log_info()  { echo -e "${BLUE}  →${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
log_error() { echo -e "${RED}  ✘  ERROR: $1${NC}"; exit 1; }

#==============================================================================
# BANNER
#==============================================================================
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║     MariaDB → Backblaze B2   Auto Backup Setup      ║
  ║          github.com/mrsiu226/backup-mariadb-b2       ║
  ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "  Hostname : ${BOLD}$(hostname)${NC}"
echo -e "  Date     : $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

#==============================================================================
# CHECK ROOT
#==============================================================================
if [[ $EUID -ne 0 ]]; then
    log_error "Installer phải chạy với quyền root. Dùng: sudo bash install.sh"
fi

#==============================================================================
# INSTALL DEPENDENCIES
#==============================================================================
echo -e "${BOLD}${CYAN}━━━ Cài dependencies ━━━${NC}"

log_info "Cập nhật package list..."
apt-get update -qq > /dev/null 2>&1 || true

install_pkg() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        log_info "Đang cài ${pkg}..."
        apt-get install -y -qq "${pkg}" > /dev/null 2>&1 \
            && log_ok "${pkg} đã cài" \
            || log_error "Không thể cài ${pkg}"
    else
        log_ok "${cmd} đã có sẵn"
    fi
}

install_pkg mysql mariadb-client
install_pkg gzip  gzip
install_pkg zip   zip
install_pkg bc    bc
install_pkg curl  curl

if ! command -v rclone > /dev/null 2>&1; then
    log_info "Đang cài rclone..."
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1 \
        && log_ok "rclone đã cài" \
        || log_error "Không thể cài rclone"
else
    log_ok "rclone đã có sẵn"
fi

#==============================================================================
# DOWNLOAD SCRIPTS
#==============================================================================
echo ""
echo -e "${BOLD}${CYAN}━━━ Tải scripts ━━━${NC}"

log_info "Tạo thư mục ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

log_info "Tải backup.sh..."
curl -fsSL "${GITHUB_RAW}/backup.sh" -o "${INSTALL_DIR}/backup.sh" \
    && chmod +x "${INSTALL_DIR}/backup.sh" \
    && log_ok "backup.sh đã tải" \
    || log_error "Không thể tải backup.sh"

log_info "Tải backup_source.sh..."
curl -fsSL "${GITHUB_RAW}/backup_source.sh" -o "${INSTALL_DIR}/backup_source.sh" \
    && chmod +x "${INSTALL_DIR}/backup_source.sh" \
    && log_ok "backup_source.sh đã tải" \
    || log_error "Không thể tải backup_source.sh"

log_info "Tải mybackup CLI..."
curl -fsSL "${GITHUB_RAW}/mybackup" -o "${INSTALL_DIR}/mybackup" \
    && chmod +x "${INSTALL_DIR}/mybackup" \
    && log_ok "mybackup đã tải" \
    || log_error "Không thể tải mybackup"

ln -sf "${INSTALL_DIR}/mybackup" /usr/local/bin/mybackup
log_ok "mybackup symlink → /usr/local/bin/mybackup"

mkdir -p "/root/backups/mariadb" "/root/backups/source" "/root/logs"
log_ok "Thư mục backup & log đã tạo"

#==============================================================================
# DONE
#==============================================================================
echo ""
echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║        ✅  Cài đặt hoàn tất!            ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Bước tiếp theo — cấu hình:${NC}"
echo ""
echo -e "    ${CYAN}sudo mybackup --setup${NC}"
echo ""
echo -e "  Hoặc xem trợ giúp: ${CYAN}mybackup --help${NC}"
echo ""
