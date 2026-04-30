#!/usr/bin/env bash
# Server mode: dispatch task to A2A server, poll for completion, return result.
# Sourced by entrypoint.sh.

# ── Dispatch a task to the CodeTether server ─────────────────────
# Usage: dispatch_server_task "$description" "$title" "$idempotency_key"
# Sets: TASK_ID, REVIEW_TEXT
# Returns: 0 on success, 1 on failure (action should exit non-zero).
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
    REVIEW_TEXT="Server dispatch failed — no response received."
    TASK_ID=""
    return 1
  fi
  save_artifact "dispatch-response.json" "$response"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    log_error "Server returned HTTP ${http_code}: ${response}"
    REVIEW_TEXT="Server dispatch failed (HTTP ${http_code})."
    TASK_ID=""
    return 1
  fi

  TASK_ID=$(echo "$response" | jq -r '.task_id // "unknown"')
  log_info "Task dispatched: ${TASK_ID}"

  if [ "$TASK_ID" = "unknown" ]; then
    log_error "Failed to dispatch task: ${response}"
    REVIEW_TEXT="Failed to dispatch task."
    return 1
  fi
}

# ── Poll server for task completion ──────────────────────────────
# Sets: REVIEW_TEXT, TASK_STATUS
# Returns: 0 if completed successfully, 1 if failed/timeout (action should exit non-zero).
poll_task_result() {
  checkpoint "server: BEFORE poll_task_result — task ${TASK_ID}, max_wait=${TASK_WAIT_SECONDS}s"
  local poll_interval=5
  local max_poll=$(( (TASK_WAIT_SECONDS + poll_interval - 1) / poll_interval ))
  local poll_count=0
  local task_status="pending"
  local task_response='{}'
  TASK_STATUS="$task_status"

  while [ "$poll_count" -lt "$max_poll" ] \
      && [ "$task_status" != "completed" ] \
      && [ "$task_status" != "failed" ] \
      && [ "$task_status" != "canceled" ] \
      && [ "$task_status" != "cancelled" ]; do
    sleep "$poll_interval"
    poll_count=$((poll_count + 1))
    # Log a checkpoint every 10 polls (every 50s) to avoid log spam but still have breadcrumbs
    if [ $((poll_count % 10)) -eq 0 ] || [ "$task_status" = "completed" ] || [ "$task_status" = "failed" ]; then
      checkpoint "server: poll ${poll_count}/${max_poll} — status=${task_status}"
    else
      echo "  Poll ${poll_count}/${max_poll}: status=${task_status}" | tee -a "${CODETETHER_LOG_FILE}"
    fi
    checkpoint "server: BEFORE curl GET task status"
    task_response=$(curl -fsSL \
      -H "Authorization: Bearer ${CODETETHER_TOKEN}" \
      "${CODETETHER_SERVER}/v1/tasks/dispatch/${TASK_ID}" 2>/dev/null || echo '{}')
    task_status=$(echo "$task_response" | jq -r '.status // "unknown"')
    TASK_STATUS="$task_status"
  done

  # Export for callers that need the final status
  TASK_STATUS="$task_status"

  if [ "$task_status" = "completed" ]; then
    checkpoint "server: Task completed — fetching result"
    local result_response
    result_response=$(curl -fsSL \
      -H "Authorization: Bearer ${CODETETHER_TOKEN}" \
      "${CODETETHER_SERVER}/v1/tasks/dispatch/${TASK_ID}")
    local result_text
    result_text=$(echo "$result_response" | jq -r '.result // "No response returned."')
    REVIEW_TEXT=$(echo "$result_text" | head -c 65000)
    save_artifact "task-result.txt" "$REVIEW_TEXT"
    log_info "Task ${TASK_ID} completed successfully"
    return 0
  elif [ "$task_status" = "failed" ] || [ "$task_status" = "canceled" ] || [ "$task_status" = "cancelled" ]; then
    local error_text
    error_text=$(echo "$task_response" | jq -r '.error // .result // empty')
    if [ -n "$error_text" ]; then
      REVIEW_TEXT="Task ${task_status}. ${error_text} Task ID: ${TASK_ID}"
    else
      REVIEW_TEXT="Task ${task_status}. Check server logs for task ${TASK_ID}."
    fi
    log_error "Task ${TASK_ID} ${task_status^^} on the server"
    save_artifact "task-failure.txt" "Task ${TASK_ID} failed with status: ${task_status}"
    return 1
  else
    REVIEW_TEXT="Task timed out after ${TASK_WAIT_SECONDS}s (status: ${task_status}). Task ID: ${TASK_ID}"
    log_error "Task ${TASK_ID} TIMED OUT — status was '${task_status}' after ${TASK_WAIT_SECONDS}s"
    save_artifact "task-timeout.txt" "Task ${TASK_ID} timed out with status: ${task_status}"
    return 1
  fi

  export TASK_STATUS
}

# ── Build metadata JSON for task dispatch ────────────────────────
build_metadata_json() {
  local pr_number="${PR_NUMBER:-0}"
  local steps="${INPUT_MAX_STEPS:-50}"
  local timeout="${TASK_WAIT_SECONDS:-3600}"
  jq -n \
    --arg source "github-actions" \
    --arg repo "${REPO_FULL_NAME}" \
    --argjson pr_num "${pr_number:-0}" \
    --argjson max_steps "${steps}" \
    --argjson task_timeout_seconds "${timeout}" \
    '{
      source: $source,
      repo: $repo,
      pr_number: $pr_num,
      issue_number: $pr_num,
      max_steps: $max_steps,
      task_timeout_seconds: $task_timeout_seconds
    }'
}
