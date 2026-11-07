#!/usr/bin/env bash
# probe.sh — Detect OS, package managers, apt locks, and preflight health.
# Provides: um_run_probes, um_probe_*  (writes results to UM_CAP[]),
#           um_is_wsl, um_reboot_required_file, um_classify_failed_units, um_unit_expected_failure
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
  if [[ -n "$raw" && "$raw" =~ ^-?[0-9]+$ ]]; then
    UM_CAP[apt_lock_timeout_supported]=1
    UM_CAP[apt_lock_timeout]="$raw"
  else
    UM_CAP[apt_lock_timeout_supported]=0
    UM_CAP[apt_lock_timeout]=120
  fi
}

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

um_probe_needrestart() {
  if um_probe_command needrestart; then
    UM_CAP[needrestart_available]=1
    UM_CAP[needrestart_version]="$(needrestart -v 2>/dev/null | head -1 || true)"
  else
    UM_CAP[needrestart_available]=0
  fi
}

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

um_probe_flatpak() {
  UM_CAP[flatpak_available]=0
  UM_CAP[flatpak_has_remotes]=0
  if ! um_probe_command flatpak; then
    return 0
  fi
  UM_CAP[flatpak_available]=1
  UM_CAP[flatpak_version]="$(flatpak --version 2>/dev/null | head -1 || true)"
  if flatpak remotes 2>/dev/null | grep -q .; then
    UM_CAP[flatpak_has_remotes]=1
  fi
}

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

um_probe_health_preflight() {
  UM_CAP[reboot_required_preflight]=0
  if [[ -f "$(um_reboot_required_file)" ]]; then UM_CAP[reboot_required_preflight]=1; fi
  if um_probe_command systemctl; then
    um_classify_failed_units
    UM_CAP[failed_units_preflight]="${#UM_FAILED_UNEXPECTED[@]}"
    UM_CAP[failed_units_expected_preflight]="${#UM_FAILED_EXPECTED[@]}"
  else
    UM_CAP[failed_units_preflight]=0
    UM_CAP[failed_units_expected_preflight]=0
  fi
}

um_probe_topgrade() {
  UM_CAP[topgrade_available]=0
  if um_probe_command topgrade; then
    UM_CAP[topgrade_available]=1
    UM_CAP[topgrade_version]="$(topgrade --version 2>/dev/null | head -1 || true)"
  fi
}

um_probe_eol_warning() {
  local major
  major="$(um_parse_version_id)"
  if [[ "$major" -eq 18 ]]; then
    UM_CAP[eol_warning]="Ubuntu 18.04 is past standard support; best-effort only"
  else
    UM_CAP[eol_warning]=""
  fi
}

um_run_probes() {
  um_load_os_release
  um_probe_apt || true
  um_probe_needrestart
  um_probe_snap
  um_probe_flatpak
  um_probe_topgrade
  um_probe_coexistence
  um_probe_health_preflight
  um_probe_eol_warning

  UM_CAP[apply_requested]="${UM_APPLY}"
  UM_CAP[manifest_timestamp]="$(date -Is 2>/dev/null || date)"
}
