#!/usr/bin/env bash

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

um_probe_apt_config_timeout() {
  local raw
  raw="$(apt-config dump 2>/dev/null | awk -F': ' '/^DPkg::Lock::Timeout / {gsub(/ /,"",$2); print $2; exit}')"
  if [[ -z "$raw" ]]; then
    raw="$(apt-config shell DPkg::Lock::Timeout 2>/dev/null | sed -n "s/^DPkg::Lock::Timeout=\"\\(.*\\)\";$/\\1/p")"
  fi
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

  local major
  major="$(um_parse_version_id)"
  if [[ "$major" -ge 22 ]]; then
    UM_CAP[apt_upgrade_standard_cmd]="apt-get upgrade -y"
    UM_CAP[apt_upgrade_conservative_cmd]="apt-get upgrade -y"
  elif [[ "$major" -ge 18 ]]; then
    UM_CAP[apt_upgrade_standard_cmd]="apt-get upgrade --with-new-pkgs -y"
    UM_CAP[apt_upgrade_conservative_cmd]="apt-get upgrade -y"
  else
    UM_CAP[apt_upgrade_standard_cmd]="apt-get upgrade -y"
    UM_CAP[apt_upgrade_conservative_cmd]="apt-get upgrade -y"
  fi
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
  if LANG=C snap list 2>/dev/null | awk 'NR>1 {exit 0} END {exit 1}'; then
    UM_CAP[snap_has_packages]=1
    UM_CAP[snap_count]="$(LANG=C snap list 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' ')"
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
    UM_CAP[unattended_upgrades_active]="$(systemctl is-active unattended-upgrades 2>/dev/null || echo unknown)"
    UM_CAP[apt_daily_active]="$(systemctl is-active apt-daily.timer 2>/dev/null || echo unknown)"
  fi
}

um_probe_health_preflight() {
  UM_CAP[reboot_required_preflight]=0
  if [[ -f /var/run/reboot-required ]]; then UM_CAP[reboot_required_preflight]=1; fi
  if um_probe_command systemctl; then
    UM_CAP[failed_units_preflight]="$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l | tr -d ' ')"
  else
    UM_CAP[failed_units_preflight]=0
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
