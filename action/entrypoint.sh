#!/usr/bin/env bash
# CodeTether GitHub Action entrypoint
# Supports two modes:
#   local  — runs the agent in the GH Actions runner (short tasks)
#   server — dispatches task to A2A server, posts task_id, exits immediately
#
# ARCHITECTURE (server mode — fire-and-forget):
#   1. GitHub Action dispatches task → gets task_id → posts notification → EXITS
#   2. Persistent worker picks up task from A2A server queue
#   3. Worker runs for up to 7 days, pushing commits incrementally
#   4. Progress reported via GitHub issue/PR comments and A2A heartbeats
#   5. User monitors via GitHub comments, A2A API, or dashboard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# shellcheck source=lib/server.sh
source "${SCRIPT_DIR}/lib/server.sh"
# shellcheck source=lib/local.sh
source "${SCRIPT_DIR}/lib/local.sh"
# shellcheck source=lib/presets.sh
source "${SCRIPT_DIR}/lib/presets.sh"
# shellcheck source=lib/issue.sh
source "${SCRIPT_DIR}/lib/issue.sh"

checkpoint "entrypoint: STARTUP — event=${GITHUB_EVENT_NAME:-?} mode=${INPUT_MODE} repo=${REPO_FULL_NAME:-?}"

# ── Parse comment context from event payload ─────────────────────
parse_comment_context() {
  COMMENT_BODY=""
  COMMENT_PATH=""
  COMMENT_DIFF_HUNK=""
  IS_PR_COMMENT="false"
  FIX_REQUEST="false"

  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    COMMENT_BODY="$(jq -r '.comment.body // ""' "${GITHUB_EVENT_PATH}")"
    COMMENT_PATH="$(jq -r '.comment.path // ""' "${GITHUB_EVENT_PATH}")"
    COMMENT_DIFF_HUNK="$(jq -r '.comment.diff_hunk // ""' "${GITHUB_EVENT_PATH}")"
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request_review_comment" ]; then
      IS_PR_COMMENT="true"
    elif [ "${GITHUB_EVENT_NAME:-}" = "issue_comment" ] \
      && jq -e '.issue.pull_request' "${GITHUB_EVENT_PATH}" >/dev/null 2>&1; then
      IS_PR_COMMENT="true"
    fi
  fi

  local body_lower
  body_lower="$(printf '%s' "${COMMENT_BODY}" | tr '\r\n' '  ' | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "${body_lower}" | grep -qE \
    '(@codetether([^[:alnum:]_-]|$).*(fix|apply|address|implement|patch))|((fix|apply|address|implement|patch).+@codetether([^[:alnum:]_-]|$))'; then
    FIX_REQUEST="true"
  fi
}

# ── Handle issues (not PR comments) ──────────────────────────────
# Server mode: dispatch-and-exit (fire-and-forget).
# Local mode: run inline with full branch→commit→push→PR flow.
handle_issue() {
  echo "::group::Processing issue #${PR_NUMBER}"
  checkpoint "handle_issue: ENTER — issue #${PR_NUMBER}: ${PR_TITLE}"
  log_info "Processing issue #${PR_NUMBER}: ${PR_TITLE}"

  local comment_instructions=""
  if [ "${GITHUB_EVENT_NAME:-}" = "issue_comment" ] && [ -n "${COMMENT_BODY}" ]; then
    comment_instructions="A new issue comment mentioned @codetether:
${COMMENT_BODY}

Respond directly to that comment while considering the full issue context.
"
  fi

  local prompt="You are responding to GitHub Issue #${PR_NUMBER}: \"${PR_TITLE}\" in ${REPO_FULL_NAME}.

Analyze the issue and provide a thorough response. If it's a bug report, suggest a fix. If it's a feature request, discuss implementation approach.

${INPUT_EXTRA_PROMPT:+Additional instructions: ${INPUT_EXTRA_PROMPT}}
${comment_instructions}

Issue body:
${PR_BODY:-No description provided.}"

  if [ "$INPUT_MODE" = "server" ]; then
    # ── SERVER MODE: dispatch → notify → exit ────────────────────
    checkpoint "handle_issue: SERVER MODE — dispatching task"

    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "## 🔵 CodeTether Picked Up

Analyzing issue #${PR_NUMBER}... Task is being dispatched to a persistent worker."
      checkpoint "handle_issue: 'picked up' comment posted"
    fi

    if ! dispatch_server_task "${prompt}" "Issue #${PR_NUMBER}: ${PR_TITLE}"; then
      checkpoint "handle_issue: dispatch FAILED"
      local fail_msg="Server dispatch failed for issue #${PR_NUMBER}."
      if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
        post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Dispatch Failed

${fail_msg} See the [workflow run](${GITHUB_SERVER_URL:-https://github.com}/${REPO_FULL_NAME}/actions/runs/${GITHUB_RUN_ID:-?}) for details."
      fi
      write_review_output "${fail_msg}" "1"
      echo "task_id=" >> "$GITHUB_OUTPUT"
      echo "::endgroup::"
      if [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then
        finalize_run 1 "Server dispatch failed for issue #${PR_NUMBER}"
        exit 1
      else
        finalize_run 0 "Server dispatch failed (best-effort mode)"
        exit 0
      fi
    fi

    checkpoint "handle_issue: Task dispatched — posting notification"
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_dispatch_notification "${PR_NUMBER}" "${TASK_ID}" "Issue #${PR_NUMBER}: ${PR_TITLE}"
    fi

    echo "task_id=${TASK_ID}" >> "$GITHUB_OUTPUT"
    write_review_output "Task ${TASK_ID} dispatched to persistent worker. Monitor progress via GitHub comments or ${CODETETHER_SERVER}/v1/tasks/${TASK_ID}" "0"
    echo "::endgroup::"
    finalize_run 0 "Issue #${PR_NUMBER} dispatched — task ${TASK_ID}"
    exit 0
  else
    # ── LOCAL MODE: delegate to full branch→commit→push→PR flow ──
    checkpoint "handle_issue: LOCAL MODE — delegating to handle_issue_local"

    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "## 🔵 CodeTether Picked Up

Analyzing issue #${PR_NUMBER}... Will post results when complete."
    fi

    handle_issue_local "$prompt"
    return $?
  fi
}

# ── Handle PR comment with fix request ───────────────────────────
handle_pr_comment() {
  checkpoint "handle_pr_comment: ENTER"
  fetch_pr_metadata
  checkpoint "handle_pr_comment: PR metadata fetched — base=${PR_BASE} head=${PR_HEAD}"

  if [ -n "${COMMENT_BODY}" ] && [ "${FIX_REQUEST}" != "true" ]; then
    INPUT_EXTRA_PROMPT="$(printf '%s\n\nRespond to this PR comment while reviewing the current diff:\n%s' "${INPUT_EXTRA_PROMPT:-}" "${COMMENT_BODY}")"
    [ -n "${COMMENT_PATH}" ] && INPUT_EXTRA_PROMPT="$(printf '%s\n\nThe comment targets file: %s' "${INPUT_EXTRA_PROMPT}" "${COMMENT_PATH}")"
    [ -n "${COMMENT_DIFF_HUNK}" ] && INPUT_EXTRA_PROMPT="$(printf '%s\n\nRelevant diff hunk:\n%s' "${INPUT_EXTRA_PROMPT}" "${COMMENT_DIFF_HUNK}")"
  fi

  if [ "${FIX_REQUEST}" = "true" ]; then
    checkpoint "handle_pr_comment: FIX_REQUEST=true — calling apply_fix"
    apply_fix "$COMMENT_BODY" "$COMMENT_PATH" "$COMMENT_DIFF_HUNK"
  fi
  checkpoint "handle_pr_comment: EXIT"
}

# ── Server-mode review (fire-and-forget) ─────────────────────────
# Dispatches the review task and exits immediately.
# The persistent worker will execute the review and post results
# as GitHub comments.
run_server_review() {
  echo "::group::Dispatching review task to A2A server"
  checkpoint "run_server_review: ENTER — PR #${PR_NUMBER}"
  local idempotency_key="pr-review-${REPO_FULL_NAME//\//-}-${PR_NUMBER}-${GITHUB_SHA:0:8}"

  checkpoint "run_server_review: BEFORE dispatch_server_task"

  if ! dispatch_server_task "${PROMPT}" "PR Review: #${PR_NUMBER} ${PR_TITLE}" "$idempotency_key"; then
    local fail_msg="Server dispatch failed for PR #${PR_NUMBER}."
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Review Dispatch Failed

${fail_msg} See the [workflow run](${GITHUB_SERVER_URL:-https://github.com}/${REPO_FULL_NAME}/actions/runs/${GITHUB_RUN_ID:-?}) for details."
    fi
    checkpoint "run_server_review: dispatch FAILED"
    write_review_output "${fail_msg}" "1"
    finalize_run 1 "Server dispatch failed"
    echo "::endgroup::"
    exit 1
  fi

  # ── Task dispatched successfully — post notification and exit ──
  checkpoint "run_server_review: Task dispatched — posting notification (task ${TASK_ID})"
  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    post_dispatch_notification "${PR_NUMBER}" "${TASK_ID}" "PR Review: #${PR_NUMBER} ${PR_TITLE}"
  fi

  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  echo "task_id=${TASK_ID}" >> "$GITHUB_OUTPUT"
  {
    echo "review<<CODETETHER_EOF"
    echo "Task ${TASK_ID} dispatched to persistent worker. Monitor progress via GitHub comments or ${CODETETHER_SERVER}/v1/tasks/${TASK_ID}"
    echo "CODETETHER_EOF"
  } >> "$GITHUB_OUTPUT"

  echo "::endgroup::"
  finalize_run 0 "PR review dispatched — task ${TASK_ID}"
  exit 0
}

# ── Main ──────────────────────────────────────────────────────────
checkpoint "main: Parsing comment context"
parse_comment_context
checkpoint "main: Changing to workspace ${WORKSPACE_PATH}"
cd "${WORKSPACE_PATH}"

# Issue mode
if [ "${GITHUB_EVENT_NAME:-}" = "issues" ] \
    || { [ "${GITHUB_EVENT_NAME:-}" = "issue_comment" ] && [ "${IS_PR_COMMENT}" != "true" ]; }; then
  checkpoint "main: Routing to handle_issue"
  handle_issue
fi

# PR comment mode (may set FIX_REQUEST=true)
if [ "${IS_PR_COMMENT}" = "true" ]; then
  checkpoint "main: Routing to handle_pr_comment"
  handle_pr_comment
fi

# Standard PR review
checkpoint "main: Building review prompt"
build_review_prompt
if [ -z "$PROMPT" ]; then
  checkpoint "main: No code changes — skipping review"
  echo "No code changes detected — skipping review."
  echo "review=No code changes to review." >> "$GITHUB_OUTPUT"
  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  finalize_run 0 "No code changes to review"
  exit 0
fi

if [ "$INPUT_MODE" = "server" ]; then
  checkpoint "main: Routing to run_server_review"
  run_server_review
else
  checkpoint "main: Routing to run_local_review"
  run_local_review
fi
