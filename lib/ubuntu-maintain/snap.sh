#!/usr/bin/env bash

um_snap_preflight_list() {
  LANG=C snap refresh --list 2>/dev/null || true
}

um_snap_phase() {
  [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]] || return 0

  um_log ""
  um_log "=== Snap ==="
  um_snap_preflight_list

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: snap refresh"
    [[ "${UM_MODE}" == "monthly" ]] && um_log "[dry-run] would prune disabled snap revisions"
    return 0
  fi

  um_log "Refreshing snaps..."
  if ! um_sudo env LANG=C snap refresh; then
    return "${UM_EXIT_SNAP}"
  fi

  if [[ "${UM_MODE}" == "monthly" ]]; then
    um_log "Removing disabled snap revisions (monthly)..."
    LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
      [[ -n "$name" && -n "$rev" ]] || continue
      um_sudo snap remove "$name" --revision="$rev" 2>/dev/null || true
    done
    um_sudo rm -rf /var/lib/snapd/cache/* 2>/dev/null || true
  fi

  return 0
}
