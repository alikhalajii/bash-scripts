#!/usr/bin/env bash
# firmware.sh — Firmware phase (fwupd): report updates; install only after a y on a terminal.
# Provides: um_firmware_phase, um_system_firmware_line, um_fw_confirm, um_have_tty,
#           um_fw_can_install
# Example:  um_firmware_phase || rc=$?    # 0, or UM_EXIT_FIRMWARE (14) if an install failed
# Sourced by: common.sh → um_source_libs

# Declared in common.sh; repeated here so shellcheck can infer the associative-array type.
declare -gA UM_CAP

# Without these, --assume-yes would also say yes to uploading reports, enabling extra
# download remotes, security tweaks and restarting the machine. fwupd's own safety checks
# (battery, AC power) stay on: never add --force or --no-safety-check.
UM_FW_INSTALL_FLAGS=(--assume-yes --no-reboot-check --no-unreported-check --no-remote-check --no-security-fix)

# Older fwupd (e.g. on 18.04/20.04) lacks some flags: then never install from here.
um_fw_can_install() {
  local help flag
  help="$(um_fw_cmd --help 2>/dev/null)"
  for flag in "${UM_FW_INSTALL_FLAGS[@]}"; do
    [[ "$help" == *"$flag"* ]] || return 1
  done
}

# A person is there to answer: stdin is a terminal and a controlling terminal can be opened
# (false from a timer, cron, or sudo started without a terminal).
um_have_tty() {
  [[ -t 0 ]] && { : </dev/tty; } 2>/dev/null
}

# um_fw_confirm N [INPUT]: ask once; 0 only for y/Y. No answer within 5 minutes is a no.
# Keys typed before the question (e.g. during the apt output) are discarded first, so only
# an answer given after reading the question counts.
um_fw_confirm() {
  local n="$1" input="${2:-/dev/tty}" answer="" fd rc=0
  exec {fd}<"$input" || return 1
  while read -r -t 0.2 -u "$fd" _; do :; done
  read -r -t 300 -u "$fd" -p "Install ${n} firmware update(s) now? A restart may be needed to finish. [y/N] " answer || rc=$?
  exec {fd}<&-
  if [[ "$rc" -ne 0 ]]; then
    printf '\n'
    um_log "No answer; firmware not installed."
    return 1
  fi
  [[ "$answer" == [yY] ]]
}

# "System firmware: <version>, released <YYYY-MM-DD>" from DMI (readable without root);
# nothing when the machine has no DMI data (some VMs, ARM boards). Vendor strings: control
# characters removed.
um_system_firmware_line() {
  local dir="${UM_DMI_DIR:-/sys/class/dmi/id}" ver date
  ver="$(tr -d '[:cntrl:]' < "${dir}/bios_version" 2>/dev/null)"
  [[ -n "$ver" ]] || return 0
  date="$(tr -d '[:cntrl:]' < "${dir}/bios_date" 2>/dev/null)"
  # DMI dates are MM/DD/YYYY.
  if [[ "$date" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})$ ]]; then
    date="${BASH_REMATCH[3]}-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  fi
  printf 'System firmware: %s%s\n' "$ver" "${date:+, released ${date}}"
}

# Dry run: list pending updates. --apply: refresh metadata, list, ask (terminal only), install.
# Sets UM_CAP[firmware_pending] or [firmware_installed]. Returns 0 or UM_EXIT_FIRMWARE.
um_firmware_phase() {
  [[ "${UM_CAP[firmware_available]:-0}" -eq 1 ]] || return 0
  um_section "Firmware"
  local sysfw
  sysfw="$(um_system_firmware_line)"
  [[ -z "$sysfw" ]] || um_log "$sysfw"

  if [[ "${UM_APPLY}" -eq 1 ]]; then
    local refresh_rc=0
    um_fw_cmd refresh --json >/dev/null 2>&1 || refresh_rc=$?
    if [[ "$refresh_rc" -ne 0 && "$refresh_rc" -ne 2 ]]; then
      um_log "warning: fwupd metadata refresh failed (exit ${refresh_rc}); using the metadata it already has"
    fi
    um_probe_firmware
  fi

  local n="${UM_CAP[firmware_updates]:-unknown}" dev ver
  if [[ "$n" == "unknown" ]]; then
    um_log "note: could not check for firmware updates (fwupdmgr get-updates failed)"
    return 0
  fi
  if [[ "$n" -eq 0 ]]; then
    um_log "Firmware: up to date"
    return 0
  fi
  um_log "Firmware updates available:"
  while IFS=$'\t' read -r dev ver; do
    [[ -n "$dev" ]] && um_log "  ${dev}: ${ver}"
  done <<<"${UM_CAP[firmware_list]}"

  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] with --apply on a terminal, would ask before installing ${n} firmware update(s)"
    return 0
  fi

  if ! um_fw_can_install; then
    um_log "note: this fwupd version cannot install without asking its own questions"
  elif um_have_tty && um_fw_confirm "$n"; then
    local rc=0
    # No time limit and no C locale: a flash must not be interrupted, and its messages are
    # for the person watching.
    fwupdmgr update "${UM_FW_INSTALL_FLAGS[@]}" </dev/null || rc=$?
    case "$rc" in
      0) UM_CAP[firmware_installed]=1; um_log "Firmware updated." ; return 0 ;;
      2) um_log "Firmware: nothing was installed." ; return 0 ;;
      *) um_log "error: fwupdmgr update failed (exit ${rc})" ; return "${UM_EXIT_FIRMWARE}" ;;
    esac
  fi
  UM_CAP[firmware_pending]="$n"
  um_log "Firmware updates available: ${n} (not installed; run 'sudo fwupdmgr update')"
  return 0
}
