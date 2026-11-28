#!/bin/bash
# Run a command under `mutter --x11` on the current DISPLAY; fail on Mutter's
# refusal to minimize, which it only logs.
set -euo pipefail
PRISM_MUTTER_LOG=$(mktemp)
mutter --x11 --replace >"$PRISM_MUTTER_LOG" 2>&1 &
PRISM_MUTTER=$!
trap 'kill "$PRISM_MUTTER" 2>/dev/null || true; wait "$PRISM_MUTTER" 2>/dev/null || true; rm -f "$PRISM_MUTTER_LOG"' EXIT
PRISM_STATUS=0
"$@" || PRISM_STATUS=$?
if grep -i "cannot be minimized" "$PRISM_MUTTER_LOG"; then
    PRISM_STATUS=1
fi
if [ "$PRISM_STATUS" -ne 0 ]; then
    cat "$PRISM_MUTTER_LOG"
fi
exit "$PRISM_STATUS"
