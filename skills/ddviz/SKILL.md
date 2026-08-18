---
name: ddviz
description: Enables, disables, or reports the status of the Datadog visualization panel (ddviz). macOS only. Use when the user wants to turn ddviz on or off, or check whether it's currently enabled.
---

## What this controls

ddviz renders Datadog charts in a floating macOS panel, backed by a background daemon. The forwarding hook reads an opt-out marker file at `$DDVIZ_DATA_DIR` (defaults to `$HOME/.ddviz`).

## Determine the user's intent

- **Status** ("is ddviz on?", "check ddviz"): run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/status.sh"`.
  Present the result as "enabled" or "disabled". Do not describe the file path or implementation details unless asked.
- **Disable**: run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/disable.sh"`.
  Confirm that ddviz is now disabled on this machine, the panel closed if one was open, and future chart calls fall back to the sandbox-URL link.
- **Enable**: run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/enable.sh"`.
  Confirm that ddviz is enabled again. A chart-producing tool call is needed to bring the panel back up, since disabling shuts the daemon down.

If the intent is ambiguous, ask which of the three the user wants.
