#!/usr/bin/env bash
# shellcheck disable=SC2034  # the E_* and STATUS_* variables are read by the commands that draw the state
# Instance state: what is configured, what runs and what does not match. Sourced by lib/bootstrap.sh.
#
# st_collect asks Docker once for every Compose project; st_eval judges one service of one instance and
# leaves the result in the E_* variables; st_notes turns the mismatch codes into text and next-step hints.
# The status command (and the home screen) only draw what these functions compute.
# It is READ-ONLY: nothing here modifies instances or containers.

# State of the containers indexed by "<project>/<service>". The Compose project is the name of the
# instance, so they are not mixed with other projects of the server.
declare -gA ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
declare -gA ST_PORTS=() HINT_SEEN=()
ST_DOCKER=0
HINTS=()
STATUS_ISSUES=0
STATUS_SERVICES=0
STATUS_INSTANCES=0

# A single query to Docker for all the containers of Compose projects.
st_collect() {
  ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
  ST_DOCKER=0
  dk_ready || return 0
  ST_DOCKER=1
  local -a ids=()
  local proj svc state health image started cname
  mapfile -t ids < <(dk_project_container_ids)
  [ "${#ids[@]}" -gt 0 ] || return 0
  while IFS='|' read -r proj svc state health image started cname; do
    [ -n "$proj" ] && [ -n "$svc" ] || continue
    ST_STATE["$proj/$svc"]="$state"
    ST_HEALTH["$proj/$svc"]="$health"
    ST_CIMAGE["$proj/$svc"]="$image"
    ST_STARTED["$proj/$svc"]="$started"
    ST_CNAME["$proj/$svc"]="${cname#/}"
  done < <(dk_container_rows "${ids[@]}")
}

# Memory and CPU usage of the running containers (takes 1-2 s: only with --stats or in the detail view).
st_collect_stats() {
  ST_STATS=()
  [ "$ST_DOCKER" -eq 1 ] || return 0
  local name mem cpu
  while IFS='|' read -r name mem cpu; do
    [ -n "$name" ] || continue
    ST_STATS["$name"]="${mem// /}|$cpu"
  done < <(dk_stats_rows)
}

# 3725 -> 1h02m
st_duration() { # seconds
  local s="$1" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return 0; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# Seconds elapsed since an ISO 8601 instant (containers report StartedAt in UTC).
st_uptime_secs() { # iso
  local t now
  t="$(date -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  [ "$t" -gt 0 ] && [ "$now" -ge "$t" ] || return 1
  printf '%s' "$((now - t))"
}

# Records a next-step suggestion (without repeating it).
st_hint() { # command reason
  [ -z "${HINT_SEEN[$1]:-}" ] || return 0
  HINT_SEEN["$1"]=1
  HINTS+=("$1|$2")
}

# Active services of an instance, error tolerant (it does not abort the panel if a file is wrong).
ST_ENABLED=()
st_enabled() { # instance
  ST_ENABLED=()
  local raw part
  local -a parts=()
  raw="$(get_var "$(instance_dir "$1")/.env.instance" COMPOSE_PROFILES)"
  IFS=',' read -ra parts <<< "$raw"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part// /}"
    if [ -n "$part" ] && valid_service "$part"; then ST_ENABLED+=("$part"); fi
  done
}

# Image reference that Compose would use for the service (the same rule as the compose files).
st_ref() { # instance service
  local dir reg tag
  dir="$(instance_dir "$1")"
  reg="$(get_var "$dir/.env.instance" REGISTRY)"
  tag="$(get_var "$dir/.env.instance" "$(tag_var "$2")")"
  printf '%s%s:%s' "${reg:+$reg/}" "$(service_repo "$2" "$1")" "$tag"
}

# Tag of a reference "[registry/]name:tag"; empty if it has none.
st_tag_of() {
  local last="${1##*/}"
  case "$last" in *:*) printf '%s' "${last##*:}" ;; *) printf '' ;; esac
}

# Map port -> "instance/service" of the active services, to detect repeated ports.
st_load_ports() {
  ST_PORTS=()
  local f name svc p
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name"
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      p="$(get_var "$f" "${svc^^}_PORT")"
      [ -n "$p" ] || continue
      ST_PORTS["$p"]="${ST_PORTS[$p]:+${ST_PORTS[$p]} }$name/$svc"
    done
  done
}

# Evaluates a row: it leaves the result in the E_* variables.
#   E_KIND/E_TEXT  state (ok|warn|err|dim) and its text     E_CODES  mismatch codes
#   E_CFG/E_RUN/E_DEP/E_PREV  configured, running, deployed and previous tags
#   E_DATA         data state code: init | existing | unseeded (translated only when shown)
E_KIND="" E_TEXT="" E_CODES="" E_CFG="" E_RUN="" E_DEP="" E_PREV="" E_PORT="" E_UP="" E_UPSECS=""
E_DATA="" E_NOTES="" E_REF="" E_HEALTH="" E_STATE=""
st_eval() { # instance service
  local name="$1" svc="$2" dir key f cur_id dep_id owners
  dir="$(instance_dir "$name")"
  f="$dir/.env.instance"
  key="$name/$svc"
  E_KIND="" E_TEXT="" E_CODES="" E_NOTES="" E_UP="" E_UPSECS=""
  E_CFG="$(get_var "$f" "$(tag_var "$svc")")"
  E_PORT="$(get_var "$f" "${svc^^}_PORT")"
  E_DEP="$(get_var "$dir/.deployed" "$(tag_var "$svc")")"
  E_PREV="$(get_var "$dir/.previous" "$(tag_var "$svc")")"
  E_REF="$(st_ref "$name" "$svc")"
  E_STATE="${ST_STATE[$key]:-}"
  E_HEALTH="${ST_HEALTH[$key]:-}"
  E_RUN="-"
  E_DATA="$(data_state "$name")"

  if [ "$ST_DOCKER" -eq 0 ]; then
    E_KIND=warn E_TEXT="$(t status.state.no_docker)"
    return 0
  fi

  if [ -z "$E_STATE" ]; then
    E_KIND=dim E_TEXT="$(t status.state.not_created)"
    E_CODES="not-created"
  else
    local rt
    rt="$(st_tag_of "${ST_CIMAGE[$key]:-}")"
    E_RUN="${rt:-?}"
    case "$E_STATE" in
      running)
        case "$E_HEALTH" in
          healthy) E_KIND=ok E_TEXT=healthy ;;
          starting) E_KIND=warn E_TEXT=starting E_CODES+=" starting" ;;
          unhealthy) E_KIND=err E_TEXT=unhealthy E_CODES+=" unhealthy" ;;
          *) E_KIND=ok E_TEXT=running ;;
        esac
        E_UPSECS="$(st_uptime_secs "${ST_STARTED[$key]:-}" 2>/dev/null || true)"
        E_UP="$(st_duration "$E_UPSECS")"
        ;;
      restarting) E_KIND=err E_TEXT="$(t status.state.restarting)" E_CODES+=" restarting" ;;
      exited | dead) E_KIND=warn E_TEXT="$(t status.state.stopped)" E_CODES+=" stopped" ;;
      *) E_KIND=warn E_TEXT="$E_STATE" E_CODES+=" stopped" ;;
    esac
    # The running tag is not the configured one: a `deploy` is missing.
    if [ -n "$rt" ] && [ -n "$E_CFG" ] && [ "$rt" != "$E_CFG" ]; then
      E_CODES+=" tag-drift"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    fi
  fi

  # Local image: it must exist, and its tag must not have moved to another image since the deploy.
  if uses_local_images "$name" && [ -n "$E_CFG" ]; then
    if ! dk_image_exists "$E_REF"; then
      E_CODES+=" image-missing"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    else
      dep_id="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
      if [ -n "$dep_id" ] && [ "$E_DEP" = "$E_CFG" ]; then
        cur_id="$(dk_image_id "$E_REF")"
        if [ -n "$cur_id" ] && [ "$cur_id" != "$dep_id" ]; then
          E_CODES+=" image-rebuilt"
          [ "$E_KIND" = "err" ] || E_KIND=warn
        fi
      fi
    fi
  fi

  # Port repeated with another instance or service.
  owners=""
  [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
  if [ -n "$owners" ] && [ "$owners" != "$name/$svc" ]; then
    E_CODES+=" port-conflict"
    E_KIND=err
  fi

  E_CODES="${E_CODES# }"
  [ -n "$E_KIND" ] || E_KIND=ok
}

# Readable text of the mismatch codes of the current row (and next-step suggestions).
st_notes() { # instance service
  local name="$1" svc="$2" code notes="" owners
  for code in $E_CODES; do
    case "$code" in
      tag-drift)
        notes+="$(t status.note.drift "$E_CFG" "$E_RUN"); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.drift "$name" "$svc" "$E_RUN" "$E_CFG")"
        ;;
      image-rebuilt)
        notes+="$(t status.note.rebuilt "$E_CFG"); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.rebuilt "$name" "$svc")"
        ;;
      image-missing)
        notes+="$(t status.note.missing "$E_REF"); "
        st_hint "$(t status.hint.load_cmd)" "$(t status.hint.load "$E_REF")"
        ;;
      port-conflict)
        owners=""
        [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
        notes+="$(t status.note.port "$E_PORT" "$owners"); "
        st_hint "$(t status.hint.port_cmd "$name")" "$(t status.hint.port "$E_PORT" "$owners")"
        ;;
      stopped)
        notes+="$(t status.note.stopped); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.stopped "$name" "$svc")"
        ;;
      unhealthy | restarting)
        notes+="$(t status.note.unhealthy); "
        st_hint "./deltactl logs $name $svc" "$(t status.hint.unhealthy "$name" "$svc")"
        ;;
      not-created)
        st_hint "./deltactl deploy $name" "$(t status.hint.not_created "$name")"
        ;;
    esac
  done
  if [ -n "$E_PREV" ] && [ "$E_PREV" != "$E_CFG" ]; then notes+="$(t status.note.previous "$E_PREV"); "; fi
  E_NOTES="${notes%; }"
}

# Hints at instance level (not service level).
st_instance_hints() { # instance
  local name="$1" marker
  marker="$(marker_file "$name")"
  if [ ! -f "$marker" ]; then
    st_hint "./deltactl init $name" "$(t status.hint.no_data "$name")"
  fi
}

# Services that run in the instance but are no longer in COMPOSE_PROFILES.
st_orphans() { # instance
  local name="$1" key svc s found
  for key in "${!ST_STATE[@]}"; do
    [ "${key%%/*}" = "$name" ] || continue
    svc="${key#*/}"
    found=0
    for s in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do [ "$s" = "$svc" ] && found=1; done
    [ "$found" -eq 1 ] && continue
    [ "${ST_STATE[$key]}" = "running" ] || continue
    printf '%s\n' "$svc"
  done
}

st_stats_cells() { # instance service -> "mem|cpu" ("-|-" if the container does not exist)
  local cn="${ST_CNAME[$1/$2]:-}"
  [ -n "$cn" ] || { printf '%s' '-|-'; return 0; }
  printf '%s' "${ST_STATS[$cn]:--|-}"
}
