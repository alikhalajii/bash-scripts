#!/usr/bin/env bash
# test_helper.bash — Shared bats setup for every tests/*.bats file.
# Provides: setup (um_test_setup), teardown, fake_bin, um_cli; TEST_TMP (per-test temp dir, also TMPDIR)
# Example:  source "${BATS_TEST_DIRNAME}/test_helper.bash"   # top of a .bats file
# Sourced by: tests/*.bats (not executed directly)

# Shared setup; a .bats file with its own setup() calls this first.
um_test_setup() {
  export ROOT="${BATS_TEST_DIRNAME}/.."
  export UM_LIB="${ROOT}/lib/ubuntu-maintain"
  # shellcheck source=../lib/ubuntu-maintain/common.sh
  source "${UM_LIB}/common.sh"
  source "${UM_LIB}/probe.sh"
  source "${UM_LIB}/manifest.sh"
  source "${UM_LIB}/summary.sh"
  export UM_APPLY=0
  export UM_AGGRESSIVE=0
  export UM_MODE="daily"
  # Keep the real /tmp clean: logs and temp dirs from tests go here.
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP TMPDIR="$TEST_TMP"
  # Restart checks read /boot and /proc: use empty fakes so results do not depend on the host.
  mkdir -p "${TEST_TMP}/boot" "${TEST_TMP}/proc"
  export UM_BOOT_DIR="${TEST_TMP}/boot" UM_PROC_DIR="${TEST_TMP}/proc" UM_DMI_DIR="${TEST_TMP}/dmi"
  # Never reach the real fwupd daemon (slow, host-dependent): firmware tests replace this.
  fake_bin fwupdmgr 'exit 1'
  # Never reach a real Docker daemon or read the host's snap: Docker tests use a fake.
  export UM_DOCKER_BIN=/nonexistent UM_DOCKER_SNAP_BIN=/nonexistent
}

setup() { um_test_setup; }

teardown() {
  rm -rf "$TEST_TMP"
}

# fake_bin NAME BODY: put an executable NAME (bash script BODY) first on PATH.
fake_bin() {
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/bin/bash\n%s\n' "$2" > "${TEST_TMP}/bin/$1"
  chmod +x "${TEST_TMP}/bin/$1"
  case ":${PATH}:" in *":${TEST_TMP}/bin:"*) ;; *) export PATH="${TEST_TMP}/bin:${PATH}" ;; esac
}

# Run the CLI with a throwaway log instead of the user's real /tmp/ubuntu-maintain.<uid>.log.
um_cli() {
  run "${ROOT}/bin/ubuntu-maintain" --log-file "${TEST_TMP}/um.log" "$@"
}
