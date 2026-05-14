# MCP JSON Registration Reference

The MCP JSON registration file is shared across all plugin skills. If you need to check the server state, locate the registration file, edit a value, or map a Datadog site to its MCP domain, use the flows below.

### Stay on script

Describe state and actions in plain language ("the Datadog MCP server is not set up", "the Datadog site has been updated"). Never reveal, at any step:

- File paths, file names, or directory layout.
- The default values for the environment variables like `not-setup` - or related terms such as "domain placeholder".
- Variable names, values, environment variables, shell syntax, or defaults.
- API keys, tokens, client secrets, or credentials of any kind — the Datadog MCP server uses OAuth by default, and API keys are for advanced usage outside this skill.

Beyond that, emit only what the current step instructs. Do not add setup tips, follow-ups, or "helpful" notes from your general knowledge of the AI client — when the user needs to reload, re-authenticate, or take any other follow-up action, the skill emits that instruction at the correct step. Pre-empting or paraphrasing it is a bug.

## Determine `datadog-server-state`

Silently determine the `datadog-server-state` of the `plugin:datadog:mcp` MCP server using **only** the steps below (also, do NOT use any other Datadog MCP server). Do not use any other source of information (status files, cached state, error messages from previous calls, etc.) to determine the `datadog-server-state`:

1. Try a lightweight MCP call on `plugin:datadog:mcp` (e.g. list tools, or read a resource using `server: "plugin:datadog:mcp"`).
2. If the server returns an actual, non-empty, non-generic Datadog-specific data (tools, resources, or content) → `datadog-server-state` is **working**.
3. If the MCP call fails or returns an empty or a generic response (like "no resources found", empty tool list, or any other content-free response), silently read the registration file (see below for its location). Check the raw file content for the literal string `not-setup`:
   - If the file contains `not-setup` → `datadog-server-state` is **not-setup**.
   - Otherwise → `datadog-server-state` is **not-working**.

Do not tell the user which `datadog-server-state` was determined, what was checked, or what was found — just follow the skill's instructions for that state.

## Registration file

Both this reference file (`<plugin-root>/skills/ddsetup/references/mcp-settings.md`) and the MCP registration file (`<plugin-root>/.mcp.json`) are located in `<plugin-root>`, the plugin's root directory. The registration file contains a URL with two shell-style template variables:

```
${DD_MCP_DOMAIN:-<current domain>}
${DD_MCP_TOOLSETS:-<current toolsets>}
```

### Editing rule

Each variable has the form `${NAME:-default}`. When editing, replace **only the default value** — the characters between `:-` and the closing `}`. The `${`, variable name, `:-`, and `}` must always remain intact.

The default value **can be empty**. An empty default (`:-}` with nothing between) is valid and meaningful — it is NOT a mistake. For `DD_MCP_TOOLSETS`, empty means "use the server's default toolsets" (see examples below).

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

### The `not-setup` sentinel

A fresh installation has `not-setup` as the default domain:

```
${DD_MCP_DOMAIN:-not-setup}
```

This value prevents the MCP server from connecting. It exists only before first-time setup and is replaced by `/ddsetup` with a real MCP domain. Once replaced, it never returns to `not-setup`.

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

Present the site options to the user using a single method — for example, don't combine a text list with an interactive picker. Choose whichever best fits the number of options and available UI capabilities.

When mapping user input:

- **Site code** (e.g. "us1", "eu") — use the matching MCP domain directly. Site codes are case-insensitive.
- **URL** (e.g. "https://app.datadoghq.com/logs") — identify the site from the URL, then use the matching MCP domain. Note: `datadoghq.com` with no site prefix is `us1` and `datadoghq.eu` is `eu`.
- **Domain not in the table** — confirm with the user, warning that an invalid domain will prevent connection.

If the user is unsure which site they use, suggest checking https://docs.datadoghq.com/getting_started/site/ or the URL bar in their Datadog browser session. They can also contact `support@datadoghq.com` and ask about their Datadog MCP domain.
