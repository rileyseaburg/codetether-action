#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../action/lib/presets.sh
source "${ROOT}/action/lib/presets.sh"
# shellcheck source=../action/lib/local.sh
source "${ROOT}/action/lib/local.sh"

INPUT_PRESET="review"
prompt="$(build_preset_prompt 'diff --git a/file b/file' main feature 7 'Format check')"

printf '%s' "${prompt}" | grep -q '## Summary'
printf '%s' "${prompt}" | grep -q '## Findings'
printf '%s' "${prompt}" | grep -q '## Validation Notes'
printf '%s' "${prompt}" | grep -q 'Do not output JSON'

json_review='{"findings":[{"severity":"High","body":"bad"}]}'
normalized_json="$(normalize_review_markdown "${json_review}")"
printf '%s' "${normalized_json}" | grep -q 'CodeTether returned structured JSON instead of Markdown'
printf '%s' "${normalized_json}" | grep -q '```json'

fenced_review='```json
{"bad":"format"}
```'
normalized_fence="$(normalize_review_markdown "${fenced_review}")"
printf '%s' "${normalized_fence}" | grep -q 'CodeTether returned a fenced response'
printf '%s' "${normalized_fence}" | grep -q '## Validation Notes'

markdown_review='## Summary
- Looks good.

## Findings
No actionable findings.'
normalized_markdown="$(normalize_review_markdown "${markdown_review}")"
[ "${normalized_markdown}" = "${markdown_review}" ]

echo "review format tests passed"
