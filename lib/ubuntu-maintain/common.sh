#!/usr/bin/env bash
# Shared state and helpers for ubuntu-maintain.

UM_VERSION="1.0.0"
UM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UM_ROOT_DIR="$(cd "${UM_LIB_DIR}/../.." && pwd)"

# Runtime flags (set by CLI)
UM_APPLY=0
UM_AGGRESSIVE=0
UM_MODE="daily"          # daily | monthly
UM_CONTINUE_ON_FAILURE=0
UM_IGNORE_STABILITY=0
UM_RESTART_SERVICES=0
UM_LOG_FILE="${UM_LOG_FILE:-/tmp/ubuntu-maintain.log}"
UM_MANIFEST_ONLY=0
UM_WITH_TOPGRADE=0

# Populated by probe
declare -gA UM_CAP=()

# Exit codes
readonly UM_EXIT_OK=0
readonly UM_EXIT_STABILITY=2
readonly UM_EXIT_APT=10
readonly UM_EXIT_SNAP=11
readonly UM_EXIT_FLATPAK=12
readonly UM_EXIT_TOPGRADE=13
readonly UM_EXIT_USAGE=64

um_die() {
  echo "error: $*" >&2
  exit "${UM_EXIT_USAGE}"
}

um_log() {
  echo "$*"
}

um_need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    um_die "root or sudo required for this operation"
  fi
}

um_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

um_load_os_release() {
  # shellcheck source=/dev/null
  [[ -f /etc/os-release ]] && source /etc/os-release
  UM_CAP[os_id]="${ID:-unknown}"
  UM_CAP[os_version_id]="${VERSION_ID:-}"
  UM_CAP[os_codename]="${VERSION_CODENAME:-}"
  UM_CAP[os_pretty]="${PRETTY_NAME:-}"
}

um_parse_version_id() {
  local v="${UM_CAP[os_version_id]}"
  v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

um_usage() {
  cat <<EOF
ubuntu-maintain ${UM_VERSION} — safe, probe-driven Ubuntu/Debian maintenance

Usage: ubuntu-maintain [OPTIONS]

Options:
  --apply                 Execute updates (default is dry-run / manifest only)
  --aggressive            Use apt dist-upgrade tier (may remove packages)
  --mode daily|monthly    Hygiene depth (default: daily)
  --manifest-only         Print manifest and exit
  --with-topgrade         Run topgrade for pip/cargo/npm/etc. (disables apt/snap/flatpak)
  --continue-on-pm-failure  Continue if snap/flatpak fails after apt succeeds
  --ignore-stability      Do not fail on failed systemd units
  --restart-services      Auto-restart services (needrestart mode a); risky
  --log-file PATH         Log file (default: /tmp/ubuntu-maintain.log)
  -h, --help              Show this help

Environment:
  UPDATE_APPLY=1          Same as --apply

Examples:
  ubuntu-maintain                    # dry-run manifest
  ubuntu-maintain --apply            # routine safe update
  ubuntu-maintain --apply --mode monthly --aggressive
EOF
}

um_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) UM_APPLY=1 ;;
      --aggressive) UM_AGGRESSIVE=1 ;;
      --mode)
        shift
        UM_MODE="${1:-}"
        [[ "$UM_MODE" == "daily" || "$UM_MODE" == "monthly" ]] || um_die "--mode must be daily or monthly"
        ;;
      --manifest-only) UM_MANIFEST_ONLY=1 ;;
      --with-topgrade) UM_WITH_TOPGRADE=1 ;;
      --continue-on-pm-failure) UM_CONTINUE_ON_FAILURE=1 ;;
      --ignore-stability) UM_IGNORE_STABILITY=1 ;;
      --restart-services) UM_RESTART_SERVICES=1 ;;
      --log-file)
        shift
        UM_LOG_FILE="${1:-}"
        [[ -n "$UM_LOG_FILE" ]] || um_die "--log-file requires a path"
        ;;
      -h|--help) um_usage; exit 0 ;;
      *) um_die "unknown option: $1" ;;
    esac
    shift
  done
  if [[ "${UPDATE_APPLY:-}" == "1" ]]; then
    UM_APPLY=1
  fi
}

um_setup_logging() {
  exec > >(tee -a "$UM_LOG_FILE") 2>&1
  um_log "ubuntu-maintain ${UM_VERSION} — $(date -Is 2>/dev/null || date)"
  um_log "mode=${UM_MODE} apply=${UM_APPLY} aggressive=${UM_AGGRESSIVE}"
}

um_source_libs() {
  # shellcheck source=probe.sh
  source "${UM_LIB_DIR}/probe.sh"
  # shellcheck source=manifest.sh
  source "${UM_LIB_DIR}/manifest.sh"
  # shellcheck source=apt_module.sh
  source "${UM_LIB_DIR}/apt_module.sh"
  # shellcheck source=snap.sh
  source "${UM_LIB_DIR}/snap.sh"
  # shellcheck source=flatpak.sh
  source "${UM_LIB_DIR}/flatpak.sh"
  # shellcheck source=stability.sh
  source "${UM_LIB_DIR}/stability.sh"
  # shellcheck source=topgrade.sh
  source "${UM_LIB_DIR}/topgrade.sh"
  # shellcheck source=dag.sh
  source "${UM_LIB_DIR}/dag.sh"
}
