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
