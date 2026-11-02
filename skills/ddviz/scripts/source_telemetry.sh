# Locates and sources the shared libs for a sibling script: the JSON engine,
# the telemetry lib, and the entrypoint allowlist (shared with forward.sh so
# the two never drift). Bundled path strips the template prefix; the source
# tree keeps it. Try bundled first.
SCRIPT_DIR="${0%/*}"
[[ "$SCRIPT_DIR" == "$0" ]] && SCRIPT_DIR="."
if [[ -f "$SCRIPT_DIR/../../../viz/hooks/ddviz_telemetry.sh" ]]; then
  LIB_DIR="$SCRIPT_DIR/../../../viz/hooks"
  TELEMETRY_LIB=ddviz_telemetry.sh
  ENTRYPOINT_LIB=ddviz_entrypoint.sh
else
  LIB_DIR="$SCRIPT_DIR/../../../../shared-viz/hooks"
  TELEMETRY_LIB=template.ddviz_telemetry.sh
  ENTRYPOINT_LIB=template.ddviz_entrypoint.sh
fi
# shellcheck source=/dev/null
. "$LIB_DIR/ddviz_json.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/$TELEMETRY_LIB"
# shellcheck source=/dev/null
. "$LIB_DIR/$ENTRYPOINT_LIB"
