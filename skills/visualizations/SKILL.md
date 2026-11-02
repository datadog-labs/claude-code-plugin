---
name: visualizations
description: Use ONLY when the user explicitly asks to see, show, graph, visualize, chart, or plot data, or when another loaded Datadog data-domain skill directs you to visualization guidance. This is the plugin's local copy of the `datadog/visualizations` server skill; prefer it over fetching the server version.
---

# Visualization Guide

Use this guide when the user asks to see, show, graph, visualize, or chart data.

## When the Visualization Tools Are Unavailable

Check this first. The tools below come from the Datadog MCP server's `visualizations` toolset, which is not enabled by default on every client. If neither `get_widget` nor `visualize_tabular_data` is available, do not call them and do not guess other tool names:

- If other Datadog MCP tools are available, the `visualizations` toolset is disabled. Tell the user that Datadog charts are not enabled and suggest running `/ddtoolsets` to enable visualizations.
- If no Datadog MCP tools are available, the server is not set up or not working. Suggest running `/ddsetup`.

Then answer with the data you can retrieve, as text or a table. In this case only, the visualization rules below do not apply.

## Tool Selection

| User intent                    | Tool                     | When to use                                                                                             |
| ------------------------------ | ------------------------ | ------------------------------------------------------------------------------------------------------- |
| Show a chart of Datadog data   | `get_widget`             | Timeseries, toplists, query tables, query values, heatmaps, distributions — any standard Datadog widget |
| Render tabular data as a chart | `visualize_tabular_data` | When you have rows/columns that aren't directly queryable via a Datadog widget definition               |

**Key rule**: If the user says "show me", "graph", "visualize", "chart", or "plot" — always use `get_widget` or `visualize_tabular_data`. Do NOT only return a markdown table or text summary for these requests.

## Chart Type Selection

| Data shape                                        | Recommended chart type                                                            |
| ------------------------------------------------- | --------------------------------------------------------------------------------- |
| Metric over time                                  | `timeseries` via get_widget                                                       |
| Grouped data / proportional breakdown / pie chart | `sunburst` via visualize_tabular_data                                             |
| Ranked list / bar chart (top N by value)          | `toplist` via get_widget or visualize_tabular_data                                |
| Nested / hierarchical breakdown                   | `treemap` via visualize_tabular_data                                              |
| Single number / KPI                               | `query_value` via get_widget (supports background timeseries and delta indicator) |
| Change over time across groups                    | `change` via get_widget                                                           |
| Distribution of values                            | `distribution` via get_widget                                                     |

## Common Patterns

**Metrics visualization**: Call `get_widget` with a widget_definition containing the metric query:

```json
{
  "type": "timeseries",
  "requests": [
    {
      "response_format": "timeseries",
      "queries": [{ "name": "query1", "data_source": "metrics", "query": "avg:system.cpu.user{*}" }]
    }
  ]
}
```

**Log/span analytics as chart**: Build the query directly in a `get_widget` call (`data_source: "logs"`, `"spans"`, etc.) — this keeps the widget exportable to Datadog. Use `visualize_tabular_data` only as a last resort when the query isn't representable in a widget definition.

## Calling get_widget

The three input modes are mutually exclusive:

- **Direct definition** (ad hoc): write a new widget from scratch by providing a `widget_definition` object. See [Building widget_definition](#building-widget_definition) for the schema-lookup workflow.
- **By ID** (`dashboard_id` + `widget_id`): fetch data for an existing dashboard widget you found via `search_datadog_dashboards`.
- **By URL**: provide a Datadog `widget_url` (a link copied from the web UI). Supports share links (`/s/...`), short links (`/u/...`), and dashboard links (`/dashboard/...` with a focused or fullscreen widget).

Pass the widget object as `widget_definition`, not `definition` (wrong key is the most common 400).

## Building widget_definition

For ad-hoc widgets (widget_definition mode), each widget type has a unique schema. Learn the schema by calling `get_widget_reference` with the list of widget types you are considering building, then construct `widget_definition` from the returned schema and pass it to `get_widget`.

For existing dashboard widgets, prefer `search_datadog_dashboards` → `get_widget` since the saved definition is already valid.

If a schema-correct retry still fails, call `ask_widget_expert` for targeted debugging.

## get_widget response

Responses include METADATA (widget_type, query metadata) and DATA sections. The DATA shape varies by widget_type; see `data_shape` and the `render_summary.text` field in each response for what came back.

## When get_widget fails

Error responses include a `[RECOVERY]` or `[EMPTY WIDGET]` action list — follow it. Focus retries on schema-level corrections; cosmetic changes (title, display_type) rarely resolve validation errors. If you have not already called `get_widget_reference` for the affected widget_type this turn, call it, then retry. After 2 failed attempts on the same visualization, explain the blocker to the user in text instead of looping.

## What NOT to Do

- Do NOT only return a markdown table when the user asked for a visualization
