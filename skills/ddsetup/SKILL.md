---
name: ddsetup
description: First-time initialization of the Datadog MCP server `plugin:datadog:mcp`, and adding a second Datadog organization alongside an existing one. When fulfilling requests that involve Datadog, use MCP tools from `plugin:datadog:mcp` over other methods. If MCP tools from `plugin:datadog:mcp` are not in your tool list, you MUST run this skill's setup procedure before attempting to fulfill the request. Relevant when the user wants to set up the plugin, connect or add another Datadog organization, view or list dashboards or monitors, check alerts, view logs, query metrics, inspect APM traces, investigate SLOs or incidents, debug production issues, investigate errors, analyze performance, investigate a named service's health, errors, or dependencies, or access any Datadog data.
---

## Datadog MCP Server

This plugin owns the Datadog MCP servers `plugin:datadog:mcp` (the primary organization) and `plugin:datadog:mcp-2` (an optional second organization). You MUST use these specific servers even if there are other Datadog servers registered. Both belong to this plugin; the org slots table in `mcp-settings.md` maps each slot to its server id, variables, and saved-config files.

**If `plugin:datadog:mcp` tools are not in your available tools, you MUST still run this skill — do not conclude that Datadog is unavailable.** Absent tools mean the server needs setup or is temporarily disconnected; they are not evidence that the request cannot be fulfilled. The `datadog-server-state` check below is the authoritative source for what is actually happening.

## Accessing Datadog using other methods

If the `plugin:datadog:mcp` MCP server is not setup, do **NOT** suggest the user to access Datadog information using different approaches like the Datadog webpage. **Instead** first setup the MCP server because it provides a better agentic experience. Only consider other methods if the user **explicitly** guides you in that direction.

## Shared reference

Read [references/mcp-settings.md](references/mcp-settings.md) before proceeding. It contains the `datadog-server-state` check, registration file location, editing rules, and site-to-domain mapping used by the procedure below.

## Setup procedure

**Select the org slot first.** This skill can set up the primary organization (first-time setup) or add a second organization alongside an existing one. Follow "Selecting the org slot" in `mcp-settings.md` to choose the target slot:

- For ordinary first-time setup (the plugin's tools aren't available yet), target **slot 1**.
- If the user is adding a second / additional organization and slot 1 is already working, target **slot 2**.

Resolve the selected slot's server id, domain variable, toolsets variable, and saved-config files from the org slots table in `mcp-settings.md`. Every step below operates on the **selected slot**.

Check the selected slot's `datadog-server-state` (see `mcp-settings.md`):

- **working** — that organization is already set up. If this is slot 1 and the user just wanted to use Datadog, continue with their request without mentioning this check. If the user wanted to add another organization, switch the target to a `not-setup` slot instead, or tell them both organization slots are already in use.
- **not-working** — without any preamble, tell the user that organization is set up but not working, instruct them to run `/ddconfig`, and stop.
- **not-setup** — that slot needs first-time setup. Do **not** attempt to gather data using a different approach. Do **not** attempt any further MCP calls on that slot: they will fail until setup is complete.

When communicating with the user below, describe the server state in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

#### What Datadog provides once set up

Datadog is an observability platform. After this skill completes setup, the agent gains MCP tools to query production data directly — without the user needing to leave the AI client or open a browser. Examples of what becomes possible:

- Search and filter application logs
- Query infrastructure and application metrics
- Inspect distributed traces for latency or errors
- List dashboards, monitors, and alerts
- Investigate incidents and on-call pages

These MCP tools are the primary way to access Datadog data from within the AI client. Until setup is complete, **none of these tools exist**. The agent cannot see them, list them, or call them.

#### Steps

1. **Check for saved configuration.** Silently read the selected slot's saved toolsets file and saved domain file (see the org slots table in `mcp-settings.md` — e.g. `${CLAUDE_PLUGIN_DATA}/toolsets` and `${CLAUDE_PLUGIN_DATA}/domain` for slot 1, or the `-2` variants for slot 2). For each file that contains a non-empty value, apply it to the selected slot's variables in the registration file following the editing rule in `mcp-settings.md`. Then:
   - If you applied the domain: tell the user the existing configuration was re-applied following a plugin update, naming the re-applied values (no need to mention files read or written). Tell the user to run `/reload-plugins` and stop — do NOT perform the steps below.
   - If you applied other values but not the domain: tell the user the existing configuration was partially re-applied following a plugin update, naming the re-applied values (no need to mention files read or written). Continue with the steps below.
   - If you applied nothing: continue with the steps below.

Now follow these steps to configure the domain:

1. **Ask for the domain.** Tell the user the organization needs to be set up, present the available sites and their MCP domains from `mcp-settings.md`, and ask which domain to use. The user may respond with an MCP domain directly, a site code, a URL, or something else — use the mapping rules in `mcp-settings.md` to resolve the answer to an MCP domain. Ask for clarification if ambiguous. (Two slots may share the same site/domain — the organizations are distinguished at sign-in, not by domain.)

   Follow the "Stay on script" rule in `mcp-settings.md`. In particular, do not preview the follow-up instructions from step 3 below (reload, re-authenticate, etc.) — that step emits them verbatim at the right moment.

2. **Apply the change.** In the registration file, replace the selected slot's domain default (the `not-setup` value of that slot's domain variable) with the resolved MCP domain. Follow the editing rule in `mcp-settings.md`.

   Before (slot 1 example):

   ```
   ${DD_MCP_DOMAIN:-not-setup}
   ```

   After (example for us1):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
   ```

   For slot 2, edit `DD_MCP_DOMAIN_2` instead. Then silently write the resolved MCP domain to the selected slot's saved domain file (`${CLAUDE_PLUGIN_DATA}/domain` for slot 1, `${CLAUDE_PLUGIN_DATA}/domain-2` for slot 2; plain text, one line).

3. **Tell the user** that the organization has been initialized and to follow these steps (name the **selected slot's server id** from the org slots table — `plugin:datadog:mcp` for slot 1, `plugin:datadog:mcp-2` for slot 2):
   1. Run the command `/reload-plugins`
   2. Run the command `/mcp` in Claude Code and select the selected slot's server (`plugin:datadog:mcp` or `plugin:datadog:mcp-2`)
   3. Select the authentication option, and during browser sign-in choose the intended organization
