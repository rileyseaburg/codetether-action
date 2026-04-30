#!/usr/bin/env bash
# CodeTether GitHub Action entrypoint
# Supports two modes:
#   local  — runs the agent in the GH Actions runner
#   server — dispatches a review task to an A2A server
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
# FAILS CLOSED: exits non-zero if the server task fails.
# Posts status comments at each stage so the user has visibility.
handle_issue() {
  echo "::group::Processing issue #${PR_NUMBER}"
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

  # ── Post "picked up" status comment ────────────────────────────
  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    post_github_comment "${PR_NUMBER}" "## 🔵 CodeTether Picked Up

Analyzing issue #${PR_NUMBER}... Will post results when complete."
  fi

  local review_text=""
  local task_failed="false"

  if [ "$INPUT_MODE" = "server" ]; then
    # ── SERVER MODE: analyze and respond ─────────────────────────
    log_info "Dispatching issue task to server"
    if ! dispatch_server_task "${prompt}" "Issue #${PR_NUMBER}: ${PR_TITLE}"; then
      task_failed="true"
      review_text="$REVIEW_TEXT"
      log_error "Server dispatch failed for issue #${PR_NUMBER}"
    elif ! poll_task_result; then
      task_failed="true"
      review_text="$REVIEW_TEXT"
      log_error "Server task failed for issue #${PR_NUMBER} (task ${TASK_ID})"
    else
      review_text="$REVIEW_TEXT"
    fi
  else
    # ── LOCAL MODE: delegate to full branch→commit→push→PR flow ──
    handle_issue_local "$prompt"
    return $?
  fi

  # ── Post result comment ────────────────────────────────────────
  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    if [ "$task_failed" = "true" ]; then
      local fail_comment="## ❌ CodeTether Failed

Issue #${PR_NUMBER}: ${PR_TITLE}

Task: \`${TASK_ID:-local}\`

**Error**: ${review_text}

See the [workflow run](${GITHUB_SERVER_URL:-https://github.com}/${REPO_FULL_NAME}/actions/runs/${GITHUB_RUN_ID:-?}) for details."
      post_github_comment "${PR_NUMBER}" "$(truncate_str "$fail_comment" 65000)"
    elif [ -n "$review_text" ]; then
      local comment="## 🤖 CodeTether Response

<details><summary>Issue #${PR_NUMBER}: ${PR_TITLE}</summary>

Task: \`${TASK_ID:-local}\`

</details>

${review_text}"
      comment="$(truncate_str "$comment" 65000)"
      post_github_comment "${PR_NUMBER}" "${comment}"
      log_info "Response posted to Issue #${PR_NUMBER}"
    fi
  fi

  write_review_output "${review_text:-}" "$( [ "$task_failed" = "true" ] && echo 1 || echo 0 )"
  [ -n "${TASK_ID:-}" ] && echo "task_id=${TASK_ID}" >> "$GITHUB_OUTPUT"
  echo "::endgroup::"

  # ── FAIL CLOSED ────────────────────────────────────────────────
  if [ "$task_failed" = "true" ]; then
    if [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then
      finalize_run 1 "Issue #${PR_NUMBER} processing failed"
      exit 1
    else
      log_warn "Issue #${PR_NUMBER} failed but fail_on_error=false — continuing"
      finalize_run 0 "Issue #${PR_NUMBER} processing failed (best-effort mode)"
      exit 0
    fi
  fi
  finalize_run 0 "Issue #${PR_NUMBER} processed successfully"
  exit 0
}

# ── Handle PR comment with fix request ───────────────────────────
handle_pr_comment() {
  fetch_pr_metadata

  if [ -n "${COMMENT_BODY}" ] && [ "${FIX_REQUEST}" != "true" ]; then
    INPUT_EXTRA_PROMPT="$(printf '%s\n\nRespond to this PR comment while reviewing the current diff:\n%s' "${INPUT_EXTRA_PROMPT:-}" "${COMMENT_BODY}")"
    [ -n "${COMMENT_PATH}" ] && INPUT_EXTRA_PROMPT="$(printf '%s\n\nThe comment targets file: %s' "${INPUT_EXTRA_PROMPT}" "${COMMENT_PATH}")"
    [ -n "${COMMENT_DIFF_HUNK}" ] && INPUT_EXTRA_PROMPT="$(printf '%s\n\nRelevant diff hunk:\n%s' "${INPUT_EXTRA_PROMPT}" "${COMMENT_DIFF_HUNK}")"
  fi

  if [ "${FIX_REQUEST}" = "true" ]; then
    apply_fix "$COMMENT_BODY" "$COMMENT_PATH" "$COMMENT_DIFF_HUNK"
  fi
}

# ── Server-mode review ───────────────────────────────────────────
# FAILS CLOSED: exits non-zero if the server task fails.
run_server_review() {
  echo "::group::Dispatching review task to A2A server"
  local idempotency_key="pr-review-${REPO_FULL_NAME//\//-}-${PR_NUMBER}-${GITHUB_SHA:0:8}"

  if ! dispatch_server_task "${PROMPT}" "PR Review: #${PR_NUMBER} ${PR_TITLE}" "$idempotency_key"; then
    local fail_msg="Server dispatch failed for PR #${PR_NUMBER}."
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Review Failed

${fail_msg} See workflow logs."
    fi
    write_review_output "${fail_msg}" "1"
    finalize_run 1 "Server dispatch failed"
    echo "::endgroup::"
    exit 1
  fi

  if ! poll_task_result; then
    # poll_task_result returns 1 on failure/timeout/canceled
    local fail_msg="${REVIEW_TEXT}"
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Review Failed

${fail_msg}"
    fi
    write_review_output "${fail_msg}" "1"
    finalize_run 1 "Server task failed: ${TASK_STATUS}"
    echo "::endgroup::"
    exit 1
  fi

  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  [ -n "${TASK_ID:-}" ] && echo "task_id=${TASK_ID}" >> "$GITHUB_OUTPUT"
  {
    echo "review<<CODETETHER_EOF"
    echo "$REVIEW_TEXT"
    echo "CODETETHER_EOF"
  } >> "$GITHUB_OUTPUT"

  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    local preset_label
    preset_label="$(preset_label)"
    local comment="## 🔍 CodeTether Review (${preset_label})

<details><summary>PR #${PR_NUMBER}: ${PR_TITLE}</summary>

Mode: server · Task: \`${TASK_ID}\`

</details>

${REVIEW_TEXT}"
    comment="$(truncate_str "$comment" 65000)"
    post_github_comment "${PR_NUMBER}" "${comment}"
    log_info "Review posted to PR #${PR_NUMBER}"
  fi

  echo "::endgroup::"
  finalize_run 0 "Server review completed successfully"
  exit 0
}

# ── Main ──────────────────────────────────────────────────────────
parse_comment_context
cd "${WORKSPACE_PATH}"

# Issue mode
if [ "${GITHUB_EVENT_NAME:-}" = "issues" ] \
    || { [ "${GITHUB_EVENT_NAME:-}" = "issue_comment" ] && [ "${IS_PR_COMMENT}" != "true" ]; }; then
  handle_issue
fi

# PR comment mode (may set FIX_REQUEST=true)
if [ "${IS_PR_COMMENT}" = "true" ]; then
  handle_pr_comment
fi

# Standard PR review
build_review_prompt
if [ -z "$PROMPT" ]; then
  echo "No code changes detected — skipping review."
  echo "review=No code changes to review." >> "$GITHUB_OUTPUT"
  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  finalize_run 0 "No code changes to review"
  exit 0
fi

if [ "$INPUT_MODE" = "server" ]; then
  run_server_review
else
  run_local_review
fi
