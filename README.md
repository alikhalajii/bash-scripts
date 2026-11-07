# ubuntu-maintain

Safe, probe-driven system updates for Ubuntu and Debian.

`ubuntu-maintain` detects what is installed (apt, snap, flatpak, optionally topgrade), prints a manifest of what it found and what it plans to do, and **changes nothing unless you pass `--apply`**. After an apply run it checks system health and prints a summary of every package installed, upgraded, or removed.

## Quick start

```bash
git clone <repo-url> ubuntu-maintain
cd ubuntu-maintain

./bin/ubuntu-maintain            # dry run: manifest + planned actions, no changes
./bin/ubuntu-maintain --apply    # apply updates (asks for your sudo password once)
```

You do not need to prefix `--apply` with `sudo`; the tool re-runs itself under sudo. It needs a real terminal for the password prompt.

### Run it from anywhere

Either add `bin/` to your PATH (e.g. in `~/.bashrc`):

```bash
export PATH="/path/to/ubuntu-maintain/bin:$PATH"
```

or symlink the command:

```bash
ln -s /path/to/ubuntu-maintain/bin/ubuntu-maintain ~/.local/bin/ubuntu-maintain
```

## What a run does

Phases run in this order; each one is skipped if its tool is missing or has nothing installed.

1. **Manifest:** OS, package managers, apt lock state, held packages, pending reboot, failed systemd units.
2. **apt:** `apt-get update`, re-simulates the upgrade against fresh package lists, then upgrades.
3. **snap:** `snap refresh`.
4. **flatpak:** `flatpak update` (the system-wide installation).
5. **topgrade** (only with `--with-topgrade`): pip, cargo, npm and other user-level tools.
6. **Stability gate** (only with `--apply`): pending reboot, failed systemd units, interrupted dpkg runs, and a `needrestart` report when installed.
7. **Update summary** (only with `--apply`).

## Common tasks

```bash
ubuntu-maintain --apply                    # routine update
ubuntu-maintain --apply --mode monthly     # update + cleanup (see below)
ubuntu-maintain --apply --aggressive       # allow dist-upgrade, which may remove packages
ubuntu-maintain --apply --with-topgrade    # also update user-level tools
ubuntu-maintain --apply --ignore-stability # do not exit 2 for known, unrelated failed units
```

**Monthly mode removes things.** On top of upgrades it runs `apt-get autoremove --purge` and `autoclean`, purges leftover config files of already-removed packages, removes disabled snap revisions and the snap download cache, and uninstalls unused flatpak runtimes. Run it without `--apply` first to review the plan.

## Options

| Option | Effect |
| --- | --- |
| `--apply` | Make changes. Without it, everything is a dry run. |
| `--mode daily\|monthly` | `daily` (default) upgrades only; `monthly` adds the cleanup above. |
| `--aggressive` | Use `apt-get dist-upgrade`, which may remove packages. |
| `--manifest-only` | Print the manifest and exit. |
| `--with-topgrade` | Run [topgrade](https://github.com/topgrade-rs/topgrade) after the system package managers. |
| `--continue-on-pm-failure` | Keep going after a snap, flatpak, or topgrade failure. The exit code still reports it. An apt failure always stops the run. |
| `--ignore-stability` | Do not exit 2 for failed units, a pending reboot, or dpkg errors. |
| `--restart-services` | Let needrestart restart affected services automatically. Use with care. |
| `--log-file PATH` | Write the log to `PATH` instead of the default (see [Logs](#logs)). |
| `-h`, `--help` | Show help. |

Setting `UPDATE_APPLY=1` in the environment is the same as `--apply`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success (a dry run always exits 0) |
| 2 | Updates finished, but the stability gate found issues (reboot required, failed units, dpkg errors) |
| 10 | apt phase failed |
| 11 | snap phase failed |
| 12 | flatpak phase failed |
| 13 | topgrade phase failed |
| 64 | Usage error: unknown option, missing value, sudo missing, sudo authentication failed, or the tool's files are writable by other users |

Exit 2 is deliberate, so scheduled runs do not report an unhealthy system as green. Units that are expected to fail in the current environment (e.g. `tpm-udev` on machines without a TPM, including WSL) are listed separately and do not cause exit 2. See [Troubleshooting](docs/TROUBLESHOOTING.md#stability-gate-exit-2).

## Safety model

- **Dry run by default.** Nothing changes without `--apply`.
- **No dist-upgrade by default.** Routine runs use `apt-get upgrade` (`upgrade --with-new-pkgs` on 18.04/20.04).
- **Removal guard.** If the post-update simulation shows package removals and `--aggressive` is not set, the apply stops before upgrading.
- **No config prompts.** Upgrades keep locally modified config files (`--force-confdef --force-confold`, the same policy as unattended-upgrades) instead of stopping at a dpkg prompt.
- **Waits for apt locks, never deletes them.** Works alongside `unattended-upgrades` and the `apt-daily` timers.
- **Refuses tampered code.** As root, the tool will not run if any of its own files or folders can be written by other users. A dry run warns about it.
- **Private logs.** Logs are readable only by the user who ran the tool, and a default log path planted by another user is never written to.

## Topgrade (optional)

`ubuntu-maintain` handles the system package managers. [topgrade](https://github.com/topgrade-rs/topgrade) can handle user-level tools (pip, cargo, npm, ...). Install it first (e.g. `cargo install topgrade`), then:

```bash
ubuntu-maintain --apply --with-topgrade
```

topgrade runs as **your** user, not as root, with its system, snap, and flatpak steps disabled so nothing runs twice. Because of this it needs to know who invoked sudo: run the command from your normal account, not from a root shell.

## Logs

By default the log is `/tmp/ubuntu-maintain.<uid>.log`. After `--apply` that is `/tmp/ubuntu-maintain.0.log`, because the run happens as root. Logs are created with mode `600`. If the default path is a symlink or belongs to another user, the tool logs to a fresh temporary file instead and prints its path.

## Supported systems

Ubuntu 18.04 and later, and Debian. CI tests Ubuntu 20.04, 22.04, and 24.04. 18.04 is past standard support and is best effort; the manifest shows a warning there.

Requires bash 4.4+ and `sudo` (for `--apply`). snap, flatpak, needrestart, and topgrade are optional. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Development

```bash
./tests/run-tests.sh    # bats test suite
shellcheck --severity=warning -x bin/ubuntu-maintain update-script.sh \
  tests/run-tests.sh tests/ubuntu-maintain.bats lib/ubuntu-maintain/*.sh
```

How to install bats and shellcheck: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). CI (`.github/workflows/ci.yml`) runs shellcheck, the bats suite, and a manifest smoke test in Ubuntu 20.04–24.04 containers.

### Repository layout

```text
bin/ubuntu-maintain     CLI entry point
lib/ubuntu-maintain/    modules (probe, manifest, apt, snap, flatpak, topgrade, stability, summary)
tests/                  bats tests
docs/                   requirements, troubleshooting, operational notes (docs/solutions/)
update-script.sh        legacy wrapper, same as `ubuntu-maintain --apply`
AGENTS.md               notes for coding agents working on this repo
```
