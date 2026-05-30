#!/usr/bin/env bash
# Legacy entry point — delegates to ubuntu-maintain.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/bin/ubuntu-maintain" --apply "$@"
