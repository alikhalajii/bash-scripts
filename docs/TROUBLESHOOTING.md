# Troubleshooting

Common issues when running `ubuntu-maintain`. For dependencies and development setup, see [REQUIREMENTS.md](REQUIREMENTS.md).

## `ubuntu-maintain: command not found`

`bin/` is not on your PATH. Add it, or symlink the command (symlinks are resolved, so the rest of the repo is still found):

```bash
export PATH="/path/to/ubuntu-maintain/bin:$PATH"
# or
ln -s /path/to/ubuntu-maintain/bin/ubuntu-maintain ~/.local/bin/ubuntu-maintain
```

A PATH change in `~/.bashrc` only applies to shells started afterwards. Run `source ~/.bashrc` or open a new terminal.

## sudo: "A terminal is required to authenticate" (exit 64)

`--apply` re-runs the tool under sudo, and sudo needs a terminal to ask for your password. This happens when the tool is started from something without one, such as an editor task, an agent, or a pipe. Run it from a normal terminal.

For scheduled runs, start it as root (for example from root's crontab), so sudo is not needed.

The tool also exits **64** if `sudo` is not installed or the password is wrong.

## APT phase failed (exit 10)

Almost always caused by a **broken third-party apt source**, not by ubuntu-maintain. The `apt-get update` output in the log names the failing source.

If apt's package lists are locked by another process, such as the `apt-daily` timer, the tool retries `apt-get update` for up to 120 seconds before giving up.

**Hash sum mismatch** on one source: clear its cached lists and retry. Replace `<repo>` with the source name from the error:

```bash
sudo rm -f /var/lib/apt/lists/*<repo>* /var/lib/apt/lists/partial/*<repo>*
sudo apt-get clean && sudo apt-get update
```

If it still fails, disable the source until its vendor fixes it, then re-enable it later:

```bash
sudo mv /etc/apt/sources.list.d/<repo>.sources /etc/apt/sources.list.d/<repo>.sources.disabled
```

Use the `.disabled` suffix. Other suffixes such as `.off` make apt warn about an invalid filename extension.

**Packages kept back:** routine runs never remove packages, so an upgrade that needs a removal is held back. Review what it would do with `apt-get -s dist-upgrade`, then re-run with `--aggressive` if that is acceptable.

## Stability gate exit 2

The updates finished, but the system is not healthy:

```text
Stability gate: issues detected (exit 2)
```

The gate reports a pending reboot (`/var/run/reboot-required`), failed systemd units, or a failed `dpkg --configure -a`. The manifest's **preflight health** section shows the first two before you apply.

- **Reboot required:** reboot. On WSL, run `wsl --shutdown` on the host, then reopen the distro.
- **Failed units:** check them with `systemctl status <unit>` and `journalctl -u <unit>`.
- **Known failures unrelated to updates** (for example a third-party agent whose service is broken): add `--ignore-stability`.

Exit 2 is deliberate, so automation does not report an unhealthy system as green.

**Units expected to fail are not counted.** When a unit fails because its precondition is missing, the gate lists it under *"Failed units expected in this environment (can be ignored)"* and does not exit 2. Currently this covers `tpm-udev.path` and `tpm-udev.service` when no `/dev/tpm*` exists (always on WSL, and on VMs without a virtual TPM). To add a case, extend `um_unit_expected_failure` in `lib/ubuntu-maintain/probe.sh`.

## Log file warnings

The default log is `/tmp/ubuntu-maintain.<uid>.log` (`.0.log` after `--apply`). If that path is a symlink or is owned by another user, the tool does not write to it. It logs to a new temporary file and prints a warning with the path. Removing the stale file fixes the warning:

```bash
sudo rm -f /tmp/ubuntu-maintain.0.log
```

With `--log-file PATH`, the path must be writable by the user the run ends up as, which is root after `--apply`. A symlinked `--log-file` path is refused (exit 64).

## Code writable by other users (exit 64)

```text
error: .../lib/ubuntu-maintain/dag.sh is writable by other users; refusing to run as root
```

`--apply` runs the tool's own files as root, so anyone who can edit them could run code as root. Remove group and world write access from the checkout (group write is fine only for your own private group, the Ubuntu default):

```bash
chmod -R go-w ~/.local/share/ubuntu-maintain    # or wherever you cloned it
```

A dry run prints the same problem as a warning.

## topgrade phase failed (exit 13)

- **"requires a non-root invoking user":** topgrade runs as the user who invoked sudo. Run `ubuntu-maintain --apply --with-topgrade` from your normal account, not from a root shell or root's crontab.
- **Any other failure:** run `topgrade` yourself as your user to see the error.

## Dry run exits non-zero

A dry run should always exit 0. If it does not, run it with tracing and note the last command before the exit:

```bash
bash -x ./bin/ubuntu-maintain
```

## Flatpak "end-of-life" messages

`Info: org.freedesktop.Platform … is end-of-life` comes from flatpak itself, not ubuntu-maintain. Installed apps still use an old runtime. Update or remove those apps when convenient (`flatpak list`).

## Related docs

- [REQUIREMENTS.md](REQUIREMENTS.md): runtime and development requirements
- [solutions/best-practices/apt-lock-timeout-ubuntu-18-04-24-04.md](solutions/best-practices/apt-lock-timeout-ubuntu-18-04-24-04.md): how apt lock waiting works across Ubuntu releases
