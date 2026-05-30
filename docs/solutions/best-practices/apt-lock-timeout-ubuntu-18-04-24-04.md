---
title: APT lock handling across Ubuntu 18.04–24.04 (DPkg::Lock::Timeout vs fuser poll)
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

# APT lock handling across Ubuntu 18.04–24.04 (DPkg::Lock::Timeout vs fuser poll)

## Context

`ubuntu-maintain` must update systems from **Ubuntu 18.04 (bionic)** through **24.04 (noble)** without hanging on apt/dpkg locks or assuming a single lock API. The legacy `update-script.sh` polled three lock files with `fuser` only and did not use `lock-frontend` or apt-level timeouts.

Research and implementation (2026) showed that **lock strategy must be probe-driven**, not hardcoded by `VERSION_ID` alone.

## Guidance

### 1. Use `DPkg::Lock::Timeout`, not `APT::Lock::Timeout`

There is **no** documented `APT::Lock::Timeout`. The supported knob is **`DPkg::Lock::Timeout`** (seconds; `-1` = wait indefinitely), available in **apt ≥ 1.9.11** (February 2020).

| Ubuntu | Typical apt | Built-in lock wait via apt |
|--------|-------------|----------------------------|
| 18.04 | 1.6.x | No — use bounded `fuser`/`lsof` poll |
| 20.04+ | 2.0+ | Yes — pass per invocation |

Pass timeout on **each** `apt-get` call (do not write system-wide `apt.conf.d` unless the operator opts in):

```bash
apt-get -o DPkg::Lock::Timeout=120 update -y
```

In `ubuntu-maintain`, `um_apt_lock_opts` emits these options only when `apt_lock_timeout_supported=1` from the probe.

### 2. Probe with `apt-config dump`, not version strings alone

Detect support by parsing config, then set `lock_wait_mode`:

```bash
raw="$(apt-config dump 2>/dev/null | awk -F': ' '/^DPkg::Lock::Timeout / {gsub(/ /,"",$2); print $2; exit}')"
```

Fallback: `apt-config shell DPkg::Lock::Timeout`. If no integer value, set `apt_lock_timeout_supported=0` and `lock_wait_mode=fuser_poll`.

On **24.04**, a failed probe (wrong parser) incorrectly forced `fuser_poll` even though `DPkg::Lock::Timeout` exists — fixing the dump parser corrected the manifest.

### 3. Wait on four lock paths (including `lock-frontend`)

Since Ubuntu 18.04 **dpkg frontend locking**, poll/wait on all four:

- `/var/lib/dpkg/lock`
- `/var/lib/dpkg/lock-frontend`
- `/var/cache/apt/archives/lock`
- `/var/lib/apt/lists/lock`

The old script omitted `lock-frontend`, which can block `apt-get` on modern systems while `fuser` on legacy paths shows clear.

### 4. Bounded `fuser` poll on 18.04 (and as fallback)

When `lock_wait_mode=fuser_poll`:

- Use **`um_sudo fuser`** on each path (non-root `fuser` can miss holders).
- Enforce a **max wait** (e.g. 600s from `UM_CAP[apt_lock_timeout]`, default 120 in probe fallback) — unbounded loops hang cron jobs if `apt-daily` holds locks.
- On timeout: log clearly and exit non-zero; **never** `rm` lock files.

### 5. Manifest should expose lock strategy

Include in preflight manifest:

- `lock_wait: dpkg_timeout | fuser_poll`
- `locks_held:` (best-effort; note non-root probes may be incomplete)

## Why This Matters

- **18.04** still appears in the wild (EOL but best-effort support); it cannot use `DPkg::Lock::Timeout`.
- **20.04–24.04** benefit from native apt waiting; redundant infinite `fuser` loops add latency and hide misconfiguration.
- Wrong timeout knob (`APT::Lock::Timeout`) or missing `lock-frontend` produces flaky “works on my machine” update scripts.
- Coexists with `unattended-upgrades` / `apt-daily` — waiting is correct; deleting locks is not.

## When to Apply

- Adding or changing apt phases in `lib/ubuntu-maintain/apt_module.sh` or similar tooling.
- CI matrix tests only check manifest exit code — add version-specific assertions on `lock_wait` when probing in containers.
- Debugging “script stuck waiting for APT” — check lock holder with `sudo lsof` on all four paths.

## Examples

**Probe result on 22.04+ (typical):**

```text
lock_wait: dpkg_timeout
apt_lock_timeout: 120
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
