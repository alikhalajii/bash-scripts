# Requirements

## Runtime (using ubuntu-maintain)

| Requirement | Notes |
|-------------|--------|
| **bash** 4.4+ | Associative arrays (`declare -A`) |
| **Debian or Ubuntu** | 18.04–24.04 (18.04 best-effort) |
| **apt-get** | Always used on Debian/Ubuntu hosts |
| **sudo or root** | Required for `--apply` (system package changes) |
| **curl** | Optional; not required by the tool itself |

Optional tools (probed; phases skipped if missing or empty):

- `snap`, `flatpak`, `needrestart`, `topgrade`

## Development and testing

| Tool | Purpose |
|------|---------|
| **[Bats](https://github.com/bats-core/bats-core)** (v1.11.1+) | Run `tests/ubuntu-maintain.bats` |
| **[shellcheck](https://www.shellcheck.net/)** | Static analysis for shell scripts |

### Install Bats (curl, user-local)

If `apt install bats` is unavailable (e.g. universe repo not enabled):

```bash
curl -fsSL https://github.com/bats-core/bats-core/tarball/v1.11.1 | tar -xz -C /tmp && /tmp/bats-core-*/install.sh "$HOME/.local" && export PATH="$HOME/.local/bin:$PATH"
```

Verify and run tests:

```bash
bats --version
cd /path/to/bash-scripts
./tests/run-tests.sh
```

Persist `PATH` (optional):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

### Install shellcheck

```bash
sudo apt install shellcheck
# or: sudo snap install shellcheck
```
