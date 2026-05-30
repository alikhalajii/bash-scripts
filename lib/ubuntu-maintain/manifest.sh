#!/usr/bin/env bash

um_manifest_print() {
  um_log ""
  um_log "=== Capability manifest ==="
  um_log "timestamp: ${UM_CAP[manifest_timestamp]}"
  um_log "os: ${UM_CAP[os_pretty]:-${UM_CAP[os_id]} ${UM_CAP[os_version_id]}}"
  if [[ -n "${UM_CAP[eol_warning]:-}" ]]; then
    um_log "warning: ${UM_CAP[eol_warning]}"
  fi

  um_log ""
  um_log "apt:"
  um_log "  available: ${UM_CAP[apt_available]:-0}"
  um_log "  tier: ${UM_CAP[apt_tier_selected]:-n/a}"
  um_log "  upgrade_cmd: ${UM_CAP[apt_upgrade_cmd]:-n/a}"
  um_log "  lock_wait: ${UM_CAP[lock_wait_mode]:-n/a}"
  um_log "  locks_held: ${UM_CAP[apt_locks_held]:-none}"
  um_log "  held_packages: ${UM_CAP[apt_held_count]:-0}"

  um_log ""
  um_log "snap:"
  um_log "  available: ${UM_CAP[snap_available]:-0}"
  um_log "  has_packages: ${UM_CAP[snap_has_packages]:-0}"

  um_log ""
  um_log "topgrade:"
  um_log "  available: ${UM_CAP[topgrade_available]:-0}"
  um_log "  requested: ${UM_WITH_TOPGRADE}"

  um_log ""
  um_log "flatpak:"
  um_log "  available: ${UM_CAP[flatpak_available]:-0}"
  um_log "  has_remotes: ${UM_CAP[flatpak_has_remotes]:-0}"

  um_log ""
  um_log "coexistence:"
  um_log "  unattended-upgrades: ${UM_CAP[unattended_upgrades_active]:-unknown}"
  um_log "  apt-daily.timer: ${UM_CAP[apt_daily_active]:-unknown}"

  um_log ""
  um_log "preflight health:"
  um_log "  reboot_required: ${UM_CAP[reboot_required_preflight]:-0}"
  um_log "  failed_units: ${UM_CAP[failed_units_preflight]:-0}"

  um_log ""
  um_log "planned phases:"
  um_manifest_planned_phases
  um_log "========================="
}

um_manifest_planned_phases() {
  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    um_log "  - apt (${UM_CAP[apt_tier_selected]})"
  fi
  if [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]]; then
    um_log "  - snap refresh"
    if [[ "${UM_MODE}" == "monthly" ]]; then um_log "  - snap revision cleanup (monthly)"; fi
  fi
  if [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]]; then
    um_log "  - flatpak update"
    if [[ "${UM_MODE}" == "monthly" ]]; then um_log "  - flatpak uninstall --unused (monthly)"; fi
  fi
  if [[ "${UM_WITH_TOPGRADE}" -eq 1 && "${UM_CAP[topgrade_available]:-0}" -eq 1 ]]; then
    um_log "  - topgrade (language/user PMs)"
  fi
  um_log "  - stability gate"
  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log ""
    um_log "DRY-RUN: no changes will be made. Use --apply to execute."
  fi
}

um_manifest_count_apt_removals() {
  local sim="$1"
  # apt-get -s uses Inst/Remv/Conf prefixes
  echo "$sim" | grep -cE '^Remv ' || true
}

um_manifest_apt_simulate_summary() {
  local sim held_changes removals
  sim="$(um_apt_simulate_upgrade 2>/dev/null || true)"
  UM_CAP[apt_simulate_output]="$sim"
  removals="$(um_manifest_count_apt_removals "$sim")"
  UM_CAP[apt_simulated_removals]="$removals"
  held_changes="$(echo "$sim" | grep -ci 'held' || true)"
  UM_CAP[apt_simulated_held_mentions]="$held_changes"

  um_log ""
  um_log "apt simulate (${UM_CAP[apt_tier_selected]}):"
  um_log "  packages_to_remove: ${removals}"
  if [[ "$removals" -gt 0 && "${UM_AGGRESSIVE}" -eq 0 ]]; then
    um_log "  note: removals detected; use --aggressive to allow dist-upgrade removals"
  fi
  if echo "$sim" | grep -qi 'held packages'; then
    um_log "  warning: held packages may block some upgrades"
  fi
}
