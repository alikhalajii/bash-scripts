#!/usr/bin/env bash
# topgrade.sh — Optional Topgrade pass for pip/cargo/npm (disables apt/snap/flatpak).
# Provides: um_topgrade_phase, um_topgrade_disable_args
# Sourced by: common.sh → um_source_libs

um_topgrade_disable_args() {
  # Step names vary by topgrade version; disable system package managers we already ran.
  local -a args=(--disable apt --disable snap --disable flatpak)
  if topgrade --help 2>&1 | grep -q -- '--disable.*system'; then
    args+=(--disable system)
  fi
  printf '%s\n' "${args[@]}"
}

um_topgrade_phase() {
  [[ "${UM_WITH_TOPGRADE}" -eq 1 ]] || return 0
  [[ "${UM_CAP[topgrade_available]:-0}" -eq 1 ]] || return 0

  um_log ""
  um_log "=== Topgrade (language / user package managers) ==="

  local -a disable_args
  mapfile -t disable_args < <(um_topgrade_disable_args)

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: topgrade -n ${disable_args[*]}"
    topgrade -n "${disable_args[@]}" 2>/dev/null || um_log "topgrade preview unavailable (install: cargo/brew/apt)"
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
  if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 1 ]]; then
    return 0
  fi
  return "${UM_EXIT_TOPGRADE}"
}
