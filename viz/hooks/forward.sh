#!/usr/bin/env bash
# Hook: PostToolUse for visualizations toolset results. Forwards a Datadog
# visualization tool result to the ddviz panel.

HOOK_DIR="${0%/*}"
[[ "$HOOK_DIR" == "$0" ]] && HOOK_DIR="."
# shellcheck source=/dev/null
. "$HOOK_DIR/ddviz_json.sh"
# Bundled path strips the template prefix. Source tree (tests) keeps it. Try bundled first.
if [[ -f "$HOOK_DIR/ddviz_telemetry.sh" ]]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/ddviz_telemetry.sh"
else
  # shellcheck source=/dev/null
  . "$HOOK_DIR/template.ddviz_telemetry.sh"
fi

INPUT=$(cat)

# Shared per-user daemon dir (GRAPHAI-1110). DDVIZ_DATA_DIR overrides it to
# isolate a dev build. The opt-out marker below lives here too.
DATA_DIR="${DDVIZ_DATA_DIR:-$HOME/.ddviz}"

# Emit the sandbox-URL fallback and exit 0. $1 is a hardcoded reason keycode
# reported via telemetry; $2 optionally overrides the model-facing fallback text.
bail() {
  emit_event bail warn message "ddviz hook bailed" reason "${1:-unknown}"
  emit_output "${2:-Could not render the visualization properly due to missing dependency. The visualization is visible via the sandbox URL provided in the browser.}"
  exit 0
}

# Emit a PostToolUse hookSpecificOutput to stdout. $1 is an optional plain-text
# additionalContext (e.g. a bail reason); a tool_response.content_text
# rides along as updatedToolOutput, replacing the full result. Emits nothing when
# neither is present, leaving the original tool output untouched.
emit_output() {
  local context="${1:-}" content_text inner inner_json

  # tool_response either a nested object or a double-encoded as a JSON string;
  # decode that before reading content_text.
  if [[ "$(json_type tool_response <<< "$INPUT")" == string ]]; then
    inner_json=$(json_get tool_response <<< "$INPUT") || inner_json=""
    content_text=$(json_get content_text <<< "$inner_json") || content_text=""
  else
    content_text=$(json_get tool_response content_text <<< "$INPUT") || content_text=""
  fi

  if [[ -z "$context" && -z "$content_text" ]]; then
    return 0
  fi

  local -a fields=(hookEventName PostToolUse)
  if [[ -n "$content_text" ]]; then
    fields+=(updatedToolOutput "$content_text")
  fi
  if [[ -n "$context" ]]; then
    fields+=(additionalContext "$context")
  fi

  if inner=$(json_build_object "${fields[@]}") && [[ -n "$inner" ]]; then
    printf '{"hookSpecificOutput":%s}' "$inner"
  elif [[ -n "$context" ]]; then
    # Only the controlled-text reason reaches here (no quotes or backslashes)
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}' "$context"
  fi
}

should_skip() {
  # Explicit opt-out (see /ddviz skill).
  if [[ -e "${DATA_DIR}/DDVIZ_DISABLED" ]]; then
    return 0
  fi

  # Avoid headless sessions (claude -p): only the interactive CLI has a session
  # to surface the panel in. Headless `claude -p` reports sdk-cli and the SDK
  # reports sdk-ts/sdk-py.
  if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" != "cli" ]]; then
    emit_output
    return 0
  fi

  # Avoid sub-agents: `agent_id` is only present inside a subagent.
  local agent_id status
  agent_id=$(json_get agent_id <<< "$INPUT")
  status=$?
  if (( status == 2 )); then
    bail invalid_json "The tool result was not valid JSON, so the visualization could not be rendered. It is available via the sandbox URL provided in the browser."
  elif (( status != 0 )); then
    bail no_json_engine
  fi
  if [[ -n "$agent_id" ]]; then
    emit_output
    return 0
  fi

  # Content-block returned from MCP: structuredContent field is absent: no MCP-App support.
  if [[ "$(json_type tool_response <<< "$INPUT")" == array ]]; then
    bail unsupported_content_block "This tool result can't be rendered in the visualization panel; it is available via the sandbox URL provided in the browser."
  fi

  return 1
}

ensure_daemon_macos() {
  # `xcode-select -p` checks for a real toolchain without triggering that installer.
  if ! command -v swift &>/dev/null || ! xcode-select -p &>/dev/null; then
    bail swift_unavailable
  fi

  local data_dir="$1"
  local socket="$data_dir/ddviz.sock"
  local pidfile="$socket.pid"
  if [[ -S "$socket" ]]; then
    local pid; pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -z "$pid" ]] || kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$socket" "$pidfile"
  fi

  mkdir -p "$data_dir" 2>/dev/null

  DDVIZ_DATA_DIR="$data_dir" \
    DDVIZ_MENUBAR_CONTEXT="1" \
    DDVIZ_IPC="hooks" \
    DDVIZ_PARENT_PID="$PPID" \
    swift "${CLAUDE_PLUGIN_ROOT}/viz/ddviz.swift" &>/dev/null &
  local pid=$!

  for _ in {1..20}; do
    if [[ -S "$socket" ]]; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.5
  done

  [[ -S "$socket" ]]
}

forward_macos() {
  if [[ ! -x /usr/bin/nc ]]; then
    bail nc_unavailable
  fi

  local payload
  payload=$(json_set "$INPUT" ddviz_parent_pid "$PPID" 2>/dev/null || printf '%s' "$INPUT")

  local socket="$DATA_DIR/ddviz.sock"
  if ! ensure_daemon_macos "$DATA_DIR"; then
    bail daemon_unavailable
  fi

  if [[ -S "$socket" && ! -L "$socket" ]]; then
    /usr/bin/nc -w 1 -U "$socket" <<< "$payload" &>/dev/null &
    emit_event usage info emitter hook
  fi

  # The panel is up; hand the model the compact response when the tool supplied
  # one (no reason: the visualization rendered).
  emit_output
}

# ── JSON layer ──────────────────────────────────────────────────────────────
# Two readers over the jq/plutil choice: scalar and type at a keypath. The
# writers (json_build_object, json_set) live in ddviz_json.sh.

# Read the JSON on stdin and print the scalar at a keypath (one component per
# argument). Prints nothing when the path is absent or not a scalar.
#   0: ok           1: no JSON engine           2: malformed JSON
json_get() {
  local json; json=$(cat)
  if command -v jq &>/dev/null; then
    # `?` treats a bad index as absent; a parse failure still trips `|| return 2`.
    jq -r 'getpath($ARGS.positional)? // empty' --args "$@" <<< "$json" 2>/dev/null || return 2
  elif command -v plutil &>/dev/null; then
    # `plutil -lint` misreads a JSON object as an OpenStep plist; convert to validate.
    plutil -convert json -o /dev/null - <<< "$json" &>/dev/null || return 2
    # Only print on success: a missing key must yield nothing. Some plutil
    # versions write the "no value at key path" error to stdout, so piping its
    # output straight through would leak that text as a bogus value.
    local IFS=. value
    if value=$(plutil -extract "$*" raw -o - - <<< "$json" 2>/dev/null); then
      printf '%s' "$value"
    fi
  else
    return 1
  fi
}

# Read the JSON on stdin and print the JSON type ("array"/"object"/"string"/…)
# at a keypath. Prints nothing when the path is absent.
#   0: ok           1: no JSON engine           2: malformed JSON
json_type() {
  local json; json=$(cat)
  if command -v jq &>/dev/null; then
    jq -r 'getpath($ARGS.positional)? | type' --args "$@" <<< "$json" 2>/dev/null || return 2
  elif command -v plutil &>/dev/null; then
    plutil -convert json -o /dev/null - <<< "$json" &>/dev/null || return 2
    local IFS=. out
    if out=$(plutil -extract "$*" json -o - - <<< "$json" 2>/dev/null); then
      case "$out" in
        \[*) printf array ;;
        \{*) printf object ;;
        *)   printf other ;;
      esac
    elif plutil -extract "$*" raw -o - - <<< "$json" &>/dev/null; then
      printf string
    fi
  else
    return 1
  fi
}

if should_skip; then
  exit 0
fi


case "$(uname)" in
  Darwin) forward_macos ;;
  *) bail unsupported_os ;;
esac
