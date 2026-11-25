#!/usr/bin/env bash
# shellcheck disable=SC2034  # PROXY_* are read by lib/cmd/new.sh, the wizard of the panel (lib/screens/newinst/access.sh) and the tests
# The reverse-proxy block of an instance: the text of an nginx server block or a Caddyfile that puts each service of the instance behind a public
# name. It GENERATES TEXT and saves it inside the instance (instances/<name>/proxy/); it never writes under /etc, never reloads nginx or Caddy
# and never runs a command: the person copies the block where it belongs (docs/server-prerequisites.md says where the proxy comes from).
# Sourced by lib/bootstrap.sh; pure Bash, no fork. Used by `new --domain/--proxy/--tls`, by the access step of the wizard and (later) by the
# access tab of an instance.
#
#   proxy_host_ok <host>               a valid public name (letters, digits, hyphen and dots; labels of at most 63; at most 253 in all)
#   proxy_domain_names <domain> <svc>...   sets PROXY_ENTRIES: one "<host>|<port>|<label>" for each service, the host being <catalog name>.<domain>
#                                       and the port the one in .env.instance when the instance exists (PROXY_PORTS[<svc>] says them otherwise)
#   proxy_render <nginx|caddy> <tls 0|1> <entry>...   the block into PROXY_OUT (and the number of lines in PROXY_LINES); 1 with PROXY_ERR when an
#                                       entry is not valid: NOTHING that was not checked goes into the text
#   proxy_detect                       nginx | caddy | "" : which one this server has (PATH and /usr/sbin)
#   proxy_save <instance> <nginx|caddy> <tls>  writes instances/<instance>/proxy/nginx.conf or Caddyfile (atomically, mode 644: it holds no secret)
#   proxy_file <flavor>                the name of the file of a flavor

PROXY_OUT="" PROXY_LINES=0 PROXY_ERR="" PROXY_ENTRIES=()
declare -gA PROXY_PORTS=()

proxy_host_ok() { # host
  local h="$1" label
  local -a labels=()
  [ -n "$h" ] && [ "${#h}" -le 253 ] || return 1
  [[ "$h" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$h" != .* && "$h" != *. && "$h" != *..* ]] || return 1
  IFS='.' read -ra labels <<< "$h"
  for label in "${labels[@]}"; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
    [[ "$label" != -* && "$label" != *- ]] || return 1
  done
  return 0
}

proxy_port_ok() { # port
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

proxy_file() { # flavor
  case "$1" in nginx) echo "nginx.conf" ;; caddy) echo "Caddyfile" ;; *) return 1 ;; esac
}

proxy_detect() {
  if command -v nginx > /dev/null 2>&1 || [ -x /usr/sbin/nginx ]; then echo nginx
  elif command -v caddy > /dev/null 2>&1 || [ -x /usr/bin/caddy ] || [ -x /usr/local/bin/caddy ]; then echo caddy
  fi
}

# The same into PROXY_DET (nginx | caddy | empty) without starting a process: the panel asks it from its loop.
PROXY_DET=""
proxy_detect_r() {
  PROXY_DET=""
  if command -v nginx > /dev/null 2>&1 || [ -x /usr/sbin/nginx ]; then PROXY_DET=nginx
  elif command -v caddy > /dev/null 2>&1 || [ -x /usr/bin/caddy ] || [ -x /usr/local/bin/caddy ]; then PROXY_DET=caddy
  fi
}

# The entries of a domain: <catalog name>.<domain> for each service. The domain is lowered (names are not case sensitive).
proxy_domain_names() { # domain service...
  local dom="${1,,}" s host port
  shift
  PROXY_ENTRIES=()
  proxy_host_ok "$dom" || return 1
  for s in "$@"; do
    host="${CAT_NAME[$s]:-$s}.$dom"
    port="${PROXY_PORTS[$s]:-}"
    PROXY_ENTRIES+=("$host|$port|$s")
  done
  return 0
}

proxy_nginx() { # tls entry...
  local tls="$1" e host port label
  shift
  PROXY_OUT="# nginx: one server block for each service. Put it in /etc/nginx/conf.d/ (or sites-available) and run: nginx -t && systemctl reload nginx"$'\n'
  PROXY_OUT+="# (deltactl only generates this text: it never writes under /etc and never reloads nginx)"$'\n'
  PROXY_OUT+="map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }"$'\n'
  for e in "$@"; do
    host="${e%%|*}" port="${e#*|}" label="${port#*|}" port="${port%%|*}"
    PROXY_OUT+=$'\n'"# $label"$'\n'
    if [ "$tls" -eq 1 ]; then
      PROXY_OUT+="server {"$'\n'"    listen 80;"$'\n'"    server_name $host;"$'\n'"    return 301 https://\$host\$request_uri;"$'\n'"}"$'\n'
      PROXY_OUT+="server {"$'\n'"    listen 443 ssl;"$'\n'"    server_name $host;"$'\n'
      PROXY_OUT+="    # the certificate: certbot --nginx -d $host"$'\n'
      PROXY_OUT+="    ssl_certificate /etc/letsencrypt/live/$host/fullchain.pem;"$'\n'
      PROXY_OUT+="    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;"$'\n'
    else
      PROXY_OUT+="server {"$'\n'"    listen 80;"$'\n'"    server_name $host;"$'\n'
    fi
    PROXY_OUT+="    location / {"$'\n'"        proxy_pass http://127.0.0.1:$port;"$'\n'"        proxy_http_version 1.1;"$'\n'
    PROXY_OUT+="        proxy_set_header Host \$host;"$'\n'
    PROXY_OUT+="        proxy_set_header X-Real-IP \$remote_addr;"$'\n'
    PROXY_OUT+="        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"$'\n'
    PROXY_OUT+="        proxy_set_header X-Forwarded-Proto \$scheme;"$'\n'
    PROXY_OUT+="        proxy_set_header Upgrade \$http_upgrade;"$'\n'
    PROXY_OUT+="        proxy_set_header Connection \$connection_upgrade;"$'\n'
    PROXY_OUT+="    }"$'\n'"}"$'\n'
  done
}

proxy_caddy() { # tls entry...
  local tls="$1" e host port label
  shift
  PROXY_OUT="# Caddy: one block for each service. Put it in your Caddyfile and run: caddy reload --config /etc/caddy/Caddyfile"$'\n'
  PROXY_OUT+="# (deltactl only generates this text: it never writes under /etc and never reloads Caddy)"$'\n'
  if [ "$tls" -eq 1 ]; then PROXY_OUT+="# Caddy gets and renews the certificates by itself."$'\n'; else PROXY_OUT+="# Without TLS: plain http on port 80."$'\n'; fi
  for e in "$@"; do
    host="${e%%|*}" port="${e#*|}" label="${port#*|}" port="${port%%|*}"
    PROXY_OUT+=$'\n'"# $label"$'\n'
    if [ "$tls" -eq 1 ]; then PROXY_OUT+="$host {"$'\n'; else PROXY_OUT+="http://$host {"$'\n'; fi
    PROXY_OUT+="    reverse_proxy 127.0.0.1:$port"$'\n'"}"$'\n'
  done
}

# The block of a flavor for the entries given (each "<host>|<port>|<label>").
proxy_render() { # flavor tls entry...
  local flavor="$1" tls="$2" e host port label
  shift 2
  PROXY_OUT="" PROXY_LINES=0 PROXY_ERR=""
  case "$flavor" in nginx | caddy) ;; *) PROXY_ERR="flavor"; return 1 ;; esac
  case "$tls" in 0 | 1) ;; *) PROXY_ERR="tls"; return 1 ;; esac
  [ "$#" -gt 0 ] || { PROXY_ERR="empty"; return 1; }
  # Everything that is put into the text is checked first: a name or a port that is not valid is never written (it could close the block or
  # add a directive).
  for e in "$@"; do
    host="${e%%|*}" port="${e#*|}" label="${port#*|}" port="${port%%|*}"
    proxy_host_ok "$host" || { PROXY_ERR="host"; return 1; }
    proxy_port_ok "$port" || { PROXY_ERR="port"; return 1; }
    [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || { PROXY_ERR="label"; return 1; }
  done
  "proxy_$flavor" "$tls" "$@"
  PROXY_LINES="${PROXY_OUT//[^$'\n']/}"
  PROXY_LINES="${#PROXY_LINES}"
  return 0
}

# Saves the block in the instance (never anywhere else). 0 written; 1 the instance does not exist or the arguments are not valid; 2 could not write.
proxy_save() { # instance flavor
  local inst="$1" flavor="$2" dir f tmp
  f="$(proxy_file "$flavor")" || return 1
  valid_instance_name "$inst" || return 1
  dir="$INSTANCES_DIR/$inst"
  [ -d "$dir" ] || return 1
  [ -n "$PROXY_OUT" ] || return 1
  mkdir -p "$dir/proxy" || return 2
  tmp="$(mktemp "$dir/proxy/.$f.XXXXXX")" || return 2
  if ! printf '%s' "$PROXY_OUT" > "$tmp"; then rm -f "$tmp"; return 2; fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$dir/proxy/$f" || { rm -f "$tmp"; return 2; }
  return 0
}

# --- What an instance remembers of its access (instances/<name>/proxy/access.conf) and how it is reached ---------------------------------------
#
#   proxy_meta_save <instance> <domain> <nginx|caddy> <tls 0|1>   writes DOMAIN= FLAVOR= TLS= (atomically, mode 644: no secret in it); 1 invalid
#   proxy_meta_load <instance>         PROXY_M_DOMAIN, PROXY_M_FLAVOR, PROXY_M_TLS from that file; without it, guessed from the block the instance
#                                      already has (`new --domain` writes one): PROXY_M_FROM is file | block | none. No process.
#   proxy_instance_ports <instance> <svc>...   PROXY_PORTS from the S<n>_PORT of .env.instance (no process)
#   proxy_reach <port>                 0 when something listens on 127.0.0.1:<port> (a connection that is closed at once; 2 s at most)
#   proxy_state <instance> <flavor>    PROXY_SAVED: none (no file), same (the file is what would be generated now) or differs; the generated text
#                                      must be in PROXY_OUT
PROXY_M_DOMAIN="" PROXY_M_FLAVOR="" PROXY_M_TLS=1 PROXY_M_FROM=none PROXY_SAVED=none

proxy_meta_save() { # instance domain flavor tls
  local inst="$1" dom="${2,,}" flavor="$3" tls="$4" dir tmp
  valid_instance_name "$inst" || return 1
  proxy_host_ok "$dom" || return 1
  case "$flavor" in nginx | caddy) ;; *) return 1 ;; esac
  case "$tls" in 0 | 1) ;; *) return 1 ;; esac
  dir="$INSTANCES_DIR/$inst"
  [ -d "$dir" ] || return 1
  mkdir -p "$dir/proxy" || return 2
  tmp="$(mktemp "$dir/proxy/.access.conf.XXXXXX")" || return 2
  if ! printf 'DOMAIN=%s\nFLAVOR=%s\nTLS=%s\n' "$dom" "$flavor" "$tls" > "$tmp"; then rm -f "$tmp"; return 2; fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$dir/proxy/access.conf" || { rm -f "$tmp"; return 2; }
  return 0
}

proxy_meta_load() { # instance
  local inst="$1" dir line host=""
  PROXY_M_DOMAIN="" PROXY_M_FLAVOR="" PROXY_M_TLS=1 PROXY_M_FROM=none
  valid_instance_name "$inst" || return 1
  dir="$INSTANCES_DIR/$inst/proxy"
  if [ -r "$dir/access.conf" ]; then
    { while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        DOMAIN=*) if proxy_host_ok "${line#DOMAIN=}"; then PROXY_M_DOMAIN="${line#DOMAIN=}"; fi ;;
        FLAVOR=nginx | FLAVOR=caddy) PROXY_M_FLAVOR="${line#FLAVOR=}" ;;
        TLS=0 | TLS=1) PROXY_M_TLS="${line#TLS=}" ;;
      esac
    done < "$dir/access.conf"; } 2> /dev/null || true
    PROXY_M_FROM="file"
    return 0
  fi
  # No file: what `new --domain` left. The host of a service is <name>.<domain>: the domain is what follows its first label.
  if [ -r "$dir/nginx.conf" ]; then
    { while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^[[:space:]]*server_name[[:space:]]+([a-z0-9.-]+)\;[[:space:]]*$ ]] || continue
      host="${BASH_REMATCH[1]}"
      PROXY_M_TLS=0
      break
    done < "$dir/nginx.conf"; } 2> /dev/null || true
    if [ -n "$host" ] && proxy_host_ok "${host#*.}"; then
      PROXY_M_DOMAIN="${host#*.}" PROXY_M_FLAVOR=nginx PROXY_M_FROM=block
      { while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == *"listen 443"* ]] && { PROXY_M_TLS=1; break; }
      done < "$dir/nginx.conf"; } 2> /dev/null || true
      return 0
    fi
  fi
  host=""
  if [ -r "$dir/Caddyfile" ]; then
    { while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^(http://)?([a-z0-9.-]+)[[:space:]]*\{[[:space:]]*$ ]] || continue
      host="${BASH_REMATCH[2]}" PROXY_M_TLS=1
      [ -z "${BASH_REMATCH[1]}" ] || PROXY_M_TLS=0
      break
    done < "$dir/Caddyfile"; } 2> /dev/null || true
    if [ -n "$host" ] && proxy_host_ok "${host#*.}"; then
      PROXY_M_DOMAIN="${host#*.}" PROXY_M_FLAVOR=caddy PROXY_M_FROM=block
      return 0
    fi
  fi
  PROXY_M_TLS=1
  return 0
}

proxy_instance_ports() { # instance service...
  local inst="$1" s
  shift
  PROXY_PORTS=()
  for s in "$@"; do
    get_var_r "$INSTANCES_DIR/$inst/.env.instance" "${s^^}_PORT"
    PROXY_PORTS[$s]="$GV"
  done
}

proxy_reach() { # port
  proxy_port_ok "$1" || return 2
  timeout 2 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" > /dev/null 2>&1
}

proxy_state() { # instance flavor
  local f path cur
  PROXY_SAVED=none
  f="$(proxy_file "$2")" || return 1
  valid_instance_name "$1" || return 1
  path="$INSTANCES_DIR/$1/proxy/$f"
  [ -r "$path" ] || return 0
  cur="$(< "$path")" 2> /dev/null || cur=""
  if [ "$cur" = "${PROXY_OUT%$'\n'}" ]; then PROXY_SAVED=same; else PROXY_SAVED=differs; fi
  return 0
}
