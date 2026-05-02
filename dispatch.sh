#!/usr/bin/env bash
# CodeTether Action — Thin dispatcher.
# Sends a task to the CodeTether server and exits immediately.
# All execution happens server-side on persistent workers.
set -euo pipefail

LOG_DIR="/tmp/codetether-dispatch"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/dispatch.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "${LOG_FILE}" >&2; }
err() { local msg="$*"; log "ERROR: ${msg}"; echo "::error::${msg}"; }

if [ -z "${CODETETHER_TOKEN:-}" ]; then
  err "token input is required. Get one at https://codetether.run → Settings → API Tokens."
  exit 1
fi
if [ -z "${CODETETHER_SERVER:-}" ]; then
  err "server_url is required."
  exit 1
fi

effective_agent_type="${INPUT_AGENT_TYPE:-code-review}"
case "${INPUT_PRESET:-review}" in
  review)       effective_agent_type="code-review" ;;
  security)     effective_agent_type="security-review" ;;
  quality)      effective_agent_type="quality-review" ;;
  performance)  effective_agent_type="performance-review" ;;
  architecture) effective_agent_type="architecture-review" ;;
  *)            effective_agent_type="${INPUT_AGENT_TYPE:-code-review}" ;;
esac

task_title=""
task_description=""

if [ "${GITHUB_EVENT_NAME}" = "issues" ] || [ "${GITHUB_EVENT_NAME}" = "issue_comment" ]; then
  task_title="Issue #${PR_NUMBER:-0}: ${PR_TITLE:-}"
  task_description="GitHub Issue #${PR_NUMBER:-0} in ${REPO_FULL_NAME:-}

Title: ${PR_TITLE:-}

Body:
${PR_BODY:-No description provided.}
${INPUT_EXTRA_PROMPT:+
Additional instructions: ${INPUT_EXTRA_PROMPT}}"
elif [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
  task_title="PR Review #${PR_NUMBER:-0}: ${PR_TITLE:-}"
  task_description="Review PR #${PR_NUMBER:-0} (${PR_HEAD:-} to ${PR_BASE:-}) in ${REPO_FULL_NAME:-}

Title: ${PR_TITLE:-}

${INPUT_EXTRA_PROMPT:+Additional instructions: ${INPUT_EXTRA_PROMPT}}"
else
  task_title="CodeTether task for ${REPO_FULL_NAME:-}"
  task_description="${INPUT_EXTRA_PROMPT:-Review the repository.}"
fi

max_chars=99000
if [ ${#task_description} -gt "$max_chars" ]; then
  log "Description truncated from ${#task_description} to ${max_chars} chars"
  task_description="${task_description:0:$max_chars}"
fi

steps="${INPUT_MAX_STEPS:-50}"
if ! [[ "$steps" =~ ^[0-9]+$ ]]; then steps="50"; fi
pr_num="${PR_NUMBER:-0}"
if ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then pr_num="0"; fi

metadata=$(jq -n \
  --arg source "github-actions" \
  --arg repo "${REPO_FULL_NAME:-}" \
  --argjson pr_num "$pr_num" \
  --argjson max_steps "$steps" \
  --arg github_run_id "${GITHUB_RUN_ID:-}" \
  --arg github_server_url "${GITHUB_SERVER_URL:-https://github.com}" \
  '{
    source: $source,
    repo: $repo,
    pr_number: $pr_num,
    issue_number: $pr_num,
    github_issue_url: ($github_server_url + "/" + $repo + "/issues/" + ($pr_num | tostring)),
    github_issue_number: $pr_num,
    max_steps: $max_steps,
    github_run_id: $github_run_id,
    github_server_url: $github_server_url,
    dispatch_mode: "fire-and-forget"
  }')

task_payload=$(jq -n \
  --arg description "$task_description" \
  --arg agent_type "$effective_agent_type" \
  --arg title "$task_title" \
  --argjson metadata "$metadata" \
  '{
    title: $title,
    description: $description,
    agent_type: $agent_type,
    metadata: $metadata
  }')

log "Dispatching task: ${task_title}"

http_code=$(curl -sS -o "${LOG_DIR}/response.json" -w "%{http_code}" \
  -X POST "${CODETETHER_SERVER}/v1/tasks/dispatch" \
  -H "Authorization: Bearer ${CODETETHER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$task_payload" 2>> "${LOG_FILE}") || true

[ -z "$http_code" ] && http_code="000"
response="$(cat "${LOG_DIR}/response.json" 2>/dev/null || echo '{}')"
log "Server response: HTTP ${http_code}"

if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
  err "Server dispatch failed (HTTP ${http_code}): ${response}"
  echo "exit_code=1" >> "$GITHUB_OUTPUT"
  echo "task_id=" >> "$GITHUB_OUTPUT"
  {
    echo "review<<CODETETHER_EOF"
    echo "Dispatch failed: HTTP ${http_code}"
    echo "CODETETHER_EOF"
  } >> "$GITHUB_OUTPUT"
  if [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then exit 1; else exit 0; fi
fi

task_id=$(echo "$response" | jq -r '.task_id // "unknown"')
log "Task dispatched: ${task_id}"

if [ "$task_id" = "unknown" ]; then
  err "Failed to extract task_id from response: ${response}"
  echo "exit_code=1" >> "$GITHUB_OUTPUT"
  echo "task_id=" >> "$GITHUB_OUTPUT"
  if [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then exit 1; else exit 0; fi
fi

# ── Post notification comment (best-effort) ──────────────────────────
if [ "${INPUT_AUTO_COMMENT:-true}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
  tracking_url="${CODETETHER_SERVER}/v1/tasks/${task_id}"
  notification_file="$(mktemp)"

  jq -n \
    --arg tid "$task_id" \
    --arg ttl "$task_title" \
    --arg url "$tracking_url" \
    '{body: (
      "## \u2705 CodeTether Task Dispatched\n\n" +
      "**Task**: `" + $tid + "`\n" +
      "**Title**: " + $ttl + "\n\n" +
      "A persistent worker will pick up this task and execute it. " +
      "Progress will be posted as comments here.\n\n" +
      "\u003cdetails\u003e\u003csummary\u003eTracking\u003c/summary\u003e\n\n" +
      "- **Task API**: " + $url + "\n" +
      "- **Status**: Queued \u2014 waiting for worker\n\n" +
      "\u003c/details\u003e\n\n" +
      "\u003e _This GitHub Action job has completed. " +
      "The task runs asynchronously on a persistent worker._\n\n" +
      "---\n" +
      "_Task dispatched by [CodeTether](https://codetether.run) \u2014 [View task](" + $url + ")_"
    )}' > "$notification_file"

  curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" \
    -d @"$notification_file" \
    >> "${LOG_FILE}" 2>&1 || true

  rm -f "$notification_file"
fi

# ── Write outputs and exit ──────────────────────────────────────────
echo "task_id=${task_id}" >> "$GITHUB_OUTPUT"
echo "exit_code=0" >> "$GITHUB_OUTPUT"
{
  echo "review<<CODETETHER_EOF"
  echo "Task ${task_id} dispatched to persistent worker. Monitor progress via GitHub comments or ${CODETETHER_SERVER}/v1/tasks/${task_id}"
  echo "CODETETHER_EOF"
} >> "$GITHUB_OUTPUT"

log "Dispatch complete — task ${task_id} queued"
