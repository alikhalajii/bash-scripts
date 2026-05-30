#!/usr/bin/env bats

setup() {
  export ROOT="${BATS_TEST_DIRNAME}/.."
  export UM_LIB="${ROOT}/lib/ubuntu-maintain"
  # shellcheck source=../lib/ubuntu-maintain/common.sh
  source "${UM_LIB}/common.sh"
  source "${UM_LIB}/probe.sh"
  source "${UM_LIB}/manifest.sh"
  UM_APPLY=0
  UM_AGGRESSIVE=0
  UM_MODE="daily"
}

@test "help exits zero" {
  run "${ROOT}/bin/ubuntu-maintain" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu-maintain"* ]]
}

@test "dry-run prints manifest without root" {
  run "${ROOT}/bin/ubuntu-maintain" --manifest-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"Capability manifest"* ]]
  [[ "$output" == *"stability gate (apply only)"* ]]
  [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"planned phases"* ]]
}

@test "manifest warns when preflight failed units on apply" {
  UM_APPLY=1
  UM_IGNORE_STABILITY=0
  UM_CAP[failed_units_preflight]=2
  UM_CAP[manifest_timestamp]="test"
  UM_CAP[apt_available]=1
  UM_CAP[apt_tier_selected]="standard"
  UM_CAP[apt_upgrade_cmd]="apt-get upgrade -y"
  UM_CAP[lock_wait_mode]="fuser_poll"
  UM_CAP[apt_locks_held]=""
  UM_CAP[apt_held_count]=0
  UM_CAP[snap_available]=0
  UM_CAP[snap_has_packages]=0
  UM_CAP[topgrade_available]=0
  UM_CAP[flatpak_available]=0
  UM_CAP[flatpak_has_remotes]=0
  UM_CAP[unattended_upgrades_active]="unknown"
  UM_CAP[apt_daily_active]="unknown"
  UM_CAP[reboot_required_preflight]=0
  run um_manifest_print
  [ "$status" -eq 0 ]
  [[ "$output" == *"stability gate will likely exit 2"* ]]
}

@test "default dry-run exits 0 without stability failure" {
  run "${ROOT}/bin/ubuntu-maintain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stability gate skipped in dry-run"* ]]
}

@test "apt tier is standard by default" {
  um_load_os_release
  UM_AGGRESSIVE=0
  UM_MODE="daily"
  um_probe_apt || true
  [ "${UM_CAP[apt_tier_selected]}" = "standard" ]
}

@test "apt tier is aggressive when flagged" {
  um_load_os_release
  UM_AGGRESSIVE=1
  um_probe_apt || true
  [ "${UM_CAP[apt_tier_selected]}" = "aggressive" ]
}

@test "removal counter parses apt simulate lines" {
  local sim=$'Inst foo [1.0] (1.1)\nRemv bar [2.0]'
  run um_manifest_count_apt_removals "$sim"
  [ "$output" -eq 1 ]
}

@test "unknown flag fails" {
  run "${ROOT}/bin/ubuntu-maintain" --not-a-flag
  [ "$status" -eq 64 ]
}

@test "with-topgrade appears in manifest when requested" {
  run "${ROOT}/bin/ubuntu-maintain" --manifest-only --with-topgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"topgrade:"* ]]
  [[ "$output" == *"requested: 1"* ]]
}
