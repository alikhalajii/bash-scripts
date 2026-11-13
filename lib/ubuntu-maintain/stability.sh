#!/usr/bin/env bash
# stability.sh — Post-apply health gate (failed units, reboot, needrestart, dpkg).
# Provides: um_stability_gate
# Sourced by: common.sh → um_source_libs

um_stability_gate() {
  um_section "Stability gate"
  local rc=0
  local -a reasons=()

  if um_probe_command dpkg; then
    if dpkg --audit 2>/dev/null | grep -q .; then
      um_log "Running dpkg --configure -a..."
      um_sudo dpkg --configure -a || {
        reasons+=("dpkg --configure -a failed")
        [[ "${UM_IGNORE_STABILITY}" -eq 0 ]] && rc="${UM_EXIT_STABILITY}"
      }
    fi
  fi

  um_probe_restart_needs
  if [[ -n "${UM_CAP[reboot_reason]}" ]]; then
    um_log "REBOOT REQUIRED (${UM_CAP[reboot_reason]})"
    reasons+=("reboot required (${UM_CAP[reboot_reason]})")
    if um_is_wsl; then um_log "  on WSL: run 'wsl --shutdown' on the host, then reopen the distro"; fi
    if [[ "${UM_IGNORE_STABILITY}" -eq 0 ]]; then rc="${UM_EXIT_STABILITY}"; fi
  elif [[ -n "${UM_CAP[restart_reason]}" ]]; then
    # Not a failure: the update is installed; running programs pick it up when restarted.
    um_log "Restart recommended: ${UM_CAP[restart_reason]}"
  fi

  if um_probe_command systemctl; then
    um_classify_failed_units
    local entry
    if [[ ${#UM_FAILED_UNEXPECTED[@]} -gt 0 ]]; then
      um_log "Failed systemd units:"
      printf '%s\n' "${UM_FAILED_UNEXPECTED[@]}"
      reasons+=("${#UM_FAILED_UNEXPECTED[@]} failed systemd unit(s)")
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

  # Read by um_result_print to explain exit 2 in one line.
  local joined="" reason
  for reason in "${reasons[@]}"; do joined+="${joined:+; }${reason}"; done
  # shellcheck disable=SC2154  # UM_CAP is declared in common.sh
  UM_CAP[stability_issues]="$joined"
  if [[ "$rc" -eq 0 ]]; then
    um_log "Stability gate: OK"
  else
    um_log "Stability gate: issues detected (exit ${rc})"
  fi

  return "$rc"
}
