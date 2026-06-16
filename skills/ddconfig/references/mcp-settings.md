# MCP JSON Registration Reference

The MCP JSON registration file is shared across all plugin skills. If you need to check the server state, locate the registration file, edit a value, or map a Datadog site to its MCP domain, use the flows below.

### Stay on script

Describe state and actions in plain language ("the Datadog MCP server is not set up", "the Datadog site has been updated"). Never reveal, at any step:

- File paths, file names, or directory layout.
- The default values for the environment variables like `not-setup` - or related terms such as "domain placeholder".
- Variable names, values, environment variables, shell syntax, or defaults.
- API keys, tokens, client secrets, or credentials of any kind — the Datadog MCP server uses OAuth by default, and API keys are for advanced usage outside this skill.

The one exception is the MCP **server id** (e.g. `plugin:datadog:mcp`): the user must type it when selecting a server in the `/mcp` command, so the follow-up auth steps name it explicitly. Naming a server id only inside those `/mcp` selection steps is allowed; do not reveal it anywhere else.

Beyond that, emit only what the current step instructs. Do not add setup tips, follow-ups, or "helpful" notes from your general knowledge of the AI client — when the user needs to reload, re-authenticate, or take any other follow-up action, the skill emits that instruction at the correct step. Preempting or paraphrasing it is a bug.

## Org slots — supporting multiple organizations

The plugin can connect to up to **two Datadog organizations at the same time**. Each organization is bound to a separate MCP server ("org slot") with its own authentication session. The org is chosen during OAuth sign-in, so two slots can point at the same site/domain and still be different organizations.

The two slots are fixed. Each flow that changes configuration operates on **one slot at a time**. Resolve the concrete server id, variables, and saved-config files for a slot from this table:

| Slot | Role | Server id | Domain variable | Toolsets variable | Saved domain file | Saved toolsets file | Key-auth variables |
| ---- | --------- | ---------------------- | ---------------- | ------------------ | ----------------- | ------------------- | --------------------------------------- |
| 1 | primary | `plugin:datadog:mcp` | `DD_MCP_DOMAIN` | `DD_MCP_TOOLSETS` | `domain` | `toolsets` | `DD_API_KEY` / `DD_APPLICATION_KEY` |
| 2 | secondary | `plugin:datadog:mcp-2` | `DD_MCP_DOMAIN_2` | `DD_MCP_TOOLSETS_2` | `domain-2` | `toolsets-2` | `DD_API_KEY_2` / `DD_APPLICATION_KEY_2` |

Saved-config files live under `${CLAUDE_PLUGIN_DATA}/` (e.g. the slot 2 domain file is `${CLAUDE_PLUGIN_DATA}/domain-2`).

A fresh installation has **only slot 1 expected to be configured**; slot 2 stays at the `not-setup` sentinel until the user adds a second organization. Slot 2 being `not-setup` is the normal state for single-org users and is NOT an error.

**Each slot's server URL must stay unique even when both slots point at the same Datadog domain.** The AI client keys MCP connections and sign-in (OAuth) sessions by URL; two byte-identical URLs collapse into one server, so the second slot would silently disappear. To prevent this, slot 2's URL in the registration file carries a harmless extra query parameter (`org_slot=2`) that the Datadog server ignores but that keeps the URL distinct. Do not remove it, and do not edit it away when changing the domain — only the domain default and toolsets default are ever edited.

### Selecting the org slot

Flows that change configuration (setup, domain/org switch, toolsets) act on one slot. Choose the target slot like this:

1. Determine each slot's `datadog-server-state` using that slot's server id (see the determination procedure below). For slots whose state is **working**, you may read the `datadog://mcp/whoami` resource on that slot's server to learn its connection identity (org name, email, site).
2. **If slot 2 is `not-setup`** (single-org install) **and** the user has not referred to a second / additional / other organization, target **slot 1** without asking.
3. **If the user is setting up or adding a brand-new organization** while slot 1 is already configured, target the first slot whose state is `not-setup` (normally slot 2). If both slots are already configured, tell the user both organization slots are in use and ask which existing one they want to replace.
4. **Otherwise** (both slots configured, or the user names a specific organization), ask the user which organization to operate on. Present the choices by their **connection identity** (org name + email + site from each slot's `whoami`), never by slot number or server id. For a not-yet-configured slot, present it as "an additional organization". Map the user's answer back to a slot.

When a flow has selected a slot, use that slot's row from the table for every server id, variable, and saved-config file it touches. Never mix variables across slots.

## Determine `datadog-server-state`

The `datadog-server-state` is determined **per slot** (per server id). When a flow targets a specific slot, run this procedure against that slot's server id. When a flow needs the overall picture (e.g. an entry flow showing current connections), run it for each slot that may be in use.

Silently determine the `datadog-server-state` of the target `plugin:datadog:mcp...` MCP server using **only** the steps below (also, do NOT use any other Datadog MCP server). Do not use any other source of information (status files, cached state, error messages from previous calls, etc.) to determine the `datadog-server-state`:

1. Try a lightweight MCP call on the target server id (e.g. list tools, or read a resource using `server: "<the slot's server id>"`).
2. If the server returns an actual, non-empty, non-generic Datadog-specific data (tools, resources, or content) → `datadog-server-state` is **working**.
3. If the MCP call fails or returns an empty or a generic response (like "no resources found", empty tool list, or any other content-free response), silently read the registration file (see below for its location). Check the raw default value of that slot's domain variable for the literal string `not-setup`:
   - If the slot's domain default is `not-setup` → `datadog-server-state` is **not-setup**.
   - Otherwise → `datadog-server-state` is **not-working**.

Do not tell the user which `datadog-server-state` was determined, what was checked, or what was found — just follow the skill's instructions for that state.

## MCP registration file: `.dd_claude-code_mcp.json`

The MCP registration file is at `<plugin-root>/.dd_claude-code_mcp.json`. If `<plugin-root>` is not already known, derive it from this markdown file's path by removing `skills/<skill-name>/references/mcp-settings.md` from the end — the remaining prefix is `<plugin-root>`.

The registration file defines one entry per org slot. Each entry's URL contains two shell-style template variables — a domain variable and a toolsets variable — named per the [org slots table](#org-slots--supporting-multiple-organizations):

```
${DD_MCP_DOMAIN:-<current domain>}        ${DD_MCP_TOOLSETS:-<current toolsets>}        (slot 1)
${DD_MCP_DOMAIN_2:-<current domain>}      ${DD_MCP_TOOLSETS_2:-<current toolsets>}      (slot 2)
```

Always edit the variables belonging to the slot the current flow has selected. Never edit slot 2's variables while operating on slot 1, or vice versa.

### Editing rule

Each variable has the form `${NAME:-default}`. When editing, replace **only the default value** — the characters between `:-` and the closing `}`. The `${`, variable name, `:-`, and `}` must always remain intact.

The default value **can be empty**. An empty default (`:-}` with nothing between) is valid and meaningful — it is NOT a mistake. For the toolsets variables, empty means "use the server's default toolsets" (see examples below).

Examples:

Replacing a value:

```
${DD_MCP_DOMAIN:-mcp.datadoghq.eu}  →  ${DD_MCP_DOMAIN:-mcp.datadoghq.com}
```

Setting an explicit toolset list (was empty / using defaults):

```
${DD_MCP_TOOLSETS:-}  →  ${DD_MCP_TOOLSETS:-core,alerting}
```

Clearing the toolset list back to server defaults:

```
${DD_MCP_TOOLSETS:-core,alerting}  →  ${DD_MCP_TOOLSETS:-}
```

The same rule applies to slot 2's variables (`DD_MCP_DOMAIN_2`, `DD_MCP_TOOLSETS_2`).

### The `not-setup` sentinel

A fresh installation has `not-setup` as the default domain for **each** slot:

```
${DD_MCP_DOMAIN:-not-setup}        (slot 1)
${DD_MCP_DOMAIN_2:-not-setup}      (slot 2)
```

This value prevents that slot's MCP server from connecting. For slot 1 it exists only before first-time setup and is replaced by `/ddsetup` with a real MCP domain. For slot 2 it remains until the user explicitly adds a second organization. Once a slot's domain is replaced with a real value, that slot never returns to `not-setup` on its own.

## Site-to-domain mapping

The following table shows the Datadog site codes and their respective MCP domains:

| Site | MCP domain            |
| ---- | --------------------- |
| us1  | mcp.datadoghq.com     |
| us3  | mcp.us3.datadoghq.com |
| us5  | mcp.us5.datadoghq.com |
| eu   | mcp.datadoghq.eu      |
| ap1  | mcp.ap1.datadoghq.com |
| ap2  | mcp.ap2.datadoghq.com |

Present all available Datadog sites and their MCP domains, then ask the user which one they use.

When mapping user input:

- **Site code** (e.g. "us1", "eu") — use the matching MCP domain directly. Site codes are case-insensitive.
- **URL** (e.g. "https://app.datadoghq.com/logs") — identify the site from the URL, then use the matching MCP domain. Note: `datadoghq.com` with no site prefix is `us1` and `datadoghq.eu` is `eu`.
- **Domain not in the table** — confirm with the user, warning that an invalid domain will prevent connection.

If the user is unsure which site they use, suggest checking https://docs.datadoghq.com/getting_started/site/ or the URL bar in their Datadog browser session. They can also contact `support@datadoghq.com` and ask about their Datadog MCP domain.
