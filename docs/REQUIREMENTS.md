# Requirements

## Running ubuntu-maintain

| Requirement              | Notes                                                                                               |
| ------------------------ | --------------------------------------------------------------------------------------------------- |
| Ubuntu 18.04+ or Debian  | CI tests Ubuntu 20.04, 22.04, 24.04, 26.04. 18.04 and 20.04 are past standard support: best effort. |
| bash 4.4+                | Uses associative arrays.                                                                            |
| apt-get, GNU coreutils   | Present on every Ubuntu/Debian install.                                                             |
| sudo, or running as root | Needed for `--apply` only.                                                                          |

Optional. Each is detected at runtime, and its phase is skipped when it is missing or has nothing installed:

- `snap`, `flatpak`: updated when present.
- `needrestart`: reports services that need a restart; used by `--restart-services`.
- `topgrade`: used by `--with-topgrade`.
- `fuser` or `lsof`: lock polling on 18.04, whose apt cannot wait for locks itself.

## Development

One tool to install: [pre-commit](https://pre-commit.com) 3.2 or newer. Ubuntu 24.04+ ships a recent enough package; on 22.04 (2.17) and older, use pipx. It downloads the pinned checkers from `.pre-commit-config.yaml` on first use, including its own Node for prettier and bats, so nothing else needs installing.

```bash
sudo apt install pre-commit    # or: pipx install pre-commit
pre-commit install             # once per clone: installs the commit, push and commit-message hooks
```

| Stage          | Checks                                                                                                                |
| -------------- | --------------------------------------------------------------------------------------------------------------------- |
| commit         | shellcheck (warnings fail, uses `.shellcheckrc`), prettier for Markdown/YAML, whitespace/EOF/YAML/merge-marker checks |
| push           | the bats suite (`tests/run-tests.sh`, about 40 s)                                                                     |
| commit message | rejects a `Co-Authored-By:` trailer                                                                                   |

Run them by hand:

```bash
pre-commit run --all-files                          # commit checks, whole repo
pre-commit run --all-files --hook-stage pre-push    # test suite
```

prettier may rewrite a file and fail the commit: review the change, `git add` it, and commit again.

To run `tests/run-tests.sh` directly instead, put bats on your PATH (`sudo apt install bats`).

The tests do not need root and do not change the system. Their logs and temporary files go to a per-test directory that is removed afterwards, and `/boot` and `/proc` are replaced by empty test folders.
