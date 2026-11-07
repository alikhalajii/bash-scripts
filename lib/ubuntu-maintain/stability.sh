#!/usr/bin/env bash
# stability.sh — Post-apply health gate (failed units, reboot, needrestart, dpkg).
# Provides: um_stability_gate
# Sourced by: common.sh → um_source_libs

um_stability_gate() {
  um_log ""
  um_log "=== Stability gate ==="
  local rc=0

  if um_probe_command dpkg; then
    if dpkg --audit 2>/dev/null | grep -q .; then
      um_log "Running dpkg --configure -a..."
      um_sudo dpkg --configure -a || { [[ "${UM_IGNORE_STABILITY}" -eq 0 ]] && rc="${UM_EXIT_STABILITY}"; }
    fi
  fi

  local reboot_file pkgs
  reboot_file="$(um_reboot_required_file)"
  if [[ -f "$reboot_file" ]]; then
    pkgs=""; [[ -f "${reboot_file}.pkgs" ]] && pkgs="$(tr '\n' ' ' < "${reboot_file}.pkgs")"
    um_log "REBOOT REQUIRED${pkgs:+ (packages: ${pkgs% })}"
    if um_is_wsl; then um_log "  on WSL: run 'wsl --shutdown' on the host, then reopen the distro"; fi
    if [[ "${UM_IGNORE_STABILITY}" -eq 0 ]]; then rc="${UM_EXIT_STABILITY}"; fi
  fi

  if um_probe_command systemctl; then
    um_classify_failed_units
    local entry
    if [[ ${#UM_FAILED_UNEXPECTED[@]} -gt 0 ]]; then
      um_log "Failed systemd units:"
      printf '%s\n' "${UM_FAILED_UNEXPECTED[@]}"
      if [[ "${UM_IGNORE_STABILITY}" -eq 0 ]]; then rc="${UM_EXIT_STABILITY}"; fi
    else
      um_log "No ${UM_FAILED_EXPECTED[*]:+unexpected }failed systemd units."
    fi
    if [[ ${#UM_FAILED_EXPECTED[@]} -gt 0 ]]; then
      um_log "Failed units expected in this environment (can be ignored):"
      for entry in "${UM_FAILED_EXPECTED[@]}"; do um_log "  ${entry}"; done
    fi
  fi

  if [[ "${UM_CAP[needrestart_available]:-0}" -eq 1 ]]; then
    um_log "needrestart report:"
    if [[ "${UM_RESTART_SERVICES}" -eq 1 ]]; then
      um_sudo env NEEDRESTART_MODE=a needrestart -b 2>/dev/null || \
        needrestart -b 2>/dev/null || true
    else
      needrestart -b 2>/dev/null || um_sudo needrestart -r l 2>/dev/null || true
    fi
  fi

  if [[ "$rc" -eq 0 ]]; then
    um_log "Stability gate: OK"
  else
    um_log "Stability gate: issues detected (exit ${rc})"
  fi

  return "$rc"
}
