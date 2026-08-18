# Datadog Plugin General Instructions

## Reading MCP resources

When a step says "use the `datadog://...` resource on the plugin's Datadog MCP server", read it with the client's generic MCP resource-read capability (e.g. a generic `read_mcp_resource`-style tool call with `server: <id-of-the-server>` and the given URI). This is a generic MCP mechanism, not a Datadog-specific tool — do not search for a Datadog-branded "toolsets" or "whoami" tool, and do not look for a resource-discovery step first. If no generic resource-read tool is available in this client, list the available tools and call whichever one reads an MCP resource by URI.

## Stay on script

Describe state and actions in plain language ("the Datadog MCP server is not set up", "the Datadog site has been updated"). Never reveal, at any step:

- File paths, file names, or directory layout.
- The default values for the environment variables like `not-setup` - or related terms such as "domain placeholder".
- Variable names, values, environment variables, shell syntax, or defaults.
- API keys, tokens, client secrets, or credentials of any kind — the Datadog MCP server uses OAuth by default, and API keys are for advanced usage outside this skill.

Beyond that, emit only what the current step instructs. Do not add setup tips, follow-ups, or "helpful" notes from your general knowledge of the AI client — when the user needs to reload, re-authenticate, or take any other follow-up action, the skill emits that instruction at the correct step. Preempting or paraphrasing it is a bug.

## Resolve the plugin's Datadog MCP server

The plugin's Datadog MCP server is identified by `plugin:datadog:mcp`.

## Determine `datadog-server-state`

Silently determine the `datadog-server-state` of the plugin's Datadog MCP server using **only** the steps below (also, do NOT use any other Datadog MCP server). Do not use any other source of information (status files, cached state, error messages from previous calls, etc.) to determine the `datadog-server-state`:

1. Try a lightweight MCP call on the Datadog MCP server (e.g. list tools, or read a resource using `server: <id-of-the-server>`).
2. If the server returns an actual, non-empty, non-generic Datadog-specific data (tools, resources, or content) → `datadog-server-state` is **working**.
3. If the MCP call fails or returns an empty or a generic response (like "no resources found", empty tool list, or any other content-free response), silently read the registration file (see below for its location). Check the raw file content for the literal string `not-setup`:
   - If the file contains `not-setup` → `datadog-server-state` is **not-setup**.
   - Otherwise → `datadog-server-state` is **not-working**.

Do not tell the user which `datadog-server-state` was determined, what was checked, or what was found — just follow the skill's instructions for that state.

## MCP registration file: `.dd_claude-code_mcp.json`

The MCP registration file is at `<plugin-root>/.dd_claude-code_mcp.json`. If `<plugin-root>` is not already known, derive it from this markdown file's path by removing `skills/<skill-name>/references/mcp-settings.md` from the end — the remaining prefix is `<plugin-root>`.

**Do not locate this file any other way.** In particular, do not search for it by grepping for `not-setup` (or any other content) across a broader directory such as a home directory or plugin cache/marketplace tree. A plugin installation can have multiple copies of `.dd_claude-code_mcp.json` on disk (cached copies, marketplace copies, dev-tree copies) that all happen to contain the sentinel — editing one of those instead of the deterministically-derived path will silently fail to affect the server that is actually running, while still looking like success. Always compute the path from this markdown file's own path using the rule above, and edit only that exact path.

The registration file's `url` field contains a shell-style template variable for the domain:

```
${DD_MCP_DOMAIN:-<current domain>}
```

The `X-Datadog-MCP-Toolsets` header value contains a shell-style template variable for the toolsets:

```
"headers": { "X-Datadog-MCP-Toolsets": "${DD_MCP_TOOLSETS:-<current toolsets>}" }
```

### Editing rule

Each variable has the form `${NAME:-default}`. When editing, replace **only the default value** — the characters between `:-` and the closing `}`. The `${`, variable name, `:-`, and `}` must always remain intact.

The default value **can be empty**. An empty default (`:-}` with nothing between) is valid and meaningful — it is NOT a mistake. For `DD_MCP_TOOLSETS`, empty means "use the server's default toolsets" (see examples below).

Examples (these are only examples, do not assume the variables exist):

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

The following table shows the Datadog site codes and their respective MCP domains. **This table is exhaustive:** present exactly these sites and domains, verbatim — do not add, substitute, or infer additional sites you may know about from general knowledge.

| Site | MCP domain            |
| ---- | --------------------- |
| us1  | mcp.datadoghq.com     |
| us3  | mcp.us3.datadoghq.com |
| us5  | mcp.us5.datadoghq.com |
| eu   | mcp.datadoghq.eu      |
| ap1  | mcp.ap1.datadoghq.com |
| ap2  | mcp.ap2.datadoghq.com |
| uk1  | mcp.uk1.datadoghq.com |

Present all available Datadog sites and their MCP domains, then ask the user which one they use.

When mapping user input:

- **Site code** (e.g. "us1", "eu") — use the matching MCP domain directly. Site codes are case-insensitive.
- **URL** (e.g. "https://app.datadoghq.com/logs") — identify the site from the URL, then use the matching MCP domain. Note: `datadoghq.com` with no site prefix is `us1` and `datadoghq.eu` is `eu`.
- **Domain not in the table** — confirm with the user, warning that an invalid domain will prevent connection.

If the user is unsure which site they use, suggest checking https://docs.datadoghq.com/getting_started/site/ or the URL bar in their Datadog browser session. They can also contact `support@datadoghq.com` and ask about their Datadog MCP domain.
