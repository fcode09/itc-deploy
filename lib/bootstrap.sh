#!/usr/bin/env bash
# Loads every layer of deltactl in dependency order. Sourced by the entry point and by the tests; never
# executed. Requires ROOT (the repo root) to be defined.
#
#   i18n/       language selection and message catalogs        (what the user reads)
#   ui/         colors, tables, banner, messages, prompts      (how it is shown)
#   core/       rules: instances, services, images, ports, state (what is true)
#   adapters/   docker, state on disk, host                    (the only code that touches the outside)
#   cmd/        the commands, loaded on demand by the entry point
#
# shellcheck source=lib/i18n/i18n.sh
source "$ROOT/lib/i18n/i18n.sh"
# shellcheck source=lib/ui/ui.sh
source "$ROOT/lib/ui/ui.sh"
# shellcheck source=lib/ui/theme.sh
source "$ROOT/lib/ui/theme.sh"
# shellcheck source=lib/ui/tokens.sh
source "$ROOT/lib/ui/tokens.sh"
# shellcheck source=lib/ui/gfx.sh
source "$ROOT/lib/ui/gfx.sh"
# shellcheck source=lib/ui/say.sh
source "$ROOT/lib/ui/say.sh"
# shellcheck source=lib/ui/prompt.sh
source "$ROOT/lib/ui/prompt.sh"

# shellcheck source=lib/core/config.sh
source "$ROOT/lib/core/config.sh"
# shellcheck source=lib/core/catalog.sh
source "$ROOT/lib/core/catalog.sh"
# shellcheck source=lib/adapters/state.sh
source "$ROOT/lib/adapters/state.sh"
# shellcheck source=lib/adapters/docker.sh
source "$ROOT/lib/adapters/docker.sh"
# shellcheck source=lib/adapters/host.sh
source "$ROOT/lib/adapters/host.sh"
# shellcheck source=lib/core/instance.sh
source "$ROOT/lib/core/instance.sh"
# shellcheck source=lib/core/services.sh
source "$ROOT/lib/core/services.sh"
# shellcheck source=lib/core/imagecat.sh
source "$ROOT/lib/core/imagecat.sh"
# shellcheck source=lib/core/envschema.sh
source "$ROOT/lib/core/envschema.sh"
# shellcheck source=lib/core/envedit.sh
source "$ROOT/lib/core/envedit.sh"
# shellcheck source=lib/core/ports.sh
source "$ROOT/lib/core/ports.sh"
# shellcheck source=lib/core/status.sh
source "$ROOT/lib/core/status.sh"
# shellcheck source=lib/core/prereqs.sh
source "$ROOT/lib/core/prereqs.sh"
# shellcheck source=lib/core/metrics.sh
source "$ROOT/lib/core/metrics.sh"
# shellcheck source=lib/core/jobs.sh
source "$ROOT/lib/core/jobs.sh"
