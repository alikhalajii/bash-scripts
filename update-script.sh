#!/usr/bin/env bash
# update-script.sh — Legacy entry point; applies updates via ubuntu-maintain.
# Run:     ./update-script.sh   (equivalent to ubuntu-maintain --apply)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/bin/ubuntu-maintain" --apply "$@"
