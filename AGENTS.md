# Agent notes

Bash maintenance tooling for Ubuntu/Debian. Entry point: `bin/ubuntu-maintain`.

Before changing apt locks, probes, or LTS version behavior, search `docs/solutions/` (YAML frontmatter: `module`, `tags`, `problem_type`).

Development: `pre-commit run --all-files` (shellcheck, prettier, hygiene) and `pre-commit run --all-files --hook-stage pre-push` (bats suite); pinned in `.pre-commit-config.yaml`, setup in `docs/REQUIREMENTS.md`. Tests use fake `/boot` and `/proc` dirs (`UM_BOOT_DIR`, `UM_PROC_DIR`).

Output: plain text, no color. Start each phase with `um_section "<Name>"`; prefix problems with `warning:` or `error:` in a direct `um_log` call (not inside `$(...)`) so they are repeated in the final Result block. Manifest keys are grepped by CI and scripts: do not rename them.

User-facing issues: `docs/TROUBLESHOOTING.md`.
