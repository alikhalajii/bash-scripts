#!/usr/bin/env bash
# docker-dind.sh — End-to-end test of the Docker phase against a throwaway Docker daemon.
# Purpose:  start a pinned docker:<version>-dind container whose socket lives in a private
#           temp dir, create test images and containers in it (no network), run the Docker
#           phase on a pseudo-terminal (tests/e2e/pty_drive.py) and check that exactly the
#           picked items are removed, and nothing when the answer is n or none; a volume
#           and a running container are never offered. The host's own images (with
#           tags), containers and volumes are compared before and after.
# Provides: exit 0 and "e2e (docker N): ok", or the first failure and exit 1.
# Example:  tests/e2e/docker-dind.sh 29        # needs Docker on the host (and network to pull)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Pinned by index digest (multi-arch); refresh with: docker buildx imagetools inspect docker:29-dind
DIND_28=docker:28-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac
DIND_29=docker:29-dind@sha256:7bf70dcb85c822e3fa6f2d332143e474b99147b9d7b39102b0cfe8b04a7dd61b

case "${1:-}" in
  28) IMAGE="$DIND_28" ;;
  29) IMAGE="$DIND_29" ;;
  *) echo "usage: $0 28|29" >&2; exit 64 ;;
esac
VERSION="$1"

fail() { echo "e2e (docker ${VERSION}): FAIL: $*" >&2; exit 1; }
host_snapshot() {
  docker image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | sort
  echo --; docker ps -aq --no-trunc | sort
  echo --; docker volume ls -q | sort
}

docker pull -q "$IMAGE" > /dev/null
BEFORE="$(host_snapshot)"
D="$(mktemp -d)"
NAME="um-e2e-$$-${RANDOM}"

cleanup() {
  local rc=$?
  docker rm -fv "$NAME" > /dev/null 2>&1 || true
  if [[ "$(host_snapshot)" != "$BEFORE" ]]; then
    echo "e2e (docker ${VERSION}): FAIL: the host's images, containers or volumes changed" >&2
    rc=1
  fi
  rm -rf "$D"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

docker run -d --privileged --network none --name "$NAME" -e DOCKER_TLS_CERTDIR= \
  -v "${D}:/run/um" "$IMAGE" \
  dockerd --host=unix:///run/um/docker.sock --group="$(id -g)" --iptables=false --bridge=none \
  > /dev/null
for _ in $(seq 60); do [[ -S "$D/docker.sock" ]] && break; sleep 1; done
[[ -S "$D/docker.sock" ]] || fail "the dind daemon did not start"

# The CLI of the same version; the wrapper refuses any daemon but this one (fail closed).
docker cp "${NAME}:/usr/local/bin/docker" "$D/docker-cli" > /dev/null
mkdir -m 700 "$D/cfg"
cat > "$D/docker" <<EOF
#!/bin/sh
[ "\${DOCKER_HOST:-}" = "unix://${D}/docker.sock" ] || { echo "e2e wrapper: refusing DOCKER_HOST=\${DOCKER_HOST:-}" >&2; exit 97; }
exec "${D}/docker-cli" "\$@"
EOF
chmod 755 "$D/docker"
dind() { DOCKER_CONFIG="$D/cfg" "$D/docker-cli" -H "unix://${D}/docker.sock" "$@"; }
for _ in $(seq 30); do dind version > /dev/null 2>&1 && break; sleep 1; done
dind version > /dev/null || fail "the dind daemon does not answer"

# Test items, made without network: empty images with distinct labels, never-run containers.
MARKER="e2e/m-${RANDOM}:1"
for n in a b c "$MARKER"; do
  ref="$n"; [[ "$n" == */* ]] || ref="e2e/${n}:1"
  tar -cf - -T /dev/null | dind import --message "$n" --change "LABEL n=${n}" - "$ref" > /dev/null
done
dind tag e2e/a:1 e2e/a:latest
dind create --name keep e2e/b:1 /x > /dev/null
dind create --name gone e2e/c:1 /x > /dev/null
dind volume create e2e-vol > /dev/null
# A running container: the host's sleep and the libraries it loads, no network needed.
mapfile -t files < <({ echo /usr/bin/sleep; ldd /usr/bin/sleep | grep -o '/[^ ]*'; } | sed 's|^/||')
tar -chf - -C / "${files[@]}" 2> /dev/null \
  | dind import --message run --change 'CMD ["/usr/bin/sleep", "600"]' - e2e/run:1 > /dev/null
dind run -d --network none --name runner e2e/run:1 > /dev/null

id_of() { dind image inspect --format '{{.Id}}' "$1"; }
IA="$(id_of e2e/a:1)" IB="$(id_of e2e/b:1)" IC="$(id_of e2e/c:1)" IM="$(id_of "$MARKER")"
CK="$(dind container inspect --format '{{.Id}}' keep)" CG="$(dind container inspect --format '{{.Id}}' gone)"
state() {
  dind image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | sort
  echo --; dind ps -a --no-trunc --format '{{.ID}} {{.State}}' | sort
  echo --; dind volume ls -q | sort
}

# phase PICK CONFIRM: run probe + Docker phase only (never the full monthly apply) under a pty.
phase() {
  # common.sh resets UM_MODE and UM_APPLY when sourced: set them afterwards.
  env UM_DOCKER_SOCK="$D/docker.sock" UM_DOCKER_BIN="$D/docker" UM_TTY_TIMEOUT=3 \
    python3 "$ROOT/tests/e2e/pty_drive.py" --marker "$MARKER" --absent runner,e2e/run:1 \
    --pick "$1" --confirm "$2" -- bash -c '
      cd "$1" && source lib/ubuntu-maintain/common.sh && um_source_libs &&
      UM_MODE=monthly UM_APPLY=1 && um_probe_docker && um_docker_phase' _ "$ROOT"
}

S0="$(state)"
phase "e2e/a:1,gone,e2e/c:1" n || fail "run n: driver failed"
[[ "$(state)" == "$S0" ]] || fail "answer n removed something"
phase "e2e/a:1,gone,e2e/c:1" none || fail "run no-confirm: driver failed"
[[ "$(state)" == "$S0" ]] || fail "no answer at the confirmation removed something"
phase "" none || fail "run no-pick: driver failed"
[[ "$(state)" == "$S0" ]] || fail "no answer at the picker removed something"

phase "e2e/a:1,gone,e2e/c:1" y || fail "run y: driver failed"
S1="$(state)"
for gone_id in "$IA" "$IC" "$CG"; do
  grep -q "^${gone_id} " <<<"$S1" && fail "picked item ${gone_id} is still there"
done
for kept_id in "$IB" "$IM" "$CK"; do
  grep -q "^${kept_id} " <<<"$S1" || fail "item ${kept_id} was removed but not picked"
done
dind image inspect e2e/a:latest > /dev/null 2>&1 && fail "e2e/a:latest is still tagged"
[[ "$(dind container inspect --format '{{.State.Running}}' runner)" == true ]] \
  || fail "the running container was touched"
dind volume inspect e2e-vol > /dev/null 2>&1 || fail "the volume was removed"

echo "e2e (docker ${VERSION}): ok"
