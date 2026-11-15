#!/usr/bin/env bats
# docker.bats — Tests for the Docker cleanup (lib/ubuntu-maintain/docker.sh). No test
# reaches a real Docker daemon: docker is tests/fixtures/docker/fake-docker, the socket a
# temp file.
# Example: bats tests/docker.bats -f 'docker pick'

bats_require_minimum_version 1.5.0

# shellcheck source=test_helper.bash
source "${BATS_TEST_DIRNAME}/test_helper.bash"

setup() {
  um_test_setup
  # shellcheck source=../lib/ubuntu-maintain/docker.sh
  source "${UM_LIB}/docker.sh"
  # Terminal questions take their answers from the test's answers=(...) list.
  um_tty_read_line() { answer_from_list "$@"; }
}

# A call the module must never make (force, volumes, system prune...) fails the test.
teardown() {
  local bad=0
  if [ -e "${TEST_TMP}/dk/forbidden" ]; then
    printf 'forbidden docker calls:\n'; cat "${TEST_TMP}/dk/forbidden"; bad=1
  fi
  rm -rf "$TEST_TMP"
  return "$bad"
}

# fake_docker [VARIANT]: a fresh copy of the fake and its state (tests/fixtures/docker),
# with a real socket file; the module is pointed at it and sees no container, no systemd.
fake_docker() {
  local d="${TEST_TMP}/dk" fx="${BATS_TEST_DIRNAME}/fixtures/docker"
  # A forbidden call from an earlier part of this test must not be wiped out.
  if [ -e "$d/forbidden" ]; then printf 'forbidden docker calls:\n'; cat "$d/forbidden"; return 1; fi
  rm -rf "$d"; mkdir -p "$d"
  cp "$fx"/state/* "$d"/
  if [ -n "${1:-}" ]; then cp "$fx/state-$1"/* "$d"/; fi
  cp "$fx/fake-docker" "$d/docker"; chmod 755 "$d/docker"
  printf '%s\n' "$UM_LIB" > "$d/libdir"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$d/docker.sock"
  : > "$d/calls"
  export UM_DOCKER_BIN="$d/docker" UM_DOCKER_SOCK="$d/docker.sock"
  fake_bin systemd-detect-virt 'exit 1'
  um_docker_in_container() { return 1; }
  um_docker_has_systemd() { return 1; }
}

# collect: read the fake's state in this shell (monthly), then forget the read calls.
collect() {
  UM_MODE=monthly
  um_docker_collect > /dev/null
  : > "${TEST_TMP}/dk/calls"
}

# item NAME: the number of the listed item whose name starts with NAME.
item() {
  local i
  for i in "${!UM_DK_NAME[@]}"; do
    [[ "${UM_DK_NAME[i]}" == "$1"* ]] && { echo "$i"; return 0; }
  done
  return 1
}

removal_calls() { grep -E $'^(container\trm|image\trm|builder\tprune)' "${TEST_TMP}/dk/calls" || true; }

assert_readonly_calls() {
  [ -z "$(removal_calls)" ]
  [ ! -e "${TEST_TMP}/dk/forbidden" ]
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
  [ ! -s "$TEST_TMP/cfg" ]
  [ ! -s "$TEST_TMP/stdin" ]
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
  [ "$(um_docker_sock)" = "$TEST_TMP/sock" ]
  [ "$(um_docker_bin)" = "$TEST_TMP/docker" ]
  um_docker_is_root() { return 0; }
  [ "$(um_docker_sock)" = /run/docker.sock ]
  [ "$(um_docker_bin || true)" != "$TEST_TMP/docker" ]
}

@test "docker pick: numbers, ranges, commas, tabs, duplicates" {
  [ "$(um_docker_parse_pick '3 1,2-4  4' 9)" = "1 2 3 4" ]
  [ "$(um_docker_parse_pick $'5\t6' 9)" = "5 6" ]
  [ "$(um_docker_parse_pick '1,,3' 9)" = "1 3" ]
  [ "$(um_docker_parse_pick '1 1' 9)" = "1" ]
  [ "$(um_docker_parse_pick '9' 9)" = "9" ]
  [ -z "$(um_docker_parse_pick '' 9)" ]
  [ -z "$(um_docker_parse_pick ' , ' 9)" ]
}

@test "docker pick: anything arithmetic could misread is not understood" {
  local t
  for t in 010 0x2 0 12 3-1 1- -1 2-10 18446744073709551617 'a[$(id)]' 1.5 y all; do
    run um_docker_parse_pick "$t" 9
    [ "$status" -eq 1 ]; [ "$output" = "$t" ]; done
  run um_docker_parse_pick '2 x 5' 9; [ "$status" -eq 1 ]; [ "$output" = x ]
}

@test "docker probe: not installed is silent and unavailable" {
  um_probe_docker
  [ "${UM_CAP[docker_available]}" = 0 ]
  [ -z "${UM_CAP[docker_note]}" ]
  [ "${UM_CAP[docker_running]}" = n/a ]
}

@test "docker probe: snap docker gets the snap note" {
  touch "$TEST_TMP/snapdocker"; UM_DOCKER_SNAP_BIN="$TEST_TMP/snapdocker" um_probe_docker
  [ "${UM_CAP[docker_note]}" = "Docker from snap is not supported here" ]
  [ "${UM_CAP[docker_available]}" = 0 ]
}

@test "docker probe: unsafe binary is skipped with a note" {
  fake_docker; chmod 775 "$UM_DOCKER_BIN"; um_probe_docker
  [[ "${UM_CAP[docker_note]}" == *"writable by other users"* ]]
  [ ! -s "$TEST_TMP/dk/calls" ]; chmod 755 "$UM_DOCKER_BIN"
}

@test "docker probe: inside a container is skipped with a note" {
  fake_docker; um_docker_in_container() { return 0; }; um_probe_docker
  [ "${UM_CAP[docker_note]}" = "inside a container; Docker cleanup skipped" ]
  [ ! -s "$TEST_TMP/dk/calls" ]
}

@test "docker probe: systemd-detect-virt or a container marker file means a container" {
  fake_bin systemd-detect-virt 'echo docker'; um_docker_in_container
  fake_bin systemd-detect-virt 'echo wsl'
  UM_DOCKER_CONTAINER_FILES="$TEST_TMP/none" run um_docker_in_container; [ "$status" -eq 1 ]
  fake_bin systemd-detect-virt 'echo none; exit 1'
  UM_DOCKER_CONTAINER_FILES="$TEST_TMP/none" run um_docker_in_container; [ "$status" -eq 1 ]
  touch "$TEST_TMP/.dockerenv"; UM_DOCKER_CONTAINER_FILES="$TEST_TMP/.dockerenv" um_docker_in_container
}

# systemctl stub: logs its arguments; only docker.service is inactive (docker.socket is
# active, so any docker call would start the daemon).
systemctl_service_inactive() {
  fake_bin systemctl "printf '%s\\n' \"\$*\" >> '${TEST_TMP}/systemctl.calls'
[ \"\$*\" = 'is-active --quiet docker.service' ] && exit 3
exit 0"
}

@test "docker probe: inactive service with an active socket never calls docker" {
  fake_docker; um_docker_has_systemd() { return 0; }; systemctl_service_inactive
  um_probe_docker
  [ "${UM_CAP[docker_running]}" = 0 ]
  [ ! -s "$TEST_TMP/dk/calls" ]
  [ "$(cat "$TEST_TMP/systemctl.calls")" = "is-active --quiet docker.service" ]
}

@test "docker probe: active service is read" {
  fake_docker; um_docker_has_systemd() { return 0; }; fake_bin systemctl 'exit 0'
  um_probe_docker
  [ "${UM_CAP[docker_running]}" = 1 ]
}

@test "docker probe: no socket means not running, without calling docker" {
  fake_docker; rm "$TEST_TMP/dk/docker.sock"; um_probe_docker
  [ "${UM_CAP[docker_running]}" = 0 ]
  [ ! -s "$TEST_TMP/dk/calls" ]
}

@test "docker probe: unreadable daemon as non-root suggests --apply, never the group" {
  fake_docker; touch "$TEST_TMP/dk/fail-version"; um_probe_docker
  [ "${UM_CAP[docker_note]}" = "could not read Docker without root; run with --apply to list it" ]
  [ "${UM_CAP[docker_running]}" = unknown ]
}

@test "docker probe: daily mode checks the daemon but never reads disk usage" {
  fake_docker; UM_MODE=daily um_probe_docker
  grep -q "^version" "$TEST_TMP/dk/calls"
  run ! grep -q "^system" "$TEST_TMP/dk/calls"
  [ "${UM_CAP[docker_running]}" = 1 ]
  [ "${UM_CAP[docker_removable_images]}" = n/a ]
}

@test "docker probe: monthly counts removable images and stopped containers" {
  fake_docker; UM_MODE=monthly um_probe_docker > /dev/null
  [ "${UM_CAP[docker_removable_images]}" = 4 ]
  [ "${UM_CAP[docker_stopped_containers]}" = 2 ]
}

@test "docker collect: items numbered in display order" {
  fake_docker; collect
  [ "${UM_DK_NAME[1]}" = old-web ]
  [ "${UM_DK_DATE[1]}" = "never run" ]
  [ "${UM_DK_NAME[2]%% *}" = old-db ]
  [ "${UM_DK_DATE[2]}" = 2026-05-02 ]
  [ "${UM_DK_NAME[3]}" = demo/big:3 ]
  [ "${UM_DK_NEEDS[4]}" = "1 2" ]
  [ "${UM_DK_TAGS[5]}" = "demo/base:1 demo/base:latest" ]
  [ "${UM_DK_DATE[5]}" = unknown ]
  [ "${UM_DK_NAME[6]}" = "<none> 0e0e0e0e0e0e" ]
  [ -z "${UM_DK_TAGS[6]}" ]
  [ "${UM_DK_KIND[7]}" = cache ]
  [ "${#UM_DK_ID[@]}" -eq 7 ]
  [ "${UM_DK_BYTES[7]}" = 1400000000 ]
  [[ "$UM_DK_KEPT" == "Kept: 1 image (420 MB) used by running container app-1" ]]
  [ "${#UM_DK_VOLUMES[@]}" -eq 3 ]
  [ "$UM_DK_VOLTOTAL" = "1.2 GB" ]
}

@test "docker collect: hostile name neutralized, malformed record dropped" {
  fake_docker hostile; UM_MODE=monthly um_docker_collect > "$TEST_TMP/out"
  grep -q 'warning: Docker: skipped an unreadable record' "$TEST_TMP/out"
  [[ "${UM_DK_NAME[*]}" != *$'\e'* && "${UM_DK_NAME[*]}" != *$'\x1f'* ]]
  [[ "${UM_DK_NAME[*]}" == *'old?]0;x?db [compose shop?x]'* ]]
  # The malformed record uses demo/db:2: that image is withheld (fail closed).
  [ "${#UM_DK_ID[@]}" -eq 6 ]
  run ! item demo/db
}

@test "docker collect: a label that is not set (null) is empty, not unreadable" {
  fake_docker
  sed -i 's|"/old-web"\t""\t""|"/old-web"\tnull\tnull|' "$TEST_TMP/dk/containers.tsv"
  grep -q 'old-web"	null	null' "$TEST_TMP/dk/containers.tsv"
  UM_MODE=monthly um_docker_collect > "$TEST_TMP/out"
  run ! grep -q warning "$TEST_TMP/out"
  [ "${UM_DK_NAME[1]}" = old-web ]
  [ "${UM_DK_NEEDS[4]}" = "1 2" ]
}

@test "docker collect: an image with an unreadable tag is not listed at all" {
  fake_docker
  sed -i 's|demo/base:1,demo/base:latest|demo/Base:1,demo/base:latest|' "$TEST_TMP/dk/images.tsv"
  UM_MODE=monthly um_docker_collect > /dev/null
  [ "${#UM_DK_ID[@]}" -eq 6 ]
  [[ "${UM_DK_NAME[*]}" != *demo/base* ]]
}

@test "docker collect: an unreadable container record keeps its image off the list" {
  fake_docker
  sed -i 's|\tunless-stopped\t"/app-1"|\t<no value>\t"/app-1"|' "$TEST_TMP/dk/containers.tsv"
  grep -q '<no value>' "$TEST_TMP/dk/containers.tsv"
  UM_MODE=monthly um_docker_collect > /dev/null
  run ! item demo/app
  [ "${#UM_DK_ID[@]}" -eq 7 ]
}

@test "docker collect: a failing list call leaves no list and a note" {
  fake_docker; collect; [ "${#UM_DK_ID[@]}" -eq 7 ]
  touch "$TEST_TMP/dk/fail-image"
  run ! um_docker_collect      # status
  um_docker_collect || true    # state, in this shell
  [ "${#UM_DK_ID[@]}" -eq 0 ]
  [[ "${UM_CAP[docker_note]}" == "could not read Docker ("* ]]
}

@test "docker collect: containerd store marks sizes approximate, N/A is unknown" {
  fake_docker containerd; collect
  [ "$UM_DK_ABOUT" = 1 ]
  [ "${UM_DK_NAME[6]}" = demo/big:3 ]
  [ -z "${UM_DK_BYTES[6]}" ]
}

@test "docker collect: only read-only calls" {
  fake_docker; UM_MODE=monthly um_docker_collect > /dev/null
  assert_readonly_calls
  [ "$(grep -c '^system' "$TEST_TMP/dk/calls")" -eq 2 ]
}

@test "docker render: every line fits 80 bytes" {
  fake_docker; collect; run um_docker_render
  [ "$(LC_ALL=C awk 'length > 80' <<<"$output" | wc -l)" -eq 0 ]
  UM_DK_NAME[3]="demo/$(printf 'x%.0s' {1..90}):tail42"; run um_docker_render
  [ "$(LC_ALL=C awk 'length > 80' <<<"$output" | wc -l)" -eq 0 ]
  [[ "$output" == *"...tail42"* ]]
}

@test "docker render: header, groups, notes, kept line, volumes" {
  fake_docker; collect; run um_docker_render
  [[ "${lines[0]}" == "Docker: 7 item(s) can be removed, at least 2.1 GB." ]]
  [[ "$output" == *"Files written inside a container are deleted with it."* ]]
  [[ "$output" == *"  #   frees  last stop   container"* ]]
  [[ "$output" == *"  1     0 B  never run   old-web, image demo/db:2"* ]]
  [[ "$output" == *'Docker does not record when an image was last used; "built" = build date.'* ]]
  [[ "$output" == *"  #   frees  built       image"* ]]
  [[ "$output" == *"  4  210 MB  2025-09-01  demo/db:2 (used by stopped 1,2: pick both)"* ]]
  [[ "$output" == *"  5  100 MB  unknown     demo/base:1, demo/base:latest"* ]]
  [[ "$output" == *"old-db [compose shop] (restarts when Docker restarts)"* ]]
  [[ "$output" == *"  7  1.4 GB  -           build cache (incl. build-mount caches)"* ]]
  [[ "$output" == *"Kept: 1 image (420 MB) used by running container app-1"* ]]
  [[ "$output" == *"Volumes (1.2 GB; kept, never removed here):"* ]]
  [[ "$output" == *"  823 MB  not used  data-vol"* ]]
  [[ "$output" == *"   12 kB  in use    app-vol"* ]]
}

@test "docker render: more than five volumes end with a count" {
  fake_docker
  printf '1MB\t0\t"v%s"\n' 1 2 3 4 >> "$TEST_TMP/dk/volumes.tsv"
  collect; run um_docker_render
  [[ "$output" == *"  ... (+2 more)"* ]]
}

@test "docker render: nothing removable is one line" {
  fake_docker kept-only; collect; run um_docker_render
  [ "${lines[0]}" = "Docker: nothing to remove" ]
  [[ "$output" != *"  #   frees"* ]]
  [[ "$output" == *"Kept: 1 image (420 MB) used by running container app-1"* ]]
  [[ "$output" == *"Volumes ("* ]]
}

@test "docker render: unknown size shows ? and is not counted" {
  fake_docker containerd; collect; run um_docker_render
  [ "${lines[0]}" = "Docker: 7 item(s) can be removed, about 1.8 GB." ]
  [[ "$output" == *"  6       ?  2025-04-08  demo/big:3"* ]]
}

@test "docker render: no build cache line when the cache is empty" {
  fake_docker no-cache; collect; run um_docker_render
  [ "${lines[0]}" = "Docker: 6 item(s) can be removed, at least 672 MB." ]
  [[ "$output" != *"build cache"* ]]
}

# Answers for the picker, one per question; __eof__ (or running out) = no answer. The
# question is printed so tests can check it.
answers=()
answer_from_list() {
  local a="${answers[0]-__eof__}"
  answers=("${answers[@]:1}")
  printf '%s\n' "$1"
  [[ "$a" == __eof__ ]] && return 1
  printf -v "$2" '%s' "$a"
}
um_docker_pick_and_remove() { um_docker_pick && um_docker_remove; }
state_has() { grep -q "$2" "${TEST_TMP}/dk/$1"; }

@test "docker pick: picking 3 removes exactly item 3" {
  fake_docker; collect; answers=(3 y)
  um_docker_pick > /dev/null && um_docker_remove > /dev/null
  [ "$(removal_calls)" = "image	rm	--	${UM_DK_ID[3]}" ]
  run ! state_has images.tsv demo/big:3
}

@test "docker pick: n, Enter, no answer at either question remove nothing" {
  local case
  for case in "3 n" "3 N" "3 yes" "''" "3 __eof__" "__eof__"; do
    fake_docker; collect; eval "answers=($case)"
    run um_docker_pick_and_remove
    [ "$status" -ne 0 ]
    [[ "$output" == *"othing removed."* ]]
    assert_readonly_calls
  done
}

@test "docker pick: Enter says nothing was removed, no answer says so too" {
  fake_docker; collect; answers=('')
  run um_docker_pick_and_remove; [[ "$output" == *"Nothing removed."* ]]
  answers=(__eof__)
  run um_docker_pick_and_remove; [[ "$output" == *"No answer; nothing removed."* ]]
}

@test "docker pick: one retry after input that is not understood" {
  fake_docker; collect; answers=(12 3 y); run um_docker_pick_and_remove
  [[ "$output" == *"not understood: 12 (choose 1-7); try once more"* ]]
  [ "$(removal_calls | wc -l)" -eq 1 ]
}

@test "docker pick: two bad answers remove nothing" {
  fake_docker; collect; answers=(12 $'x\e[2J' y); run um_docker_pick_and_remove
  [ "$status" -ne 0 ]
  [[ "$output" == *"not understood: x?[2J; nothing removed."* ]]
  assert_readonly_calls
}

@test "docker pick: image without all its containers is skipped" {
  fake_docker; collect; answers=("2 4" y); run um_docker_pick_and_remove
  [[ "$output" == *"skipped 4: container 1 was not picked"* ]]
  [ "$(removal_calls | grep -c $'^image')" -eq 0 ]
  [ "$(removal_calls)" = "container	rm	--	${UM_DK_ID[2]}" ]
}

@test "docker pick: image with its containers is removed after them" {
  fake_docker; collect; answers=("4 2 1" y); run um_docker_pick_and_remove
  [ "$(removal_calls)" = "container	rm	--	${UM_DK_ID[1]}
container	rm	--	${UM_DK_ID[2]}
image	rm	--	${UM_DK_ID[4]}" ]
  [[ "$output" == *"Docker: removed 3 of 3 item(s), at least 222 MB freed"* ]]
}

@test "docker pick: confirm line lists every picked item and the total" {
  fake_docker; collect; answers=("3,5" y); run um_docker_pick_and_remove
  [[ "$output" == *"  3  300 MB  2025-04-08  demo/big:3"*"  5  100 MB  unknown     demo/base:1, demo/base:latest"*"Remove 2 item(s), at least 400 MB? [y/N] "* ]]
}

@test "docker pick: confirm repeats long names in full" {
  fake_docker; collect; UM_DK_NAME[3]="demo/$(printf 'x%.0s' {1..90}):3"; answers=(3 n)
  run um_docker_pick_and_remove
  [[ "$output" == *"${UM_DK_NAME[3]}"* ]]
}

@test "docker remove: shared-ID image untags by name then removes by ID" {
  fake_docker; collect; answers=(5 y); run um_docker_pick_and_remove
  [ "$(removal_calls)" = "image	rm	--	demo/base:1
image	rm	--	${UM_DK_ID[5]}" ]
  run ! state_has images.tsv "${UM_DK_ID[5]}"
}

@test "docker remove: moved tag is skipped, image kept" {
  fake_docker; collect; answers=(5 y)
  local new
  new="sha256:$(printf 'e7%.0s' {1..32})"
  sed -i 's|demo/base:1,demo/base:latest|demo/base:latest|' "$TEST_TMP/dk/images.tsv"
  printf '%s\t5MB\t2026-11-10 10:00:00 +0000 UTC\tdemo/base:1\n' "$new" >> "$TEST_TMP/dk/images.tsv"
  run um_docker_pick_and_remove
  [[ "$output" == *"warning: Docker: demo/base:1 now points to another image; not removed"* ]]
  assert_readonly_calls
  state_has images.tsv "${UM_DK_ID[5]}" && state_has images.tsv "$new"
}

@test "docker remove: a tag added since the list keeps the image" {
  fake_docker; collect; answers=(6 y)
  sed -i "s|^\(${UM_DK_ID[6]}.*\)\t-$|\1\tdemo/new:1|" "$TEST_TMP/dk/images.tsv"
  run um_docker_pick_and_remove
  [[ "$output" == *"warning: Docker: <none> 0e0e0e0e0e0e changed since the list; not removed"* ]]
  assert_readonly_calls
}

@test "docker remove: restarted container is not removed" {
  fake_docker; collect; answers=(2 y)
  sed -i 's|2026-05-01T08:00:00.5Z|2026-11-15T08:00:00Z|' "$TEST_TMP/dk/containers.tsv"
  run um_docker_pick_and_remove
  [[ "$output" == *"warning: Docker: old-db [compose shop] changed since the list; not removed"* ]]
  assert_readonly_calls
}

@test "docker remove: a container running again is not removed" {
  fake_docker; collect; answers=(2 y)
  sed -i 's|\texited\t|\trunning\t|' "$TEST_TMP/dk/containers.tsv"
  run um_docker_pick_and_remove
  [[ "$output" == *"changed since the list; not removed"* ]]
  assert_readonly_calls
}

@test "docker remove: vanished container is skipped and its image kept" {
  fake_docker; collect; answers=("1 2 4" y)
  sed -i "/^${UM_DK_ID[1]}/d" "$TEST_TMP/dk/containers.tsv"
  run um_docker_pick_and_remove
  [[ "$output" == *"warning: Docker: old-web is gone; skipped"* ]]
  [[ "$output" == *"warning: Docker: demo/db:2 kept; its container was not removed"* ]]
  [ "$(removal_calls)" = "container	rm	--	${UM_DK_ID[2]}" ]
}

@test "docker remove: failed container keeps its image" {
  fake_docker; collect; answers=("1 2 4" y); touch "$TEST_TMP/dk/fail-container-rm"
  run um_docker_pick_and_remove
  [[ "$output" == *"warning: Docker: could not remove old-web: Error response from daemon: injected failure"* ]]
  [[ "$output" == *"demo/db:2 kept; its container was not removed"* ]]
  [ "$(removal_calls | grep -c $'^image')" -eq 0 ]
}

@test "docker remove: build cache pruned only when picked" {
  fake_docker; collect; answers=(3 y); run um_docker_pick_and_remove
  run ! grep -q $'^builder' "$TEST_TMP/dk/calls"
  fake_docker; collect; answers=(7 y); run um_docker_pick_and_remove
  [ "$(removal_calls)" = "builder	prune	--all	-f" ]
  [[ "$output" == *"removed build cache (incl. build-mount caches) (1.4 GB)"* ]]
}

@test "docker remove: total counts only successful removals" {
  fake_docker; collect; answers=("1-4" y); touch "$TEST_TMP/dk/fail-container-rm"
  run um_docker_pick_and_remove
  [[ "$output" == *"removed demo/big:3 (300 MB)"* ]]
  [[ "$output" == *"Docker: removed 1 of 4 item(s), at least 300 MB freed"* ]]
}

@test "docker remove: everything picked leaves only what is kept; never force, never volumes" {
  fake_docker; collect; answers=(1-7 y); run um_docker_pick_and_remove
  [[ "$output" == *"Docker: removed 7 of 7 item(s), at least 2.1 GB freed"* ]]
  [ "$(cut -f4 "$TEST_TMP/dk/images.tsv")" = demo/app:1 ]
  [ "$(wc -l < "$TEST_TMP/dk/containers.tsv")" -eq 1 ]
  [ "$(wc -l < "$TEST_TMP/dk/volumes.tsv")" -eq 3 ]
  run ! grep -E $'\t(-f|--force|-v|--volumes)(\t|$)' <(grep -v $'^builder' "$TEST_TMP/dk/calls")
}

@test "docker phase: dry run lists, asks nothing, reads only" {
  fake_docker; export UM_MODE=monthly UM_APPLY=0; um_probe_docker > /dev/null
  um_have_tty() { return 0; }
  run um_docker_phase
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Docker ==="*"Docker: 7 item(s) can be removed"* ]]
  [[ "$output" == *"[dry-run] with --apply on a terminal, would ask which of 7 item(s) to remove"* ]]
  [[ "$output" != *"Remove which?"* ]]
  assert_readonly_calls
}

@test "docker phase: apply without terminal reports and recommends" {
  fake_docker; export UM_MODE=monthly UM_APPLY=1; um_probe_docker > /dev/null
  um_have_tty() { return 1; }; um_docker_phase > "$TEST_TMP/out"
  grep -q 'Docker: nothing removed without a terminal' "$TEST_TMP/out"
  run um_result_print 0
  [[ "$output" == *"Recommended: free Docker space (2.1 GB): ubuntu-maintain --apply --mode monthly"* ]]
  assert_readonly_calls
}

@test "docker phase: apply re-reads the list before asking" {
  fake_docker; export UM_MODE=monthly UM_APPLY=1; um_probe_docker > /dev/null
  : > "$TEST_TMP/dk/calls"; um_have_tty() { return 1; }; um_docker_phase > /dev/null
  grep -q $'^system\tdf\t-v' "$TEST_TMP/dk/calls"
}

@test "docker phase: answering none or n sets no Recommended line" {
  local a
  for a in '' n; do
    fake_docker; export UM_MODE=monthly UM_APPLY=1; um_probe_docker > /dev/null
    um_have_tty() { return 0; }; answers=("$a"); [ -z "$a" ] || answers=(3 "$a")
    um_docker_phase > /dev/null
    run um_result_print 0
    [[ "$output" != *"free Docker space"* ]]
    assert_readonly_calls
  done
}

@test "docker phase: not running prints the skipped line" {
  fake_docker; rm "$TEST_TMP/dk/docker.sock"; export UM_MODE=monthly; um_probe_docker
  run um_docker_phase
  [[ "$output" == *"=== Docker ==="*"Docker: not running; skipped"* ]]
}

@test "docker phase: a note is shown and nothing is read" {
  fake_docker; touch "$TEST_TMP/dk/fail-version"; export UM_MODE=monthly; um_probe_docker
  run um_docker_phase
  [[ "$output" == *"note: could not read Docker without root; run with --apply to list it"* ]]
  run ! grep -q '^system' "$TEST_TMP/dk/calls"
}

@test "docker phase: daily mode and no docker print nothing" {
  fake_docker; export UM_MODE=daily; um_probe_docker
  run um_docker_phase; [ -z "$output" ]
  UM_DOCKER_BIN=/nonexistent; export UM_MODE=monthly; um_probe_docker
  run um_docker_phase; [ -z "$output" ]
}

@test "docker phase: a failed removal never changes the exit code" {
  fake_docker; export UM_MODE=monthly UM_APPLY=1; um_probe_docker > /dev/null
  touch "$TEST_TMP/dk/fail-container-rm"; um_have_tty() { return 0; }; answers=(1 y)
  run um_docker_phase
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: Docker: could not remove old-web"* ]]
}

@test "manifest shows the docker block, n/a counts outside monthly" {
  fake_docker; export UM_MODE=daily; um_probe_docker
  run um_manifest_print
  [[ "$output" == *$'docker:\n  available: 1\n  running: 1\n  removable_images: n/a\n  stopped_containers: n/a'* ]]
  [[ "$output" != *"  - docker"* ]]
  export UM_MODE=monthly; um_probe_docker > /dev/null
  run um_manifest_print
  [[ "$output" == *$'  removable_images: 4\n  stopped_containers: 2'* ]]
  [[ "$output" == *"  - docker (report; removing asks first) (monthly)"* ]]
}

@test "manifest shows running n/a when docker is unavailable" {
  export UM_MODE=monthly; um_probe_docker
  run um_manifest_print
  [[ "$output" == *$'docker:\n  available: 0\n  running: n/a'* ]]
  [[ "$output" != *"  - docker"* ]]
}

@test "dag runs docker after topgrade and before firmware" {
  run bash -c "
    source '${UM_LIB}/common.sh'; um_source_libs
    UM_APPLY=0 UM_MODE=monthly
    um_run_probes() { UM_CAP[apt_available]=0; }
    um_manifest_print() { :; }
    um_journal_phase() { echo JOURNAL; }
    um_topgrade_phase() { echo TOPGRADE; }
    um_docker_phase() { echo DOCKER; return 1; }
    um_firmware_phase() { echo FIRMWARE; }
    um_run_dag
  "
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(JOURNAL|TOPGRADE|DOCKER|FIRMWARE)$' <<<"$output" | paste -sd ' ')" = "JOURNAL TOPGRADE DOCKER FIRMWARE" ]
}

@test "docker: disk usage and removals get the long time limit" {
  fake_docker
  eval "real_$(declare -f um_docker_cmd)"
  um_docker_cmd() { printf '%s\n' "$*" >> "$TEST_TMP/limits"; real_um_docker_cmd "$@"; }
  collect; answers=(1-7 y); um_docker_pick_and_remove > /dev/null
  run ! grep -E '^(system df|container rm|image rm|builder prune)' "$TEST_TMP/limits"
  [ "$(grep -cE '^--slow (system df|container rm|image rm|builder prune)' "$TEST_TMP/limits")" -eq 10 ]
}
