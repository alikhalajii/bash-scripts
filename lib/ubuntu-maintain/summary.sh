#!/usr/bin/env bash
# summary.sh — Capture pre/post PM snapshots and print a structured apply summary.
# Provides: um_summary_init, um_summary_snapshot, um_summary_print, um_result_print
# Sourced by: common.sh → um_source_libs

# Declared in common.sh; repeated here so shellcheck can infer the associative-array type.
declare -gA UM_CAP

UM_SUMMARY_DIR=""

um_summary_init() {
  UM_SUMMARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-maintain-summary.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${UM_SUMMARY_DIR}'" EXIT
}

um_summary_snapshot() {
  local label="$1"
  [[ -n "$UM_SUMMARY_DIR" ]] || return 0

  # All snapshot files use normalized "name version" (space-separated, one per line, sorted).
  # "version" is whatever changes on update: apt version, snap revision, flatpak commit.
  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    # Installed packages only (status ii/hi). Config-only leftovers ("rc") are not
    # installed, so purging them must not be reported as a removal. binary:Package keeps
    # the :arch suffix of Multi-Arch: same packages, so libc6:i386 and libc6:amd64 differ.
    dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package} ${Version}\n' 2>/dev/null \
      | awk '$1 ~ /^[ih]i/ && NF==3 {print $2, $3}' \
      | sort > "${UM_SUMMARY_DIR}/${label}-apt" || true
  fi

  if [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]]; then
    LANG=C snap list 2>/dev/null \
      | awk 'NR>1 && NF>=3{print $1, $3}' \
      | sort > "${UM_SUMMARY_DIR}/${label}-snap" || true
  fi

  if [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]]; then
    # ref (app or runtime, with arch and branch) and the active commit: runtimes are most
    # updates, and a new commit often keeps the same version string.
    flatpak list --system --columns=ref,active 2>/dev/null \
      | awk 'NF>=2{print $1, $2}' \
      | sort > "${UM_SUMMARY_DIR}/${label}-flatpak" || true
  fi
}

# _um_count_changes <before> <after>
# Prints two lines: "N" (count) and the space-separated package names.
# Uses awk for all lookups — safe with package names containing regex metacharacters.
_um_count_changes() {
  local before="$1" after="$2"
  [[ -f "$before" && -f "$after" ]] || { printf '0\n\n'; return 0; }
  awk '
    NR==FNR { pre[$1]=$2; next }
    NF<2    { next }
    !($1 in pre) || pre[$1] != $2 { names=names (names?" ":"") $1; count++ }
    END { print (count+0); print names }
  ' "$before" "$after"
}

# _um_diff_apt <before> <after>
# Prints three groups (installed/upgraded/removed), each as "N name1 name2 ...".
_um_diff_apt() {
  local before="$1" after="$2"
  [[ -f "$before" && -f "$after" ]] || {
    printf '0\n\n0\n\n0\n\n'
    return 0
  }
  awk '
    NR==FNR { pre[$1]=$2; next }
    NF<2    { next }
    !($1 in pre)           { inst=inst (inst?" ":"") $1; inst_n++ }
    ($1 in pre) && pre[$1] != $2 { upg=upg (upg?" ":"") $1 "(" pre[$1] "->" $2 ")"; upg_n++ }
    END {
      print (inst_n+0); print inst
      print (upg_n+0);  print upg
    }
  ' "$before" "$after"
  awk '
    NR==FNR { post[$1]=1; next }
    NF<2    { next }
    !($1 in post) { rem=rem (rem?" ":"") $1; rem_n++ }
    END { print (rem_n+0); print rem }
  ' "$after" "$before"
}

um_summary_print() {
  [[ -n "$UM_SUMMARY_DIR" ]] || return 0

  um_section "Update Summary"

  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    local apt_diff inst_n inst_names upg_n upg_names rem_n rem_names
    apt_diff="$(_um_diff_apt \
      "${UM_SUMMARY_DIR}/pre-apt" "${UM_SUMMARY_DIR}/post-apt")"
    inst_n="$(printf '%s' "$apt_diff"     | awk 'NR==1')"
    inst_names="$(printf '%s' "$apt_diff" | awk 'NR==2')"
    upg_n="$(printf '%s' "$apt_diff"      | awk 'NR==3')"
    upg_names="$(printf '%s' "$apt_diff"  | awk 'NR==4')"
    rem_n="$(printf '%s' "$apt_diff"      | awk 'NR==5')"
    rem_names="$(printf '%s' "$apt_diff"  | awk 'NR==6')"
    um_log "APT:"
    um_log "  Installed: ${inst_n:-0}${inst_names:+ (${inst_names})}"
    um_log "  Upgraded:  ${upg_n:-0}${upg_names:+  (${upg_names})}"
    um_log "  Removed:   ${rem_n:-0}${rem_names:+  (${rem_names})}"
  fi

  if [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]]; then
    local snap_diff snap_n snap_names
    snap_diff="$(_um_count_changes \
      "${UM_SUMMARY_DIR}/pre-snap" "${UM_SUMMARY_DIR}/post-snap")"
    snap_n="$(printf '%s' "$snap_diff"     | awk 'NR==1')"
    snap_names="$(printf '%s' "$snap_diff" | awk 'NR==2')"
    um_log ""
    um_log "Snap:"
    um_log "  Refreshed: ${snap_n:-0}${snap_names:+ (${snap_names})}"
  fi

  if [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]]; then
    local fp_diff fp_n fp_names
    fp_diff="$(_um_count_changes \
      "${UM_SUMMARY_DIR}/pre-flatpak" "${UM_SUMMARY_DIR}/post-flatpak")"
    fp_n="$(printf '%s' "$fp_diff"     | awk 'NR==1')"
    fp_names="$(printf '%s' "$fp_diff" | awk 'NR==2')"
    um_log ""
    um_log "Flatpak:"
    um_log "  Updated:   ${fp_n:-0}${fp_names:+ (${fp_names})}"
  fi

  um_log ""
  um_log "Stability: ${UM_CAP[summary_stability]:-OK}"
}

# Last block of every run: what happened in one sentence, the exit code, and every
# warning/error logged along the way (collected by um_log).
um_result_print() {
  local rc="$1" verdict issue reasons="${UM_CAP[stability_issues]:-}"
  local -a next=()
  case "$rc" in
    0)
      if [[ "${UM_APPLY}" -eq 1 ]]; then
        verdict="Done: updates applied and the system looks healthy."
      else
        verdict="Dry run: nothing was changed. Run with --apply to apply."
      fi ;;
    "${UM_EXIT_STABILITY}")
      verdict="Updates applied, but the system needs attention: ${reasons:-see the stability gate above}"
      [[ "$reasons" == *"reboot required"* ]] && next+=("reboot to finish the update.")
      [[ "$reasons" == *"failed systemd unit"* ]] && next+=("check the failed units above (systemctl status <unit>), or re-run with --ignore-stability if they are expected.")
      [[ "$reasons" == *"dpkg --configure -a failed"* ]] && next+=("run 'sudo dpkg --configure -a' and read its errors.")
      ;;
    "${UM_EXIT_APT}")      verdict="APT step failed; see its section above." ;;
    "${UM_EXIT_SNAP}")     verdict="Snap step failed; see its section above." ;;
    "${UM_EXIT_FLATPAK}")  verdict="Flatpak step failed; see its section above." ;;
    "${UM_EXIT_TOPGRADE}") verdict="Topgrade step failed; see its section above." ;;
    *)                     verdict="Finished with errors." ;;
  esac
  um_section "Result"
  printf '%s\n' "$verdict"
  for issue in "${next[@]}"; do printf 'Next: %s\n' "$issue"; done
  for issue in "${UM_ISSUES[@]}"; do printf '  ! %s\n' "$issue"; done
  printf 'Exit code: %s\n' "$rc"
  [[ -n "${UM_LOG_FILE:-}" ]] && printf 'Log: %s\n' "$UM_LOG_FILE"
  return 0
}
