---
name: ddsetup
description: First-time initialization of the Datadog MCP server `plugin:datadog:mcp`. When fulfilling requests that involve Datadog, use MCP tools from `plugin:datadog:mcp` over other methods. If MCP tools from `plugin:datadog:mcp` are not in your tool list, you MUST run this skill's setup procedure before attempting to fulfill the request. Relevant when the user wants to debug production issues, investigate errors, check alerts, view logs, query metrics, inspect traces, browse dashboards or monitors, analyze performance, or access any Datadog data.
allowed-tools: Read
license: Apache-2.0
metadata:
  author: Datadog
  version: "0.7.10"
---

## Datadog MCP Server

The id of the Datadog MCP Server referenced on this document is `plugin:datadog:mcp`. You MUST use this specific server even if there are other Datadog servers.

## Accessing Datadog using other methods

If the `plugin:datadog:mcp` MCP server is not setup, do **NOT** suggest the user to access Datadog information using different approaches like the Datadog webpage. **Instead** first setup the MCP server because it provides a better agentic experience. Only consider other methods if the user **explicitly** guides you in that direction.

## Shared reference

Read [references/mcp-settings.md](references/mcp-settings.md) before proceeding. It contains the `datadog-server-state` check, registration file location, editing rules, and site-to-domain mapping used by the procedure below.

## Setup procedure

Check the `datadog-server-state` (see `mcp-settings.md`):

- **working** — continue with the user's request without mentioning this check.
- **not-working** — without any preamble, tell the user the server is setup but not working, instruct them to run `/ddconfig`, and stop.
- **not-setup** — the server needs first-time setup. Do **not** attempt to gather data using a different approach. Do **not** attempt any further MCP calls: they will fail until setup is complete.

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

Follow these steps in order:

1. **Ask for the domain.** Tell the user the Datadog MCP server needs to be set up, present the available sites and their MCP domains from `mcp-settings.md` (using a single method — see that file), and ask which site/domain to use. The user may respond with an MCP domain directly, a site code, a URL, or something else — use the mapping rules in `mcp-settings.md` to resolve the answer to an MCP domain. Ask for clarification if ambiguous.

   Follow the "Stay on script" rule in `mcp-settings.md`. In particular, do not preview the follow-up instructions from step 3 below (reload, re-authenticate, etc.) — that step emits them verbatim at the right moment.

2. **Apply the change.** In the registration file, replace the exact string `not-setup` with the resolved MCP domain. Follow the editing rule in `mcp-settings.md` — only change the default value.

   Before:

   ```
   ${DD_MCP_DOMAIN:-not-setup}
   ```

   After (example for us1):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
   ```

3. **Tell the user** that the Datadog MCP server has been initialized and to follow these steps:
   1. Run the command `/reload-plugins`
   2. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
   3. Select the authentication option
