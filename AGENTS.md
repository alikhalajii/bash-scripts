# Agent notes

Bash maintenance tooling for Ubuntu/Debian. Entry point: `bin/ubuntu-maintain`.

Before changing apt locks, probes, or LTS version behavior, search `docs/solutions/` (YAML frontmatter: `module`, `tags`, `problem_type`).

Development: `shellcheck` on `lib/` and `bin/`; `tests/run-tests.sh` (requires [bats](https://github.com/bats-core/bats-core) — see `docs/REQUIREMENTS.md`).

Output: plain text, no color. Start each phase with `um_section "<Name>"`; prefix problems with `warning:` or `error:` in a direct `um_log` call (not inside `$(...)`) so they are repeated in the final Result block. Manifest keys are grepped by CI and scripts: do not rename them.

User-facing issues: `docs/TROUBLESHOOTING.md`.
