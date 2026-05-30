#!/usr/bin/env bash

# Topgrade handles language/user PMs; ubuntu-maintain owns apt/snap/flatpak.
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

  um_log "Running topgrade (apt/snap/flatpak disabled — already handled)..."
  if topgrade -y "${disable_args[@]}"; then
    return 0
  fi
  um_log "warning: topgrade exited non-zero"
  if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 1 ]]; then
    return 0
  fi
  return 13
}
