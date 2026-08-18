#!/usr/bin/env bash
# Hook: SessionEnd. Forwards the event payload (which carries session_id) to
# ddviz so it can drop that session and terminate once none remain.

forward_macos() {
  # Must match the daemon dir resolved in forward.sh so SessionEnd reaches it.
  DDVIZ_SOCKET="${DDVIZ_DATA_DIR:-$HOME/.ddviz}/ddviz.sock"
  if [[ -S "$DDVIZ_SOCKET" && ! -L "$DDVIZ_SOCKET" ]]; then
    /usr/bin/nc -w 1 -U "$DDVIZ_SOCKET" &>/dev/null || true
  fi
}

case "$(uname)" in
  Darwin) forward_macos ;;
  *) ;;
esac
