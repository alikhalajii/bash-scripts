#!/usr/bin/env bash
# docker.sh — Docker phase (monthly): list stopped containers, images and build cache with
#             the space each frees; remove only what the user picks and confirms on a terminal.
# Provides: um_docker_cmd (the only way to call docker), um_docker_bin, um_docker_sock,
#           um_docker_size_bytes, um_docker_fmt_size, um_docker_safe_text, um_docker_json_str
# Example:  um_docker_cmd version --format '{{.Server.Version}}'
# Sourced by: common.sh → um_source_libs

# Field separator in docker --format output; the only PATH docker ever runs with.
[[ -v UM_DK_SEP ]] || readonly UM_DK_SEP=$'\x1f'
[[ -v UM_DK_PATH ]] || readonly UM_DK_PATH=/usr/sbin:/usr/bin:/sbin:/bin

um_docker_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Print the docker binary: UM_DOCKER_BIN (tests; ignored as root) or docker on UM_DK_PATH.
# Returns 1 if there is none; 2 if it is unsafe to run (owned by someone other than root or
# the current user, or writable by group or others).
um_docker_bin() {
  local bin owner mode
  if ! um_docker_is_root && [[ -n "${UM_DOCKER_BIN:-}" ]]; then
    bin="$UM_DOCKER_BIN"
  else
    bin="$(PATH="$UM_DK_PATH" type -P docker)" || return 1
  fi
  [[ "$bin" == /* && -f "$bin" && -x "$bin" ]] || return 1
  read -r owner mode < <(stat -L -c '%u %a' -- "$bin" 2>/dev/null) || return 1
  [[ "$owner" == 0 || "$owner" == "${EUID:-$(id -u)}" ]] || return 2
  [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 8#022) == 0 )) || return 2
  printf '%s\n' "$bin"
}

# The daemon socket: UM_DOCKER_SOCK (tests; ignored as root) or /run/docker.sock.
um_docker_sock() {
  if ! um_docker_is_root && [[ -n "${UM_DOCKER_SOCK:-}" ]]; then
    printf '%s\n' "$UM_DOCKER_SOCK"
  else
    printf '%s\n' /run/docker.sock
  fi
}

# um_docker_cmd [--slow] ARGS...: run docker ARGS with nothing from the user's setup: a
# fresh empty config dir (removed after), fixed PATH, socket and C locale, stdin /dev/null,
# a time limit (60 s, --slow 300 s). Stdout passes through; on failure the first line of
# docker's error, made safe to print, goes to stderr. Returns docker's exit code (124 on
# timeout; 125 if docker or the config dir is unusable).
um_docker_cmd() {
  local _um_t=60 _um_bin _um_dir _um_rc=0 _um_err=""
  if [[ "${1:-}" == --slow ]]; then _um_t=300; shift; fi
  _um_bin="$(um_docker_bin)" || { printf 'docker program not usable\n' >&2; return 125; }
  # Root: always /tmp (sticky); TMPDIR may point somewhere another user controls.
  if um_docker_is_root; then
    _um_dir="$(mktemp -d /tmp/ubuntu-maintain-docker.XXXXXX)"
  else
    _um_dir="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-maintain-docker.XXXXXX")"
  fi || { printf 'cannot create a temporary directory\n' >&2; return 125; }
  if [[ -L "$_um_dir" || ! -d "$_um_dir" || ! -O "$_um_dir" ]] || ! mkdir "$_um_dir/cfg"; then
    printf 'unsafe temporary directory\n' >&2
    return 125
  fi
  /usr/bin/env -i PATH="$UM_DK_PATH" LC_ALL=C DOCKER_CONFIG="$_um_dir/cfg" \
    DOCKER_HOST="unix://$(um_docker_sock)" \
    /usr/bin/timeout -k 5 "$_um_t" "$_um_bin" "$@" </dev/null 2>"$_um_dir/err" || _um_rc=$?
  if [[ "$_um_rc" -ne 0 ]]; then
    IFS= read -r _um_err < "$_um_dir/err" || true
    [[ "$_um_rc" -eq 124 && -z "$_um_err" ]] && _um_err="no answer within ${_um_t} s"
    um_docker_safe_text "${_um_err:-exit ${_um_rc}}" 160 >&2
  fi
  rm -rf -- "$_um_dir"
  return "$_um_rc"
}

# um_docker_size_bytes STR: Docker's decimal size ("846kB", "120.2MB", "649MB (60%)") as
# bytes. Returns 1 for anything else ("N/A", binary units, too large).
um_docker_size_bytes() {
  local s="${1%% *}" int frac unit mult
  [[ "$s" =~ ^([0-9]{1,12})(\.([0-9]{1,6}))?(B|kB|MB|GB|TB)$ ]] || return 1
  int="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[3]}000000" unit="${BASH_REMATCH[4]}"
  case "$unit" in
    B) mult=1 ;; kB) mult=1000 ;; MB) mult=1000000 ;; GB) mult=1000000000 ;; *) mult=1000000000000 ;;
  esac
  (( 10#$int <= 9000000000000000000 / mult )) || return 1
  printf '%s\n' "$(( 10#$int * mult + 10#${frac:0:6} * mult / 1000000 ))"
}

# um_docker_fmt_size BYTES: "0 B", "846 kB", "120 MB", "1.2 GB", "12 GB" (one decimal only
# for GB/TB below 10; rounded half to even, like printf %.1f).
um_docker_fmt_size() {
  local b="$1" i=0 div=1 step q r
  local -a units=(B kB MB GB TB)
  [[ "$b" =~ ^[0-9]{1,18}$ ]] || { printf '?\n'; return 1; }
  b=$((10#$b))
  while (( i < 4 && b >= div * 1000 )); do div=$((div * 1000)); i=$((i + 1)); done
  step="$div"
  (( i >= 3 && b < div * 10 )) && step=$((div / 10))   # count in tenths
  q=$((b / step)) r=$((b % step))
  if (( r * 2 > step || (r * 2 == step && q % 2 == 1) )); then q=$((q + 1)); fi
  if (( step != div )); then
    if (( q < 100 )); then printf '%d.%d %s\n' "$((q / 10))" "$((q % 10))" "${units[i]}"
    else printf '%d %s\n' "$((q / 10))" "${units[i]}"; fi            # 9.96 -> 10
  elif (( q >= 1000 && i < 4 )); then                                   # 999.6 MB -> 1.0 GB
    i=$((i + 1))
    if (( i >= 3 )); then printf '1.0 %s\n' "${units[i]}"; else printf '1 %s\n' "${units[i]}"; fi
  else
    printf '%d %s\n' "$q" "${units[i]}"
  fi
}

# um_docker_safe_text STR MAX: STR with every byte outside printable ASCII as "?"; longer
# than MAX bytes is shortened in the middle so the end stays visible ("abc...6e239a").
um_docker_safe_text() {
  local LC_ALL=C s="$1" max="$2"
  s="${s//[^ -~]/?}"
  if (( ${#s} > max )); then
    if (( max >= 10 )); then s="${s:0:max-9}...${s: -6}"; else s="${s:0:max}"; fi
  fi
  printf '%s\n' "$s"
}

# um_docker_json_str STR: decode one Go {{json}} string ("..."). \" \\ \/ and  -~
# are decoded; every other escape and every non-ASCII byte becomes "?". Returns 1 if STR is
# not exactly one JSON string.
um_docker_json_str() {
  local LC_ALL=C s="$1" out="" c h
  [[ ${#s} -ge 2 && "$s" == \"*\" ]] || return 1
  s="${s:1:${#s}-2}"
  if [[ "$s" != *\\* ]]; then
    [[ "$s" != *\"* ]] || return 1
    out="$s"
  else
    while [[ -n "$s" ]]; do
      c="${s:0:1}"
      if [[ "$c" == \\ ]]; then
        c="${s:1:1}"
        case "$c" in
          \" | \\ | /) out+="$c"; s="${s:2}" ;;
          u)
            h="${s:2:4}"
            if [[ "$h" =~ ^00([2-7][0-9a-fA-F])$ && "$h" != 007[fF] ]]; then
              printf -v c "\\x${BASH_REMATCH[1]}"; out+="$c"
            else
              out+='?'
            fi
            s="${s:6}" ;;
          *) out+='?'; s="${s:2}" ;;
        esac
      elif [[ "$c" == \" ]]; then
        return 1
      else
        out+="$c"; s="${s:1}"
      fi
    done
  fi
  printf '%s\n' "${out//[^ -~]/?}"
}
