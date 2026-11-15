# ubuntu-maintain

Safe, probe-driven system updates for Ubuntu and Debian.

`ubuntu-maintain` detects what is installed (apt, snap, flatpak, fwupd, Docker, optionally topgrade), prints a manifest of what it found and what it plans to do, and **changes nothing unless you pass `--apply`**. After an apply run it checks system health and prints a summary of every package installed, upgraded, or removed. Every dry run and update run ends with a short **Result**: what happened, the exit code, the warnings it logged, and the log path.

## Install

Needs Ubuntu 18.04+ or Debian, with `git` and `sudo`.

```bash
git clone https://github.com/alikhalajii/bash-scripts.git ~/.local/share/ubuntu-maintain
mkdir -p ~/.local/bin
ln -s ~/.local/share/ubuntu-maintain/bin/ubuntu-maintain ~/.local/bin/ubuntu-maintain
```

Ubuntu adds `~/.local/bin` to your PATH at login. If `ubuntu-maintain` is not found, log out and back in, or run `export PATH="$HOME/.local/bin:$PATH"`.

## Use

```bash
ubuntu-maintain            # dry run: shows what it found and would do, changes nothing
ubuntu-maintain --apply    # apply updates (asks for your sudo password)
```

Run it as your normal user, not with `sudo` in front: `--apply` re-runs itself under sudo, and needs a real terminal for the password prompt.

- **Update:** `git -C ~/.local/share/ubuntu-maintain pull`
- **Uninstall:** `rm ~/.local/bin/ubuntu-maintain && rm -rf ~/.local/share/ubuntu-maintain`
- **Try without installing:** run `./bin/ubuntu-maintain` from any clone.

## What a run does

Phases run in this order; each one is skipped if its tool is missing or has nothing installed.

1. **Manifest:** OS, package managers, apt lock state, held packages, pending reboot, failed systemd units.
2. **apt:** `apt-get update`, re-simulates the upgrade against fresh package lists, then `apt-get upgrade --with-new-pkgs`.
3. **snap:** `snap refresh`.
4. **flatpak:** `flatpak update` for the system-wide installation (per-user installs are left alone).
5. **Journal** (monthly only): trims archived systemd journal files to 500 MB.
6. **topgrade** (only with `--with-topgrade`): pip, cargo, npm and other user-level tools.
7. **Docker** (monthly only, when Docker is running): lists stopped containers, unused images and the build cache, and removes only what you pick; see [Docker](#docker).
8. **Firmware** (when `fwupdmgr` is installed): reports available firmware updates; see [Firmware](#firmware).
9. **Stability gate** (only with `--apply`): a reboot needed for a new kernel, firmware, microcode or dbus (or a reboot flag that names no package), failed systemd units, interrupted dpkg runs, and a `needrestart` report when installed. Library updates such as `libc6` only add a restart recommendation; they do not fail the run.
10. **Update summary** (only with `--apply`).
11. **Result** (every dry run and update run; not for `--help` or usage errors): one-line verdict, a `Next:` or `Recommended:` hint when there is something to do, the warnings logged during the run, the exit code, and the log path.

## Common tasks

```bash
ubuntu-maintain --apply                    # routine update
ubuntu-maintain --mode monthly             # preview the cleanup; changes nothing
ubuntu-maintain --apply --mode monthly     # update + cleanup (see below)
ubuntu-maintain --apply --aggressive       # allow dist-upgrade, which may remove packages
ubuntu-maintain --apply --with-topgrade    # also update user-level tools
ubuntu-maintain --apply --ignore-stability # do not exit 2 for known, unrelated failed units
```

**Monthly mode removes things.** On top of upgrades it runs `apt-get autoremove --purge` and `apt-get clean` (the whole download cache), purges leftover config files of already-removed packages, removes disabled snap revisions and the snap download cache, uninstalls unused flatpak runtimes, trims archived journal files to 500 MB, and removes the [Docker](#docker) items you pick. Run it without `--apply` first: the dry run prints a **cleanup preview** with the packages autoremove would remove and their size, the leftover configs, the cache size, the journal size, and the snap revisions to remove, plus a Docker section with what can be removed.

- **Large autoremoves need `--aggressive`.** If autoremove would remove more than 25 packages, the step is skipped with a warning. Newer apt (3.x, the default on Ubuntu 26.04) removes more than older releases; review the list, then re-run with `--aggressive` to allow it.
- **Packages no repository provides are only reported.** The manifest counts them (`obsolete_packages`), and the monthly preview lists them. These are often deliberate installs (a downloaded `.deb`, software from a removed PPA), so the tool never removes them. `apt list '?obsolete'` shows the full list.

## Options

| Option                     | Effect                                                                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `--apply`                  | Make changes. Without it, everything is a dry run.                                                                                    |
| `--mode daily\|monthly`    | `daily` (default) upgrades only; `monthly` adds the cleanup above.                                                                    |
| `--aggressive`             | Use `apt-get dist-upgrade`, and allow a monthly autoremove of more than 25 packages. Both may remove packages.                        |
| `--manifest-only`          | Print the manifest and exit.                                                                                                          |
| `--with-topgrade`          | Run [topgrade](https://github.com/topgrade-rs/topgrade) after the system package managers.                                            |
| `--continue-on-pm-failure` | Keep going after a snap, flatpak, topgrade, or firmware failure. The exit code still reports it. An apt failure always stops the run. |
| `--ignore-stability`       | Do not exit 2 for failed units, a pending reboot, or dpkg errors.                                                                     |
| `--restart-services`       | Let needrestart restart affected services automatically. Use with care.                                                               |
| `--log-file PATH`          | Write the log to `PATH` instead of the default (see [Logs](#logs)).                                                                   |
| `-h`, `--help`             | Show help.                                                                                                                            |

Setting `UPDATE_APPLY=1` in the environment is the same as `--apply`.

## Exit codes

| Code | Meaning                                                                                                                               |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | Success (a dry run always exits 0)                                                                                                    |
| 2    | Updates finished, but the stability gate found issues (reboot for kernel/firmware/microcode/dbus, failed units, dpkg errors)          |
| 10   | apt phase failed                                                                                                                      |
| 11   | snap phase failed                                                                                                                     |
| 12   | flatpak phase failed                                                                                                                  |
| 13   | topgrade phase failed                                                                                                                 |
| 14   | firmware phase failed (`fwupdmgr update` returned an error)                                                                           |
| 64   | Usage error: unknown option, missing value, sudo missing, sudo authentication failed, or the tool's files are writable by other users |

Exit 2 is deliberate, so scheduled runs do not report an unhealthy system as green. Units that are expected to fail in the current environment (e.g. `tpm-udev` on machines without a TPM, including WSL) are listed separately and do not cause exit 2. See [Troubleshooting](docs/TROUBLESHOOTING.md#stability-gate-exit-2).

## Safety model

- **Dry run by default.** Nothing changes without `--apply`.
- **Never removes packages by default.** Routine runs use `apt-get upgrade --with-new-pkgs`: it installs new dependencies such as a new kernel, but never removes a package. An upgrade that needs a removal stays "kept back" until you run with `--aggressive` (`dist-upgrade`).
- **Cleanup is opt-in, previewed and capped.** Only `--mode monthly` cleans up; its dry run lists what would go; an autoremove of more than 25 packages needs `--aggressive`; packages that no repository provides are never removed.
- **Firmware and Docker removals need your yes.** Firmware is installed, and Docker items are removed, only after a `y` on a terminal, never from a timer. Docker volumes and running containers are never removed.
- **No config prompts.** Upgrades keep locally modified config files (`--force-confdef --force-confold`, the same policy as unattended-upgrades) instead of stopping at a dpkg prompt.
- **Waits for apt locks, never deletes them.** Works alongside `unattended-upgrades` and the `apt-daily` timers.
- **Refuses tampered code.** As root, the tool will not run if any of its own files or folders can be written by other users. A dry run warns about it.
- **Private logs.** Logs are readable only by the user who ran the tool, and a default log path planted by another user is never written to.

## Topgrade (optional)

`ubuntu-maintain` handles the system package managers. [topgrade](https://github.com/topgrade-rs/topgrade) can handle user-level tools (pip, cargo, npm, ...). Install it first (e.g. `cargo install topgrade`), then:

```bash
ubuntu-maintain --apply --with-topgrade
```

topgrade runs as **your** user, not as root, with its system, snap, and flatpak steps disabled so nothing runs twice. It is looked up in your login shell's PATH, so `~/.cargo/bin` works. Run the command from your normal account, not from a root shell. If topgrade is not found, the run prints a warning and skips it.

## Firmware

With `fwupdmgr` (fwupd) installed, every run reports available firmware updates in the manifest and in a Firmware section, which also shows the system firmware version and its release date. Nothing is installed without you:

- With `--apply` on a terminal, the tool lists the devices and new versions and asks `Install N firmware update(s) now? [y/N]`. No answer within 5 minutes counts as no.
- From a timer, cron, or any run without a terminal, it never installs; the Result block recommends `sudo fwupdmgr update`.
- After an install, the Result block recommends a restart: many firmware updates finish on the next boot. fwupd's own battery and power checks stay on.

## Docker

With Docker installed and running, `--mode monthly` adds a Docker section: stopped containers, images that no running container uses, and the build cache, each numbered with the space it frees and a date. Nothing is removed without you:

- The dry run (`ubuntu-maintain --mode monthly`) only lists. If your user cannot reach Docker, it says `run with --apply to list it`.
- `ubuntu-maintain --apply --mode monthly` on a terminal asks `Remove which? Numbers like 1 3 or 2-4, Enter = none:`, repeats your picks, and removes them only after `y`. Enter, `n`, or no answer within 5 minutes removes nothing.
- From a timer, cron, or any run without a terminal, it never removes anything; the Result block recommends a terminal run.
- An image only stopped containers use is marked `(used by stopped 1,2: pick both)`: pick it together with those containers, or it is skipped.
- Never removed here: volumes (listed with their size), running or paused containers and their images, and anything that changed between the list and your `y`.
- Images show their build date (`built`): Docker does not record when an image was last used. Dates before 2000 (reproducible builds) show as `unknown`.
- Sizes are minimums (`at least`): images share layers, so removing several can free more. With Docker's containerd image store they are estimates (`about`).
- Removing a container deletes the files written inside it. A container marked `(restarts when Docker restarts)` is a stopped service that comes back with Docker. The build cache line also covers `RUN --mount=type=cache` contents.
- It talks to the system Docker at `/run/docker.sock` and ignores your Docker CLI settings (contexts, `DOCKER_HOST`). Docker from snap, rootless Docker, Docker Desktop and Podman are not covered.

Messages: [Troubleshooting](docs/TROUBLESHOOTING.md#docker-section-notes-and-warnings).

## Logs

By default the log is `/tmp/ubuntu-maintain.<uid>.log`. After `--apply` that is `/tmp/ubuntu-maintain.0.log`, because the run happens as root. Logs are created with mode `600`. If the default path is a symlink or belongs to another user, the tool logs to a fresh temporary file instead and prints its path.

## Supported systems

Ubuntu 18.04 and later, and Debian. CI tests Ubuntu 20.04, 22.04, 24.04, and 26.04, and Debian 12 and 13: a dry run, then a real `--apply --mode monthly` in a throwaway container for each. 18.04 and 20.04 are past standard support and are best effort; the manifest shows a warning there.

Requires bash 4.4+ and `sudo` (for `--apply`). snap, flatpak, needrestart, fwupd, Docker, and topgrade are optional. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).

## Development

Checks run through [pre-commit](https://pre-commit.com), which downloads pinned versions of shellcheck, prettier and bats itself. Set it up once per clone:

```bash
sudo apt install pre-commit    # Ubuntu 24.04+; older releases: pipx install pre-commit
pre-commit install             # commit: shellcheck, prettier, hygiene; push: bats; message: no Co-Authored-By
pre-commit run --all-files     # run the commit checks on the whole repo
pre-commit run --all-files --hook-stage pre-push   # run the test suite
```

CI (`.github/workflows/ci.yml`) runs the same two `pre-commit` commands, plus a dry run and a real monthly `--apply` in Ubuntu 20.04–26.04 and Debian 12–13 containers. Details: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md#development).

### Repository layout

```text
bin/ubuntu-maintain     CLI entry point
lib/ubuntu-maintain/    modules (probe, manifest, apt, snap, flatpak, journal, topgrade, docker, firmware, stability, summary)
tests/                  bats tests; tests/fixtures/ holds sample tool output
docs/                   requirements, troubleshooting, operational notes (docs/solutions/)
update-script.sh        legacy wrapper, same as `ubuntu-maintain --apply`
.pre-commit-config.yaml pinned quality checks (local hooks and CI)
AGENTS.md               notes for coding agents working on this repo
```

## License

[MIT](LICENSE)
