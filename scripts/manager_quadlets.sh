#!/usr/bin/env bash
# manager_quadlets.sh — NetBox Podman Quadlet manager

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
  $0 --install-local
  $0 --install-root
  $0 --reload
  $0 --start-network
  $0 --start-volumes
  $0 --start-quadlets
  $0 --start-all
  $0 --stop-quadlets
  $0 --enable-quadlets
  $0 --status-network
  $0 --status-volumes
  $0 --help

${BOLD}Arguments:${RESET}
  --install-local     Copy quadlet files to ~/.config/containers/systemd  (rootless)
  --install-root      Copy quadlet files to /etc/containers/systemd       (root — requires sudo)
  --reload            systemctl --user daemon-reload
  --start-network     Start netbox-production-network
  --start-volumes     Start all NetBox volumes
  --start-quadlets    Enable and start all containers in order (with delays)
  --start-all         Full stack start: network → volumes → enable → containers
  --stop-quadlets     Stop all containers in reverse order (with delays)
  --enable-quadlets   Enable all containers to start on boot (requires lingering)
  --status-network    Show NetBox networks (podman network ls)
  --status-volumes    Show NetBox volumes (podman volume ls)

${BOLD}Examples:${RESET}
  $0 --install-local
  $0 --reload
  $0 --start-all
  $0 --status-network
  $0 --status-volumes
"
    exit 0
}

# ── config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLETS_SRC="${SCRIPT_DIR}/../Quadlets"

LOCAL_DST="${HOME}/.config/containers/systemd"
ROOT_DST="/etc/containers/systemd"

NETWORK_UNIT="netbox-production-network"

VOLUMES=(
    "netbox-postgres-db-data"
    "netbox-media-files"
    "netbox-redis-cache-data"
    "netbox-redis-data"
    "netbox-reports-files"
    "netbox-scripts-files"
)

# Start order
CONTAINERS_START=(
    "netbox-postgres"
    "netbox-redis"
    "netbox-redis-cache"
    "netbox"
    "netbox-worker"
    "netbox-nginx"

)

# Stop order (reverse)
CONTAINERS_STOP=(
    "netbox-nginx"
    "netbox-worker"
    "netbox"
    "netbox-redis-cache"
    "netbox-redis"
    "netbox-postgres"
)

WAIT_SECONDS=25

# ── --install-local ───────────────────────────────────────────────────────────

install_local() {
    header "Install quadlets — rootless (~/.config/containers/systemd)"

    if [[ ! -d "${QUADLETS_SRC}" ]]; then
        log_fail "Quadlets source directory not found: ${QUADLETS_SRC}"
        log_info "Expected quadlet files in: ${QUADLETS_SRC}/"
        exit 1
    fi

    mkdir -p "${LOCAL_DST}"

    local count=0
    while IFS= read -r -d '' file; do
        local filename
        filename="$(basename "${file}")"
        local dst_file="${LOCAL_DST}/${filename}"

        if [[ -f "${dst_file}" ]]; then
            log_warn "Overwriting: ${dst_file}"
        fi

        cp "${file}" "${dst_file}"
        log_ok "Copied: ${filename}  →  ${dst_file}"
        (( count++ )) || true

    done < <(find "${QUADLETS_SRC}" -maxdepth 1 -type f \( -name "*.container" -o -name "*.volume" -o -name "*.network" \) -print0 | sort -z)

    echo ""
    if [[ ${count} -eq 0 ]]; then
        log_warn "No quadlet files found in ${QUADLETS_SRC}"
    else
        log_ok "Installed ${count} file(s) to ${LOCAL_DST}"
        echo -e "\n  ${CYAN}Next step:${RESET}  $0 --reload\n"
    fi
}

# ── --install-root ────────────────────────────────────────────────────────────

install_root() {
    header "Install quadlets — root (/etc/containers/systemd)"

    echo -e "
  ${YELLOW}⚠  ROOT INSTALL — important notes:${RESET}
  ${YELLOW}   Files will be copied to: ${ROOT_DST}${RESET}
  ${YELLOW}   This requires sudo for the copy step.${RESET}
  ${YELLOW}   After installing, ALL systemctl commands must be run as root:${RESET}

    sudo systemctl daemon-reload
    sudo systemctl start netbox-production-network
    sudo systemctl start netbox-postgres
    ...

  ${YELLOW}   Rootless 'systemctl --user' will NOT manage these units.${RESET}
"

    if [[ ! -d "${QUADLETS_SRC}" ]]; then
        log_fail "Quadlets source directory not found: ${QUADLETS_SRC}"
        exit 1
    fi

    sudo mkdir -p "${ROOT_DST}"

    local count=0
    while IFS= read -r -d '' file; do
        local filename
        filename="$(basename "${file}")"
        local dst_file="${ROOT_DST}/${filename}"

        if sudo test -f "${dst_file}"; then
            log_warn "Overwriting: ${dst_file}"
        fi

        sudo cp "${file}" "${dst_file}"
        log_ok "Copied: ${filename}  →  ${dst_file}"
        (( count++ )) || true

    done < <(find "${QUADLETS_SRC}" -maxdepth 1 -type f \( -name "*.container" -o -name "*.volume" -o -name "*.network" \) -print0 | sort -z)

    echo ""
    if [[ ${count} -eq 0 ]]; then
        log_warn "No quadlet files found in ${QUADLETS_SRC}"
    else
        log_ok "Installed ${count} file(s) to ${ROOT_DST}"
        echo -e "\n  ${YELLOW}Remember: use 'sudo systemctl' for all operations (not --user)${RESET}\n"
    fi
}

# ── --reload ──────────────────────────────────────────────────────────────────

do_reload() {
    header "Reload systemd user daemon"
    systemctl --user daemon-reload
    log_ok "daemon-reload complete"
    echo -e "\n  ${CYAN}Quadlet generator has processed all .container / .volume / .network files.${RESET}"
    echo -e "  ${CYAN}Check generated units with:  systemctl --user list-units | grep netbox${RESET}\n"
}

# ── --start-network ───────────────────────────────────────────────────────────

start_network() {
    header "Start network — ${NETWORK_UNIT}"
    systemctl --user start "${NETWORK_UNIT}.service"
    log_ok "Started: ${NETWORK_UNIT}"
}

# ── --start-volumes ───────────────────────────────────────────────────────────

start_volumes() {
    header "Start volumes"
    for vol in "${VOLUMES[@]}"; do
        log_info "Starting volume: ${vol}"
        systemctl --user start "${vol}-volume.service" && log_ok "${vol}" || log_fail "${vol}"
    done
    echo ""
    log_ok "All volumes started."
}


# ── --start-quadlets ──────────────────────────────────────────────────────────

start_quadlets() {
    header "Start NetBox containers (ordered)"

    local total="${#CONTAINERS_START[@]}"
    local i=1
    local first_run=false

    # Detect first run — postgres data directory empty (cluster not yet initialised)
    if [[ -z "$(podman volume inspect netbox-postgres-db-data --format '{{.Mountpoint}}' 2>/dev/null | xargs ls 2>/dev/null)" ]]; then
        first_run=true
        log_warn "First run detected — extended startup delays will apply."
    fi

    for svc in "${CONTAINERS_START[@]}"; do
        log_info "[${i}/${total}] Starting: ${svc}"
        systemctl --user start "${svc}" && log_ok "${svc} started" || log_fail "${svc} failed to start"

        if [[ ${i} -lt ${total} ]]; then
            if [[ "${svc}" == "netbox" && "${first_run}" == true ]]; then
                log_info "First run — waiting up to 300s for NetBox to finish initialisation..."
                local elapsed=0
                local interval=5
                local timeout=300
                local ready=false

                while [[ ${elapsed} -lt ${timeout} ]]; do
                    if podman logs netbox 2>&1 | grep -q "Finished\|spawned uWSGI"; then
                        log_ok "NetBox is ready (${elapsed}s)"
                        ready=true
                        break
                    fi
                    sleep "${interval}"
                    (( elapsed += interval )) || true
                    log_info "Still waiting for NetBox... (${elapsed}s / ${timeout}s)"
                done

                if [[ "${ready}" == false ]]; then
                    log_warn "NetBox did not report ready within ${timeout}s — continuing anyway."
                    log_warn "Check logs: podman logs netbox"
                fi

            elif [[ "${svc}" == "netbox-worker" ]]; then
                log_info "Waiting 60s after netbox-worker..."
                sleep 60
            else
                log_info "Waiting ${WAIT_SECONDS}s before next service..."
                sleep "${WAIT_SECONDS}"
            fi
        fi
        (( i++ )) || true
    done

    echo ""
    log_ok "All containers started."
}

# ── --start-all ───────────────────────────────────────────────────────────────

start_all() {
    header "Full stack start — network → volumes → enable → containers"
    start_network
    echo ""
    start_volumes
    echo ""
    start_quadlets
    echo ""
    log_ok "NetBox stack is up."
}

# ── --stop-quadlets ───────────────────────────────────────────────────────────

stop_quadlets() {
    header "Stop NetBox containers (reverse order)"
    local total="${#CONTAINERS_STOP[@]}"
    local i=1

    for svc in "${CONTAINERS_STOP[@]}"; do
        log_info "[${i}/${total}] Stopping: ${svc}"
        systemctl --user stop "${svc}.service" && log_ok "${svc} stopped" || log_warn "${svc} was not running"

        if [[ ${i} -lt ${total} ]]; then
            log_info "Waiting ${WAIT_SECONDS}s before next service..."
            sleep "${WAIT_SECONDS}"
        fi
        (( i++ )) || true
    done

    echo ""
    log_ok "All containers stopped."
}

# ── --status-network ──────────────────────────────────────────────────────────

status_network() {
    header "Network status"
    echo -e "  ${CYAN}podman network ls | grep netbox${RESET}\n"
    podman network ls | grep -i netbox || log_warn "No NetBox networks found"
}

# ── --status-volumes ──────────────────────────────────────────────────────────

status_volumes() {
    header "Volume status"
    echo -e "  ${CYAN}podman volume ls | grep netbox${RESET}\n"
    podman volume ls | grep -i netbox || log_warn "No NetBox volumes found"
}

# ── argument parsing ──────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
    usage
fi

case "$1" in
    --install-local)         install_local ;;
    --install-root)          install_root ;;
    --reload)                do_reload ;;
    --start-network)         start_network ;;
    --start-volumes)         start_volumes ;;
    --start-quadlets)        start_quadlets ;;
    --start-all)             start_all ;;
    --stop-quadlets)         stop_quadlets ;;
    --status-network)        status_network ;;
    --status-volumes)        status_volumes ;;
    --help|-h)               usage ;;
    *)
        log_fail "Unknown argument: $1"
        usage
        ;;
esac