#!/usr/bin/env bash
# run-tests.sh — Run the bats test suite (bats >= 1.5 on PATH).
# Example: tests/run-tests.sh                                      # whole suite
#          bats tests/ubuntu-maintain.bats -f 'firmware'           # tests whose name matches
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bats "${ROOT}/tests/ubuntu-maintain.bats"
