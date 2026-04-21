#!/bin/bash
#==============================================================================
# install.sh — Setup MariaDB B2 Backup trên server mới
# Chạy 1 lần duy nhất: sudo bash install.sh
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

#--- Colors -------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_section() { echo -e "\n${BOLD}${CYAN}==== $1 ====${NC}"; }

#==============================================================================
# BANNER
#==============================================================================
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ____             _                   __  __           _       ____  ____
 | __ )  __ _  ___| | ___   _ _ __   |  \/  | __ _ _ _(_) __ _|  _ \| __ )
 |  _ \ / _` |/ __| |/ / | | | '_ \  | |\/| |/ _` | '__| |/ _` | | | |  _ \
 | |_) | (_| | (__|   <| |_| | |_) | | |  | | (_| | |  | | (_| | |_| | |_) |
 |____/ \__,_|\___|_|\_\\__,_| .__/  |_|  |_|\__,_|_|  |_|\__,_|____/|____/
                               |_|
EOF
echo -e "${NC}"
echo -e "  MariaDB → Backblaze B2 Backup Installer"
echo -e "  Hostname: $(hostname) | Date: $(date '+%Y-%m-%d %H:%M:%S')\n"

#==============================================================================
# STEP 1: Load config.env
#==============================================================================
log_section "Step 1: Load Config"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_warn "config.env not found. Creating from template..."
    cp "${SCRIPT_DIR}/config.example.env" "${CONFIG_FILE}"
    log_error "Please edit ${CONFIG_FILE} with your credentials then re-run install.sh"
fi

# shellcheck source=config.env
source "${CONFIG_FILE}"

# Validate required fields
for VAR in B2_ACCOUNT_ID B2_APPLICATION_KEY B2_BUCKET B2_REMOTE_NAME \
           MYSQL_BACKUP_USER MYSQL_BACKUP_PASSWORD; do
    VALUE="${!VAR:-}"
    if [[ -z "${VALUE}" || "${VALUE}" == *"CHANGE_ME"* || "${VALUE}" == *"your_"* ]]; then
        log_error "${VAR} is not set in config.env. Please fill it in."
    fi
done

log_ok "Config loaded from ${CONFIG_FILE}"

#==============================================================================
# STEP 2: Check dependencies
#==============================================================================
log_section "Step 2: Check Dependencies"

install_if_missing() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        log_info "Installing ${pkg}..."
        apt-get install -y "${pkg}" > /dev/null 2>&1 && log_ok "${pkg} installed" \
            || log_error "Failed to install ${pkg}"
    else
        log_ok "${cmd} already installed"
    fi
}

install_if_missing mysql     mariadb-client
install_if_missing mysqldump mariadb-client
install_if_missing gzip      gzip
install_if_missing bc        bc
install_if_missing curl      curl

# Install rclone if missing
if ! command -v rclone > /dev/null 2>&1; then
    log_info "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1
    log_ok "rclone installed"
else
    log_ok "rclone already installed ($(rclone version --no-check-update 2>/dev/null | head -1))"
fi

#==============================================================================
# STEP 3: Configure rclone for B2
#==============================================================================
log_section "Step 3: Configure Rclone → B2"

RCLONE_CONFIG_DIR="${HOME}/.config/rclone"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_DIR}/rclone.conf"
mkdir -p "${RCLONE_CONFIG_DIR}"

if rclone listremotes 2>/dev/null | grep -q "^${B2_REMOTE_NAME}:"; then
    log_warn "rclone remote '${B2_REMOTE_NAME}' already exists — skipping"
else
    log_info "Creating rclone remote '${B2_REMOTE_NAME}'..."
    cat >> "${RCLONE_CONFIG_FILE}" << EOF

[${B2_REMOTE_NAME}]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}
EOF
    log_ok "rclone remote '${B2_REMOTE_NAME}' created"
fi

# Test connection
log_info "Testing B2 connection..."
rclone mkdir "${B2_REMOTE_NAME}:${B2_BUCKET}" > /dev/null 2>&1 \
    && log_ok "B2 bucket '${B2_BUCKET}' accessible" \
    || log_error "Cannot connect to B2. Check B2_ACCOUNT_ID and B2_APPLICATION_KEY."

#==============================================================================
# STEP 4: Create MariaDB backup user
#==============================================================================
log_section "Step 4: Setup MariaDB Backup User"

# Kiểm tra user đã tồn tại chưa
USER_EXISTS=$(mysql -u root -N -e \
    "SELECT COUNT(*) FROM mysql.user WHERE user='${MYSQL_BACKUP_USER}' AND host='localhost';" \
    2>/dev/null || echo "0")

if [[ "${USER_EXISTS}" -gt 0 ]]; then
    log_warn "User '${MYSQL_BACKUP_USER}'@'localhost' already exists — updating password..."
    mysql -u root -e "
        ALTER USER '${MYSQL_BACKUP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
        FLUSH PRIVILEGES;
    " 2>/dev/null || log_warn "Could not update user (may need root password)"
else
    log_info "Creating MariaDB user '${MYSQL_BACKUP_USER}'..."
    mysql -u root -e "
        CREATE USER '${MYSQL_BACKUP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
        GRANT SELECT, SHOW DATABASES, LOCK TABLES, RELOAD,
              REPLICATION CLIENT, EVENT, TRIGGER, SHOW VIEW
        ON *.* TO '${MYSQL_BACKUP_USER}'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null && log_ok "User '${MYSQL_BACKUP_USER}'@'localhost' created" \
        || log_error "Failed to create MariaDB user. Ensure you can login as root without password."
fi

#==============================================================================
# STEP 5: Create .my.cnf
#==============================================================================
log_section "Step 5: Create .my.cnf"

MY_CNF="${SCRIPT_DIR}/.my.cnf"
cat > "${MY_CNF}" << EOF
[client]
user=${MYSQL_BACKUP_USER}
password=${MYSQL_BACKUP_PASSWORD}
host=${MYSQL_HOST:-localhost}

[mysqldump]
user=${MYSQL_BACKUP_USER}
password=${MYSQL_BACKUP_PASSWORD}
host=${MYSQL_HOST:-localhost}
EOF
chmod 600 "${MY_CNF}"
log_ok ".my.cnf created at ${MY_CNF}"

# Test connection
mysql --defaults-file="${MY_CNF}" -e "SELECT 1;" > /dev/null 2>&1 \
    && log_ok "MariaDB connection test passed" \
    || log_error "Cannot connect with backup_user. Check credentials."

#==============================================================================
# STEP 6: Create directories
#==============================================================================
log_section "Step 6: Create Directories"

mkdir -p "${BACKUP_DIR}" "${LOG_DIR}"
log_ok "Backup dir : ${BACKUP_DIR}"
log_ok "Log dir    : ${LOG_DIR}"

#==============================================================================
# STEP 7: Chmod scripts
#==============================================================================
log_section "Step 7: Set Permissions"

chmod +x "${SCRIPT_DIR}/backup.sh"
log_ok "backup.sh is executable"

#==============================================================================
# STEP 8: Install cronjob
#==============================================================================
log_section "Step 8: Setup Cronjob"

CRON_CMD="${CRON_MINUTE:-30} ${CRON_HOUR:-2} * * * /bin/bash ${SCRIPT_DIR}/backup.sh >> ${LOG_DIR}/backup_cron.log 2>&1"
CRON_MARKER="backup-mariadb-b2"

# Xóa cronjob cũ nếu có, thêm mới
( crontab -l 2>/dev/null | grep -v "${CRON_MARKER}" ; \
  echo "# ${CRON_MARKER}" ; \
  echo "${CRON_CMD}" ) | crontab -

log_ok "Cronjob added: runs daily at ${CRON_HOUR:-2}:$(printf '%02d' ${CRON_MINUTE:-30})"

#==============================================================================
# DONE
#==============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================${NC}"
echo -e "${BOLD}${GREEN}  ✅ Installation complete!${NC}"
echo -e "${BOLD}${GREEN}============================================${NC}"
echo ""
echo -e "  ${BOLD}Test run:${NC}    bash ${SCRIPT_DIR}/backup.sh"
echo -e "  ${BOLD}Logs:${NC}        ${LOG_DIR}/backup_mariadb_\$(date +%Y%m%d).log"
echo -e "  ${BOLD}B2 bucket:${NC}   ${B2_REMOTE_NAME}:${B2_BUCKET}/$(hostname)/"
echo -e "  ${BOLD}Cronjob:${NC}     daily at ${CRON_HOUR:-2}:$(printf '%02d' ${CRON_MINUTE:-30}) AM"
echo ""
