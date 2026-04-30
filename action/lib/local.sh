#!/usr/bin/env bash
# Local mode: run codetether binary directly in the Actions runner.
# Sourced by entrypoint.sh.

# ── Run codetether locally with optional max-steps ───────────────
# Returns: the exit code of codetether (0 = success).
run_local_codetether() {
  local prompt="$1"
  local output_file="$2"
  local run_args=()
  if codetether run --help 2>&1 | grep -q -- '--max-steps'; then
    run_args+=(--max-steps "${INPUT_MAX_STEPS}")
  fi

  save_artifact "prompt.txt" "$prompt"
  log_info "Running codetether locally (prompt $(echo "$prompt" | wc -c) bytes)"
  codetether run "${run_args[@]}" "$prompt" 2>&1 | tee "$output_file"
  local ec="${PIPESTATUS[0]:-0}"
  log_info "codetether exited with code ${ec}"
  [ -f "$output_file" ] && cp "$output_file" "${CODETETHER_ARTIFACT_DIR}/codetether-output.txt"
  return "$ec"
}

# ── Gather PR diff, truncated to MAX_DIFF_LINES ──────────────────
gather_diff() {
  echo "::group::Fetching PR diff"
  DIFF_FILE="$(mktemp)"
  git diff "origin/${PR_BASE}...HEAD" \
    -- '*.rs' '*.py' '*.ts' '*.js' '*.go' '*.java' '*.tsx' '*.jsx' '*.yml' '*.yaml' '*.toml' \
    > "$DIFF_FILE" 2>/dev/null || true

  DIFF_LINES=$(wc -l < "$DIFF_FILE")
  log_info "Diff: ${DIFF_LINES} lines"

  local max_diff_lines=3000
  if [ "$DIFF_LINES" -gt "$max_diff_lines" ]; then
    log_warn "Diff truncated to ${max_diff_lines} lines (was ${DIFF_LINES})"
    head -n "$max_diff_lines" "$DIFF_FILE" > "${DIFF_FILE}.trunc"
    mv "${DIFF_FILE}.trunc" "$DIFF_FILE"
  fi
  cp "$DIFF_FILE" "${CODETETHER_ARTIFACT_DIR}/pr-diff.patch" 2>/dev/null || true
  echo "::endgroup::"
}
# ── Build a review prompt using the active preset ────────────────
build_review_prompt() {
  gather_diff
  if [ "$DIFF_LINES" -eq 0 ]; then
    PROMPT=""
    return
  fi
  local preset_instructions
  preset_instructions="$(build_preset_prompt \
    "$(cat "$DIFF_FILE")" \
    "${PR_BASE}" "${PR_HEAD}" "${PR_NUMBER}" "${PR_TITLE}")"
  PROMPT="${preset_instructions}

${INPUT_EXTRA_PROMPT:+Additional instructions: ${INPUT_EXTRA_PROMPT}}

```diff
$(cat "$DIFF_FILE")
```"
}

# ── Execute local review and post comment ────────────────────────
# FAILS CLOSED: exits non-zero if codetether fails.
run_local_review() {
  echo "::group::Running CodeTether review"
  local review_file
  review_file="$(mktemp)"

  run_local_codetether "$PROMPT" "$review_file"
  local exit_code=$?
  echo "::endgroup::"

  local review_text
  review_text=$(head -c 65000 "$review_file")
  write_review_output "$review_text" "$exit_code"

  # ── FAIL CLOSED: if codetether failed, report and exit non-zero ──
  if [ "$exit_code" -ne 0 ]; then
    log_error "codetether exited with code ${exit_code} — failing the action"
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      local workflow_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO_FULL_NAME}/actions/runs/${GITHUB_RUN_ID:-?}"
      post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Review Failed

codetether exited with code **${exit_code}**. See the [workflow run](${workflow_url}) for details."
    fi
    finalize_run "$exit_code" "codetether failed with exit code ${exit_code}"
    exit "$exit_code"
  fi

  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    echo "::group::Posting review comment"
    local preset_label
    preset_label="$(preset_label)"
    local comment_body="## 🔍 CodeTether Review (${preset_label})

<details>
<summary>PR #${PR_NUMBER}: ${PR_TITLE}</summary>

Mode: local · Model: \`${CODETETHER_DEFAULT_MODEL:-default}\` · Steps: ${INPUT_MAX_STEPS}

</details>

${review_text}"
    comment_body="$(truncate_str "$comment_body" 65000)"
    post_github_comment "${PR_NUMBER}" "$comment_body"
    log_info "Review posted to PR #${PR_NUMBER}"
    echo "::endgroup::"
  fi

  rm -f "$DIFF_FILE" "$review_file"
  finalize_run 0 "Local review completed successfully"
}

# ── Apply a fix requested via PR comment ─────────────────────────
# FAILS CLOSED: verifies push, exits non-zero on any failure.
apply_fix() {
  local comment_body="$1"
  local comment_path="${2:-}"
  local comment_diff_hunk="${3:-}"

  echo "::group::Applying requested PR fix"

  if [ "${INPUT_MODE}" != "local" ]; then
    local msg="Auto-fix requests require local mode with repository write access."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix

${msg}"
    write_review_output "${msg}"
    finalize_run 0 "Skipped: server-mode fix request"
    echo "::endgroup::"
    exit 0
  fi

  if [ "${PR_HEAD_REPO}" != "${REPO_FULL_NAME}" ]; then
    local msg="Auto-fix is not available for forked pull requests (cannot push to \`${PR_HEAD_REPO}:${PR_HEAD}\`)."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix

${msg}"
    write_review_output "${msg}"
    finalize_run 0 "Skipped: forked PR"
    echo "::endgroup::"
    exit 0
  fi

  git fetch origin "${PR_HEAD}" --depth=1 || true
  git checkout -B "${PR_HEAD}" "origin/${PR_HEAD}" 2>/dev/null || git checkout -B "${PR_HEAD}"

  local diff_file
  diff_file="$(mktemp)"
  git diff "origin/${PR_BASE}...HEAD" \
    -- '*.rs' '*.py' '*.ts' '*.js' '*.go' '*.java' '*.tsx' '*.jsx' '*.yml' '*.yaml' '*.toml' \
    > "$diff_file" 2>/dev/null || true
  local fix_diff
  fix_diff="$(head -n 3000 "$diff_file")"

  local fix_prompt="You are editing the checked-out PR branch for PR #${PR_NUMBER}: \"${PR_TITLE}\" (${PR_HEAD} → ${PR_BASE}).

Apply the requested changes directly in the working tree. Do not just describe the fix.

Triggering comment:
${comment_body}

${comment_path:+Commented file: ${comment_path}}
${comment_diff_hunk:+
Relevant diff hunk:
${comment_diff_hunk}}

${INPUT_EXTRA_PROMPT:+Additional instructions: ${INPUT_EXTRA_PROMPT}}

Current diff:
\`\`\`diff
${fix_diff}
\`\`\`

After editing files, run the smallest relevant validation needed to support the change. Do not commit or push; the workflow will handle git."

  local fix_file
  fix_file="$(mktemp)"

  run_local_codetether "${fix_prompt}" "${fix_file}"
  local ec=$?
  if [ "$ec" -ne 0 ]; then
    local msg="I couldn't apply the requested changes automatically. Review the workflow logs for details."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix

${msg}"
    write_review_output "${msg}" "$ec"
    log_error "codetether failed to apply the requested PR changes (exit ${ec})"
    echo "::endgroup::"
    finalize_run "$ec" "codetether failed during fix application"
    exit "$ec"
  fi

  if [ -z "$(git status --short)" ]; then
    local msg="I reviewed the request but did not find any file changes to apply."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix

${msg}"
    write_review_output "${msg}"
    rm -f "${diff_file}" "${fix_file}"
    echo "::endgroup::"
    finalize_run 0 "No file changes produced"
    exit 0
  fi

  # ── Commit and push with VERIFICATION ──────────────────────────
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_FULL_NAME}.git"
  git add -A
  local commit_sha
  GIT_AUTHOR_NAME="codetether[bot]" \
  GIT_AUTHOR_EMAIL="codetether[bot]@users.noreply.github.com" \
  GIT_COMMITTER_NAME="codetether[bot]" \
  GIT_COMMITTER_EMAIL="codetether[bot]@users.noreply.github.com" \
    git commit -m "fix: address @codetether request on PR #${PR_NUMBER}"
  commit_sha="$(git rev-parse HEAD)"
  log_info "Committed ${commit_sha:0:8}"

  # Use verified push — will fail the action if push doesn't stick
  if ! verified_git_push "${PR_HEAD}"; then
    local msg="Failed to push commit \`${commit_sha:0:8}\` to \`${PR_HEAD}\`. The push was rejected or did not persist on the remote."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Fix Push Failed

${msg}"
    write_review_output "${msg}" "1"
    log_error "Push verification failed for ${commit_sha:0:8} → ${PR_HEAD}"
    echo "::endgroup::"
    finalize_run 1 "Push verification failed"
    exit 1
  fi

  local msg="Applied the requested changes in commit \`${commit_sha:0:8}\` and pushed to \`${PR_HEAD}\`."
  [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix

${msg}"
  write_review_output "${msg}"
  rm -f "${diff_file}" "${fix_file}"
  echo "::endgroup::"
  finalize_run 0 "Fix applied and pushed: ${commit_sha:0:8}"
}
