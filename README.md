**This plugin is currently in Preview.**

# Datadog Claude Code Plugin

Query your Datadog data directly from Claude Code using natural language. Ask about logs, metrics, traces, dashboards, monitors, and more.

## What you need

- A [Datadog](https://www.datadoghq.com/) account
- [Claude Code](https://code.claude.com/docs) IDE (v2.1.20+)

## Getting started

> If you already have the Datadog MCP server registered separately (e.g., in `.claude/mcp.json`), disable or remove it first to avoid conflicts. Run `/mcp` in Claude Code, then restart Claude Code.

Start Claude Code, install the plugin from the official marketplace:

```
/plugin install datadog@claude-plugins-official
```

> Auto-updates: Enable auto-update so Claude Code notifies when an update is available. Run /plugin, select the Marketplaces tab, select claude-plugins-official, then select Enable auto-update.

Before you can start querying your Datadog data, you’ll need to connect the plugin to Datadog using your account. The setup process will guide you in selecting the correct Datadog MCP domain. After setup, follow the instructions shown in Claude Code.

> You can manually trigger setup by running the `/ddsetup` command.

## Using the plugin

Once connected, just ask the agent anything about your Datadog data:

```
Show me error logs from the last hour
```

```
What monitors are currently alerting?
```

```
Find traces for service "api-gateway" with latency > 500ms
```

```
List my dashboards
```

## Can't connect?

**Never connected before?** Run the `/ddsetup` command. It will help you provide the correct Datadog MCP domain and set up the MCP server.

**Was working before but stopped?** Run the `/ddconfig` command. It will check your site, authentication status, and network access to help diagnose the issue.

## Changing settings

The plugin provides a few commands you can run in the agent to manage configuration:

- `/ddconfig` — change your Datadog site or switch organizations
- `/ddtoolsets` — enable or disable groups of tools

## Advanced usage

### Key authentication

Instead of OAuth, you can authenticate using a Datadog API key and application key. Set all three environment variables before starting Claude Code:

```bash
DD_MCP_DOMAIN=your-mcp-domain \
DD_API_KEY=your-api-key \
DD_APPLICATION_KEY=your-application-key \
claude
```

The `DD_MCP_DOMAIN` value must be the MCP domain (e.g. `mcp.datadoghq.com`, `mcp.us3.datadoghq.com`, `mcp.datadoghq.eu`), not a URL — do not include `https://`. When using key authentication, `/ddsetup` is not required — the plugin connects directly.

### Environment variable overrides

The plugin uses environment variables with default values in its registration file. You can override these defaults by setting the environment variables directly:

- `DD_MCP_DOMAIN` — overrides the Datadog MCP domain. If set, the plugin uses this value regardless of what `/ddsetup` or `/ddconfig` configured. Useful for non-standard environments or key authentication.
- `DD_MCP_TOOLSETS` — overrides the enabled toolsets (comma-separated). If set, the plugin uses this value regardless of what `/ddtoolsets` configured.

When environment variables are set, `/ddsetup`, `/ddconfig`, and `/ddtoolsets` still edit the default values in the registration file, but those defaults won't take effect until the environment variables are removed.

## Good to know

- By default, authentication is handled via OAuth in your browser. Key authentication is also [supported](#key-authentication).
- No Datadog credentials are sent to the AI model provider.

## Support

- [Datadog MCP Server Documentation](https://docs.datadoghq.com/bits_ai/mcp_server/)

## Legal

See the [LICENSE](LICENSE) and [NOTICE](NOTICE) files included with this plugin.

For details on how Datadog handles your data, see the [Datadog Privacy Policy](https://www.datadoghq.com/legal/privacy).
