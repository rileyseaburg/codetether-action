# CodeTether Code Review — GitHub Action

AI-powered code review and PR fix automation. Add this action to any repo in 30 seconds.

## Quick Start

1. Sign up at [codetether.run](https://codetether.run)
2. Go to **Settings → API Tokens** and create a token
3. Add it as a repository secret: `CODETETHER_TOKEN`
4. Create `.github/workflows/codetether-review.yml`:

```yaml
name: CodeTether Review

on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

concurrency:
  group: codetether-review-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: true

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 25
    if: >
      github.event_name == 'pull_request' ||
      (github.event_name == 'issue_comment' &&
       contains(github.event.comment.body, '@codetether')) ||
      (github.event_name == 'pull_request_review_comment' &&
       contains(github.event.comment.body, '@codetether'))
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: CodeTether Review
        uses: rileyseaburg/codetether-action@v1
        with:
          token: ${{ secrets.CODETETHER_TOKEN }}
```

That's it. Every PR gets an automated review comment.

## Features

- **Automatic PR reviews** on every push
- **Issue responses** — assign issues or comment `@codetether` to get AI analysis
- **PR comment replies** — `@codetether` on a PR comment for contextual review
- **Auto-fix** — comment `@codetether fix this` to push a commit directly to the PR branch
- **Server mode** (default) — no API keys needed, runs on CodeTether cloud
- **Local mode** (BYOK) — run on your own infrastructure with your own LLM keys

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `token` | CodeTether API token (**required**) | — |
| `server_url` | CodeTether server URL | `https://api.codetether.run` |
| `mode` | `server` or `local` | `server` |
| `extra_prompt` | Additional instructions for the reviewer | `""` |
| `auto_comment` | Post review as PR comment | `true` |
| `agent_type` | Agent type for task dispatch | `code-review` |
| `model` | LLM model (local mode) | `glm-5.1` |
| `max_steps` | Max agentic iterations (local mode) | `30` |
| `task_wait_seconds` | Timeout for server tasks | `1200` |
| `workspace_path` | Repo path to review | `""` |

### Local Mode (BYOK)

To run the agent on your own runner with your own LLM keys:

```yaml
- uses: rileyseaburg/codetether-action@v1
  with:
    mode: local
    api_key: ${{ secrets.OPENAI_API_KEY }}
    model: gpt-4o
    max_steps: "60"
```

## Outputs

| Output | Description |
|--------|-------------|
| `review` | Full review text |
| `exit_code` | 0 on success, non-zero on failure |

## Auto-Fix

Comment on a PR with `@codetether fix <description>` and the action will:

1. Check out the PR branch
2. Apply the requested changes
3. Run validation
4. Commit and push

> **Note:** Auto-fix only works in local mode and on non-forked PRs.

## Pricing

- **Server mode**: Uses your [codetether.run](https://codetether.run) subscription
- **Local mode**: Free — bring your own LLM API keys

## License

MIT
