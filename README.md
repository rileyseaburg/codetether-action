# CodeTether GitHub Action

AI-powered code review and automated issue resolution for GitHub repositories.

## Two Integration Paths

### Path 1: GitHub App (Recommended — Zero Config)

Install the [CodeTether GitHub App](https://github.com/apps/codetether) on your repository. That's it. No workflow file, no secrets, no action.

```
User comments "@codetether fix this" on an issue
       |
       v
GitHub sends webhook to CodeTether server
       |
       v
Server queues task -> Persistent worker picks it up
       |
       +-- Clones repo
       +-- Runs agent (up to 7 days)
       +-- Pushes commits incrementally
       +-- Posts progress as GitHub comments
```

**Benefits:**
- No workflow file needed in your repo
- No secrets to manage
- No GitHub Actions runner used (zero compute cost to you)
- Tasks run on CodeTether infrastructure for up to 7 days
- Progress reported as GitHub issue/PR comments
- Works with private repositories (grant the app access)

**Setup:**
1. Go to [github.com/apps/codetether](https://github.com/apps/codetether)
2. Install it on your repo or organization
3. Comment `@codetether` on any issue or PR

### Path 2: GitHub Action (For Repos Without the App)

For repositories where you can't install the GitHub App (e.g., restricted org policies), use this action. It dispatches a task to the CodeTether server using your API token.

```yaml
name: CodeTether
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
    timeout-minutes: 5
    steps:
      - uses: rileyseaburg/codetether-action@main
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
```

The action dispatches the task and **exits immediately**. A persistent CodeTether worker picks it up, runs it, and reports progress via GitHub comments. The GitHub Action job completes in seconds.

Get your token at [codetether.run](https://codetether.run) -> Settings -> API Tokens.

## How It Works

### Webhook Path (GitHub App)

```
GitHub webhook -> POST /v1/webhooks/github -> handle_fix_request()
    -> queue_github_comment_task()
    -> Worker: ensure_workspace() -> create_clone_task() -> create_build_task()
    -> Worker runs for as long as needed
    -> Progress posted as GitHub issue comments
```

All execution happens server-side on CodeTether's Knative cluster with persistent workers. No GitHub Actions runner is involved.

### Action Path (Without the App)

```
GitHub Action -> POST /v1/tasks/dispatch -> task queued -> EXIT (seconds)
Persistent worker -> claims task -> runs for up to 7 days -> posts progress
```

The action is a thin dispatcher. It sends the task to CodeTether and exits. The actual work happens on persistent workers.

## Which Path Should You Use?

| | GitHub App | GitHub Action |
|---|---|---|
| **Setup** | One-click install | Add workflow file + secret |
| **Workflow file** | Not needed | Required |
| **Secrets** | None | `CODETETHER_TOKEN` |
| **Compute cost** | Zero (runs on our infra) | Seconds of runner time |
| **Triggers** | All GitHub events via webhook | Limited to workflow triggers |
| **Recommended?** | Yes | Only if you can't install the app |

## Action Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `token` | CodeTether API token (required) | — |
| `server_url` | Server URL | `https://api.codetether.run` |
| `preset` | Review focus: `review`, `security`, `quality`, `performance`, `architecture`, or custom | `review` |
| `extra_prompt` | Additional instructions for the agent | `""` |
| `auto_comment` | Post results as comments | `true` |
| `max_steps` | Max agentic loop iterations | `50` |
| `fail_on_error` | Fail workflow on dispatch error | `true` |

## Action Outputs

| Output | Description |
|--------|-------------|
| `task_id` | Server task ID for tracking |
| `review` | Dispatch confirmation with task_id |
| `exit_code` | 0 = dispatch succeeded |

## Monitoring Task Progress

1. **GitHub Comments** — Progress is posted as comments on the issue/PR
2. **Task API** — `GET https://api.codetether.run/v1/tasks/{task_id}`
3. **Dashboard** — [codetether.run](https://codetether.run) dashboard

## Presets

- **review** — General code review (bugs, security, performance, style)
- **security** — OWASP-focused security audit
- **quality** — Code quality, complexity, testing, documentation
- **performance** — Algorithmic complexity, memory, I/O, concurrency
- **architecture** — Separation of concerns, coupling, API design, extensibility

## Architecture

### Why No Execution in the Action?

Previous versions ran the agent inside the GitHub Actions runner. This was unreliable:

- GitHub Actions max timeout is 72 hours (often 45 min in practice)
- Cold starts on every run — no persistent state
- If the runner died, all work was lost
- No progress visibility while running

The webhook path eliminates all of these problems:
- No GitHub Actions runner used at all (for the GitHub App path)
- Persistent workers survive pod recycles (state in database)
- Tasks can run for up to 7 days
- Progress visible via GitHub comments in real-time
- Worker pushes commits incrementally as it works

## License

MIT
