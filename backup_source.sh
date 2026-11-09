#!/bin/bash
#==============================================================================
# Website Source Code Backup to Backblaze B2 via Rclone
# Hỗ trợ cả 2 phiên bản HostVN:
#   - Cũ : /var/hostvn/users/.<domain>.conf          (key=value, có [section])
#   - Mới: /var/hostvn/data/websites/<domain>/.settings.conf  (key='value')
# https://github.com/YOUR_ORG/backup-mariadb-b2
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Load config
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "❌ ERROR: config.env not found. Run ./install.sh first."
    exit 1
fi
# shellcheck source=config.env
source "${CONFIG_FILE}"

#--- Defaults (nếu config cũ chưa có các biến source backup) ------------------
SOURCE_BACKUP_DIR="${SOURCE_BACKUP_DIR:-/root/backups/source}"
SOURCE_EXCLUDE_DOMAINS="${SOURCE_EXCLUDE_DOMAINS:-}"
SOURCE_EXCLUDE_PATTERNS="${SOURCE_EXCLUDE_PATTERNS:-/vendor node_modules .git .svn .cache cache tmp logs *.log error_log* storage/framework/sessions storage/framework/views storage/debugbar var/log .next/cache wp-content/updraft wp-content/backups wp-content/upgrade wp-content/wflogs wp-content/et-cache wp-content/ai1wm-backups wp-content/wp-snapshots wp-content/backups-dup-lite wp-content/wpvividbackups}"
SOURCE_LOCAL_RETENTION_DAYS="${SOURCE_LOCAL_RETENTION_DAYS:-3}"
SOURCE_B2_RETENTION_DAYS="${SOURCE_B2_RETENTION_DAYS:-14}"
# Chu kỳ backup source (ngày): 1=hàng ngày, 3, 5, 7... Chạy tay với --force để bỏ qua.
SOURCE_BACKUP_INTERVAL_DAYS="${SOURCE_BACKUP_INTERVAL_DAYS:-1}"

HOSTVN_OLD_DIR="/var/hostvn/users"
HOSTVN_NEW_DIR="/var/hostvn/data/websites"

#--- Derived vars -------------------------------------------------------------
HOSTNAME=$(hostname)
DATE=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/backup_source_$(date +%Y%m%d).log"
SOURCE_BACKUP_DAILY_DIR="${SOURCE_BACKUP_DIR}/${DATE_DIR}"

#--- Setup dirs ---------------------------------------------------------------
mkdir -p "${LOG_DIR}"

#--- Functions ----------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

send_telegram() {
    local message="$1"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" > /dev/null 2>&1 || true
    fi
}

error_exit() {
    log "❌ ERROR: $1"
    send_telegram "❌ <b>[${HOSTNAME}] Source Backup FAILED</b>%0A${1}"
    exit 1
}

trap 'error_exit "Script failed at line $LINENO"' ERR

#--- Chu kỳ: bỏ qua nếu lần thành công gần nhất chưa đủ N ngày ----------------
LAST_OK_FILE="${SOURCE_BACKUP_DIR}/.last_success"
if [[ "${1:-}" != "--force" && "${SOURCE_BACKUP_INTERVAL_DAYS}" =~ ^[0-9]+$ && -f "${LAST_OK_FILE}" ]]; then
    LAST_OK="$(cat "${LAST_OK_FILE}")"
    if LAST_EPOCH=$(date -d "${LAST_OK}" +%s 2>/dev/null); then
        ELAPSED_DAYS=$(( ($(date -d "${DATE_DIR}" +%s) - LAST_EPOCH) / 86400 ))
        if (( ELAPSED_DAYS < SOURCE_BACKUP_INTERVAL_DAYS )); then
            log "⏭️  Bỏ qua source backup: lần cuối ${LAST_OK} (${ELAPSED_DAYS}/${SOURCE_BACKUP_INTERVAL_DAYS} ngày)"
            exit 0
        fi
    fi
fi
mkdir -p "${SOURCE_BACKUP_DAILY_DIR}"

# Thêm nginx vhost + trạng thái enabled vào zip (thư mục _nginx/). Không có thì bỏ qua.
add_nginx_to_zip() {
    local domain="$1" zip_file="$2" conf="" tmp
    conf="/etc/nginx/sites-available/${domain}.conf"
    [[ -f "${conf}" ]] || conf="$(find /etc/nginx/sites-available -maxdepth 1 -name "${domain}*.conf" 2>/dev/null | head -n1 || true)"
    [[ -n "${conf}" && -f "${conf}" ]] || return 0
    tmp="$(mktemp -d)"
    mkdir "${tmp}/_nginx"
    cp "${conf}" "${tmp}/_nginx/nginx.conf"
    if [[ -e "/etc/nginx/sites-enabled/${domain}.conf" ]]; then
        echo enabled > "${tmp}/_nginx/nginx.enabled"
    else
        echo disabled > "${tmp}/_nginx/nginx.enabled"
    fi
    (cd "${tmp}" && zip -q -X "${zip_file}" _nginx/nginx.conf _nginx/nginx.enabled) >> "${LOG_FILE}" 2>&1 \
        || log "⚠️  ${domain}: không thêm được nginx config vào zip"
    rm -rf "${tmp}"
}

# In: đọc danh sách site, mỗi dòng "domain|source_path"
discover_sites() {
    local conf domain base_dir public_html site_path

    if [[ -d "${HOSTVN_NEW_DIR}" ]]; then
        while IFS= read -r conf; do
            domain=$(grep -m1 "^domain=" "${conf}" | sed -E "s/^domain=//; s/^'//; s/'\$//")
            base_dir=$(grep -m1 "^base_dir=" "${conf}" | sed -E "s/^base_dir=//; s/^'//; s/'\$//")
            [[ -z "${domain}" || -z "${base_dir}" ]] && continue
            if [[ -d "${base_dir}/public_html" ]]; then
                site_path="${base_dir}/public_html"
            else
                site_path="${base_dir}"
            fi
            echo "${domain}|${site_path}"
        done < <(find "${HOSTVN_NEW_DIR}" -mindepth 2 -maxdepth 2 -type f \( -name ".settings.conf" -o -name ".setting.conf" \) 2>/dev/null)
    fi

    if [[ -d "${HOSTVN_OLD_DIR}" ]]; then
        while IFS= read -r conf; do
            domain=$(grep -m1 "^domain=" "${conf}" | cut -d= -f2-)
            public_html=$(grep -m1 "^public_html=" "${conf}" | cut -d= -f2-)
            [[ -z "${domain}" || -z "${public_html}" ]] && continue
            echo "${domain}|${public_html}"
        done < <(find "${HOSTVN_OLD_DIR}" -maxdepth 1 -type f -name "*.conf" 2>/dev/null)
    fi
}

#==============================================================================
# PREFLIGHT CHECKS
#==============================================================================
log "=========================================="
log "🚀 Starting Source Code backup on ${HOSTNAME}"
log "=========================================="

command -v rclone > /dev/null 2>&1 || error_exit "rclone not installed. Run: ./install.sh"
command -v zip    > /dev/null 2>&1 || error_exit "zip not installed. Run: ./install.sh"

if [[ ! -d "${HOSTVN_OLD_DIR}" && ! -d "${HOSTVN_NEW_DIR}" ]]; then
    error_exit "Không tìm thấy ${HOSTVN_OLD_DIR} hoặc ${HOSTVN_NEW_DIR} — không phải server HostVN?"
fi

#==============================================================================
# DISCOVER SITES (dedupe theo domain, ưu tiên bản mới)
#==============================================================================
declare -A SEEN_DOMAIN
SITES=()
while IFS='|' read -r DOMAIN SITE_PATH; do
    [[ -z "${DOMAIN}" ]] && continue
    [[ -n "${SEEN_DOMAIN[${DOMAIN}]:-}" ]] && continue
    SEEN_DOMAIN["${DOMAIN}"]=1
    SITES+=("${DOMAIN}|${SITE_PATH}")
done < <(discover_sites)

log "🔎 Phát hiện ${#SITES[@]} website"

#==============================================================================
# BUILD ZIP EXCLUDE PATTERNS
# - Thư mục (không chứa *): loại trừ cả dir lẫn nội dung bên trong
# - File glob (chứa *): chỉ match file, không thêm hậu tố /*
#==============================================================================
set -f   # tắt glob: pattern như *.log không được bung theo thư mục hiện tại
ZIP_EXCLUDES=()
ROOT_EXCLUDES=""   # pattern bắt đầu bằng "/" → chỉ loại ở gốc site (vd /vendor), ghép tiền tố theo từng site
for PATTERN in ${SOURCE_EXCLUDE_PATTERNS}; do
    if [[ "${PATTERN}" == /* ]]; then
        ROOT_EXCLUDES="${ROOT_EXCLUDES} ${PATTERN#/}"
    elif [[ "${PATTERN}" == *"*"* ]]; then
        # File glob pattern (e.g. *.log, *.webm) — match mọi cấp thư mục
        ZIP_EXCLUDES+=("*/${PATTERN}" "${PATTERN}")
    else
        # Thư mục — loại trừ chính thư mục và toàn bộ nội dung bên trong
        ZIP_EXCLUDES+=("*/${PATTERN}/" "*/${PATTERN}/*" "${PATTERN}/" "${PATTERN}/*")
    fi
done
set +f

#==============================================================================
# ZIP EACH SITE
#==============================================================================
TOTAL_SIZE=0
SITE_COUNT=0
FAILED_SITES=""
SKIPPED_SITES=""

for ENTRY in "${SITES[@]:-}"; do
    [[ -z "${ENTRY}" ]] && continue
    IFS='|' read -r DOMAIN SITE_PATH <<< "${ENTRY}"

    if echo "${SOURCE_EXCLUDE_DOMAINS}" | grep -qw "${DOMAIN}"; then
        log "⏭️  Skipping (excluded): ${DOMAIN}"
        continue
    fi

    if [[ ! -d "${SITE_PATH}" ]]; then
        log "⏭️  Skipping ${DOMAIN}: path không tồn tại (${SITE_PATH})"
        SKIPPED_SITES="${SKIPPED_SITES} ${DOMAIN}"
        continue
    fi

    ZIP_FILE="${SOURCE_BACKUP_DAILY_DIR}/${DOMAIN}_${DATE}.zip"
    log "📦 Zipping source: ${DOMAIN} (${SITE_PATH}) ..."

    SITE_PARENT="$(dirname "${SITE_PATH}")"
    SITE_BASENAME="$(basename "${SITE_PATH}")"

    SITE_EXCLUDES=("${ZIP_EXCLUDES[@]}")
    for ROOT_NAME in ${ROOT_EXCLUDES}; do
        SITE_EXCLUDES+=("${SITE_BASENAME}/${ROOT_NAME}/" "${SITE_BASENAME}/${ROOT_NAME}/*")
    done

    # -y: store symlinks as-is (không follow) → tránh symlink vòng lặp gây file khổng lồ
    if (cd "${SITE_PARENT}" && zip -r -q -X -y "${ZIP_FILE}" "${SITE_BASENAME}" -x "${SITE_EXCLUDES[@]}") >> "${LOG_FILE}" 2>&1; then
        add_nginx_to_zip "${DOMAIN}" "${ZIP_FILE}"
        FILE_SIZE=$(stat -c%s "${ZIP_FILE}" 2>/dev/null || echo 0)
        FILE_SIZE_MB=$(echo "scale=2; ${FILE_SIZE}/1024/1024" | bc)
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        SITE_COUNT=$((SITE_COUNT + 1))
        log "✅ ${DOMAIN} — ${FILE_SIZE_MB} MB"
    else
        log "❌ FAILED: ${DOMAIN}"
        FAILED_SITES="${FAILED_SITES} ${DOMAIN}"
        rm -f "${ZIP_FILE}"
    fi
done

#==============================================================================
# UPLOAD TO B2
#==============================================================================
log "☁️  Uploading to ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DATE_DIR}/"
rclone mkdir "${B2_REMOTE_NAME}:${B2_BUCKET}" 2>/dev/null || true

if rclone copy \
    "${SOURCE_BACKUP_DAILY_DIR}/" \
    "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DATE_DIR}/" \
    --transfers 4 \
    --checkers 8 \
    --b2-hard-delete \
    --log-file="${LOG_FILE}" \
    --log-level INFO \
    --stats-one-line; then
    log "✅ Upload completed"
else
    error_exit "Upload to B2 failed"
fi

#==============================================================================
# VERIFY
#==============================================================================
log "🔍 Verifying upload..."
REMOTE_COUNT=$(rclone ls "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DATE_DIR}/" 2>/dev/null | wc -l)
LOCAL_COUNT=$(ls -1 "${SOURCE_BACKUP_DAILY_DIR}/"*.zip 2>/dev/null | wc -l)

if [[ "${REMOTE_COUNT}" -ge "${LOCAL_COUNT}" ]]; then
    log "✅ Verified: ${REMOTE_COUNT} files on B2, ${LOCAL_COUNT} files local"
else
    log "⚠️  WARNING: Mismatch — Remote: ${REMOTE_COUNT}, Local: ${LOCAL_COUNT}"
fi

#==============================================================================
# CLEANUP LOCAL
#==============================================================================
log "🧹 Cleaning local source backups older than ${SOURCE_LOCAL_RETENTION_DAYS} days..."
find "${SOURCE_BACKUP_DIR}" -type f -name "*.zip" -mtime +${SOURCE_LOCAL_RETENTION_DAYS} -delete 2>/dev/null
find "${SOURCE_BACKUP_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
log "✅ Local cleanup done"

#==============================================================================
# CLEANUP B2
#==============================================================================
log "🧹 Cleaning B2 source backups older than ${SOURCE_B2_RETENTION_DAYS} days..."
REMOTE_DIRS=$(rclone lsd "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/" 2>/dev/null | awk '{print $NF}' || true)
CUTOFF_DATE=$(date -d "-${SOURCE_B2_RETENTION_DAYS} days" +%Y-%m-%d)

for DIR in ${REMOTE_DIRS}; do
    if [[ "${DIR}" < "${CUTOFF_DATE}" ]] && [[ "${DIR}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "🗑️  Removing old B2 source backup: ${DIR}"
        rclone purge "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DIR}/" 2>/dev/null || true
    fi
done
log "✅ B2 cleanup done"

# Chỉ ghi mốc khi không có site lỗi → lần cron sau tự thử lại
[[ -z "${FAILED_SITES}" ]] && echo "${DATE_DIR}" > "${LAST_OK_FILE}"

#==============================================================================
# SUMMARY
#==============================================================================
TOTAL_SIZE_MB=$(echo "scale=2; ${TOTAL_SIZE}/1024/1024" | bc)

log "=========================================="
log "📊 SOURCE BACKUP SUMMARY"
log "=========================================="
log "  Hostname   : ${HOSTNAME}"
log "  Websites   : ${SITE_COUNT} backed up"
log "  Total size : ${TOTAL_SIZE_MB} MB"
log "  Local path : ${SOURCE_BACKUP_DAILY_DIR}/"
log "  Remote     : ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DATE_DIR}/"
log "  Local keep : ${SOURCE_LOCAL_RETENTION_DAYS} days"
log "  B2 keep    : ${SOURCE_B2_RETENTION_DAYS} days"
log "  Interval   : mỗi ${SOURCE_BACKUP_INTERVAL_DAYS} ngày"
[[ -n "${SKIPPED_SITES}" ]] && log "  ⏭️  Skipped :${SKIPPED_SITES}"
[[ -n "${FAILED_SITES}" ]] && log "  ⚠️  Failed  :${FAILED_SITES}"
log "=========================================="
log "✅ Source backup completed at $(date '+%Y-%m-%d %H:%M:%S')"
log "=========================================="

NOTIFY_MSG="✅ <b>[${HOSTNAME}] Source Backup OK</b>
📦 ${SITE_COUNT} websites | ${TOTAL_SIZE_MB} MB
📁 ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/source/${DATE_DIR}/
🕐 $(date '+%H:%M %d/%m/%Y')"
[[ -n "${FAILED_SITES}" ]] && NOTIFY_MSG="${NOTIFY_MSG}
⚠️ Failed:${FAILED_SITES}"

send_telegram "${NOTIFY_MSG}"
exit 0
