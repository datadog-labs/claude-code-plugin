#!/usr/bin/env bash
# Tests for hooks/hooks.json and the viz hook scripts.
#
# Runs on macOS, Linux and Git Bash. Nothing here touches the network or the
# ddviz socket: telemetry is opted out via DO_NOT_TRACK, and the non-Darwin
# paths under test never open a socket in the first place.
#
# The Windows failure in #27 cannot be reproduced on a Unix host -- it depends
# on `bash` resolving to the WSL launcher. So the Windows-specific check is a
# contract assertion on hooks.json, and the behavioural checks confirm the
# hooks work on whichever host is running the suite. Run it on windows-latest
# and the behavioural checks cover the real thing.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

# What Claude Code would substitute for ${CLAUDE_PLUGIN_ROOT}. Defaults to this
# checkout; CI overrides it on Windows with a native backslash path
# (D:\a\repo\repo) so the suite exercises the shape of plugin root that #27
# reported, rather than the Unix-style path Git Bash reports for $PWD.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required to run this suite"; exit 2; }

# A directory whose `uname` reports whatever we need, prepended to PATH so the
# hooks' own `$(uname)` resolves to it.
stub_uname_path() {
  local dir; dir=$(mktemp -d)
  printf '#!/bin/sh\necho %s\n' "$1" > "$dir/uname"
  chmod 755 "$dir/uname"
  printf '%s' "$dir"
}

# Run the hook declared for $1 the way Claude Code would, reading the payload on
# stdin. Shell form goes to a shell, which expands ${CLAUDE_PLUGIN_ROOT} from
# the environment; exec form is spawned directly with no shell. Supporting both
# means this suite reports honestly against the pre-fix config too, rather than
# failing it for the wrong reason.
run_hook() {
  local event="$1" form command
  form=$(jq -r --arg e "$event" '.hooks[$e][0].hooks[0] | if has("args") then "exec" else "shell" end' "$HOOKS_JSON")
  command=$(jq -r --arg e "$event" '.hooks[$e][0].hooks[0].command' "$HOOKS_JSON")

  if [ "$form" = shell ]; then
    sh -c "$command"
  else
    local -a argv=()
    local a
    while IFS= read -r a; do
      # Parameter expansion, not sed: sed treats backslashes in the replacement
      # as escapes, so a Windows ${CLAUDE_PLUGIN_ROOT} would be eaten here --
      # the same class of bug this suite exists to catch.
      argv+=("${a/\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}")
    done < <(jq -r --arg e "$event" '.hooks[$e][0].hooks[0].args[]' "$HOOKS_JSON")
    "$command" "${argv[@]}"
  fi
}

SESSION_PAYLOAD='{"session_id":"test-session","hook_event_name":"SessionEnd","reason":"exit"}'
TOOL_PAYLOAD='{"hook_event_name":"PostToolUse","tool_response":{"content_text":"chart"}}'

echo "hooks.json is well formed"

if jq empty "$HOOKS_JSON" 2>/dev/null; then
  ok "parses as JSON"
else
  fail "parses as JSON"
fi

echo
echo "hook invocation is safe on Windows (#27)"

# Exec form resolves `command` against PATH with no shell. On a default Windows
# install `bash` is C:\Windows\System32\bash.exe -- the WSL launcher, which
# reads the Windows ${CLAUDE_PLUGIN_ROOT} as escape sequences and never finds
# the script. Shell form hands the string to Git Bash instead, which resolves
# it correctly.
BARE=$(jq -r '
  .hooks | to_entries[] | .key as $event | .value[] | .hooks[]
  | select(has("args"))
  | select(.command | test("^(bash|sh|zsh|dash|python|python3|node)$"))
  | "\($event): command=\(.command)"' "$HOOKS_JSON")
if [ -z "$BARE" ]; then
  ok "no hook spawns a bare interpreter name in exec form"
else
  fail "no hook spawns a bare interpreter name in exec form" "$BARE"
fi

# Exec form keeps the script in args[0]; shell form carries it in the command
# string.
HOOKS=$(jq -r '
  .hooks | to_entries[] | .key as $event | .value[] | .hooks[]
  | if has("args")
    then [$event, "exec",  (.args[0] // "")]
    else [$event, "shell", (.command // "")]
    end | @tsv' "$HOOKS_JSON")

# Resolved against this checkout rather than $PLUGIN_ROOT: whether a Windows
# path survives is what the behavioural runs below cover, while these two checks
# are about the files themselves.
while IFS="$(printf '\t')" read -r event form script; do
  [ -n "$script" ] || continue
  script=${script//\"/}                              # shell form quotes the variable
  script=${script//$'\r'/}                           # CRLF checkouts on Windows
  rel=${script#*\$\{CLAUDE_PLUGIN_ROOT\}}            # -> /viz/hooks/forward.sh
  rel=${rel#/}

  if [ -f "$REPO_ROOT/$rel" ]; then
    ok "$event: script exists"
  else
    fail "$event: script exists" "$REPO_ROOT/$rel"
    continue
  fi

  # Only shell form runs the file itself; exec form hands it to an interpreter,
  # so the mode does not matter there. Asserted against the mode git records,
  # not the working tree: git does not materialise permission bits on Windows,
  # so -x there says nothing, while the recorded mode is what ships to users.
  if [ "$form" = shell ]; then
    mode=$(cd "$REPO_ROOT" && git ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')
    if [ "$mode" = 100755 ]; then
      ok "$event: script is executable in git ($mode)"
    else
      fail "$event: script is executable in git" "got ${mode:-<not tracked>}; shell form runs the file directly, and mode 644 exits 126"
    fi
  fi
done <<EOF
$HOOKS
EOF

echo
echo "hooks run clean on this host"

out=$(printf '%s' "$SESSION_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" DO_NOT_TRACK=1 run_hook SessionEnd 2>&1)
status=$?
if [ $status -eq 0 ]; then
  ok "SessionEnd exits 0 on $(uname -s)"
else
  fail "SessionEnd exits 0 on $(uname -s)" "exit=$status output=$out"
fi
if [ -z "$out" ]; then
  ok "SessionEnd prints nothing"
else
  fail "SessionEnd prints nothing" "$out"
fi

echo
echo "the non-macOS no-op is reachable and silent"

# Off Darwin the hook has no work to do. Once it can actually be spawned it must
# reach that branch and say nothing -- the visible symptom in #27 was the hook
# failing before it ever got there.
for os in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0 Linux; do
  stub=$(stub_uname_path "$os")
  out=$(printf '%s' "$SESSION_PAYLOAD" | PATH="$stub:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        DO_NOT_TRACK=1 run_hook SessionEnd 2>&1)
  status=$?
  rm -rf "$stub"
  if [ $status -eq 0 ] && [ -z "$out" ]; then
    ok "SessionEnd is a silent no-op when uname reports $os"
  else
    fail "SessionEnd is a silent no-op when uname reports $os" "exit=$status output=$out"
  fi
done

echo
echo "PostToolUse still falls back off macOS"

# forward.sh, unlike session_end.sh, has real work to do off macOS: it tells the
# model the chart is available at the sandbox URL. Dropping the registration on
# non-macOS would lose that, so it must stay registered and exit 0 with the
# fallback rather than be skipped.
stub=$(stub_uname_path Linux)
out=$(printf '%s' "$TOOL_PAYLOAD" | PATH="$stub:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      CLAUDE_CODE_ENTRYPOINT=cli DO_NOT_TRACK=1 DISABLE_TELEMETRY=1 run_hook PostToolUse 2>&1)
status=$?
rm -rf "$stub"
if [ $status -eq 0 ]; then
  ok "PostToolUse exits 0 off macOS"
else
  fail "PostToolUse exits 0 off macOS" "exit=$status output=$out"
fi
if printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("sandbox URL")' >/dev/null 2>&1; then
  ok "PostToolUse returns the sandbox-URL fallback off macOS"
else
  fail "PostToolUse returns the sandbox-URL fallback off macOS" "$out"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
