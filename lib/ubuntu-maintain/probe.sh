#!/usr/bin/env bash
# probe.sh — Read-only detection: OS, package managers, apt locks, health, firmware,
#           Docker (um_probe_docker, in docker.sh).
#           Results go to UM_CAP[]; nothing here changes the system.
# Provides: um_run_probes, um_probe_*, um_fw_cmd, um_fw_parse_updates, um_is_wsl,
#           um_reboot_required_file, um_classify_failed_units, um_unit_expected_failure
# Example:  um_run_probes; echo "${UM_CAP[firmware_updates]}"
# Sourced by: common.sh → um_source_libs

# Declared in common.sh; repeated here so shellcheck can infer the associative-array type.
declare -gA UM_CAP

readonly UM_APT_LOCK_PATHS=(
  /var/lib/dpkg/lock
  /var/lib/dpkg/lock-frontend
  /var/cache/apt/archives/lock
  /var/lib/apt/lists/lock
)

um_probe_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

# apt-config dump prints `Key "value";`. apt >= 1.9.11 (20.04+) ships the knob as a
# binary-scoped default (`Binary::apt::DPkg::Lock::Timeout "120";`, case varies); an
# operator-set unscoped `DPkg::Lock::Timeout` wins. Absent on apt 1.6 (18.04).
um_probe_apt_config_timeout() {
  local raw
  raw="$(apt-config dump 2>/dev/null | awk '
    { k = tolower($1); v = $2; gsub(/[";]/, "", v) }
    k == "dpkg::lock::timeout"              { print v; found = 1; exit }
    k ~ /::dpkg::lock::timeout$/ && s == "" { s = v }
    END { if (!found && s != "") print s }')"
  # apt-config echoes any key that is set, even one this apt ignores (e.g. a fleet-wide
  # snippet on 18.04), so the key alone does not prove support.
  local ver="${UM_CAP[apt_version]:-}"
  ver="$(awk '{print $2}' <<<"$ver")"
  if [[ -n "$ver" ]] && um_probe_command dpkg \
     && dpkg --compare-versions "$ver" lt 1.9.11 2>/dev/null; then
    raw=""
  fi
  if [[ -n "$raw" && "$raw" =~ ^-?[0-9]+$ ]]; then
    UM_CAP[apt_lock_timeout_supported]=1
    UM_CAP[apt_lock_timeout]="$raw"
  else
    UM_CAP[apt_lock_timeout_supported]=0
    UM_CAP[apt_lock_timeout]=120
  fi
}

# Sets UM_CAP[apt_locks_held]: apt/dpkg lock files currently held (empty when free).
um_probe_lock_holders() {
  local path holders=()
  for path in "${UM_APT_LOCK_PATHS[@]}"; do
    if um_probe_command fuser && fuser "$path" >/dev/null 2>&1; then
      holders+=("$path")
    elif um_probe_command lsof && lsof "$path" >/dev/null 2>&1; then
      holders+=("$path")
    fi
  done
  UM_CAP[apt_locks_held]="${holders[*]:-}"
}

# Sets apt_available, apt_version, lock timeout/wait mode, held count, tier and upgrade_cmd.
um_probe_apt() {
  if ! um_probe_command apt-get; then
    UM_CAP[apt_available]=0
    return 1
  fi
  UM_CAP[apt_available]=1
  UM_CAP[apt_version]="$(apt-get --version 2>/dev/null | head -1)"

  um_probe_apt_config_timeout
  um_probe_lock_holders

  if um_probe_command apt-mark; then
    UM_CAP[apt_held_count]="$(apt-mark showhold 2>/dev/null | grep -c . || true)"
  else
    UM_CAP[apt_held_count]=0
  fi

  um_probe_apt_obsolete

  UM_CAP[apt_upgrade_standard_cmd]="apt-get upgrade --with-new-pkgs -y"
  UM_CAP[apt_upgrade_aggressive_cmd]="apt-get dist-upgrade -y"

  if [[ "${UM_AGGRESSIVE}" -eq 1 ]]; then
    UM_CAP[apt_tier_selected]="aggressive"
    UM_CAP[apt_upgrade_cmd]="${UM_CAP[apt_upgrade_aggressive_cmd]}"
  elif [[ "${UM_MODE}" == "daily" ]]; then
    UM_CAP[apt_tier_selected]="standard"
    UM_CAP[apt_upgrade_cmd]="${UM_CAP[apt_upgrade_standard_cmd]}"
  else
    UM_CAP[apt_tier_selected]="standard"
    UM_CAP[apt_upgrade_cmd]="${UM_CAP[apt_upgrade_standard_cmd]}"
  fi

  if [[ "${UM_CAP[apt_lock_timeout_supported]}" -eq 1 ]]; then
    UM_CAP[lock_wait_mode]="dpkg_timeout"
  else
    UM_CAP[lock_wait_mode]="fuser_poll"
  fi

  return 0
}

# Installed packages that no configured repository provides any more: removed PPAs, manual
# .deb installs, leftovers from older releases. Reported only, never removed: many are
# deliberate installs. Search patterns need apt >= 2.0 (not on 18.04).
um_probe_apt_obsolete() {
  UM_CAP[apt_obsolete_count]="unknown"
  UM_CAP[apt_obsolete_list]=""
  local major out
  major="${UM_CAP[apt_version]:-}"
  major="${major#apt }"
  major="${major%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$major" -ge 2 ]] || return 0
  out="$(LC_ALL=C apt list '?obsolete' 2>/dev/null)" || return 0
  UM_CAP[apt_obsolete_list]="$(awk -F/ '/\[installed/ {print $1}' <<<"$out" | paste -sd ' ')"
  UM_CAP[apt_obsolete_count]="$(awk -F/ '/\[installed/' <<<"$out" | grep -c . || true)"
}

# Every fwupdmgr query goes through here: C locale, no terminal on stdin (some subcommands
# otherwise ask questions, e.g. "Restart now?"), and a time limit. Not for `update`: killing
# the client during a flash is worse than waiting.
um_fw_cmd() {
  LC_ALL=C timeout 120 fwupdmgr "$@" </dev/null
}

# fwupd JSON on stdin -> "<device name>\t<new version>" per device with a release. Line-based
# (no jq/python): the device "Name" comes before its "Releases" array; the first "Version"
# inside the array is the newest. Device strings come from hardware and vendors, so control
# characters (terminal escapes) are removed.
um_fw_parse_updates() {
  awk '
    function val(line) {
      sub(/^[^:]*:[[:space:]]*"?/, "", line); sub(/"?,?[[:space:]]*$/, "", line)
      gsub(/[[:cntrl:]]/, "", line); return line
    }
    /"Name"[[:space:]]*:/ { name = val($0); next }
    /"Releases"[[:space:]]*:[[:space:]]*\[[[:space:]]*$/ { dev = name; want = 1; next }
    want && /"Version"[[:space:]]*:/ { print dev "\t" val($0); want = 0 }
  '
}

# firmware_available, firmware_updates (N or "unknown"), firmware_list (parser output).
# Read-only: uses the metadata fwupd already has (refresh happens only under --apply).
um_probe_firmware() {
  UM_CAP[firmware_available]=0
  UM_CAP[firmware_updates]="unknown"
  UM_CAP[firmware_list]=""
  um_probe_command fwupdmgr || return 0
  UM_CAP[firmware_available]=1
  local out rc=0
  out="$(um_fw_cmd get-updates --json 2>/dev/null)" || rc=$?
  case "$rc" in
    0 | 2)
      if [[ "$out" == *'"Devices"'* ]]; then
        UM_CAP[firmware_list]="$(um_fw_parse_updates <<<"$out")"
        UM_CAP[firmware_updates]="$(grep -c . <<<"${UM_CAP[firmware_list]}" || true)"
      elif [[ "$rc" -eq 2 ]]; then
        UM_CAP[firmware_updates]=0
      fi ;;
    3) UM_CAP[firmware_updates]=0 ;; # no supported devices (VMs, containers)
  esac
  return 0
}

# Sets needrestart_available, needrestart_version.
um_probe_needrestart() {
  if um_probe_command needrestart; then
    UM_CAP[needrestart_available]=1
    UM_CAP[needrestart_version]="$(needrestart -v 2>/dev/null | head -1 || true)"
  else
    UM_CAP[needrestart_available]=0
  fi
}

# Sets snap_available, snap_count, snap_has_packages.
um_probe_snap() {
  UM_CAP[snap_available]=0
  UM_CAP[snap_has_packages]=0
  if ! um_probe_command snap; then
    return 0
  fi
  UM_CAP[snap_available]=1
  # Count rows after the header. (An awk `exit 0` still runs END, so an early-exit
  # test with `END {exit 1}` always failed and snap was never detected.)
  local count
  count="$(LANG=C snap list 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ' || true)"
  if [[ "${count:-0}" -gt 0 ]]; then
    UM_CAP[snap_has_packages]=1
    UM_CAP[snap_count]="$count"
  fi
}

# Sets flatpak_available, flatpak_version, flatpak_has_remotes (system remotes only).
um_probe_flatpak() {
  UM_CAP[flatpak_available]=0
  UM_CAP[flatpak_has_remotes]=0
  if ! um_probe_command flatpak; then
    return 0
  fi
  UM_CAP[flatpak_available]=1
  UM_CAP[flatpak_version]="$(flatpak --version 2>/dev/null | head -1 || true)"
  # System installation only: --apply runs as root and updates the system installation,
  # so a dry run as the user must not plan an update for per-user remotes.
  if flatpak remotes --system 2>/dev/null | grep -q .; then
    UM_CAP[flatpak_has_remotes]=1
  fi
}

# Sets unattended_upgrades_active, apt_daily_active (shown in the manifest).
um_probe_coexistence() {
  if um_probe_command systemctl; then
    UM_CAP[unattended_upgrades_active]="$(um_probe_unit_state unattended-upgrades)"
    UM_CAP[apt_daily_active]="$(um_probe_unit_state apt-daily.timer)"
  fi
}

# `systemctl is-active` prints a state (e.g. "inactive") AND exits non-zero for
# anything not active, so `|| echo unknown` would yield two lines. Take the first line.
um_probe_unit_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  state="${state%%$'\n'*}"
  echo "${state:-unknown}"
}

# WSL_DISTRO_NAME is stripped by sudo, so also check the interop binfmt entry and the
# WSL2 kernel release suffix. Only affects messages; the TPM rule keys on /dev/tpm*.
um_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && return 0
  grep -q 'WSL' /proc/sys/kernel/osrelease 2>/dev/null
}

um_have_tpm_device() {
  compgen -G '/dev/tpm*' >/dev/null
}

# Path of the reboot flag written by package scripts (a function so tests can move it).
um_reboot_required_file() {
  echo /var/run/reboot-required
}

# Echo a reason and return 0 when a unit's failure is expected in this environment
# (its precondition is absent), so it should not trip the gate. Keyed on the missing
# precondition, not on "is WSL", so the same rule covers VMs without a vTPM.
um_unit_expected_failure() {
  case "$1" in
    tpm-udev.path|tpm-udev.service)
      um_have_tpm_device && return 1
      if um_is_wsl; then echo "WSL has no TPM device"; else echo "no TPM device (/dev/tpm*)"; fi
      return 0 ;;
  esac
  return 1
}

# Split `systemctl --failed` into UM_FAILED_UNEXPECTED (lines) and
# UM_FAILED_EXPECTED ("unit — reason" lines).
um_classify_failed_units() {
  UM_FAILED_UNEXPECTED=()
  UM_FAILED_EXPECTED=()
  local line unit reason
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    unit="$(awk '{print $1}' <<<"${line#*● }")"
    if reason="$(um_unit_expected_failure "$unit")"; then
      UM_FAILED_EXPECTED+=("${unit} — ${reason}")
    else
      UM_FAILED_UNEXPECTED+=("$line")
    fi
  done < <(systemctl --failed --no-legend --no-pager --plain 2>/dev/null || true)
}

# Processes still running code from a file that an upgrade replaced: the old file is
# deleted but still mapped. Root sees every process; a normal user only their own.
um_outdated_process_count() {
  local maps n=0
  for maps in "${UM_PROC_DIR:-/proc}"/[0-9]*/maps; do
    grep -qE ' /(usr/)?(lib|lib64|libexec|bin|sbin)/.* \(deleted\)$' "$maps" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

# Sets UM_CAP[reboot_reason] when only a reboot helps: a newer kernel than the running
# one, or kernel/firmware/microcode/dbus packages in the reboot-required list (or a flag
# without a package list). Library updates such as libc6 also set that flag, but
# restarting the processes that use them is enough: those set UM_CAP[restart_reason],
# and only while some process still uses the old files.
um_probe_restart_needs() {
  UM_CAP[reboot_reason]=""
  UM_CAP[restart_reason]=""
  local flag running flavor newest pkgs="" hw n btime
  flag="$(um_reboot_required_file)"
  running="$(uname -r)"
  flavor="${running##*-}"
  # Unknown boot time (no /proc/stat): every installed kernel counts.
  btime="$(awk '$1 == "btime" {print $2}' "${UM_PROC_DIR:-/proc}/stat" 2>/dev/null)" || btime=""
  # Only kernels installed since this boot count: a newer one installed before it means
  # an older kernel was booted on purpose. ctime, not mtime: dpkg sets mtime to build time.
  newest="$( { echo "$running"
               for f in "${UM_BOOT_DIR:-/boot}"/vmlinuz-*-"$flavor"; do
                 [[ -e "$f" ]] || continue
                 [[ -n "$btime" && "$(stat -c %Z -- "$f")" -lt "$btime" ]] && continue
                 echo "${f##*/vmlinuz-}"
               done; } | sort -V | tail -n1)"
  if [[ "$newest" != "$running" ]]; then
    UM_CAP[reboot_reason]="kernel ${newest} installed, running ${running}"
    return 0
  fi
  [[ -f "$flag" ]] || return 0
  [[ -f "${flag}.pkgs" ]] && pkgs="$(awk 'NF && !seen[$0]++' "${flag}.pkgs" | paste -sd ' ')"
  # dbus: the system message bus cannot be restarted on a running system.
  hw="$(tr ' ' '\n' <<<"$pkgs" | grep -E '^linux-|microcode|^dbus(-daemon|-broker)?$' | paste -sd ' ')"
  if [[ -z "$pkgs" ]]; then
    UM_CAP[reboot_reason]="requested by a package update"
  elif [[ -n "$hw" ]]; then
    UM_CAP[reboot_reason]="${hw// /, }"
  else
    n="$(um_outdated_process_count)"
    if [[ "$n" -eq 1 ]]; then
      UM_CAP[restart_reason]="1 process still uses replaced libraries after the ${pkgs// /, } update"
    elif [[ "$n" -gt 1 ]]; then
      UM_CAP[restart_reason]="${n} processes still use replaced libraries after the ${pkgs// /, } update"
    fi
  fi
}

# Sets reboot_required_preflight, failed_units_preflight, failed_units_expected_preflight.
um_probe_health_preflight() {
  um_probe_restart_needs
  UM_CAP[reboot_required_preflight]=0
  if [[ -n "${UM_CAP[reboot_reason]}" ]]; then UM_CAP[reboot_required_preflight]=1; fi
  if um_probe_command systemctl; then
    um_classify_failed_units
    UM_CAP[failed_units_preflight]="${#UM_FAILED_UNEXPECTED[@]}"
    UM_CAP[failed_units_expected_preflight]="${#UM_FAILED_EXPECTED[@]}"
  else
    UM_CAP[failed_units_preflight]=0
    UM_CAP[failed_units_expected_preflight]=0
  fi
}

# Sets topgrade_available, topgrade_version (looked up as the invoking user).
um_probe_topgrade() {
  UM_CAP[topgrade_available]=0
  # Under --apply we are root with a fixed PATH, but topgrade runs as the invoking user,
  # often from ~/.cargo/bin. Probe it the way the phase will run it.
  if [[ "${UM_WITH_TOPGRADE:-0}" -eq 1 && "${EUID:-$(id -u)}" -eq 0 \
        && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if sudo -u "$SUDO_USER" -i sh -c 'command -v topgrade' >/dev/null 2>&1; then
      UM_CAP[topgrade_available]=1
      UM_CAP[topgrade_version]="$(sudo -u "$SUDO_USER" -i topgrade --version 2>/dev/null | head -1 || true)"
    fi
    return 0
  fi
  if um_probe_command topgrade; then
    UM_CAP[topgrade_available]=1
    UM_CAP[topgrade_version]="$(topgrade --version 2>/dev/null | head -1 || true)"
  fi
}

# Sets eol_warning on Ubuntu releases past standard support (18.04, 20.04).
um_probe_eol_warning() {
  local major
  major="$(um_parse_version_id)"
  UM_CAP[eol_warning]=""
  # Only Ubuntu's numbering is known here; derivatives reuse VERSION_ID differently.
  if [[ "${UM_CAP[os_id]:-}" == "ubuntu" ]] && [[ "$major" -eq 18 || "$major" -eq 20 ]]; then
    UM_CAP[eol_warning]="Ubuntu ${UM_CAP[os_version_id]} is past standard support; best-effort only"
  fi
}

# Run every probe; fills UM_CAP for the manifest and the phases.
um_run_probes() {
  um_load_os_release
  um_probe_apt || true
  um_probe_needrestart
  um_probe_snap
  um_probe_flatpak
  um_probe_topgrade
  um_probe_firmware
  um_probe_docker
  um_probe_coexistence
  um_probe_health_preflight
  um_probe_eol_warning

  UM_CAP[apply_requested]="${UM_APPLY}"
  UM_CAP[manifest_timestamp]="$(date -Is 2>/dev/null || date)"
}
