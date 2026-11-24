#!/usr/bin/env bash
# UI kit of the redesign: loads every component. Sourced after lib/ui/tui.sh and lib/ui/tokens.sh (the panel and the tools do it);
# never executed. See DISENO notes in each file: components are pure (data in, lines out) and use no process.
# shellcheck source=lib/ui/kit/box.sh
source "$ROOT/lib/ui/kit/box.sh"
# shellcheck source=lib/ui/kit/graph_braille.sh
source "$ROOT/lib/ui/kit/graph_braille.sh"
# shellcheck source=lib/ui/kit/meter.sh
source "$ROOT/lib/ui/kit/meter.sh"
# shellcheck source=lib/ui/kit/metric_row.sh
source "$ROOT/lib/ui/kit/metric_row.sh"
# shellcheck source=lib/ui/kit/state.sh
source "$ROOT/lib/ui/kit/state.sh"
# shellcheck source=lib/ui/kit/wrap.sh
source "$ROOT/lib/ui/kit/wrap.sh"
# shellcheck source=lib/ui/kit/stepper.sh
source "$ROOT/lib/ui/kit/stepper.sh"
# shellcheck source=lib/ui/kit/tabs.sh
source "$ROOT/lib/ui/kit/tabs.sh"
# shellcheck source=lib/ui/kit/field.sh
source "$ROOT/lib/ui/kit/field.sh"
# shellcheck source=lib/ui/kit/table.sh
source "$ROOT/lib/ui/kit/table.sh"
# shellcheck source=lib/ui/kit/checklist.sh
source "$ROOT/lib/ui/kit/checklist.sh"
# shellcheck source=lib/ui/kit/toast.sh
source "$ROOT/lib/ui/kit/toast.sh"
# shellcheck source=lib/ui/kit/modal.sh
source "$ROOT/lib/ui/kit/modal.sh"
