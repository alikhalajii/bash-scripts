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

# Without --aggressive, a monthly autoremove larger than this is skipped. apt 3.x (default on
# Ubuntu 26.04) autoremoves more than older releases; routine runs remove 0-10 packages
# (old kernels come in groups of 4-6), a solver change or release upgrade dozens.
UM_AUTOREMOVE_LIMIT=25

# um_list_head MAX NAME...: the first MAX names, then "… (+N more)".
um_list_head() {
  local max="$1"; shift
  local out="${*:1:max}"
  if [[ $# -gt "$max" ]]; then out+=" … (+$(( $# - max )) more)"; fi
  printf '%s\n' "$out"
}

# Packages `apt-get autoremove --purge` would remove, one per line (simulation, no root).
um_apt_autoremove_list() {
  LC_ALL=C um_apt_run -s autoremove --purge 2>/dev/null | awk '$1 == "Purg" || $1 == "Remv" {print $2}'
}

# um_pkgs_size_mb NAME...: installed size of the named packages in MB (names no longer
# installed count as 0).
um_pkgs_size_mb() {
  [[ $# -gt 0 ]] || { echo 0; return 0; }
  LC_ALL=C dpkg-query -W -f '${Installed-Size}\n' -- "$@" 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ {kib += $1} END {printf "%d\n", (kib + 512) / 1024}'
}

# Removed packages whose config files are still on disk (dpkg status "rc").
um_apt_residual_configs() {
  LC_ALL=C dpkg -l 2>/dev/null | awk '$1 == "rc" {print $2}'
}

# What monthly cleanup will touch. "forecast" (dry run) also lists autoremove, computed
# before the upgrade; under --apply um_apt_autoremove_guarded lists the real set instead.
um_apt_cleanup_preview() {
  local label="${1:-}" kib
  local -a auto=() rc=() obsolete=()
  um_log "Cleanup preview (monthly):"
  if [[ "$label" == "forecast" ]]; then
    mapfile -t auto < <(um_apt_autoremove_list)
    if [[ ${#auto[@]} -gt 0 ]]; then
      um_log "  autoremove (before upgrades): ${#auto[@]} package(s), $(um_pkgs_size_mb "${auto[@]}") MB: $(um_list_head 10 "${auto[@]}")"
    else
      um_log "  autoremove (before upgrades): 0 package(s)"
    fi
  fi
  mapfile -t rc < <(um_apt_residual_configs)
  um_log "  residual configs: ${#rc[@]} package(s)${rc[0]:+: $(um_list_head 10 "${rc[@]}")}"
  kib="$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')"
  um_log "  download cache: $(( ${kib:-0} / 1024 )) MB (apt-get clean)"
  if [[ "${UM_CAP[apt_obsolete_count]:-unknown}" =~ ^[1-9][0-9]*$ ]]; then
    read -ra obsolete <<<"${UM_CAP[apt_obsolete_list]:-}"
    um_log "  not in any repository (review, never removed): ${UM_CAP[apt_obsolete_count]} package(s): $(um_list_head 10 "${obsolete[@]}")"
  fi
}

# Re-simulate after the upgrade (it can make more packages removable), log the list, and
# remove it unless it is larger than UM_AUTOREMOVE_LIMIT without --aggressive.
um_apt_autoremove_guarded() {
  local -a auto=()
  mapfile -t auto < <(um_apt_autoremove_list)
  if [[ ${#auto[@]} -eq 0 ]]; then
    um_log "autoremove: 0 package(s)"
    return 0
  fi
  um_log "autoremove: ${#auto[@]} package(s), $(um_pkgs_size_mb "${auto[@]}") MB: ${auto[*]}"
  if [[ ${#auto[@]} -gt "$UM_AUTOREMOVE_LIMIT" && "${UM_AGGRESSIVE}" -eq 0 ]]; then
    um_log "warning: autoremove would remove ${#auto[@]} packages (limit ${UM_AUTOREMOVE_LIMIT}); review the list above and re-run with --aggressive to allow it"
    return 0
  fi
  um_apt_run autoremove --purge -y || return "${UM_EXIT_APT}"
}

um_apt_phase() {
  [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]] || return 0

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: apt-get update && apt-get $(um_apt_upgrade_args | paste -sd ' ') -y"
    if [[ "${UM_MODE}" == "monthly" ]]; then
      um_log "[dry-run] would run: apt-get autoremove --purge -y (limit ${UM_AUTOREMOVE_LIMIT} without --aggressive) && apt-get clean, and purge residual configs (dpkg 'rc')"
      um_apt_cleanup_preview forecast
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
    um_log "Monthly hygiene: autoremove, clean, residual configs"
    um_apt_cleanup_preview
    um_apt_autoremove_guarded || return "${UM_EXIT_APT}"
    um_apt_run clean || return "${UM_EXIT_APT}"
    local pkg
    while IFS= read -r pkg; do
      um_sudo dpkg --purge -- "$pkg" 2>/dev/null || true
    done < <(um_apt_residual_configs)
  fi

  return 0
}
