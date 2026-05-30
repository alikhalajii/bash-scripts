#!/usr/bin/env bash
# flatpak.sh — Flatpak update and optional monthly unused-app removal.
# Provides: um_flatpak_phase
# Sourced by: common.sh → um_source_libs

um_flatpak_noninteractive_flags() {
  # Prefer --noninteractive; fall back to -y on older flatpak
  if flatpak update --help 2>&1 | grep -q -- '--noninteractive'; then
    echo "--noninteractive -y"
  else
    echo "-y"
  fi
}

um_flatpak_phase() {
  [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]] || return 0

  um_log ""
  um_log "=== Flatpak ==="
  flatpak remote-ls --updates 2>/dev/null || true

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: flatpak update"
    [[ "${UM_MODE}" == "monthly" ]] && um_log "[dry-run] would run: flatpak uninstall --unused"
    return 0
  fi

  local -a flags
  # shellcheck disable=SC2206
  flags=( $(um_flatpak_noninteractive_flags) )

  um_log "Updating flatpak apps..."
  if ! flatpak update "${flags[@]}"; then
    return "${UM_EXIT_FLATPAK}"
  fi

  if [[ "${UM_MODE}" == "monthly" ]]; then
    um_log "Removing unused flatpak runtimes (monthly)..."
    flatpak uninstall --unused "${flags[@]}" 2>/dev/null || true
  fi

  return 0
}
