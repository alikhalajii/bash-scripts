# Agent notes

Bash maintenance tooling for Ubuntu/Debian. Entry point: `bin/ubuntu-maintain`.

Before changing apt locks, probes, or LTS version behavior, search `docs/solutions/` (YAML frontmatter: `module`, `tags`, `problem_type`).

Development: `pre-commit run --all-files` (shellcheck, prettier, hygiene) and `pre-commit run --all-files --hook-stage pre-push` (bats suite); pinned in `.pre-commit-config.yaml`, setup in `docs/REQUIREMENTS.md`. Tests use fake `/boot` and `/proc` dirs (`UM_BOOT_DIR`, `UM_PROC_DIR`).

Output: plain text, no color. Start each phase with `um_section "<Name>"`; prefix problems with `warning:` or `error:` in a direct `um_log` call (not inside `$(...)`) so they are repeated in the final Result block. Manifest keys are grepped by CI and scripts: do not rename them.

Firmware: query `fwupdmgr` only through `um_fw_cmd` (C locale, stdin `/dev/null`, `--json`, time limit); never call `check-reboot-needed` (it asks to restart). Install only via `um_firmware_phase`. Never remove packages from `?obsolete`.

Docker: call docker only through `um_docker_cmd` (isolated env, fixed socket). Never `system prune`, `image prune`, `volume rm`, `-f`/`--force`/`-v` on rm; the only prune is `builder prune --all -f`. Validate every parsed field and pass displayed text through `um_docker_safe_text`. Remove only after the picker's final `y` and a re-check of each item.

User-facing issues: `docs/TROUBLESHOOTING.md`.
