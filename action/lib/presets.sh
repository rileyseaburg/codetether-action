#!/usr/bin/env bash
# Preset prompt templates for different review focuses.
# Sourced by entrypoint.sh.

# ── Map preset name to a review prompt ───────────────────────────
# If INPUT_PRESET is set, it overrides the default review instructions.
# Custom presets fall through to extra_prompt only.
build_preset_prompt() {
  local diff_content="$1"
  local base="${2:-}"
  local head="${3:-}"
  local pr_number="${4:-}"
  local pr_title="${5:-}"

  case "${INPUT_PRESET:-review}" in
    review)
      echo "You are reviewing PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

Review the following diff and report:
1. **Bugs** — logic errors, off-by-one, null/unwrap safety
2. **Security** — OWASP Top 10, injection, auth bypass, secrets exposure
3. **Performance** — unnecessary allocations, O(n²) patterns, missing indexes
4. **Style** — naming, dead code, missing error handling

Be concise. Only comment on real issues, not nitpicks.
If the code looks good, say so briefly."
      ;;
    security)
      echo "You are a security auditor reviewing PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

Perform a thorough security review of the following diff. Focus on:
1. **Injection** — SQL, command, template injection, unsanitized user input
2. **Auth/Access** — broken auth, missing authorization, privilege escalation
3. **Data exposure** — secrets in code, PII leaks, verbose error messages
4. **Crypto** — weak algorithms, hardcoded keys, missing TLS, improper validation
5. **OWASP Top 10** — any applicable items from the current OWASP list
6. **Supply chain** — dependency vulnerabilities, unsafe deserialization

Rate each finding as Critical / High / Medium / Low.
If no security issues are found, say so explicitly."
      ;;
    quality)
      echo "You are a code quality reviewer for PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

Analyze the following diff for code quality. Focus on:
1. **Readability** — clear naming, logical structure, appropriate abstractions
2. **Complexity** — cyclomatic complexity, deep nesting, god functions
3. **DRY** — duplicated logic that should be extracted
4. **Testing** — missing test coverage, untested edge cases, flaky test patterns
5. **Documentation** — missing or misleading doc comments, stale READMEs
6. **Error handling** — swallowed errors, missing error types, panicking paths

Do NOT comment on style trivia (formatting, import order).
Focus on changes that meaningfully improve maintainability."
      ;;
    performance)
      echo "You are a performance engineer reviewing PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

Analyze the following diff for performance implications. Focus on:
1. **Algorithmic complexity** — O(n²) or worse, unnecessary loops, redundant computation
2. **Memory** — unnecessary allocations, large clones, missing streaming, leaks
3. **I/O** — synchronous blocking calls, missing batching, N+1 queries
4. **Concurrency** — lock contention, race conditions, missing parallelism opportunities
5. **Hot paths** — changes in request handlers, tight loops, or data processing pipelines

Quantify impact where possible (e.g., 'this reduces allocations from O(n) to O(1)').
If no performance concerns are found, say so explicitly."
      ;;
    architecture)
      echo "You are a software architect reviewing PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

Analyze the following diff for architectural soundness. Focus on:
1. **Separation of concerns** — mixed responsibilities, leaky abstractions
2. **Coupling** — tight coupling between modules, hidden dependencies
3. **API design** — breaking changes, inconsistent interfaces, missing versioning
4. **Extensibility** — hard-coded assumptions, missing plugin/extension points
5. **Data flow** — inconsistent state management, missing validation layers
6. **Trade-offs** — acknowledge when a simpler approach has acceptable downsides

Consider the diff in the context of the project's existing patterns.
Suggest concrete alternatives, not just problems."
      ;;
    *)
      # Custom preset — fall through to extra_prompt only
      echo "You are reviewing PR #${pr_number}: \"${pr_title}\" (${head} → ${base}).

${INPUT_PRESET}"
      ;;
  esac
}

# ── Map preset to display label for comment headers ──────────────
preset_label() {
  case "${INPUT_PRESET:-review}" in
    review)       echo "General" ;;
    security)     echo "🔒 Security" ;;
    quality)      echo "✨ Quality" ;;
    performance)  echo "⚡ Performance" ;;
    architecture) echo "🏗️ Architecture" ;;
    *)            echo "${INPUT_PRESET}" ;;
  esac
}

# ── Map preset to agent_type for server dispatch ─────────────────
preset_agent_type() {
  case "${INPUT_PRESET:-review}" in
    review)       echo "code-review" ;;
    security)     echo "security-review" ;;
    quality)      echo "quality-review" ;;
    performance)  echo "performance-review" ;;
    architecture) echo "architecture-review" ;;
    *)            echo "${INPUT_AGENT_TYPE:-code-review}" ;;
  esac
}
