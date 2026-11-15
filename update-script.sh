#!/usr/bin/env bash
# update-script.sh — Legacy entry point, kept for old cron jobs and aliases.
# Example: ./update-script.sh        # same as: ubuntu-maintain --apply
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec "${SCRIPT_DIR}/bin/ubuntu-maintain" --apply "$@"
