# Requirements

## Running ubuntu-maintain

| Requirement | Notes |
| --- | --- |
| Ubuntu 18.04+ or Debian | CI tests Ubuntu 20.04, 22.04, 24.04, 26.04. 18.04 and 20.04 are past standard support: best effort. |
| bash 4.4+ | Uses associative arrays. |
| apt-get, GNU coreutils | Present on every Ubuntu/Debian install. |
| sudo, or running as root | Needed for `--apply` only. |

Optional. Each is detected at runtime, and its phase is skipped when it is missing or has nothing installed:

- `snap`, `flatpak`: updated when present.
- `needrestart`: reports services that need a restart; used by `--restart-services`.
- `topgrade`: used by `--with-topgrade`.
- `fuser` or `lsof`: lock polling on 18.04, whose apt cannot wait for locks itself.

## Development

| Tool | Purpose |
| --- | --- |
| [bats](https://github.com/bats-core/bats-core) | Runs `tests/ubuntu-maintain.bats`. CI uses the Ubuntu package. |
| [shellcheck](https://www.shellcheck.net/) | Static analysis; CI fails on warnings |

Install both from the Ubuntu archive (universe):

```bash
sudo apt install bats shellcheck
```

If the `bats` package is unavailable or too old, install it into `~/.local`:

```bash
curl -fsSL https://github.com/bats-core/bats-core/tarball/v1.11.1 | tar -xz -C /tmp
/tmp/bats-core-*/install.sh "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.bashrc to keep it
```

Run the checks from the repo root:

```bash
./tests/run-tests.sh
shellcheck --severity=warning -x bin/ubuntu-maintain update-script.sh \
  tests/run-tests.sh tests/ubuntu-maintain.bats lib/ubuntu-maintain/*.sh
```

The tests do not need root and do not change the system. Their logs and temporary files go to a per-test directory that is removed afterwards.
