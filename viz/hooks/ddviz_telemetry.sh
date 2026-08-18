# ddviz telemetry lib. Fire-and-forget one browser log per event. Every path
# returns 0 so telemetry can't break the caller. Content is aggregate only, no
# user/session/install id.

# The token is write-only, so it is safe to inline. SERVICE/LOGGER mirror
# dataviz-mcp-ui's datadogLogs.init() so these land in the same index.
DDVIZ_TELEMETRY_CLIENT_TOKEN="pub9e6850a2eb60360846c8dd17080ce916"
DDVIZ_TELEMETRY_SITE="datadoghq.com"
DDVIZ_TELEMETRY_SERVICE="dataviz-mcp-ui"
DDVIZ_TELEMETRY_LOGGER="ddviz-hook"

# emit_event EVENT STATUS [KEY VALUE ...attributes]
emit_event() {
  case "${DO_NOT_TRACK:-}" in 1 | true) return 0 ;; esac
  case "${DISABLE_TELEMETRY:-}" in 1 | true) return 0 ;; esac
  command -v curl &>/dev/null || return 0
  command -v json_build_object &>/dev/null || return 0

  [[ "$#" -ge 2 ]] || return 0
  local event="$1" status="$2"; shift 2
  local env="prod" version="0.7.17" plugin_id="claude-code-plugin"

  local ddtags="env:${env},service:${DDVIZ_TELEMETRY_SERVICE},version:${version},plugin_id:${plugin_id},event:${event},status:${status}"

  local logger payload
  logger=$(json_build_object name "$DDVIZ_TELEMETRY_LOGGER") || return 0
  payload=$(json_build_object \
    service "$DDVIZ_TELEMETRY_SERVICE" \
    ddtags "$ddtags" \
    status "$status" \
    "$@") || return 0
  payload=$(json_set "$payload" logger "$logger") || return 0
  [[ -n "$payload" ]] || return 0

  local url="https://browser-intake-${DDVIZ_TELEMETRY_SITE}/api/v2/logs?ddsource=browser&dd-api-key=${DDVIZ_TELEMETRY_CLIENT_TOKEN}"
  curl -sf -m 2 -X POST "$url" -H 'Content-Type: application/json' -d "$payload" &>/dev/null &
  return 0
}
