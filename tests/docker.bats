#!/usr/bin/env bats
# Docker cleanup (lib/ubuntu-maintain/docker.sh). No test reaches a real Docker daemon:
# the binary is a fake, and the socket path is a temp file.

bats_require_minimum_version 1.5.0

# shellcheck source=test_helper.bash
source "${BATS_TEST_DIRNAME}/test_helper.bash"

setup() {
  um_test_setup
  # shellcheck source=../lib/ubuntu-maintain/docker.sh
  source "${UM_LIB}/docker.sh"
}

@test "docker size: decimal units, fractions, leading zeros, df suffix" {
  run um_docker_size_bytes 0B;            [ "$output" = 0 ]
  run um_docker_size_bytes 846kB;         [ "$output" = 846000 ]
  run um_docker_size_bytes 120.2MB;       [ "$output" = 120200000 ]
  run um_docker_size_bytes 1.05GB;        [ "$output" = 1050000000 ]
  run um_docker_size_bytes 08MB;          [ "$output" = 8000000 ]
  run um_docker_size_bytes '649MB (60%)'; [ "$output" = 649000000 ]
}

@test "docker size: anything else is unknown" {
  local s
  for s in N/A '' 12 1.2.3MB 5MiB -1MB 1e3MB '$(id)MB' 9999999999999MB 999999999999TB; do
    run um_docker_size_bytes "$s"; [ "$status" -eq 1 ]; done
}

@test "docker size: display" {
  [ "$(um_docker_fmt_size 120200000)" = "120 MB" ]
  [ "$(um_docker_fmt_size 1250000000)" = "1.2 GB" ]
  [ "$(um_docker_fmt_size 2072000000)" = "2.1 GB" ]
  [ "$(um_docker_fmt_size 12500000000)" = "12 GB" ]
  [ "$(um_docker_fmt_size 846000)" = "846 kB" ]
  [ "$(um_docker_fmt_size 999600000)" = "1.0 GB" ]
  [ "$(um_docker_fmt_size 0)" = "0 B" ]
}

@test "docker text: every non-printable byte becomes ?, long names keep their end" {
  [ "$(um_docker_safe_text $'a\e[2Jb\xc2\x9bc' 40)" = "a?[2Jb??c" ]
  [ "$(um_docker_safe_text "$(printf 'x%.0s' {1..80})6e239a" 30)" = "xxxxxxxxxxxxxxxxxxxxx...6e239a" ]
}

@test "docker json string: decoded, escapes neutralized, non-strings rejected" {
  [ "$(um_docker_json_str '"shop\"web"')" = 'shop"web' ]
  [ "$(um_docker_json_str '"a\u001bb\nc"')" = 'a?b?c' ]
  [ "$(um_docker_json_str '"a&b"')" = 'a&b' ]
  run um_docker_json_str null; [ "$status" -eq 1 ]
  run um_docker_json_str '"a"b"'; [ "$status" -eq 1 ]
}

@test "docker wrapper: isolated environment, pinned socket, stdin closed, dir removed" {
  printf '#!/bin/bash\nenv > %q/env; echo "$DOCKER_CONFIG" > %q/cfgpath; ls -A "$DOCKER_CONFIG" > %q/cfg; cat > %q/stdin\n' \
    "$TEST_TMP" "$TEST_TMP" "$TEST_TMP" "$TEST_TMP" > "$TEST_TMP/docker"; chmod 755 "$TEST_TMP/docker"
  export UM_DOCKER_BIN="$TEST_TMP/docker" DOCKER_CONTEXT=other HOME=/home/x BUILDX_BUILDER=b
  unset UM_DOCKER_SOCK
  um_docker_cmd info
  grep -qx 'DOCKER_HOST=unix:///run/docker.sock' "$TEST_TMP/env"
  grep -qx 'LC_ALL=C' "$TEST_TMP/env"
  run ! grep -E '^(DOCKER_CONTEXT|HOME|BUILDX_BUILDER|TEST_TMP)=' "$TEST_TMP/env"
  [ ! -s "$TEST_TMP/cfg" ] && [ ! -s "$TEST_TMP/stdin" ]
  [ ! -e "$(cat "$TEST_TMP/cfgpath")" ]
}

@test "docker wrapper: docker's error text is shown sanitized" {
  printf '#!/bin/bash\nprintf "bad\\033]0;x\\007 thing\\n" >&2; exit 1\n' > "$TEST_TMP/docker"
  chmod 755 "$TEST_TMP/docker"; export UM_DOCKER_BIN="$TEST_TMP/docker"
  run --separate-stderr um_docker_cmd ps
  [ "$status" -eq 1 ]; [ "$stderr" = "bad?]0;x? thing" ]
}

@test "docker binary: 755 accepted, group- or other-writable refused" {
  printf '#!/bin/bash\n' > "$TEST_TMP/docker"; export UM_DOCKER_BIN="$TEST_TMP/docker"
  chmod 755 "$TEST_TMP/docker"; run um_docker_bin; [ "$status" -eq 0 ]
  chmod 775 "$TEST_TMP/docker"; run um_docker_bin; [ "$status" -eq 2 ]
  chmod 757 "$TEST_TMP/docker"; run um_docker_bin; [ "$status" -eq 2 ]
  UM_DOCKER_BIN=/nonexistent run um_docker_bin; [ "$status" -eq 1 ]
}

@test "docker hooks: UM_DOCKER_BIN and UM_DOCKER_SOCK are ignored as root" {
  printf '#!/bin/bash\n' > "$TEST_TMP/docker"; chmod 755 "$TEST_TMP/docker"
  export UM_DOCKER_BIN="$TEST_TMP/docker" UM_DOCKER_SOCK="$TEST_TMP/sock"
  [ "$(um_docker_sock)" = "$TEST_TMP/sock" ] && [ "$(um_docker_bin)" = "$TEST_TMP/docker" ]
  um_docker_is_root() { return 0; }
  [ "$(um_docker_sock)" = /run/docker.sock ]
  [ "$(um_docker_bin || true)" != "$TEST_TMP/docker" ]
}
