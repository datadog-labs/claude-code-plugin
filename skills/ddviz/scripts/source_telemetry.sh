# Locates and sources the shared telemetry lib for a sibling script.
# Bundled path strips the template prefix. Source tree keeps it. Try bundled first.
SCRIPT_DIR="${0%/*}"
[[ "$SCRIPT_DIR" == "$0" ]] && SCRIPT_DIR="."
if [[ -f "$SCRIPT_DIR/../../../viz/hooks/ddviz_telemetry.sh" ]]; then
  LIB_DIR="$SCRIPT_DIR/../../../viz/hooks"
  TELEMETRY_LIB=ddviz_telemetry.sh
else
  LIB_DIR="$SCRIPT_DIR/../../../../shared-viz/hooks"
  TELEMETRY_LIB=template.ddviz_telemetry.sh
fi
# shellcheck source=/dev/null
. "$LIB_DIR/ddviz_json.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/$TELEMETRY_LIB"
