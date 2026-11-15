#!/usr/bin/env bash
# journal.sh — Journal phase (monthly): trim archived systemd journal files to 500M.
# Provides: um_journal_phase, um_journal_usage_bytes
# Example:  um_journal_phase              # always returns 0; a failed trim is a warning
# Sourced by: common.sh → um_source_libs

# journald's own default cap is up to 4G (10% of the filesystem). Size only, no age limit:
# a quiet system keeps its older logs. --vacuum-size never touches the active journal files.
UM_JOURNAL_CAP="500M"
UM_JOURNAL_CAP_BYTES=$(( 500 * 1024 * 1024 ))

# Bytes used by journal files, from "... take up 1.2G in the file system." Empty on failure.
um_journal_usage_bytes() {
  local out
  out="$(LC_ALL=C journalctl --disk-usage 2>/dev/null)" || return 0
  [[ "$out" =~ take\ up\ ([0-9.]+)([BKMGTPE]) ]] || return 0
  awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[2]}" 'BEGIN {
    m = index("BKMGTPE", u) - 1; v = n; while (m-- > 0) v *= 1024; printf "%.0f\n", int(v)
  }'
}

# Monthly only. Trims when usage is above UM_JOURNAL_CAP; always returns 0.
um_journal_phase() {
  [[ "${UM_MODE}" == "monthly" ]] || return 0
  um_probe_command journalctl || return 0
  um_section "Journal"
  local bytes human scope=""
  bytes="$(um_journal_usage_bytes)"
  if [[ -z "$bytes" ]]; then
    um_log "note: could not read the journal size; skipping the trim"
    return 0
  fi
  human="$(LC_ALL=C journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[BKMGTPE]' | head -1)"
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || scope=" (as seen without root)"
  if [[ "$bytes" -le "$UM_JOURNAL_CAP_BYTES" ]]; then
    um_log "journal: ${human}, under the ${UM_JOURNAL_CAP} cap, nothing to do${scope}"
    return 0
  fi
  if [[ "${UM_APPLY}" -eq 0 ]]; then
    um_log "[dry-run] journal: ${human} in use, would trim archived files to ${UM_JOURNAL_CAP}${scope}"
    return 0
  fi
  um_log "journal: ${human} in use, trimming archived files to ${UM_JOURNAL_CAP}..."
  if ! um_sudo journalctl --vacuum-size="${UM_JOURNAL_CAP}"; then
    um_log "warning: journalctl --vacuum-size=${UM_JOURNAL_CAP} failed; journal left as is"
  fi
  return 0
}
