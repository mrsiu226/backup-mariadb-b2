#!/usr/bin/env bash
#==============================================================================
# MariaDB → Backblaze B2 | One-line Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main/install.sh | sudo bash
#==============================================================================

# --- Config ------------------------------------------------------------------
GITHUB_RAW="https://raw.githubusercontent.com/mrsiu226/backup-mariadb-b2/main"
INSTALL_DIR="/opt/backup-mariadb-b2"

# Chuyển stdin về /dev/tty ngay lập tức để đọc user input được
# khi script chạy qua pipe: curl ... | bash
if [[ -t 0 ]]; then
    : # stdin đã là terminal
elif exec < /dev/tty 2>/dev/null; then
    : # redirect thành công
else
    echo ""
    echo "  ⚠  Không thể mở /dev/tty. Vui lòng chạy theo cách sau:"
    echo ""
    echo "  curl -fsSL ${GITHUB_RAW}/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh"
    echo ""
    exit 1
fi

# Bật strict mode SAU khi đã xử lý tty (tránh set -e bắt lỗi exec)
set -euo pipefail


# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()      { echo -e "${GREEN}  ✔${NC}  $1"; }
log_info()    { echo -e "${BLUE}  →${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}  ⚠${NC}  $1"; }
log_error()   { echo -e "${RED}  ✘  ERROR: $1${NC}"; exit 1; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

# Input helpers — prompt ra stderr, read từ stdin (đã được exec redirect về /dev/tty)
ask() {
    local prompt="$1" default="${2:-}" var_name="$3"
    local input
    if [[ -n "${default}" ]]; then
        printf "%b" "${BOLD}  ${prompt}${NC} ${CYAN}[${default}]${NC}: " >&2
    else
        printf "%b" "${BOLD}  ${prompt}${NC}: " >&2
    fi
    read -r input
    input="${input:-${default}}"
    printf -v "${var_name}" '%s' "${input}"
}

ask_secret() {
    local prompt="$1" var_name="$2"
    local input
    printf "%b" "${BOLD}  ${prompt}${NC}: " >&2
    read -rs input
    echo "" >&2
    printf -v "${var_name}" '%s' "${input}"
}

ask_yn() {
    local prompt="$1" default="${2:-y}" var_name="$3"
    local input
    if [[ "${default}" == "y" ]]; then
        printf "%b" "${BOLD}  ${prompt}${NC} ${CYAN}[Y/n]${NC}: " >&2
    else
        printf "%b" "${BOLD}  ${prompt}${NC} ${CYAN}[y/N]${NC}: " >&2
    fi
    read -r input
    input="${input:-${default}}"
    printf -v "${var_name}" '%s' "${input,,}"
}

#==============================================================================
# BANNER
#==============================================================================
clear 2>/dev/null || true
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
# AUTO-DETECT: Load defaults từ rclone/config.env có sẵn
#==============================================================================

# Defaults ban đầu
_DEF_B2_ACCOUNT=""
_DEF_B2_KEY=""
_DEF_B2_BUCKET="mariadb-backups"
_DEF_B2_REMOTE="b2"
_DEF_MYSQL_USER="backup_user"
_DEF_MYSQL_PASS=""
_DEF_MYSQL_HOST="localhost"
_DEF_LOCAL_DAYS="3"
_DEF_B2_DAYS="30"
_DEF_EXCLUDE="information_schema performance_schema sys mysql"
_DEF_CRON_HOUR="2"
_DEF_CRON_MIN="30"
_DEF_TG_TOKEN=""
_DEF_TG_CHAT=""

# 1. Thử load từ config.env đã cài trước
if [[ -f "${INSTALL_DIR}/config.env" ]]; then
    source "${INSTALL_DIR}/config.env" 2>/dev/null || true
    _DEF_B2_ACCOUNT="${B2_ACCOUNT_ID:-}"
    _DEF_B2_KEY="${B2_APPLICATION_KEY:-}"
    _DEF_B2_BUCKET="${B2_BUCKET:-mariadb-backups}"
    _DEF_B2_REMOTE="${B2_REMOTE_NAME:-b2}"
    _DEF_MYSQL_USER="${MYSQL_BACKUP_USER:-backup_user}"
    _DEF_MYSQL_PASS="${MYSQL_BACKUP_PASSWORD:-}"
    _DEF_MYSQL_HOST="${MYSQL_HOST:-localhost}"
    _DEF_LOCAL_DAYS="${LOCAL_RETENTION_DAYS:-3}"
    _DEF_B2_DAYS="${B2_RETENTION_DAYS:-30}"
    _DEF_EXCLUDE="${EXCLUDE_DBS:-information_schema performance_schema sys mysql}"
    _DEF_CRON_HOUR="${CRON_HOUR:-2}"
    _DEF_CRON_MIN="${CRON_MINUTE:-30}"
    _DEF_TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    _DEF_TG_CHAT="${TELEGRAM_CHAT_ID:-}"
    echo -e "  ${GREEN}✔  Phát hiện cấu hình cũ tại ${INSTALL_DIR}/config.env — dùng làm mặc định${NC}\n"
fi

# 2. Thử detect từ rclone nếu chưa có account/key
if command -v rclone > /dev/null 2>&1 && [[ -z "${_DEF_B2_ACCOUNT}" ]]; then
    RCLONE_CONF_PATH="${HOME}/.config/rclone/rclone.conf"
    if [[ -f "${RCLONE_CONF_PATH}" ]]; then
        # Tìm section type = b2
        _DETECTED_REMOTE=$(awk '/^\[/{remote=$0} /type = b2/{print remote}' "${RCLONE_CONF_PATH}" \
            | tr -d '[]' | head -1)
        if [[ -n "${_DETECTED_REMOTE}" ]]; then
            _DEF_B2_REMOTE="${_DETECTED_REMOTE}"
            _DEF_B2_ACCOUNT=$(awk "/^\[${_DETECTED_REMOTE}\]/,/^\[/" "${RCLONE_CONF_PATH}" \
                | grep '^account' | awk '{print $3}' | head -1)
            _DEF_B2_KEY=$(awk "/^\[${_DETECTED_REMOTE}\]/,/^\[/" "${RCLONE_CONF_PATH}" \
                | grep '^key' | awk '{print $3}' | head -1)
            echo -e "  ${GREEN}✔  Phát hiện rclone B2 remote '${_DETECTED_REMOTE}' — dùng làm mặc định${NC}\n"
        fi
    fi
fi

#==============================================================================
# STEP 1: COLLECT CONFIG (Interactive)
#==============================================================================
log_section "Bước 1/6 — Cấu hình Backblaze B2"
if [[ -n "${_DEF_B2_ACCOUNT}" ]]; then
    echo -e "  ${CYAN}Đã phát hiện cấu hình B2 có sẵn. Nhấn Enter để giữ nguyên.${NC}\n"
else
    echo -e "  ${YELLOW}Lấy thông tin tại: https://secure.backblaze.com/app_keys.htm${NC}\n"
fi

ask "B2 Account ID (Application Key ID)" "${_DEF_B2_ACCOUNT}" B2_ACCOUNT_ID
ask "B2 Application Key" "${_DEF_B2_KEY}" B2_APPLICATION_KEY
ask "B2 Bucket name" "${_DEF_B2_BUCKET}" B2_BUCKET
ask "B2 Remote name (tên trong rclone)" "${_DEF_B2_REMOTE}" B2_REMOTE_NAME

[[ -z "${B2_ACCOUNT_ID}" ]]     && log_error "B2 Account ID không được để trống"
[[ -z "${B2_APPLICATION_KEY}" ]] && log_error "B2 Application Key không được để trống"

log_section "Bước 2/6 — Cấu hình MariaDB"
if [[ -n "${_DEF_MYSQL_PASS}" ]]; then
    echo -e "  ${CYAN}Đã phát hiện cấu hình MariaDB có sẵn. Nhấn Enter để giữ nguyên.${NC}\n"
else
    echo -e "  ${YELLOW}Tạo user backup riêng (KHÔNG dùng root)${NC}\n"
fi

ask "Tên user backup MariaDB" "${_DEF_MYSQL_USER}" MYSQL_BACKUP_USER

if [[ -n "${_DEF_MYSQL_PASS}" ]]; then
    # Có password cũ — hỏi có muốn giữ không
    ask_yn "Giữ nguyên password cũ cho '${MYSQL_BACKUP_USER}'?" "y" _KEEP_PASS
    if [[ "${_KEEP_PASS}" == "y" ]]; then
        MYSQL_BACKUP_PASSWORD="${_DEF_MYSQL_PASS}"
    else
        ask_secret "Password mới cho '${MYSQL_BACKUP_USER}'" MYSQL_BACKUP_PASSWORD
        [[ -z "${MYSQL_BACKUP_PASSWORD}" ]] && log_error "Password không được để trống"
        ask_secret "Nhập lại password để xác nhận" MYSQL_BACKUP_PASSWORD_CONFIRM
        [[ "${MYSQL_BACKUP_PASSWORD}" != "${MYSQL_BACKUP_PASSWORD_CONFIRM}" ]] \
            && log_error "Password không khớp. Chạy lại installer."
    fi
else
    ask_secret "Password cho user '${MYSQL_BACKUP_USER}'" MYSQL_BACKUP_PASSWORD
    [[ -z "${MYSQL_BACKUP_PASSWORD}" ]] && log_error "Password không được để trống"
    ask_secret "Nhập lại password để xác nhận" MYSQL_BACKUP_PASSWORD_CONFIRM
    [[ "${MYSQL_BACKUP_PASSWORD}" != "${MYSQL_BACKUP_PASSWORD_CONFIRM}" ]] \
        && log_error "Password không khớp. Chạy lại installer."
fi

ask "MySQL host" "${_DEF_MYSQL_HOST}" MYSQL_HOST

log_section "Bước 3/6 — Cấu hình Backup"

ask "Giữ backup local bao nhiêu ngày" "${_DEF_LOCAL_DAYS}" LOCAL_RETENTION_DAYS
ask "Giữ backup trên B2 bao nhiêu ngày" "${_DEF_B2_DAYS}" B2_RETENTION_DAYS
ask "Databases loại trừ khi backup" "${_DEF_EXCLUDE}" EXCLUDE_DBS

log_section "Bước 4/6 — Cấu hình Cronjob"

ask "Giờ chạy backup (0-23)" "${_DEF_CRON_HOUR}" CRON_HOUR
ask "Phút chạy backup (0-59)" "${_DEF_CRON_MIN}" CRON_MINUTE
echo -e "  ${CYAN}→ Backup sẽ chạy lúc ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE}) mỗi ngày${NC}"

log_section "Bước 5/6 — Telegram Notification (tùy chọn)"

_DEF_USE_TG="n"
[[ -n "${_DEF_TG_TOKEN}" ]] && _DEF_USE_TG="y"
ask_yn "Bạn có muốn nhận thông báo Telegram không?" "${_DEF_USE_TG}" USE_TELEGRAM

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
if [[ "${USE_TELEGRAM}" == "y" ]]; then
    ask "Telegram Bot Token" "${_DEF_TG_TOKEN}" TELEGRAM_BOT_TOKEN
    ask "Telegram Chat ID" "${_DEF_TG_CHAT}" TELEGRAM_CHAT_ID
fi

#==============================================================================
# CONFIRM
#==============================================================================
echo ""
echo -e "${BOLD}${CYAN}━━━ Xác nhận cấu hình ━━━${NC}"
echo ""
echo -e "  ${BOLD}B2 Bucket     :${NC} ${B2_BUCKET}"
echo -e "  ${BOLD}B2 Remote     :${NC} ${B2_REMOTE_NAME}"
echo -e "  ${BOLD}MySQL User    :${NC} ${MYSQL_BACKUP_USER}@${MYSQL_HOST}"
echo -e "  ${BOLD}Exclude DBs   :${NC} ${EXCLUDE_DBS}"
echo -e "  ${BOLD}Local keep    :${NC} ${LOCAL_RETENTION_DAYS} ngày"
echo -e "  ${BOLD}B2 keep       :${NC} ${B2_RETENTION_DAYS} ngày"
echo -e "  ${BOLD}Cronjob       :${NC} ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE}) hàng ngày"
echo -e "  ${BOLD}Telegram      :${NC} ${USE_TELEGRAM}"
echo -e "  ${BOLD}Install dir   :${NC} ${INSTALL_DIR}"
echo ""

ask_yn "Tiến hành cài đặt?" "y" CONFIRM
[[ "${CONFIRM}" != "y" ]] && echo "Đã hủy." && exit 0

#==============================================================================
# STEP 2: INSTALL DEPENDENCIES
#==============================================================================
log_section "Bước 6/6 — Cài đặt"

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

install_pkg mysql     mariadb-client
install_pkg gzip      gzip
install_pkg bc        bc
install_pkg curl      curl

# rclone
if ! command -v rclone > /dev/null 2>&1; then
    log_info "Đang cài rclone..."
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1 \
        && log_ok "rclone đã cài" \
        || log_error "Không thể cài rclone"
else
    log_ok "rclone đã có sẵn"
fi

#==============================================================================
# SETUP RCLONE B2
#==============================================================================
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"
mkdir -p "$(dirname "${RCLONE_CONF}")"

if rclone listremotes 2>/dev/null | grep -q "^${B2_REMOTE_NAME}:"; then
    log_warn "rclone remote '${B2_REMOTE_NAME}' đã tồn tại — bỏ qua"
else
    log_info "Tạo rclone remote '${B2_REMOTE_NAME}'..."
    cat >> "${RCLONE_CONF}" << EOF

[${B2_REMOTE_NAME}]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APPLICATION_KEY}
EOF
    log_ok "rclone remote '${B2_REMOTE_NAME}' đã tạo"
fi

log_info "Kiểm tra kết nối B2..."
rclone mkdir "${B2_REMOTE_NAME}:${B2_BUCKET}" > /dev/null 2>&1 \
    && log_ok "Kết nối B2 OK — bucket '${B2_BUCKET}'" \
    || log_error "Không thể kết nối B2. Kiểm tra lại Account ID và Application Key."

#==============================================================================
# SETUP MARIADB USER
#==============================================================================
log_info "Tạo MariaDB user '${MYSQL_BACKUP_USER}'..."

USER_EXISTS=$(mysql -u root -N -e \
    "SELECT COUNT(*) FROM mysql.user WHERE user='${MYSQL_BACKUP_USER}' AND host='localhost';" \
    2>/dev/null || echo "0")

if [[ "${USER_EXISTS}" -gt 0 ]]; then
    log_warn "User đã tồn tại — cập nhật password..."
    mysql -u root -e "
        ALTER USER '${MYSQL_BACKUP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
        FLUSH PRIVILEGES;
    " 2>/dev/null
else
    mysql -u root -e "
        CREATE USER '${MYSQL_BACKUP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
        GRANT SELECT, SHOW DATABASES, LOCK TABLES, RELOAD,
              REPLICATION CLIENT, EVENT, TRIGGER, SHOW VIEW
        ON *.* TO '${MYSQL_BACKUP_USER}'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null && log_ok "User '${MYSQL_BACKUP_USER}' đã tạo" \
        || log_error "Không thể tạo user MariaDB"
fi

#==============================================================================
# DOWNLOAD BACKUP.SH
#==============================================================================
log_info "Tạo thư mục ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

log_info "Tải backup.sh từ GitHub..."
curl -fsSL "${GITHUB_RAW}/backup.sh" -o "${INSTALL_DIR}/backup.sh" \
    && log_ok "backup.sh đã tải" \
    || log_error "Không thể tải backup.sh từ GitHub"
chmod +x "${INSTALL_DIR}/backup.sh"

log_info "Tải và cài mybackup CLI..."
curl -fsSL "${GITHUB_RAW}/mybackup" -o "${INSTALL_DIR}/mybackup" \
    && log_ok "mybackup đã tải" \
    || log_error "Không thể tải mybackup từ GitHub"
chmod +x "${INSTALL_DIR}/mybackup"
ln -sf "${INSTALL_DIR}/mybackup" /usr/local/bin/mybackup
log_ok "mybackup đã cài tại /usr/local/bin/mybackup"

#==============================================================================
# CREATE CONFIG FILES
#==============================================================================
log_info "Tạo config.env..."
cat > "${INSTALL_DIR}/config.env" << EOF
# Được tạo tự động bởi installer | $(date '+%Y-%m-%d %H:%M:%S')
# Hostname: $(hostname)

B2_ACCOUNT_ID="${B2_ACCOUNT_ID}"
B2_APPLICATION_KEY="${B2_APPLICATION_KEY}"
B2_BUCKET="${B2_BUCKET}"
B2_REMOTE_NAME="${B2_REMOTE_NAME}"

MYSQL_BACKUP_USER="${MYSQL_BACKUP_USER}"
MYSQL_BACKUP_PASSWORD="${MYSQL_BACKUP_PASSWORD}"
MYSQL_HOST="${MYSQL_HOST}"

BACKUP_DIR="/root/backups/mariadb"
EXCLUDE_DBS="${EXCLUDE_DBS}"
LOCAL_RETENTION_DAYS=${LOCAL_RETENTION_DAYS}
B2_RETENTION_DAYS=${B2_RETENTION_DAYS}

CRON_MINUTE=${CRON_MINUTE}
CRON_HOUR=${CRON_HOUR}

LOG_DIR="/root/logs"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
EOF
chmod 600 "${INSTALL_DIR}/config.env"
log_ok "config.env đã tạo (chmod 600)"

log_info "Tạo .my.cnf..."
cat > "${INSTALL_DIR}/.my.cnf" << EOF
[client]
user=${MYSQL_BACKUP_USER}
password=${MYSQL_BACKUP_PASSWORD}
host=${MYSQL_HOST}

[mysqldump]
user=${MYSQL_BACKUP_USER}
password=${MYSQL_BACKUP_PASSWORD}
host=${MYSQL_HOST}
EOF
chmod 600 "${INSTALL_DIR}/.my.cnf"
log_ok ".my.cnf đã tạo (chmod 600)"

# Test connection
mysql --defaults-file="${INSTALL_DIR}/.my.cnf" -e "SELECT 1;" > /dev/null 2>&1 \
    && log_ok "Kết nối MariaDB OK" \
    || log_error "Không thể kết nối MariaDB với user '${MYSQL_BACKUP_USER}'"

#==============================================================================
# CREATE DIRECTORIES
#==============================================================================
mkdir -p "/root/backups/mariadb" "/root/logs"
log_ok "Thư mục backup và log đã tạo"

#==============================================================================
# SETUP CRONJOB
#==============================================================================
CRON_CMD="${CRON_MINUTE} ${CRON_HOUR} * * * /bin/bash ${INSTALL_DIR}/backup.sh >> /root/logs/backup_cron.log 2>&1"
CRON_MARKER="backup-mariadb-b2"

( crontab -l 2>/dev/null | grep -v "${CRON_MARKER}" ; \
  echo "# ${CRON_MARKER}" ; \
  echo "${CRON_CMD}" ) | crontab -
log_ok "Cronjob đã thêm: chạy lúc ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE}) mỗi ngày"

#==============================================================================
# TEST RUN
#==============================================================================
ask_yn "Chạy thử backup ngay bây giờ?" "y" RUN_NOW
if [[ "${RUN_NOW}" == "y" ]]; then
    echo ""
    log_info "Đang chạy backup (có thể mất vài phút)..."
    bash "${INSTALL_DIR}/backup.sh" && log_ok "Backup thử nghiệm thành công!" \
        || log_warn "Backup có lỗi, kiểm tra log tại /root/logs/"
fi

#==============================================================================
# DONE
#==============================================================================
echo ""
echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║        ✅  Cài đặt hoàn tất!            ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Install dir :${NC}  ${INSTALL_DIR}"
echo -e "  ${BOLD}Config      :${NC}  ${INSTALL_DIR}/config.env"
echo -e "  ${BOLD}Logs        :${NC}  /root/logs/backup_mariadb_YYYYMMDD.log"
echo -e "  ${BOLD}B2 bucket   :${NC}  ${B2_REMOTE_NAME}:${B2_BUCKET}/$(hostname)/"
echo -e "  ${BOLD}Cronjob     :${NC}  Hàng ngày lúc ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE}) AM"
echo ""
echo -e "  ${CYAN}Chạy thủ công:  bash ${INSTALL_DIR}/backup.sh${NC}"
echo ""
