#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/tests/helpers/bin:${PATH}"
exec bats "${ROOT}/tests/ubuntu-maintain.bats"
