#!/usr/bin/env bash
# Common setup: env var cleanup, API key mapping, shared utilities.
# Sourced by entrypoint.sh.
set -euo pipefail

# ── Clear empty credential env vars to avoid panic ───────────────
# vaultrs panics on empty VAULT_ADDR; codetether should fall back to env providers
[ -z "${VAULT_ADDR:-}" ] && unset VAULT_ADDR
[ -z "${VAULT_TOKEN:-}" ] && unset VAULT_TOKEN
[ -z "${GITHUB_COPILOT_TOKEN:-}" ] && unset GITHUB_COPILOT_TOKEN

# ── Map generic API key to provider-specific env var ─────────────
if [ -n "${CODETETHER_API_KEY:-}" ]; then
  MODEL="${CODETETHER_DEFAULT_MODEL:-glm-5.1}"
  case "$MODEL" in
    glm*|zhipu*)   export ZAI_API_KEY="$CODETETHER_API_KEY" ;;
    gpt*|o1*|o3*)  export OPENAI_API_KEY="$CODETETHER_API_KEY" ;;
    claude*)       export ANTHROPIC_API_KEY="$CODETETHER_API_KEY" ;;
    copilot/*)     export GITHUB_COPILOT_TOKEN="$CODETETHER_API_KEY" ;;
    *)             export OPENAI_API_KEY="$CODETETHER_API_KEY" ;;
  esac
  unset CODETETHER_API_KEY
fi

# ── Shared variables ─────────────────────────────────────────────
WORKSPACE_PATH="${INPUT_WORKSPACE_PATH:-${GITHUB_WORKSPACE:-$PWD}}"
TASK_WAIT_SECONDS="${INPUT_TASK_WAIT_SECONDS:-1200}"
mkdir -p "${WORKSPACE_PATH}"

# ── Logging and artifact persistence ─────────────────────────────
# Create a log file that captures all diagnostics for artifact upload.
# This ensures evidence survives even when the action fails.
CODETETHER_LOG_DIR="${WORKSPACE_PATH}/.codetether-logs"
mkdir -p "${CODETETHER_LOG_DIR}"
CODETETHER_LOG_FILE="${CODETETHER_LOG_DIR}/action.log"
CODETETHER_ARTIFACT_DIR="${CODETETHER_LOG_DIR}/artifacts"
mkdir -p "${CODETETHER_ARTIFACT_DIR}"

# Touch the log file so it always exists
: > "${CODETETHER_LOG_FILE}"

# ── Structured logging ──────────────────────────────────────────
# log_info, log_warn, log_error: append to the persistent log AND
# echo to the GitHub Actions console.
log_info()  { local msg="[$(date -Iseconds)] INFO: $*"; echo "$msg" | tee -a "${CODETETHER_LOG_FILE}"; }
log_warn()  { local msg="[$(date -Iseconds)] WARN: $*"; echo "$msg" | tee -a "${CODETETHER_LOG_FILE}" >&2; }
log_error() { local msg="[$(date -Iseconds)] ERROR: $*"; echo "$msg" | tee -a "${CODETETHER_LOG_FILE}" >&2; echo "::error::$*"; }

# ── Utility: truncate string to N characters ─────────────────────
truncate_str() {
  local str="$1"
  local max="$2"
  if [ ${#str} -gt "$max" ]; then
    printf '%s' "${str:0:$((max - 100))}

..._truncated (response exceeded size limit)_"
  else
    printf '%s' "$str"
  fi
}

# ── Utility: save an artifact for post-mortem debugging ──────────
save_artifact() {
  local name="$1"
  local content="$2"
  local path="${CODETETHER_ARTIFACT_DIR}/${name}"
  printf '%s' "$content" > "$path"
  log_info "Artifact saved: ${name} ($(wc -c < "$path") bytes)"
}

# ── Utility: finalize run — write summary to GITHUB_STEP_SUMMARY ─
# Call at every exit path. Persists logs and writes a markdown summary.
finalize_run() {
  local exit_code="${1:-0}"
  local summary_line="${2:-"Completed with exit code ${exit_code}"}"

  # Write GitHub Actions job summary (visible in the Actions run UI)
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## CodeTether Action Summary"
      echo ""
      echo "- **Status**: $( [ "$exit_code" -eq 0 ] && echo '✅ Success' || echo '❌ Failed (exit '"${exit_code}"')' )"
      echo "- **Mode**: ${INPUT_MODE}"
      echo "- **Task ID**: \`${TASK_ID:-N/A}\`"
      echo "- **Exit code**: ${exit_code}"
      echo ""
      echo "${summary_line}"
      echo ""
      if [ -f "${CODETETHER_LOG_FILE}" ]; then
        local log_size
        log_size=$(wc -c < "${CODETETHER_LOG_FILE}")
        if [ "$log_size" -gt 10240 ]; then
          echo "<details><summary>Action log (last 10 KB of ${log_size} bytes — full log in uploaded artifact)</summary>"
          echo ""
          echo '```'
          tail -c 10240 "${CODETETHER_LOG_FILE}"
          echo '```'
          echo "</details>"
        else
          echo "<details><summary>Full action log</summary>"
          echo ""
          echo '```'
          cat "${CODETETHER_LOG_FILE}"
          echo '```'
          echo "</details>"
        fi
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  log_info "Run finalized: exit_code=${exit_code} — ${summary_line}"
}
