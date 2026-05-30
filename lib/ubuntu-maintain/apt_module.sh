#!/usr/bin/env bash

um_apt_lock_opts() {
  if [[ "${UM_CAP[apt_lock_timeout_supported]:-0}" -eq 1 ]]; then
    echo "-o" "DPkg::Lock::Timeout=${UM_CAP[apt_lock_timeout]:-120}"
  fi
}

um_apt_env() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "${UM_RESTART_SERVICES}" -eq 1 ]]; then
    export NEEDRESTART_MODE=a
    unset NEEDRESTART_SUSPEND
  elif [[ "${UM_CAP[needrestart_available]:-0}" -eq 1 ]]; then
    export NEEDRESTART_MODE=l
    export NEEDRESTART_SUSPEND=1
  fi
}

um_apt_wait_locks() {
  if [[ "${UM_CAP[lock_wait_mode]:-}" == "fuser_poll" ]]; then
    um_log "Waiting for APT locks (fuser poll)..."
    local path
    while true; do
      local held=0
      for path in "${UM_APT_LOCK_PATHS[@]}"; do
        if um_probe_command fuser && um_sudo fuser "$path" >/dev/null 2>&1; then
          held=1
          break
        fi
      done
      if [[ "$held" -eq 0 ]]; then break; fi
      sleep 3
    done
    return 0
  fi
  um_log "Using DPkg::Lock::Timeout for apt locking"
}

um_apt_run() {
  local -a opts
  mapfile -t opts < <(um_apt_lock_opts)
  um_sudo env DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE="${NEEDRESTART_MODE:-}" \
    NEEDRESTART_SUSPEND="${NEEDRESTART_SUSPEND:-}" \
    apt-get "${opts[@]}" "$@"
}

um_apt_upgrade_args() {
  local -a args
  case "${UM_CAP[apt_tier_selected]:-standard}" in
    aggressive) args=(dist-upgrade) ;;
    *)
      local major
      major="$(um_parse_version_id)"
      if [[ "$major" -ge 22 ]]; then
        args=(upgrade)
      elif [[ "$major" -ge 18 ]]; then
        args=(upgrade --with-new-pkgs)
      else
        args=(upgrade)
      fi
      ;;
  esac
  printf '%s\n' "${args[@]}"
}

um_apt_simulate_upgrade() {
  local -a upgrade_args
  mapfile -t upgrade_args < <(um_apt_upgrade_args)
  um_apt_run -s "${upgrade_args[@]}" 2>&1 | sed '/^WARNING: /d'
}

um_apt_apply_upgrade() {
  local -a upgrade_args
  mapfile -t upgrade_args < <(um_apt_upgrade_args)
  um_apt_run "${upgrade_args[@]}" -y
}

um_apt_validate_sources_edge() {
  local edge_file="/etc/apt/sources.list.d/microsoft-edge.list"
  [[ -f "$edge_file" ]] || return 0
  if grep -q "dl.google.com/linux/chrome" "$edge_file" 2>/dev/null; then
    um_log "Fixing known-bad microsoft-edge.list (Chrome URL)"
    if command -v microsoft-edge >/dev/null 2>&1; then
      echo "deb [arch=amd64] https://packages.microsoft.com/repos/edge stable main" | \
        um_sudo tee "$edge_file" >/dev/null
    else
      um_sudo rm -f "$edge_file"
    fi
  fi
}

um_apt_phase() {
  [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]] || return 0

  um_apt_env
  um_manifest_apt_simulate_summary

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: apt-get update && apt-get $(um_apt_upgrade_args | tr '\n' ' ') -y"
    return 0
  fi

  um_apt_wait_locks
  um_apt_validate_sources_edge

  um_log "Running apt-get update..."
  um_apt_run update -y || return "${UM_EXIT_APT}"

  um_manifest_apt_simulate_summary
  local removals="${UM_CAP[apt_simulated_removals]:-0}"
  if [[ "$removals" -gt 0 && "${UM_AGGRESSIVE}" -eq 0 ]]; then
    um_log "error: simulate shows ${removals} package removal(s); re-run with --aggressive"
    return "${UM_EXIT_APT}"
  fi

  um_log "Running apt-get $(um_apt_upgrade_args | tr '\n' ' ')..."
  um_apt_apply_upgrade || return "${UM_EXIT_APT}"

  if [[ "${UM_MODE}" == "monthly" ]]; then
    um_log "Monthly hygiene: autoremove, autoclean"
    um_apt_run autoremove --purge -y || return "${UM_EXIT_APT}"
    um_apt_run autoclean -y || return "${UM_EXIT_APT}"
    if um_probe_command dpkg; then
      dpkg -l | awk '/^rc/ {print $2}' | xargs -r um_sudo dpkg --purge 2>/dev/null || true
    fi
  fi

  return 0
}
