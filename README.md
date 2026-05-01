# CodeTether GitHub Action

AI-powered code review and issue resolution. Fire-and-forget architecture with persistent workers.

## How It Works

CodeTether uses a **fire-and-forget** architecture:

```
GitHub Action ──POST /v1/tasks/dispatch──► A2A Server ──task queue──► Persistent Worker
     │                                        │                          │
     │  ← task_id                             │                          ├── Claims task
     │  Posts notification comment             │                          ├── Clones repo
     │  EXITS (job completes in seconds)       │                          ├── Runs agent (up to 7 days)
     │                                         │                          ├── Pushes commits incrementally
     │                                         │                          └── Posts progress comments
     │                                         │
     │  User monitors via GitHub comments ◄────┘
```

**Key point**: The GitHub Action job completes in seconds. The actual work happens on a persistent worker that runs for up to 7 days.

### Execution Flow

1. **Dispatch** — The action sends a task to the CodeTether server and receives a `task_id`
2. **Notify** — It posts a comment with the task_id and tracking URL to the issue/PR
3. **Exit** — The GitHub Action job exits immediately (no waiting, no polling)
4. **Execute** — A persistent worker picks up the task, clones the repo, and runs the agent
5. **Report** — Progress is posted as GitHub comments on the issue/PR as the worker works
6. **Complete** — Final results (commits, PR, response) are posted when the task finishes

## Quick Start

```yaml
name: CodeTether Review
on:
  issues:
    types: [opened, edited]
  issue_comment:
    types: [created]
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 5  # Action exits in seconds, this is just a safety net
    steps:
      - uses: actions/checkout@v4
      - uses: rileyseaburg/codetether-action@main
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
```

Get your token at [codetether.run](https://codetether.run) → Settings → API Tokens.

## Modes

### Server Mode (default)

Dispatches tasks to CodeTether cloud. **Fire-and-forget** — the action exits immediately after dispatching.

- ✅ No LLM API keys needed
- ✅ Tasks run for up to 7 days on persistent workers
- ✅ Progress reported via GitHub comments
- ✅ GitHub Action job completes in seconds

### Local Mode

Runs the agent directly in the GitHub Actions runner. Requires your own LLM API keys.

- ⚠️ Limited by GitHub Actions timeout (max 72 hours)
- ⚠️ Requires `api_key` or `vault_addr` + `vault_token`
- ✅ Full control over the agent environment

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `token` | CodeTether API token (required) | — |
| `server_url` | Server URL | `https://api.codetether.run` |
| `mode` | `server` or `local` | `server` |
| `preset` | Review focus: `review`, `security`, `quality`, `performance`, `architecture`, or custom | `review` |
| `extra_prompt` | Additional instructions for the agent | `""` |
| `auto_comment` | Post results as comments | `true` |
| `max_steps` | Max agentic loop iterations | `50` |
| `task_timeout_hours` | Max worker runtime before task reaped (hours) | `168` (7 days) |
| `fail_on_error` | Fail workflow on dispatch error | `true` |
| `workspace_path` | Repo path to review | `""` |

### Local Mode Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `api_key` | LLM API key | — |
| `model` | LLM model | `glm-5.1` |
| `vault_addr` | Vault address | — |
| `vault_token` | Vault token | — |
| `version` | CodeTether binary version | `latest` |

### Deprecated Inputs

| Input | Note |
|-------|------|
| `task_wait_seconds` | No longer used. Tasks are fire-and-forget. Kept for backward compatibility. |
| `timeout_minutes` | Set via `timeout-minutes` in your workflow instead. |

## Outputs

| Output | Description |
|--------|-------------|
| `task_id` | Server task ID for tracking |
| `review` | Dispatch confirmation (in server mode) or full review (in local mode) |
| `exit_code` | 0 = dispatch succeeded |

## Monitoring Task Progress

In server mode, monitor progress via:

1. **GitHub Comments** — Progress is posted as comments on the issue/PR
2. **Task API** — `GET https://api.codetether.run/v1/tasks/{task_id}`
3. **Dashboard** — [codetether.run](https://codetether.run) dashboard

## Presets

- **review** — General code review (bugs, security, performance, style)
- **security** — OWASP-focused security audit
- **quality** — Code quality, complexity, testing, documentation
- **performance** — Algorithmic complexity, memory, I/O, concurrency
- **architecture** — Separation of concerns, coupling, API design, extensibility

## Example Workflows

### Issue Triage

```yaml
on:
  issues:
    types: [opened]

jobs:
  triage:
    runs-on: ubuntu-latest
    steps:
      - uses: rileyseaburg/codetether-action@main
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
          preset: quality
```

### On-Comment Fix

```yaml
on:
  issue_comment:
    types: [created]

jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rileyseaburg/codetether-action@main
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
          # Comment "@codetether fix this" on an issue to trigger implementation
```

### PR Security Review

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rileyseaburg/codetether-action@main
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
          preset: security
```

## Architecture: Why Fire-and-Forget?

The previous architecture had the GitHub Action poll the server for task completion:

```
# OLD (broken for long tasks):
GH Action → dispatch → poll for up to 1800s → timeout if worker dies
```

Problems:
- GitHub Actions max timeout is 72h (configured at 45min for many orgs)
- Knative worker timeout was 600s — hard kill by queue-proxy
- If the worker died, all state was lost (emptyDir, no persistence)
- No progress visibility while waiting

New architecture:

```
# NEW (fire-and-forget):
GH Action → dispatch → post task_id → EXIT (seconds)
Persistent worker → claims task → runs for up to 7 days → posts progress
```

Benefits:
- GitHub Action job completes in seconds, not hours
- Persistent workers survive pod recycles (state in database)
- Progress visible via GitHub comments
- Tasks can run for up to 7 days (configurable via `task_timeout_hours` on server)
- Worker pushes commits incrementally as it works

## License

MIT
