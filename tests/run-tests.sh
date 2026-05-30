#!/usr/bin/env bash
# run-tests.sh — Run the ubuntu-maintain Bats test suite.
# Run:     ./tests/run-tests.sh   (requires bats on PATH)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bats "${ROOT}/tests/ubuntu-maintain.bats"
