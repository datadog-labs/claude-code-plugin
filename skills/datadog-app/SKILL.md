---
name: datadog-app
description: Use ONLY when the user explicitly asks to create, scaffold, or initialize a new Datadog App project — they must use action words like "create", "scaffold", "new", or "build" together with "Datadog App" or "@datadog/apps" or "npm create @datadog/apps". Do NOT use for any question that does not involve creating a new project from scratch — questions about Datadog observability products (logs, metrics, APM, traces, monitors, dashboards), working inside an existing project, deploying, publishing, auth, or CI/CD.
---

# Datadog Apps

Use this skill only to **scaffold a new Datadog App**. It covers nothing else.

Once the app is scaffolded, all further guidance — local development, auth, deploy, publish, CI/CD, backend functions, data access, upgrading, and troubleshooting — lives in the generated project's `AGENTS.md` and `docs/agents/` files.

## Reference Routing

| User task                | Read                            |
| ------------------------ | ------------------------------- |
| Create a new Datadog App | `references/getting-started.md` |

## Boundaries

- This skill covers scaffolding only. Stop here once the project is created.
- Do not provide auth, deploy, publish, CI/CD, or app logic guidance from this skill — read the project's `AGENTS.md` instead.
- Do not cover Datadog package/platform development in this skill.
