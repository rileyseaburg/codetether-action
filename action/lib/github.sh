#!/usr/bin/env bash
# GitHub API helpers: posting comments, fetching PR metadata, writing outputs.
# Sourced by entrypoint.sh.

# ── Post a comment on an issue or PR ─────────────────────────────
post_github_comment() {
  local target_number="$1"
  local body="$2"
  curl -fsSL \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO_FULL_NAME}/issues/${target_number}/comments" \
    -d "$(jq -n --arg body "$body" '{body: $body}')" \
    > /dev/null
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

# ── GET request to GitHub API ────────────────────────────────────
github_api_get() {
  local path="$1"
  curl -fsSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com${path}"
}

# ── Fetch PR metadata (base, head, head repo) ───────────────────
fetch_pr_metadata() {
  local response
  response="$(github_api_get "/repos/${REPO_FULL_NAME}/pulls/${PR_NUMBER}")"
  PR_BASE="$(echo "$response" | jq -r '.base.ref')"
  PR_HEAD="$(echo "$response" | jq -r '.head.ref')"
  PR_HEAD_REPO="$(echo "$response" | jq -r '.head.repo.full_name')"
}
