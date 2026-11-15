#!/usr/bin/env bash
# snap.sh — Snap phase: refresh; monthly, remove disabled revisions and the download cache.
# Provides: um_snap_phase, um_snap_disabled_revisions
# Example:  um_snap_phase || rc=$?        # 0, or UM_EXIT_SNAP (11)
# Sourced by: common.sh → um_source_libs

# Print pending snap refreshes (informational; never fails).
um_snap_preflight_list() {
  LANG=C snap refresh --list 2>/dev/null || true
}

# Disabled (superseded) snap revisions as "name rev" lines; monthly removes them.
um_snap_disabled_revisions() {
  LC_ALL=C snap list --all 2>/dev/null | awk 'NR>1 && $NF ~ /(^|,)disabled(,|$)/ {print $1, $3}' || true
}

# Dry run: print the plan. --apply: refresh; monthly, remove disabled revisions and the
# download cache. Returns 0 or UM_EXIT_SNAP.
um_snap_phase() {
  [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]] || return 0

  um_section "Snap"
  um_snap_preflight_list

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] would run: snap refresh"
    if [[ "${UM_MODE}" == "monthly" ]]; then
      local -a revs=()
      mapfile -t revs < <(um_snap_disabled_revisions)
      [[ ${#revs[@]} -gt 0 ]] || um_log "[dry-run] no disabled snap revisions to remove"
      local rev
      for rev in "${revs[@]}"; do um_log "[dry-run] would remove disabled revision: ${rev}"; done
    fi
    return 0
  fi

  um_log "Refreshing snaps..."
  if ! um_sudo env LANG=C snap refresh; then
    return "${UM_EXIT_SNAP}"
  fi

  if [[ "${UM_MODE}" == "monthly" ]]; then
    um_log "Removing disabled snap revisions (monthly)..."
    local name rev
    while read -r name rev; do
      [[ -n "$name" && -n "$rev" ]] || continue
      um_sudo snap remove "$name" --revision="$rev" 2>/dev/null || true
    done < <(um_snap_disabled_revisions)
    um_sudo rm -rf /var/lib/snapd/cache/* 2>/dev/null || true
  fi

  return 0
}
