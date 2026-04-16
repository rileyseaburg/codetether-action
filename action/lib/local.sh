#!/usr/bin/env bash
# Local mode: run codetether binary directly in the Actions runner.
# Sourced by entrypoint.sh.

# ── Run codetether locally with optional max-steps ───────────────
# Usage: run_local_codetether "$prompt" "$output_file"
run_local_codetether() {
  local prompt="$1"
  local output_file="$2"
  local run_args=()
  if codetether run --help 2>&1 | grep -q -- '--max-steps'; then
    run_args+=(--max-steps "${INPUT_MAX_STEPS}")
  fi
  codetether run "${run_args[@]}" "$prompt" 2>&1 | tee "$output_file"
  return "${PIPESTATUS[0]:-0}"
}

# ── Gather PR diff, truncated to MAX_DIFF_LINES ──────────────────
# Usage: gather_diff
# Sets: DIFF_FILE, DIFF_LINES
gather_diff() {
  echo "::group::Fetching PR diff"
  DIFF_FILE="$(mktemp)"
  git diff "origin/${PR_BASE}...HEAD" \
    -- '*.rs' '*.py' '*.ts' '*.js' '*.go' '*.java' '*.tsx' '*.jsx' '*.yml' '*.yaml' '*.toml' \
    > "$DIFF_FILE" 2>/dev/null || true

  DIFF_LINES=$(wc -l < "$DIFF_FILE")
  echo "Diff: ${DIFF_LINES} lines"

  local max_diff_lines=3000
  if [ "$DIFF_LINES" -gt "$max_diff_lines" ]; then
    echo "⚠ Diff truncated to ${max_diff_lines} lines (was ${DIFF_LINES})"
    head -n "$max_diff_lines" "$DIFF_FILE" > "${DIFF_FILE}.trunc"
    mv "${DIFF_FILE}.trunc" "$DIFF_FILE"
  fi
  echo "::endgroup::"
}

# ── Build a review prompt using the active preset ────────────────
# Usage: build_review_prompt
# Sets: PROMPT
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

\`\`\`diff
$(cat "$DIFF_FILE")
\`\`\`"
}

# ── Execute local review and post comment ────────────────────────
# Usage: run_local_review
run_local_review() {
  echo "::group::Running CodeTether review"

  local review_file
  review_file="$(mktemp)"

  run_local_codetether "$PROMPT" "$review_file"
  local exit_code=${PIPESTATUS[0]:-0}

  echo "exit_code=${exit_code}" >> "$GITHUB_OUTPUT"
  echo "::endgroup::"

  local review_text
  review_text=$(head -c 65000 "$review_file")

  write_review_output "$review_text" "$exit_code"

  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    echo "::group::Posting review comment"
    local preset_label
    preset_label="$(preset_label)"
    local comment_body="## 🔍 CodeTether Review (${preset_label})

<details>
<summary>PR #${PR_NUMBER}: ${PR_TITLE}</summary>

Model: \`${CODETETHER_DEFAULT_MODEL:-default}\` · Steps: ${INPUT_MAX_STEPS}

</details>

${review_text}"
    comment_body="$(truncate_str "$comment_body" 65000)"
    post_github_comment "${PR_NUMBER}" "${comment_body}"
    echo "Review posted to PR #${PR_NUMBER}"
    echo "::endgroup::"
  fi

  rm -f "$DIFF_FILE" "$review_file"
}

# ── Apply a fix requested via PR comment ─────────────────────────
# Usage: apply_fix "$comment_body" "$comment_path" "$comment_diff_hunk"
apply_fix() {
  local comment_body="$1"
  local comment_path="${2:-}"
  local comment_diff_hunk="${3:-}"

  echo "::group::Applying requested PR fix"

  if [ "${INPUT_MODE}" != "local" ]; then
    local msg="Auto-fix requests require local mode with repository write access."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix\n\n${msg}"
    write_review_output "${msg}"
    echo "::endgroup::"
    exit 0
  fi

  if [ "${PR_HEAD_REPO}" != "${REPO_FULL_NAME}" ]; then
    local msg="Auto-fix is not available for forked pull requests (cannot push to \`${PR_HEAD_REPO}:${PR_HEAD}\`)."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix\n\n${msg}"
    write_review_output "${msg}"
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

  if ! run_local_codetether "${fix_prompt}" "${fix_file}"; then
    local msg="I couldn't apply the requested changes automatically. Review the workflow logs for details."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix\n\n${msg}"
    write_review_output "${msg}" "1"
    echo "::error::codetether failed to apply the requested PR changes"
    echo "::endgroup::"
    exit 1
  fi

  if [ -z "$(git status --short)" ]; then
    local msg="I reviewed the request but did not find any file changes to apply."
    [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix\n\n${msg}"
    write_review_output "${msg}"
    rm -f "${diff_file}" "${fix_file}"
    echo "::endgroup::"
    exit 0
  fi

  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_FULL_NAME}.git"
  git add -A
  GIT_AUTHOR_NAME="codetether[bot]" \
  GIT_AUTHOR_EMAIL="codetether[bot]@users.noreply.github.com" \
  GIT_COMMITTER_NAME="codetether[bot]" \
  GIT_COMMITTER_EMAIL="codetether[bot]@users.noreply.github.com" \
    git commit -m "fix: address @codetether request on PR #${PR_NUMBER}"
  git push origin "HEAD:${PR_HEAD}"

  local commit_sha
  commit_sha="$(git rev-parse --short HEAD)"
  local msg="Applied the requested changes in commit \`${commit_sha}\` and pushed to \`${PR_HEAD}\`."
  [ "${INPUT_AUTO_COMMENT}" = "true" ] && post_github_comment "${PR_NUMBER}" "## 🛠️ CodeTether Fix\n\n${msg}"
  write_review_output "${msg}"
  rm -f "${diff_file}" "${fix_file}"
  echo "::endgroup::"
  exit 0
}
