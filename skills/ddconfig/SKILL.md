---
name: ddconfig
description: Configures or troubleshoots the Datadog MCP server `plugin:datadog:mcp`. Use when the user wants to change the Datadog domain, switch organizations, manage a connection when more than one Datadog organization is configured, or when the server was previously configured but is not responding.
---

## Datadog MCP Server

This plugin owns the Datadog MCP servers `plugin:datadog:mcp` (the primary organization) and `plugin:datadog:mcp-2` (an optional second organization). You MUST use these specific servers even if there are other Datadog servers registered. Both belong to this plugin; the org slots table in `mcp-settings.md` maps each slot to its server id, variables, and saved-config files.

## Shared reference

Read [references/mcp-settings.md](references/mcp-settings.md) before proceeding. It contains the `datadog-server-state` check, registration file location, editing rules, and site-to-domain mapping used by the flows below.

## Entry flow

The plugin supports up to two organizations (slots). Check the `datadog-server-state` for **each slot** (see `mcp-settings.md`), using the `datadog://mcp/whoami` resource on that slot's server id as the MCP call (do NOT use any other Datadog MCP server). Do not output anything until the states and resource content are available, and proceed based on the results:

- **Slot 1 is `not-setup`** — the plugin has not been set up at all. Without any preamble, tell the user the plugin is not set up and instruct them to run `/ddsetup`, and stop.
- **Otherwise** — without any preamble, show the user the current connection(s):
  - For each slot whose state is **working** and **valid content**: show the connection (from that slot's `whoami`): user name and email, organization name, and site (the `dd_site` value).
  - For each slot that is **not-working** or **not valid content** (and not `not-setup`): note that organization is configured but not responding.
  - If slot 2 is `not-setup`, do not mention it as an error — optionally let the user know they can add a second organization with `/ddsetup`.

  Then **select the org slot** to operate on (see "Selecting the org slot" in `mcp-settings.md`): if only slot 1 is in use, target it; if both are in use, ask which organization (by its connection identity) to change. For the selected slot, let the user choose between [using a different Datadog MCP domain or site](#domain-flow) or [switching to a different Datadog organization](#organization-flow). If the selected slot is **not-working**, go to the [Troubleshooting Flow](#troubleshooting-flow) for it instead.

Every sub-flow below operates on the **selected slot** — resolve its server id, domain variable, and saved-config files from the org slots table in `mcp-settings.md`.

When communicating with the user below, describe the server state and actions in plain language. Do not reveal what was checked, what was found, or any implementation details like file contents or variable values.

## Troubleshooting Flow

The selected slot's server is configured but not responding. Read its current domain from the registration file (the selected slot's domain variable — see `mcp-settings.md` for the file format and how to find the domain), then present the user with the likely causes — do not follow these sequentially, show them all and use judgment:

- **Domain issue.** Compare the domain against the site-to-domain table in `mcp-settings.md`. Only flag it as suspicious if it looks like a typo or a clearly malformed URL (e.g. `mcp.us5.datadog.com` missing the `hq`). A domain not in the standard table is not necessarily wrong — the user may be using a valid non-standard domain.
- **Authentication.** The authentication may have expired or was never completed, and the user needs to follow these steps (name the selected slot's server id):
  1. Run the command `/mcp` in Claude Code and select the selected slot's server (`plugin:datadog:mcp` or `plugin:datadog:mcp-2`)
  2. Select the authentication option

- **Network or access.** The user's network may be blocking the connection, or their Datadog account may not have API access, like not having the `MCP Read` permission.

If the domain looks wrong, suggest running the [Domain Flow](#domain-flow) to correct it.

## Domain Flow

Changes the Datadog MCP domain the server connects to.

1. Show the selected slot's current domain information (from its `whoami` → `dd_site` if available, or from its domain variable's default in the registration file — see `mcp-settings.md` for the file format). Present it in plain language (e.g. "the plugin is currently connected to …") — follow the "Stay on script" rule in `mcp-settings.md`.
2. **Ask for the new domain.** Present the available sites and their MCP domains from `mcp-settings.md`, and ask which domain to switch to. The user may respond with an MCP domain directly, a site code, a URL, or something else — use the mapping rules in `mcp-settings.md` to resolve the answer. Ask for clarification if ambiguous.

   Follow the "Stay on script" rule in `mcp-settings.md`. In particular, do not preview the follow-up instructions from step 4 below (reload, re-authenticate, etc.) — that step emits them verbatim at the right moment.

3. Edit the **selected slot's** domain variable in the registration file following the editing rule in `mcp-settings.md`.

   Before (slot 1 example):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.eu}
   ```

   After (switching to us1):

   ```
   ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
   ```

   For slot 2, edit `DD_MCP_DOMAIN_2` instead. Then silently write the resolved MCP domain to the selected slot's saved domain file (`${CLAUDE_PLUGIN_DATA}/domain` for slot 1, `${CLAUDE_PLUGIN_DATA}/domain-2` for slot 2; plain text, one line) so it survives plugin updates.

4. Tell the user the domain has been changed and to follow these steps (name the selected slot's server id):
   1. Run the command `/reload-plugins`
   2. Run the command `/mcp` in Claude Code and select the selected slot's server (`plugin:datadog:mcp` or `plugin:datadog:mcp-2`)
   3. Select the authentication option

## Organization Flow

Switches the **selected slot** to a different Datadog organization, **replacing** the organization currently in that slot. The agent cannot do this automatically — the user must select the target organization in the browser.

If the user wants to keep the current organization **and** use another one at the same time (rather than replace it), this is not the right flow — tell them to run `/ddsetup` to add a second organization in the other slot, and stop. (If both slots are already in use, switching one is the only option, since the plugin supports two organizations at a time.)

Otherwise, ask the user if they want to use an organization on the same domain or on a different domain.

- If on the same domain:
  - The user needs to reauthenticate and, during sign-in, choose the target organization in the browser, using the following steps (name the selected slot's server id):
    1. Run the command `/mcp` in Claude Code and select the selected slot's server (`plugin:datadog:mcp` or `plugin:datadog:mcp-2`)
    2. Select the authentication option

- If on a different domain:
  - Run the [Domain Flow](#domain-flow) telling the user to choose the target organization in the browser during sign-in.
