---
date: 2026-05-30
topic: ubuntu-update-tool
focus: Audit update-script.sh; general safe multi-PM Ubuntu/Debian updater (18.04–24.04)
mode: repo-grounded
---

# Ideation: General Ubuntu/Debian Update Tool

## Grounding Context

**Codebase context:** Flat repo with a single script, `update-script.sh` (138 lines). Bash with `set -Eeuo pipefail`, tee logging to `/tmp/system-update.log`, modular functions for APT, Snap, and Flatpak.

**Current behavior:**
- APT: lock wait via `fuser`, Edge-specific `fix_apt_sources`, `apt-get update`, **`dist-upgrade` every run**, autoremove/autoclean, purge `rc` packages
- Snap/Flatpak: skipped if binary missing (`command -v`)
- User cleanup: pip/huggingface cache wipe, broken `.desktop` entries

**Gaps vs stated goal (18.04–24.04, safe, stable, installed-PM-only):**
- No `/etc/os-release` branching; unconditional `dist-upgrade` is aggressive for routine runs
- Lock handling may miss `lock-frontend`; no `APT::Lock::Timeout`
- No post-update stability checks (`systemctl --failed`, `/var/run/reboot-required`, needrestart)
- Blind `awk` dedupe of all `.list` files can break valid sources
- Destructive user cache cleanup every run (e.g. Hugging Face)
- No dry-run, no preflight manifest, no per-PM failure policy

**Past learnings:** None in `docs/solutions/`.

**External context:** [Topgrade](https://github.com/topgrade-rs/topgrade) orchestrates many package managers with config, `--dry-run`, and `--only`. Ubuntu 2025 guidance treats `apt full-upgrade` and `dist-upgrade` as synonyms; prefer `full-upgrade` naming on modern releases. `needrestart` can block “non-interactive” apt on 22.04+ unless `NEEDRESTART_MODE` is set. `unattended-upgrades` remains the security baseline on LTS.

## Topic Axes

1. APT/dpkg foundation (locks, upgrade policy, holds, source hygiene)
2. Secondary package managers (snap, flatpak, optional language PMs)
3. Detection & orchestration (installed-only, ordering, release matrix)
4. Post-update stability verification
5. Cleanup & hygiene (non-destructive defaults, cadence)

## Ranked Ideas

### 1. Preflight manifest + dry-run / `--apply`

**Description:** Before mutating anything, build a machine-readable manifest (JSON or YAML): detected PMs, pending upgrades per PM (apt simulate, `snap refresh --list`, `flatpak remote-ls --updates`), lock state, held packages, disk space, `VERSION_ID`, reboot-required flag. Default mode is **dry-run** (print manifest + planned commands); require `--apply` or `UPDATE_APPLY=1` to execute.

**Axis:** Detection & orchestration

**Basis:** `direct:` `update-script.sh` always mutates on run (no preview); `external:` Topgrade supports `--dry-run` and step filtering

**Rationale:** Operators on mixed Ubuntu boxes need to see surprise removals (full-upgrade) and destructive cleanup before they happen; one manifest drives logging, resume, and stability checks.

**Downsides:** Extra implementation for parsers per PM; simulate output differs across 18.04 vs 24.04 apt.

**Confidence:** 88%

**Complexity:** Medium

**Status:** Unexplored

---

### 2. Release-aware APT tier policy

**Description:** Branch APT behavior on `/etc/os-release` `VERSION_ID` and flags: routine default `apt-get upgrade` (or `full-upgrade` when phasing requires it); promote to `dist-upgrade`/`full-upgrade` only with `--aggressive` or detected release-hop. Use `DEBIAN_FRONTEND=noninteractive`, `APT::Lock::Timeout=120`, respect `apt-mark hold`, and prefer `full-upgrade` naming on 22.04+.

**Axis:** APT/dpkg foundation

**Basis:** `direct:` line 70 always runs `dist-upgrade`; `external:` Ubuntu 2025 threads recommend naming `full-upgrade` and reviewing removals

**Rationale:** Same command string behaves differently across 18.04–24.04; a general tool must not equate “daily update” with “always dist-upgrade.”

**Downsides:** Users expecting old script behavior may see fewer package changes until they opt in.

**Confidence:** 90%

**Complexity:** Medium

**Status:** Unexplored

---

### 3. Post-update stability gate

**Description:** After all PM phases, run a bundled check: `dpkg --configure -a` (if needed), `systemctl --failed --no-pager`, `/var/run/reboot-required`, `needrestart` with `NEEDRESTART_MODE=a` (or list-only + log on 22.04+). Exit non-zero on failed units unless `--ignore-stability`. Replace unconditional “✅ success” with a health summary.

**Axis:** Post-update stability verification

**Basis:** `direct:` script ends at line 134 without health checks; `external:` needrestart + reboot-required are standard LTS ops signals

**Rationale:** apt exit 0 ≠ system healthy; especially after full-upgrade and snap refreshes.

**Downsides:** needrestart behavior varies by release; may still prompt in edge configs.

**Confidence:** 85%

**Complexity:** Medium

**Status:** Unexplored

---

### 4. Source sanity validator (replace blind dedupe)

**Description:** Remove global `awk '!seen[$0]++'` over all `.list` files. Validate sources with targeted `apt-get update` error handling: quarantine broken lists to `.list.disabled`, keep Edge/Chrome mismatch fix as one entry in a small “known-bad patterns” list (not hardcoded-only forever). Dedupe only exact duplicate `deb` lines after validation.

**Axis:** APT/dpkg foundation

**Basis:** `direct:` lines 51–57 rewrite all list files; `reasoned:` signed-by/options lines break under blind dedupe

**Rationale:** General tool must not ship machine-specific hacks that risk breaking unrelated apt configs.

**Downsides:** Slower first run; needs careful testing on multi-repo systems.

**Confidence:** 82%

**Complexity:** Medium

**Status:** Unexplored

---

### 5. Installed-PM probe registry (skip empty managers)

**Description:** At startup, probe each PM: apt always on Debian/Ubuntu; snap only if `snap list` works; flatpak only if remotes exist; optional pip/npm/cargo only if binaries exist **and** have managed packages. Skip phases with zero packages. Document optional **Topgrade** for language PMs while bash owns apt safety.

**Axis:** Detection & orchestration

**Basis:** `direct:` snap/flatpak use `command -v` but apt always runs; `external:` Topgrade’s per-tool enable/disable

**Rationale:** “Only update what’s installed” is the core product promise; reduces sudo noise and failure modes.

**Downsides:** Probe logic must stay in sync with new PMs users expect.

**Confidence:** 87%

**Complexity:** Low–Medium

**Status:** Unexplored

---

### 6. PM update DAG (apt → snap → flatpak)

**Description:** Model order as a dependency graph: apt (base libs/repos) → snap → flatpak; parallelize snap+flatpak only after apt succeeds. Fail-fast by default; `--continue-on-pm-failure` for partial success. Log stage boundaries in the shared tee log.

**Axis:** Secondary package managers

**Basis:** `direct:` linear `update_apt` → `update_snap` → `update_flatpak`; `reasoned:` flatpak runtimes may depend on libs updated via apt

**Rationale:** CI-style ordering beats hardcoded sequence when optional PMs are skipped or fail.

**Downsides:** Some sites may prefer flatpak-before-snap; needs config override.

**Confidence:** 80%

**Complexity:** Low

**Status:** Unexplored

---

### 7. Cadence-aware hygiene (daily vs monthly)

**Description:** `--mode=daily` (default): upgrade path only, **no** autoremove/purge, snap revision prune, flatpak `--delete-data`, or huggingface cache wipe. `--mode=monthly`: full hygiene (current script’s cleanup + rc purge) with a “freed X MB” report. Opt-in destructive user cleanup.

**Axis:** Cleanup & hygiene

**Basis:** `direct:` autoremove + aggressive user cleanup every run; `reasoned:` daily destructive hygiene risks ML/dev workflows

**Rationale:** Separates “stay secure/current” from “deep clean,” matching how LTS users actually maintain systems.

**Downsides:** Users must learn two modes; monthly may need calendar reminder/cron hint in docs.

**Confidence:** 86%

**Complexity:** Low

**Status:** Unexplored

---

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Plugin `lib/update.d/` layout | Duplicates manifest + DAG; defer to brainstorm |
| 2 | Canary/lagging fleet profiles | Fleet scope overrun for personal bash-scripts repo |
| 3 | Offline air-gap export/import | High complexity, niche for v1 |
| 4 | Zero-sudo PolicyKit lane | Good v2; v1 should nail elevated path |
| 5 | Security-only unattended track | Overlaps cadence + APT tiers |
| 6 | Standalone “flight deck” restart UX | Merged into stability gate (#3) |
| 7 | Topgrade as full replacement | Use coexistence via probe registry instead |

## Audit notes on `update-script.sh`

| Area | Keep | Change |
|------|------|--------|
| `set -Eeuo pipefail` + tee log | ✓ | Configurable log path |
| `command -v` for snap/flatpak | ✓ | Extend to probe + empty skip |
| `wait_for_apt` | Partial | Add lock-frontend + apt timeouts |
| `fix_apt_sources` | Edge case only | Generalize to source validator |
| `dist-upgrade` always | ✗ | Release-aware tiers |
| User cache wipe | ✗ | Monthly + opt-in |
| Success without checks | ✗ | Stability gate |
