#!/usr/bin/env bash
# Docker adapter: the ONLY place that runs the `docker` binary. Commands and core rules call these
# functions, so what the tool asks Docker is visible in one file and tests can replace Docker with a
# simulated binary on the PATH (tests/fake-docker.sh).
# Sourced by lib/bootstrap.sh; requires KNOWN_SERVICES (lib/core/catalog.sh) and ROOT.

# --- Availability ------------------------------------------------------------------------------------
dk_installed() { command -v docker >/dev/null 2>&1; }

# The read-only questions of the server requirements (daemon, versions, network) go through dk_ask: with DK_TIMEOUT set (seconds) a docker
# that does not answer is cut instead of waited for (the checks run in the background of the panel and would be abandoned after a minute,
# leaving the program behind). Empty, as it is for everything else, it is a plain call.
DK_TIMEOUT=""
dk_ask() {
  if [ -n "$DK_TIMEOUT" ] && command -v timeout >/dev/null 2>&1; then timeout -k 1 "$DK_TIMEOUT" docker "$@"; else docker "$@"; fi
}

# The Docker daemon answers.
dk_daemon_ok() { dk_ask info >/dev/null 2>&1; }

# Docker is installed and its daemon answers.
# The panel asks every few seconds: DK_READY_TTL > 0 lets it trust a recent positive answer instead of running `docker info` again.
DK_READY_AT=0 DK_READY_TTL=0
dk_ready() {
  if [ "$DK_READY_TTL" -gt 0 ] && [ "$DK_READY_AT" -gt 0 ] && [ $((SECONDS - DK_READY_AT)) -lt "$DK_READY_TTL" ]; then return 0; fi
  dk_installed && dk_daemon_ok || return 1
  DK_READY_AT="$SECONDS"
}

# The `docker compose` plugin is present.
dk_compose_ok() { docker compose version >/dev/null 2>&1; }

# Compose version without the leading "v" (empty when the plugin is missing).
dk_compose_version() { dk_ask compose version --short 2>/dev/null | sed 's/^v//'; }

# One field of `docker info` (ServerVersion, Architecture, DockerRootDir...). Empty on error.
dk_info() { # Field
  dk_ask info --format "{{.$1}}" 2>/dev/null || true
}

# Architecture of this server in the images' vocabulary (amd64, arm64...).
server_arch() {
  local a
  a="$(dk_info Architecture)"
  case "$a" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) echo "$a" ;;
  esac
}

# Gateway of the default bridge network (how containers reach services on the host).
dk_network_gateway() {
  dk_ask network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true
}

# --- Compose -----------------------------------------------------------------------------------------
# Variables read by the compose files (plus Compose's own that would change what gets deployed). In Compose
# the shell wins over --env-file: if one of them were exported, Docker would use that value while the tool
# validated the one in .env.instance. That is why dk_compose ignores all of them: only .env.instance counts.
compose_shell_vars() {
  local s u
  printf '%s\n' INSTANCE REGISTRY DATA_DIR PULL_POLICY \
    COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR
  for s in "${KNOWN_SERVICES[@]}"; do
    u="${s^^}"
    printf '%s\n' "${u}_IMAGE" "${u}_TAG" "${u}_PORT" "${u}_MEM_LIMIT"
  done
}

# Runs docker compose for an instance, always from the repo root.
# - Variables of compose_shell_vars exported in the shell are ignored (see above).
# - With local images (empty REGISTRY) PULL_POLICY=never is set: if the image is missing, Docker must
#   not pull a same-named image that is not ours from Docker Hub.
dk_compose() { # instance args...
  local name="$1" policy=missing v
  local -a drop=()
  shift
  if uses_local_images "$name"; then policy=never; fi
  while IFS= read -r v; do drop+=("$v"); done < <(compose_shell_vars)
  (cd "$ROOT" && unset "${drop[@]}" \
    && PULL_POLICY="$policy" docker compose --env-file "instances/$name/.env.instance" "$@")
}

# --- Images ------------------------------------------------------------------------------------------
dk_image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

dk_image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

# Architecture of a loaded image (empty if it is not loaded).
dk_image_arch() { docker image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true; }

# Loaded images as "repository|tag|id|created|size|created_at" lines, and as "repository|tag" lines. `created` is Docker's "2 days ago" and
# `created_at` its date ("2026-11-20 10:15:30 +0000 UTC"), last so that what reads the first five fields does not notice it: ONE query gives both.
dk_images_detail() { docker image ls --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{.Size}}|{{.CreatedAt}}'; }
dk_images_tags() { docker image ls --format '{{.Repository}}|{{.Tag}}' 2>/dev/null; }
# "repository|tag|id" for every loaded image in ONE query (the id is the full "sha256:..." one).
dk_images_ids() { docker image ls --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}' 2>/dev/null; }

# "id|architecture" for several images in ONE query (ids or references). What it cannot find, it leaves out.
dk_images_arch() { # id_or_ref...
  docker image inspect --format '{{.Id}}|{{.Architecture}}' "$@" 2>/dev/null || true
}

# Loads an image archive (docker save output, plain or gzip). Prints docker's output; returns its status.
dk_load() { # file
  case "$1" in
    *.gz | *.tgz) gunzip -c -- "$1" | docker load 2>&1 ;;
    *) docker load -i "$1" 2>&1 ;;
  esac
}

# --- Containers --------------------------------------------------------------------------------------
# Runs a command in a one-off container of an image, with the instance's env file and access to the host.
# usage: dk_run_once <env_file> <image_ref> [extra docker-run args...] -- <command...>
dk_run_once() {
  local envf="$1" ref="$2"
  local -a extra=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  shift
  docker run --rm --add-host host.docker.internal:host-gateway --env-file "$envf" \
    ${extra[@]+"${extra[@]}"} "$ref" "$@"
}

# Ids of every container (running or not) that belongs to a Compose project.
dk_project_container_ids() { docker ps -aq --filter label=com.docker.compose.project 2>/dev/null; }

# Ids of the containers (running or not) of one instance: its Compose project is named after it.
dk_instance_container_ids() { # instance
  docker ps -aq --filter "label=com.docker.compose.project=$1" 2>/dev/null
}

# One "project|service|state|health|image|started|name|pid|restarts" row per container id.
dk_container_rows() { # ids...
  docker inspect --format \
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Config.Image}}|{{.State.StartedAt}}|{{.Name}}|{{.State.Pid}}|{{.RestartCount}}' \
    "$@" 2>/dev/null
}

# Stream of container lifecycle events, one action per line (start, die, health_status, ...). It never ends:
# the panel reads it through a coprocess to refresh only when something changes.
dk_events_stream() { # run it in a coprocess: it replaces that process with `docker events`
  exec docker events --since 6h --filter type=container --filter event=start --filter event=die --filter event=stop \
    --filter event=restart --filter event=oom --filter event=destroy --filter event=health_status \
    --format '{{.Time}}|{{.Actor.Attributes.name}}|{{.Action}}' 2>/dev/null
}

# "name|memory|cpu" rows for the running containers (takes 1-2 s).
dk_stats_rows() { docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' 2>/dev/null; }

# The last N lines of a container's log (stdout and stderr together).
dk_logs_tail() { # container lines
  docker logs --tail "$2" "$1" 2>&1
}

# The log of a container, followed (stdout and stderr together). Run it in a subshell: it replaces that process with `docker logs -f`.
dk_logs_stream() { # container lines
  exec docker logs --tail "$2" -f "$1" 2>&1
}

# Number of log lines of the last 10 minutes that look like errors.
dk_log_error_count() { # container
  docker logs --since 10m "$1" 2>&1 | grep -acE 'ERROR|ECONNREFUSED|Unable to connect' || true
}

# Number of running containers of a Compose project.
dk_project_running_count() { # project
  docker ps -q --filter "label=com.docker.compose.project=$1" | wc -l | tr -d ' '
}

# Does the Compose project publish host port $2?
dk_project_publishes_port() { # project port
  docker ps --filter "label=com.docker.compose.project=$1" --format '{{.Ports}}' 2>/dev/null | grep -q ":$2->"
}
