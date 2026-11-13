---
title: APT lock handling across Ubuntu 18.04–26.04 (DPkg::Lock::Timeout vs fuser poll)
date: 2026-05-30
category: best-practices
module: ubuntu-maintain
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - "Writing bash scripts that run apt-get on multiple Ubuntu LTS releases"
  - "Manifest or logs show lock_wait: fuser_poll on 20.04+ when apt-config probe fails"
  - "Migrating from fuser-only lock waits to release-aware behavior"
tags:
  - apt
  - dpkg
  - ubuntu-18-04
  - ubuntu-24-04
  - lock-frontend
  - bash
  - ubuntu-maintain
related_components:
  - apt_module.sh
  - probe.sh
---

# APT lock handling across Ubuntu 18.04–26.04 (DPkg::Lock::Timeout vs fuser poll)

## Context

`ubuntu-maintain` must update systems from **Ubuntu 18.04 (bionic)** through **24.04 (noble)** without hanging on apt/dpkg locks or assuming a single lock API. The legacy `update-script.sh` polled three lock files with `fuser` only and did not use `lock-frontend` or apt-level timeouts.

Research and implementation (2026) showed that **lock strategy must be probe-driven**, not hardcoded by `VERSION_ID` alone.

## Guidance

### 1. Use `DPkg::Lock::Timeout`, not `APT::Lock::Timeout`

There is **no** documented `APT::Lock::Timeout`. The supported knob is **`DPkg::Lock::Timeout`** (seconds; `-1` = wait indefinitely), available in **apt ≥ 1.9.11** (February 2020).

| Ubuntu | Typical apt | Built-in lock wait via apt           |
| ------ | ----------- | ------------------------------------ |
| 18.04  | 1.6.x       | No — use bounded `fuser`/`lsof` poll |
| 20.04+ | 2.0+        | Yes — pass per invocation            |

Pass timeout on **each** `apt-get` call (do not write system-wide `apt.conf.d` unless the operator opts in):

```bash
apt-get -o DPkg::Lock::Timeout=120 update -y
```

In `ubuntu-maintain`, `um_apt_lock_opts` emits these options only when `apt_lock_timeout_supported=1` from the probe.

### 2. Probe with `apt-config dump`, not version strings alone

`apt-config dump` prints `Key "value";` lines. apt ≥ 1.9.11 ships the knob as a **binary-scoped default**, not as a plain key (key case varies by release):

| Ubuntu | apt    | `apt-config dump \| grep Lock::Timeout`                              |
| ------ | ------ | -------------------------------------------------------------------- |
| 18.04  | 1.6.17 | _(absent)_                                                           |
| 20.04  | 2.0.10 | `Binary::apt::DPkg::Lock::Timeout "120";`                            |
| 22.04  | 2.4.14 | `Binary::apt::DPkg::Lock::Timeout "120";`                            |
| 24.04  | 2.8.3  | `Binary::apt::DPkg::Lock::Timeout "120";` (`binary::` on some hosts) |
| 26.04  | 3.2.1  | `Version::2.0::Dpkg::Lock::Timeout "120";`                           |

(Verified in `ubuntu:<version>` containers, 2026-09-29; 26.04 on a host, 2026-11-07.) The scoped default applies to the `apt` front-end only — `apt-get` defaults to no wait, which is why the option must be passed per call. Its presence is still the support signal. Parse case-insensitively; an operator-set unscoped `DPkg::Lock::Timeout` wins over the scoped default:

```bash
raw="$(apt-config dump 2>/dev/null | awk '
  { k = tolower($1); v = $2; gsub(/[";]/, "", v) }
  k == "dpkg::lock::timeout"              { print v; found = 1; exit }
  k ~ /::dpkg::lock::timeout$/ && s == "" { s = v }
  END { if (!found && s != "") print s }')"
```

If no integer value, set `apt_lock_timeout_supported=0` and `lock_wait_mode=fuser_poll`.

**The key alone is not proof.** `apt-config dump` echoes any key that is set, including one this apt ignores, such as a fleet-wide `DPkg::Lock::Timeout` snippet deployed to 18.04. The probe therefore also requires `apt >= 1.9.11` (`dpkg --compare-versions`) before trusting the key.

**Pitfall (fixed 2026-09-29):** an earlier parser (`awk -F': ' '/^DPkg::Lock::Timeout /'`) never matched the real `Key "value";` format or the scoped key, so **every** release silently fell back to `fuser_poll`. Separately, `um_apt_lock_opts` echoed `-o DPkg::…` as one word; apt stored it as the bogus key `%20DPkg::Lock::Timeout` and ignored it. Emit `-o` and `DPkg::Lock::Timeout=N` as **two** argv words. Both are covered by bats tests; CI asserts `lock_wait: dpkg_timeout` on 20.04–26.04.

### 3. Wait on four lock paths (including `lock-frontend`)

Since Ubuntu 18.04 **dpkg frontend locking**, poll/wait on all four:

- `/var/lib/dpkg/lock`
- `/var/lib/dpkg/lock-frontend`
- `/var/cache/apt/archives/lock`
- `/var/lib/apt/lists/lock`

The old script omitted `lock-frontend`, which can block `apt-get` on modern systems while `fuser` on legacy paths shows clear.

**`DPkg::Lock::Timeout` does not cover the lists lock.** `apt-get update` fails immediately (exit 100, `E: Could not get lock /var/lib/apt/lists/lock`) while `apt-daily.service` refreshes the lists, even with the option set. Verified with a held fcntl lock on apt 2.0.10, 2.4.14, 2.8.3 and 3.2.0 (2026-11-07). `um_apt_update` therefore retries `apt-get update` every 5s, up to the same timeout, but only for that error (matched under `LC_ALL=C`); any other failure returns at once.

### 4. Bounded `fuser` poll on 18.04 (and as fallback)

When `lock_wait_mode=fuser_poll`:

- Use **`um_sudo fuser`** on each path (non-root `fuser` can miss holders).
- If neither `fuser` (psmisc) nor `lsof` is installed (minimal images), holders cannot be detected; log a warning rather than silently treating locks as free.
- Enforce a **max wait** (e.g. 600s from `UM_CAP[apt_lock_timeout]`, default 120 in probe fallback) — unbounded loops hang cron jobs if `apt-daily` holds locks.
- On timeout: log clearly and exit non-zero; **never** `rm` lock files.

### 5. Manifest should expose lock strategy

Include in preflight manifest:

- `lock_wait: dpkg_timeout | fuser_poll`
- `locks_held:` (best-effort; note non-root probes may be incomplete)

## Why This Matters

- **18.04** still appears in the wild (EOL but best-effort support); it cannot use `DPkg::Lock::Timeout`.
- **20.04–26.04** benefit from native apt waiting; redundant infinite `fuser` loops add latency and hide misconfiguration.
- Wrong timeout knob (`APT::Lock::Timeout`) or missing `lock-frontend` produces flaky “works on my machine” update scripts.
- Coexists with `unattended-upgrades` / `apt-daily` — waiting is correct; deleting locks is not.

## When to Apply

- Adding or changing apt phases in `lib/ubuntu-maintain/apt_module.sh` or similar tooling.
- CI asserts `lock_wait: dpkg_timeout` in the 20.04–26.04 containers; keep that assertion when changing the probe.
- Debugging “script stuck waiting for APT” — check lock holder with `sudo lsof` on all four paths.

## Examples

**Manifest on 20.04+ (typical):**

```text
lock_wait: dpkg_timeout
```

**Probe / apply path on 18.04:**

```text
lock_wait: fuser_poll
# um_apt_wait_locks loops with max_wait, then apt-get without -o DPkg::Lock::Timeout
```

**Before (legacy `update-script.sh`):**

```bash
while sudo fuser /var/lib/dpkg/lock ... /var/cache/apt/archives/lock ...; do sleep 3; done
# missing lock-frontend, no max wait, no DPkg::Lock::Timeout
```

**After (`ubuntu-maintain`):**

- `um_probe_apt_config_timeout` → sets `lock_wait_mode`
- `um_apt_lock_opts` → `-o DPkg::Lock::Timeout=N` when supported
- `um_apt_wait_locks` → bounded fuser poll otherwise

## Related

- `lib/ubuntu-maintain/probe.sh` — `um_probe_apt_config_timeout`, `UM_APT_LOCK_PATHS`
- `lib/ubuntu-maintain/apt_module.sh` — `um_apt_lock_opts`, `um_apt_wait_locks`, `um_apt_run`
- `docs/REQUIREMENTS.md` — runtime targets 18.04–24.04
- Implementation: `lib/ubuntu-maintain/apt_module.sh`, `lib/ubuntu-maintain/probe.sh`
