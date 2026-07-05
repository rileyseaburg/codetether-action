#!/usr/bin/env bash
# Git/Forge API helpers: posting comments, fetching PR metadata, writing outputs,
# creating branches, creating PRs, verifying pushes.
# Sourced by entrypoint.sh.

# ── Resolve API base for GitHub or Forgejo/Gitea runners ─────────
github_api_base() {
  if [ -n "${GITHUB_API_URL:-}" ]; then
    printf '%s\n' "${GITHUB_API_URL%/}"
    return 0
  fi
  local server_url="${GITHUB_SERVER_URL:-https://github.com}"
  if [ "$server_url" = "https://github.com" ]; then
    printf '%s\n' "https://api.github.com"
  else
    printf '%s\n' "${server_url%/}/api/v1"
  fi
}

# ── Post a comment on an issue or PR ─────────────────────────────
post_github_comment() {
  local target_number="$1"
  local body="$2"
  checkpoint "github: BEFORE post_github_comment #${target_number}"
  local resp api_base
  api_base="$(github_api_base)"
  resp=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/json" \
    "${api_base}/repos/${REPO_FULL_NAME}/issues/${target_number}/comments" \
    -d "$(jq -n --arg body "$body" '{body: $body}')" 2>> "${CODETETHER_LOG_FILE}") || :
  [ -z "$resp" ] && resp="000"
  if [ "$resp" -ge 200 ] && [ "$resp" -lt 300 ]; then
    log_info "Comment posted to #${target_number} (HTTP ${resp})"
  else
    log_warn "Failed to post comment to #${target_number} (HTTP ${resp})"
  fi
}

# ── Write multi-line review output to $GITHUB_OUTPUT ─────────────
write_review_output() {
  local text="$1"
  local code="${2:-0}"
  echo "exit_code=${code}" >> "$GITHUB_OUTPUT"
  {
    echo "review<<CODETETHER_EOF"
    echo "$text"
    echo "CODETETHER_EOF"
  } >> "$GITHUB_OUTPUT"
}

# ── GET request to Git/Forge API ─────────────────────────────────
github_api_get() {
  local path="$1"
  local api_base
  api_base="$(github_api_base)"
  curl -fsSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/json" \
    "${api_base}${path}"
}

# ── POST request to Git/Forge API with status check ──────────────
github_api_post() {
  local path="$1"
  local payload="$2"
  local desc="${3:-Git API call}"
  checkpoint "github: BEFORE api_post ${desc} ${path}"
  local http_code tmp_resp api_base
  api_base="$(github_api_base)"
  tmp_resp=$(mktemp)
  http_code=$(curl -sS -o "$tmp_resp" -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/json" \
    "${api_base}${path}" \
    -d "$payload" 2>> "${CODETETHER_LOG_FILE}") || :
  [ -z "$http_code" ] && http_code="000"
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    log_error "${desc} failed (HTTP ${http_code}): $(cat "$tmp_resp" 2>/dev/null || echo 'no response body')"
    rm -f "$tmp_resp"
    return 1
  fi
  cat "$tmp_resp"
  rm -f "$tmp_resp"
}

# ── Fetch PR metadata (base, head, head repo) ───────────────────
fetch_pr_metadata() {
  local response
  response="$(github_api_get "/repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}")"
  PR_BASE="$(echo "$response" | jq -r '.base.ref')"
  PR_HEAD="$(echo "$response" | jq -r '.head.ref')"
  PR_HEAD_REPO="$(echo "$response" | jq -r '.head.repo.full_name')"
}

# ── Verify a branch exists on the remote ────────────────────────
# Returns 0 if the branch exists, 1 otherwise.
verify_branch_pushed() {
  local branch="$1"
  local encoded_branch
  encoded_branch=$(jq -rn --arg v "$branch" '$v|@uri')
  local ref_response api_base
  api_base="$(github_api_base)"
  ref_response=$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/json" \
    "${api_base}/repos/${REPO_FULL_NAME}/branches/${encoded_branch}" 2>> "${CODETETHER_LOG_FILE}") || :
  [ -z "$ref_response" ] && ref_response="000"
  if [ "$ref_response" -ge 200 ] && [ "$ref_response" -lt 300 ]; then
    log_info "Branch '${branch}' verified on remote (HTTP ${ref_response})"
    return 0
  else
    log_error "Branch '${branch}' NOT found on remote (HTTP ${ref_response})"
    return 1
  fi
}

# ── Verify a commit exists on a remote branch ───────────────────
# Returns 0 if the commit is the tip of the branch, 1 otherwise.
verify_commit_on_branch() {
  local branch="$1"
  local expected_sha="$2"
  local encoded_branch
  encoded_branch=$(jq -nr --arg v "$branch" '$v|@uri' 2>/dev/null) || encoded_branch="$branch"
  local response
  response=$(github_api_get "/repos/${REPO_FULL_NAME}/branches/${encoded_branch}" 2>/dev/null) || true
  local actual_sha
  actual_sha=$(echo "${response:-{}}" | jq -r '.commit.sha // empty' 2>/dev/null) || true
  if [ "$actual_sha" = "$expected_sha" ]; then
    log_info "Commit ${expected_sha:0:8} verified on branch '${branch}'"
    return 0
  else
    log_error "Commit mismatch on '${branch}': expected ${expected_sha:0:8}, got ${actual_sha:0:8}"
    return 1
  fi
}

# ── Create a pull request ───────────────────────────────────────
# Returns the PR number on success, empty string on failure.
create_pull_request() {
  local head_branch="$1"
  local base_branch="${2:-main}"
  local title="$3"
  local body="${4:-}"
  local pr_url=""
  local max_retries=3
  local attempt=1

  checkpoint "github: BEFORE create_pull_request — ${head_branch} → ${base_branch}: '${title}'"

  while [ "$attempt" -le "$max_retries" ]; do
    log_info "Creating PR: '${title}' (${head_branch} → ${base_branch}), attempt ${attempt}/${max_retries}"
    local resp
    resp=$(github_api_post \
      "/repos/${REPO_FULL_NAME}/pulls" \
      "$(jq -n \
        --arg head "$head_branch" \
        --arg base "$base_branch" \
        --arg title "$title" \
        --arg body "$body" \
        '{head: $head, base: $base, title: $title, body: $body}')" \
      "Create PR") || true

    local pr_number
    pr_number=$(echo "$resp" | jq -r '.number // empty' 2>/dev/null) || true
    pr_url=$(echo "$resp" | jq -r '.html_url // empty' 2>/dev/null) || true

    if [ -n "$pr_number" ]; then
      log_info "PR created: #${pr_number} — ${pr_url}"
      CREATED_PR_NUMBER="$pr_number"
      CREATED_PR_URL="$pr_url"
      return 0
    fi

    # Check if PR already exists for this branch pair
    local existing
    existing=$(github_api_get "/repos/${REPO_FULL_NAME}/pulls?head=${REPO_FULL_NAME%%/*}:${head_branch}&state=open" 2>/dev/null) || true
    existing_number=$(echo "$existing" | jq -r '.[0].number // empty' 2>/dev/null) || true
    if [ -n "$existing_number" ]; then
      existing_url=$(echo "$existing" | jq -r '.[0].html_url // empty' 2>/dev/null)
      log_info "PR already exists: #${existing_number} — ${existing_url}"
      CREATED_PR_NUMBER="$existing_number"
      CREATED_PR_URL="$existing_url"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done

  log_error "Failed to create PR after ${max_retries} attempts"
  return 1
}
