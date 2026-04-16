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
handle_issue() {
  echo "::group::Processing issue #${PR_NUMBER}"

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

  local review_text=""

  if [ "$INPUT_MODE" = "server" ]; then
    dispatch_server_task "${prompt}" "Issue #${PR_NUMBER}: ${PR_TITLE}"
    poll_task_result
    review_text="$REVIEW_TEXT"
  fi

  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "$review_text" ]; then
    local comment="## 🤖 CodeTether Response

<details><summary>Issue #${PR_NUMBER}: ${PR_TITLE}</summary>

Task: \`${TASK_ID:-local}\`

</details>

${review_text}"
    comment="$(truncate_str "$comment" 65000)"
    post_github_comment "${PR_NUMBER}" "${comment}"
    echo "Response posted to Issue #${PR_NUMBER}"
  fi

  write_review_output "$review_text"
  echo "::endgroup::"
  exit 0
}

# ── Handle PR comment with fix request ───────────────────────────
handle_pr_comment() {
  fetch_pr_metadata

  # Non-fix PR comment: append context to extra prompt then fall through to review
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
run_server_review() {
  echo "::group::Dispatching review task to A2A server"
  local idempotency_key="pr-review-${REPO_FULL_NAME//\//-}-${PR_NUMBER}-${GITHUB_SHA:0:8}"
  dispatch_server_task "${PROMPT}" "PR Review: #${PR_NUMBER} ${PR_TITLE}" "$idempotency_key"
  poll_task_result

  echo "exit_code=0" >> "$GITHUB_OUTPUT"
  {
    echo "review<<CODETETHER_EOF"
    echo "$REVIEW_TEXT"
    echo "CODETETHER_EOF"
  } >> "$GITHUB_OUTPUT"

  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ] \
      && [ "${TASK_STATUS:-}" = "completed" ]; then
    local preset_label
    preset_label="$(preset_label)"
    local comment="## 🔍 CodeTether Review (${preset_label})

<details><summary>PR #${PR_NUMBER}: ${PR_TITLE}</summary>

Mode: server · Task: \`${TASK_ID}\`

</details>

${REVIEW_TEXT}"
    comment="$(truncate_str "$comment" 65000)"
    post_github_comment "${PR_NUMBER}" "${comment}"
    echo "Review posted to PR #${PR_NUMBER}"
  fi

  echo "::endgroup::"
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
  exit 0
fi

if [ "$INPUT_MODE" = "server" ]; then
  run_server_review
else
  run_local_review
fi
