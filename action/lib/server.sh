#!/usr/bin/env bash
# Server mode: dispatch task to A2A server (fire-and-forget).
# Sourced by entrypoint.sh.
#
# Architecture:
#   GitHub Action → POST /v1/tasks/dispatch → returns task_id → EXIT
#   Persistent worker picks up task from queue, runs for up to 7 days.
#   Progress reported via heartbeats to A2A server → GitHub issue comments.
#
# The GitHub Action does NOT poll for completion. It dispatches and exits.

# ── Dispatch a task to the CodeTether server ─────────────────────
# Usage: dispatch_server_task "$description" "$title" "$idempotency_key"
# Sets: TASK_ID
# Returns: 0 on success, 1 on failure.
dispatch_server_task() {
  local description="$1"
  local title="$2"
  local idempotency_key="${3:-}"

  checkpoint "server: BEFORE dispatch_server_task — '${title}'"

  if [ -z "${CODETETHER_SERVER:-}" ]; then
    log_error "server_url is required in server mode"
    exit 1
  fi
  if [ -z "${CODETETHER_TOKEN:-}" ]; then
    log_error "token is required in server mode"
    exit 1
  fi

  local max_chars=99000
  local truncated_desc="${description:0:$max_chars}"
  if [ ${#description} -gt "$max_chars" ]; then
    log_warn "Description truncated from ${#description} to ${max_chars} chars"
  fi

  local metadata_block
  metadata_block=$(build_metadata_json)

  local effective_agent_type
  effective_agent_type="$(preset_agent_type)"

  local task_payload
  task_payload=$(jq -n \
    --arg description "$truncated_desc" \
    --arg agent_type "$effective_agent_type" \
    --arg title "$title" \
    --argjson metadata "$metadata_block" \
    '{
      title: $title,
      description: $description,
      agent_type: $agent_type,
      metadata: $metadata
    }')

  local curl_args=(
    -sS -o /tmp/codetether-response.json -w "%{http_code}"
    -X POST "${CODETETHER_SERVER}/v1/tasks/dispatch"
    -H "Authorization: Bearer ${CODETETHER_TOKEN}"
    -H "Content-Type: application/json"
    -d "$task_payload"
  )
  if [ -n "$idempotency_key" ]; then
    curl_args+=(-H "Idempotency-Key: ${idempotency_key}")
  fi

  local http_code
  checkpoint "server: BEFORE curl POST ${CODETETHER_SERVER}/v1/tasks/dispatch"
  http_code=$(curl "${curl_args[@]}" 2>> "${CODETETHER_LOG_FILE}")
  local curl_exit=$?
  checkpoint "server: AFTER curl POST — http_code=${http_code} curl_exit=${curl_exit}"
  [ -z "$http_code" ] && http_code="000"

  local response
  response="$(cat /tmp/codetether-response.json 2>/dev/null || true)"
  if [ -z "$response" ]; then
    log_error "No response received from server (curl exit ${curl_exit})"
    TASK_ID=""
    return 1
  fi
  save_artifact "dispatch-response.json" "$response"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    log_error "Server returned HTTP ${http_code}: ${response}"
    TASK_ID=""
    return 1
  fi

  TASK_ID=$(echo "$response" | jq -r '.task_id // "unknown"')
  log_info "Task dispatched: ${TASK_ID}"

  if [ "$TASK_ID" = "unknown" ]; then
    log_error "Failed to dispatch task: ${response}"
    return 1
  fi

  # ── Fire-and-forget: task is queued. Exit immediately. ─────────
  # The persistent worker will pick it up, run it, and report
  # progress via GitHub comments and A2A server heartbeats.
  log_info "Task ${TASK_ID} queued — persistent worker will execute"
  return 0
}

# ── Post dispatch notification comment ────────────────────────────
# Posts a comment on the issue/PR with the task_id and tracking URL.
# This replaces the old polling loop — the user monitors progress
# via GitHub comments, not by watching the Action job.
post_dispatch_notification() {
  local target_number="$1"
  local task_id="$2"
  local task_title="$3"
  local tracking_url="${CODETETHER_SERVER}/v1/tasks/${task_id}"

  local notification_comment="## 🚀 CodeTether Task Dispatched

**Task**: \`${task_id}\`
**Title**: ${task_title}

A persistent worker will pick up this task and execute it. Progress will be posted as comments on this issue/PR.

<details><summary>Tracking</summary>

- **Task API**: ${tracking_url}
- **Status**: Queued — waiting for worker

</details>

> _This GitHub Action job has completed. The task runs asynchronously on a persistent worker._

---
_Task dispatched by [CodeTether](https://codetether.run) — [View task](${tracking_url})_"

  post_github_comment "${target_number}" "$(truncate_str "$notification_comment" 65000)"
  log_info "Dispatch notification posted to #${target_number} for task ${task_id}"
}

# ── Validate/coerce a non-negative integer input ─────────────────
normalize_non_negative_integer() {
  local value="$1"
  local field_name="$2"
  local normalized
  normalized="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ ! "$normalized" =~ ^[0-9]+$ ]]; then
    log_error "${field_name} must be a non-negative integer, got: ${value}"
    return 1
  fi
  printf '%s\n' "$normalized"
}

# ── Build metadata JSON for task dispatch ────────────────────────
build_metadata_json() {
  local pr_number="${PR_NUMBER:-0}"
  local steps="${INPUT_MAX_STEPS:-50}"
  local normalized_steps
  normalized_steps="$(normalize_non_negative_integer "${steps}" "max_steps")" || return 1
  local timeout_secs="${TASK_TIMEOUT_SECONDS:-$(( 168 * 3600 ))}"
  local github_server="${GITHUB_SERVER_URL:-https://github.com}"
  local issue_url="${github_server}/${REPO_FULL_NAME}/issues/${pr_number}"
  jq -n \
    --arg source "github-actions" \
    --arg repo "${REPO_FULL_NAME}" \
    --argjson pr_num "${pr_number:-0}" \
    --argjson max_steps "${normalized_steps}" \
    --argjson task_timeout_seconds "${timeout_secs}" \
    --arg github_run_id "${GITHUB_RUN_ID:-}" \
    --arg github_server_url "${github_server}" \
    --arg github_issue_url "${issue_url}" \
    --argjson github_issue_number "${pr_number:-0}" \
    '{
      source: $source,
      repo: $repo,
      pr_number: $pr_num,
      issue_number: $pr_num,
      github_issue_url: $github_issue_url,
      github_issue_number: $github_issue_number,
      max_steps: $max_steps,
      task_timeout_seconds: $task_timeout_seconds,
      github_run_id: $github_run_id,
      github_server_url: $github_server_url,
      dispatch_mode: "fire-and-forget"
    }'
}
