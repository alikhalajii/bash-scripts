# ubuntu-maintain Troubleshooting

Common issues when running `ubuntu-maintain` or `update-script.sh`. For dependencies and development setup, see [REQUIREMENTS.md](REQUIREMENTS.md).

## `--apply` and sudo

`ubuntu-maintain --apply` (without leading `sudo`) **re-runs itself under sudo** and prompts for your password once. You do not need to prefix the command with `sudo` unless you prefer to.

If `sudo` is not installed or authentication fails, the tool exits with code **64**.

## Log file permission denied

**Symptom:** `tee: /tmp/ubuntu-maintain.<uid>.log: Permission denied` at start of a run.

**Cause:** Usually an old log file owned by another user (e.g. dry-run as UID 1000, then a root-owned process still pointed at `...1000.log`). Current versions pick the log path **after** sudo re-exec (root uses `/tmp/ubuntu-maintain.0.log`).

**Fix:** Remove stale logs or use an explicit writable path:

```bash
rm -f /tmp/ubuntu-maintain.log /tmp/ubuntu-maintain.1000.log
ubuntu-maintain --apply
```

Override with `--log-file PATH` (must be writable by the user running the final process, usually root after `--apply`).

## Command not found

**Symptom:** `ubuntu-maintain: command not found` outside the repo directory.

**Fix:** Add `bin/` to your PATH or symlink the CLI:

```bash
export PATH="/path/to/bash-scripts/bin:$PATH"
# or
ln -sf /path/to/bash-scripts/bin/ubuntu-maintain ~/.local/bin/ubuntu-maintain
```

The script must stay in the repo layout (it loads `lib/ubuntu-maintain/` relative to `bin/`).

## APT phase failed (exit 10)

**Symptom:** `APT phase failed (exit 10)` during `apt-get update` or upgrade.

**Cause:** Almost always a **broken third-party apt source**, not ubuntu-maintain.

### Cursor repo hash mismatch

```bash
sudo rm -f /var/lib/apt/lists/*cursor* /var/lib/apt/lists/partial/*cursor*
sudo apt-get clean && sudo apt-get update
```

If it still fails, disable the repo until the vendor fixes the mirror:

```bash
sudo mv /etc/apt/sources.list.d/cursor.sources /etc/apt/sources.list.d/cursor.sources.disabled
sudo apt-get update && sudo ubuntu-maintain --apply
```

Use a `**.disabled**` suffix (not `.off`) so apt does not warn: `Ignoring file 'cursor.sources.off' … invalid filename extension`.

Re-enable when `apt-get update` succeeds without errors.

## Stability gate exit 2 after updates succeeded

**Symptom:** Apt and/or flatpak completed, then:

```text
Stability gate: issues detected (exit 2)
ubuntu-maintain finished with errors (exit 2).
```

(or the newer message: *Package manager updates completed* + stability warning)

**Cause:** Failed systemd units and/or `/var/run/reboot-required`. The manifest **preflight** `failed_units` count shows this before apply when `systemctl` is available.

**Fix options:**

1. Fix the failed services (e.g. `systemctl status <unit>`, vendor docs).
2. If units are known-broken and unrelated to updates (common: Sophos `sav-protect`, `sav-rms`):

```bash
sudo ubuntu-maintain --apply --ignore-stability
```

Exit **2** is intentional without `--ignore-stability` so automation does not treat an unhealthy system as fully green.

## Dry-run exits non-zero

**Symptom:** `./bin/ubuntu-maintain` exits 1 without `--apply`.

**Checks:**

- Ensure you are on a recent version (probe uses `(systemctl … || true) | wc -l` under `pipefail`).
- Run with `bash -x ./bin/ubuntu-maintain` and note the last command before exit.

Dry-run should exit **0** even when preflight reports failed units; the stability gate runs only with `--apply`.

## Flatpak end-of-life runtime messages

**Symptom:** `Info: org.freedesktop.Platform … is end-of-life` during flatpak update.

**Cause:** Installed apps use an old runtime. Informational from flatpak, not an ubuntu-maintain failure.

**Fix:** Update or remove affected flatpak apps/runtimes (`flatpak list`, `flatpak update` per app) when convenient.

## Making ubuntu-maintain available in every terminal

See [README.md](../README.md#install) — add `bin/` to `PATH` or install a symlink under `~/.local/bin` or `/usr/local/bin`.

## Related docs

- [REQUIREMENTS.md](REQUIREMENTS.md) — Bats, shellcheck, runtime
- [solutions/best-practices/apt-lock-timeout-ubuntu-18-04-24-04.md](solutions/best-practices/apt-lock-timeout-ubuntu-18-04-24-04.md) — apt lock behavior across LTS releases

