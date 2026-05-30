# bash-scripts

Safe, probe-driven Ubuntu/Debian maintenance tooling.

## Documentation

| Document                                           | Contents                                                                      |
| -------------------------------------------------- | ----------------------------------------------------------------------------- |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)       | Runtime dependencies, Bats and shellcheck setup                               |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Sudo prompt, log paths, apt repo errors, stability exit 2                     |
| [docs/solutions/](docs/solutions/)                 | Operational learnings (e.g. apt locks across LTS); search by YAML frontmatter |
| [AGENTS.md](AGENTS.md)                             | Short notes for coding agents working in this repo                            |

**Layout:** `bin/ubuntu-maintain` (CLI), `lib/ubuntu-maintain/` (modules), `tests/`, `update-script.sh` (legacy `--apply` wrapper).

## ubuntu-maintain

Detects what is actually installed (apt, snap, flatpak), prints a **preflight manifest**, and by default runs in **dry-run** mode (no package changes). Use `--apply` to execute updates.

### Install

```bash
chmod +x bin/ubuntu-maintain
export PATH="/path/to/bash-scripts/bin:$PATH"   # optional
```

### Quick start

```bash
./bin/ubuntu-maintain                    # manifest + planned actions (dry-run)
./bin/ubuntu-maintain --apply            # routine safe update (prompts for sudo password)
```

### Usage

```bash
# Manifest + simulate (no package changes)
./bin/ubuntu-maintain

# Routine safe update (standard apt tier — not dist-upgrade; prompts for sudo if needed)
./bin/ubuntu-maintain --apply

# Monthly deep clean (autoremove, snap revs, flatpak unused)
sudo ./bin/ubuntu-maintain --apply --mode monthly

# Allow package removals (dist-upgrade)
sudo ./bin/ubuntu-maintain --apply --aggressive

# Language/user tools via Topgrade (after system PMs)
sudo ./bin/ubuntu-maintain --apply --with-topgrade
```

### Flags

| Flag                       | Purpose                                                                                          |
| -------------------------- | ------------------------------------------------------------------------------------------------ |
| `--apply`                  | Execute updates (default is dry-run)                                                             |
| `--aggressive`             | `apt-get dist-upgrade` tier (may remove packages)                                                |
| `--mode daily\|monthly`    | Hygiene depth (`daily` = upgrades only; `monthly` adds cleanup)                                  |
| `--manifest-only`          | Print manifest and exit                                                                          |
| `--with-topgrade`          | Run [Topgrade](https://github.com/topgrade-rs/topgrade) for pip/cargo/npm after apt/snap/flatpak |
| `--continue-on-pm-failure` | Continue to later package managers if snap/flatpak/topgrade fails                                |
| `--ignore-stability`       | Do not fail on failed systemd units after `--apply`                                              |
| `--restart-services`       | Auto-restart services via needrestart (use with care)                                            |
| `--log-file PATH`          | Log file (default: `/tmp/ubuntu-maintain.<uid>.log`, e.g. `0` under sudo)                        |

Environment: `UPDATE_APPLY=1` is equivalent to `--apply`.

### Exit codes

| Code | Meaning                                                                       |
| ---- | ----------------------------------------------------------------------------- |
| 0    | Success                                                                       |
| 2    | Stability issues after `--apply` (e.g. reboot required, failed systemd units) |
| 10   | APT phase failed                                                              |
| 11   | Snap phase failed                                                             |
| 12   | Flatpak phase failed                                                          |
| 13   | Topgrade phase failed                                                         |
| 64   | Usage error (bad flag, missing value, sudo missing, or sudo auth failed)      |

Dry-run (default, without `--apply`) exits **0** even if the system already has failed units; the stability gate runs only with `--apply`.

### Safety model

- **Dry-run by default** — review the manifest before `--apply`.
- **Standard apt tier** — routine runs use `upgrade` (or `upgrade --with-new-pkgs` on 18.04–20.04), not `dist-upgrade`, unless `--aggressive`.
- **Removal guard** — if simulate shows package removals and `--aggressive` is not set, apply aborts.
- **Probe-driven** — only runs snap/flatpak/topgrade when those tools are present and have packages/remotes.
- **Order** — apt → snap → flatpak → topgrade (optional) → stability gate (apply only).
- **Coexists** with `unattended-upgrades`; does not delete apt lock files.

### Topgrade (optional)

ubuntu-maintain owns **system** package managers. Topgrade handles pip, cargo, npm, and similar user-level tools:

```bash
# Install topgrade first, e.g. apt install topgrade  OR  cargo install topgrade
sudo ./bin/ubuntu-maintain --apply --with-topgrade
```

Apt/snap/flatpak steps are disabled inside Topgrade so work is not duplicated.

### Legacy wrapper

`update-script.sh` runs `ubuntu-maintain --apply` for backward compatibility.

### Development

Install Bats and shellcheck per **Documentation** above. When `apt install bats` is not available:

```bash
curl -fsSL https://github.com/bats-core/bats-core/tarball/v1.11.1 | tar -xz -C /tmp && /tmp/bats-core-*/install.sh "$HOME/.local" && export PATH="$HOME/.local/bin:$PATH"
```

Run checks:

```bash
./tests/run-tests.sh
shellcheck -x bin/ubuntu-maintain lib/ubuntu-maintain/*.sh update-script.sh
```

### CI

GitHub Actions: **shellcheck**, **bats** on `ubuntu-latest`, and **manifest smoke** on Ubuntu **18.04–24.04** containers.

### Supported systems

Ubuntu/Debian **18.04–24.04** (18.04 is best-effort; manifest shows an EOL warning).
