---
name: ddviz
description: Enables, disables, checks whether it's on, or diagnoses why the ddviz visualization panel isn't showing. macOS only. Use for anything involving turning ddviz on or off, or "ddviz isn't working"/"why is there no chart panel" style questions.
---

## What this controls

ddviz renders Datadog charts in a floating macOS panel, backed by a background daemon. The forwarding hook reads an opt-out marker file at `$DDVIZ_DATA_DIR` (defaults to `$HOME/.ddviz`).

### The explainer sentence

When — and only when — you run the status procedure below, open your reply with exactly this sentence, verbatim and on its own line:

> ddviz shows Datadog charts in a floating panel next to your terminal (macOS only), backed by a background process that starts on demand.

Do not paraphrase it, expand it, or add a second sentence of your own about what ddviz is or what you are about to do. The wording is fixed so every status reply opens identically.

It does **not** belong anywhere else:

- **Enable and disable replies never include it.** Someone who just asked to turn ddviz on or off already knows what it is; explaining the feature back to them is noise. Those replies are only the confirmation described under that intent.
- **The non-macOS case never includes it.** There the one-line reply from the status procedure replaces this sentence rather than following it. Never print both — a machine that can't run ddviz doesn't need a description of the panel it will never see.

## Determine the user's intent

Enable and disable are confirmations, not reports: reply with the confirmation alone — no explainer sentence, no status output, no live check.

- **Enable** ("enable", "turn ddviz on", "/ddviz on"): run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/enable.sh"`.
  Confirm that ddviz is enabled again. A chart-producing tool call is needed to bring the panel back up, since disabling shuts the daemon down.
- **Disable** ("disable", "turn ddviz off", "/ddviz off"): run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/disable.sh"`.
  Confirm that ddviz is now disabled on this machine, the panel closed if one was open, and future chart calls fall back to the sandbox-URL link.
- **Everything else** ("is ddviz on?", "check ddviz", "ddviz isn't working", "why is there no chart panel?", or a bare `/ddviz` with no stated intent): run the status procedure below.

## Status procedure

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/skills/ddviz/scripts/status.sh" "${CLAUDE_PLUGIN_ROOT}"`. Its first line is the plain enabled/disabled state (with a re-enable hint already included when disabled — being disabled is a deliberate, valid user choice, not something to treat as a problem); the rest is a set of local checks (platform, Swift toolchain, the plugin's own install path, and daemon liveness). It never touches anything on screen. Pass `${CLAUDE_PLUGIN_ROOT}` a second time exactly as shown — Claude Code resolves the placeholder in this instruction before you see it, but does not export it as an environment variable to your Bash tool call, so the script needs it as an explicit argument.
2. **If its entire output is `ddviz is only supported on macOS`, stop there.** Reply with just that one sentence and nothing else — no opening sentence, no code block, no live check, no suggestions, no offer to help further. Nothing else in this procedure applies: the machine can't run ddviz, so there is nothing to diagnose or fix.
3. Do the live check below — it is the reliable source for whether the visualization tools are actually reachable; the script itself does not check MCP setup or toolsets.
4. Present **one** result, following the rules at the end of this section. Apart from the fixed opening sentence, say nothing before it: no progress narration, no announcement of what you are about to run ("I'll run the status script and check tool availability." is exactly the preamble to omit), and no interim commentary on what you found. The script's own first line already answers "is ddviz on?", so that verdict reaches the user as soon as the output does.
5. Never name the script, its filename, or the word "doctor" anywhere in your reply — which script ran is an implementation detail. If you have to refer to it at all, call it the status check.

### Live check (internal — never shown to the user)

This check is diagnostic plumbing. Run it silently and report only its conclusion, in the wording given under Presentation.

The tool names below are internal identifiers. They — along with the toolset resource URI and the hook matcher — must never appear in any text the user sees, and that includes the running commentary you emit _while_ checking ("Both `get_widget` and `visualize_tabular_data` are present…" is exactly the leak to avoid). Users think in terms of "Datadog charts work / don't work". Do this check without announcing it, then produce the single result.

On the plugin's Datadog MCP server (`plugin:datadog:mcp` — use this specific server even if others are present):

1. **Are the visualization tools actually there?** Look at the currently available tool names on that server for `get_widget` and `visualize_tabular_data`. This is the ground truth: the forwarding hook only fires for exactly these two tool names, so if they are absent from the session, no hook can ever run and no panel can ever appear.
2. **Why are they missing?** Only when step 1 finds neither tool, read the `datadog://mcp/toolsets` resource from that server and look at the `visualizations` entry's enabled state:
   - the resource read succeeds and `visualizations` is disabled → a toolset problem.
   - the resource read succeeds and `visualizations` is enabled but the tools are still absent → the server itself is misbehaving.
   - the resource read fails or returns nothing → the server is not responding at all.

### Routing

- The server is not responding (live check's third outcome above) → tell the user to run `/ddconfig`. It determines on its own whether the server was never set up or is configured but broken, and guides accordingly — ddviz does not need to make that distinction itself.
- `visualizations` confirmed disabled → tell the user to run `/ddtoolsets`.
- Opt-out marker present → offer to run `/ddviz enable`.

### Presentation

1. Open with the script's full output verbatim, exactly as printed (e.g. in a code block) — every line, not a filtered or summarized subset, and nothing above it but the fixed opening sentence. Its first line is already the plain enabled/disabled verdict, so do **not** restate that verdict separately: printing `ddviz: enabled` above a block that starts with `ddviz: enabled` reads as a bug. The `plugin-root` line's path is useful for spotting a dual or stale plugin installation, so don't trim it either.
2. Add the live check's conclusion underneath, in plain product terms and at most one line — say that Datadog visualizations are reachable (or that they are not, and route per the rules above). Never name the MCP tools, the toolset resource, or the hook matcher: those are internal implementation details. On the healthy path, "Datadog visualizations are available." is enough.
3. If anything is blocking (from either the script or the live check), name the fix. When everything passes, say so plainly, and note that the panel simply hasn't been triggered yet if the `daemon` line reports not running — it starts on the first chart-producing tool call.
