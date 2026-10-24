#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/p0_guest_acceptance.py" "$@"
