#!/bin/bash
#==============================================================================
# MariaDB Auto Backup to Backblaze B2 via Rclone
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

#--- Derived vars -------------------------------------------------------------
HOSTNAME=$(hostname)
DATE=$(date +%Y%m%d_%H%M%S)
DATE_DIR=$(date +%Y-%m-%d)
MYSQL_DEFAULTS_FILE="${SCRIPT_DIR}/.my.cnf"
LOG_FILE="${LOG_DIR}/backup_mariadb_$(date +%Y%m%d).log"
BACKUP_DAILY_DIR="${BACKUP_DIR}/${DATE_DIR}"

#--- Setup dirs ---------------------------------------------------------------
mkdir -p "${BACKUP_DAILY_DIR}" "${LOG_DIR}"

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
    send_telegram "❌ <b>[${HOSTNAME}] DB Backup FAILED</b>%0A${1}"
    exit 1
}

trap 'error_exit "Script failed at line $LINENO"' ERR

#==============================================================================
# PREFLIGHT CHECKS
#==============================================================================
log "=========================================="
log "🚀 Starting MariaDB backup on ${HOSTNAME}"
log "=========================================="

command -v rclone    > /dev/null 2>&1 || error_exit "rclone not installed. Run: ./install.sh"
command -v mysqldump > /dev/null 2>&1 || error_exit "mysqldump not installed"
command -v gzip      > /dev/null 2>&1 || error_exit "gzip not installed"

[[ -f "${MYSQL_DEFAULTS_FILE}" ]] || error_exit ".my.cnf not found. Run: ./install.sh"

mysql --defaults-file="${MYSQL_DEFAULTS_FILE}" -e "SELECT 1;" > /dev/null 2>&1 \
    || error_exit "Cannot connect to MariaDB. Check .my.cnf credentials."

#==============================================================================
# BACKUP EACH DATABASE
#==============================================================================
ALL_DBS=$(mysql --defaults-file="${MYSQL_DEFAULTS_FILE}" -N -e "SHOW DATABASES;")

TOTAL_SIZE=0
DB_COUNT=0
FAILED_DBS=""

for DB in ${ALL_DBS}; do
    if echo "${EXCLUDE_DBS}" | grep -qw "${DB}"; then
        log "⏭️  Skipping: ${DB}"
        continue
    fi

    DUMP_FILE="${BACKUP_DAILY_DIR}/${DB}_${DATE}.sql.gz"
    log "📦 Backing up: ${DB} ..."

    if mysqldump --defaults-file="${MYSQL_DEFAULTS_FILE}" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --quick \
        --lock-tables=false \
        "${DB}" 2>> "${LOG_FILE}" | gzip -9 > "${DUMP_FILE}"; then

        FILE_SIZE=$(stat -c%s "${DUMP_FILE}" 2>/dev/null || echo 0)
        FILE_SIZE_MB=$(echo "scale=2; ${FILE_SIZE}/1024/1024" | bc)
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        DB_COUNT=$((DB_COUNT + 1))
        log "✅ ${DB} — ${FILE_SIZE_MB} MB"
    else
        log "❌ FAILED: ${DB}"
        FAILED_DBS="${FAILED_DBS} ${DB}"
        rm -f "${DUMP_FILE}"
    fi
done

#==============================================================================
# BACKUP ALL-IN-ONE
#==============================================================================
ALL_DB_FILE="${BACKUP_DAILY_DIR}/all_databases_${DATE}.sql.gz"
log "📦 Creating all-databases dump..."

if mysqldump --defaults-file="${MYSQL_DEFAULTS_FILE}" \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --quick \
    --lock-tables=false \
    2>> "${LOG_FILE}" | gzip -9 > "${ALL_DB_FILE}"; then

    ALL_SIZE=$(stat -c%s "${ALL_DB_FILE}" 2>/dev/null || echo 0)
    ALL_SIZE_MB=$(echo "scale=2; ${ALL_SIZE}/1024/1024" | bc)
    TOTAL_SIZE=$((TOTAL_SIZE + ALL_SIZE))
    log "✅ All databases — ${ALL_SIZE_MB} MB"
else
    log "❌ FAILED: all-databases dump"
    rm -f "${ALL_DB_FILE}"
fi

#==============================================================================
# UPLOAD TO B2
#==============================================================================
log "☁️  Uploading to ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DATE_DIR}/"
rclone mkdir "${B2_REMOTE_NAME}:${B2_BUCKET}" 2>/dev/null || true

if rclone copy \
    "${BACKUP_DAILY_DIR}/" \
    "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DATE_DIR}/" \
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
REMOTE_COUNT=$(rclone ls "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DATE_DIR}/" 2>/dev/null | wc -l)
LOCAL_COUNT=$(ls -1 "${BACKUP_DAILY_DIR}/"*.gz 2>/dev/null | wc -l)

if [[ "${REMOTE_COUNT}" -ge "${LOCAL_COUNT}" ]]; then
    log "✅ Verified: ${REMOTE_COUNT} files on B2, ${LOCAL_COUNT} files local"
else
    log "⚠️  WARNING: Mismatch — Remote: ${REMOTE_COUNT}, Local: ${LOCAL_COUNT}"
fi

#==============================================================================
# CLEANUP LOCAL
#==============================================================================
log "🧹 Cleaning local backups older than ${LOCAL_RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "*.sql.gz" -mtime +${LOCAL_RETENTION_DAYS} -delete 2>/dev/null
find "${BACKUP_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
log "✅ Local cleanup done"

#==============================================================================
# CLEANUP B2
#==============================================================================
log "🧹 Cleaning B2 backups older than ${B2_RETENTION_DAYS} days..."
REMOTE_DIRS=$(rclone lsd "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/" 2>/dev/null | awk '{print $NF}' || true)
CUTOFF_DATE=$(date -d "-${B2_RETENTION_DAYS} days" +%Y-%m-%d)

for DIR in ${REMOTE_DIRS}; do
    if [[ "${DIR}" < "${CUTOFF_DATE}" ]] && [[ "${DIR}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "🗑️  Removing old B2 backup: ${DIR}"
        rclone purge "${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DIR}/" 2>/dev/null || true
    fi
done
log "✅ B2 cleanup done"

#==============================================================================
# SUMMARY
#==============================================================================
TOTAL_SIZE_MB=$(echo "scale=2; ${TOTAL_SIZE}/1024/1024" | bc)

log "=========================================="
log "📊 BACKUP SUMMARY"
log "=========================================="
log "  Hostname   : ${HOSTNAME}"
log "  Databases  : ${DB_COUNT} backed up"
log "  Total size : ${TOTAL_SIZE_MB} MB"
log "  Local path : ${BACKUP_DAILY_DIR}/"
log "  Remote     : ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DATE_DIR}/"
log "  Local keep : ${LOCAL_RETENTION_DAYS} days"
log "  B2 keep    : ${B2_RETENTION_DAYS} days"
[[ -n "${FAILED_DBS}" ]] && log "  ⚠️  Failed  :${FAILED_DBS}"
log "=========================================="
log "✅ Backup completed at $(date '+%Y-%m-%d %H:%M:%S')"
log "=========================================="

NOTIFY_MSG="✅ <b>[${HOSTNAME}] DB Backup OK</b>
📦 ${DB_COUNT} databases | ${TOTAL_SIZE_MB} MB
📁 ${B2_REMOTE_NAME}:${B2_BUCKET}/${HOSTNAME}/${DATE_DIR}/
🕐 $(date '+%H:%M %d/%m/%Y')"
[[ -n "${FAILED_DBS}" ]] && NOTIFY_MSG="${NOTIFY_MSG}
⚠️ Failed:${FAILED_DBS}"

send_telegram "${NOTIFY_MSG}"

#==============================================================================
# SOURCE CODE BACKUP (tùy chọn — HostVN websites)
#==============================================================================
if [[ "${ENABLE_SOURCE_BACKUP:-no}" == "yes" ]]; then
    if [[ -f "${SCRIPT_DIR}/backup_source.sh" ]]; then
        log "🚀 Bắt đầu backup source code website..."
        bash "${SCRIPT_DIR}/backup_source.sh" || log "❌ Source code backup thất bại — xem log riêng"
    else
        log "⚠️  ENABLE_SOURCE_BACKUP=yes nhưng không tìm thấy backup_source.sh"
    fi
fi

exit 0
