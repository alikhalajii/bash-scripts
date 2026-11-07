#!/usr/bin/env bats

setup() {
  export ROOT="${BATS_TEST_DIRNAME}/.."
  export UM_LIB="${ROOT}/lib/ubuntu-maintain"
  # shellcheck source=../lib/ubuntu-maintain/common.sh
  source "${UM_LIB}/common.sh"
  source "${UM_LIB}/probe.sh"
  source "${UM_LIB}/manifest.sh"
  export UM_APPLY=0
  export UM_AGGRESSIVE=0
  export UM_MODE="daily"
  # Keep the real /tmp clean: logs and temp dirs from tests go here.
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP TMPDIR="$TEST_TMP"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Run the CLI with a throwaway log instead of the user's real /tmp/ubuntu-maintain.<uid>.log.
um_cli() {
  run "${ROOT}/bin/ubuntu-maintain" --log-file "${TEST_TMP}/um.log" "$@"
}

@test "help exits zero" {
  um_cli --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ubuntu-maintain"* ]]
}

@test "dry-run prints manifest without root" {
  um_cli --manifest-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"Capability manifest"* ]]
  [[ "$output" == *"stability gate (apply only)"* ]]
  [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"planned phases"* ]]
}

@test "manifest warns when preflight failed units on apply" {
  export UM_APPLY=1
  export UM_IGNORE_STABILITY=0
  # UM_CAP is declared as an assoc array in common.sh (sourced above); shellcheck cannot
  # follow the dynamic source path so it flags keys as unset vars (SC2154).
  # shellcheck disable=SC2154
  { UM_CAP[failed_units_preflight]=2
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
    UM_CAP[reboot_required_preflight]=0; }
  run um_manifest_print
  [ "$status" -eq 0 ]
  [[ "$output" == *"stability gate will likely exit 2"* ]]
}

@test "default dry-run exits 0 without stability failure" {
  um_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stability gate skipped in dry-run"* ]]
}

@test "apt tier is standard by default" {
  um_load_os_release
  export UM_AGGRESSIVE=0
  export UM_MODE="daily"
  um_probe_apt || true
  [ "${UM_CAP[apt_tier_selected]}" = "standard" ]
}

@test "apt tier is aggressive when flagged" {
  um_load_os_release
  export UM_AGGRESSIVE=1
  um_probe_apt || true
  [ "${UM_CAP[apt_tier_selected]}" = "aggressive" ]
}

@test "removal counter parses apt simulate lines" {
  local sim=$'Inst foo [1.0] (1.1)\nRemv bar [2.0]'
  run um_manifest_count_apt_removals "$sim"
  [ "$output" -eq 1 ]
}

@test "unknown flag fails" {
  um_cli --not-a-flag
  [ "$status" -eq 64 ]
}

@test "with-topgrade appears in manifest when requested" {
  um_cli --manifest-only --with-topgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"topgrade:"* ]]
  [[ "$output" == *"requested: 1"* ]]
}

@test "stability gate returns 0 with ignore-stability and reboot-required" {
  local tmpf
  tmpf="$(mktemp)"
  run bash -c "
    source '${UM_LIB}/common.sh'
    source '${UM_LIB}/probe.sh'
    source '${UM_LIB}/stability.sh'
    export UM_IGNORE_STABILITY=1
    UM_CAP[needrestart_available]=0
    dpkg() { return 1; }
    systemctl() { return 0; }
    um_reboot_required_file() { echo '${tmpf}'; }
    um_stability_gate
  "
  rm -f "$tmpf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REBOOT REQUIRED"* ]]
}

@test "stability gate reboot-required exits 2 without ignore-stability" {
  local tmpf
  tmpf="$(mktemp)"
  printf 'linux-image-6.8\nlibc6\n' > "${tmpf}.pkgs"
  run bash -c "
    source '${UM_LIB}/common.sh'
    source '${UM_LIB}/probe.sh'
    source '${UM_LIB}/stability.sh'
    export UM_IGNORE_STABILITY=0
    UM_CAP[needrestart_available]=0
    dpkg() { return 0; }
    systemctl() { return 0; }
    um_reboot_required_file() { echo '${tmpf}'; }
    um_stability_gate
  "
  rm -f "$tmpf" "${tmpf}.pkgs"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REBOOT REQUIRED (packages: linux-image-6.8 libc6)"* ]]
}

@test "manifest warns about exit 2 when only a reboot is pending" {
  export UM_APPLY=1 UM_IGNORE_STABILITY=0
  # shellcheck disable=SC2154
  { UM_CAP[failed_units_preflight]=0; UM_CAP[reboot_required_preflight]=1; UM_CAP[manifest_timestamp]="t"; }
  run um_manifest_print
  [[ "$output" == *"stability gate will likely exit 2"* ]]
}

@test "snap monthly cleanup does not fail when snap list exits nonzero" {
  source "${UM_LIB}/snap.sh"
  export UM_APPLY=1
  export UM_MODE="monthly"
  # shellcheck disable=SC2154
  UM_CAP[snap_has_packages]=1
  # mock um_sudo to run commands directly (no real sudo needed)
  um_sudo() { "$@"; }
  export -f um_sudo
  # put a fake snap script on PATH: succeeds for refresh, fails for list
  local tmpbin
  tmpbin="$(mktemp -d)"
  printf '#!/bin/bash\n[[ "$1" == "refresh" ]] && exit 0\nexit 1\n' > "${tmpbin}/snap"
  chmod +x "${tmpbin}/snap"
  export PATH="${tmpbin}:${PATH}"
  run um_snap_phase
  rm -rf "$tmpbin"
  [ "$status" -eq 0 ]
}

@test "topgrade phase skips and exits UM_EXIT_TOPGRADE when SUDO_USER unset" {
  source "${UM_LIB}/topgrade.sh"
  export UM_APPLY=1
  export UM_WITH_TOPGRADE=1
  unset SUDO_USER
  # shellcheck disable=SC2154
  UM_CAP[topgrade_available]=1
  UM_CAP[apt_available]=0
  topgrade() { return 0; }
  export -f topgrade
  run um_topgrade_phase
  [ "$status" -eq "${UM_EXIT_TOPGRADE}" ]
}

@test "log symlink guard exits 64" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local real_log="${tmpdir}/real.log"
  local sym_log="${tmpdir}/symlink.log"
  touch "$real_log"
  ln -s "$real_log" "$sym_log"
  run bash -c "
    source '${UM_LIB}/common.sh'
    UM_LOG_FILE='${sym_log}'
    UM_LOG_FILE_EXPLICIT=1
    um_setup_logging
  "
  [ "$status" -eq 64 ]
  [[ "$output" == *"symlink"* ]]
  rm -rf "$tmpdir"
}

@test "summary module prints Update Summary block on apply" {
  source "${UM_LIB}/summary.sh"
  # shellcheck disable=SC2154
  { UM_CAP[apt_available]=0
    UM_CAP[snap_has_packages]=0
    UM_CAP[flatpak_has_remotes]=0
    UM_CAP[summary_stability]="OK"; }
  # shellcheck disable=SC2034  # read by um_summary_snapshot/print
  UM_SUMMARY_DIR="$(mktemp -d)"
  um_summary_snapshot pre
  um_summary_snapshot post
  run um_summary_print
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update Summary"* ]]
  [[ "$output" == *"Stability: OK"* ]]
}

@test "tpm-udev failure is expected when no TPM device exists" {
  um_have_tpm_device() { return 1; }
  um_is_wsl() { return 0; }
  run um_unit_expected_failure tpm-udev.service
  [ "$status" -eq 0 ]
  [[ "$output" == *"WSL"* ]]
}

@test "tpm-udev failure is NOT expected when a TPM device exists" {
  um_have_tpm_device() { return 0; }
  run um_unit_expected_failure tpm-udev.service
  [ "$status" -eq 1 ]
}

@test "stability gate passes when only expected units failed" {
  run bash -c "
    source '${UM_LIB}/common.sh'
    source '${UM_LIB}/probe.sh'
    source '${UM_LIB}/stability.sh'
    export UM_IGNORE_STABILITY=0
    UM_CAP[needrestart_available]=0
    dpkg() { return 0; }
    systemctl() { printf 'tpm-udev.path loaded failed failed TPM\ntpm-udev.service loaded failed failed TPM\n'; }
    um_have_tpm_device() { return 1; }
    um_is_wsl() { return 0; }
    um_reboot_required_file() { echo /nonexistent; }
    um_stability_gate
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unexpected failed systemd units."* ]]
  [[ "$output" == *"can be ignored"* ]]
  [[ "$output" == *"Stability gate: OK"* ]]
}

@test "stability gate still fails on an unexpected failed unit" {
  run bash -c "
    source '${UM_LIB}/common.sh'
    source '${UM_LIB}/probe.sh'
    source '${UM_LIB}/stability.sh'
    export UM_IGNORE_STABILITY=0
    UM_CAP[needrestart_available]=0
    dpkg() { return 0; }
    systemctl() { printf 'tpm-udev.service loaded failed failed TPM\nnginx.service loaded failed failed web\n'; }
    um_have_tpm_device() { return 1; }
    um_reboot_required_file() { echo /nonexistent; }
    um_stability_gate
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"nginx.service"* ]]
}

@test "preflight counts only unexpected failed units" {
  systemctl() { printf 'tpm-udev.path loaded failed failed TPM\nfoo.service loaded failed failed x\n'; }
  um_probe_command() { return 0; }
  um_have_tpm_device() { return 1; }
  um_probe_health_preflight
  # shellcheck disable=SC2154
  [ "${UM_CAP[failed_units_preflight]}" -eq 1 ]
  [ "${UM_CAP[failed_units_expected_preflight]}" -eq 1 ]
}

@test "lock-timeout probe detects scoped key (apt 2.x: Binary::apt::DPkg::Lock::Timeout)" {
  apt-config() { printf 'APT::Architecture "amd64";\nBinary::apt::DPkg::Lock::Timeout "120";\n'; }
  um_probe_apt_config_timeout
  # shellcheck disable=SC2154
  [ "${UM_CAP[apt_lock_timeout_supported]}" -eq 1 ]
  [ "${UM_CAP[apt_lock_timeout]}" -eq 120 ]
}

@test "lock-timeout probe prefers operator-set unscoped value" {
  apt-config() { printf 'binary::apt::DPkg::Lock::Timeout "120";\nDPkg::Lock::Timeout "600";\n'; }
  um_probe_apt_config_timeout
  [ "${UM_CAP[apt_lock_timeout]}" -eq 600 ]
}

@test "lock-timeout probe falls back to fuser poll when key absent (apt 1.6 / 18.04)" {
  apt-config() { printf 'APT::Architecture "amd64";\n'; }
  um_probe_apt_config_timeout
  [ "${UM_CAP[apt_lock_timeout_supported]}" -eq 0 ]
}

@test "apt lock opts are two separate argv words" {
  source "${UM_LIB}/apt_module.sh"
  UM_CAP[apt_lock_timeout_supported]=1
  UM_CAP[apt_lock_timeout]=77
  local -a opts
  mapfile -t opts < <(um_apt_lock_opts)
  [ "${#opts[@]}" -eq 2 ]
  [ "${opts[0]}" = "-o" ]
  [ "${opts[1]}" = "DPkg::Lock::Timeout=77" ]
}

@test "entry point works when invoked through a symlink" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  ln -s "${ROOT}/bin/ubuntu-maintain" "${tmpdir}/ubuntu-maintain"
  run "${tmpdir}/ubuntu-maintain" --help
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ubuntu-maintain"* ]]
}

@test "unit state probe yields one value for inactive units" {
  systemctl() { echo inactive; return 3; }
  run um_probe_unit_state apt-daily.timer
  [ "$output" = "inactive" ]
}

@test "unit state probe yields unknown when systemctl prints nothing" {
  systemctl() { return 1; }
  run um_probe_unit_state apt-daily.timer
  [ "$output" = "unknown" ]
}

@test "topgrade disable args use valid step names (no 'apt' step)" {
  source "${UM_LIB}/topgrade.sh"
  run um_topgrade_disable_args
  [[ "$output" != *"apt"* ]]
  [[ "$output" == *"system"* ]]
}

@test "topgrade failure is reported even with --continue-on-pm-failure" {
  source "${UM_LIB}/topgrade.sh"
  export UM_APPLY=1 UM_WITH_TOPGRADE=1 UM_CONTINUE_ON_FAILURE=1 SUDO_USER=nobody
  # shellcheck disable=SC2154
  UM_CAP[topgrade_available]=1
  sudo() { return 1; }
  run um_topgrade_phase
  [ "$status" -eq "${UM_EXIT_TOPGRADE}" ]
}

@test "fuser lock poll returns 0 when locks are free even with zero max wait" {
  source "${UM_LIB}/apt_module.sh"
  UM_CAP[lock_wait_mode]="fuser_poll"
  UM_CAP[apt_lock_timeout]=0
  um_probe_command() { return 0; }
  um_sudo() { return 1; }   # fuser/lsof: no holder
  sleep() { :; }
  run um_apt_wait_locks
  [ "$status" -eq 0 ]
}

@test "fuser lock poll times out with exit 10 while a lock stays held" {
  source "${UM_LIB}/apt_module.sh"
  UM_CAP[lock_wait_mode]="fuser_poll"
  UM_CAP[apt_lock_timeout]=6
  um_probe_command() { return 0; }
  um_sudo() { return 0; }   # always held
  sleep() { :; }
  run um_apt_wait_locks
  [ "$status" -eq 10 ]
  [[ "$output" == *"timed out"* ]]
}

@test "apt phase aborts when the post-update simulate fails" {
  source "${UM_LIB}/apt_module.sh"
  export UM_APPLY=1
  # shellcheck disable=SC2154
  { UM_CAP[apt_available]=1; UM_CAP[apt_simulated_removals]=0; }
  um_apt_wait_locks() { return 0; }
  um_apt_run() { [[ "$1" == "update" ]] && return 0; echo "UPGRADE-RAN"; return 0; }
  um_apt_simulate_upgrade() { return 100; }
  run um_apt_phase
  [ "$status" -eq 10 ]
  [[ "$output" != *"UPGRADE-RAN"* ]]
}

@test "apt upgrade keeps local conffiles non-interactively" {
  source "${UM_LIB}/apt_module.sh"
  um_apt_run() { printf '%s\n' "$@"; }
  run um_apt_apply_upgrade
  [[ "$output" == *"Dpkg::Options::=--force-confold"* ]]
  [[ "$output" == *"Dpkg::Options::=--force-confdef"* ]]
}

@test "apt failure stops the run even with --continue-on-pm-failure" {
  run bash -c "
    source '${UM_LIB}/common.sh'
    um_source_libs
    UM_APPLY=1 UM_CONTINUE_ON_FAILURE=1
    um_run_probes() { UM_CAP[apt_available]=0; }
    um_manifest_print() { :; }
    um_need_root() { :; }
    um_summary_init() { :; }
    um_summary_snapshot() { :; }
    um_stability_gate() { return 0; }
    um_apt_phase() { return 10; }
    um_snap_phase() { echo SNAP-RAN; }
    um_run_dag
  "
  [ "$status" -eq 10 ]
  [[ "$output" != *"SNAP-RAN"* ]]
}

@test "default log path that is a symlink falls back to a private temp file" {
  local fake_uid=987654 target
  target="$(mktemp)"
  ln -sfn "$target" "/tmp/ubuntu-maintain.${fake_uid}.log"
  run bash -c "
    source '${UM_LIB}/common.sh'
    id() { echo ${fake_uid}; }
    um_setup_logging
    echo LOG=\$UM_LOG_FILE
  "
  rm -f "/tmp/ubuntu-maintain.${fake_uid}.log" "$target" /tmp/ubuntu-maintain.${fake_uid}.??????
  [ "$status" -eq 0 ]
  [[ "$output" == *"logging to /tmp/ubuntu-maintain.${fake_uid}."* ]]
  [[ "$output" != *"LOG=/tmp/ubuntu-maintain.${fake_uid}.log"* ]]
}

@test "default log path with extra hardlinks falls back to a private temp file" {
  local fake_uid=987656 log
  log="/tmp/ubuntu-maintain.${fake_uid}.log"
  rm -f "$log" "${log}.link"; : > "$log"; ln "$log" "${log}.link"
  run bash -c "
    source '${UM_LIB}/common.sh'
    id() { echo ${fake_uid}; }
    um_setup_logging
    echo LOG=\$UM_LOG_FILE
  "
  rm -f "$log" "${log}.link" /tmp/ubuntu-maintain.${fake_uid}.??????
  [ "$status" -eq 0 ]
  [[ "$output" != *"LOG=${log}"* ]]
}

@test "missing default log is created exclusively with mode 600" {
  local fake_uid=987657 log mode
  log="/tmp/ubuntu-maintain.${fake_uid}.log"
  rm -f "$log"
  run bash -c "
    umask 022
    source '${UM_LIB}/common.sh'
    id() { echo ${fake_uid}; }
    um_setup_logging
    echo LOG=\$UM_LOG_FILE
  "
  mode="$(stat -c %a "$log")"
  rm -f "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG=${log}"* ]]
  [ "$mode" = "600" ]
}

@test "snap probe detects installed snaps" {
  snap() { printf 'Name Version Rev Tracking Publisher Notes\ncore22 1 2 latest/stable x base\n'; }
  um_probe_command() { return 0; }
  um_probe_snap
  # shellcheck disable=SC2154
  [ "${UM_CAP[snap_has_packages]}" -eq 1 ]
  [ "${UM_CAP[snap_count]}" -eq 1 ]
}

@test "snap probe reports no packages for header-only output" {
  snap() { printf 'Name Version Rev Tracking Publisher Notes\n'; }
  um_probe_command() { return 0; }
  um_probe_snap
  [ "${UM_CAP[snap_has_packages]}" -eq 0 ]
}

@test "apt simulate never invokes sudo (dry-run must not prompt)" {
  source "${UM_LIB}/apt_module.sh"
  local tmpbin
  tmpbin="$(mktemp -d)"
  # env(1) executes binaries, not shell functions, so fake both on PATH.
  printf '#!/bin/sh\necho SUDO-CALLED; exit 1\n' > "${tmpbin}/sudo"
  printf '#!/bin/sh\necho "apt-get $*"\n' > "${tmpbin}/apt-get"
  chmod +x "${tmpbin}/sudo" "${tmpbin}/apt-get"
  PATH="${tmpbin}:${PATH}" run um_apt_simulate_upgrade
  rm -rf "$tmpbin"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SUDO-CALLED"* ]]
  [[ "$output" == *"apt-get"*"-s"* ]]
}

@test "default log left world-readable by an older version is tightened to 600" {
  local fake_uid=987655 log
  log="/tmp/ubuntu-maintain.${fake_uid}.log"
  rm -f "$log"; : > "$log"; chmod 644 "$log"
  run bash -c "
    source '${UM_LIB}/common.sh'
    id() { echo ${fake_uid}; }
    um_setup_logging
  "
  local mode
  mode="$(stat -c %a "$log")"
  rm -f "$log"
  [ "$status" -eq 0 ]
  [ "$mode" = "600" ]
}

@test "summary does not count purged config-only (rc) packages as removed" {
  source "${UM_LIB}/summary.sh"
  local tmpbin state
  tmpbin="$(mktemp -d)"; state="${tmpbin}/state"
  # Fake dpkg-query: "pre" has an rc leftover, "post" has it purged.
  cat > "${tmpbin}/dpkg-query" <<'SH'
#!/bin/sh
printf 'ii  bash 5.2\n'
[ "$(cat "$UM_FAKE_STATE")" = pre ] && printf 'rc  linux-image-old 6.8\n'
exit 0
SH
  chmod +x "${tmpbin}/dpkg-query"
  export PATH="${tmpbin}:${PATH}" UM_FAKE_STATE="$state"
  # shellcheck disable=SC2154
  { UM_CAP[apt_available]=1; UM_CAP[snap_has_packages]=0; UM_CAP[flatpak_has_remotes]=0; }
  # shellcheck disable=SC2034  # read by um_summary_snapshot/print
  UM_SUMMARY_DIR="$(mktemp -d)"
  echo pre > "$state";  um_summary_snapshot pre
  echo post > "$state"; um_summary_snapshot post
  run um_summary_print
  rm -rf "$tmpbin"
  [[ "$output" == *"Removed:   0"* ]]
  [[ "$output" != *"linux-image-old"* ]]
}

@test "standard tier uses upgrade --with-new-pkgs on every release" {
  source "${UM_LIB}/apt_module.sh"
  local v
  for v in 18.04 20.04 22.04 24.04 26.04 12; do
    UM_CAP[os_version_id]="$v"
    UM_CAP[apt_tier_selected]=standard
    run um_apt_upgrade_args
    [ "$output" = "$(printf 'upgrade\n--with-new-pkgs')" ]
  done
}

@test "lock-timeout key is ignored on apt older than 1.9.11" {
  apt-config() { printf 'DPkg::Lock::Timeout "300";\n'; }
  UM_CAP[apt_version]="apt 1.6.12 (amd64)"
  um_probe_apt_config_timeout
  [ "${UM_CAP[apt_lock_timeout_supported]}" -eq 0 ]
  UM_CAP[apt_version]="apt 2.4.13 (amd64)"
  um_probe_apt_config_timeout
  [ "${UM_CAP[apt_lock_timeout_supported]}" -eq 1 ]
}

@test "lock-timeout probe reads apt 3.x Version::2.0 scoped key" {
  apt-config() { printf 'Version::2.0::Dpkg::Lock::Timeout "120";\n'; }
  um_probe_apt_config_timeout
  [ "${UM_CAP[apt_lock_timeout_supported]}" -eq 1 ]
  [ "${UM_CAP[apt_lock_timeout]}" -eq 120 ]
}

@test "topgrade requested but not found logs a warning" {
  source "${UM_LIB}/topgrade.sh"
  export UM_WITH_TOPGRADE=1
  UM_CAP[topgrade_available]=0
  run um_topgrade_phase
  [ "$status" -eq 0 ]
  [[ "$output" == *"topgrade was not found"* ]]
}

@test "entry point warns when its code is writable by other users" {
  local copy="${TEST_TMP}/repo"
  mkdir -p "$copy"
  cp -R "${ROOT}/bin" "${ROOT}/lib" "$copy/"
  chmod -R go-w "$copy"
  chmod o+w "${copy}/lib/ubuntu-maintain/dag.sh"
  run "${copy}/bin/ubuntu-maintain" --log-file "${TEST_TMP}/um.log" --manifest-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"dag.sh is writable by other users"* ]]
  chmod o-w "${copy}/lib/ubuntu-maintain/dag.sh"
  run "${copy}/bin/ubuntu-maintain" --log-file "${TEST_TMP}/um.log" --manifest-only
  [[ "$output" != *"writable by other users"* ]]
}

@test "apt-get update retries while the apt lists lock is held, then succeeds" {
  source "${UM_LIB}/apt_module.sh"
  local tmpbin="${TEST_TMP}/bin"
  mkdir -p "$tmpbin"
  # Fail twice with apt's lists-lock error, then succeed.
  cat > "${tmpbin}/apt-get" <<SH
#!/bin/sh
n=\$(cat "${TEST_TMP}/n" 2>/dev/null || echo 0); echo \$((n+1)) > "${TEST_TMP}/n"
[ "\$n" -lt 2 ] && { echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 9 (apt-get)"; exit 100; }
echo "Reading package lists... Done"
SH
  chmod +x "${tmpbin}/apt-get"
  sleep() { :; }
  PATH="${tmpbin}:${PATH}" run um_apt_update
  [ "$status" -eq 0 ]
  [ "$(cat "${TEST_TMP}/n")" -eq 3 ]
  [[ "$output" == *"retrying in 5s"* ]]
}

@test "apt-get update does not retry other errors" {
  source "${UM_LIB}/apt_module.sh"
  local tmpbin="${TEST_TMP}/bin"
  mkdir -p "$tmpbin"
  printf '#!/bin/sh\necho "E: Malformed entry 1 in list file"; exit 100\n' > "${tmpbin}/apt-get"
  chmod +x "${tmpbin}/apt-get"
  sleep() { echo SLEPT; }
  PATH="${tmpbin}:${PATH}" run um_apt_update
  [ "$status" -eq 100 ]
  [[ "$output" != *"SLEPT"* ]]
}

@test "apt-get update gives up after the lock timeout" {
  source "${UM_LIB}/apt_module.sh"
  local tmpbin="${TEST_TMP}/bin"
  mkdir -p "$tmpbin"
  printf '#!/bin/sh\necho "E: Could not get lock /var/lib/apt/lists/lock."; exit 100\n' > "${tmpbin}/apt-get"
  chmod +x "${tmpbin}/apt-get"
  sleep() { :; }
  UM_CAP[apt_lock_timeout]=10
  PATH="${tmpbin}:${PATH}" run um_apt_update
  [ "$status" -eq 100 ]
  [[ "$output" == *"timed out after 10s"* ]]
}
