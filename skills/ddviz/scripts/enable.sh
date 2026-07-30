#!/usr/bin/env bash
# Enables ddviz: removes the opt-out marker file.

# shellcheck source=/dev/null
. "${0%/*}/source_telemetry.sh"

DATA_DIR="${DDVIZ_DATA_DIR:-$HOME/.ddviz}"
MARKER="$DATA_DIR/DDVIZ_DISABLED"

if [[ ! -e "$MARKER" ]]; then
  echo enabled
  exit 0
fi

if ! rm -f "$MARKER" 2>/dev/null; then
  echo "failed to enable: cannot remove $MARKER" >&2
  exit 1
fi
emit_event enable info emitter skill
echo enabled
