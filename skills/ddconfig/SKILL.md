---
name: ddconfig
description: Configures or troubleshoots the Datadog MCP server `plugin:datadog:mcp`. Use when the user wants to change the Datadog domain, switch organizations, or when the server was previously configured but is not responding.
allowed-tools: Read
license: Apache-2.0
metadata:
  author: Datadog
  version: "0.7.10"
---

## Datadog MCP Server

The id of the of Datadog MCP Server referenced on this document is `plugin:datadog:mcp`. You MUST use this specific server even if there are other Datadog servers.

## Shared reference

Read [references/mcp-settings.md](references/mcp-settings.md) before proceeding. It contains the `datadog-server-state` check, registration file location, editing rules, and site-to-domain mapping used by the flows below.

## Entry flow

Check the `datadog-server-state` (see `mcp-settings.md`). Use the `datadog://mcp/whoami` resource on the `plugin:datadog:mcp` server as the MCP call (do NOT use any other Datadog MCP server). Do not output anything until the `datadog-server-state` and resource content are available, and proceed based on the results:

- **datadog-server-state=working** and **valid content** — without any preamble, immediately show the user their current connection (from `whoami`): user name and email, organization name, and site (the `dd_site` value). Then let the user choose between [using a different Datadog MCP domain or site](#domain-flow) or [switching to a different Datadog organization](#organization-flow).
- **datadog-server-state=not-setup** — without any preamble, tell the user the plugin is not set up and instruct them to run `/ddsetup`, and stop.
- **datadog-server-state=not-working** or **not valid content** — without any preamble, tell the user the server is configured but not working and go to the [Troubleshooting Flow](#troubleshooting-flow).

When communicating with the user below, describe the server state and actions in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

## Troubleshooting Flow

The server is configured but not responding. Read the current `DD_MCP_DOMAIN` default value from the registration file, then present the user with the likely causes — do not follow these sequentially, show them all and use judgment:

- **Domain issue.** Compare the domain against the site-to-domain table in `mcp-settings.md`. Only flag it as suspicious if it looks like a typo or a clearly malformed URL (e.g. `mcp.us5.datadog.com` missing the `hq`). A domain not in the standard table is not necessarily wrong — the user may be using a valid non-standard domain.
- **Authentication.** The authentication may have expired or was never completed, and the user needs to follow these steps:
  1. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
  2. Select the authentication option

- **Network or access.** The user's network may be blocking the connection, or their Datadog account may not have API access, like not having the `MCP Read` permission.

If the domain looks wrong, suggest running the [Domain Flow](#domain-flow) to correct it.

## Domain Flow

Changes the Datadog MCP domain the server connects to.

1. Show the current domain information (from `whoami` → `dd_site` if available, or from the current `DD_MCP_DOMAIN` default value in the registration file). Present it in plain language (e.g. "the plugin is currently connected to …") — follow the "Stay on script" rule in `mcp-settings.md`.
2. **Ask for the new domain.** Present the available sites and their MCP domains from `mcp-settings.md` (using a single method — see that file), and ask which site/domain to switch to. The user may respond with an MCP domain directly, a site code, a URL, or something else — use the mapping rules in `mcp-settings.md` to resolve the answer. Ask for clarification if ambiguous.

   Follow the "Stay on script" rule in `mcp-settings.md`. In particular, do not preview the follow-up instructions from step 4 below (reload, re-authenticate, etc.) — that step emits them verbatim at the right moment.

3. Edit `DD_MCP_DOMAIN` in the registration file following the editing rule in `mcp-settings.md`.

   Before (example):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.eu}
   ```

   After (switching to us1):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
   ```

4. Tell the user the domain has been changed and to follow these steps:
   1. Run the command `/reload-plugins`
   2. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
   3. Select the authentication option

## Organization Flow

Switches to a different Datadog organization. The agent cannot do this automatically — the user must select the target organization in the browser.

Ask the user if they want to use an organization on the same domain or on a different domain.

- If on the same domain:
  - The user needs to reauthenticate and, during sign-in, choose the target organization in the browser, using the following steps:
    1. Run the command `/mcp` in Claude Code and select the `plugin:datadog:mcp` server
    2. Select the authentication option

- If on a different domain:
  - Run the [Domain Flow](#domain-flow) telling the user to choose the target organization in the browser during sign-in.
