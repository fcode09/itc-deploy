#!/usr/bin/env bash
# shellcheck disable=SC2034  # the IC_* tables are read by `images`, `new`, the panel and the tests
# Catalog of image versions: which versions of each service are loaded in this Docker, when they were built, which one is the most recent
# one you may choose, and which instance uses which. Sourced by lib/bootstrap.sh (after lib/core/services.sh); pure Bash.
#
# One query to Docker (`docker image ls`, which carries the creation date) and one more for the architectures of the images it has not met
# (`docker image inspect` of all of them at once). Everything else (dates, versions, order, use) is computed here, without a process.
#
# The rules (the same ones `images`, `new --sN-tag latest` and the panel's version picker use):
#   1. The versions of an image are ordered by CREATION DATE of the image, the newest first. That is a fact Docker knows; a tag is only a name.
#   2. The star (★) is the newest one that (a) is a STABLE version (its tag looks like 1.2.3, v1.2.3, 2026.11.3 or 1.2; one with a suffix such as
#      1.2.3-rc1, 1.2.3-debug or 1.2.3-alpine is a version too, and is listed, but never the star) and (b) can run on this server (its
#      architecture is the server's, or one of the two is not known). `latest` and tags that are not versions are NEVER the star: they move,
#      and going back to them is not possible (kind "latest" and "other": ▲ in the screens). With only suffixed tags there is no star.
#   3. If the tags are versions and the order by version disagrees with the order by date (2.13.2 was built after 2.14.0), the star is still
#      the newest by date and the group says so (IC_DISC): usually the old one was rebuilt, and the person should look.
#   4. An image built for another architecture is not an option (IC_OK=0).
#
# What loading leaves (index i is one tag of one image; the groups are service + image name):
#   IC_N                     how many tags
#   IC_SVC IC_REPO IC_TAG IC_ID IC_ARCH IC_SINCE IC_SIZE      as Docker said them (IC_ARCH is ? when it is not known)
#   IC_EPOCH[i]              creation date in seconds since 1970 (0 when Docker gave none)
#   IC_KIND[i]               ver | latest | other
#   IC_VNUM[i] IC_VPRE[i]    the version of a "ver" tag: its dotted numbers and its pre-release ("rc1"), both without the leading v
#   IC_OK[i]                 1 when it can run on this server
#   IC_STAR[i]               1 for the most recent of its group (rule 2)
#   IC_USE[i]                "instance(current) other(previous) ", "" when nobody uses it
#   IC_GROUPS                the groups, "<sN>|<repo>", services in catalog order
#   IC_ORDER[group]          the indexes of the group, the newest first ("3 0 1")
#   IC_STARIDX[group]        the index of the star (-1 when there is none)
#   IC_DISC[group]           "<tag newest by date>|<tag highest by version>" when rule 3 applies
#   IC_SERVER_ARCH           the server's architecture

IC_N=0 IC_SERVER_ARCH=""
IC_SVC=() IC_REPO=() IC_TAG=() IC_ID=() IC_ARCH=() IC_SINCE=() IC_SIZE=() IC_EPOCH=() IC_KIND=() IC_VNUM=() IC_VPRE=() IC_OK=() IC_STAR=() IC_USE=()
IC_GROUPS=()
declare -gA IC_ORDER=() IC_STARIDX=() IC_DISC=() IC_USED=() IC_REPOS=()

# --- Dates -----------------------------------------------------------------------------------------------------------

# A date as Docker writes it ("2026-11-20 10:15:30 -0500 EST", or ISO 8601 "2026-11-20T10:15:30.5Z") into IC_E, in seconds since 1970. Returns
# 1 (and leaves IC_E empty) when the text is not a date or is the "never" date of an image that has none.
IC_E=""
ic_epoch() { # text
  local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)? ?(Z|[+-][0-9]{2}:?[0-9]{2})?'
  local y m d hh mi ss zone off=0 era yoe doy doe days
  IC_E=""
  [[ "$1" =~ $re ]] || return 1
  y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  hh=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]})) zone="${BASH_REMATCH[8]}"
  { [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] && [ "$hh" -le 23 ] && [ "$mi" -le 59 ] && [ "$ss" -le 60 ]; } || return 1
  if [[ "$zone" =~ ^([+-])([0-9]{2}):?([0-9]{2})$ ]]; then
    off=$((10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60))
    [ "${BASH_REMATCH[1]}" = "+" ] || off=$((-off))
  fi
  # Days since 1970 of a civil date (the proleptic Gregorian calendar, integer arithmetic only).
  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then doy=$(((153 * (m - 3) + 2) / 5 + d - 1)); else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  days=$((era * 146097 + doe - 719468))
  IC_E=$((days * 86400 + hh * 3600 + mi * 60 + ss - off))
  [ "$IC_E" -gt 0 ] || { IC_E=""; return 1; }
}

# Seconds since 1970 as "2026-11-20T15:15:30Z" (UTC) into IC_S; empty when it is not a positive number.
IC_S=""
ic_iso() { # epoch
  local e="$1" days secs z era doe yoe y doy mp d m
  IC_S=""
  [[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -gt 0 ] || return 1
  days=$((e / 86400)) secs=$((e % 86400))
  z=$((days + 719468))
  era=$((z / 146097))
  doe=$((z - era * 146097))
  yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
  y=$((yoe + era * 400))
  doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  mp=$(((5 * doy + 2) / 153))
  d=$((doy - (153 * mp + 2) / 5 + 1))
  if [ "$mp" -lt 10 ]; then m=$((mp + 3)); else m=$((mp - 9)); fi
  if [ "$m" -le 2 ]; then y=$((y + 1)); fi
  printf -v IC_S '%04d-%02d-%02dT%02d:%02d:%02dZ' "$y" "$m" "$d" $((secs / 3600)) $((secs % 3600 / 60)) $((secs % 60))
}

# How long ago an epoch was, as a count and a unit into IC_AGO_N and IC_AGO_U (min, hour, day, month, year; "now" under a minute). Months
# are 30 days and years 365: it is a label, not a calendar. Empty when the date is not known.
IC_AGO_N="" IC_AGO_U=""
ic_ago() { # epoch [now]
  local e="$1" now="${2:-}" s
  IC_AGO_N="" IC_AGO_U=""
  [[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -gt 0 ] || return 1
  [ -n "$now" ] || printf -v now '%(%s)T' -1
  s=$((now - e))
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 60 ]; then IC_AGO_U=now IC_AGO_N=0
  elif [ "$s" -lt 3600 ]; then IC_AGO_U=min IC_AGO_N=$((s / 60))
  elif [ "$s" -lt 86400 ]; then IC_AGO_U=hour IC_AGO_N=$((s / 3600))
  elif [ "$s" -lt 2592000 ]; then IC_AGO_U=day IC_AGO_N=$((s / 86400))
  elif [ "$s" -lt 31536000 ]; then IC_AGO_U=month IC_AGO_N=$((s / 2592000))
  else IC_AGO_U=year IC_AGO_N=$((s / 31536000)); fi
}

# The same, as a sentence in the UI language into IC_AGO_T (for example "2 days ago"); empty when the date is not known.
IC_AGO_T=""
ic_ago_text() { # epoch [now]
  local k
  IC_AGO_T=""
  ic_ago "$@" || return 1
  k="images.ago.$IC_AGO_U"
  if [ "$IC_AGO_U" = day ] || [ "$IC_AGO_U" = month ] || [ "$IC_AGO_U" = year ]; then
    [ "$IC_AGO_N" -eq 1 ] && k+=.1 || k+=.n
  fi
  t_r "$k" "$IC_AGO_N"
  IC_AGO_T="$T_OUT"
}

# --- Versions --------------------------------------------------------------------------------------------------------

# Does a tag look like a version? 1.2.3, v1.2.3, 2026.11.3, 1.2, 7, 1.2.3-rc1. Leaves the dotted numbers in IC_VN and the pre-release in IC_VP.
IC_VN="" IC_VP=""
ic_version() { # tag
  local re='^v?([0-9]{1,15}(\.[0-9]{1,15})*)(-([0-9A-Za-z][0-9A-Za-z.-]*))?$'
  IC_VN="" IC_VP=""
  [[ "$1" =~ $re ]] || return 1
  IC_VN="${BASH_REMATCH[1]}" IC_VP="${BASH_REMATCH[4]}"
}

# Compares two pre-releases the way semver does, into IC_CMP: field by field (they are separated by dots); two numbers compare as numbers
# (rc.10 > rc.9), two words by their bytes (never by the collation of the language of the user: RC2 < rc1), a number is lower than a word, and
# when the first fields are the same the one with more fields is higher (rc.1 < rc.1.1).
ic_precmp() { # pre_a pre_b
  local LC_ALL=C
  local -a a b
  local n i x y
  IC_CMP=0
  IFS=. read -ra a <<< "$1"
  IFS=. read -ra b <<< "$2"
  n="${#a[@]}"
  [ "${#b[@]}" -ge "$n" ] || n="${#b[@]}"   # the fields both have
  for ((i = 0; i < n; i++)); do
    x="${a[$i]}" y="${b[$i]}"
    [ "$x" != "$y" ] || continue
    if [[ "$x" =~ ^[0-9]+$ ]] && [[ "$y" =~ ^[0-9]+$ ]]; then
      while [[ "$x" == 0?* ]]; do x="${x#0}"; done
      while [[ "$y" == 0?* ]]; do y="${y#0}"; done
      if [ "${#x}" -ne "${#y}" ]; then [ "${#x}" -gt "${#y}" ] && IC_CMP=1 || IC_CMP=-1; return 0; fi
      [ "$x" != "$y" ] || continue
    elif [[ "$x" =~ ^[0-9]+$ ]]; then IC_CMP=-1; return 0
    elif [[ "$y" =~ ^[0-9]+$ ]]; then IC_CMP=1; return 0; fi
    if [[ "$x" > "$y" ]]; then IC_CMP=1; else IC_CMP=-1; fi
    return 0
  done
  if [ "${#a[@]}" -gt "${#b[@]}" ]; then IC_CMP=1; elif [ "${#a[@]}" -lt "${#b[@]}" ]; then IC_CMP=-1; fi
  return 0
}

# Compares two versions (dotted numbers, then pre-release) into IC_CMP: 1 when the first is higher, -1 when lower, 0 when they are the same.
# Numbers are compared as numbers (1.2.10 > 1.2.9), a missing number is 0 (1.2 = 1.2.0) and a pre-release is lower than the release (1.2.3-rc1 <
# 1.2.3); two pre-releases compare as ic_precmp says.
IC_CMP=0
ic_vcmp() { # numbers_a pre_a numbers_b pre_b
  local -a a b
  local n i x y
  IC_CMP=0
  IFS=. read -ra a <<< "$1"
  IFS=. read -ra b <<< "$3"
  n="${#a[@]}"
  [ "${#b[@]}" -le "$n" ] || n="${#b[@]}"
  for ((i = 0; i < n; i++)); do
    x=$((10#${a[$i]:-0})) y=$((10#${b[$i]:-0}))
    if [ "$x" -gt "$y" ]; then IC_CMP=1; return 0; fi
    if [ "$x" -lt "$y" ]; then IC_CMP=-1; return 0; fi
  done
  if [ -z "$2" ] && [ -n "$4" ]; then IC_CMP=1
  elif [ -n "$2" ] && [ -z "$4" ]; then IC_CMP=-1
  elif [ -n "$2" ]; then ic_precmp "$2" "$4"; fi
  return 0
}

# --- Use by instances ------------------------------------------------------------------------------------------------

# What each instance has deployed: IC_USED["<repo>:<tag>"] = "name(current) name(previous) ", and the image names in use per service
# (the default one plus each instance's own, in IC_REPOS["<sN>"], separated by spaces).
ic_usage_build() {
  local svc f name r cur prev dir
  IC_USED=() IC_REPOS=()
  for svc in "${KNOWN_SERVICES[@]}"; do IC_REPOS[$svc]="$(default_repo "$svc")"; done
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    dir="${f%/.env.instance}"
    name="${dir##*/}"
    for svc in "${KNOWN_SERVICES[@]}"; do
      service_repo_r "$svc" "$name"; r="$SR"
      case " ${IC_REPOS[$svc]} " in *" $r "*) ;; *) IC_REPOS[$svc]+=" $r" ;; esac
      get_var_r "$f" "$(tag_var "$svc")"; cur="$GV"
      get_var_r "$dir/.previous" "$(tag_var "$svc")"; prev="$GV"
      [ -z "$cur" ] || IC_USED["$r:$cur"]+="$name(current) "
      if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then IC_USED["$r:$prev"]+="$name(previous) "; fi
    done
  done
}

# --- Loading ---------------------------------------------------------------------------------------------------------

# Is the tag at index $1 before the one at $2 in a group? Newest first by date; the same date: the higher version; else Docker's own order.
ic_before() { # i j
  local ei="${IC_EPOCH[$1]:-0}" ej="${IC_EPOCH[$2]:-0}"
  if [ "$ei" -ne "$ej" ]; then [ "$ei" -gt "$ej" ]; return; fi
  if [ "${IC_KIND[$1]}" = ver ] && [ "${IC_KIND[$2]}" = ver ]; then
    ic_vcmp "${IC_VNUM[$1]}" "${IC_VPRE[$1]}" "${IC_VNUM[$2]}" "${IC_VPRE[$2]}"
    if [ "$IC_CMP" -ne 0 ]; then [ "$IC_CMP" -gt 0 ]; return; fi
  fi
  [ "$1" -lt "$2" ]
}

# The architectures of the images with ids "sha256:..." or short ones: one inspect for all, "id|arch" lines into IC_ARCH_OF[<12 characters>].
declare -gA IC_ARCH_OF=()
ic_arch_fetch() { # id...
  local line oid oarch
  IC_ARCH_OF=()
  [ "$#" -gt 0 ] || return 0
  while IFS='|' read -r oid oarch; do
    [ -n "$oarch" ] || continue
    oid="${oid#sha256:}"
    IC_ARCH_OF[${oid:0:12}]="$oarch"
  done < <(dk_images_arch "$@")
}

# Reads the catalog from Docker (see the top). Returns 1 when Docker is not there. Every argument "<sN>=<image name>" adds an image the instances
# do not use yet (the one a person is typing in the wizard) to the groups.
ic_load() {
  local extra full tag id since size created svc repo i g j line sid arch star found nxt_done
  local -a raw=() ids=() order=() cand=() nxt=()
  local -A seen=()
  IC_N=0 IC_SVC=() IC_REPO=() IC_TAG=() IC_ID=() IC_ARCH=() IC_SINCE=() IC_SIZE=() IC_EPOCH=() IC_KIND=() IC_VNUM=() IC_VPRE=() IC_OK=() IC_STAR=() IC_USE=()
  IC_GROUPS=() IC_ORDER=() IC_STARIDX=() IC_DISC=()
  dk_ready || return 1
  IC_SERVER_ARCH="$(server_arch)"
  ic_usage_build
  for extra in "$@"; do
    svc="${extra%%=*}" repo="${extra#*=}"
    [ -n "${IC_REPOS[$svc]+x}" ] || continue
    case " ${IC_REPOS[$svc]} " in *" $repo "*) ;; *) IC_REPOS[$svc]+=" $repo" ;; esac
  done
  mapfile -t raw < <(dk_images_detail)
  # The groups, in catalog order: every image name of every service, each with the tags Docker has for it.
  for svc in "${KNOWN_SERVICES[@]}"; do
    for repo in ${IC_REPOS[$svc]}; do
      IC_GROUPS+=("$svc|$repo")
      for line in "${raw[@]}"; do
        IFS='|' read -r full tag id since size created <<< "$line"
        [ -n "$tag" ] && [ "$tag" != "<none>" ] || continue
        case "$full" in "$repo" | */"$repo") ;; *) continue ;; esac
        i="$IC_N"
        IC_SVC[i]="$svc" IC_REPO[i]="$repo" IC_TAG[i]="$tag" IC_ID[i]="$id" IC_SINCE[i]="$since" IC_SIZE[i]="$size"
        if ic_epoch "$created"; then IC_EPOCH[i]="$IC_E"; else IC_EPOCH[i]=0; fi
        if [ "$tag" = latest ]; then IC_KIND[i]=latest IC_VNUM[i]="" IC_VPRE[i]=""
        elif ic_version "$tag"; then IC_KIND[i]=ver IC_VNUM[i]="$IC_VN" IC_VPRE[i]="$IC_VP"
        else IC_KIND[i]=other IC_VNUM[i]="" IC_VPRE[i]=""; fi
        IC_USE[i]="${IC_USED["$repo:$tag"]:-}"
        IC_N=$((IC_N + 1))
        sid="${id#sha256:}"; sid="${sid:0:12}"
        if [ -z "${seen[$sid]:-}" ]; then seen[$sid]=1; ids+=("$id"); fi
      done
    done
  done
  # Architectures: one query for the images; what it does not answer is asked one by one (a Docker that does not take several at once).
  ic_arch_fetch ${ids[@]+"${ids[@]}"}
  for ((i = 0; i < IC_N; i++)); do
    sid="${IC_ID[$i]#sha256:}"; sid="${sid:0:12}"
    arch="${IC_ARCH_OF[$sid]:-}"
    [ -n "$arch" ] || arch="$(dk_image_arch "${IC_REPO[$i]}:${IC_TAG[$i]}")"
    [ -n "$arch" ] || arch='?'
    IC_ARCH[i]="$arch"
    if [ "$arch" != '?' ] && [ -n "$IC_SERVER_ARCH" ] && [ "$arch" != "$IC_SERVER_ARCH" ]; then IC_OK[i]=0; else IC_OK[i]=1; fi
    IC_STAR[i]=0
  done
  # Order, star and discrepancy of each group.
  for g in "${IC_GROUPS[@]}"; do
    order=()
    svc="${g%%|*}" repo="${g#*|}"
    for ((i = 0; i < IC_N; i++)); do
      [ "${IC_SVC[$i]}" = "$svc" ] && [ "${IC_REPO[$i]}" = "$repo" ] || continue
      # Insertion sort: the new one goes before the first that it must precede.
      nxt=() nxt_done=0
      for j in ${order[@]+"${order[@]}"}; do
        if [ "$nxt_done" -eq 0 ] && ic_before "$i" "$j"; then nxt+=("$i"); nxt_done=1; fi
        nxt+=("$j")
      done
      [ "$nxt_done" -eq 1 ] || nxt+=("$i")
      order=("${nxt[@]}")
    done
    IC_ORDER[$g]="${order[*]-}"
    star=-1
    cand=()
    for i in ${order[@]+"${order[@]}"}; do
      # A stable version only: 2.0.0-rc1, 2.14.0-debug or 2.0.0-alpine are listed and can be chosen by hand, but "the most recent version" is
      # never one of them (an instance of a municipality must not be moved to a release candidate or a variant by a date).
      [ "${IC_KIND[$i]}" = ver ] && [ -z "${IC_VPRE[$i]}" ] && [ "${IC_OK[$i]}" -eq 1 ] && [ "${IC_EPOCH[$i]}" -gt 0 ] || continue
      cand+=("$i")
    done
    if [ "${#cand[@]}" -gt 0 ]; then
      star="${cand[0]}"
      IC_STAR[star]=1
      # The highest version among the same candidates; when it is not the star's version, the two orders disagree.
      found="$star"
      for i in "${cand[@]}"; do
        ic_vcmp "${IC_VNUM[$i]}" "${IC_VPRE[$i]}" "${IC_VNUM[$found]}" "${IC_VPRE[$found]}"
        if [ "$IC_CMP" -gt 0 ]; then found="$i"; fi
      done
      ic_vcmp "${IC_VNUM[$found]}" "${IC_VPRE[$found]}" "${IC_VNUM[$star]}" "${IC_VPRE[$star]}"
      if [ "$IC_CMP" -ne 0 ]; then IC_DISC[$g]="${IC_TAG[$star]}|${IC_TAG[$found]}"; fi
    fi
    IC_STARIDX[$g]="$star"
  done
  return 0
}

# The tag `new --sN-tag latest` and the panel offer for a service: the star of its image (the name given, else the service's default) into
# IC_LATEST. Returns 1 with nothing in IC_LATEST when there is none (no versions loaded, none compatible, only `latest`). Needs ic_load.
IC_LATEST=""
ic_latest() { # service [repo]
  local svc="$1" repo="${2:-}" g i
  IC_LATEST=""
  [ -n "$repo" ] || repo="$(default_repo "$svc")" || return 1
  g="$svc|$repo"
  i="${IC_STARIDX[$g]:--1}"
  [ "$i" -ge 0 ] || return 1
  IC_LATEST="${IC_TAG[$i]}"
}

# --- For the version picker (lib/ui/kit/version_picker.sh) -------------------------------------------------------------------

# The records of the picker for a group "<sN>|<image>", newest first, into the array named $2: tag, how long ago (words in the UI language, the
# text of Docker when the date is not known), size, architecture, use ("colorado (current)" with the words in the UI language) and flags (star,
# mutable, foreign). The fields are separated by the unit separator. IC_NOW (seconds since 1970) replaces the clock, for the tests.
ic_picker_rows() { # group array-name
  local -n _pr="$2"
  local i use cur prev flags
  _pr=()
  t_r images.use_current; cur="$T_OUT"
  t_r images.use_previous; prev="$T_OUT"
  for i in ${IC_ORDER[$1]:-}; do
    use="${IC_USE[$i]% }"
    use="${use//(current)/($cur)}"
    use="${use//(previous)/($prev)}"
    if ic_ago_text "${IC_EPOCH[$i]}" "${IC_NOW:-}"; then :; else IC_AGO_T="${IC_SINCE[$i]}"; fi
    flags=""
    [ "${IC_STAR[$i]}" -ne 1 ] || flags+="star,"
    [ "${IC_KIND[$i]}" = ver ] || flags+="mutable,"
    [ "${IC_OK[$i]}" -eq 1 ] || flags+="foreign,"
    _pr+=("${IC_TAG[$i]}"$'\x1f'"$IC_AGO_T"$'\x1f'"${IC_SIZE[$i]}"$'\x1f'"${IC_ARCH[$i]}"$'\x1f'"$use"$'\x1f'"${flags%,}")
  done
}

# The texts of the picker in the UI language into the associative array named $1 (the keys of kit_vpick_text). The two placeholders of the
# message about an architecture stay as {1} and {2}: the picker fills them.
# shellcheck disable=SC2004,SC2154  # the keys of the array are plain words
ic_picker_texts() { # assoc-array-name
  local -n _pt="$1"
  local k
  for k in col_version col_created col_size col_arch col_use unused empty hint_star hint_mutable type_label type_ok type_missing type_bad; do
    t_r "images.pick.$k"; _pt[$k]="$T_OUT"
  done
  t_r images.pick.why_arch "{1}" "{2}"; _pt[why_arch]="$T_OUT"
  t_r images.pick.latest_hint "$UI_S_UP"; _pt[latest_hint]="$T_OUT"
  t_r images.pick.other "$UI_S_ELL"; _pt[other]="$T_OUT"
  t_r images.pick.load "$UI_S_ELL"; _pt[load]="$T_OUT"
}

# The warning of a group whose order by date and by version disagree, into IC_NOTE (empty when they agree).
IC_NOTE=""
ic_note() { # group
  IC_NOTE=""
  [ -z "${IC_DISC[$1]:-}" ] || { t_r images.disc "${IC_DISC[$1]%%|*}" "${IC_DISC[$1]#*|}"; IC_NOTE="$T_OUT"; }
}
