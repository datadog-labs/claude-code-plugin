---
name: ddtoolsets
description: Manages toolsets for the Datadog MCP server `plugin:datadog:mcp`. Use when the user wants to view, enable, or disable toolsets that control which tools are available on the MCP server.
allowed-tools: Read
license: Apache-2.0
metadata:
  author: Datadog
  version: "0.7.10"
---

## Datadog MCP Server

The id of the of Datadog MCP Server referenced on this document is `plugin:datadog:mcp`. You MUST use this specific server even if there are other Datadog servers.

## Shared reference

Read [references/mcp-settings.md](references/mcp-settings.md) before proceeding. It contains the `datadog-server-state` check, registration file location, and editing rules used by the flows below.

## Entry flow

Check the `datadog-server-state` (see `mcp-settings.md`). Use the `datadog://mcp/toolsets` resource on the `plugin:datadog:mcp` server as the MCP call (do NOT use any other Datadog MCP server). Do not output anything until the `datadog-server-state` and resource content are available, and proceed based on the results:

- **datadog-server-state=working** AND **valid content** — without any preamble, go to the [Toolsets Flow](#toolsets-flow).
- **datadog-server-state=not-setup** — without any preamble, tell the user the plugin is not set up and instruct them to run `/ddsetup`, and stop.
- **datadog-server-state=not-working** OR **not valid content** — without any preamble, tell the user the server is configured but not working, instruct them to run `/ddconfig`, and stop.

When communicating with the user below, describe the server state and actions in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

## Toolsets Flow

A toolset is a named group of related tools for a specific Datadog feature. Enabling a toolset makes its tools available; disabling it removes them.

### How toolset defaults work

The `DD_MCP_TOOLSETS` default value in the registration file controls which toolsets are active. It has two states:

- **Empty** (`${DD_MCP_TOOLSETS:-}`) — the server decides which toolsets to enable. This is the preferred state because the plugin automatically picks up new default toolsets added by the server in the future.
- **Explicit** (`${DD_MCP_TOOLSETS:-core,alerting}`) — exactly these toolsets are enabled, nothing more. The server's defaults are ignored. If the server adds a new default toolset later, this plugin will NOT pick it up.

The order of toolsets in the comma-separated list is not meaningful. `core,alerting` and `alerting,core` are equivalent. When comparing lists (e.g. to check if the result matches the defaults), compare as sets, not strings.

When computing changes, always prefer empty over an explicit list that happens to match the current defaults. See the editing rule in `mcp-settings.md` for how to set an empty default value.

### 1. Gather toolset information

Use the content of the `datadog://mcp/toolsets` resource from the `plugin:datadog:mcp` MCP server. This tells you which toolsets exist, which are currently enabled, which are defaults, and what each one does. Present this information to the user — choose the best format for the client (selectable list, table, grouped summary, etc.). Make it easy for the user to identify which toolsets are currently enabled and which toolsets are available to them.

Also read the current `DD_MCP_TOOLSETS` default value from the registration file. If it is empty, the user is currently using server defaults. If it has an explicit list, those are the manually selected toolsets. Any toolset name in the registration file that does not appear in the `datadog://mcp/toolsets` resource is unknown — ignore it when presenting to the user and silently drop it when writing the updated list.

### 2. Understand the user's intent

The user may want to:

- **Add** more toolsets to the currently enabled list
- **Remove** toolsets from the currently enabled list
- **Replace** the entire list with a specific set of toolsets

Understand the user's intent from their response. Ask for clarification if ambiguous.

**Important:** If the current default value is empty (server defaults) and the user wants to add a toolset, you need to know what the defaults ARE so you can build the full list. Use the default information from the `datadog://mcp/toolsets` resource.

### 3. Compute the new toolset list

Apply the user's changes to produce a new comma-separated value for `DD_MCP_TOOLSETS`:

- If the resulting list matches the default toolsets exactly → use an empty string (revert to server defaults).
- If the user wants to revert to defaults (e.g. "reset", "use defaults") → use an empty string.
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

### 5. Confirm

Tell the user the toolsets have been updated including which toolsets are now enabled, and that they need to follow these steps:

1. Run the command `/reload-plugins`
2. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
3. Select the authentication option
