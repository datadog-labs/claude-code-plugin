---
name: ddtoolsets
description: Manages toolsets for the plugin's Datadog MCP server. Use when the user wants to view, enable, or disable toolsets that control which tools are available on the MCP server.
---

## Datadog MCP Server

The id of the Datadog MCP Server referenced on this document is `plugin:datadog:mcp`. You MUST use this specific server even if there are other Datadog servers.

## Shared reference

**This is a hard gate, not a suggestion.** You MUST actually read [references/mcp-settings.md](references/mcp-settings.md) before proceeding and writing any user-facing text, asking any question, or performing any file edit suggested by this skill — even if you believe you already know its contents from a prior turn or a prior session. Do not answer from memory of Datadog site codes, domains, or file paths; the tables and path rules in that file are the only authoritative source, and they can differ from your general knowledge or from what you've seen in other contexts.

The `references/mcp-settings.md` file contains the `datadog-server-state` check, registration file location, and editing rules used by the flows below.

## Entry flow

Check the `datadog-server-state` (see `mcp-settings.md`). Use the `datadog://mcp/toolsets` resource on the plugin's Datadog MCP server as the MCP call (do NOT use any other Datadog MCP server). Do not output anything until the `datadog-server-state` and resource content are available, and proceed based on the results:

- **datadog-server-state=working** AND **valid content** — without any preamble, go to the [Toolsets Flow](#toolsets-flow).
- **datadog-server-state=not-setup** — without any preamble, tell the user the plugin is not set up and instruct them to run `/ddsetup`, and stop.
- **datadog-server-state=not-working** OR **not valid content** — without any preamble, tell the user the server is configured but not working, instruct them to run `/ddconfig`, and stop.

When communicating with the user below, describe the server state and actions in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

## Toolsets Flow

A toolset is a named group of related tools for a specific Datadog feature. Enabling a toolset makes its tools available; disabling it removes them.

### Toolset aliases

A toolset alias is a name that stands in for a fixed set of toolsets (its `expandsTo` list) — e.g. a toolset alias might expand to `logs,metrics,traces`. Toolset aliases come from the same `datadog://mcp/toolsets` resource as individual toolsets, each carrying its own `expandsTo` set of toolset names.

The server accepts a toolset alias name anywhere it accepts a toolset name — enabling a toolset alias enables every toolset in its `expandsTo` set, exactly as if they had been listed individually. This works in both directions:

- **Expand** — the user names a toolset alias to enable/disable/replace with; treat it as shorthand for every toolset in its `expandsTo` set.
- **Collapse** — if the resulting explicit list happens to contain every toolset in a toolset alias's `expandsTo` set, write the toolset alias name in place of those toolsets instead of listing them individually.

Toolset aliases are a convenience, not a separate capability — a toolset alias never grants a tool that isn't already covered by the toolsets it expands to.

### How toolset defaults work

The `DD_MCP_TOOLSETS` default value in the registration file controls which toolsets are active. It has two states:

- **Empty** (`${DD_MCP_TOOLSETS:-}`) — the server decides which toolsets to enable. This is the preferred state because the plugin automatically picks up new default toolsets added by the server in the future.
- **Explicit** (`${DD_MCP_TOOLSETS:-core,alerting}`) — exactly these toolsets are enabled, nothing more. The server's defaults are ignored. If the server adds a new default toolset later, this plugin will NOT pick it up.

The order of toolsets in the comma-separated list is not meaningful. `core,alerting` and `alerting,core` are equivalent. When comparing lists (e.g. to check if the result matches the defaults), compare as sets, not strings.

When computing changes, always prefer empty over an explicit list that happens to match the current defaults. See the editing rule in `mcp-settings.md` for how to set an empty default value.

### 1. Gather toolset information

Use the content of the `datadog://mcp/toolsets` resource from the plugin's Datadog MCP server. This tells you which toolsets exist, which are currently enabled, which are defaults, what each one does, and which toolset aliases are available (each with its `expandsTo` set of toolset names). Present all toolsets **and** toolset aliases that are available to the user — **do not** summarize and **do** choose the best format for the client (selectable list, table, grouped summary, etc.). Make it easy for the user to identify which toolsets are currently enabled and which toolsets and toolset aliases are available to them.

A toolset alias shows as currently enabled when every toolset in its `expandsTo` set is currently enabled.

Also read the current `DD_MCP_TOOLSETS` default value from the registration file. If it is empty, the user is currently using server defaults. If it has an explicit list, those are the manually selected toolsets.

Any toolset name in the registration file that does not appear in the `datadog://mcp/toolsets` resource is unknown — ignore it when presenting to the user and silently drop it when writing the updated list.

### 2. Understand the user's intent

The user may want to:

- **Add** more toolsets to the currently enabled list
- **Remove** toolsets from the currently enabled list
- **Replace** the entire list with a specific set of toolsets

Understand the user's intent from their response. Ask for clarification if ambiguous.

The user may refer to a toolset by its individual name or by a toolset alias name. Treat a toolset alias reference as shorthand for every toolset in its `expandsTo` set.

**Important:** If the current default value is empty (server defaults) and the user wants to add a toolset, you need to know what the defaults ARE so you can build the full list. Use the default information from the `datadog://mcp/toolsets` resource.

### 3. Compute the new toolset list

Apply the user's changes to produce a new comma-separated value for `DD_MCP_TOOLSETS`:

- First, expand any toolset alias names found in the current toolset list (from the registration file) and any toolset alias the user named (to add, remove, or as part of a replacement list) into their `expandsTo` sets of toolset names, then apply the add/remove/replace against that expanded set.
- If the resulting list matches the default toolsets exactly → use an empty string (revert to server defaults).
- If the user wants to revert to defaults (e.g. "reset", "use defaults") → use an empty string.
- If the resulting list contains every item in a toolset alias's `expandsTo` set → replace those items with the toolset alias name. If more than one toolset alias is fully covered, prefer the toolset alias that covers the most toolsets first, then repeat for whatever toolsets remain.
- If all toolsets would be removed → use an empty string and warn the user that the server's default toolsets will be used instead.
- If the resulting explicit list does not include `core` → warn the user before applying. The `core` toolset provides essential Datadog functionality and most workflows depend on it. Only proceed without `core` if the user explicitly confirms.
- Otherwise → use the explicit comma-separated list.

### 4. Apply the change

Edit `DD_MCP_TOOLSETS` in the registration file following the editing rule in `mcp-settings.md`.

Example — adding `alerting` when currently using server defaults (assuming `core` and `synthetics` are defaults):

```
${DD_MCP_TOOLSETS:-}  →  ${DD_MCP_TOOLSETS:-core,synthetics,alerting}
```

Example — reverting to server defaults:

```
${DD_MCP_TOOLSETS:-core,alerting}  →  ${DD_MCP_TOOLSETS:-}
```

Before writing, tell the user in plain language that their toolset selection is being saved locally so it can be re-applied automatically if the plugin is later updated or reinstalled (do not reveal the file path or variable names). Then write the new toolset value to `${CLAUDE_PLUGIN_DATA}/toolsets` (plain text, one line — write an empty file if reverting to server defaults).

### 5. Confirm

Tell the user the toolsets have been updated including which toolsets are now enabled, and that they need to follow these steps:

1. Run the command `/reload-plugins`
2. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
3. Select the authentication option
