#!/usr/bin/env bash
# Reports whether ddviz is on and, when the panel isn't showing, what is
# stopping it: platform, toolchain, plugin install, opt-out marker, and daemon
# liveness. MCP/toolset state is not checked here — the skill's live MCP check
# is the reliable source for that. Read-only and sub-second.

# shellcheck source=/dev/null
. "${0%/*}/source_telemetry.sh"

DATA_DIR="${DDVIZ_DATA_DIR:-$HOME/.ddviz}"
MARKER="$DATA_DIR/DDVIZ_DISABLED"
SOCKET="$DATA_DIR/ddviz.sock"

# The skill passes the plugin root as an argument because Claude Code
# resolves ${CLAUDE_PLUGIN_ROOT} in skill content before the model sees it,
# but does not export it as an env var to a Bash tool call. $CLAUDE_PLUGIN_ROOT
# is kept only as a fallback for manual/test invocations that set it directly.
PLUGIN_ROOT="${1:-${CLAUDE_PLUGIN_ROOT:-}}"

# Off macOS there is nothing to diagnose: the panel is a native macOS window
# and no amount of local fixing changes that. Say so in one line and stop —
# a table of toolchain rows would only imply the rest is worth investigating.
if [[ "$(uname)" != Darwin ]]; then
  echo "ddviz is only supported on macOS"
  emit_event status warn emitter skill reason unsupported_os
  exit 1
fi

blocking=0
fixes=()
first_reason=""

# row KEY STATUS [DETAIL] — one aligned report line.
row() {
  printf '%-13s %-13s %s\n' "$1:" "$2" "${3:-}"
}

# The opt-out marker answers "is ddviz on?" directly. Disabled is a
# deliberate, valid user choice, not a problem — it is never counted as
# blocking or reported as a "fail" anywhere below. The re-enable hint rides
# along on this same line instead of a separate row, so there's nothing to
# misread as an error.
if [[ -e "$MARKER" ]]; then
  echo "ddviz: disabled (run \`/ddviz enable\` to turn it back on)"
else
  echo "ddviz: enabled"
fi
echo

# fail KEY DETAIL REASON FIX — records a blocking check.
fail() {
  row "$1" fail "$2"
  blocking=$((blocking + 1))
  fixes+=("$1: $4")
  [[ -z "$first_reason" ]] && first_reason="$3"
}

# 1. plugin — provenance only.
row plugin ok "v0.7.19"

# 2. platform — macOS 13+ required. Non-macOS already exited above, so this
# only has to judge the version.
os_version=$(sw_vers -productVersion 2>/dev/null)
major="${os_version%%.*}"
if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 13 )); then
  row platform ok "macOS $os_version"
else
  fail platform "macOS ${os_version:-unknown}" unsupported_os "requires macOS 13 or later"
fi

# 3. xcode-tools — checked before anything invokes `swift`: on a machine
# without the Command Line Tools, `swift --version` is what pops the GUI
# installer (see forward.sh's ensure_daemon_macos comment).
xcode_ok=0
if xcode_path=$(xcode-select -p 2>/dev/null); then
  xcode_ok=1
  sdk=$(xcrun --show-sdk-version 2>/dev/null)
  row xcode-tools ok "${xcode_path}${sdk:+ (SDK $sdk)}"
else
  fail xcode-tools "not installed" swift_unavailable "run \`xcode-select --install\`"
fi

# 4. swift — only probed once xcode-tools succeeded. Probing `swift --version`
# directly (rather than just `command -v swift`) catches a broken toolchain —
# e.g. an Xcode update awaiting license acceptance — where the binary is on
# PATH but unusable, which is exactly what would stop forward.sh's daemon.
if (( xcode_ok )); then
  if swift_version_output=$(swift --version 2>/dev/null); then
    swift_version=$(echo "$swift_version_output" | grep -oE 'Apple Swift version [0-9.]+' | grep -oE '[0-9.]+$')
    row swift ok "${swift_version:-unknown}"
  else
    fail swift "not available" swift_unavailable "install the Swift toolchain"
  fi
else
  row swift skipped "no toolchain"
fi

# 5. netcat — no version flag on the BSD build, so the detail is just its path.
if [[ -x /usr/bin/nc ]]; then
  row netcat ok /usr/bin/nc
else
  fail netcat "not found" nc_unavailable "/usr/bin/nc is required and should ship with macOS"
fi

# 6. json-engine — same preference order forward.sh uses at runtime.
if command -v jq &>/dev/null; then
  jq_version=$(jq --version 2>/dev/null)
  row json-engine ok "${jq_version:-jq}"
elif command -v plutil &>/dev/null; then
  row json-engine ok plutil
else
  fail json-engine "none found" no_json_engine "install jq (plutil should already ship with macOS)"
fi

# 7. plugin-root — logs the actual install path, which helps spot dual or
# stale installations. This only fails when the script is run outside the
# skill flow with neither the argument nor CLAUDE_PLUGIN_ROOT set. If it's
# empty, "$PLUGIN_ROOT/viz/ddviz.swift" silently collapses to
# "/viz/ddviz.swift" and plugin-files would otherwise misreport "reinstall the
# plugin" for what is actually a missing argument.
if [[ -n "$PLUGIN_ROOT" ]]; then
  plugin_root_ok=1
  row plugin-root ok "$PLUGIN_ROOT"
else
  plugin_root_ok=0
  fail plugin-root "not set" plugin_root_unset "re-run via the /ddviz skill, which passes the plugin root explicitly"
fi

# 8. plugin-files — a broken/partial install. Only meaningful once plugin-root is known good.
if (( plugin_root_ok )); then
  if [[ -f "$PLUGIN_ROOT/viz/ddviz.swift" && -f "$PLUGIN_ROOT/viz/hooks/forward.sh" ]]; then
    row plugin-files ok
  else
    fail plugin-files "missing viz assets" daemon_unavailable "reinstall the plugin"
  fi
else
  row plugin-files skipped "plugin root unknown"
fi

# 9. entrypoint — the panel only ever shows in these hosts (forward.sh's
# allowlist, shared via DDVIZ_ALLOWED_ENTRYPOINTS so the two never drift).
if ddviz_entrypoint_allowed; then
  row entrypoint ok "${CLAUDE_CODE_ENTRYPOINT}"
else
  row entrypoint warn "${CLAUDE_CODE_ENTRYPOINT:-unknown} (panel only shows in the CLI or VS Code extension)"
fi

# 10. daemon — copied verbatim from forward.sh's ensure_daemon_macos liveness probe.
# Never blocking: not-running is the normal steady state (it starts on the first chart).
if [[ -S "$SOCKET" ]]; then
  pid=$(cat "$SOCKET.pid" 2>/dev/null)
  if [[ -z "$pid" ]] || kill -0 "$pid" 2>/dev/null; then
    row daemon running "pid ${pid:-unknown}"
  else
    row daemon stale-socket "socket present, process gone"
  fi
else
  row daemon not-running "starts on the first chart"
fi

echo
echo "blocking: $blocking"
for fix in "${fixes[@]}"; do
  echo "fix: $fix"
done

if (( blocking > 0 )); then
  emit_event status warn emitter skill reason "${first_reason:-unknown}"
fi

(( blocking == 0 ))
