#!/usr/bin/env bash
# docker.sh — Docker phase (monthly): list stopped containers, images and build cache with
#             the space each frees; remove only what the user picks and confirms on a terminal.
# Provides: um_docker_cmd (the only way to call docker), um_docker_bin, um_docker_sock,
#           um_docker_size_bytes, um_docker_fmt_size, um_docker_safe_text, um_docker_json_str,
#           um_docker_parse_pick, um_probe_docker, um_docker_collect (fills UM_DK_*)
# Example:  um_docker_cmd version --format '{{.Server.Version}}'
# Sourced by: common.sh → um_source_libs

# Declared in common.sh; repeated here so shellcheck can infer the associative-array type.
declare -gA UM_CAP

# Field separator in docker --format output; the only PATH docker ever runs with. The
# --format strings: fixed fields first, free text last through {{json}} (control
# characters escaped, so a name can never shift the fields). tests/fixtures/docker/
# fake-docker serves exactly these layouts.
# shellcheck disable=SC2034  # TEMP until render/pick/remove use them (Task 7 removes this)
if [[ ! -v UM_DK_SEP ]]; then
  readonly UM_DK_SEP=$'\x1f'
  readonly UM_DK_PATH=/usr/sbin:/usr/bin:/sbin:/bin
  readonly UM_DK_FMT_DF="{{range .Images}}I${UM_DK_SEP}{{.ID}}${UM_DK_SEP}{{.UniqueSize}}${UM_DK_SEP}{{.CreatedAt}}${UM_DK_SEP}{{.Containers}}
{{end}}{{range .Containers}}C${UM_DK_SEP}{{.ID}}${UM_DK_SEP}{{.Size}}
{{end}}{{range .Volumes}}V${UM_DK_SEP}{{.Size}}${UM_DK_SEP}{{.Links}}${UM_DK_SEP}{{json .Name}}
{{end}}"
  readonly UM_DK_FMT_DF_SUM="{{.Type}}${UM_DK_SEP}{{.Reclaimable}}"
  readonly UM_DK_FMT_IMAGES="{{.ID}}${UM_DK_SEP}{{json .Repository}}${UM_DK_SEP}{{json .Tag}}"
  readonly UM_DK_FMT_CT="{{.Id}}${UM_DK_SEP}{{.State.Status}}${UM_DK_SEP}{{.State.StartedAt}}${UM_DK_SEP}{{.State.FinishedAt}}${UM_DK_SEP}{{.Image}}${UM_DK_SEP}{{.HostConfig.RestartPolicy.Name}}${UM_DK_SEP}{{json .Name}}${UM_DK_SEP}{{json (index .Config.Labels \"com.docker.compose.project\")}}${UM_DK_SEP}{{json (index .Config.Labels \"com.docker.compose.oneoff\")}}${UM_DK_SEP}{{json .Config.Image}}"
  readonly UM_DK_FMT_RECHECK="{{.State.Status}}${UM_DK_SEP}{{.State.StartedAt}}${UM_DK_SEP}{{.State.FinishedAt}}"
  readonly UM_DK_FMT_INFO='{{json .DriverStatus}}'
  readonly UM_DK_FMT_IMGID='{{.Id}}'
  readonly UM_DK_FMT_NTAGS='{{len .RepoTags}}'
  readonly UM_DK_RE_IMAGE='^sha256:[0-9a-f]{64}$'
  readonly UM_DK_RE_CONTAINER='^[0-9a-f]{64}$'
  readonly UM_DK_RE_TIME='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2})$'
  readonly UM_DK_RE_REPO='^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?(/[a-z0-9][a-z0-9._-]*)*$'
  readonly UM_DK_RE_TAG='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
  readonly UM_DK_CACHE_NAME='build cache (incl. build-mount caches)'
fi

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

# Print a new private directory (mode 700, ours, not a symlink); the caller removes it.
# Root always uses /tmp (sticky): TMPDIR may point somewhere another user controls.
um_docker_tmpdir() {
  local d
  if um_docker_is_root; then
    d="$(mktemp -d /tmp/ubuntu-maintain-docker.XXXXXX)" || return 1
  else
    d="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-maintain-docker.XXXXXX")" || return 1
  fi
  if [[ -L "$d" || ! -d "$d" || ! -O "$d" ]]; then return 1; fi
  printf '%s\n' "$d"
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
  _um_dir="$(um_docker_tmpdir)" && mkdir "$_um_dir/cfg" \
    || { printf 'cannot create a private temporary directory\n' >&2; return 125; }
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

# um_docker_parse_pick INPUT N: the item numbers in a picker answer ("3 1,2-4") as
# "1 2 3 4" (ascending, unique; empty answer -> empty). Tokens are split on spaces, tabs
# and commas; each must be a number or an ascending range within 1..N, with no leading
# zero. Otherwise prints the first token that is not understood and returns 1.
um_docker_parse_pick() {
  local input="$1" n="$2" tok lo hi i out=""
  local -a toks=() picked=()
  IFS=$' \t,' read -r -a toks <<<"$input"
  for tok in "${toks[@]}"; do
    [[ -n "$tok" ]] || continue
    if [[ "$tok" =~ ^([1-9][0-9]{0,3})(-([1-9][0-9]{0,3}))?$ ]]; then
      lo=$((10#${BASH_REMATCH[1]})) hi="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
      hi=$((10#$hi))
      if (( lo <= hi && hi <= n )); then
        for (( i = lo; i <= hi; i++ )); do picked[i]=1; done
        continue
      fi
    fi
    printf '%s\n' "$tok"
    return 1
  done
  for i in "${!picked[@]}"; do out+="${out:+ }$i"; done
  printf '%s\n' "$out"
}

# um_docker_date STR: "YYYY-MM-DD" from a Docker time ("2026-05-02T09:30:00Z",
# "2026-11-04 22:23:39 +0100 CET"); "unknown" for anything else or a year before 2000
# (reproducible builds use 1970).
um_docker_date() {
  local d="${1:0:10}"
  if [[ "$d" =~ ^([0-9]{4})-[0-9]{2}-[0-9]{2}$ ]] && (( 10#${BASH_REMATCH[1]} >= 2000 )); then
    printf '%s\n' "$d"
  else
    printf 'unknown\n'
  fi
}

um_docker_has_systemd() { [[ -d /run/systemd/system ]]; }

# Running inside a container (Docker, LXC, podman...): a mounted host socket would clean the
# host. WSL reports itself as a container but is a normal machine here.
um_docker_in_container() {
  local v f files="/.dockerenv /run/.containerenv"
  if v="$(systemd-detect-virt -c 2>/dev/null)" && [[ "$v" != wsl ]]; then return 0; fi
  if ! um_docker_is_root && [[ -n "${UM_DOCKER_CONTAINER_FILES:-}" ]]; then
    files="$UM_DOCKER_CONTAINER_FILES"
  fi
  for f in $files; do [[ -e "$f" ]] && return 0; done
  return 1
}

# Sets UM_CAP docker_available (0/1), docker_running (1/0/unknown/n/a), docker_note, and in
# monthly mode with a reachable daemon fills UM_DK_* (um_docker_collect) and the counts
# docker_removable_images / docker_stopped_containers (else n/a). Never starts the daemon:
# with systemd, docker.service must already be active. Run it in the main shell.
um_docker_probe_reset() {
  UM_CAP[docker_available]=0 UM_CAP[docker_running]=n/a UM_CAP[docker_note]=""
  UM_CAP[docker_removable_images]=n/a UM_CAP[docker_stopped_containers]=n/a
}
um_probe_docker() {
  local rc=0 sock i ni=0 nc=0
  um_docker_probe_reset
  um_docker_bin > /dev/null || rc=$?
  if [[ "$rc" -ne 0 && -e "${UM_DOCKER_SNAP_BIN:-/snap/bin/docker}" ]]; then
    UM_CAP[docker_note]="Docker from snap is not supported here"
    return 0
  fi
  [[ "$rc" -ne 1 ]] || return 0
  UM_CAP[docker_available]=1
  if [[ "$rc" -eq 2 ]]; then
    UM_CAP[docker_running]=unknown
    UM_CAP[docker_note]="the docker program is writable by other users; Docker cleanup skipped"
    return 0
  fi
  if um_docker_in_container; then
    UM_CAP[docker_note]="inside a container; Docker cleanup skipped"
    return 0
  fi
  sock="$(um_docker_sock)"
  UM_CAP[docker_running]=0
  if [[ "$sock" == /run/docker.sock ]] && um_docker_has_systemd \
      && ! systemctl is-active --quiet docker.service 2>/dev/null; then
    return 0
  fi
  [[ -S "$sock" ]] || return 0
  if ! um_docker_cmd version --format '{{.Server.Version}}' > /dev/null 2>&1; then
    UM_CAP[docker_running]=unknown
    if um_docker_is_root; then
      UM_CAP[docker_note]="could not read Docker"
    else
      UM_CAP[docker_note]="could not read Docker without root; run with --apply to list it"
    fi
    return 0
  fi
  UM_CAP[docker_running]=1
  [[ "${UM_MODE}" == monthly ]] || return 0
  if um_docker_collect; then
    for i in "${!UM_DK_KIND[@]}"; do
      case "${UM_DK_KIND[i]}" in image) ni=$((ni + 1)) ;; container) nc=$((nc + 1)) ;; esac
    done
    UM_CAP[docker_removable_images]="$ni" UM_CAP[docker_stopped_containers]="$nc"
  else
    UM_CAP[docker_removable_images]=unknown UM_CAP[docker_stopped_containers]=unknown
  fi
}

# Empty every collected list (all 1-based, in display order).
# shellcheck disable=SC2034  # TEMP until render/pick/remove use them (Task 7 removes this)
um_docker_reset() {
  declare -ga UM_DK_KIND=() UM_DK_ID=() UM_DK_BYTES=() UM_DK_DATE=() UM_DK_NAME=() \
    UM_DK_NOTE=() UM_DK_FROM=() UM_DK_NEEDS=() UM_DK_TAGS=() UM_DK_STARTED=() \
    UM_DK_FINISHED=() UM_DK_VOLUMES=() UM_DK_PICKED=()
  declare -g UM_DK_KEPT="" UM_DK_VOLTOTAL="" UM_DK_ABOUT=0 UM_DK_TOTAL=0
}

# Read everything the list needs into files in DIR (one slow `system df -v`). Returns 1 on
# the first failed call; DIR/err then holds docker's error line.
um_docker_read_all() {
  local d="$1" id
  local -a ids=()
  um_docker_cmd --slow system df -v --format "$UM_DK_FMT_DF" > "$d/df" 2> "$d/err" \
    && um_docker_cmd system df --format "$UM_DK_FMT_DF_SUM" > "$d/sum" 2> "$d/err" \
    && um_docker_cmd image ls --no-trunc --format "$UM_DK_FMT_IMAGES" > "$d/images" 2> "$d/err" \
    && um_docker_cmd ps -a --no-trunc -q > "$d/ps" 2> "$d/err" \
    && um_docker_cmd info --format "$UM_DK_FMT_INFO" > "$d/info" 2> "$d/err" || return 1
  while read -r id; do [[ "$id" =~ $UM_DK_RE_CONTAINER ]] && ids+=("$id"); done < "$d/ps"
  : > "$d/ct"
  [[ ${#ids[@]} -eq 0 ]] \
    || um_docker_cmd container inspect --format "$UM_DK_FMT_CT" -- "${ids[@]}" > "$d/ct" 2> "$d/err"
}

um_docker_bad_record() { um_log "warning: Docker: skipped an unreadable record"; }

# Fill the UM_DK_* lists from the daemon (read-only): stopped containers (oldest stop
# first), images no running container uses (largest first), then the build cache; plus
# UM_DK_KEPT, UM_DK_VOLUMES (lines, largest first), UM_DK_VOLTOTAL, UM_DK_ABOUT (1 = sizes
# approximate: containerd image store) and UM_DK_TOTAL (known bytes of all items). Every
# field is validated; a record that fails is skipped with a warning. Returns 1 if a docker
# call fails: the lists stay empty and UM_CAP[docker_note] says why.
# shellcheck disable=SC2034  # TEMP until render/pick/remove use them (Task 7 removes this)
um_docker_collect() {
  local d err="" line k id n b i j name proj tag repo vb vt=0 kept_n=0 kept_b=0
  local -a f=() order=() cs=() is=() vl=()
  local -A img_b=() img_date=() img_tags=() img_bad=() img_seen=() ct_b=() kept_by=()
  local -A c_id=() c_fin=() c_start=() c_img=() c_name=() c_note=() c_from=() c_item=()
  um_docker_reset
  if ! d="$(um_docker_tmpdir)"; then
    UM_CAP[docker_note]="could not read Docker (no private temporary directory)"
    return 1
  fi
  if ! um_docker_read_all "$d"; then
    IFS= read -r err < "$d/err" || true
    UM_CAP[docker_note]="could not read Docker (${err:-no answer})"
    rm -rf -- "$d"
    return 1
  fi

  # Sizes and dates of images and containers; volumes.
  while IFS="$UM_DK_SEP" read -r -a f; do
    case "${f[0]:-}" in
      "") ;;
      I)
        if [[ ${#f[@]} -eq 5 && "${f[1]}" =~ $UM_DK_RE_IMAGE ]] \
            && { [[ "${f[2]}" == N/A ]] || b="$(um_docker_size_bytes "${f[2]}")"; }; then
          [[ "${f[2]}" == N/A ]] && b=""
          img_b[${f[1]}]="$b" img_date[${f[1]}]="$(um_docker_date "${f[3]}")"
        else
          um_docker_bad_record
        fi ;;
      C)
        if [[ ${#f[@]} -eq 3 && "${f[1]}" =~ $UM_DK_RE_CONTAINER ]] \
            && { [[ "${f[2]}" == N/A ]] || b="$(um_docker_size_bytes "${f[2]}")"; }; then
          [[ "${f[2]}" == N/A ]] && b=""
          ct_b[${f[1]}]="$b"
        else
          um_docker_bad_record
        fi ;;
      V)
        if [[ ${#f[@]} -eq 4 && "${f[2]}" =~ ^[0-9]+$ ]] && name="$(um_docker_json_str "${f[3]}")" \
            && { [[ "${f[1]}" == N/A ]] || b="$(um_docker_size_bytes "${f[1]}")"; }; then
          [[ "${f[1]}" == N/A ]] && b=""
          vb="${b:+$(um_docker_fmt_size "$b")}"
          vt=$((vt + ${b:-0}))
          if [[ "${f[2]}" -gt 0 ]]; then k="in use"; else k="not used"; fi
          vl+=("$(printf '%s\t  %6s  %-8s  %s' "${b:--1}" "${vb:-?}" "$k" "$(um_docker_safe_text "$name" 58)")")
        else
          um_docker_bad_record
        fi ;;
      *) um_docker_bad_record ;;
    esac
  done < "$d/df"

  # Tags per image ID, in the order docker lists them.
  while IFS="$UM_DK_SEP" read -r -a f; do
    [[ ${#f[@]} -gt 0 ]] || continue
    id="${f[0]}"
    if [[ ${#f[@]} -ne 3 || ! "$id" =~ $UM_DK_RE_IMAGE ]] \
        || ! repo="$(um_docker_json_str "${f[1]}")" || ! tag="$(um_docker_json_str "${f[2]}")"; then
      um_docker_bad_record
      [[ "$id" =~ $UM_DK_RE_IMAGE ]] && img_bad[$id]=1
      continue
    fi
    [[ -v img_seen[$id] ]] || { img_seen[$id]=1; order+=("$id"); }
    [[ "$repo" == "<none>" || "$tag" == "<none>" ]] && continue
    if [[ "$repo" =~ $UM_DK_RE_REPO && "$tag" =~ $UM_DK_RE_TAG ]]; then
      img_tags[$id]+="${img_tags[$id]:+ }${repo}:${tag}"
    else
      um_docker_bad_record
      img_bad[$id]=1
    fi
  done < "$d/images"

  # Containers: stopped ones become items; any other state keeps its image.
  while IFS="$UM_DK_SEP" read -r -a f; do
    [[ ${#f[@]} -gt 0 ]] || continue
    if [[ ${#f[@]} -ne 10 || ! "${f[0]}" =~ $UM_DK_RE_CONTAINER || ! "${f[1]}" =~ ^[a-z]+$ \
          || ! "${f[2]}" =~ $UM_DK_RE_TIME || ! "${f[3]}" =~ $UM_DK_RE_TIME \
          || ! "${f[4]}" =~ $UM_DK_RE_IMAGE || ! "${f[5]}" =~ ^[a-z-]*$ ]] \
        || ! name="$(um_docker_json_str "${f[6]}")" || ! proj="$(um_docker_json_str "${f[7]}")" \
        || ! k="$(um_docker_json_str "${f[8]}")" || ! tag="$(um_docker_json_str "${f[9]}")"; then
      um_docker_bad_record
      continue
    fi
    id="${f[0]}" name="$(um_docker_safe_text "${name#/}" 200)"
    case "${f[1]}" in
      exited | created | dead) ;;
      *) kept_by[${f[4]}]+="${kept_by[${f[4]}]:+, }$name"; continue ;;
    esac
    c_id[$id]="$id" c_start[$id]="${f[2]}" c_fin[$id]="${f[3]}" c_img[$id]="${f[4]}"
    if [[ "$k" == True ]]; then name+=" [compose run leftover]"
    elif [[ -n "$proj" ]]; then name+=" [compose $(um_docker_safe_text "$proj" 60)]"; fi
    c_name[$id]="$name"
    case "${f[5]}" in always | unless-stopped) c_note[$id]="(restarts when Docker restarts)" ;; esac
    [[ "$tag" =~ $UM_DK_RE_IMAGE ]] && tag="<none> ${tag:7:12}"
    c_from[$id]="$(um_docker_safe_text "$tag" 200)"
  done < "$d/ct"

  # Number the items: containers, oldest stop first ("never run" = zero time sorts first).
  i=0
  while IFS=$'\t' read -r _ id; do cs+=("$id"); done < <(
    for id in "${!c_id[@]}"; do printf '%s|%s\t%s\n' "${c_fin[$id]:0:19}" "${c_name[$id]}" "$id"; done \
      | LC_ALL=C sort)
  for id in "${cs[@]}"; do
    i=$((i + 1)); c_item[$id]="$i"
    UM_DK_KIND[i]=container UM_DK_ID[i]="$id" UM_DK_BYTES[i]="${ct_b[$id]:-}"
    UM_DK_NAME[i]="${c_name[$id]}" UM_DK_NOTE[i]="${c_note[$id]:-}" UM_DK_FROM[i]="${c_from[$id]}"
    UM_DK_STARTED[i]="${c_start[$id]}" UM_DK_FINISHED[i]="${c_fin[$id]}"
    UM_DK_NEEDS[i]="" UM_DK_TAGS[i]=""
    if [[ "${c_start[$id]}" == 0001-* ]]; then UM_DK_DATE[i]="never run"
    elif [[ "${c_fin[$id]}" == 0001-* ]]; then UM_DK_DATE[i]=unknown
    else UM_DK_DATE[i]="$(um_docker_date "${c_fin[$id]}")"; fi
  done

  # Images: those a running container uses are only counted for the Kept line.
  for id in "${order[@]}"; do
    [[ -v img_bad[$id] ]] && continue
    if [[ -v kept_by[$id] ]]; then
      kept_n=$((kept_n + 1)) kept_b=$((kept_b + ${img_b[$id]:-0}))
      continue
    fi
    is+=("$(printf '%s\t%s' "${img_b[$id]:--1}" "$id")")
  done
  while IFS=$'\t' read -r _ id; do
    [[ -n "$id" ]] || continue
    i=$((i + 1))
    UM_DK_KIND[i]=image UM_DK_ID[i]="$id" UM_DK_BYTES[i]="${img_b[$id]:-}"
    UM_DK_DATE[i]="${img_date[$id]:-unknown}" UM_DK_TAGS[i]="${img_tags[$id]:-}"
    if [[ -n "${img_tags[$id]:-}" ]]; then UM_DK_NAME[i]="${img_tags[$id]// /, }"
    else UM_DK_NAME[i]="<none> ${id:7:12}"; fi
    n=""
    for j in "${!c_img[@]}"; do [[ "${c_img[$j]}" == "$id" ]] && n+="${n:+ }${c_item[$j]}"; done
    n="$(tr ' ' '\n' <<<"$n" | sort -n | paste -sd ' ')"
    UM_DK_NEEDS[i]="$n" UM_DK_NOTE[i]="${n:+(used by stopped ${n// /,}: pick both)}"
    UM_DK_FROM[i]="" UM_DK_STARTED[i]="" UM_DK_FINISHED[i]=""
  done < <(((${#is[@]})) && printf '%s\n' "${is[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2)

  # Build cache: one item when something can be freed.
  while IFS="$UM_DK_SEP" read -r -a f; do
    [[ "${f[0]:-}" == "Build Cache" && ${#f[@]} -eq 2 ]] || continue
    if b="$(um_docker_size_bytes "${f[1]}")" && [[ "$b" -gt 0 ]]; then
      i=$((i + 1))
      UM_DK_KIND[i]=cache UM_DK_ID[i]=build-cache UM_DK_BYTES[i]="$b" UM_DK_DATE[i]="-"
      UM_DK_NAME[i]="$UM_DK_CACHE_NAME" UM_DK_NOTE[i]="" UM_DK_FROM[i]="" UM_DK_NEEDS[i]=""
      UM_DK_TAGS[i]="" UM_DK_STARTED[i]="" UM_DK_FINISHED[i]=""
    fi
  done < "$d/sum"

  for j in "${!UM_DK_BYTES[@]}"; do UM_DK_TOTAL=$((UM_DK_TOTAL + ${UM_DK_BYTES[j]:-0})); done
  if [[ "$kept_n" -gt 0 ]]; then
    name=""
    for id in "${!kept_by[@]}"; do
      [[ -v img_seen[$id] && ! -v img_bad[$id] ]] && name+="${name:+, }${kept_by[$id]}"
    done
    if [[ "$kept_n" -eq 1 ]]; then k="1 image"; else k="${kept_n} images"; fi
    if [[ "$name" == *", "* ]]; then j="containers"; else j="container"; fi
    UM_DK_KEPT="$(um_docker_safe_text "Kept: ${k} ($(um_docker_fmt_size "$kept_b")) used by running ${j} ${name}" 80)"
  fi
  j=0
  while IFS=$'\t' read -r _ line; do j=$((j + 1)); UM_DK_VOLUMES[j]="$line"; done < <(
    ((${#vl[@]})) && printf '%s\n' "${vl[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr)
  [[ ${#vl[@]} -eq 0 ]] || UM_DK_VOLTOTAL="$(um_docker_fmt_size "$vt")"
  grep -q 'io\.containerd\.snapshotter' "$d/info" && UM_DK_ABOUT=1
  rm -rf -- "$d"
  return 0
}
