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
- `fwupdmgr` (fwupd): firmware updates are reported; installed only after a `y` on a terminal.
- `docker` (Docker Engine from a package, not snap): monthly runs list removable Docker items; removed only after a `y` on a terminal.
- `journalctl`: monthly runs trim archived journal files to 500 MB.
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
| push           | the bats suite (`tests/run-tests.sh`, about 90 s)                                                                     |
| commit message | rejects a `Co-Authored-By:` trailer                                                                                   |

Run them by hand:

```bash
pre-commit run --all-files                          # commit checks, whole repo
pre-commit run --all-files --hook-stage pre-push    # test suite
```

prettier may rewrite a file and fail the commit: review the change, `git add` it, and commit again.

To run `tests/run-tests.sh` directly instead, put bats 1.5 or newer on your PATH (`sudo apt install bats` on 24.04+; 22.04 ships 1.2).

The tests do not need root and do not change the system. Their logs and temporary files go to a per-test directory that is removed afterwards, and `/boot` and `/proc` are replaced by empty test folders. `fwupdmgr` is replaced by a stub, so no test talks to the firmware daemon. No test reaches a Docker daemon either: Docker is "not installed" by default, and the Docker tests use a fake `docker` (`tests/fixtures/docker/fake-docker`) that reads small state files.

To repeat CI's container check locally (needs Docker; `--apply` changes only the throwaway container):

```bash
docker run --rm -v "$PWD":/r:ro debian:13 bash -c 'cp -r /r /x && chown -R root:root /x && chmod -R go-w /x && cd /x &&
  apt-get update -qq && ./bin/ubuntu-maintain --apply --mode monthly --ignore-stability'
```

To run the Docker end-to-end test (needs Docker and network on first use):

```bash
tests/e2e/docker-dind.sh 29    # or 28
```

It starts a throwaway docker-in-docker daemon from a pinned `docker:dind` image (about 400 MB, kept for the next run), creates test images and containers inside it, and answers the Docker picker on a pseudo-terminal. It removes only items inside that daemon; your own images, containers and volumes are compared before and after. After about 30 s it prints `e2e (docker 29): ok`.
