#!/usr/bin/env bash
# files_manager.sh — NetBox Podman setup helper

set -euo pipefail

# ── ANSI colors ───────────────────────────────────────────────────────────────
GREEN="\033[92m"
RED="\033[91m"
YELLOW="\033[93m"
CYAN="\033[96m"
BOLD="\033[1m"
RESET="\033[0m"

OK="${GREEN}[  OK  ]${RESET}"
FAIL="${RED}[ FAIL ]${RESET}"
WARN="${YELLOW}[ WARN ]${RESET}"
INFO="${CYAN}[ INFO ]${RESET}"

# ── helpers ───────────────────────────────────────────────────────────────────

log_ok()   { echo -e "  ${OK}  $*"; }
log_fail() { echo -e "  ${FAIL}  $*"; }
log_warn() { echo -e "  ${WARN}  $*"; }
log_info() { echo -e "  ${INFO}  $*"; }

header() {
    local title="$1"
    local width=60
    echo -e "\n${BOLD}${CYAN}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    echo -e "${BOLD}${CYAN}  ${title}${RESET}"
    echo -e "${BOLD}${CYAN}$(printf '═%.0s' $(seq 1 $width))${RESET}"
}

usage() {
    echo -e "
${BOLD}Usage:${RESET}
  $0 --generate-configuration-directories
  $0 --copy-env-files --src <source_dir> --dst <destination_dir>
  $0 --copy-configuration-files --src <source_dir> --dst <destination_dir>
  $0 --help

${BOLD}Arguments:${RESET}
  --generate-configuration-directories
        Creates the base NetBox directory structure under /opt/netbox/

  --copy-env-files --src <dir> --dst <dir>
        Copies env files from <src> to <dst>, stripping the 'default.' prefix
        Example files:  default.netbox.env  →  netbox.env
                        default.postgres.env  →  postgres.env
                        default.redis.env  →  redis.env
                        default.redis-cache.env  →  redis-cache.env

  --copy-configuration-files --src <dir> --dst <dir>
        Copies all files from <src> to <dst> without renaming them
        Example files:  configuration.py  →  configuration.py
                        ldap_config.py    →  ldap_config.py

${BOLD}Examples:${RESET}
  $0 --generate-configuration-directories

  $0 --copy-env-files \\
        --src /home/podmanadm/netbox-podman/env-files \\
        --dst /opt/netbox/configuration

  $0 --copy-configuration-files \\
        --src /home/podmanadm/netbox-podman/configurations \\
        --dst /opt/netbox/configuration/netbox_configuration
"
    exit 0
}

# ── --generate-configuration-directories ─────────────────────────────────────

generate_dirs() {
    header "Generate configuration directories"

    local base="/opt/netbox"
    local dirs=(
        "${base}/storage"
        "${base}/configuration"
        "${base}/configuration/netbox_configuration"
        "${base}/storage/netbox-postgres-data"
        "${base}/storage/netbox-redis-cache-data"
        "${base}/storage/netbox-redis-data"
        "${base}/storage/netbox-reports-files"
        "${base}/storage/netbox-scripts-files"
        "${base}/storage/netbox-media-files"
        "${base}/storage/backup"
    )

    # Check if /opt/netbox exists and is writable
    if [[ ! -d "${base}" ]]; then
        log_warn "${base} does not exist — attempting to create it..."
        if ! mkdir -p "${base}" 2>/dev/null; then
            log_fail "Permission denied creating ${base}"
            echo -e "
  ${YELLOW}Run the following as root / sudo first:${RESET}

    sudo mkdir -p /opt/netbox/
    sudo chown podmanadm:podmanadm /opt/netbox
    sudo chmod -R 755 /opt/netbox

  ${YELLOW}Then re-run this script as podmanadm.${RESET}
"
            exit 1
        fi
    fi

    if [[ ! -w "${base}" ]]; then
        log_fail "Permission denied — cannot write to ${base}"
        echo -e "
  ${YELLOW}Run the following as root / sudo first:${RESET}

    sudo mkdir -p /opt/netbox/
    sudo chown podmanadm:podmanadm /opt/netbox
    sudo chmod -R 755 /opt/netbox

  ${YELLOW}Then re-run this script as podmanadm.${RESET}
"
        exit 1
    fi

    for dir in "${dirs[@]}"; do
        if [[ -d "${dir}" ]]; then
            log_warn "Already exists: ${dir}"
        else
            if mkdir -p "${dir}" 2>/dev/null; then
                log_ok "Created: ${dir}"
            else
                log_fail "Failed to create: ${dir}"
                exit 1
            fi
        fi
    done

    echo ""
    log_ok "All directories ready."
}

# ── --copy-env-files ──────────────────────────────────────────────────────────

copy_env_files() {
    local src="$1"
    local dst="$2"

    header "Copy env files"

    # Validate source
    if [[ ! -d "${src}" ]]; then
        log_fail "Source directory does not exist: ${src}"
        exit 1
    fi

    # Validate / create destination
    if [[ ! -d "${dst}" ]]; then
        log_warn "Destination does not exist — attempting to create: ${dst}"
        if ! mkdir -p "${dst}" 2>/dev/null; then
            log_fail "Permission denied creating ${dst}"
            exit 1
        fi
    fi

    if [[ ! -w "${dst}" ]]; then
        log_fail "Permission denied — cannot write to ${dst}"
        exit 1
    fi

    local count=0

    # Find all files starting with "default." in source dir
    while IFS= read -r -d '' file; do
        local filename
        filename="$(basename "${file}")"

        # Strip the "default." prefix
        local newname="${filename#default.}"

        if [[ "${newname}" == "${filename}" ]]; then
            # No "default." prefix — skip
            log_warn "Skipping (no 'default.' prefix): ${filename}"
            continue
        fi

        local dst_file="${dst}/${newname}"

        if [[ -f "${dst_file}" ]]; then
            log_warn "Already exists, skipping: ${dst_file}"
        else
            cp "${file}" "${dst_file}"
            log_ok "${filename}  →  ${dst_file}"
            (( count++ )) || true
        fi

    done < <(find "${src}" -maxdepth 1 -type f -name "default.*" -print0 | sort -z)

    echo ""
    if [[ ${count} -eq 0 ]]; then
        log_warn "No files were copied (all already exist or no 'default.*' files found in ${src})"
    else
        log_ok "Copied ${count} file(s) to ${dst}"
    fi
}

# ── --copy-configuration-files ────────────────────────────────────────────────

copy_configuration_files() {
    local src="$1"
    local dst="$2"

    header "Copy configuration files"

    # Validate source
    if [[ ! -d "${src}" ]]; then
        log_fail "Source directory does not exist: ${src}"
        exit 1
    fi

    # Validate / create destination
    if [[ ! -d "${dst}" ]]; then
        log_warn "Destination does not exist — attempting to create: ${dst}"
        if ! mkdir -p "${dst}" 2>/dev/null; then
            log_fail "Permission denied creating ${dst}"
            exit 1
        fi
    fi

    if [[ ! -w "${dst}" ]]; then
        log_fail "Permission denied — cannot write to ${dst}"
        exit 1
    fi

    local count=0

    # Copy all files without renaming
    while IFS= read -r -d '' file; do
        local filename
        filename="$(basename "${file}")"
        local dst_file="${dst}/${filename}"

        if [[ -f "${dst_file}" ]]; then
            log_warn "Already exists, skipping: ${dst_file}"
        else
            cp "${file}" "${dst_file}"
            log_ok "${filename}  →  ${dst_file}"
            (( count++ )) || true
        fi

    done < <(find "${src}" -maxdepth 1 -type f -print0 | sort -z)

    echo ""
    if [[ ${count} -eq 0 ]]; then
        log_warn "No files were copied (all already exist or no files found in ${src})"
    else
        log_ok "Copied ${count} file(s) to ${dst}"
    fi
}

# ── argument parsing ──────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
    usage
fi

CMD=""
SRC=""
DST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --generate-configuration-directories)
            CMD="generate"
            shift
            ;;
        --copy-env-files)
            CMD="copy-env"
            shift
            ;;
        --copy-configuration-files)
            CMD="copy-config"
            shift
            ;;
        --src)
            SRC="$2"
            shift 2
            ;;
        --dst)
            DST="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_fail "Unknown argument: $1"
            usage
            ;;
    esac
done

case "${CMD}" in
    generate)
        generate_dirs
        ;;
    copy-env)
        if [[ -z "${SRC}" || -z "${DST}" ]]; then
            log_fail "--copy-env-files requires both --src and --dst"
            usage
        fi
        copy_env_files "${SRC}" "${DST}"
        ;;
    copy-config)
        if [[ -z "${SRC}" || -z "${DST}" ]]; then
            log_fail "--copy-configuration-files requires both --src and --dst"
            usage
        fi
        copy_configuration_files "${SRC}" "${DST}"
        ;;
    *)
        log_fail "No valid command specified."
        usage
        ;;
esac