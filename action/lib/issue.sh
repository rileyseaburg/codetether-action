#!/usr/bin/env bash
# Issue handling: local-mode branch → edit → commit → push → PR workflow.
# Sourced by entrypoint.sh.

# ── Local-mode issue handler: branch → edit → commit → push → PR ──
# Creates a feature branch, runs codetether to make changes,
# then commits, pushes, and opens a PR.
handle_issue_local() {
  local prompt="$1"

  checkpoint "handle_issue_local: ENTER — issue #${PR_NUMBER}"

  local branch_name="codetether/issue-${PR_NUMBER}"
  local base_branch=""

  # Determine the default branch
  checkpoint "handle_issue_local: Determining default branch"
  base_branch="$(git remote show origin 2>/dev/null | grep 'HEAD branch' | sed 's/.*: //')" || base_branch="main"
  [ -z "$base_branch" ] && base_branch="main"
  log_info "Base branch: ${base_branch}, feature branch: ${branch_name}"
  checkpoint "handle_issue_local: Base branch resolved = ${base_branch}"

  # Fetch and checkout base branch
  checkpoint "handle_issue_local: BEFORE git fetch origin/${base_branch}"
  git fetch origin "${base_branch}" --depth=1 2>&1 | tee -a "${CODETETHER_LOG_FILE}" || true
  checkpoint "handle_issue_local: AFTER git fetch — checking out branch ${branch_name}"
  git checkout -B "${branch_name}" "origin/${base_branch}" 2>/dev/null || git checkout -B "${branch_name}"
  checkpoint "handle_issue_local: Branch ${branch_name} checked out successfully"

  # Tell codetether to actually edit files, not just describe changes
  local impl_prompt="${prompt}

IMPORTANT: You must directly edit the files in the working tree to fix this issue. Do not just describe the fix — implement it by modifying the relevant source files.

After editing files, run the smallest relevant validation needed to support the change (e.g., build, lint, or tests). Do not commit or push; the workflow will handle git."

  # Run codetether
  checkpoint "handle_issue_local: BEFORE run_local_codetether (this is the big time sink)"
  local output_file
  output_file="$(mktemp)"
  run_local_codetether "${impl_prompt}" "$output_file"
  local ec=$?
  checkpoint "handle_issue_local: AFTER run_local_codetether — exit_code=${ec}"
  local review_text
  review_text=$(cat "$output_file")
  review_text="${review_text:0:65000}"
  rm -f "$output_file"

  if [ "$ec" -ne 0 ]; then
    log_error "codetether failed for issue #${PR_NUMBER} (exit ${ec})"
    checkpoint "handle_issue_local: codetether FAILED — posting error comment"
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "$(truncate_str "## ❌ CodeTether Failed

Issue #${PR_NUMBER}: ${PR_TITLE}

**Error**: ${review_text}

See the [workflow run](${GITHUB_SERVER_URL:-https://github.com}/${REPO_FULL_NAME}/actions/runs/${GITHUB_RUN_ID:-?}) for details." 65000)"
    fi
    write_review_output "${review_text}" "1"
    echo "::endgroup::"
    finalize_run "$ec" "codetether failed for issue #${PR_NUMBER}"
    if [ "${INPUT_FAIL_ON_ERROR:-true}" = "true" ]; then
      exit 1
    else
      exit 0
    fi
  fi

  # Check if any files were changed
  checkpoint "handle_issue_local: Checking for file changes"
  if [ -z "$(git status --short)" ]; then
    log_warn "codetether completed but no file changes were produced for issue #${PR_NUMBER}"
    checkpoint "handle_issue_local: No file changes — posting analysis-only comment"
    if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
      post_github_comment "${PR_NUMBER}" "$(truncate_str "## 🤖 CodeTether Response

<details><summary>Issue #${PR_NUMBER}: ${PR_TITLE}</summary>

Mode: local · Steps: ${INPUT_MAX_STEPS}

</details>

${review_text}" 65000)"
    fi
    write_review_output "${review_text}" "0"
    echo "::endgroup::"
    finalize_run 0 "Issue analyzed (no code changes needed)"
    exit 0
  fi
  local changed_files
  changed_files="$(git status --short | wc -l)"
  checkpoint "handle_issue_local: ${changed_files} file(s) changed — proceeding to commit"

  # ── Commit and push with verification ──────────────────────────
  checkpoint "handle_issue_local: BEFORE git remote set-url"
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_FULL_NAME}.git"
  checkpoint "handle_issue_local: BEFORE git add -A"
  git add -A
  checkpoint "handle_issue_local: AFTER git add — staged files: $(git diff --cached --stat | tail -1)"
  local commit_sha
  checkpoint "handle_issue_local: BEFORE git commit"
  GIT_AUTHOR_NAME="codetether[bot]" \
  GIT_AUTHOR_EMAIL="codetether[bot]@users.noreply.github.com" \
  GIT_COMMITTER_NAME="codetether[bot]" \
  GIT_COMMITTER_EMAIL="codetether[bot]@users.noreply.github.com" \
    git commit -m "fix: resolve issue #${PR_NUMBER} — ${PR_TITLE}"
  commit_sha="$(git rev-parse HEAD)"
  checkpoint "handle_issue_local: AFTER git commit — sha=${commit_sha:0:8}"

  checkpoint "handle_issue_local: BEFORE verified_git_push (${branch_name})"
  if ! verified_git_push "${branch_name}"; then
    checkpoint "handle_issue_local: PUSH FAILED for ${branch_name}"
    local msg="Failed to push commit \`${commit_sha:0:8}\` to \`${branch_name}\`."
    if [ "${INPUT_AUTO_COMMENT}" = "true" ]; then
      post_github_comment "${PR_NUMBER}" "## ❌ CodeTether Push Failed

${msg}"
    fi
    write_review_output "${msg}" "1"
    echo "::endgroup::"
    finalize_run 1 "Push verification failed for issue #${PR_NUMBER}"
    exit 1
  fi
  checkpoint "handle_issue_local: PUSH SUCCEEDED — ${commit_sha:0:8} → ${branch_name}"

  # ── Create a pull request ──────────────────────────────────────
  checkpoint "handle_issue_local: BEFORE create_pull_request"
  local pr_title="fix: resolve issue #${PR_NUMBER} — ${PR_TITLE}"
  local pr_body="## Automated Fix for Issue #${PR_NUMBER}

${PR_TITLE}

This PR was automatically generated by CodeTether to address issue #${PR_NUMBER}.

### Issue Description
${PR_BODY:-No description provided.}

### Changes
${review_text}

---
Closes #${PR_NUMBER}"

  local created_pr_num=""
  local created_pr_url=""
  if create_pull_request "${branch_name}" "${base_branch}" "${pr_title}" "${pr_body}"; then
    created_pr_num="${CREATED_PR_NUMBER}"
    created_pr_url="${CREATED_PR_URL}"
    checkpoint "handle_issue_local: PR CREATED — #${created_pr_num} — ${created_pr_url}"
  else
    checkpoint "handle_issue_local: PR CREATION FAILED — branch was pushed but no PR"
    log_warn "Could not create PR for issue #${PR_NUMBER}, but branch was pushed"
  fi

  # ── Post success comment ───────────────────────────────────────
  checkpoint "handle_issue_local: BEFORE posting success comment"
  if [ "${INPUT_AUTO_COMMENT}" = "true" ] && [ -n "${PR_NUMBER:-}" ]; then
    local success_comment="## 🛠️ CodeTether Fix Applied

Issue #${PR_NUMBER}: ${PR_TITLE}

- **Branch**: \`${branch_name}\`
- **Commit**: \`${commit_sha:0:8}\`"
    if [ -n "${created_pr_num}" ]; then
      success_comment="${success_comment}
- **Pull Request**: #${created_pr_num} — ${created_pr_url}"
    fi
    success_comment="${success_comment}

### Summary
${review_text}"
    post_github_comment "${PR_NUMBER}" "$(truncate_str "$success_comment" 65000)"
  fi
  checkpoint "handle_issue_local: AFTER posting success comment"

  write_review_output "${review_text}" "0"
  echo "task_id=local" >> "$GITHUB_OUTPUT"
  echo "::endgroup::"
  checkpoint "handle_issue_local: COMPLETE — branch=${branch_name} commit=${commit_sha:0:8} pr=#${created_pr_num:-N/A}"
  finalize_run 0 "Issue #${PR_NUMBER} fixed and PR created (#${created_pr_num:-N/A})"
  exit 0
}
