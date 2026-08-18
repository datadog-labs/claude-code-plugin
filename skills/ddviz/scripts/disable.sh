#!/usr/bin/env bash
# Disables ddviz: creates the opt-out marker file, then tears down the panel if one is open.

# shellcheck source=/dev/null
. "${0%/*}/source_telemetry.sh"

DATA_DIR="${DDVIZ_DATA_DIR:-$HOME/.ddviz}"
MARKER="$DATA_DIR/DDVIZ_DISABLED"
SOCKET="$DATA_DIR/ddviz.sock"

if [[ -e "$MARKER" ]]; then
  echo disabled
  exit 0
fi

mkdir -p "$DATA_DIR" 2>/dev/null
if ! : > "$MARKER" 2>/dev/null; then
  echo "failed to disable: cannot write $MARKER" >&2
  exit 1
fi
if [[ -S "$SOCKET" && ! -L "$SOCKET" ]]; then
  printf '{"command":"shutdown"}' | /usr/bin/nc -w 1 -U "$SOCKET" &>/dev/null
fi
emit_event disable info emitter skill
echo disabled
