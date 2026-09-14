# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repository is

The `datadog` plugin for Claude Code: a preconfigured Datadog MCP server, a set
of skills, and a macOS-only visualization panel (`ddviz`). It is published to
the `anthropics/claude-plugins-official` marketplace.

**This repo is a downstream artifact.** It is regenerated from an internal
Datadog source repository on each release. External contributions are reviewed
here and then ported back internally. Two consequences worth keeping in mind:

- Keep changes focused and self-explanatory. Someone has to re-apply them by
  hand on the other side.
- The test suite that covers most of this code lives in the internal repo, not
  here. `forward.sh` still carries a `template.` fallback path for that source
  tree. Don't delete it because it looks dead — it is live upstream.

## Layout

```
.claude-plugin/plugin.json   Plugin manifest (name, version, MCP server path)
.dd_claude-code_mcp.json     MCP server definition
hooks/hooks.json             Hook registrations
viz/hooks/                   ddviz hook scripts (forward.sh, session_end.sh)
viz/ddviz.swift              The macOS panel daemon
skills/                      Skills, each a SKILL.md plus optional scripts/
tests/hooks_test.sh          Hook wiring tests (see Testing)
```

## Hooks: use shell form, never a bare interpreter

`hooks/hooks.json` must invoke scripts in **shell form** — a `command` string
with no `args` key:

```json
{ "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}\"/viz/hooks/forward.sh" }
```

Not exec form:

```json
{ "type": "command", "command": "bash", "args": ["${CLAUDE_PLUGIN_ROOT}/viz/hooks/forward.sh"] }
```

The difference matters on Windows. Adding `args` switches Claude Code to exec
form, which resolves `command` against `PATH` and spawns it with no shell. On a
default Windows install `bash` on `PATH` is `C:\Windows\System32\bash.exe` — the
**WSL launcher**, not Git Bash. It reads the Windows `${CLAUDE_PLUGIN_ROOT}` as
escape sequences, the script is never found, and the hook fails on every
invocation. That was issue #27: a `SessionEnd` hook whose only job off macOS is
to do nothing still printed an error on every exit.

Shell form hands the string to `sh -c` on macOS and Linux and to **Git Bash** on
Windows, which resolves the path correctly.

Two rules follow:

1. **Hook scripts must be executable** (mode `755`). Shell form runs the file
   directly, so mode `644` exits `126` with "Permission denied".
2. **There is no OS conditional for hook registration.** The `if` field takes
   permission-rule syntax and is only evaluated on tool events — on `SessionEnd`
   and friends, a hook with `if` set *never runs at all*. So a hook that is
   macOS-only cannot be unregistered elsewhere; it must be cheap and silent
   instead. Return `0` and print nothing on the platforms you don't serve.

Skill scripts are different: `SKILL.md` tells the model to run
`bash "${CLAUDE_PLUGIN_ROOT}/skills/.../foo.sh"` through the **Bash tool**,
which already uses Git Bash on Windows. Those stay mode `644` and keep the
explicit `bash` prefix.

## Platform support

`ddviz` is macOS-only — it needs Swift, `xcode-select`, and `/usr/bin/nc`. The
two hooks behave differently off macOS and this is deliberate:

- `session_end.sh` has nothing to do. It hits the `*)` branch and exits `0`.
- `forward.sh` **does** have work to do. It calls `bail unsupported_os`, which
  tells the model the chart is available at the sandbox URL. Never "optimize"
  this into an early exit — the fallback message is the whole point off macOS.

## Telemetry

`emit_event` posts a failure-reason code and nothing else: no queries, results,
user, session, or install id. It honors `DO_NOT_TRACK` and `DISABLE_TELEMETRY`.

**Set `DO_NOT_TRACK=1` in anything that exercises these scripts**, including
tests, so a local run never posts to Datadog's intake.

## Testing

```bash
bash tests/hooks_test.sh     # requires jq
```

Covers hook wiring: that `hooks.json` parses, that no hook uses exec form with a
bare interpreter, that every referenced script exists and is executable, and
that both hooks exit `0` on the host. It stubs `uname` to check the
`MINGW64_NT` / `MSYS_NT` / `CYGWIN_NT` / `Linux` paths are silent no-ops.

CI runs it on macOS, Linux and Windows. One Windows job injects
`CLAUDE_PLUGIN_ROOT` as a native backslash path, because Git Bash reports `$PWD`
in Unix form and would otherwise never exercise the path shape that caused #27.

The suite makes no network calls and never opens the ddviz socket.

## Conventions

- Shell scripts target bash and must work under Git Bash. Keep them POSIX-ish;
  macOS ships bash 3.2, so no `declare -A`, no `${var^^}`.
- JSON is read through the `jq`-or-`plutil` helpers in `ddviz_json.sh`. Don't
  assume `jq` is installed — every helper has a `plutil` branch and a "no JSON
  engine" return code.
- A hook must never break the session. Fail open: exit `0` and let the tool
  result through.
- Don't hand-edit `version` in `plugin.json`; releases are cut by
  `.github/workflows/release.yaml`.
