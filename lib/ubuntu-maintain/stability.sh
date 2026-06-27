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

  if [[ -f /var/run/reboot-required ]]; then
    um_log "REBOOT REQUIRED: $(cat /var/run/reboot-required 2>/dev/null || echo yes)"
    if [[ "${UM_IGNORE_STABILITY}" -eq 0 ]]; then rc="${UM_EXIT_STABILITY}"; fi
  fi

  if um_probe_command systemctl; then
    local failed
    failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)"
    if [[ -n "$failed" ]]; then
      um_log "Failed systemd units:"
      echo "$failed"
      if [[ "${UM_IGNORE_STABILITY}" -eq 0 ]]; then rc="${UM_EXIT_STABILITY}"; fi
    else
      um_log "No failed systemd units."
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
