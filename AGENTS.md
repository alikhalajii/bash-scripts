# Agent notes

Bash maintenance tooling for Ubuntu/Debian. Entry point: `bin/ubuntu-maintain`.

Before changing apt locks, probes, or LTS version behavior, search `docs/solutions/` (YAML frontmatter: `module`, `tags`, `problem_type`).

Development: `shellcheck` on `lib/` and `bin/`; `tests/run-tests.sh` (requires [bats](https://github.com/bats-core/bats-core) — see README).
