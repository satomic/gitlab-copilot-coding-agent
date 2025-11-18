#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

cd "${REPO_ROOT}"

require_env GITLAB_TOKEN
require_env TARGET_PROJECT_ID
require_env TARGET_ISSUE_IID

echo "[INFO] Posting acknowledgment to issue ${TARGET_ISSUE_IID}..."

# Build the note body with pipeline link if available
NOTE_BODY="👀 Got it! Copilot Coding task 🚀 started at $(date -Iseconds)."

if [ -n "${CI_PIPELINE_URL:-}" ]; then
  NOTE_BODY="${NOTE_BODY}\n\n🔗 [View Pipeline Progress](${CI_PIPELINE_URL})"
fi

if ! curl --fail --silent --show-error \
  --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --data-urlencode "body=${NOTE_BODY}" \
  "${UPSTREAM_GITLAB_BASE_URL}/api/v4/projects/${TARGET_PROJECT_ID}/issues/${TARGET_ISSUE_IID}/notes" > /dev/null; then
  echo "[ERROR] Failed to post acknowledgment comment" >&2
  exit 1
fi

echo "[INFO] Acknowledgment posted successfully"

