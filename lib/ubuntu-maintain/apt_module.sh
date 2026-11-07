#!/usr/bin/env bash
# apt_module.sh — APT lock wait, upgrade tiers, simulate, and apply phase.
# Provides: um_apt_phase, um_apt_run, um_apt_simulate_upgrade
# Sourced by: common.sh → um_source_libs

um_apt_lock_opts() {
  if [[ "${UM_CAP[apt_lock_timeout_supported]:-0}" -eq 1 ]]; then
    # One word per line: callers mapfile this into argv.
    printf '%s\n' -o "DPkg::Lock::Timeout=${UM_CAP[apt_lock_timeout]:-120}"
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
    if ! um_probe_command fuser && ! um_probe_command lsof; then
      um_log "warning: neither fuser (psmisc) nor lsof is installed; cannot detect APT lock holders"
    fi
    local path held waited=0 max_wait="${UM_CAP[apt_lock_timeout]:-120}"
    # Check before deciding on timeout, so locks freed on the last poll are not
    # reported as a timeout.
    while :; do
      held=0
      for path in "${UM_APT_LOCK_PATHS[@]}"; do
        if um_probe_command fuser && um_sudo fuser "$path" >/dev/null 2>&1; then
          held=1; break
        elif um_probe_command lsof && um_sudo lsof "$path" >/dev/null 2>&1; then
          held=1; break
        fi
      done
      [[ "$held" -eq 0 ]] && return 0
      if [[ "$waited" -ge "$max_wait" ]]; then
        um_log "error: timed out after ${max_wait}s waiting for APT locks"
        return "${UM_EXIT_APT}"
      fi
      sleep 3
      waited=$((waited + 3))
    done
  fi
  um_log "Using DPkg::Lock::Timeout for apt locking"
}

# No sudo here: --apply always runs as root (re-exec), and dry-run/simulate must work
# unprivileged without prompting for a password.
um_apt_run() {
  local -a opts
  mapfile -t opts < <(um_apt_lock_opts)
  env DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE="${NEEDRESTART_MODE:-}" \
    NEEDRESTART_SUSPEND="${NEEDRESTART_SUSPEND:-}" \
    apt-get "${opts[@]}" "$@"
}

# DPkg::Lock::Timeout covers only the dpkg locks: `apt-get update` fails at once when
# apt-daily holds /var/lib/apt/lists/lock (verified on apt 2.0 through 3.2). Retry while
# that is the reason, up to the same timeout. LC_ALL=C keeps the message matchable.
um_apt_update() {
  local out rc waited=0 max_wait="${UM_CAP[apt_lock_timeout]:-120}"
  while :; do
    rc=0
    out="$(LC_ALL=C um_apt_run update 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [[ "$rc" -eq 0 ]] && return 0
    grep -qE 'lock /var/lib/apt/lists/lock|lock directory /var/lib/apt/lists' <<<"$out" || return "$rc"
    if [[ "$waited" -ge "$max_wait" ]]; then
      um_log "error: timed out after ${max_wait}s waiting for the apt lists lock"
      return "$rc"
    fi
    um_log "apt package lists are locked by another process (e.g. apt-daily); retrying in 5s..."
    sleep 5
    waited=$((waited + 5))
  done
}

um_apt_upgrade_args() {
  local -a args
  case "${UM_CAP[apt_tier_selected]:-standard}" in
    aggressive) args=(dist-upgrade) ;;
    # --with-new-pkgs (apt >= 1.1, every supported release) installs new dependencies such
    # as a new kernel ABI, but like plain upgrade it never removes a package.
    *) args=(upgrade --with-new-pkgs) ;;
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
  # Non-interactive run: keep locally modified conffiles (same policy as unattended-upgrades)
  # instead of blocking on, or failing at, a dpkg conffile prompt.
  um_apt_run -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "${upgrade_args[@]}" -y
}

um_apt_phase() {
  [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]] || return 0

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: apt-get update && apt-get $(um_apt_upgrade_args | paste -sd ' ') -y"
    if [[ "${UM_MODE}" == "monthly" ]]; then
      um_log "[dry-run] would run: apt-get autoremove --purge -y && apt-get autoclean -y, and purge residual configs (dpkg 'rc')"
    fi
    return 0
  fi

  um_apt_wait_locks || return $?

  um_log "Running apt-get update..."
  um_apt_update || return "${UM_EXIT_APT}"

  # Re-simulate against fresh lists. The standard tier never removes packages, so the
  # guard below is a backstop in case that ever changes; it must not use a stale count.
  um_manifest_apt_simulate_summary || return "${UM_EXIT_APT}"
  local removals="${UM_CAP[apt_simulated_removals]:-0}"
  if [[ "$removals" -gt 0 && "${UM_AGGRESSIVE}" -eq 0 ]]; then
    um_log "error: simulate shows ${removals} package removal(s); re-run with --aggressive"
    return "${UM_EXIT_APT}"
  fi

  um_log "Running apt-get $(um_apt_upgrade_args | paste -sd ' ')..."
  um_apt_apply_upgrade || return "${UM_EXIT_APT}"

  if [[ "${UM_MODE}" == "monthly" ]]; then
    um_log "Monthly hygiene: autoremove, autoclean"
    um_apt_run autoremove --purge -y || return "${UM_EXIT_APT}"
    um_apt_run autoclean -y || return "${UM_EXIT_APT}"
    if um_probe_command dpkg; then
      dpkg -l | awk '/^rc/{print $2}' | while IFS= read -r pkg; do
        um_sudo dpkg --purge -- "$pkg" 2>/dev/null || true
      done
    fi
  fi

  return 0
}
