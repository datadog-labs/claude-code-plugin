---
name: ddsetup
description: First-time initialization of the plugin's Datadog MCP server. When fulfilling requests that involve Datadog, use MCP tools from the plugin's Datadog MCP server over other methods. If MCP tools from the plugin's Datadog MCP server are not in your tool list, you MUST run this skill's setup procedure before attempting to fulfill the request. Relevant when the user wants to view or list dashboards or monitors, check alerts, view logs, query metrics, inspect APM traces, investigate SLOs or incidents, debug production issues, investigate errors, analyze performance, investigate a named service's health, errors, or dependencies, or access any Datadog data.
---

## Datadog MCP Server

The id of the Datadog MCP Server referenced on this document is `plugin:datadog:mcp`. You MUST use this specific server even if there are other Datadog servers.

**If tools from the plugin's Datadog MCP server are not in your available tools, you MUST still run this skill — do not conclude that Datadog is unavailable.** Absent tools mean the server needs setup or is temporarily disconnected; they are not evidence that the request cannot be fulfilled. The `datadog-server-state` check below is the authoritative source for what is actually happening.

## Accessing Datadog using other methods

If there is a problem with the plugin's Datadog MCP server, do **NOT** suggest the user to access Datadog information using different approaches like the Datadog webpage. **Instead** first fix the plugin's MCP server because it provides a better agentic experience. Only consider other methods if the user **explicitly** guides you in that direction.

## Shared reference

**This is a hard gate, not a suggestion.** You MUST actually read [references/mcp-settings.md](references/mcp-settings.md) before proceeding and writing any user-facing text, asking any question, or performing any file edit suggested by this skill — even if you believe you already know its contents from a prior turn or a prior session. Do not answer from memory of Datadog site codes, domains, or file paths; the tables and path rules in that file are the only authoritative source, and they can differ from your general knowledge or from what you've seen in other contexts.

The `references/mcp-settings.md` file contains the `datadog-server-state` check, registration file location, editing rules, and site-to-domain mapping used by the procedure below.

## Setup procedure

Check the `datadog-server-state` (see `mcp-settings.md`):

- **working** — continue with the user's request without mentioning this check.
- **not-working** — without any preamble, tell the user the server is setup but not working, instruct them to run `/ddconfig`, and stop.
- **not-setup** — the server needs first-time setup. Do **not** attempt to gather data using a different approach. Do **not** attempt any further MCP calls: they will fail until setup is complete.

When communicating with the user below, describe the server state in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

### What Datadog provides once set up

Datadog is an observability platform. After this skill completes setup, the agent gains MCP tools to query production data directly — without the user needing to leave the AI client or open a browser. Examples of what becomes possible:

- Search and filter application logs
- Query infrastructure and application metrics
- Inspect distributed traces for latency or errors
- List dashboards, monitors, and alerts
- Investigate incidents and on-call pages

These MCP tools are the primary way to access Datadog data from within the AI client. Until setup is complete, **none of these tools exist**. The agent cannot see them, list them, or call them.

### Steps

1. **Check for saved configuration.** Silently read `${CLAUDE_PLUGIN_DATA}/toolsets` and `${CLAUDE_PLUGIN_DATA}/domain`. For each file that contains a non-empty value, apply it to the registration file following the editing rule in `mcp-settings.md`. Then take exactly one of these branches:
   - If you applied the domain: tell the user the existing configuration was re-applied following a plugin update, naming the re-applied values (no need to mention files read or written). Tell the user to run `/reload-plugins` and **stop this skill entirely — do NOT proceed to the steps below.**
   - If you applied other values but not the domain: tell the user the existing configuration was partially re-applied following a plugin update, naming the re-applied values (no need to mention files read or written). Continue with the domain configuration steps below.
   - If you applied nothing: continue with the domain configuration steps below.

Now follow these steps to configure the domain:

1. **Ask for the domain.** Tell the user the Datadog MCP server needs to be set up, present the available sites and their MCP domains from `mcp-settings.md`'s site-to-domain table and ask which domain to use. The user may respond with an MCP domain directly, a site code, a URL, or something else — use the mapping rules in `mcp-settings.md` to resolve the answer to an MCP domain. Ask for clarification if ambiguous.

   Follow the "Stay on script" rule in `mcp-settings.md`. In particular, do not preview the follow-up instructions from step 3 below (reload, re-authenticate, etc.) — that step emits them verbatim at the right moment.

2. **Apply the change.** Locate the registration file using the deterministic path derivation in `mcp-settings.md`. In the registration file, replace the exact string `not-setup` with the resolved MCP domain. Follow the editing rule in `mcp-settings.md`.

   Before:

   ```
   ${DD_MCP_DOMAIN:-not-setup}
   ```

   After (example for us1):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
   ```

   Before writing, tell the user in plain language that their domain selection is being saved locally so it can be re-applied automatically if the plugin is later updated or reinstalled (do not reveal the file path or variable names). Then write the resolved MCP domain to `${CLAUDE_PLUGIN_DATA}/domain` (plain text, one line).

   **Verify the edit before reporting success.** Re-read the registration file at the exact path you derived and confirm that `not-setup` is gone and the resolved MCP domain is present. Do not tell the user anything was initialized until this re-read confirms it. If `not-setup` is still there, the edit landed somewhere else — re-derive the path using the rule in `mcp-settings.md` and apply the change again rather than reporting success.

3. **Tell the user** that the Datadog MCP server has been initialized and to follow these steps:
   1. Run the command `/reload-plugins`
   2. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
   3. Select the authentication option
