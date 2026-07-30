# Getting Started

Use this when a developer wants to create a new Datadog App from scratch.

## Prerequisites

- Node.js 20.19+ (Node 20 line) or 22.12+ (Node 22 line). Prefer a current Node 22 release.
- A Datadog account. API and application keys are needed for deploy and CI — the app key needs **Actions API Access** and **Apps** scopes. OAuth handles local dev automatically; no keys needed upfront.

Check Node:

```bash
node --version
```

If the command fails or returns an unsupported version, ask the user to install a supported Node version and re-run. If you know how the user manages Node locally, you may suggest the appropriate command, for example Volta (`volta install node@22`), nvm (`nvm install 22`), or fnm (`fnm install 22`). Otherwise, ask them to use their usual Node installation or version-management process.

## Scaffold

Use the user's preferred package manager if known. Otherwise default to npm:

```bash
npm create @datadog/apps@latest
# or: pnpm create @datadog/apps@latest
# or: yarn create @datadog/apps@latest
```

Follow the prompts, then enter the generated directory.

## Non-interactive scaffolding

AI agents should use non-interactive mode. First check available options:

```bash
npm create @datadog/apps@latest -- --help
```

Then run with explicit flags, for example:

```bash
npm create @datadog/apps@latest -- my-app --template vite-react -y
```

Adjust the package manager prefix to match the user's preference.

## After scaffolding

Read `AGENTS.md` in the generated project — it contains all guidance for local development, auth, deploy, publish, CI/CD, data access, and troubleshooting specific to the scaffolded app.
