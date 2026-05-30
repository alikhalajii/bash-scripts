---
date: 2026-05-30
title: "feat: Probe-driven ubuntu-maintain tool"
status: completed
type: feat
origin: docs/ideation/2026-05-30-ubuntu-update-tool-ideation.md
---

# feat: Probe-driven ubuntu-maintain tool

## Summary

Implemented `bin/ubuntu-maintain` — a probe-driven, dry-run-by-default Ubuntu/Debian maintainer replacing the unsafe defaults in `update-script.sh`.

## Delivered

- `lib/ubuntu-maintain/` modules: probe, manifest, apt, snap, flatpak, stability, DAG
- `bin/ubuntu-maintain` CLI with `--apply`, `--aggressive`, `--mode`, stability flags
- `update-script.sh` delegates to `ubuntu-maintain --apply`
- `README.md`, `tests/ubuntu-maintain.bats`

## Usage

```bash
./bin/ubuntu-maintain              # dry-run manifest
sudo ./bin/ubuntu-maintain --apply # safe routine update
```
