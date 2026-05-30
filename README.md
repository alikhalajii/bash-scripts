# bash-scripts

Safe, probe-driven Ubuntu/Debian maintenance tooling.

## ubuntu-maintain

Detects what is actually installed (apt, snap, flatpak), prints a **preflight manifest**, and by default runs in **dry-run** mode. Apply updates only when you pass `--apply`.

### Install

```bash
chmod +x bin/ubuntu-maintain
# Optional: add repo to PATH
export PATH="/path/to/bash-scripts/bin:$PATH"
```

### Usage

```bash
# Manifest + simulate (no system changes)
./bin/ubuntu-maintain

# Routine safe update (standard apt tier, not dist-upgrade)
sudo ./bin/ubuntu-maintain --apply

# Monthly deep clean (autoremove, snap revs, flatpak unused)
sudo ./bin/ubuntu-maintain --apply --mode monthly

# Allow package removals (dist-upgrade)
sudo ./bin/ubuntu-maintain --apply --aggressive
```

### Flags

| Flag | Purpose |
|------|---------|
| `--apply` | Execute updates (default is dry-run) |
| `--aggressive` | `apt-get dist-upgrade` tier |
| `--mode daily\|monthly` | Hygiene depth |
| `--manifest-only` | Print manifest and exit |
| `--continue-on-pm-failure` | Continue if snap/flatpak fails after apt |
| `--ignore-stability` | Do not exit on failed systemd units |
| `--restart-services` | needrestart auto-restart (use with care) |
| `--with-topgrade` | After apt/snap/flatpak, run [Topgrade](https://github.com/topgrade-rs/topgrade) for pip/cargo/npm/etc. |

Logs append to `/tmp/ubuntu-maintain.log` (override with `--log-file`).

### Topgrade (optional)

ubuntu-maintain owns **system** package managers (apt, snap, flatpak). For language and user-level tools, install Topgrade and pass `--with-topgrade`:

```bash
# Install (pick one): cargo install topgrade | brew install topgrade | apt install topgrade
sudo ./bin/ubuntu-maintain --apply --with-topgrade
```

Topgrade runs with apt/snap/flatpak steps disabled so work is not duplicated.

### Design

- **Probe-driven**: capabilities from `apt-config`, `command -v`, snap/flatpak presence — not hardcoded Ubuntu version checks alone.
- **APT**: `apt-get` only; `DPkg::Lock::Timeout` on 20.04+, fuser poll fallback on 18.04; four lock paths.
- **Order**: apt → snap → flatpak → stability gate.
- **Coexists** with `unattended-upgrades`; does not remove apt locks.

### Legacy

`update-script.sh` now runs `ubuntu-maintain --apply` for backward compatibility.

### Tests

```bash
# Install bats: apt install bats
./tests/run-tests.sh

# Static analysis
shellcheck -x bin/ubuntu-maintain lib/ubuntu-maintain/*.sh
```

### CI

GitHub Actions runs **shellcheck**, **bats**, and an **Ubuntu 18.04–24.04** matrix (`--manifest-only` smoke tests) on push/PR.

### Git

```bash
git init   # if not already a repo
git add .
git commit -m "feat: add probe-driven ubuntu-maintain with CI"
```

### Supported systems

Ubuntu/Debian **18.04–24.04** (18.04 best-effort, EOL warning in manifest).
