#!/usr/bin/env bash
# topgrade.sh — Optional Topgrade pass for pip/cargo/npm (topgrade's own system/snap/flatpak steps disabled).
# Provides: um_topgrade_phase, um_topgrade_disable_args
# Sourced by: common.sh → um_source_libs

um_topgrade_disable_args() {
  # Disable the system package managers already handled. topgrade has no "apt" step
  # (unknown step names are rejected and topgrade exits); apt runs inside "system".
  printf '%s\n' --disable system --disable snap --disable flatpak
}

um_topgrade_phase() {
  [[ "${UM_WITH_TOPGRADE}" -eq 1 ]] || return 0
  if [[ "${UM_CAP[topgrade_available]:-0}" -ne 1 ]]; then
    um_log "warning: --with-topgrade given, but topgrade was not found for the invoking user; skipping"
    return 0
  fi

  um_section "Topgrade (language / user package managers)"

  local -a disable_args
  mapfile -t disable_args < <(um_topgrade_disable_args)

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: topgrade -n ${disable_args[*]}"
    topgrade -n "${disable_args[@]}" 2>/dev/null || um_log "topgrade preview unavailable (install via cargo or your package manager)"
    return 0
  fi

  local target_user="${SUDO_USER:-}"
  if [[ -z "$target_user" || "$target_user" == "root" ]]; then
    um_log "error: topgrade requires a non-root invoking user (SUDO_USER='${SUDO_USER:-}'); skipping phase"
    return "${UM_EXIT_TOPGRADE}"
  fi

  um_log "Running topgrade as ${target_user} (apt/snap/flatpak disabled — already handled)..."
  if sudo -u "$target_user" -i topgrade -y "${disable_args[@]}"; then
    return 0
  fi
  um_log "warning: topgrade exited non-zero"
  # Always report the failure; um_run_dag applies --continue-on-pm-failure uniformly.
  return "${UM_EXIT_TOPGRADE}"
}
