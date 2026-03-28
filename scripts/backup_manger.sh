#!/bin/bash
# =============================================================================
# backup_manager.sh — NetBox Backup Manager
# =============================================================================
# Usage:
#   ./backup_manager.sh --backup
#   ./backup_manager.sh --restore --file /opt/netbox/storage/backup/backup_20260328_224800.tar.gz
#
# Backup performs:
#   1. pg_dump from the netbox-postgres container
#   2. Copy of systemd container unit files
#   3. Copy of /opt/netbox/configuration
#
# Restore performs:
#   1. psql restore into the netbox-postgres container
#   2. Restore of systemd container unit files
#   3. Restore of /opt/netbox/configuration
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BACKUP_ROOT="/opt/netbox/storage/backup"
CONTAINER_NAME="netbox-postgres"
POSTGRES_DB="netbox"
POSTGRES_USER="netbox"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="$(mktemp -d /tmp/netbox_backup_XXXXXX)"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

usage() {
    echo ""
    echo "Usage:"
    echo "  $0 --backup"
    echo "  $0 --restore --file <path-to-backup.tar.gz>"
    echo ""
    echo "Options:"
    echo "  --backup          Create a new backup"
    echo "  --restore         Restore from an existing backup archive"
    echo "  --file <path>     Path to the tar.gz archive (required for --restore)"
    echo ""
}

cleanup() {
    log "Removing temporary working directory: ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in podman tar gzip; do
    if ! command -v "${cmd}" &>/dev/null; then
        err "Required command '${cmd}' is not available. Aborting."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            MODE="backup"
            shift
            ;;
        --restore)
            MODE="restore"
            shift
            ;;
        --file)
            RESTORE_FILE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    err "No mode specified. Use --backup or --restore."
    usage
    exit 1
fi

if [[ "${MODE}" == "restore" && -z "${RESTORE_FILE}" ]]; then
    err "--restore requires --file <path-to-backup.tar.gz>"
    usage
    exit 1
fi

# ===========================================================================
# BACKUP
# ===========================================================================
do_backup() {
    local ARCHIVE_NAME="backup_${TIMESTAMP}.tar.gz"
    local ARCHIVE_PATH="${BACKUP_ROOT}/${ARCHIVE_NAME}"

    mkdir -p "${BACKUP_ROOT}"
    mkdir -p "${WORK_DIR}/db"
    mkdir -p "${WORK_DIR}/systemd"
    mkdir -p "${WORK_DIR}/configuration"

    log "Working directory : ${WORK_DIR}"
    log "Target archive    : ${ARCHIVE_PATH}"

    # -------------------------------------------------------------------------
    # 1. PostgreSQL dump
    # -------------------------------------------------------------------------
    log "--- [1/3] PostgreSQL database dump ---"

    local DB_DUMP_FILE="${WORK_DIR}/db/netbox_db_${TIMESTAMP}.sql"

    if ! podman exec "${CONTAINER_NAME}" \
            pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" \
            > "${DB_DUMP_FILE}"; then
        err "pg_dump failed. Make sure the container '${CONTAINER_NAME}' is running."
        exit 2
    fi

    log "Database dump saved: ${DB_DUMP_FILE} ($(du -sh "${DB_DUMP_FILE}" | cut -f1))"

    # -------------------------------------------------------------------------
    # 2. Systemd container unit files
    # -------------------------------------------------------------------------
    log "--- [2/3] Systemd container unit files ---"

    local USER_SYSTEMD_DIR="${HOME}/.config/containers/systemd"
    local SYSTEM_SYSTEMD_DIR="/etc/containers/systemd"
    local SYSTEMD_SOURCE=""

    if [[ -d "${USER_SYSTEMD_DIR}" ]]; then
        SYSTEMD_SOURCE="${USER_SYSTEMD_DIR}"
        log "Using user-level directory: ${SYSTEMD_SOURCE}"
    elif [[ -d "${SYSTEM_SYSTEMD_DIR}" ]] && [[ -r "${SYSTEM_SYSTEMD_DIR}" ]]; then
        SYSTEMD_SOURCE="${SYSTEM_SYSTEMD_DIR}"
        log "Using system-level directory: ${SYSTEMD_SOURCE}"
    else
        warn "No accessible systemd container directory found — skipping this step."
    fi

    if [[ -n "${SYSTEMD_SOURCE}" ]]; then
        cp -a "${SYSTEMD_SOURCE}/." "${WORK_DIR}/systemd/"
        local FILE_COUNT
        FILE_COUNT="$(find "${WORK_DIR}/systemd" -type f | wc -l)"
        log "Copied ${FILE_COUNT} file(s) from ${SYSTEMD_SOURCE}"
    fi

    # -------------------------------------------------------------------------
    # 3. NetBox configuration files
    # -------------------------------------------------------------------------
    log "--- [3/3] NetBox configuration files ---"

    local NETBOX_CONFIG_DIR="/opt/netbox/configuration"

    if [[ -d "${NETBOX_CONFIG_DIR}" ]]; then
        cp -a "${NETBOX_CONFIG_DIR}/." "${WORK_DIR}/configuration/"
        local FILE_COUNT
        FILE_COUNT="$(find "${WORK_DIR}/configuration" -type f | wc -l)"
        log "Copied ${FILE_COUNT} file(s) from ${NETBOX_CONFIG_DIR}"
    else
        warn "Directory ${NETBOX_CONFIG_DIR} does not exist — skipping."
    fi

    # -------------------------------------------------------------------------
    # Pack archive
    # -------------------------------------------------------------------------
    log "--- Creating tar.gz archive ---"

    tar \
        --exclude="*.pyc" \
        --exclude="__pycache__" \
        -czf "${ARCHIVE_PATH}" \
        -C "${WORK_DIR}" .

    local ARCHIVE_SIZE
    ARCHIVE_SIZE="$(du -sh "${ARCHIVE_PATH}" | cut -f1)"
    log "Archive created: ${ARCHIVE_PATH} (${ARCHIVE_SIZE})"

    echo ""
    echo "=============================================="
    echo "  Backup completed successfully"
    echo "=============================================="
    echo "  File      : ${ARCHIVE_PATH}"
    echo "  Size      : ${ARCHIVE_SIZE}"
    echo "  Timestamp : ${TIMESTAMP}"
    echo "=============================================="
}

# ===========================================================================
# RESTORE
# ===========================================================================
do_restore() {
    if [[ ! -f "${RESTORE_FILE}" ]]; then
        err "Archive not found: ${RESTORE_FILE}"
        exit 1
    fi

    log "Starting restore from: ${RESTORE_FILE}"
    log "Working directory     : ${WORK_DIR}"

    # -------------------------------------------------------------------------
    # Extract archive
    # -------------------------------------------------------------------------
    log "--- Extracting archive ---"
    tar -xzf "${RESTORE_FILE}" -C "${WORK_DIR}"
    log "Archive extracted to ${WORK_DIR}"

    # -------------------------------------------------------------------------
    # 1. Restore PostgreSQL database
    # -------------------------------------------------------------------------
    log "--- [1/3] Restoring PostgreSQL database ---"

    local SQL_FILE
    SQL_FILE="$(find "${WORK_DIR}/db" -name "*.sql" | head -n1)"

    if [[ -z "${SQL_FILE}" ]]; then
        err "No .sql dump file found in archive. Aborting restore."
        exit 3
    fi

    log "Found dump file: ${SQL_FILE}"

    # Drop existing connections and recreate the database
    log "Dropping and recreating database '${POSTGRES_DB}'..."
    podman exec "${CONTAINER_NAME}" \
        psql -U "${POSTGRES_USER}" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();" \
        > /dev/null

    podman exec "${CONTAINER_NAME}" \
        psql -U "${POSTGRES_USER}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};" \
        > /dev/null

    podman exec "${CONTAINER_NAME}" \
        psql -U "${POSTGRES_USER}" -d postgres \
        -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};" \
        > /dev/null

    log "Restoring data from dump..."
    podman exec -i "${CONTAINER_NAME}" \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        < "${SQL_FILE}"

    log "Database restored successfully."

    # -------------------------------------------------------------------------
    # 2. Restore systemd container unit files
    # -------------------------------------------------------------------------
    log "--- [2/3] Restoring systemd container unit files ---"

    local SYSTEMD_BACKUP_DIR="${WORK_DIR}/systemd"

    if [[ -d "${SYSTEMD_BACKUP_DIR}" ]] && \
       [[ -n "$(ls -A "${SYSTEMD_BACKUP_DIR}" 2>/dev/null)" ]]; then

        local USER_SYSTEMD_DIR="${HOME}/.config/containers/systemd"
        local SYSTEM_SYSTEMD_DIR="/etc/containers/systemd"
        local SYSTEMD_DEST=""

        # Prefer user-level; fall back to system-level if writable
        if [[ -d "${USER_SYSTEMD_DIR}" ]] || mkdir -p "${USER_SYSTEMD_DIR}" 2>/dev/null; then
            SYSTEMD_DEST="${USER_SYSTEMD_DIR}"
        elif [[ -w "${SYSTEM_SYSTEMD_DIR}" ]]; then
            SYSTEMD_DEST="${SYSTEM_SYSTEMD_DIR}"
        else
            warn "No writable systemd container directory found — skipping systemd restore."
        fi

        if [[ -n "${SYSTEMD_DEST}" ]]; then
            cp -a "${SYSTEMD_BACKUP_DIR}/." "${SYSTEMD_DEST}/"
            local FILE_COUNT
            FILE_COUNT="$(find "${SYSTEMD_DEST}" -type f | wc -l)"
            log "Restored ${FILE_COUNT} file(s) to ${SYSTEMD_DEST}"
            log "Run 'systemctl --user daemon-reload' (or without --user for system) to apply."
        fi
    else
        warn "No systemd files found in archive — skipping."
    fi

    # -------------------------------------------------------------------------
    # 3. Restore NetBox configuration files
    # -------------------------------------------------------------------------
    log "--- [3/3] Restoring NetBox configuration files ---"

    local CONFIG_BACKUP_DIR="${WORK_DIR}/configuration"
    local NETBOX_CONFIG_DIR="/opt/netbox/configuration"

    if [[ -d "${CONFIG_BACKUP_DIR}" ]] && \
       [[ -n "$(ls -A "${CONFIG_BACKUP_DIR}" 2>/dev/null)" ]]; then
        mkdir -p "${NETBOX_CONFIG_DIR}"
        cp -a "${CONFIG_BACKUP_DIR}/." "${NETBOX_CONFIG_DIR}/"
        local FILE_COUNT
        FILE_COUNT="$(find "${NETBOX_CONFIG_DIR}" -type f | wc -l)"
        log "Restored ${FILE_COUNT} file(s) to ${NETBOX_CONFIG_DIR}"
    else
        warn "No configuration files found in archive — skipping."
    fi

    echo ""
    echo "=============================================="
    echo "  Restore completed successfully"
    echo "=============================================="
    echo "  Source    : ${RESTORE_FILE}"
    echo "  Timestamp : ${TIMESTAMP}"
    echo "  NOTE: Restart NetBox and reload systemd units"
    echo "        to apply the restored configuration."
    echo "=============================================="
}

# ===========================================================================
# Entry point
# ===========================================================================
case "${MODE}" in
    backup)  do_backup  ;;
    restore) do_restore ;;
esac