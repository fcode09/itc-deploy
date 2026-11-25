#!/usr/bin/env bash
# shellcheck disable=SC2034  # tables read by the commands, the screens and the tests
# Schema of the environment variables as data. Sourced by lib/bootstrap.sh; requires ROOT. Nothing is read until envschema_load runs.
#
# The table comes from three sources, none of them duplicated here:
#   lib/help/variables.txt (the glossary of `help variable`)  key, file, type, default and description of every variable
#   templates/.env.*.example                                   the example value of each key (and the keys of a service the
#                                                              glossary does not know yet)
#   lib/core/catalog.data / REQUIRED_<SN>                      which variables are required and which ones can be generated
# plus lib/core/envschema.data, which says how to validate each key and whether it is a secret (rules by name, so a new variable
# gets a sensible validator without touching anything).
#
# A variable is identified by "<file>|<KEY>" (`.env.s0|JWT_SECRET`): the same key can live in two files. Validators never put the
# value in the message they leave: a secret must not end up on a screen or in a log through an error text.
#
# Everything is read with `read` and parameter expansion: no `$(...)`, no processes.

ENV_IDS=()   # every variable, in glossary order
declare -gA ENV_KEY=() ENV_FILE=() ENV_TYPE=() ENV_DEFAULT=() ENV_HASDEF=() ENV_DEFNOTE=() ENV_DESC=() ENV_VALIDATOR=() \
  ENV_SECRET=() ENV_GEN=() ENV_REQUIRED=() ENV_EXAMPLE=() ENV_INGLOSSARY=()
ENVSCHEMA_LANG=""
ENVSCHEMA_RULES=()   # the lines of envschema.data, in order

# Result of a validation: EV_RC 0 valid, 1 invalid, 2 valid with a warning; EV_MSG the message (empty when valid).
EV_RC=0
EV_MSG=""

# Files of variables of an instance, in display order: .env.instance and one .env.<sN> per catalog service.
envschema_files() {
  local s
  printf '%s\n' .env.instance
  for s in "${KNOWN_SERVICES[@]}"; do printf '.env.%s\n' "$s"; done
}

# The glossary of the active language (the one `help variable` shows), or the Spanish one when it is not translated.
envschema_glossary() {
  local f="$ROOT/lib/help/variables.txt" lang="${DELTACTL_LANG_ACTIVE:-es}"
  [ "$lang" = "es" ] || [ ! -f "$ROOT/lib/help/$lang/variables.txt" ] || f="$ROOT/lib/help/$lang/variables.txt"
  printf '%s' "$f"
}

# Reads the validation rules once.
envschema_rules_load() {
  local line
  ENVSCHEMA_RULES=()
  [ -r "$ROOT/lib/core/envschema.data" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    ENVSCHEMA_RULES+=("$line")
  done < "$ROOT/lib/core/envschema.data"
}

# Validator and secret flag of a key by the rules: leaves them in ES_VALIDATOR and ES_SECRET.
ES_VALIDATOR="text"
ES_SECRET=0
envschema_classify() { # file key
  local rule pat rest
  ES_VALIDATOR="text"
  ES_SECRET=0
  for rule in "${ENVSCHEMA_RULES[@]}"; do
    pat="${rule%%|*}"
    rest="${rule#*|}"
    if [[ "$pat" == .env.*:* ]]; then
      [ "${pat%%:*}" = "$1" ] || continue
      pat="${pat#*:}"
    fi
    # shellcheck disable=SC2254  # the pattern is a glob on purpose
    case "$2" in
      $pat)
        ES_VALIDATOR="${rest%%|*}"
        ES_SECRET="${rest#*|}"
        return 0
        ;;
    esac
  done
}

# Is the written default a value, or a description ("none", "set by ./deltactl new", "disabled")?
envschema_default_is_note() { # text
  case "${1,,}" in
    '' | ninguno | none | desactivada | disabled | 'lo pone '* | 'set by '*) return 0 ;;
  esac
  [[ "$1" == *'<'* ]]   # a placeholder such as ./instances/<INSTANCE>/data
}

# Adds one variable (or completes it when the glossary and a template both name it).
envschema_add() { # file key
  local id="$1|$2"
  if [ -z "${ENV_KEY[$id]+x}" ]; then
    ENV_IDS+=("$id")
    ENV_KEY[$id]="$2" ENV_FILE[$id]="$1" ENV_TYPE[$id]="opt" ENV_DEFAULT[$id]="" ENV_HASDEF[$id]=0 ENV_DEFNOTE[$id]=""
    ENV_DESC[$id]="" ENV_REQUIRED[$id]=0 ENV_EXAMPLE[$id]="" ENV_INGLOSSARY[$id]=0 ENV_GEN[$id]=""
    envschema_classify "$1" "$2"
    ENV_VALIDATOR[$id]="$ES_VALIDATOR" ENV_SECRET[$id]="$ES_SECRET"
  fi
}

# Reads the glossary: "@ KEY | file | type | default" and the description under it up to the next "@" or a blank line.
envschema_read_glossary() { # file
  local line key file typ def desc="" id=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '#'*) continue ;;
      '@ '*)
        IFS='|' read -r key file typ def <<< "${line#@ }"
        key="${key%"${key##*[![:space:]]}"}"; key="${key#"${key%%[![:space:]]*}"}"
        file="${file%"${file##*[![:space:]]}"}"; file="${file#"${file%%[![:space:]]*}"}"
        typ="${typ%"${typ##*[![:space:]]}"}"; typ="${typ#"${typ%%[![:space:]]*}"}"
        def="${def%"${def##*[![:space:]]}"}"; def="${def#"${def%%[![:space:]]*}"}"
        envschema_add "$file" "$key"
        id="$file|$key"
        ENV_INGLOSSARY[$id]=1
        case "${typ,,}" in
          obligatoria | required) ENV_TYPE[$id]="req" ENV_REQUIRED[$id]=1 ;;
          fija | fixed) ENV_TYPE[$id]="fixed" ;;
          *) ENV_TYPE[$id]="opt" ;;
        esac
        ENV_DESC[$id]=""
        if envschema_default_is_note "$def"; then
          ENV_DEFNOTE[$id]="$def"
        elif [[ "${def,,}" == vac*o || "${def,,}" == empty ]]; then   # the Spanish and English words for "empty": the default is the empty value
          ENV_HASDEF[$id]=1 ENV_DEFAULT[$id]=""
        else
          ENV_HASDEF[$id]=1 ENV_DEFAULT[$id]="$def"
        fi
        ;;
      '')
        id=""
        ;;
      *)
        if [ -n "$id" ]; then
          if [ -n "${ENV_DESC[$id]}" ]; then ENV_DESC[$id]+=" $line"; else ENV_DESC[$id]="$line"; fi
        fi
        ;;
    esac
  done < "$1"
}

# Reads the example values of a template (KEY=value lines; comments and blank lines are skipped). A key the glossary does not
# know is added as optional, so a service that only has a template still has a schema.
envschema_read_template() { # file(.env.x) template-path
  local line key
  [ -r "$2" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    envschema_add "$1" "$key"
    ENV_EXAMPLE["$1|$key"]="${BASH_REMATCH[2]}"
  done < "$2"
}

# Required variables and generators of the services, from the service catalog.
envschema_apply_catalog() {
  local s req kind pair file id
  for s in "${KNOWN_SERVICES[@]}"; do
    file=".env.$s"
    for req in ${CAT_REQUIRED[$s]:-}; do
      id="$file|$req"
      envschema_add "$file" "$req"
      ENV_REQUIRED[$id]=1
      [ "${ENV_TYPE[$id]}" = "fixed" ] || ENV_TYPE[$id]="req"
    done
    for pair in ${CAT_SECRETS[$s]:-}; do
      id="$file|${pair%%:*}"
      kind="${pair#*:}"
      envschema_add "$file" "${pair%%:*}"
      ENV_GEN[$id]="$kind"
      ENV_SECRET[$id]=1
    done
  done
  # The tag and the port of each service are in the glossary; this keeps them required even if a glossary line is missing.
  for s in "${KNOWN_SERVICES[@]}"; do
    for req in "${s^^}_TAG" "${s^^}_PORT"; do
      id=".env.instance|$req"
      envschema_add .env.instance "$req"
      ENV_REQUIRED[$id]=1
      ENV_TYPE[$id]="req"
    done
  done
}

# Does the default of each variable pass its own validator? A default that does not (a description such as "desactivada") is a
# note, not a value to write.
envschema_check_defaults() {
  local id
  for id in "${ENV_IDS[@]}"; do
    [ "${ENV_HASDEF[$id]}" = 1 ] || continue
    [ -n "${ENV_DEFAULT[$id]}" ] || continue
    envschema_validate_r "${ENV_VALIDATOR[$id]}" "${ENV_DEFAULT[$id]}" ""
    if [ "$EV_RC" = 1 ]; then
      ENV_DEFNOTE[$id]="${ENV_DEFAULT[$id]}" ENV_HASDEF[$id]=0 ENV_DEFAULT[$id]=""
    fi
  done
}

# Builds the schema. Idempotent per language: a second call with the same language does nothing.
envschema_load() {
  local s gl lang="${DELTACTL_LANG_ACTIVE:-es}"
  [ "$ENVSCHEMA_LANG" != "$lang" ] || return 0
  ENV_IDS=()
  ENV_KEY=() ENV_FILE=() ENV_TYPE=() ENV_DEFAULT=() ENV_HASDEF=() ENV_DEFNOTE=() ENV_DESC=() ENV_VALIDATOR=() ENV_SECRET=()
  ENV_GEN=() ENV_REQUIRED=() ENV_EXAMPLE=() ENV_INGLOSSARY=()
  envschema_rules_load || return 1
  gl="$(envschema_glossary)"
  if [ -r "$gl" ]; then envschema_read_glossary "$gl"; fi
  envschema_read_template .env.instance "$ROOT/templates/.env.instance.example"
  for s in "${KNOWN_SERVICES[@]}"; do envschema_read_template ".env.$s" "$ROOT/templates/${CAT_TEMPLATE[$s]:-.env.$s.example}"; done
  envschema_apply_catalog
  envschema_check_defaults
  ENVSCHEMA_LANG="$lang"
}

# Forgets the schema (a test, or after changing the language, makes the next envschema_load read it again).
envschema_reset() { ENVSCHEMA_LANG=""; }

# Ids of the variables of one file, in order; with a second argument, only the ones of that type (req|opt|fixed).
envschema_ids_of() { # file [type]
  local id
  for id in "${ENV_IDS[@]}"; do
    [ "${ENV_FILE[$id]}" = "$1" ] || continue
    [ -z "${2:-}" ] || [ "${ENV_TYPE[$id]}" = "$2" ] || continue
    printf '%s\n' "$id"
  done
}

# Files that declare a key, one per line (the same key can be in .env.s0 and .env.s1).
envschema_files_of_key() { # key
  local id
  for id in "${ENV_IDS[@]}"; do
    [ "${ENV_KEY[$id]}" = "$1" ] || continue
    printf '%s\n' "${ENV_FILE[$id]}"
  done
}

# File given by the person ("s0", ".env.s0", "instance") as the name of the file of variables, or nothing when it is not one.
envschema_file_name() { # word
  local w="${1#.env.}" s
  [ "$w" = "instance" ] && { printf '.env.instance'; return 0; }
  for s in "${KNOWN_SERVICES[@]}"; do [ "$w" = "$s" ] && { printf '.env.%s' "$s"; return 0; }; done
  return 1
}

# ---------- validators ----------
# Each one reads $1 (the value) and leaves EV_RC / EV_MSG; none prints the value.

ev_ok() { EV_RC=0 EV_MSG=""; }
ev_fail() { # message-key [args]
  EV_RC=1
  t_r "$@"
  EV_MSG="$T_OUT"
}
ev_warn() { # message-key [args]
  EV_RC=2
  t_r "$@"
  EV_MSG="$T_OUT"
}

ev_text() { ev_ok; }

ev_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ] && { ev_ok; return; }
  ev_fail envschema.err.port
}

ev_int() { [[ "$1" =~ ^[0-9]+$ ]] && { ev_ok; return; }; ev_fail envschema.err.int; }

ev_bool() { [ "$1" = true ] || [ "$1" = false ] && { ev_ok; return; }; ev_fail envschema.err.bool; }

ev_host() {
  local h='^([A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])$'
  [[ "$1" =~ $h ]] && { ev_ok; return; }
  ev_fail envschema.err.host
}

ev_path() { [[ "$1" == *[[:cntrl:]]* ]] && { ev_fail envschema.err.path; return; }; ev_ok; }

ev_memory() {
  local m='^([0-9]+|[0-9]+\.[0-9]+)([bBkKmMgG][bB]?)?$'
  if [[ "$1" =~ $m ]] && [[ "${1%%[!0-9.]*}" =~ [1-9] ]]; then ev_ok; else ev_fail envschema.err.memory; fi
}

ev_tag() {
  local m='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
  if ! [[ "$1" =~ $m ]]; then ev_fail envschema.err.tag; return; fi
  if [ "$1" = latest ]; then ev_warn envschema.warn.tag_latest; else ev_ok; fi
}

ev_image-name() {
  if [[ "$1" != *:* ]] && valid_image_name "$1"; then ev_ok; else ev_fail envschema.err.image; fi
}

ev_instance-name() {
  if ! valid_instance_name "$1"; then ev_fail envschema.err.instance; return; fi
  if [ -n "${EV_INSTANCE:-}" ] && [ "$1" != "$EV_INSTANCE" ]; then ev_fail envschema.err.instance_mismatch "$EV_INSTANCE"; return; fi
  ev_ok
}

ev_services-list() {
  local s seen=" " list
  [ -n "$1" ] || { ev_fail envschema.err.services "${KNOWN_SERVICES[*]}"; return; }
  [[ "$1" != *[[:space:]]* ]] || { ev_fail envschema.err.services "${KNOWN_SERVICES[*]}"; return; }
  IFS=',' read -ra list <<< "$1"
  [ "${#list[@]}" -gt 0 ] && [[ "$1" != *,,* && "$1" != ,* && "$1" != *, ]] || { ev_fail envschema.err.services "${KNOWN_SERVICES[*]}"; return; }
  for s in "${list[@]}"; do
    valid_service "$s" || { ev_fail envschema.err.services_unknown "$s"; return; }
    case "$seen" in *" $s "*) ev_fail envschema.err.services_dup "$s"; return ;; esac
    seen+="$s "
  done
  ev_ok
}

ev_registry() {
  local m='^[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*$'
  { [ -z "$1" ] || [[ "$1" =~ $m ]]; } && { ev_ok; return; }
  ev_fail envschema.err.registry
}

ev_duration() {
  local m='^[0-9]+(ms|s|m|h|d|w|y)?$'
  [[ "$1" =~ $m ]] && { ev_ok; return; }
  ev_fail envschema.err.duration
}

# A reference to another variable, as compose understands it: ${IP_SERVER}:3200
ENVSCHEMA_REF='^\$\{[A-Za-z_][A-Za-z0-9_]*\}(:[0-9]+)?(/.*)?$'

# Public base URL (IP_SERVER): scheme and host, no path, no trailing slash; a port only warns (each service adds its own).
ev_public-url() {
  local m='^https?://([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?$'
  if [[ "$1" =~ $ENVSCHEMA_REF ]]; then ev_ok; return; fi
  if [[ "$1" =~ ^https?://[^/[:space:]]+/$ ]]; then ev_fail envschema.err.trailing_slash; return; fi
  if ! [[ "$1" =~ $m ]]; then ev_fail envschema.err.public_url; return; fi
  [[ "$1" =~ :[0-9]+$ ]] && { ev_warn envschema.warn.url_port; return; }
  ev_ok
}

ev_url() {
  local m='^https?://([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?(/[^[:space:]]*)?$'
  if [[ "$1" =~ $ENVSCHEMA_REF ]]; then ev_ok; return; fi
  if [[ "$1" == */ ]]; then ev_fail envschema.err.trailing_slash; return; fi
  [[ "$1" =~ $m ]] && { ev_ok; return; }
  ev_fail envschema.err.url
}

ev_url-ws() {
  local m='^(https?|wss?)://([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]+)?(/[^[:space:]]*)?$'
  [[ "$1" =~ $m ]] && { ev_ok; return; }
  ev_fail envschema.err.url_ws
}

# mongodb://[user:pass@]host[:port][,host2[:port]]/db[?options] or mongodb+srv://… The host of a replica set can be several; any of
# them being loopback only warns: inside a container, localhost is the container itself.
ev_mongo-uri() {
  local rest auth hosts h hs
  if ! [[ "$1" =~ ^mongodb(\+srv)?://[^[:space:]]+$ ]]; then ev_fail envschema.err.mongo; return; fi
  rest="${1#*://}"
  auth="${rest%%[/?]*}"
  hosts="${auth##*@}"
  [ -n "$hosts" ] || { ev_fail envschema.err.mongo; return; }
  IFS=',' read -ra hs <<< "$hosts"
  for h in "${hs[@]}"; do
    if [[ "$h" == \[* ]]; then h="${h#[}"; h="${h%%]*}"; else h="${h%%:*}"; fi
    case "${h,,}" in localhost | 127.* | ::1) ev_warn envschema.warn.mongo_local; return ;; esac
  done
  ev_ok
}

# base64 of exactly 32 bytes: 43 characters and one "=".
ev_b64-32() {
  local m='^[A-Za-z0-9+/]{43}=$'
  [[ "$1" =~ $m ]] && { ev_ok; return; }
  ev_fail envschema.err.b64
}

ev_secret-path() {
  local m='^/run/secrets/[A-Za-z0-9._-]+$'
  [[ "$1" =~ $m ]] && { ev_ok; return; }
  ev_fail envschema.err.secret_path
}

ev_secret-min32() {
  [ "${#1}" -ge 32 ] && [[ "$1" != *[[:space:]]* ]] && { ev_ok; return; }
  ev_fail envschema.err.min32
}

ev_json-line() {
  case "$1" in
    '['*']' | '{'*'}') ev_ok ;;
    *) ev_fail envschema.err.json ;;
  esac
}

# Validates a value with a validator by name. The empty value is checked by the caller (envschema_check_r), not here.
envschema_validate_r() { # validator value [instance]
  # The classes of the checks ([0-9], [A-Za-z]) mean the same in every locale: in en_US.UTF-8 they match accents and Arabic digits.
  local v="$1" fn LC_ALL=C
  EV_INSTANCE="${3:-}"
  if [[ "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then ev_fail envschema.err.newline; return 0; fi
  fn="ev_$v"
  if declare -F "$fn" > /dev/null; then "$fn" "$2"; else ev_ok; fi
}

# Validates a value for a variable of the schema: the empty value of a required one is an error, a fixed variable does not go in the
# file, an unknown one is reported (EV_RC 1) unless the caller allows it. Leaves EV_RC / EV_MSG.
envschema_check_r() { # file key value [instance]
  local id="$1|$2" v
  envschema_load
  if [ -z "${ENV_KEY[$id]+x}" ]; then ev_fail envschema.err.unknown; return 0; fi
  if [ "${ENV_TYPE[$id]}" = fixed ]; then ev_fail envschema.err.fixed; return 0; fi
  if [ -z "$3" ]; then
    if [ "${ENV_REQUIRED[$id]}" = 1 ]; then ev_fail envschema.err.required; else ev_ok; fi
    return 0
  fi
  v="${ENV_VALIDATOR[$id]}"
  envschema_validate_r "$v" "$3" "${4:-}"
}

# Can the tool generate the value of this variable? Prints the kind (shared, hex32, hex24, b64-32) or nothing.
envschema_generator() { # file key
  envschema_load
  printf '%s' "${ENV_GEN[$1|$2]:-}"
}

# The variables of the glossary and of the catalog that are required and have no default: what an instance must fill in before
# `deploy`. Leaves the ids in ENV_TODO.
ENV_TODO=()
envschema_required_ids() { # file
  local id
  ENV_TODO=()
  for id in "${ENV_IDS[@]}"; do
    [ "${ENV_FILE[$id]}" = "$1" ] && [ "${ENV_REQUIRED[$id]}" = 1 ] && [ "${ENV_TYPE[$id]}" != fixed ] && ENV_TODO+=("$id")
  done
  return 0
}
