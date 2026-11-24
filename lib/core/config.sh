#!/usr/bin/env bash
# shellcheck disable=SC2034  # constants read by the commands that source this layer
# Constants of the tool. Sourced by lib/bootstrap.sh; requires ROOT.

INSTANCES_DIR="$ROOT/instances"
BASE_PORT=4100        # first host port block
PORT_STEP=10          # each instance takes a block of 10 ports (sN uses base + N)
RUNTIME_UID=1000      # uid of the "node" user inside the images

# Known services (KNOWN_SERVICES) come from the service catalog: lib/core/catalog.data, read by lib/core/catalog.sh.
