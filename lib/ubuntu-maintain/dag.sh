#!/usr/bin/env bash
# dag.sh — Orchestrate probes → manifest → apt → snap → flatpak → topgrade → stability.
# Provides: um_run_dag
# Sourced by: common.sh → um_source_libs

um_run_dag() {
  local exit_code=0
  local apt_rc=0 snap_rc=0 flatpak_rc=0 stab_rc=0 topgrade_rc=0

  um_run_probes
  um_manifest_print

  if [[ "${UM_MANIFEST_ONLY}" -eq 1 ]]; then
    if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
      um_manifest_apt_simulate_summary || um_log "note: apt simulate skipped or incomplete without root"
    fi
    return 0
  fi

  if [[ "${UM_APPLY}" -eq 1 ]]; then
    um_need_root
  fi

  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    um_apt_env
    if ! um_manifest_apt_simulate_summary; then
      if [[ "${UM_APPLY}" -eq 0 ]]; then
        um_log "note: apt simulate incomplete without root"
      else
        um_log "APT simulate failed before apply (exit ${UM_EXIT_APT})"
        return "${UM_EXIT_APT}"
      fi
    fi
  fi

  um_apt_phase || apt_rc=$?
  if [[ "$apt_rc" -ne 0 ]]; then
    um_log "APT phase failed (exit ${apt_rc})"
    exit_code="$apt_rc"
    if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 0 ]]; then
      if [[ "${UM_APPLY}" -eq 1 ]]; then
        um_stability_gate || stab_rc=$?
      fi
      return $(( exit_code != 0 ? exit_code : stab_rc ))
    fi
  fi

  um_snap_phase || snap_rc=$?
  if [[ "$snap_rc" -ne 0 ]]; then
    um_log "Snap phase failed (exit ${snap_rc})"
    if [[ "$exit_code" -eq 0 ]]; then exit_code="$snap_rc"; fi
    if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 0 ]]; then
      if [[ "${UM_APPLY}" -eq 1 ]]; then
        um_stability_gate || stab_rc=$?
      fi
      return $(( exit_code != 0 ? exit_code : stab_rc ))
    fi
  fi

  um_flatpak_phase || flatpak_rc=$?
  if [[ "$flatpak_rc" -ne 0 ]]; then
    um_log "Flatpak phase failed (exit ${flatpak_rc})"
    if [[ "$exit_code" -eq 0 ]]; then exit_code="${flatpak_rc}"; fi
    if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 0 ]]; then
      if [[ "${UM_APPLY}" -eq 1 ]]; then
        um_stability_gate || stab_rc=$?
      fi
      return $(( exit_code != 0 ? exit_code : stab_rc ))
    fi
  fi

  um_topgrade_phase || topgrade_rc=$?
  if [[ "$topgrade_rc" -ne 0 ]]; then
    um_log "Topgrade phase failed (exit ${topgrade_rc})"
    if [[ "$exit_code" -eq 0 ]]; then exit_code="$topgrade_rc"; fi
    if [[ "${UM_CONTINUE_ON_FAILURE}" -eq 0 ]]; then
      if [[ "${UM_APPLY}" -eq 1 ]]; then
        um_stability_gate || stab_rc=$?
      fi
      return $(( exit_code != 0 ? exit_code : stab_rc ))
    fi
  fi

  if [[ "${UM_APPLY}" -eq 1 ]]; then
    um_stability_gate || stab_rc=$?
    if [[ "$stab_rc" -ne 0 && "$exit_code" -eq 0 ]]; then exit_code="$stab_rc"; fi
  else
    um_log "Stability gate skipped in dry-run (use --apply to verify system health)."
  fi

  if [[ "${UM_APPLY}" -eq 1 ]]; then
    if [[ "$exit_code" -eq 0 ]]; then
      um_log "ubuntu-maintain completed successfully."
    else
      um_log "ubuntu-maintain finished with errors (exit ${exit_code})."
    fi
    um_log "Log: ${UM_LOG_FILE}"
  fi

  return "$exit_code"
}
