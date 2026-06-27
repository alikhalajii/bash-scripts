#!/usr/bin/env bash
# summary.sh — Capture pre/post PM snapshots and print a structured apply summary.
# Provides: um_summary_init, um_summary_snapshot, um_summary_print
# Sourced by: common.sh → um_source_libs

# Declared in common.sh; repeated here so shellcheck can infer the associative-array type.
declare -gA UM_CAP

UM_SUMMARY_DIR=""

um_summary_init() {
  UM_SUMMARY_DIR="$(mktemp -d /tmp/ubuntu-maintain-summary.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '${UM_SUMMARY_DIR}'" EXIT
}

um_summary_snapshot() {
  local label="$1"
  [[ -n "$UM_SUMMARY_DIR" ]] || return 0

  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null \
      | sort > "${UM_SUMMARY_DIR}/${label}-apt" || true
  fi

  if [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]]; then
    LANG=C snap list 2>/dev/null | awk 'NR>1 {print $1, $2}' \
      | sort > "${UM_SUMMARY_DIR}/${label}-snap" || true
  fi

  if [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]]; then
    flatpak list --app --columns=application,version 2>/dev/null \
      | sort > "${UM_SUMMARY_DIR}/${label}-flatpak" || true
  fi
}

# Diff two "name version" snapshot files; print one line each:
#   installed <count> [name ...]
#   upgraded  <count> [name oldver->newver ...]
#   removed   <count> [name ...]
_um_diff_pkg() {
  local before="$1" after="$2"
  local inst_n=0 upg_n=0 rem_n=0
  local inst_list="" upg_list="" rem_list=""
  local pkg ver_before ver_after

  if [[ ! -f "$before" || ! -f "$after" ]]; then
    printf 'installed 0\nupdated 0\nremoved 0\n'
    return 0
  fi

  while IFS=' ' read -r pkg _; do
    if ! grep -q "^${pkg} " "$after" 2>/dev/null; then
      rem_n=$(( rem_n + 1 ))
      rem_list="${rem_list:+${rem_list} }${pkg}"
    fi
  done < "$before"

  while IFS=' ' read -r pkg ver_after; do
    if ! grep -q "^${pkg} " "$before" 2>/dev/null; then
      inst_n=$(( inst_n + 1 ))
      inst_list="${inst_list:+${inst_list} }${pkg}"
    else
      ver_before="$(awk -v p="$pkg" '$1==p {print $2; exit}' "$before")"
      if [[ "$ver_before" != "$ver_after" ]]; then
        upg_n=$(( upg_n + 1 ))
        upg_list="${upg_list:+${upg_list} }${pkg}(${ver_before}->${ver_after})"
      fi
    fi
  done < "$after"

  printf 'installed %d %s\n' "$inst_n" "$inst_list"
  printf 'upgraded %d %s\n'  "$upg_n"  "$upg_list"
  printf 'removed %d %s\n'   "$rem_n"  "$rem_list"
}

# Diff two "name version" snapshot files for snap/flatpak (report new/changed as updated).
_um_diff_refreshed() {
  local before="$1" after="$2"
  local count=0 names="" pkg ver_after ver_before

  if [[ ! -f "$before" || ! -f "$after" ]]; then
    printf '0\n'
    return 0
  fi

  while IFS=' ' read -r pkg ver_after; do
    local changed=0
    if ! grep -q "^${pkg} " "$before" 2>/dev/null; then
      changed=1
    else
      ver_before="$(awk -v p="$pkg" '$1==p {print $2; exit}' "$before")"
      [[ "$ver_before" != "$ver_after" ]] && changed=1
    fi
    if [[ "$changed" -eq 1 ]]; then
      count=$(( count + 1 ))
      names="${names:+${names} }${pkg}"
    fi
  done < "$after"

  printf '%d %s\n' "$count" "$names"
}

um_summary_print() {
  [[ -n "$UM_SUMMARY_DIR" ]] || return 0

  um_log ""
  um_log "=== Update Summary ==="

  if [[ "${UM_CAP[apt_available]:-0}" -eq 1 ]]; then
    um_log "APT:"
    local diff_out inst_line upg_line rem_line
    diff_out="$(_um_diff_pkg \
      "${UM_SUMMARY_DIR}/pre-apt" "${UM_SUMMARY_DIR}/post-apt")"
    inst_line="$(echo "$diff_out" | awk '/^installed/{$1=""; sub(/^ /,""); print}')"
    upg_line="$(echo "$diff_out"  | awk '/^upgraded/{$1=""; sub(/^ /,""); print}')"
    rem_line="$(echo "$diff_out"  | awk '/^removed/{$1=""; sub(/^ /,""); print}')"
    um_log "  Installed: ${inst_line:-0}"
    um_log "  Upgraded:  ${upg_line:-0}"
    um_log "  Removed:   ${rem_line:-0}"
  fi

  if [[ "${UM_CAP[snap_has_packages]:-0}" -eq 1 ]]; then
    um_log ""
    um_log "Snap:"
    local snap_out
    snap_out="$(_um_diff_refreshed \
      "${UM_SUMMARY_DIR}/pre-snap" "${UM_SUMMARY_DIR}/post-snap")"
    um_log "  Refreshed: ${snap_out:-0}"
  fi

  if [[ "${UM_CAP[flatpak_has_remotes]:-0}" -eq 1 ]]; then
    um_log ""
    um_log "Flatpak:"
    local flatpak_out
    flatpak_out="$(_um_diff_refreshed \
      "${UM_SUMMARY_DIR}/pre-flatpak" "${UM_SUMMARY_DIR}/post-flatpak")"
    um_log "  Updated:   ${flatpak_out:-0}"
  fi

  um_log ""
  um_log "Stability: ${UM_CAP[summary_stability]:-OK}"
  um_log "======================"
}
